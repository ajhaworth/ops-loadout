//! Everything persisted outside the catalog: the launcher's own `config.json`
//! (repo path, profile), repo discovery, and the SideFX credentials the
//! Settings dialog writes into `<repo>/config/sidefx.local`.

use crate::catalog::{self, App};
use crate::repo_of;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;
use tauri::{AppHandle, Manager, State};

#[derive(Default)]
pub(crate) struct Store {
    pub(crate) repo: Mutex<Option<PathBuf>>,
    pub(crate) apps: Mutex<Vec<App>>,
    /// When the quick panel last hid itself on blur - see `toggle_quick`.
    pub(crate) quick_hidden_at: Mutex<Option<Instant>>,
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
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("config dir {}: {e}", dir.display());
        }
    }
    if let Ok(body) = serde_json::to_string(config) {
        if let Err(e) = std::fs::write(&path, body) {
            eprintln!("config write {}: {e}", path.display());
        }
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
pub(crate) fn saved_profile(app: &AppHandle) -> Option<String> {
    read_config(app).profile.filter(|p| !p.is_empty())
}

/// OPS_DESKTOP_DIR -> saved path -> the source checkout -> ~/Developer/ops/ops-desktop
/// -> ask once and remember.
pub(crate) fn find_repo(app: &AppHandle) -> Option<PathBuf> {
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
pub(crate) fn find_repo_on_disk(app: &AppHandle) -> Option<PathBuf> {
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

fn settings_file(handle: &AppHandle, store: &Store) -> Result<PathBuf, String> {
    let repo = repo_of(handle, store).ok_or("no ops-desktop repo found")?;
    Ok(repo.join("config/sidefx.local"))
}

/// `KEY="value"` / `KEY=value` lines with `#` comments - the shape bash sources.
pub(crate) fn parse_env_file(text: &str) -> Vec<(String, String)> {
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
pub(crate) fn list_profiles(repo: &Path) -> Vec<String> {
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
pub(crate) async fn get_settings(
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
pub(crate) async fn set_settings(
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
