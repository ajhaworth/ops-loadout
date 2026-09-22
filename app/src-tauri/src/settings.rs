//! Everything persisted outside the catalog: Loadout's own `config.json`
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

/// OPS_LOADOUT_DIR -> saved path -> the source checkout -> ~/Developer/ops/ops-loadout
/// -> the copy seeded from the bundle -> ask once and remember.
pub(crate) fn find_repo(app: &AppHandle) -> Option<PathBuf> {
    if let Some(path) = find_repo_on_disk(app) {
        return Some(path);
    }

    // Nothing on disk: ask. Runs off the main thread (commands here are async).
    use tauri_plugin_dialog::DialogExt;
    let picked = app
        .dialog()
        .file()
        .set_title("Where is the ops-loadout repo?")
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
    // Seeded before the candidates are walked, not just when the last one is
    // reached: once the seeded copy is picked, `save_repo` puts it in
    // `config.json`, where it matches earlier - and an app update still has to
    // refresh it. `seed_bundled_repo` is a no-op when the stamp already matches.
    let seeded = seed_bundled_repo(app);
    // `OPS_LOADOUT_DIR=bundled` forces the seeded copy, for testing a release
    // build on a machine that also has a checkout. Deliberately not saved: the
    // next ordinary launch goes back to the checkout.
    if std::env::var("OPS_LOADOUT_DIR").is_ok_and(|v| v == "bundled") {
        return seeded;
    }

    let candidates = [
        std::env::var("OPS_LOADOUT_DIR").ok().map(PathBuf::from),
        saved_repo(app),
        Some(compiled),
        home.map(|h| h.join("Developer/ops/ops-loadout")),
        seeded,
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

/// A downloaded release carries `config/`, `lib/` and `platforms/` as a Tauri
/// resource (`app/scripts/bundle-repo.js`). The scripts write back into the
/// repo - `config/sidefx.local`, Blender's portable prefs, `.ops-tag` files -
/// and editing an app bundle breaks its ad-hoc seal, so the runtime copy lives
/// in the app data dir instead. Returns that copy, or `None` with no bundle.
fn seed_bundled_repo(app: &AppHandle) -> Option<PathBuf> {
    // Once per process: the candidate list is walked on every `serve_ui` request.
    static SEEDED: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();
    SEEDED
        .get_or_init(|| {
            let source = app.path().resource_dir().ok()?.join("bundled");
            if !source.is_dir() {
                return None;
            }
            let target = app.path().app_data_dir().ok()?.join("repo");
            let version = app.package_info().version.to_string();
            if let Err(e) = seed_dir(&source, &target, &version) {
                eprintln!("seed {}: {e}", target.display());
            }
            catalog::is_repo(&target).then_some(target)
        })
        .clone()
}

/// Copy `source` over `target` unless `target/.bundled-version` already reads
/// the version and bundle revision. Refresh scripts without deleting runtime
/// files or overwriting saved Blender preferences and startup scenes.
fn seed_dir(source: &Path, target: &Path, version: &str) -> std::io::Result<()> {
    let revision = std::fs::read_to_string(source.join(".bundle-revision")).unwrap_or_default();
    let version = if revision.trim().is_empty() {
        version.to_string()
    } else {
        format!("{version}:{}", revision.trim())
    };
    let stamp = target.join(".bundled-version");
    if std::fs::read_to_string(&stamp).is_ok_and(|s| s.trim() == version) {
        return Ok(());
    }
    copy_over(source, target)?;
    std::fs::write(stamp, version)
}

fn copy_over(source: &Path, target: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let to = target.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_over(&entry.path(), &to)?;
        } else {
            // Blender saves personal preferences and startup scenes here. Seed
            // defaults on first install, but preserve them across app updates.
            if to.exists() && to.extension().is_some_and(|e| e == "blend") {
                continue;
            }
            std::fs::copy(entry.path(), &to)?;
            // Tauri's resource copying keeps the mode bits today (verified in a
            // built .app), but nothing promises it does, and Loadout execs
            // `lib/tasks.sh` and `platforms/**/*.sh` directly.
            #[cfg(unix)]
            if to.extension().is_some_and(|e| e == "sh") {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o755))?;
            }
        }
    }
    Ok(())
}

