// Ops Launcher - a grid of every app config/packages/** knows about.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod catalog;
mod platform;

use catalog::App;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Instant;
use tauri::menu::MenuBuilder;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

#[derive(Default)]
struct Store {
    repo: Mutex<Option<PathBuf>>,
    apps: Mutex<Vec<App>>,
    /// When the quick panel last hid itself on blur - see `toggle_quick`.
    quick_hidden_at: Mutex<Option<Instant>>,
}

/// One row from `lib/tasks.sh status` / `bridge.ps1 tasks-status` - see
/// CLAUDE.md "Setup Tasks (launcher)" for the JSON contract.
#[derive(Clone, Serialize, Deserialize)]
struct Task {
    id: String,
    section: String,
    group: String,
    name: String,
    state: String,
    detail: String,
}

/// `config.json` in the app config dir. `#[serde(default)]` keeps a
/// pre-existing `{"repo": ...}` file (from before `profile` existed) loading
/// fine, and keeps a config with neither field loading fine too.
#[derive(Default, Serialize, Deserialize)]
struct Config {
    #[serde(default)]
    repo: Option<String>,
    #[serde(default)]
    profile: Option<String>,
}

fn config_file(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("config.json"))
}

fn read_config(app: &AppHandle) -> Config {
    config_file(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write_config(app: &AppHandle, config: &Config) {
    let Some(path) = config_file(app) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(body) = serde_json::to_string(config) {
        let _ = std::fs::write(path, body);
    }
}

fn saved_repo(app: &AppHandle) -> Option<PathBuf> {
    read_config(app).repo.map(PathBuf::from)
}

fn save_repo(app: &AppHandle, repo: &Path) {
    let mut config = read_config(app);
    config.repo = Some(repo.to_string_lossy().to_string());
    write_config(app, &config);
}

/// `None` when unset, same as an empty string from the settings form.
fn saved_profile(app: &AppHandle) -> Option<String> {
    read_config(app).profile.filter(|p| !p.is_empty())
}

/// OPS_DESKTOP_DIR -> saved path -> the source checkout -> ~/Developer/ops/ops-desktop
/// -> ask once and remember.
fn find_repo(app: &AppHandle) -> Option<PathBuf> {
    if let Some(path) = find_repo_on_disk(app) {
        return Some(path);
    }

    // Nothing on disk: ask. Runs off the main thread (commands here are async).
    use tauri_plugin_dialog::DialogExt;
    let picked = app
        .dialog()
        .file()
        .set_title("Where is the ops-desktop repo?")
        .blocking_pick_folder()?;
    let picked = picked.into_path().ok()?;
    if catalog::is_repo(&picked) {
        save_repo(app, &picked);
        return Some(picked);
    }
    None
}

/// The non-interactive half of `find_repo`: safe to call from anywhere.
fn find_repo_on_disk(app: &AppHandle) -> Option<PathBuf> {
    let compiled = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let home = app.path().home_dir().ok();

    let candidates = [
        std::env::var("OPS_DESKTOP_DIR").ok().map(PathBuf::from),
        saved_repo(app),
        Some(compiled),
        home.map(|h| h.join("Developer/ops/ops-desktop")),
    ];

    for path in candidates.into_iter().flatten() {
        if catalog::is_repo(&path) {
            let path = path.canonicalize().unwrap_or(path);
            save_repo(app, &path);
            return Some(path);
        }
    }
    None
}

/// Serves `<repo>/app/ui/*` straight off disk so a `git pull` (or an edit)
/// updates the installed launcher's UI without a rebuild. Falls back to the
/// assets baked in at build time when the repo isn't found.
fn serve_ui(
    ctx: tauri::UriSchemeContext<'_, tauri::Wry>,
    req: tauri::http::Request<Vec<u8>>,
) -> tauri::http::Response<Vec<u8>> {
    let path = req.uri().path().trim_start_matches('/');
    let path = if path.is_empty() { "index.html" } else { path };
    let app = ctx.app_handle();

    let from_disk = find_repo_on_disk(app)
        .map(|r| r.join("app/ui").join(path))
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

fn repo_of(app: &AppHandle, store: &Store) -> Option<PathBuf> {
    let mut guard = store.repo.lock().unwrap();
    if guard.is_none() {
        *guard = find_repo(app);
    }
    guard.clone()
}

fn cache_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("ops-launcher"))
}

fn resource_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .resource_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// Dock badge with the number of updates waiting. Windows has no badge count -
/// it wants an overlay icon instead - so this is macOS only.
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))]
fn set_dock_badge(handle: &AppHandle, apps: &[App]) {
    #[cfg(target_os = "macos")]
    if let Some(window) = handle.get_webview_window("main") {
        let n = apps.iter().filter(|a| a.outdated).count() as i64;
        let _ = window.set_badge_count((n > 0).then_some(n));
    }
}

