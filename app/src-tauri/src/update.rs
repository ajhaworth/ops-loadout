//! Tray > Check for Updates. tauri-plugin-updater against the `latest.json`
//! attached to each GitHub release - see CLAUDE.md "Ops Launcher".
use crate::emit_line;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::AppHandle;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_updater::UpdaterExt;

/// Checks, asks, installs and relaunches. Runs off the main thread, since the
/// dialogs block and the download takes as long as it takes.
pub fn check_for_updates(app: &AppHandle) {
    // One at a time: a second click mid-download must not start a second
    // install into the same running bundle.
    static BUSY: AtomicBool = AtomicBool::new(false);
    if BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        run(&app).await;
        BUSY.store(false, Ordering::SeqCst);
    });
}

async fn run(app: &AppHandle) {
    let found = match app.updater() {
        Ok(updater) => updater.check().await,
        Err(e) => Err(e),
    };

    let update = match found {
        Err(e) => return say(app, &format!("Update check failed: {e}")),
        Ok(None) => {
            let version = app.package_info().version.to_string();
            return say(app, &format!("Ops Launcher {version} is up to date."));
        }
        Ok(Some(update)) => update,
    };

    let install = app
        .dialog()
        .message(format!(
            "Version {} is available. Install and relaunch?",
            update.version
        ))
        .title("Ops Launcher")
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Install".into(),
            "Later".into(),
        ))
        .blocking_show();
    if !install {
        return;
    }

    log(app, &format!("Downloading Ops Launcher {}", update.version));
    let mut got = 0usize;
    let mut last = 0usize;
    let progress = |chunk: usize, total: Option<u64>| {
        got += chunk;
        // One line per 10%, or per 5 MB when the size is unknown.
        let step = total.map_or(5 << 20, |t| (t as usize / 10).max(1));
        if got - last >= step {
            last = got;
            match total {
                Some(t) => log(app, &format!("  {}%", got * 100 / t as usize)),
                None => log(app, &format!("  {} MB", got >> 20)),
            }
        }
    };
    match update.download_and_install(progress, || {}).await {
        // restart() never returns; the new binary comes up in its place.
        Ok(()) => {
            log(app, "Update installed, relaunching");
            app.restart();
        }
        Err(e) => say(app, &format!("Update failed: {e}")),
    }
}

fn say(app: &AppHandle, text: &str) {
    log(app, text);
    app.dialog().message(text).title("Ops Launcher").blocking_show();
}

/// Same `install-log` stream the package jobs use, so the log drawer shows it.
fn log(app: &AppHandle, line: &str) {
    emit_line(app, "updater", "update", line);
}
