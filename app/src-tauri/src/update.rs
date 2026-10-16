//! Tray > Check for Updates. Reads the newest release tag from github.com,
//! compares it with the running version and installs the dmg (macOS) or NSIS
//! exe (Windows) - see CLAUDE.md "Loadout".
use crate::emit_line;
#[cfg(target_os = "macos")]
use std::path::Path;
use std::path::PathBuf;
#[cfg(target_os = "windows")]
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};

/// Left in the app data dir across the relaunch so the new process brings the
/// window back up. A file, not an environment variable: the NSIS installer's
/// `/R` starts the new app through Explorer, which inherits nothing from us.
pub fn reopen_marker(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|dir| dir.join("reopen-after-update"))
}

fn mark_reopen(app: &AppHandle) {
    if let Some(marker) = reopen_marker(app) {
        if let Some(dir) = marker.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(marker, "");
    }
}

const REPO: &str = "https://github.com/ajhaworth/ops-loadout";

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

/// The newest release's version, read from where `<repo>/releases/latest`
/// redirects (`.../releases/tag/vX.Y.Z`). Shared by the tray's "Check for
/// Updates" and the background checker. Not the REST API: unauthenticated it
/// allows 60 requests an hour per IP, shared with every other GitHub lookup on
/// the network (Windows tile status, Blender extensions), and answers 403 once
/// they are spent - which broke updates on both platforms.
pub fn latest_release() -> Result<semver::Version, String> {
    let null = if cfg!(windows) { "NUL" } else { "/dev/null" };
    let url = sh("curl", &["-sS", "-o", null, "-w", "%{redirect_url}", &format!("{REPO}/releases/latest")])?;
    let tag = url
        .trim()
        .rsplit_once("/tag/")
        .map(|(_, tag)| tag)
        .ok_or_else(|| format!("no release tag in redirect {url:?}"))?;
    semver::Version::parse(tag.trim_start_matches('v')).map_err(|e| format!("{tag}: {e}"))
}