fn rescan(app: &AppHandle, store: &Store) -> Result<Vec<App>, String> {
    let repo = repo_of(app, store).ok_or("no ops-desktop repo found")?;
    let mut apps = catalog::scan(&repo);
    platform::hydrate(&mut apps, &cache_dir(app), &repo, &resource_dir(app));
    *store.apps.lock().unwrap() = apps.clone();
    set_dock_badge(app, &apps);
    Ok(apps)
}

#[tauri::command]
async fn list_apps(app: AppHandle, store: State<'_, Store>) -> Result<Vec<App>, String> {
    let cached = store.apps.lock().unwrap().clone();
    if !cached.is_empty() {
        return Ok(cached);
    }
    rescan(&app, &store)
}

#[tauri::command]
async fn refresh(app: AppHandle, store: State<'_, Store>) -> Result<Vec<App>, String> {
    rescan(&app, &store)
}

#[tauri::command]
async fn set_repo_dir(
    app: AppHandle,
    store: State<'_, Store>,
    path: String,
) -> Result<Vec<App>, String> {
    let path = PathBuf::from(path);
    if !catalog::is_repo(&path) {
        return Err(format!("{} has no config/packages", path.display()));
    }
    save_repo(&app, &path);
    *store.repo.lock().unwrap() = Some(path);
    rescan(&app, &store)
}

fn find_app(store: &Store, id: &str) -> Option<App> {
    store
        .apps
        .lock()
        .unwrap()
        .iter()
        .find(|a| a.id == id)
        .cloned()
}

#[tauri::command]
async fn launch(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    let app = find_app(&store, &id).ok_or("unknown app")?;
    platform::launch(&app, &resource_dir(&handle))
}

#[tauri::command]
async fn install(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    run_job(handle, store, id, "install")
}

#[tauri::command]
async fn uninstall(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    run_job(handle, store, id, "uninstall")
}

#[tauri::command]
async fn update(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    run_job(handle, store, id, "update")
}

#[tauri::command]
async fn reinstall(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    run_job(handle, store, id, "reinstall")
}

#[tauri::command]
async fn reveal(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    let app = find_app(&store, &id).ok_or("unknown app")?;
    platform::reveal(&app, &resource_dir(&handle))
}

/// Opens the package's homepage in the default browser. Only http(s) is passed
/// on; anything else in a list file stays unopened.
#[tauri::command]
async fn open_homepage(handle: AppHandle, store: State<'_, Store>, id: String) -> Result<(), String> {
    let app = find_app(&store, &id).ok_or("unknown app")?;
    let url = app.homepage.as_deref().ok_or("no homepage for this entry")?;
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(format!("refusing to open {url}"));
    }
    platform::open_url(url, &resource_dir(&handle))
}

/// Opens a link the UI itself points at (the Settings help). Same http(s)-only
/// rule as `open_homepage`.
#[tauri::command]
async fn open_url(handle: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(format!("refusing to open {url}"));
    }
    platform::open_url(&url, &resource_dir(&handle))
}

