// loadout-wm: the normal windows of apps listed in ~/.loadout-wm.txt fill their screen, inset by a padding; every
// other window is never touched, so it floats as usual. There are no virtual workspaces: an app is its own
// workspace, reached by switching to it (Dock, Cmd-Tab, taskbar), which brings its filled windows to the front.
// This file is the platform-neutral part (rules and layout math); macos.rs and windows.rs feed it windows.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::SystemTime;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Layout {
    /// Every normal window of the app fills the screen.
    Fill,
    /// Only the app's first normal window fills; later ones float.
    First,
    /// Equal-width columns, ordered by where the windows currently sit.
    Split,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    /// Lowercase; compared against the bundle id or app name (macOS) or the exe name without .exe (Windows).
    pub app: String,
    /// Lowercase substring of the window title; empty matches any.
    pub title: String,
    pub layout: Layout,
    pub padding: f64,
}

/// `app | title contains | layout | padding` per line; `#` starts a comment, trailing fields may be left out.
pub fn parse(text: &str) -> Vec<Rule> {
    text.lines()
        .filter_map(|line| {
            let line = line.split('#').next().unwrap_or("").trim();
            let f: Vec<&str> = line.split('|').map(str::trim).collect();
            let app = f[0].to_lowercase();
            if app.is_empty() {
                return None;
            }
            let field = |i: usize| f.get(i).copied().unwrap_or("");
            let layout = match field(2).to_lowercase().as_str() {
                "first" => Layout::First,
                "split" => Layout::Split,
                "fill" | "" => Layout::Fill,
                other => {
                    eprintln!("loadout-wm: unknown layout {other:?} for {app}, using fill");
                    Layout::Fill
                }
            };
            let padding = field(3).parse().unwrap_or_else(|_| {
                if !field(3).is_empty() {
                    eprintln!("loadout-wm: bad padding {:?} for {app}, using 8", field(3));
                }
                8.0
            });
            Some(Rule { app, title: field(1).to_lowercase(), layout, padding })
        })
        .collect()
}

/// Whether any rule names this app (`names`: every name it goes by, matched case-insensitively).
pub fn app_listed(rules: &[Rule], names: &[&str]) -> bool {
    rules.iter().any(|r| names.iter().any(|n| n.eq_ignore_ascii_case(&r.app)))
}

/// Index of the first rule matching this app and window title.
pub fn rule_for(rules: &[Rule], names: &[&str], title: &str) -> Option<usize> {
    let title = title.to_lowercase();
    rules
        .iter()
        .position(|r| names.iter().any(|n| n.eq_ignore_ascii_case(&r.app)) && title.contains(&r.title))
}

/// The rules file, linked from config/dotfiles/wm/rules.txt by the dotfiles stage.
pub fn rules_path() -> PathBuf {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
    PathBuf::from(home).join(".loadout-wm.txt")
}

/// Rereads the rules when the file's mtime changed since the last call, so edits apply on the next window event.
#[derive(Default)]
pub struct Rules {
    pub list: Vec<Rule>,
    mtime: Option<SystemTime>,
}

impl Rules {
    /// The padding for windows no rule covers (snapped ones): the first rule's, or the default 8.
    pub fn padding(&self) -> f64 {
        self.list.first().map_or(8.0, |r| r.padding)
    }

    /// True when the rules changed.
    pub fn reload(&mut self) -> bool {
        let path = rules_path();
        let mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if mtime == self.mtime {
            return false;
        }
        self.mtime = mtime;
        self.list = std::fs::read_to_string(&path).map(|t| parse(&t)).unwrap_or_default();
        eprintln!("loadout-wm: {} rules from {}", self.list.len(), path.display());
        true
    }
}

/// Top-left origin, y down, on both platforms.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }
}

pub struct Screen {
    /// The usable area: no menu bar or Dock (macOS), no taskbar (Windows).
    pub area: Rect,
    /// Multiplies the padding: 1 for macOS points, DPI / 96 for Windows pixels.
    pub scale: f64,
}

/// The screen holding the window's center, or the first screen when it sits off every screen.
pub fn screen_of(frame: Rect, screens: &[Screen]) -> usize {
    let (cx, cy) = (frame.x + frame.w / 2.0, frame.y + frame.h / 2.0);
    screens.iter().position(|s| s.area.contains(cx, cy)).unwrap_or(0)
}

/// `n` equal columns across `area`, `pad` around and between them.
pub fn columns(area: Rect, pad: f64, n: usize) -> Vec<Rect> {
    let w = (area.w - pad * (n as f64 + 1.0)) / n as f64;
    (0..n)
        .map(|i| Rect {
            x: (area.x + pad + i as f64 * (w + pad)).round(),
            y: (area.y + pad).round(),
            w: w.round(),
            h: (area.h - 2.0 * pad).round(),
        })
        .collect()
}

