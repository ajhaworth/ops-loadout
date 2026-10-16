//! Windows backend: everything goes through `bridge.ps1`, which imports the
//! repo's own `lib/windows/*.psm1` so status and install logic stay in one place.

use crate::catalog::App;
use crate::platform::{cache_name, command, Cmd};
use base64::Engine;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

/// pwsh when it is on PATH, else Windows PowerShell. Probing means starting a
/// pwsh, so a hit is remembered; a miss is not, so a pwsh installed from the
/// Prerequisites row is picked up without a restart.
fn shell() -> &'static str {
    static PWSH: AtomicBool = AtomicBool::new(false);
    if PWSH.load(Ordering::Relaxed) {
        return "pwsh";
    }
    if command("pwsh").arg("-Version").output().is_ok() {
        PWSH.store(true, Ordering::Relaxed);
        "pwsh"
    } else {
        "powershell.exe"
    }
}

fn bridge(resources: &Path) -> PathBuf {
    let bundled = resources.join("bridge.ps1");
    if bundled.is_file() {
        return bundled;
    }
    // `tauri dev` has no resource dir yet.
    Path::new(env!("CARGO_MANIFEST_DIR")).join("bridge.ps1")
}

fn base_args(resources: &Path) -> Vec<String> {
    vec![
        "-NoProfile".into(),
        "-NonInteractive".into(),
        // Windows PowerShell's default policy on client Windows is Restricted,
        // and RemoteSigned refuses a checkout carrying Mark of the Web; either
        // would fail every call. -File only, so the repo's scripts it imports
        // run under the same process policy.
        "-ExecutionPolicy".into(),
        "Bypass".into(),
        "-File".into(),
        bridge(resources).to_string_lossy().to_string(),
    ]
}

fn icon(exe: &str, id: &str, cache_dir: &Path, repo: &Path, resources: &Path) -> Option<String> {
    // Its own dir so the 32px icons cached before 256px extraction go unused.
    let dir = cache_dir.join("icons-256");
    let png = dir.join(cache_name(id));
    // `<id>.failed` holds a target whose extraction failed, so a
    // scan does not spend a pwsh start on it again. Keyed by target: a new
    // exe path (an update moved it) gets a fresh try.
    let failed = dir.join(format!("{}.failed", cache_name(id)));
    if std::fs::read_to_string(&failed).is_ok_and(|t| t == exe) {
        return None;
    }

    if !png.is_file() {
        std::fs::create_dir_all(&dir).ok()?;
        let mut args = base_args(resources);
        args.push("icon".into());
        args.push(exe.to_string());
        args.push(png.to_string_lossy().to_string());
        // A packaged app's target is an AppsFolder path; the bridge reads its
        // manifest through the repo's packages.psm1 to find an exe to extract.
        args.push(repo.to_string_lossy().to_string());
        let ok = command(shell())
            .args(&args)
            .output()
            .ok()
            .is_some_and(|o| o.status.success());
        if !ok {
            let _ = std::fs::write(&failed, exe);
            return None;
        }
    }

    let bytes = std::fs::read(&png).ok()?;
    Some(format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    ))
}

pub fn hydrate(apps: &mut [App], cache_dir: &Path, repo: &Path, resources: &Path) {
    hydrate_only(apps, None, cache_dir, repo, resources);
}

/// `only` limits the bridge's status to one catalog id, which skips `winget
/// list` and the GitHub API for every other app.
fn hydrate_only(apps: &mut [App], only: Option<&str>, cache_dir: &Path, repo: &Path, resources: &Path) {
    let mut args = base_args(resources);
    args.push("status".into());
    args.push(repo.to_string_lossy().to_string());
    args.extend(only.map(str::to_string));

    let out = match command(shell()).args(&args).output() {
        Ok(o) if o.status.success() => o.stdout,
        Ok(o) => {
            eprintln!("bridge status failed: {}", String::from_utf8_lossy(&o.stderr).trim());
            return;
        }
        Err(e) => {
            eprintln!("bridge status: {e}");
            return;
        }
    };
    let rows: Vec<Value> = match serde_json::from_slice(&out) {
        Ok(rows) => rows,
        Err(e) => {
            let text: String = String::from_utf8_lossy(&out).chars().take(300).collect();
            eprintln!("bridge status is not JSON ({e}): {text}");
            return;
        }
    };

    for app in apps.iter_mut() {
        let Some(row) = rows
            .iter()
            .find(|r| r.get("id").and_then(Value::as_str) == Some(app.id.as_str()))
        else {
            continue;
        };
        app.installed = row
            .get("installed")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        app.outdated = app.installed
            && row
                .get("outdated")
                .and_then(Value::as_bool)
                .unwrap_or(false);

        let exe = row.get("exe").and_then(Value::as_str).unwrap_or("");
        if app.installed && !exe.is_empty() {
            app.launchable = true;
            app.target = Some(exe.to_string());
            app.icon = icon(exe, &app.id, cache_dir, repo, resources);
        }
    }
}