fn settings_file(handle: &AppHandle, store: &Store) -> Result<PathBuf, String> {
    let repo = repo_of(handle, store).ok_or("no ops-desktop repo found")?;
    Ok(repo.join("config/sidefx.local"))
}

/// `KEY="value"` / `KEY=value` lines with `#` comments - the shape bash sources.
fn parse_env_file(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            let value = value.trim();
            let unquote = |q: char| value.strip_prefix(q).and_then(|v| v.strip_suffix(q));
            let value = unquote('\'').or_else(|| unquote('"')).unwrap_or(value);
            Some((key.trim().to_string(), value.to_string()))
        })
        .collect()
}

/// The current OS name as `config/profiles/*.conf`'s `PROFILE_OS` spells it.
fn profile_os() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// Names of `config/profiles/*.conf` whose `PROFILE_OS` matches this platform
/// (or is absent). Sorted for a stable dropdown order.
fn list_profiles(repo: &Path) -> Vec<String> {
    let os = profile_os();
    let Ok(entries) = std::fs::read_dir(repo.join("config/profiles")) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "conf"))
        .filter_map(|p| {
            let stem = p.file_stem()?.to_string_lossy().to_string();
            let text = std::fs::read_to_string(&p).ok()?;
            let its_os = parse_env_file(&text)
                .into_iter()
                .find(|(k, _)| k == "PROFILE_OS")
                .map(|(_, v)| v);
            its_os.map_or(true, |v| v == os).then_some(stem)
        })
        .collect();
    names.sort();
    names
}

