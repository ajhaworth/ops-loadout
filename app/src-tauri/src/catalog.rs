//! Repo discovery and package-list parsing.
//!
//! Mirrors `lib/packages.sh:parse_package_list` (full-line and trailing `#`
//! comments, trimmed, blanks skipped) plus the pipe-delimited formats used by
//! the mas / windows-github / windows-comfynodes lists.

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct App {
    pub id: String,
    pub name: String,
    pub category: String,
    /// "cask" | "formula" | "mas" | "github" | "comfynode" | "installer"
    pub kind: String,
    pub installed: bool,
    /// An installed app with a newer version available.
    pub outdated: bool,
    pub homepage: Option<String>,
    /// data URL
    pub icon: Option<String>,
    pub launchable: bool,

    /// Raw list entry / cask token / formula name / mas id. Backend only.
    #[serde(skip)]
    pub token: String,
    /// macOS: "Ghostty.app". Windows: the resolved exe path. Backend only.
    #[serde(skip)]
    pub target: Option<String>,
}

impl App {
    fn new(kind: &str, token: &str, name: &str, category: &str) -> Self {
        App {
            id: format!("{kind}:{token}"),
            name: name.to_string(),
            category: category.to_string(),
            kind: kind.to_string(),
            installed: false,
            outdated: false,
            homepage: None,
            icon: None,
            launchable: false,
            token: token.to_string(),
            target: None,
        }
    }
}

