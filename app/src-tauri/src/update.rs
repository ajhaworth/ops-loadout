//! Tray > Check for Updates. Asks the GitHub releases API for the newest
//! release, compares its tag with the running version and installs the dmg
//! (macOS) or NSIS exe (Windows) - see CLAUDE.md "Launchbay".
use crate::emit_line;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::AppHandle;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};

const LATEST: &str = "https://api.github.com/repos/ajhaworth/ops-workstation/releases/latest";

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
    let body = match sh("curl", &["-fsSL", "-H", "User-Agent: Launchbay", LATEST]) {
        Ok(body) => body,
        Err(e) => return say(app, &format!("Update check failed: {e}")),
    };
    let release: serde_json::Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => return say(app, &format!("Update check failed: {e}")),
    };

    let tag = match release["tag_name"].as_str() {
        Some(tag) => tag.to_string(),
        None => return say(app, "Update check failed: no tag in the latest release."),
    };
    let latest = match semver::Version::parse(tag.trim_start_matches('v')) {
        Ok(v) => v,
        Err(e) => return say(app, &format!("Update check failed: {tag}: {e}")),
    };
    if latest <= app.package_info().version {
        let version = app.package_info().version.to_string();
        return say(app, &format!("Launchbay {version} is up to date."));
    }

    let ext = if cfg!(target_os = "macos") {
        ".dmg"
    } else {
        ".exe"
    };
    let asset = release["assets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|a| {
            a["name"]
                .as_str()
                .is_some_and(|n| n.to_lowercase().ends_with(ext))
        });
    let (name, url) = match asset {
        Some(a) => (
            a["name"].as_str().unwrap_or_default().to_string(),
            a["browser_download_url"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
        ),
        None => {
            return say(
                app,
                &format!("Release {tag} has no installer for this platform."),
            )
        }
    };
    // The name goes into a path: keep it a bare file name.
    if name.is_empty() || name.contains(['/', '\\']) || !url.starts_with("https://github.com/") {
        return say(
            app,
            &format!("Update check failed: unexpected asset {name}"),
        );
    }

    let install = app
        .dialog()
        .message(format!(
            "Version {latest} is available. Install and relaunch?"
        ))
        .title("Launchbay")
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Install".into(),
            "Later".into(),
        ))
        .blocking_show();
    if !install {
        return;
    }

    log(app, &format!("Downloading Launchbay {latest}"));
    let file = std::env::temp_dir().join(&name);
    if let Err(e) = sh("curl", &["-fL", "-o", &file.to_string_lossy(), &url]) {
        return say(app, &format!("Update failed: {e}"));
    }

    #[cfg(target_os = "macos")]
    {
        let mnt = std::env::temp_dir().join("launchbay-update");
        let bundle = match std::env::current_exe().ok().and_then(|exe| {
            // exe is <Launchbay.app>/Contents/MacOS/launchbay
            exe.parent()?.parent()?.parent().map(|p| p.to_path_buf())
        }) {
            Some(b) if b.extension().is_some_and(|e| e == "app") => b,
            _ => return say(app, "Update failed: not running from an app bundle."),
        };
        if let Err(e) = sh(
            "hdiutil",
            &[
                "attach",
                "-nobrowse",
                "-noautoopen",
                "-mountpoint",
                &mnt.to_string_lossy(),
                &file.to_string_lossy(),
            ],
        ) {
            return say(app, &format!("Update failed: {e}"));
        }
        // Copy beside the old bundle first, then swap, so a failed copy never
        // leaves the app deleted.
        let app_name = bundle
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let staged = bundle.with_extension("app.new");
        let old = bundle.with_extension("app.old");
        let replaced = sh(
            "rm",
            &["-rf", &staged.to_string_lossy(), &old.to_string_lossy()],
        )
        .and_then(|_| {
            sh(
                "ditto",
                &[
                    &mnt.join(&app_name).to_string_lossy(),
                    &staged.to_string_lossy(),
                ],
            )
        })
        .and_then(|_| sh("mv", &[&bundle.to_string_lossy(), &old.to_string_lossy()]))
        .and_then(|_| {
            sh(
                "mv",
                &[&staged.to_string_lossy(), &bundle.to_string_lossy()],
            )
        })
        .and_then(|_| sh("rm", &["-rf", &old.to_string_lossy()]));
        let _ = sh("hdiutil", &["detach", &mnt.to_string_lossy()]);
        if let Err(e) = replaced {
            return say(app, &format!("Update failed: {e}"));
        }
        log(app, "Update installed, relaunching");
        // restart() never returns; the new binary comes up in its place.
        app.restart();
    }

    #[cfg(target_os = "windows")]
    {
        // ponytail: /P /R unverified on a real Windows box until the first release ships an exe.
        match Command::new(&file).args(["/P", "/R"]).spawn() {
            Ok(_) => app.exit(0),
            Err(e) => say(app, &format!("Update failed: {e}")),
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    say(
        app,
        "Self-update is only implemented for macOS and Windows.",
    );
}

/// Runs a command to completion, stdout on success, stderr in the error.
fn sh(program: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "{program} failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn say(app: &AppHandle, text: &str) {
    log(app, text);
    app.dialog()
        .message(text)
        .title("Launchbay")
        .blocking_show();
}

/// Same `install-log` stream the package jobs use, so the log drawer shows it.
fn log(app: &AppHandle, line: &str) {
    emit_line(app, "updater", "update", line);
}