fn settings_file(handle: &AppHandle, store: &Store) -> Result<PathBuf, String> {
    let repo = repo_of(handle, store).ok_or("no ops-loadout repo found")?;
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
            // A quoted value ends at its closing quote; a bare one at the first
            // `#`. Either way a trailing `# comment` is dropped, as bash does.
            let unquote = |q: char| {
                let rest = value.strip_prefix(q)?;
                let end = rest.find(q)?;
                Some(&rest[..end])
            };
            let value = unquote('\'')
                .or_else(|| unquote('"'))
                .unwrap_or_else(|| value.split('#').next().unwrap_or("").trim());
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
    let repo = repo_of(&handle, &store).ok_or("no ops-loadout repo found")?;
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

#[cfg(test)]
mod tests {
    #[test]
    fn env_file_drops_trailing_comments() {
        let vars = super::parse_env_file(
            "A=\"false\"   # why\nB='x'#c\nC=bare # c\nD=\"a # b\"\n# E=1\n",
        );
        let get = |k: &str| vars.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
        assert_eq!(get("A"), Some("false"));
        assert_eq!(get("B"), Some("x"));
        assert_eq!(get("C"), Some("bare"));
        assert_eq!(get("D"), Some("a # b"));
        assert_eq!(get("E"), None);
    }

    use super::seed_dir;

    fn write(path: &std::path::Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
    }

    #[test]
    fn same_version_rebuild_refreshes_scripts_but_preserves_blender_preferences() {
        let tmp = std::env::temp_dir().join(format!("ops-seed-revision-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let (source, target) = (tmp.join("bundled"), tmp.join("repo"));
        let prefs = "config/dcc/blender/portable/config/userpref.blend";
        write(&source.join(prefs), "defaults");
        write(&source.join("lib/tasks.sh"), "old");
        write(&source.join(".bundle-revision"), "first");
        seed_dir(&source, &target, "0.3.4").unwrap();
        write(&target.join(prefs), "personal preferences");
        write(&source.join("lib/tasks.sh"), "fixed");
        write(&source.join(".bundle-revision"), "second");
        seed_dir(&source, &target, "0.3.4").unwrap();
        assert_eq!(std::fs::read_to_string(target.join("lib/tasks.sh")).unwrap(), "fixed");
        assert_eq!(std::fs::read_to_string(target.join(prefs)).unwrap(), "personal preferences");
        std::fs::remove_dir_all(tmp).unwrap();
    }

    #[test]
    fn seeds_once_then_refreshes_on_a_new_version_without_deleting() {
        let tmp = std::env::temp_dir().join(format!("ops-seed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let (source, target) = (tmp.join("bundled"), tmp.join("repo"));
        write(&source.join("config/packages/macos/formulae/core.txt"), "git\n");
        write(&source.join("lib/tasks.sh"), "v1\n");

        seed_dir(&source, &target, "0.1.0").unwrap();
        assert_eq!(std::fs::read_to_string(target.join("lib/tasks.sh")).unwrap(), "v1\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(target.join("lib/tasks.sh")).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "*.sh must be executable");
        }

        // Same version: nothing is copied, so a local edit survives.
        write(&target.join("lib/tasks.sh"), "edited\n");
        write(&target.join("config/sidefx.local"), "secret\n");
        seed_dir(&source, &target, "0.1.0").unwrap();
        assert_eq!(std::fs::read_to_string(target.join("lib/tasks.sh")).unwrap(), "edited\n");

        // New version: tracked files are overwritten, extras are left alone.
        write(&source.join("lib/tasks.sh"), "v2\n");
        seed_dir(&source, &target, "0.2.0").unwrap();
        assert_eq!(std::fs::read_to_string(target.join("lib/tasks.sh")).unwrap(), "v2\n");
        assert_eq!(std::fs::read_to_string(target.join("config/sidefx.local")).unwrap(), "secret\n");
        std::fs::remove_dir_all(&tmp).unwrap();
    }
}
