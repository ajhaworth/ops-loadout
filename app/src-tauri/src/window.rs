//! Loadout's windows: the `loadout://` scheme that serves the UI off disk,
//! the full window, and the quick panel anchored to the tray icon.

use crate::settings::{find_repo_on_disk, Store};
use std::path::Path;
use tauri::{AppHandle, Manager};

/// Serves `<repo>/app/ui/*` straight off disk so a `git pull` (or an edit)
/// updates the installed app's UI without a rebuild. Falls back to the
/// assets baked in at build time when the repo isn't found.
pub(crate) fn serve_ui(
    ctx: tauri::UriSchemeContext<'_, tauri::Wry>,
    req: tauri::http::Request<Vec<u8>>,
) -> tauri::http::Response<Vec<u8>> {
    let path = req.uri().path().trim_start_matches('/');
    let path = if path.is_empty() { "index.html" } else { path };
    let app = ctx.app_handle();

    // `dcc/...` serves `<repo>/config/dcc/...` - the DCC helper pages (the
    // Blender keymap viewer) live with their configs, not in the Loadout UI.
    // No embedded copy of those, so a missing repo just 404s below.
    let rel = match path.strip_prefix("dcc/") {
        Some(rest) => Path::new("config/dcc").join(rest),
        None => Path::new("app/ui").join(path),
    };
    let from_disk = find_repo_on_disk(app)
        .map(|r| r.join(rel))
        .filter(|p| p.is_file() && !path.contains(".."))
        .and_then(|p| std::fs::read(p).ok());
    let (bytes, mime) = match from_disk {
        Some(bytes) => {
            let mime = match path.rsplit('.').next() {
                Some("html") => "text/html",
                Some("js") => "text/javascript",
                Some("css") => "text/css",
                Some("svg") => "image/svg+xml",
                Some("png") => "image/png",
                Some("json") => "application/json",
                Some("py") => "text/plain",
                _ => "application/octet-stream",
            };
            (bytes, mime.to_string())
        }
        None => match app.asset_resolver().get(format!("/{path}")) {
            Some(asset) => (asset.bytes, asset.mime_type),
            None => {
                return tauri::http::Response::builder().status(404).body(Vec::new()).unwrap()
            }
        },
    };
    let csp = app.config().app.security.csp.as_ref().map(|c| c.to_string()).unwrap_or_default();
    tauri::http::Response::builder()
        .header("Content-Type", mime)
        .header("Content-Security-Policy", csp)
        .body(bytes)
        .unwrap()
}

/// Bring the full Loadout window up, dismissing the quick panel.
pub(crate) fn show_main(app: &AppHandle) {
    if let Some(quick) = app.get_webview_window("quick") {
        let _ = quick.hide();
    }
    if let Some(main) = app.get_webview_window("main") {
        // A Dock tile while the full window is up; back to tray-only on close.
        #[cfg(target_os = "macos")]
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
        let _ = main.show();
        let _ = main.unminimize();
        let _ = main.set_focus();
    }
}

/// Top-left corner for a panel of `(w, h)` centred under (or over) a tray icon
/// at `(x, y, w, h)`, all in physical pixels. A menubar at the top of the
/// screen (macOS) drops the panel below the icon; a taskbar at the bottom
/// (Windows) puts it above. `monitor` is that screen's `(x, y, w, h)`, which
/// keeps a panel hanging off the right edge on screen - tray icons live there
/// on both platforms. `None` when the monitor is unknown: place it unclamped
/// rather than guess at bounds.
pub(crate) fn panel_origin(
    icon: (i32, i32, i32, i32),
    panel: (i32, i32),
    monitor: Option<(i32, i32, i32, i32)>,
) -> (i32, i32) {
    let (ix, iy, iw, ih) = icon;
    let (pw, ph) = panel;
    let mut x = ix + iw / 2 - pw / 2;
    let mut y = if iy < 100 { iy + ih } else { iy - ph };
    if let Some((mx, my, mw, mh)) = monitor {
        x = x.min(mx + mw - pw);
        y = y.min(my + mh - ph);
    }
    (x.max(0), y.max(0))
}

/// Show or hide the quick panel, anchored to the tray icon's screen rect.
pub(crate) fn toggle_quick(app: &AppHandle, rect: tauri::Rect) {
    let Some(window) = app.get_webview_window("quick") else { return };
    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        return;
    }
    // ponytail: blur-hide races the tray click; a click within 250ms of the
    // hide is the same click, so treat it as "toggle off".
    if let Some(at) = *app.state::<Store>().quick_hidden_at.lock().unwrap() {
        if at.elapsed() < std::time::Duration::from_millis(250) {
            return;
        }
    }

    let scale = window.scale_factor().unwrap_or(1.0);
    let icon_pos = rect.position.to_physical::<i32>(scale);
    let icon_size = rect.size.to_physical::<i32>(scale);
    // A hidden window may not report a current monitor yet, hence the fallback.
    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
        .map(|m| {
            let (pos, size) = (m.position(), m.size());
            (pos.x, pos.y, size.width as i32, size.height as i32)
        });
    if let Ok(win) = window.outer_size() {
        let (x, y) = panel_origin(
            (icon_pos.x, icon_pos.y, icon_size.width, icon_size.height),
            (win.width as i32, win.height as i32),
            monitor,
        );
        let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
    }
    let _ = window.show();
    let _ = window.set_focus();
}

#[tauri::command]
pub(crate) async fn open_full(handle: AppHandle) -> Result<(), String> {
    show_main(&handle);
    Ok(())
}

/// Opens a page served by `serve_ui` in its own window, one per path.
#[tauri::command]
pub(crate) async fn open_page(handle: AppHandle, path: String) -> Result<(), String> {
    let url = if cfg!(windows) {
        format!("http://loadout.localhost/{path}")
    } else {
        format!("loadout://localhost/{path}")
    };
    let label: String =
        path.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();

    if let Some(window) = handle.get_webview_window(&label) {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let url = url.parse().map_err(|e| format!("bad page url: {e}"))?;
    tauri::WebviewWindowBuilder::new(&handle, label, tauri::WebviewUrl::External(url))
        .title("Loadout")
        .inner_size(1100.0, 780.0)
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub(crate) async fn hide_quick(handle: AppHandle) -> Result<(), String> {
    if let Some(quick) = handle.get_webview_window("quick") {
        let _ = quick.hide();
    }
    Ok(())
}
