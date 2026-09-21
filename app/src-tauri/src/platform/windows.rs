//! Windows backend: everything goes through `bridge.ps1`, which imports the
//! repo's own `lib/windows/*.psm1` so status and install logic stay in one place.

use crate::catalog::App;
use crate::platform::Cmd;
use base64::Engine;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

fn shell() -> &'static str {
    if Command::new("pwsh").arg("-Version").output().is_ok() {
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
        "-File".into(),
        bridge(resources).to_string_lossy().to_string(),
    ]
}

fn cache_name(id: &str) -> String {
    format!("{}.png", id.replace(['/', ':', ' '], "_"))
}

fn icon(exe: &str, id: &str, cache_dir: &Path, resources: &Path) -> Option<String> {
    let png = cache_dir.join(cache_name(id));

    if !png.is_file() {
        std::fs::create_dir_all(cache_dir).ok()?;
        let mut args = base_args(resources);
        args.push("icon".into());
        args.push(exe.to_string());
        args.push(png.to_string_lossy().to_string());
        let ok = Command::new(shell())
            .args(&args)
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

pub fn hydrate(apps: &mut [App], cache_dir: &Path, repo: &Path, resources: &Path) {
    let mut args = base_args(resources);
    args.push("status".into());
    args.push(repo.to_string_lossy().to_string());

    let out = match Command::new(shell()).args(&args).output() {
        Ok(o) if o.status.success() => o.stdout,
        _ => return,
    };
    let rows: Vec<Value> = serde_json::from_slice(&out).unwrap_or_default();

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
            app.icon = icon(exe, &app.id, cache_dir, resources);
        }
    }
}

pub fn refresh_icon(app: &mut App, cache_dir: &Path, repo: &Path, resources: &Path) {
    let mut one = [app.clone()];
    hydrate(&mut one, cache_dir, repo, resources);
    *app = one.into_iter().next().unwrap();
}

pub fn launch(app: &App, resources: &Path) -> Result<(), String> {
    let exe = app.target.as_deref().ok_or("no executable for this entry")?;
    let mut args = base_args(resources);
    args.push("launch".into());
    args.push(exe.to_string());

    Command::new(shell())
        .args(&args)
        .status()
        .map_err(|e| e.to_string())?
        .success()
        .then_some(())
        .ok_or_else(|| format!("Start-Process {exe} failed"))
}

pub fn job_command(action: &str, app: &App, repo: &Path, resources: &Path) -> Result<Cmd, String> {
    // The repo's own upgrade path is a -Force reinstall, so both map to it.
    let verb = match action {
        "install" => "install",
        "uninstall" => "uninstall",
        "update" | "reinstall" => "update",
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

    Command::new(shell())
        .args(&args)
        .status()
        .map_err(|e| e.to_string())?
        .success()
        .then_some(())
        .ok_or_else(|| format!("could not open {url}"))
}

fn bridge_job(verb: &str, app: &App, repo: &Path, resources: &Path) -> Result<Cmd, String> {
    let kind = match app.kind.as_str() {
        "github" | "comfynode" => app.kind.clone(),
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
