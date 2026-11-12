---
paths:
  - "lib/tasks.sh"
  - "lib/dotfiles.sh"
  - "app/src-tauri/**"
  - "app/ui/**"
  - "platforms/macos/defaults.sh"
  - "platforms/macos/defaults/**"
  - "platforms/windows/defaults.ps1"
  - "platforms/windows/defaults/**"
  - "platforms/windows/debloat.ps1"
  - "lib/windows/registry.psm1"
  - "config/wallpapers/**"
---

# Setup tasks, macOS defaults, wallpaper

Moved out of the root `CLAUDE.md`; loads when you touch the task verbs, the
defaults modules, the bridge or the app. Windows defaults and the registry
helpers are in `platforms/windows/CLAUDE.md`.

## Setup Tasks (Loadout)

Loadout's **Updates** tab (below outdated packages) drives the non-package stages: prerequisites,
dotfiles, system defaults and (Windows) debloat. Every section is fed by one
status verb per platform and applied by one apply verb:

```
lib/tasks.sh status <section> [--profile name]          # macOS
lib/tasks.sh apply  <section> <id> [--profile name]
bridge.ps1 tasks-status <repo> <section> [profile]      # Windows
bridge.ps1 tasks-apply  <repo> <section> <id> [profile]
```

Sections: `prereq`, `dotfiles`, `defaults`, `debloat` (Windows only), `cleanup`
(macOS only; manual - never counted as an update or run by Run all, and each
row confirms first. Old Houdini builds get a row only when they are neither
the newest, the pinned nor `Current`, so their ids cannot be applied).

The macOS dotfiles section also carries an "Accounts" group (`tasks_logins`):
CLI logins for `gh` (github.com) and `tea` (a self-hosted Gitea, whose URL is
asked for at login and kept only in tea's config), each shown only
while that CLI is installed. Loadout has no terminal, so the login functions in
`lib/dotfiles.sh` branch on `SUDO_ASKPASS`: `gh` runs the browser device flow
(`--web --clipboard`), and `tea`'s token comes from a hidden `osascript` dialog
and reaches `tea` as `GITEA_SERVER_TOKEN`, never argv. `setup.sh` keeps
`gh`'s interactive login and reuses `tea_login` with a terminal prompt.

A status verb prints exactly one JSON array on stdout and nothing else:

```json
[{"id":"defaults:finder:com.apple.finder/AppleShowAllFiles","section":"defaults",
  "group":"Finder","name":"Show hidden files","state":"pending","detail":"currently 0, want 1"}]
```

- `state` is one of `applied`, `pending`, `failed`, `needs_admin`, `unknown`.
- Items disabled by the profile are not emitted; profile filtering stays in
  the scripts, the app never re-implements it. No `--profile` means every
  flag defaults to enabled, as everywhere else in this repo.
- `id` is namespaced by section (`dotfiles:~/.zshrc`, `defaults:dock:com.apple.dock/tilesize`)
  so it cannot collide with package ids in the app.
- Apply verbs stream plain text and exit non-zero on failure, exactly like
  package installs, so the app reuses the same streaming and log drawer.
- **Status is the apply traversal with writes turned off.** There is one code
  path per item; the helper (`defaults_set` on macOS, `Set-RegistryValue` on
  Windows) branches on mode. Never add a separate checker that can drift.

## macOS Defaults

System preferences are set via `defaults write` commands in `platforms/macos/defaults/*.sh`. Each file defines an `apply_<name>()` function that is dynamically discovered and invoked.

Each `apply_<name>()` is built from two declarative helpers in `lib/tasks.sh`:
`defaults_set <domain> <key> <type> <value> <label>` compares the current
`defaults read` value against the desired one and writes only on a mismatch;
`defaults_hook <hook-id> <label> <check-cmd> <apply-cmd>` covers anything that
isn't a scalar `defaults write` (an `-array` write, a `chflags`, a `mkdir -p`).
Both branch on the same code path for status (writes off) and apply, per
"Setup Tasks (Loadout)" above - there is no separate checker to keep in sync.

## Wallpaper

`config/wallpapers/macos.jpg` and `windows.jpg` are the desktop pictures, set by
a `wallpaper` defaults module on each platform (one Updates-tab row). macOS
(`defaults/wallpaper.sh`) reads and sets every screen through `NSWorkspace` in
JXA, not System Events, so it needs no Automation permission; it covers the
current Space per display. Windows (`defaults/wallpaper.ps1`, `DEFAULTS_WALLPAPER`)
compares `HKCU:\Control Panel\Desktop\WallPaper` and sets it with
`SystemParametersInfo`. Both point at the repo file in place, so moving the repo
(or switching to the seeded copy) shows the row pending again. To change a
wallpaper, replace the file; keep it a JPEG around 5K wide.
