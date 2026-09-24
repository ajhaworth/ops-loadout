//! macOS backend: brew/mas status, icon extraction, launch, install.

use crate::catalog::App;
use crate::platform::Cmd;
use base64::Engine;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One `brew info --json=v2` call for the whole set.
///
/// brew fails the entire call when any token is unknown, naming it in stderr;
/// drop those and retry.
// ponytail: drops any requested token whose text appears in brew's error
// output. A token that is a substring of another package's error text would be
// dropped too - if that ever bites, parse the quoted name instead.
fn brew_info(flag: &str, tokens: &[String]) -> Option<Value> {
    if tokens.is_empty() {
        return None;
    }
    let mut wanted: Vec<String> = tokens.to_vec();

    for _ in 0..3 {
        let out = Command::new("brew")
            .arg("info")
            .arg("--json=v2")
            .arg(flag)
            .args(&wanted)
            .output()
            .ok()?;

        if out.status.success() {
            return serde_json::from_slice(&out.stdout).ok();
        }

        let err = String::from_utf8_lossy(&out.stderr).to_string();
        let kept: Vec<String> = wanted
            .iter()
            .filter(|t| !err.contains(t.as_str()))
            .cloned()
            .collect();
        if kept.len() == wanted.len() || kept.is_empty() {
            return None;
        }
        wanted = kept;
    }
    None
}

fn lines_of(cmd: &str, args: &[&str]) -> Vec<String> {
    Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// The `.app` a cask installs, from `artifacts[].app[0]`.
fn cask_app_name(cask: &Value) -> Option<String> {
    cask.get("artifacts")?.as_array()?.iter().find_map(|a| {
        a.get("app")?
            .as_array()?
            .first()?
            .as_str()
            .map(str::to_string)
    })
}

fn bundle_path(app_name: &str) -> Option<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    [
        PathBuf::from("/Applications").join(app_name),
        PathBuf::from(&home).join("Applications").join(app_name),
    ]
    .into_iter()
    .find(|p| p.is_dir())
}

/// App Store apps are not always named after their listing, so fall back to
/// Spotlight's record of the purchase id.
fn mas_bundle_path(name: &str, id: &str) -> Option<PathBuf> {
    bundle_path(&format!("{name}.app")).or_else(|| {
        lines_of("mdfind", &[&format!("kMDItemAppStoreAdamID == {id}")])
            .into_iter()
            .map(PathBuf::from)
            .find(|p| p.is_dir())
    })
}

fn installer_script(repo: &Path, token: &str) -> PathBuf {
    repo.join("platforms/macos/installers").join(format!("{token}.sh"))
}

/// The script prints where it installed to, then `outdated` when its applied
/// config has drifted from the repo; a non-zero exit means "not here".
fn installer_status(repo: &Path, token: &str) -> Option<(PathBuf, bool)> {
    let out = Command::new(installer_script(repo, token)).arg("status").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut lines = stdout.lines().map(str::trim).filter(|l| !l.is_empty());
    let path = PathBuf::from(lines.next()?);
    Some((path, lines.any(|l| l == "outdated")))
}

/// A resolved `.app` bundle: openable, revealable and worth an icon.
fn mark_launchable(app: &mut App, bundle: &Path, cache_dir: &Path) {
    app.launchable = true;
    app.target = Some(bundle.to_string_lossy().to_string());
    app.icon = icon(bundle, &app.id, cache_dir);
}

/// Only a `.app` can be opened; anything else is still worth revealing.
fn set_installer_target(app: &mut App, path: &Path, cache_dir: &Path) {
    app.target = Some(path.to_string_lossy().to_string());
    if path.is_dir() && path.extension().is_some_and(|e| e == "app") {
        app.launchable = true;
        app.icon = icon(path, &app.id, cache_dir);
    }
}