/// The SideFX credentials `platforms/macos/installers/houdini.sh` reads, plus
/// the saved profile and the profiles available for this platform.
/// Missing file or missing key reads as empty, so the dialog just opens blank.
#[tauri::command]
async fn get_settings(
    handle: AppHandle,
    store: State<'_, Store>,
) -> Result<serde_json::Value, String> {
    let repo = repo_of(&handle, &store).ok_or("no ops-desktop repo found")?;
    let path = settings_file(&handle, &store)?;
    let vars = parse_env_file(&std::fs::read_to_string(path).unwrap_or_default());
    let value = |key: &str| {
        vars.iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    Ok(serde_json::json!({
        "sidefx_client_id": value("SIDEFX_CLIENT_ID"),
        "sidefx_client_secret": value("SIDEFX_CLIENT_SECRET"),
        "profile": saved_profile(&handle).unwrap_or_default(),
        "profiles": list_profiles(&repo),
    }))
}

#[tauri::command]
async fn set_settings(
    handle: AppHandle,
    store: State<'_, Store>,
    sidefx_client_id: String,
    sidefx_client_secret: String,
    profile: String,
) -> Result<(), String> {
    let mut config = read_config(&handle);
    config.profile = (!profile.trim().is_empty()).then(|| profile.trim().to_string());
    write_config(&handle, &config);

    let path = settings_file(&handle, &store)?;
    let id = sidefx_client_id.trim();
    let secret = sidefx_client_secret.trim();
    // The file is sourced by bash. Single quotes expand nothing, so only the
    // quote itself and a newline could break out of the value.
    if [id, secret].iter().any(|v| v.contains('\'') || v.contains('\n')) {
        return Err("credentials cannot contain a single quote or a newline".into());
    }

    if id.is_empty() && secret.is_empty() {
        return match std::fs::remove_file(&path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        };
    }

    let body = format!(
        "# SideFX web API credentials for platforms/macos/installers/houdini.sh (gitignored)\n\
         SIDEFX_CLIENT_ID='{id}'\n\
         SIDEFX_CLIENT_SECRET='{secret}'\n"
    );
    // Created 0600, never briefly world-readable; an existing file keeps its
    // own mode, so narrow that one too.
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
    };
    #[cfg(not(unix))]
    let file = std::fs::File::create(&path);
    use std::io::Write;
    file.and_then(|mut f| f.write_all(body.as_bytes()))
        .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// One `lib/tasks.sh status <section>` / `bridge.ps1 tasks-status` call. Short
/// and one-shot, so it runs the same way `list_apps`/`refresh` do - straight
/// inside the async command, off the UI thread by virtue of not being awaited
/// on it.
#[tauri::command]
async fn tasks_status(handle: AppHandle, store: State<'_, Store>, section: String) -> Result<Vec<Task>, String> {
    let repo = repo_of(&handle, &store).ok_or("no ops-desktop repo found")?;
    let resources = resource_dir(&handle);
    let profile = saved_profile(&handle);
    let cmd = platform::task_command("status", &section, None, &repo, &resources, profile.as_deref())?;

    let out = std::process::Command::new(&cmd.program)
        .args(&cmd.args)
        .envs(cmd.env.iter().cloned())
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    serde_json::from_slice::<Vec<Task>>(&out.stdout).map_err(|_| {
        let text: String = String::from_utf8_lossy(&out.stdout).chars().take(300).collect();
        format!("could not parse task status: {text}")
    })
}

/// Applies one task, streaming like a package job but without the app-catalog
/// bookkeeping (`run_job`'s icon refresh / dock badge) - a task has no `App`.
#[tauri::command]
async fn run_task(handle: AppHandle, store: State<'_, Store>, id: String, section: String) -> Result<(), String> {
    let repo = repo_of(&handle, &store).ok_or("no ops-desktop repo found")?;
    let resources = resource_dir(&handle);
    let profile = saved_profile(&handle);
    let cmd = platform::task_command("apply", &section, Some(&id), &repo, &resources, profile.as_deref())?;

    std::thread::spawn(move || {
        let ok = run_streaming(&handle, &id, "apply", cmd);
        let _ = handle.emit(
            "install-done",
            serde_json::json!({ "id": id, "ok": ok, "action": "apply" }),
        );
    });

    Ok(())
}

/// Runs one package-manager job in the background, streaming its output to the
/// UI as `install-log` and finishing with `install-done`. Both events carry the
/// action, so the frontend can tell an install from an uninstall.
fn run_job(
    handle: AppHandle,
    store: State<'_, Store>,
    id: String,
    action: &'static str,
) -> Result<(), String> {
    let target = find_app(&store, &id).ok_or("unknown app")?;
    let repo = repo_of(&handle, &store).ok_or("no ops-desktop repo found")?;
    let resources = resource_dir(&handle);
    let cache = cache_dir(&handle);
    let cmd = platform::job_command(action, &target, &repo, &resources)?;

    std::thread::spawn(move || {
        let ok = run_streaming(&handle, &id, action, cmd);

        if ok {
            let store: State<'_, Store> = handle.state();

            // refresh_icon shells out, so work on a clone with the lock released.
            let mut fresh = find_app(&store, &id);
            if let Some(app) = fresh.as_mut() {
                // Whatever the job was, the app is no longer behind.
                app.outdated = false;
                if action == "uninstall" {
                    app.installed = false;
                    app.launchable = false;
                    app.icon = None;
                } else {
                    app.installed = true;
                    platform::refresh_icon(app, &cache, &repo, &resources);
                }
            }

            if let Some(fresh) = fresh {
                let snapshot = {
                    let mut apps = store.apps.lock().unwrap();
                    if let Some(app) = apps.iter_mut().find(|a| a.id == id) {
                        app.installed = fresh.installed;
                        app.outdated = fresh.outdated;
                        app.launchable = fresh.launchable;
                        app.icon = fresh.icon;
                        app.target = fresh.target;
                    }
                    apps.clone()
                };
                set_dock_badge(&handle, &snapshot);
            }
        }

        let _ = handle.emit(
            "install-done",
            serde_json::json!({ "id": id, "ok": ok, "action": action }),
        );
    });

    Ok(())
}

fn run_streaming(handle: &AppHandle, id: &str, action: &str, cmd: platform::Cmd) -> bool {
    let child = std::process::Command::new(&cmd.program)
        .args(&cmd.args)
        .envs(cmd.env.iter().cloned())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();

    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            emit_line(handle, id, action, &format!("{}: {e}", cmd.program));
            return false;
        }
    };

    let mut pumps = Vec::new();
    for pipe in [
        child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
        child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let handle = handle.clone();
        let id = id.to_string();
        let action = action.to_string();
        pumps.push(std::thread::spawn(move || {
            for line in BufReader::new(pipe).lines().map_while(Result::ok) {
                emit_line(&handle, &id, &action, &line);
            }
        }));
    }
    for pump in pumps {
        let _ = pump.join();
    }

    child.wait().map(|s| s.success()).unwrap_or(false)
}