async fn run(app: &AppHandle) {
    let latest = match latest_release() {
        Ok(v) => v,
        Err(e) => return say(app, &format!("Update check failed: {e}")),
    };
    if latest <= app.package_info().version {
        let version = app.package_info().version.to_string();
        return say(app, &format!("Loadout {version} is up to date."));
    }

    // tauri-action's names for release.yml's two bundles (Apple silicon dmg,
    // x64 NSIS); a rename there must change these.
    let name = if cfg!(target_os = "macos") {
        format!("Loadout_{latest}_aarch64.dmg")
    } else {
        format!("Loadout_{latest}_x64-setup.exe")
    };
    let url = format!("{REPO}/releases/download/v{latest}/{name}");

    let install = app
        .dialog()
        .message(format!(
            "Version {latest} is available. Install and relaunch?"
        ))
        .title("Loadout")
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Install".into(),
            "Later".into(),
        ))
        .blocking_show();
    if !install {
        return;
    }

    log(app, &format!("Downloading Loadout {latest}"));
    let file = std::env::temp_dir().join(&name);
    if let Err(e) = sh("curl", &["-fsSL", "-o", &file.to_string_lossy(), &url]) {
        return say(app, &format!("Update failed: {e}"));
    }

    #[cfg(target_os = "macos")]
    {
        let mnt = std::env::temp_dir().join("loadout-update");
        let bundle = match std::env::current_exe().ok().and_then(|exe| {
            // exe is <Loadout.app>/Contents/MacOS/loadout
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
        let replaced = mounted_app(&mnt).and_then(|src| swap_bundle(&src, &bundle, sh));
        let _ = sh("hdiutil", &["detach", &mnt.to_string_lossy()]);
        if let Err(e) = replaced {
            return say(app, &format!("Update failed: {e}"));
        }
        log(app, "Update installed, relaunching");
        mark_reopen(app);
        // restart() never returns; the new binary comes up in its place.
        app.restart();
    }

    #[cfg(target_os = "windows")]
    {
        // ponytail: /P /R unverified on a real Windows box until the first release ships an exe.
        mark_reopen(app);
        match Command::new(&file).args(["/P", "/R"]).spawn() {
            Ok(_) => app.exit(0),
            Err(e) => {
                if let Some(marker) = reopen_marker(app) {
                    let _ = std::fs::remove_file(marker);
                }
                say(app, &format!("Update failed: {e}"))
            }
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    say(
        app,
        "Self-update is only implemented for macOS and Windows.",
    );
}

/// Replaces `bundle` with a copy of `src`. Copies beside the old bundle
/// first, then swaps, so a failed copy never leaves the app deleted. `sh` is
/// a parameter so tests can fail one step.
#[cfg(target_os = "macos")]
fn swap_bundle(
    src: &Path,
    bundle: &Path,
    sh: impl Fn(&str, &[&str]) -> Result<String, String>,
) -> Result<(), String> {
    let staged = bundle.with_extension("app.new");
    let old = bundle.with_extension("app.old");
    let (src, bundle, staged, old) = (
        src.to_string_lossy(),
        bundle.to_string_lossy(),
        staged.to_string_lossy(),
        old.to_string_lossy(),
    );
    sh("rm", &["-rf", &staged, &old])?;
    sh("ditto", &[&src, &staged])?;
    sh("mv", &[&bundle, &old])?;
    if let Err(e) = sh("mv", &[&staged, &bundle]) {
        // Put the old app back rather than leave none at all.
        let _ = sh("mv", &[&old, &bundle]);
        return Err(e);
    }
    // The new app is in place; a leftover .app.old goes on the next update.
    let _ = sh("rm", &["-rf", &old]);
    Ok(())
}

/// The one `.app` inside a mounted disk image. Its name follows the product
/// name, which renames do change - so this never assumes it matches the bundle
/// being replaced. Guessing that name is what stranded the updater across the
/// Ops Launcher -> Launchbay -> Loadout renames.
#[cfg(target_os = "macos")]
fn mounted_app(mnt: &Path) -> Result<PathBuf, String> {
    let mut apps: Vec<PathBuf> = std::fs::read_dir(mnt)
        .map_err(|e| format!("{}: {e}", mnt.display()))?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "app"))
        .collect();
    match apps.len() {
        1 => Ok(apps.remove(0)),
        n => Err(format!("expected one .app in the disk image, found {n}")),
    }
}

/// Runs a command to completion, stdout on success, stderr in the error.
/// `platform::command`, so curl opens no console window on Windows (one that
/// would sit there for the whole download, and kill it if closed).
fn sh(program: &str, args: &[&str]) -> Result<String, String> {
    let out = crate::platform::command(program)
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
        .title("Loadout")
        .blocking_show();
}

/// Same `install-log` stream the package jobs use, so the log drawer shows it.
fn log(app: &AppHandle, line: &str) {
    emit_line(app, "updater", "update", line);
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::{mounted_app, sh, swap_bundle};
    use std::cell::Cell;

    /// Whichever step fails, an app is left at the bundle path: the old one
    /// when the update reports failure, the new one when it reports success.
    #[test]
    fn a_failed_swap_never_leaves_the_app_missing() {
        let root = std::env::temp_dir().join(format!("loadout-swap-{}", std::process::id()));
        let (src, bundle) = (root.join("dmg/Loadout.app"), root.join("Applications/Loadout.app"));
        let version = |p: &std::path::Path| std::fs::read_to_string(p.join("v")).ok();
        for fail_at in 0..6 {
            let _ = std::fs::remove_dir_all(&root);
            for (dir, v) in [(&src, "new"), (&bundle, "old")] {
                std::fs::create_dir_all(dir).unwrap();
                std::fs::write(dir.join("v"), v).unwrap();
            }
            let step = Cell::new(0);
            let result = swap_bundle(&src, &bundle, |program, args| {
                step.set(step.get() + 1);
                if step.get() == fail_at { Err(format!("injected {program}")) } else { sh(program, args) }
            });
            let want = if result.is_ok() { "new" } else { "old" };
            assert_eq!(version(&bundle).as_deref(), Some(want), "failing step {fail_at}: {result:?}");
            assert!(!bundle.with_extension("app.new").exists() || result.is_err(), "step {fail_at}: staged copy left");
        }
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn takes_the_apps_own_name_not_the_running_bundles() {
        let mnt = std::env::temp_dir().join("loadout-update-test");
        let _ = std::fs::remove_dir_all(&mnt);
        std::fs::create_dir_all(mnt.join("Applications")).unwrap();
        assert!(mounted_app(&mnt).is_err(), "no .app yet");

        // The dmg carries the new name; the running bundle is still the old one.
        std::fs::create_dir(mnt.join("Loadout.app")).unwrap();
        assert_eq!(mounted_app(&mnt).unwrap(), mnt.join("Loadout.app"));

        std::fs::create_dir(mnt.join("Launchbay.app")).unwrap();
        assert!(mounted_app(&mnt).is_err(), "ambiguous with two bundles");
        std::fs::remove_dir_all(&mnt).unwrap();
    }
}

#[cfg(test)]
mod live {
    /// Network: the redirect still names a tag (run with --ignored).
    #[test]
    #[ignore]
    fn latest_release_reads_the_redirect() {
        let v = super::latest_release().unwrap();
        assert!(v >= semver::Version::new(0, 24, 0), "{v}");
    }
}