fn icns_in(bundle: &Path) -> Option<PathBuf> {
    let resources = bundle.join("Contents/Resources");

    let plist = Command::new("plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(bundle.join("Contents/Info.plist"))
        .output()
        .ok()?;
    let named = serde_json::from_slice::<Value>(&plist.stdout)
        .ok()
        .and_then(|v| {
            let name = v.get("CFBundleIconFile")?.as_str()?.to_string();
            let name = if name.ends_with(".icns") {
                name
            } else {
                format!("{name}.icns")
            };
            Some(resources.join(name))
        })
        .filter(|p| p.is_file());

    named.or_else(|| {
        std::fs::read_dir(&resources)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .find(|p| p.extension().is_some_and(|e| e == "icns"))
    })
}

fn cache_name(id: &str) -> String {
    format!("{}.png", id.replace(['/', ':', ' '], "_"))
}

/// 128px PNG data URL for an installed bundle, cached on disk.
pub fn icon(bundle: &Path, id: &str, cache_dir: &Path) -> Option<String> {
    let png = cache_dir.join(cache_name(id));

    if !png.is_file() {
        let icns = icns_in(bundle)?;
        std::fs::create_dir_all(cache_dir).ok()?;
        let ok = Command::new("sips")
            .args(["-s", "format", "png", "-Z", "128"])
            .arg(&icns)
            .arg("--out")
            .arg(&png)
            .output()
            .ok()
            .is_some_and(|o| o.status.success());
        if !ok {
            return None;
        }
    }

    let bytes = std::fs::read(&png).ok()?;
    Some(format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

/// Re-read one app's icon after a successful install.
pub fn refresh_icon(app: &mut App, cache_dir: &Path, repo: &Path, _resources: &Path) {
    if app.kind == "installer" {
        if let Some((path, outdated)) = installer_status(repo, &app.token) {
            app.outdated = outdated;
            set_installer_target(app, &path, cache_dir);
        }
        return;
    }
    let bundle = match app.kind.as_str() {
        "cask" => app.target.as_deref().and_then(bundle_path),
        "mas" => mas_bundle_path(&app.name, &app.token),
        _ => None,
    };
    if let Some(bundle) = bundle {
        mark_launchable(app, &bundle, cache_dir);
    }
}

/// Tokens brew reports as upgradable. `--greedy-auto-updates` covers casks that
/// update themselves but leaves `version :latest` ones alone, which have no
/// version to compare. Network-touching, so a failure just means "none known".
fn brew_outdated() -> (Vec<String>, Vec<String>) {
    let none = (Vec::new(), Vec::new());
    let Ok(out) = Command::new("brew")
        .args(["outdated", "--json=v2", "--greedy-auto-updates"])
        .envs(brew_env())
        .output()
    else {
        return none;
    };
    if !out.status.success() {
        return none;
    }
    let Ok(value) = serde_json::from_slice::<Value>(&out.stdout) else {
        return none;
    };

    let names = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|e| e.get("name")?.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    };
    (names("casks"), names("formulae"))
}

/// `owner/repo` from a cask's `homepage` or `url`, when either is a GitHub URL.
fn github_slug(c: &Value) -> Option<String> {
    ["homepage", "url"].into_iter().find_map(|key| {
        let rest = c.get(key)?.as_str()?.strip_prefix("https://github.com/")?;
        let mut parts = rest.split('/');
        let owner = parts.next().filter(|s| !s.is_empty())?;
        let repo = parts
            .next()?
            .split(['#', '?'])
            .next()?
            .trim_end_matches(".git");
        (!repo.is_empty()).then(|| format!("{owner}/{repo}"))
    })
}

/// `license.spdx_id` for a GitHub repo, via curl - the crate has no HTTP
/// client and everything else here shells out too.
///
/// `Some(x)` is an answer worth caching (including `Some(None)` for a repo with
/// no license); `None` means the lookup failed and must not be cached. Sets
/// `blocked` when GitHub rate-limits us, so the caller stops asking.
fn github_license(slug: &str, blocked: &mut bool) -> Option<Option<String>> {
    let mut cmd = Command::new("curl");
    cmd.args([
        "-sSL",
        "--max-time",
        "5",
        "-w",
        "\n%{http_code}",
        "-H",
        "User-Agent: loadout",
        "-H",
        "Accept: application/vnd.github+json",
    ]);
    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        if !token.is_empty() {
            cmd.arg("-H").arg(format!("Authorization: Bearer {token}"));
        }
    }
    let out = cmd
        .arg(format!("https://api.github.com/repos/{slug}"))
        .output()
        .ok()?;

    let body = String::from_utf8_lossy(&out.stdout);
    let (body, code) = body.rsplit_once('\n')?;
    match code.trim() {
        "200" => {}
        "403" | "429" => {
            *blocked = true;
            return None;
        }
        _ => return None,
    }

    let value: Value = serde_json::from_str(body).ok()?;
    Some(
        value
            .get("license")
            .and_then(|l| l.get("spdx_id"))
            .and_then(Value::as_str)
            .filter(|s| *s != "NOASSERTION")
            .map(str::to_string),
    )
}

/// Cask JSON never carries a `license` key, so ask GitHub when the cask points
/// at a repo. Answers are cached on disk, nulls included, to keep a routine
/// hydrate off the network.
fn cask_license(
    c: &Value,
    cache: &mut serde_json::Map<String, Value>,
    blocked: &mut bool,
    dirty: &mut bool,
) -> Option<String> {
    let slug = github_slug(c)?;
    if let Some(hit) = cache.get(&slug) {
        return hit.as_str().map(str::to_string);
    }
    if *blocked {
        return None;
    }
    let found = github_license(&slug, blocked)?;
    cache.insert(slug, found.clone().map_or(Value::Null, Value::String));
    *dirty = true;
    found
}

pub fn hydrate(apps: &mut [App], cache_dir: &Path, repo: &Path, _resources: &Path) {
    let license_cache = cache_dir.join("github-licenses.json");
    let mut licenses: serde_json::Map<String, Value> = std::fs::read_to_string(&license_cache)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    let (mut blocked, mut dirty) = (false, false);

    let tokens = |kind: &str| -> Vec<String> {
        apps.iter()
            .filter(|a| a.kind == kind)
            .map(|a| a.token.clone())
            .collect()
    };

    // A profile can leave no brew or mas apps in the catalog at all (see
    // `catalog::filter_by_profile`), so every lookup below is gated on its own
    // kind being present - a machine without Homebrew is then never asked for
    // it.
    let (cask_tokens, formula_tokens, mas_tokens) = (tokens("cask"), tokens("formula"), tokens("mas"));

    // Casks: `installed` is the version string, null when absent.
    let cask_info = brew_info("--cask", &cask_tokens);
    let installed_casks: Vec<String> = if cask_info.is_none() && !cask_tokens.is_empty() {
        lines_of("brew", &["list", "--cask", "-1"])
    } else {
        Vec::new()
    };

    // Formulae: `installed` is an array of installed kegs.
    let formula_info = brew_info("--formula", &formula_tokens);
    let installed_formulae: Vec<String> = if formula_info.is_none() && !formula_tokens.is_empty() {
        lines_of("brew", &["list", "--formula", "-1"])
    } else {
        Vec::new()
    };

    let ids = |lines: Vec<String>| -> Vec<String> {
        lines.iter().filter_map(|l| l.split_whitespace().next().map(str::to_string)).collect()
    };
    // `mas list` is "<id>  <name>  (<version>)", `mas outdated` the same with
    // "(<old> -> <new>)".
    let (installed_mas, outdated_mas) = if mas_tokens.is_empty() {
        (Vec::new(), Vec::new())
    } else {
        (ids(lines_of("mas", &["list"])), ids(lines_of("mas", &["outdated"])))
    };

    let (outdated_casks, outdated_formulae) = if cask_tokens.is_empty() && formula_tokens.is_empty() {
        (Vec::new(), Vec::new())
    } else {
        brew_outdated()
    };

    let find = |info: &Option<Value>, key: &str, token: &str| -> Option<Value> {
        info.as_ref()?
            .get(key)?
            .as_array()?
            .iter()
            .find(|e| {
                e.get("token").and_then(Value::as_str) == Some(token)
                    || e.get("full_name").and_then(Value::as_str) == Some(token)
                    || e.get("name").and_then(Value::as_str) == Some(token)
            })
            .cloned()
    };

    for app in apps.iter_mut() {
        match app.kind.as_str() {
            "cask" => {
                if let Some(c) = find(&cask_info, "casks", &app.token) {
                    app.installed = !c.get("installed").is_none_or(Value::is_null);
                    app.homepage = c
                        .get("homepage")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    app.license = cask_license(&c, &mut licenses, &mut blocked, &mut dirty);
                    if let Some(app_file) = cask_app_name(&c) {
                        app.name = app_file.trim_end_matches(".app").to_string();
                        app.target = Some(app_file);
                    }
                } else {
                    app.installed = installed_casks.contains(&app.token);
                }
                app.outdated = app.installed && outdated_casks.contains(&app.token);
                if app.installed {
                    if let Some(bundle) = app.target.as_deref().and_then(bundle_path) {
                        mark_launchable(app, &bundle, cache_dir);
                    }
                }
            }
            "formula" => {
                if let Some(f) = find(&formula_info, "formulae", &app.token) {
                    app.installed = f
                        .get("installed")
                        .and_then(Value::as_array)
                        .is_some_and(|a| !a.is_empty());
                    app.homepage = f
                        .get("homepage")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    app.license = f.get("license").and_then(Value::as_str).map(str::to_string);
                } else {
                    app.installed = installed_formulae.contains(&app.token);
                }
                app.outdated = app.installed && outdated_formulae.contains(&app.token);
            }
            "mas" => {
                app.installed = installed_mas.contains(&app.token);
                app.outdated = app.installed && outdated_mas.contains(&app.token);
                if app.installed {
                    if let Some(bundle) = mas_bundle_path(&app.name, &app.token) {
                        mark_launchable(app, &bundle, cache_dir);
                    }
                }
            }
            // The script is the only source of truth here. It reports no
            // version, so `outdated` means config drift, not a newer release.
            "installer" => {
                if let Some((path, outdated)) = installer_status(repo, &app.token) {
                    app.installed = true;
                    app.outdated = outdated;
                    set_installer_target(app, &path, cache_dir);
                }
            }
            _ => {}
        }
    }

    if dirty {
        let _ = std::fs::create_dir_all(cache_dir);
        let _ = std::fs::write(&license_cache, Value::Object(licenses).to_string());
    }

    mas_artwork(apps, cache_dir);
}

/// `trackId -> artworkUrl512` from an iTunes lookup response.
fn artwork_urls(lookup: &Value) -> serde_json::Map<String, Value> {
    let results = lookup.get("results").and_then(Value::as_array);
    results
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let id = r.get("trackId")?.as_u64()?.to_string();
            Some((id, r.get("artworkUrl512")?.clone()))
        })
        .collect()
}