fn emit_line(handle: &AppHandle, id: &str, action: &str, line: &str) {
    let _ = handle.emit(
        "install-log",
        serde_json::json!({ "id": id, "line": line, "action": action }),
    );
}

#[cfg(target_os = "macos")]
fn install_askpass(dir: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let script = dir.join("askpass.sh");
    let body = "#!/bin/sh\nexec osascript -e 'display dialog \"Ops Launcher needs your password to finish this update.\" with title \"Ops Launcher\" default answer \"\" with hidden answer buttons {\"Cancel\", \"OK\"} default button \"OK\"' -e 'text returned of result'\n";
    let ok = std::fs::create_dir_all(dir).is_ok()
        && std::fs::write(&script, body).is_ok()
        && std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).is_ok();
    if ok {
        std::env::set_var("SUDO_ASKPASS", &script);
    }
}

/// Bring the full launcher window up, dismissing the quick panel.
fn show_main(app: &AppHandle) {
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
fn panel_origin(
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
fn toggle_quick(app: &AppHandle, rect: tauri::Rect) {
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
fn open_full(app: AppHandle) {
    show_main(&app);
}

#[tauri::command]
fn hide_quick(app: AppHandle) {
    if let Some(quick) = app.get_webview_window("quick") {
        let _ = quick.hide();
    }
}

fn main() {
    // Launched from Finder, the app inherits launchd's minimal PATH, which lacks
    // Homebrew's bin dir, so brew and mas would look absent. Fix it once here
    // and every child process inherits it.
    #[cfg(target_os = "macos")]
    {
        let path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("/opt/homebrew/bin:/usr/local/bin:{path}"));
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(Store::default())
        .register_uri_scheme_protocol("ops", serve_ui)
        .setup(|app| {
            // The tray is the app's home; no Dock tile, no menubar of our own.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            for label in ["main", "quick"] {
                let Some(window) = app.get_webview_window(label) else { continue };

                #[cfg(target_os = "macos")]
                window_vibrancy::apply_vibrancy(
                    &window,
                    window_vibrancy::NSVisualEffectMaterial::HudWindow,
                    None,
                    Some(10.0), // matches the 10px CSS radius; the effect view otherwise fills the square window
                )
                .ok();

                #[cfg(target_os = "windows")]
                window_vibrancy::apply_mica(&window, None).ok();

                let _ = &window;
            }

            // Some casks (istat-menus) and mas run sudo, which has no terminal
            // here to prompt from. SUDO_ASKPASS points it at a native password
            // dialog instead; brew passes -A along when the variable is set.
            #[cfg(target_os = "macos")]
            install_askpass(&cache_dir(app.handle()));

            let menu = MenuBuilder::new(app)
                .text("open", "Open Ops Launcher")
                .separator()
                .quit_with_text("Quit")
                .build()?;
            TrayIconBuilder::with_id("tray")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("Ops Launcher")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| {
                    if event.id().as_ref() == "open" {
                        show_main(app);
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        rect,
                        ..
                    } = event
                    {
                        toggle_quick(tray.app_handle(), rect);
                    }
                })
                .build(app)?;

            Ok(())
        })
        .on_window_event(|window, event| match event {
            // Closing a window would tear down the app's only UI; the tray
            // keeps it alive, so close means hide.
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
                #[cfg(target_os = "macos")]
                if window.label() == "main" {
                    let _ = window.app_handle().set_activation_policy(tauri::ActivationPolicy::Accessory);
                }
            }
            WindowEvent::Focused(false) if window.label() == "quick" => {
                let _ = window.hide();
                *window.state::<Store>().quick_hidden_at.lock().unwrap() = Some(Instant::now());
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            list_apps,
            refresh,
            set_repo_dir,
            launch,
            install,
            uninstall,
            update,
            reinstall,
            reveal,
            open_homepage,
            open_url,
            get_settings,
            set_settings,
            tasks_status,
            run_task,
            open_full,
            hide_quick
        ])
        .run(tauri::generate_context!())
        .expect("error while running Ops Launcher");
}

#[cfg(test)]
mod smoke {
    /// Headless catalog check against the checkout this crate lives in.
    /// `cargo test -- --ignored --nocapture` to see the counts.
    #[test]
    #[ignore]
    fn scan_this_repo() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        assert!(crate::catalog::is_repo(&repo), "{} is not the repo", repo.display());

        let mut apps = crate::catalog::scan(&repo);
        crate::platform::hydrate(&mut apps, &std::env::temp_dir().join("ops-launcher-test"), &repo, &repo);

        let mut by_kind: std::collections::BTreeMap<&str, (usize, usize, usize, usize)> =
            Default::default();
        let mut categories: std::collections::BTreeSet<(&str, &str)> = Default::default();
        for a in &apps {
            let e = by_kind.entry(&a.kind).or_default();
            e.0 += 1;
            e.1 += a.installed as usize;
            e.2 += a.icon.is_some() as usize;
            e.3 += a.outdated as usize;
            categories.insert((&a.kind, &a.category));
        }
        for (kind, (total, installed, icons, outdated)) in &by_kind {
            println!(
                "{kind:10} total={total:3} installed={installed:3} icons={icons:3} outdated={outdated:3}"
            );
        }
        for a in apps.iter().filter(|a| a.outdated) {
            println!("  update available: {}", a.id);
        }
        for (kind, cat) in &categories {
            println!("  {kind}/{cat}");
        }
        for a in &apps {
            if a.installed && a.icon.is_none() && a.kind != "formula" {
                println!("  no icon: {} target={:?}", a.id, a.target);
            }
        }
        assert!(!apps.is_empty());
        // Informational only: a fully up-to-date machine legitimately has none.
        println!("  outdated: {}", apps.iter().filter(|a| a.outdated).count());
    }

    /// Menubar icon anchors below, taskbar icon above, and neither runs off an
    /// edge of the screen.
    #[test]
    fn panel_anchors_to_the_right_side_of_the_tray_icon() {
        let panel = (340, 400);
        let mon = Some((0, 0, 2560, 1440));
        let at = |icon| crate::panel_origin(icon, panel, mon);
        assert_eq!(at((500, 0, 24, 24)), (342, 24));
        assert_eq!(at((1800, 1400, 24, 24)), (1642, 1000));
        assert_eq!(at((10, 0, 24, 24)), (0, 24));
        // Icon in the far corner: the panel stops at the right edge.
        assert_eq!(at((2540, 0, 24, 24)), (2220, 24));
    }

    #[test]
    fn env_file_parses_quoted_and_bare_values() {
        let vars = crate::parse_env_file(
            "# comment\nSIDEFX_CLIENT_ID='a$(b)'\n\nSIDEFX_CLIENT_SECRET = bare\nQ=\"dq\"\n#KEY=no\n",
        );
        assert_eq!(
            vars,
            [
                ("SIDEFX_CLIENT_ID".to_string(), "a$(b)".to_string()),
                ("SIDEFX_CLIENT_SECRET".to_string(), "bare".to_string()),
                ("Q".to_string(), "dq".to_string()),
            ]
        );
    }

    /// Against this checkout's real `config/profiles/`: macOS sees only the
    /// two macOS profiles, not windows/linux.
    #[cfg(target_os = "macos")]
    #[test]
    fn list_profiles_filters_by_os() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        assert_eq!(crate::list_profiles(&repo), vec!["personal", "work"]);
    }

    fn app_of(kind: &str, token: &str) -> crate::catalog::App {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        crate::catalog::scan(&repo)
            .into_iter()
            .find(|a| a.kind == kind && a.token == token)
            .unwrap_or_else(|| panic!("no {kind} named {token} in the lists"))
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn job_argv_per_kind_and_action() {
        let here = std::path::Path::new(".");
        let argv = |action: &str, a: &crate::catalog::App| {
            let c = crate::platform::job_command(action, a, here, here).unwrap();
            (c.program, c.args)
        };
        let brew = |args: &[&str]| {
            ("brew".to_string(), args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        };

        let cask = app_of("cask", "blender");
        assert_eq!(argv("install", &cask), brew(&["install", "--cask", "blender"]));
        assert_eq!(argv("uninstall", &cask), brew(&["uninstall", "--cask", "blender"]));
        assert_eq!(argv("update", &cask), brew(&["upgrade", "--cask", "blender"]));
        assert_eq!(argv("reinstall", &cask), brew(&["reinstall", "--cask", "blender"]));

        let formula = app_of("formula", "ripgrep");
        assert_eq!(argv("uninstall", &formula), brew(&["uninstall", "ripgrep"]));
        assert_eq!(argv("update", &formula), brew(&["upgrade", "ripgrep"]));
        assert_eq!(argv("reinstall", &formula), brew(&["reinstall", "ripgrep"]));

        let mas = crate::catalog::scan(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."),
        )
        .into_iter()
        .find(|a| a.kind == "mas")
        .unwrap();
        // mas runs under sudo -A so its own inner sudo needs no password.
        let (program, args) = argv("update", &mas);
        assert_eq!(program, "sudo");
        assert_eq!(args[0], "-A");
        assert!(args[1].ends_with("/mas"), "{args:?}");
        assert_eq!(&args[2..], ["upgrade".to_string(), mas.token.clone()]);
        // Root cannot delete App Store apps either, so Finder trashes them.
        let (program, args) = argv("uninstall", &mas);
        assert_eq!(program, "osascript");
        assert_eq!(args[0], "-e");
        assert!(
            args[1].starts_with(r#"tell application "Finder" to delete POSIX file "/"#)
                && args[1].ends_with(r#".app""#),
            "unexpected script: {}",
            args[1]
        );
        // Installers take the action verbatim; the script is the program.
        let inst = app_of("installer", "houdini");
        for action in ["install", "update", "reinstall", "uninstall"] {
            let (program, args) = argv(action, &inst);
            assert!(
                program.ends_with("platforms/macos/installers/houdini.sh"),
                "unexpected program: {program}"
            );
            assert_eq!(args, [action.to_string()]);
        }
        assert!(crate::platform::job_command("frobnicate", &inst, here, here).is_err());

        // A no-op over an installed app, so it is not offered either.
        assert!(crate::platform::job_command("reinstall", &mas, here, here).is_err());
        assert!(crate::platform::job_command("frobnicate", &cask, here, here).is_err());
    }

    /// Runs the generated argv for real against a cask that is not installed:
    /// brew refuses it, which proves the command line parses without removing
    /// anything.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore]
    fn uninstall_argv_runs() {
        let here = std::path::Path::new(".");
        let app = app_of("cask", "blender");
        assert!(!app.installed, "pick a cask that is not installed");

        let cmd = crate::platform::job_command("uninstall", &app, here, here).unwrap();
        let out = std::process::Command::new(&cmd.program)
            .args(&cmd.args)
            .envs(cmd.env.iter().cloned())
            .output()
            .unwrap();
        let err = String::from_utf8_lossy(&out.stderr).to_string();
        println!("exit={:?} stderr={}", out.status.code(), err.trim());
        assert!(
            err.contains("not installed"),
            "expected a not-installed refusal, got: {err}"
        );
    }
}