/// For a window snapped flush to screen fractions (Swish's halves, thirds and quarters, which leave no gaps), the
/// same frame with the padding added: `pad` at the screen's edges, half of it on each side of an inner edge, so
/// two snapped windows end up `pad` apart, lined up with filled ones. None when any edge is off the grid.
pub fn gapped(frame: Rect, area: Rect, pad: f64) -> Option<Rect> {
    const FRACTIONS: [f64; 7] = [0.0, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1.0];
    // Each edge as its fraction of the area, or None off the grid (2 px of slack for rounding).
    let snap = |pos: f64, origin: f64, len: f64| {
        FRACTIONS.iter().copied().find(|f| (pos - (origin + f * len)).abs() <= 2.0)
    };
    let inset = |f: f64| if f == 0.0 || f == 1.0 { pad } else { pad / 2.0 };
    let l = snap(frame.x, area.x, area.w)?;
    let r = snap(frame.x + frame.w, area.x, area.w)?;
    let t = snap(frame.y, area.y, area.h)?;
    let b = snap(frame.y + frame.h, area.y, area.h)?;
    if l >= r || t >= b {
        return None;
    }
    let x = area.x + l * area.w + inset(l);
    let y = area.y + t * area.h + inset(t);
    Some(Rect {
        x: x.round(),
        y: y.round(),
        w: (area.x + r * area.w - inset(r) - x).round(),
        h: (area.y + b * area.h - inset(b) - y).round(),
    })
}

/// Logs to stderr when LOADOUT_WM_DEBUG is set.
pub fn debug(msg: impl FnOnce() -> String) {
    if std::env::var_os("LOADOUT_WM_DEBUG").is_some() {
        eprintln!("loadout-wm: {}", msg());
    }
}

/// A normal window of a listed app, as the platform sees it.
pub struct Win<W> {
    pub id: W,
    pub rule: usize,
    pub frame: Rect,
}

/// Where each window should go. `first` remembers each `first` rule's window across calls.
pub fn plan<W: Clone + PartialEq>(
    rules: &[Rule],
    wins: &[Win<W>],
    screens: &[Screen],
    first: &mut HashMap<usize, W>,
) -> Vec<(W, Rect)> {
    let mut out = Vec::new();
    if screens.is_empty() {
        return out;
    }
    for (ri, rule) in rules.iter().enumerate() {
        let mine: Vec<&Win<W>> = wins.iter().filter(|w| w.rule == ri).collect();
        let Some(front) = mine.first() else { continue };
        let fill = |w: &Win<W>| {
            let s = &screens[screen_of(w.frame, screens)];
            (w.id.clone(), columns(s.area, rule.padding * s.scale, 1)[0])
        };
        match rule.layout {
            Layout::Fill => out.extend(mine.iter().map(|w| fill(w))),
            Layout::First => {
                // Keep the remembered window while it is still open; otherwise the frontmost one takes over.
                let keep = mine
                    .iter()
                    .find(|w| first.get(&ri) == Some(&w.id))
                    .unwrap_or(front);
                first.insert(ri, keep.id.clone());
                out.push(fill(keep));
            }
            Layout::Split => {
                for (si, s) in screens.iter().enumerate() {
                    let mut here: Vec<&&Win<W>> =
                        mine.iter().filter(|w| screen_of(w.frame, screens) == si).collect();
                    here.sort_by(|a, b| a.frame.x.total_cmp(&b.frame.x));
                    let cols = columns(s.area, rule.padding * s.scale, here.len());
                    out.extend(here.iter().zip(cols).map(|(w, r)| (w.id.clone(), r)));
                }
            }
        }
    }
    out
}

fn main() {
    #[cfg(target_os = "macos")]
    macos::run();
    #[cfg(windows)]
    windows::run();
    #[cfg(not(any(target_os = "macos", windows)))]
    eprintln!("loadout-wm runs on macOS and Windows only");
}

#[cfg(test)]
mod tests {
    use super::*;

    const AREA: Rect = Rect { x: 0.0, y: 30.0, w: 1000.0, h: 600.0 };

    fn screens() -> Vec<Screen> {
        vec![Screen { area: AREA, scale: 1.0 }, Screen { area: Rect { x: 1000.0, ..AREA }, scale: 2.0 }]
    }

    fn win(id: u32, rule: usize, x: f64) -> Win<u32> {
        Win { id, rule, frame: Rect { x, y: 100.0, w: 200.0, h: 200.0 } }
    }