/// App Store artwork for MAS apps with no local bundle to extract an icon from,
/// so the "+ more" menu shows the real icon instead of a monogram. One batched
/// iTunes lookup, cached on disk with misses too (Apple's own apps, like Pages,
/// are absent from the API), so a routine hydrate stays off the network.
fn mas_artwork(apps: &mut [App], cache_dir: &Path) {
    let cache_file = cache_dir.join("mas-artwork.json");
    let mut cache: serde_json::Map<String, Value> = std::fs::read_to_string(&cache_file)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let wanted = |a: &App| a.kind == "mas" && a.icon.is_none();
    let missing: Vec<String> = apps
        .iter()
        .filter(|a| wanted(a) && !cache.contains_key(&a.token))
        .map(|a| a.token.clone())
        .collect();
    if !missing.is_empty() {
        let lookup = Command::new("curl")
            .args(["-sSf", "--max-time", "5"])
            .arg(format!("https://itunes.apple.com/lookup?id={}", missing.join(",")))
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok());
        // A failed lookup caches nothing, so the next hydrate asks again.
        if let Some(lookup) = lookup {
            let found = artwork_urls(&lookup);
            for id in missing {
                let url = found.get(&id).cloned().unwrap_or(Value::Null);
                cache.insert(id, url);
            }
            let _ = std::fs::create_dir_all(cache_dir);
            let _ = std::fs::write(&cache_file, Value::Object(cache.clone()).to_string());
        }
    }

    for app in apps.iter_mut().filter(|a| wanted(a)) {
        app.icon = cache.get(&app.token).and_then(Value::as_str).map(str::to_string);
    }
}

