// Ops Launcher - a grid of every app config/packages/** knows about.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod catalog;
mod platform;
mod settings;
mod window;

use catalog::App;
use serde::{Deserialize, Serialize};
use settings::{find_repo, saved_profile, Store};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;
use tauri::menu::MenuBuilder;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use window::{serve_ui, show_main, toggle_quick};

// Addressed at the crate root by the tests at the bottom of this file.
#[cfg(test)]
use settings::{list_profiles, parse_env_file};
#[cfg(test)]
use window::panel_origin;

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

pub(crate) fn repo_of(app: &AppHandle, store: &Store) -> Option<PathBuf> {
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
async fn list_apps(handle: AppHandle, store: State<'_, Store>) -> Result<Vec<App>, String> {
    let cached = store.apps.lock().unwrap().clone();
    if !cached.is_empty() {
        return Ok(cached);
    }
    rescan(&handle, &store)
}

#[tauri::command]
async fn refresh(handle: AppHandle, store: State<'_, Store>) -> Result<Vec<App>, String> {
    rescan(&handle, &store)
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
            launch,
            install,
            uninstall,
            update,
            reinstall,
            reveal,
            open_homepage,
            open_url,
            settings::get_settings,
            settings::set_settings,
            tasks_status,
            run_task,
            window::open_full,
            window::open_page,
            window::hide_quick
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

        let cask = app_of("cask", "gimp");
        assert_eq!(argv("install", &cask), brew(&["install", "--cask", "gimp"]));
        assert_eq!(argv("uninstall", &cask), brew(&["uninstall", "--cask", "gimp"]));
        assert_eq!(argv("update", &cask), brew(&["upgrade", "--cask", "gimp"]));
        assert_eq!(argv("reinstall", &cask), brew(&["reinstall", "--cask", "gimp"]));

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
