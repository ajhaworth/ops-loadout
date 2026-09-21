//! Platform backends. Each provides status/icon hydration, launch, and the
//! command used to install one app; `main.rs` does the streaming.

pub struct Cmd {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::{hydrate, job_command, launch, open_url, refresh_icon, reveal};

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
pub use windows::{hydrate, job_command, launch, open_url, refresh_icon, reveal};

// Linux is not a target of this launcher (no apt support in the plan), but the
// crate should still build there.
// ponytail: stub backend; add an apt/flatpak backend when Linux is asked for.
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod stub {
    use crate::catalog::App;
    use crate::platform::Cmd;
    use std::path::Path;

    pub fn hydrate(_apps: &mut [App], _cache_dir: &Path, _repo: &Path, _resources: &Path) {}
    pub fn refresh_icon(_app: &mut App, _cache_dir: &Path, _repo: &Path, _resources: &Path) {}
    pub fn launch(_app: &App, _resources: &Path) -> Result<(), String> {
        Err("unsupported platform".into())
    }
    pub fn job_command(
        _action: &str,
        _app: &App,
        _repo: &Path,
        _resources: &Path,
    ) -> Result<Cmd, String> {
        Err("unsupported platform".into())
    }
    pub fn reveal(_app: &App, _resources: &Path) -> Result<(), String> {
        Err("unsupported platform".into())
    }
    pub fn open_url(_url: &str, _resources: &Path) -> Result<(), String> {
        Err("unsupported platform".into())
    }
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub use stub::{hydrate, job_command, launch, open_url, refresh_icon, reveal};
