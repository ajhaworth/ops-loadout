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
pub fn refresh_icon(app: &mut App, cache_dir: &Path, _repo: &Path, _resources: &Path) {
    let bundle = match app.kind.as_str() {
        "cask" => app.target.as_deref().and_then(bundle_path),
        "mas" => mas_bundle_path(&app.name, &app.token),
        _ => None,
    };
    if let Some(bundle) = bundle {
        app.launchable = true;
        app.target = Some(bundle.to_string_lossy().to_string());
        app.icon = icon(&bundle, &app.id, cache_dir);
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

pub fn hydrate(apps: &mut [App], cache_dir: &Path, _repo: &Path, _resources: &Path) {
    let tokens = |kind: &str| -> Vec<String> {
        apps.iter()
            .filter(|a| a.kind == kind)
            .map(|a| a.token.clone())
            .collect()
    };

    // Casks: `installed` is the version string, null when absent.
    let cask_info = brew_info("--cask", &tokens("cask"));
    let installed_casks: Vec<String> = if cask_info.is_none() {
        lines_of("brew", &["list", "--cask", "-1"])
    } else {
        Vec::new()
    };

    // Formulae: `installed` is an array of installed kegs.
    let formula_info = brew_info("--formula", &tokens("formula"));
    let installed_formulae: Vec<String> = if formula_info.is_none() {
        lines_of("brew", &["list", "--formula", "-1"])
    } else {
        Vec::new()
    };

    // `mas list` is "<id>  <name>  (<version>)".
    let installed_mas: Vec<String> = lines_of("mas", &["list"])
        .iter()
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .collect();

    let (outdated_casks, outdated_formulae) = brew_outdated();
    // `mas outdated` is "<id>  <name>  (<old> -> <new>)".
    let outdated_mas: Vec<String> = lines_of("mas", &["outdated"])
        .iter()
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .collect();

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
                        app.launchable = true;
                        app.icon = icon(&bundle, &app.id, cache_dir);
                        app.target = Some(bundle.to_string_lossy().to_string());
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
                        app.launchable = true;
                        app.icon = icon(&bundle, &app.id, cache_dir);
                        app.target = Some(bundle.to_string_lossy().to_string());
                    }
                }
            }
            _ => {}
        }
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
pub fn job_command(action: &str, app: &App, _repo: &Path, _resources: &Path) -> Result<Cmd, String> {
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
        other => Err(format!("cannot {action} a {other} on macOS")),
    }
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