/// Strip comments and whitespace; keep the surviving entries in file order.
pub fn parse_list(text: &str) -> Vec<String> {
    text.lines()
        .map(|line| line.split('#').next().unwrap_or("").trim())
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

fn field(line: &str, idx: usize) -> Option<String> {
    line.split('|')
        .nth(idx)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// `software-dev` -> `Software Dev`
fn title_case(stem: &str) -> String {
    stem.split(['-', '_'])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Every `*.txt` in `dir`, sorted by filename, as (category, entries).
fn read_dir_lists(dir: &Path) -> Vec<(String, Vec<String>)> {
    let mut files: Vec<PathBuf> = match fs::read_dir(dir) {
        Ok(rd) => rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "txt"))
            .collect(),
        Err(_) => return Vec::new(),
    };
    files.sort();

    files
        .iter()
        .filter_map(|p| {
            let stem = p.file_stem()?.to_string_lossy().to_string();
            let text = fs::read_to_string(p).ok()?;
            Some((stem, parse_list(&text)))
        })
        .collect()
}

fn casks(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/macos/casks"))
        .into_iter()
        .flat_map(|(stem, entries)| {
            let category = title_case(&stem);
            entries
                .into_iter()
                .map(move |token| App::new("cask", &token, &token, &category))
        })
        .collect()
}

fn formulae(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/macos/formulae"))
        .into_iter()
        .flat_map(|(stem, entries)| {
            let category = title_case(&stem);
            entries
                .into_iter()
                .map(move |name| App::new("formula", &name, &name, &category))
        })
        .collect()
}

fn mas(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/macos/mas"))
        .into_iter()
        .flat_map(|(_, entries)| entries)
        .filter_map(|line| {
            // ID|Name
            let id = field(&line, 0)?;
            if !id.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            let name = field(&line, 1).unwrap_or_else(|| id.clone());
            Some(App::new("mas", &id, &name, "App Store"))
        })
        .collect()
}

fn github(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/windows/github"))
        .into_iter()
        .flat_map(|(stem, entries)| {
            let category = title_case(&stem);
            entries.into_iter().filter_map(move |line| {
                // owner/repo | asset-pattern | display-name | install-args
                let repo_slug = field(&line, 0)?;
                let default_name = repo_slug.split('/').nth(1)?.to_string();
                let name = field(&line, 2).unwrap_or(default_name);
                let mut app = App::new("github", &repo_slug, &name, &category);
                app.token = line.clone(); // the installer wants the whole spec
                app.id = format!("github:{repo_slug}");
                app.homepage = Some(format!("https://github.com/{repo_slug}"));
                Some(app)
            })
        })
        .collect()
}

fn installers(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/macos/installers"))
        .into_iter()
        .flat_map(|(stem, entries)| {
            let category = title_case(&stem);
            entries.into_iter().filter_map(move |line| {
                // token | display-name | homepage
                let token = field(&line, 0)?;
                let name = field(&line, 1).unwrap_or_else(|| token.clone());
                let mut app = App::new("installer", &token, &name, &category);
                app.homepage = field(&line, 2);
                Some(app)
            })
        })
        .collect()
}

fn comfynodes(repo: &Path) -> Vec<App> {
    read_dir_lists(&repo.join("config/packages/windows/comfynodes"))
        .into_iter()
        .flat_map(|(_, entries)| entries)
        .filter_map(|line| {
            // owner/repo | directory-name
            let repo_slug = field(&line, 0)?;
            let default_dir = repo_slug.split('/').nth(1)?.to_string();
            let dir = field(&line, 1).unwrap_or(default_dir);
            let mut app = App::new("comfynode", &repo_slug, &dir, "ComfyUI Nodes");
            app.token = line.clone();
            app.id = format!("comfynode:{repo_slug}");
            app.homepage = Some(format!("https://github.com/{repo_slug}"));
            Some(app)
        })
        .collect()
}

/// Every app this repo manages for the current platform, before the platform
/// backend fills in installed state, homepage and icons.
///
/// Profile flags are ignored on purpose: the launcher shows every list file.
// ponytail: no profile filtering; add it if the work/personal split ever
// matters here.
pub fn scan(repo: &Path) -> Vec<App> {
    if cfg!(target_os = "windows") {
        let mut apps = github(repo);
        apps.extend(comfynodes(repo));
        apps
    } else {
        let mut apps = casks(repo);
        apps.extend(installers(repo));
        apps.extend(mas(repo));
        apps.extend(formulae(repo));
        apps
    }
}

pub fn is_repo(path: &Path) -> bool {
    path.join("config/packages").is_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_four_line_shapes() {
        let text = "\
# a full-line comment
\n   \n
ghostty
ripgrep   # trailing comment
497799835|Xcode
Nonary/Vibepollo | VibepolloSetup-*.exe | Vibepollo | /quiet
willmiao/ComfyUI-Lora-Manager
houdini | Houdini | https://www.sidefx.com/
#still a comment
";
        let lines = parse_list(text);
        assert_eq!(
            lines,
            vec![
                "ghostty",
                "ripgrep",
                "497799835|Xcode",
                "Nonary/Vibepollo | VibepolloSetup-*.exe | Vibepollo | /quiet",
                "willmiao/ComfyUI-Lora-Manager",
                "houdini | Houdini | https://www.sidefx.com/",
            ]
        );

        // bare name
        assert_eq!(field(&lines[0], 0).as_deref(), Some("ghostty"));
        assert_eq!(field(&lines[0], 1), None);
        // mas: ID|Name
        assert_eq!(field(&lines[2], 0).as_deref(), Some("497799835"));
        assert_eq!(field(&lines[2], 1).as_deref(), Some("Xcode"));
        // github: owner/repo | pattern | display | args
        assert_eq!(field(&lines[3], 2).as_deref(), Some("Vibepollo"));
        assert_eq!(field(&lines[3], 3).as_deref(), Some("/quiet"));
        // comfynode: directory defaults to the repo name
        assert_eq!(field(&lines[4], 1), None);
        // installer: token | display-name | homepage
        assert_eq!(field(&lines[5], 0).as_deref(), Some("houdini"));
        assert_eq!(field(&lines[5], 1).as_deref(), Some("Houdini"));
        assert_eq!(field(&lines[5], 2).as_deref(), Some("https://www.sidefx.com/"));

        assert_eq!(title_case("software-dev"), "Software Dev");
        assert_eq!(title_case("core"), "Core");
    }
}