    #[test]
    fn parses_fields_defaults_and_comments() {
        let rules = parse(
            "# comment\n\n Org.Blender | - Blender | fill # trailing\nmail||first\nghostty | | split | 12\nx | | bogus | wide\n",
        );
        assert_eq!(rules.len(), 4);
        assert_eq!(rules[0], Rule { app: "org.blender".into(), title: "- blender".into(), layout: Layout::Fill, padding: 8.0 });
        assert_eq!(rules[1].layout, Layout::First);
        assert_eq!((rules[2].layout, rules[2].padding), (Layout::Split, 12.0));
        assert_eq!((rules[3].layout, rules[3].padding), (Layout::Fill, 8.0));
    }

    #[test]
    fn matches_any_name_and_title_substring() {
        let rules = parse("org.blender | - Blender\nmail\n");
        assert_eq!(rule_for(&rules, &["org.blender", "Blender"], "a.blend - Blender 5.0"), Some(0));
        assert_eq!(rule_for(&rules, &["org.blender", "Blender"], "Blender Preferences"), None);
        assert_eq!(rule_for(&rules, &["com.apple.mail", "Mail"], "Inbox"), Some(1));
        assert!(app_listed(&rules, &["x", "MAIL"]));
        assert!(!app_listed(&rules, &["finder"]));
    }

    #[test]
    fn fill_insets_by_scaled_padding_on_the_window_screen() {
        let rules = parse("a\n");
        let got = plan(&rules, &[win(1, 0, 10.0), win(2, 0, 1100.0)], &screens(), &mut HashMap::new());
        assert_eq!(got[0], (1, Rect { x: 8.0, y: 38.0, w: 984.0, h: 584.0 }));
        assert_eq!(got[1], (2, Rect { x: 1016.0, y: 46.0, w: 968.0, h: 568.0 }));
    }

    #[test]
    fn first_keeps_its_window_until_it_closes() {
        let rules = parse("a | | first\n");
        let mut first = HashMap::new();
        assert_eq!(plan(&rules, &[win(1, 0, 0.0)], &screens(), &mut first)[0].0, 1);
        let got = plan(&rules, &[win(2, 0, 0.0), win(1, 0, 0.0)], &screens(), &mut first);
        assert_eq!(got.iter().map(|g| g.0).collect::<Vec<_>>(), [1]);
        assert_eq!(plan(&rules, &[win(2, 0, 0.0)], &screens(), &mut first)[0].0, 2);
    }

    #[test]
    fn split_orders_by_x_with_padding_between() {
        let rules = parse("a | | split | 10\n");
        let got = plan(&rules, &[win(1, 0, 500.0), win(2, 0, 0.0), win(3, 0, 300.0)], &screens(), &mut HashMap::new());
        assert_eq!(got.iter().map(|g| g.0).collect::<Vec<_>>(), [2, 3, 1]);
        let w: f64 = (1000.0 - 40.0) / 3.0;
        assert_eq!(got[0].1, Rect { x: 10.0, y: 40.0, w: w.round(), h: 580.0 });
        assert_eq!(got[1].1.x, (20.0 + w).round());
        assert_eq!(got[2].1.x + got[2].1.w, 990.0);
        assert_eq!(columns(AREA, 10.0, 1)[0], Rect { x: 10.0, y: 40.0, w: 980.0, h: 580.0 });
    }

    #[test]
    fn snapped_windows_get_the_padding_and_others_are_left_alone() {
        let area = Rect { x: 0.0, y: 33.0, w: 1512.0, h: 949.0 };
        let left = gapped(Rect { x: 0.0, y: 33.0, w: 756.0, h: 949.0 }, area, 8.0).unwrap();
        let right = gapped(Rect { x: 756.0, y: 33.0, w: 756.0, h: 949.0 }, area, 8.0).unwrap();
        assert_eq!(left, Rect { x: 8.0, y: 41.0, w: 744.0, h: 933.0 });
        assert_eq!(right.x - (left.x + left.w), 8.0);
        assert_eq!(right.x + right.w, 1504.0);
        // A maximized window lines up with a filled one.
        assert_eq!(gapped(area, area, 8.0), Some(columns(area, 8.0, 1)[0]));
        // A top-right quarter.
        let q = gapped(Rect { x: 1134.0, y: 33.0, w: 378.0, h: 474.5 }, area, 8.0).unwrap();
        assert_eq!((q.x, q.y, q.x + q.w), (1138.0, 41.0, 1504.0));
        // Already gapped, or placed by hand: untouched.
        assert_eq!(gapped(left, area, 8.0), None);
        assert_eq!(gapped(Rect { x: 117.0, y: 130.0, w: 756.0, h: 949.0 }, area, 8.0), None);
    }

    #[test]
    fn windows_off_every_screen_use_the_first() {
        assert_eq!(screen_of(Rect { x: -5000.0, y: 0.0, w: 10.0, h: 10.0 }, &screens()), 0);
        assert_eq!(screen_of(Rect { x: 1400.0, y: 200.0, w: 10.0, h: 10.0 }, &screens()), 1);
    }
}