pub fn launch(app: &App, _resources: &Path) -> Result<(), String> {
    let target = app.target.as_deref().ok_or("no app bundle for this entry")?;
    run(Command::new("open").arg("-a").arg(target), "open -a")
}

fn brew_env() -> Vec<(String, String)> {
    // HOMEBREW_NO_COLOR, not HOMEBREW_COLOR=0: brew reads HOMEBREW_COLOR by
    // presence, so setting it to "0" forces colour on and fills the log drawer
    // with escape codes.
    vec![
        ("HOMEBREW_NO_AUTO_UPDATE".into(), "1".into()),
        ("HOMEBREW_NO_COLOR".into(), "1".into()),
    ]
}

/// (program, args, extra env) for one package-manager action.
pub fn job_command(action: &str, app: &App, repo: &Path, _resources: &Path) -> Result<Cmd, String> {
    match app.kind.as_str() {
        "cask" | "formula" => {
            let verb = match action {
                "install" => "install",
                "uninstall" => "uninstall",
                "update" => "upgrade",
                "reinstall" => "reinstall",
                other => return Err(format!("unknown action {other}")),
            };
            let mut args = vec![verb.to_string()];
            if app.kind == "cask" {
                args.push("--cask".into());
            }
            args.push(app.token.clone());
            Ok(Cmd { program: "brew".into(), args, env: brew_env() })
        }
        // Installing over an installed App Store app is a no-op, so that one is
        // not offered; uninstall needs root and goes through the auth prompt.
        "mas" => {
            let verb = match action {
                "install" => "install",
                "update" => "upgrade",
                "uninstall" => return mas_uninstall(app),
                other => return Err(format!("cannot {other} an App Store app")),
            };
            // mas 7 spawns `sudo -n` itself to run the installer, which cannot
            // prompt. Running mas under our own sudo (askpass dialog) makes that
            // inner call free. sudo resets PATH, so mas needs its full path.
            let mas = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
                .into_iter()
                .find(|p| Path::new(p).exists())
                .ok_or("mas is not installed")?;
            Ok(Cmd {
                program: "sudo".into(),
                args: vec!["-A".into(), mas.into(), verb.to_string(), app.token.clone()],
                env: vec![],
            })
        }
        // The script takes the action verbatim and handles its own sudo -A.
        "installer" => match action {
            "install" | "update" | "reinstall" | "configure" | "uninstall" => Ok(Cmd {
                program: installer_script(repo, &app.token).to_string_lossy().to_string(),
                args: vec![action.to_string()],
                env: vec![],
            }),
            other => Err(format!("unknown action {other}")),
        },
        other => Err(format!("cannot {action} a {other} on macOS")),
    }
}