pub fn refresh_icon(app: &mut App, cache_dir: &Path, repo: &Path, resources: &Path) {
    let mut one = [app.clone()];
    hydrate_only(&mut one, Some(app.id.as_str()), cache_dir, repo, resources);
    *app = one.into_iter().next().unwrap();
}

/// `background` is macOS-only (`open -g`); Windows always brings the app forward.
pub fn launch(app: &App, resources: &Path, _background: bool) -> Result<(), String> {
    let exe = app.target.as_deref().ok_or("no executable for this entry")?;
    let mut args = base_args(resources);
    args.push("launch".into());
    args.push(exe.to_string());

    command(shell())
        .args(&args)
        .status()
        .map_err(|e| e.to_string())?
        .success()
        .then_some(())
        .ok_or_else(|| format!("Start-Process {exe} failed"))
}

/// No installer script offers multiple builds on Windows.
pub fn launch_targets(_app: &App, _repo: &Path, _resources: &Path) -> Vec<String> {
    Vec::new()
}

/// Nor build channels.
pub fn channels(_app: &App, _repo: &Path, _resources: &Path) -> Vec<String> {
    Vec::new()
}

pub fn job_command(action: &str, app: &App, repo: &Path, resources: &Path) -> Result<Cmd, String> {
    // The bridge maps reinstall per kind: installer scripts take it as is,
    // winget runs install --force, a GitHub release reinstalls with -Force.
    let verb = match action {
        "install" | "uninstall" | "update" | "reinstall" | "configure" => action,
        other => return Err(format!("unknown action {other}")),
    };
    bridge_job(verb, app, repo, resources)
}

pub fn reveal(app: &App, _resources: &Path) -> Result<(), String> {
    let exe = app.target.as_deref().ok_or("no path known for this entry")?;
    // explorer returns a non-zero code even when it succeeds, so only the
    // spawn is checked.
    Command::new("explorer")
        .arg(format!("/select,{exe}"))
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

pub fn open_url(url: &str, resources: &Path) -> Result<(), String> {
    let mut args = base_args(resources);
    args.push("open".into());
    args.push(url.to_string());

    command(shell())
        .args(&args)
        .status()
        .map_err(|e| e.to_string())?
        .success()
        .then_some(())
        .ok_or_else(|| format!("could not open {url}"))
}

/// Reloads PATH from the registry into this process, so a tool installed
/// since Loadout started (git or pwsh from the Prerequisites rows) is found
/// by what Loadout runs itself - `git pull`, the pwsh probe - without a
/// restart. The bridge does the same for its own children.
pub fn refresh_path() {
    let script = "[Environment]::GetEnvironmentVariable('Path','Machine') + ';' + \
                  [Environment]::GetEnvironmentVariable('Path','User')";
    let Ok(out) = command(shell()).args(["-NoProfile", "-NonInteractive", "-Command", script]).output() else {
        return;
    };
    let fresh = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || fresh.is_empty() {
        return;
    }
    let current = std::env::var("PATH").unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    let merged: Vec<&str> = fresh
        .split(';')
        .chain(current.split(';'))
        .filter(|p| !p.is_empty() && seen.insert(p.to_ascii_lowercase()))
        .collect();
    std::env::set_var("PATH", merged.join(";"));
}

/// `bridge.ps1 tasks-status <repo> <section> [profile]` /
/// `tasks-apply <repo> <section> <id> [profile]` - positional, so id is only
/// inserted when present and profile always comes last.
pub fn task_command(
    verb: &str,
    section: &str,
    id: Option<&str>,
    repo: &Path,
    resources: &Path,
    profile: Option<&str>,
) -> Result<Cmd, String> {
    let sub = match verb {
        "status" => "tasks-status",
        "apply" => "tasks-apply",
        other => return Err(format!("unknown verb {other}")),
    };
    let mut args = base_args(resources);
    args.push(sub.into());
    args.push(repo.to_string_lossy().to_string());
    args.push(section.to_string());
    if let Some(id) = id {
        args.push(id.to_string());
    }
    if let Some(profile) = profile {
        args.push(profile.to_string());
    }
    Ok(Cmd { program: shell().to_string(), args, env: vec![] })
}

fn bridge_job(verb: &str, app: &App, repo: &Path, resources: &Path) -> Result<Cmd, String> {
    let kind = match app.kind.as_str() {
        "installer" | "winget" | "github" => app.kind.clone(),
        other => return Err(format!("cannot {verb} a {other} on Windows")),
    };
    let mut args = base_args(resources);
    args.push(verb.into());
    args.push(repo.to_string_lossy().to_string());
    args.push(kind);
    args.push(app.token.clone());

    Ok(Cmd {
        program: shell().to_string(),
        args,
        env: vec![],
    })
}
