// Ops Launcher - a grid of every app config/packages/** knows about.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod catalog;
mod platform;

use catalog::App;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Default)]
struct Store {
    repo: Mutex<Option<PathBuf>>,
    apps: Mutex<Vec<App>>,
}

fn config_file(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("config.json"))
}

fn saved_repo(app: &AppHandle) -> Option<PathBuf> {
    let text = std::fs::read_to_string(config_file(app)?).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    Some(PathBuf::from(v.get("repo")?.as_str()?))
}

fn save_repo(app: &AppHandle, repo: &Path) {
    let Some(path) = config_file(app) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let body = serde_json::json!({ "repo": repo.to_string_lossy() });
    let _ = std::fs::write(path, body.to_string());
}

/// OPS_DESKTOP_DIR -> saved path -> the source checkout -> ~/Developer/ops/ops-desktop
/// -> ask once and remember.
fn find_repo(app: &AppHandle) -> Option<PathBuf> {
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
        .manage(Store::default())
        .setup(|app| {
            let window = app.get_webview_window("main").unwrap();

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
            Ok(())
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
            open_homepage
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
        assert_eq!(
            argv("update", &mas),
            ("mas".to_string(), vec!["upgrade".to_string(), mas.token.clone()])
        );
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