/// `lib/tasks.sh status|apply <section> [id] [--profile name]`. Runs with the
/// same inherited env as `installer_script`'s Cmd (SUDO_ASKPASS and the
/// Homebrew PATH prefix are set process-wide in `main()`, so the child gets
/// them for free without repeating them here).
pub fn task_command(
    verb: &str,
    section: &str,
    id: Option<&str>,
    repo: &Path,
    _resources: &Path,
    profile: Option<&str>,
) -> Result<Cmd, String> {
    let mut args = vec![verb.to_string(), section.to_string()];
    if let Some(id) = id {
        args.push(id.to_string());
    }
    if let Some(profile) = profile {
        args.push("--profile".into());
        args.push(profile.to_string());
    }
    Ok(Cmd {
        program: repo.join("lib/tasks.sh").to_string_lossy().to_string(),
        args,
        env: vec![],
    })
}

/// App Store apps carry a system restriction that even root cannot chown or
/// delete, so `mas uninstall` fails on them. Finder holds the entitlement to
/// trash them (and shows its own auth prompt when needed), so ask Finder.
fn mas_uninstall(app: &App) -> Result<Cmd, String> {
    if app.name.contains('/') {
        return Err(format!("refusing to build a path from name {:?}", app.name));
    }
    let path = app
        .target
        .clone()
        .unwrap_or_else(|| format!("/Applications/{}.app", app.name));
    // AppleScript string literal: only backslash and quote need escaping.
    let quoted = path.replace('\\', "\\\\").replace('"', "\\\"");
    Ok(Cmd {
        program: "osascript".into(),
        args: vec![
            "-e".into(),
            format!(r#"tell application "Finder" to delete POSIX file "{quoted}""#),
        ],
        env: vec![],
    })
}

fn run(cmd: &mut Command, what: &str) -> Result<(), String> {
    cmd.status()
        .map_err(|e| e.to_string())?
        .success()
        .then_some(())
        .ok_or_else(|| format!("{what} failed"))
}

pub fn reveal(app: &App, _resources: &Path) -> Result<(), String> {
    let target = app.target.as_deref().ok_or("no path known for this entry")?;
    run(Command::new("open").arg("-R").arg(target), "open -R")
}

pub fn open_url(url: &str, _resources: &Path) -> Result<(), String> {
    run(Command::new("open").arg(url), "open")
}

#[cfg(test)]
mod tests {
    use super::{artwork_urls, github_slug};
    use serde_json::json;

    #[test]
    fn artwork_urls_keys_by_track_id() {
        let lookup = json!({"results": [
            {"trackId": 585829637, "artworkUrl512": "https://x.mzstatic.com/a.png"},
            {"trackId": 1, "artworkUrl100": "https://x.mzstatic.com/small.png"},
        ]});
        let urls = artwork_urls(&lookup);
        assert_eq!(urls.get("585829637"), Some(&json!("https://x.mzstatic.com/a.png")));
        assert_eq!(urls.len(), 1);
        assert!(artwork_urls(&json!({})).is_empty());
    }

    #[test]
    fn slug_from_homepage_or_url() {
        let slug = |v| github_slug(&v);
        assert_eq!(
            slug(json!({"homepage": "https://github.com/owner/repo"})),
            Some("owner/repo".into())
        );
        assert_eq!(
            slug(json!({"homepage": "https://example.com/",
                        "url": "https://github.com/o/r.git#tag=v1"})),
            Some("o/r".into())
        );
        assert_eq!(
            slug(json!({"url": "https://github.com/o/r/releases/download/v1/x.dmg"})),
            Some("o/r".into())
        );
        assert_eq!(slug(json!({"homepage": "https://github.com/owner"})), None);
        assert_eq!(slug(json!({"homepage": "https://gitlab.com/o/r"})), None);
    }
}
