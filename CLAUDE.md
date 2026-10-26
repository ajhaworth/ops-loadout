# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Loadout: the set of apps a workstation runs, plus their configuration, kept in
one repo. It tracks what is installed, installs it, and configures both the apps
themselves (dotfiles, DCC configs, keymaps) and the OS around them - across
macOS, Linux and Windows, for work and personal machines. The desktop app in
`app/` is the primary interface; the shell/PowerShell entry points do the same
work headlessly.

## Key Concepts

### Profiles

Profiles (`config/profiles/*.conf`) control what gets installed. Profile variables are bash-style `KEY="value"` pairs parsed by both bash (source) and PowerShell (regex).

- `personal.conf` - Full installation for personal macOS devices
- `workstation.conf` - Work macOS device: Blender, Houdini, ComfyUI Desktop, Fork, Ghostty, Loadout WM, Swish, Vorssaint and core CLI tools, from Loadout
- `linux.conf` - Full dev station setup for Linux (Debian/Ubuntu)
- `windows.conf` - Gaming workstation setup for Windows

Two profile-wide switches sit above the per-category flags. `PROFILE_HOMEBREW="false"`
disables every formula, cask and MAS app at once, makes `homebrew.sh` and
Loadout's prerequisites row skip Homebrew entirely, and stops Loadout
executing `brew`/`mas` at all - not even for status - so a Mac without Homebrew
never sees a "command not found". `INSTALLERS_<CATEGORY>` gates
`config/packages/macos/installers/<category>.txt` the same way `CASKS_*` gates
casks. `workstation.conf` keeps Homebrew (core and shell formulae only, no
casks, no MAS) and leaves `installers/3D.txt` (Blender, Houdini, ComfyUI Desktop) and
`installers/development.txt` (Fork, Ghostty, Loadout WM) and `installers/power-user.txt`
(Swish, Vorssaint) visible; `personal.conf` turns `INSTALLERS_POWER_USER` off since it
gets both from their casks; the user installs those
by hand from the Loadout tiles. Apps added for the work Mac go in as installer
scripts, not casks, so the allow-list stays explicit.

`.github/workflows/release.yml` builds Loadout for every `v*` tag - the
macOS dmg on a macOS runner and the Windows installer on a Windows runner - and
attaches both to a GitHub Release (`tauri-apps/tauri-action`).
It is unsigned, so README tells downloaders to use Open Anyway or clear the
quarantine flag. The app bundles the repo content, so it runs without a
checkout (see "A release ships the repo content" in `app/CLAUDE.md`).

### Package Lists

Packages are defined in text files under `config/packages/` — one package per line, comments start with `#`.

### Where the detail lives

Subsystem notes live in nested `CLAUDE.md` files, loaded when you work under that directory:

- `app/CLAUDE.md` - Loadout internals: Rust modules, `serve_ui`, repo bundling/seeding, self-update, background checks
- `lib/windows/CLAUDE.md` - winget, GitHub releases, ComfyUI (nodes, LAN access, auth, model library), Windows installer scripts, Blender/Houdini on Windows
- `platforms/windows/CLAUDE.md` - Windows defaults modules and the registry helpers
- `platforms/macos/installers/CLAUDE.md` - macOS installer-script contract, `houdini.sh`, `blender.sh` install/update
- `config/dcc/CLAUDE.md` - Blender and Houdini config (portable prefs, `setup.py`, keymap, extensions, Loadout tab, asset library)
- `wm/CLAUDE.md` - Loadout WM, the repo's own window manager (replaced AeroSpace; GlazeWM on Windows until it is proven there): rules, AX/WinEvent backends, install, version rule

Rules that hold even before you open those files:

- **No credential belongs in this repo.** ComfyUI's login password is chosen at first visit; there is no profile variable for it by design.
- **Never pin `bcrypt<5`** for ComfyUI-Login: it restores silent 72-byte truncation.
- **The ComfyUI firewall rule stays gated on an installed auth node** (`Test-ComfyAuthInstalled`) and scoped `LocalSubnet`/`Private`. Anything that changes the listen address must keep Manager's `network_mode = personal_cloud` in step.
- **Remove the Blender portable junction before any recursive delete** of its Windows install dir (`Remove-Junction`): Windows PowerShell can follow it into the repo.
- **Never compare a GitHub release tag against an app's own DisplayVersion**; compare stamped tag against tag.

### Versioning and releases

**Versioning.** Every change that reaches main and touches something a release
ships gets a version bump: `app/`, `config/`, `lib/`, `platforms/` (the bundle),
plus `setup.sh`/`setup.ps1`. That includes package-list edits, installer
scripts, DCC configs, keymaps and `.blend` prefs - a downloaded app sees none of
it until a new version exists. No bump for docs (`README`, `CLAUDE.md`),
`tests/`, or CI-only changes. One bump per push to main, not per commit: bump as
the last commit before the push.

- **patch** (0.4.1 -> 0.4.2): fixes and tweaks to existing things - a bug fix, a
  package added to or removed from a list, a changed default, keymap or prefs
  edits, installer script fixes.
- **minor** (0.4.x -> 0.5.0): something new the user can see or do - a new
  installer app, tab, setting, task section, package kind or platform
  capability. While on 0.x, breaking changes also go here (as the Launchbay ->
  Loadout rename did in 0.4.0).
- **major**: reserved. 1.0.0 is cut deliberately when the user declares it
  stable; after that, major means a change that needs manual action on existing
  machines (an identifier rename stranding the install, a profile format
  change, a repo layout the seeded copy can't follow).

Bump the same version in `app/src-tauri/tauri.conf.json`,
`app/src-tauri/Cargo.toml` and `app/package.json` (let `cargo` refresh
`Cargo.lock`). Commit as `release: X.Y.Z (<summary>)`. The release itself is the
`vX.Y.Z` tag push, which runs `release.yml` - once a shipped change is done and
verified, push main and the tag without asking.

**Work directly on main.** No feature branches, worktrees or merge commits in
this repo: commit to `main`, then bump, push and tag as above. This overrides the global
branch/worktree doctrine here.

### Setup Tasks (Loadout)

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

### Wallpaper

`config/wallpapers/macos.jpg` and `windows.jpg` are the desktop pictures, set by
a `wallpaper` defaults module on each platform (one Updates-tab row). macOS
(`defaults/wallpaper.sh`) reads and sets every screen through `NSWorkspace` in
JXA, not System Events, so it needs no Automation permission; it covers the
current Space per display. Windows (`defaults/wallpaper.ps1`, `DEFAULTS_WALLPAPER`)
compares `HKCU:\Control Panel\Desktop\WallPaper` and sets it with
`SystemParametersInfo`. Both point at the repo file in place, so moving the repo
(or switching to the seeded copy) shows the row pending again. To change a
wallpaper, replace the file; keep it a JPEG around 5K wide.

### Dotfiles

Dotfiles use symlinks managed via two platform-specific manifests:

**`manifest.txt`** (macOS/Linux): `source|destination|backup|condition`
- Destinations use `~` for `$HOME`
- Backup field exists but is currently unused; leave empty

**`manifest.windows.txt`** (Windows): `source|destination|condition`
- Destinations are relative to `$HOME` (`%USERPROFILE%`), no tilde
- Only 3 fields (no backup field)
- Destinations may use tokens, expanded by `Expand-DestPath`: `%USERPROFILE%`,
  `%DOCUMENTS%`, `%LOCALAPPDATA%`, `%APPDATA%`. `%DOCUMENTS%` resolves through
  the shell API rather than `$HOME\Documents`, so OneDrive Known Folder Move is
  handled correctly.
- Windows manages git, WezTerm (`.wezterm.lua`, Ghostty has no Windows build)
  and GlazeWM only. No shell profile or prompt: that box isn't terminal-driven.
  Don't add them without asking.
- `glazewm/config.yaml` is a port of the Mac's former AeroSpace config: one workspace per app,
  everything else floats (`initial_state`, since GlazeWM runs *every* matching
  rule, so a catch-all floating rule would undo the tiling ones), Caps Lock ->
  F18 leader with the same `window`/`repeat` modes. The remap is a `Scancode
  Map` write in `defaults/system.ps1`, only while `DOTFILES_GLAZEWM` is on.
  Games are `ignore`d by engine window class; Alt+Shift+P pauses GlazeWM. The
  entry is skipped until GlazeWM has run once and created `.glzr\glazewm`.

Both manifests: condition is a profile variable name; entry is skipped when that variable is `"false"`.

`config/dotfiles/t3/settings.json` is T3 Code's server settings (personal Mac
only, `DOTFILES_T3`). T3 writes through the symlink and saves only non-default
keys, so a change made in its UI shows up in `git status` here. Before
committing one, check it for `sourceControlHosts`/`deviceHosts` entries, which
can name private hosts. Secrets stay in `~/.t3/userdata/secrets/`.

### macOS Defaults

System preferences are set via `defaults write` commands in `platforms/macos/defaults/*.sh`. Each file defines an `apply_<name>()` function that is dynamically discovered and invoked.

Each `apply_<name>()` is built from two declarative helpers in `lib/tasks.sh`:
`defaults_set <domain> <key> <type> <value> <label>` compares the current
`defaults read` value against the desired one and writes only on a mismatch;
`defaults_hook <hook-id> <label> <check-cmd> <apply-cmd>` covers anything that
isn't a scalar `defaults write` (an `-array` write, a `chflags`, a `mkdir -p`).
Both branch on the same code path for status (writes off) and apply, per
"Setup Tasks (Loadout)" above - there is no separate checker to keep in sync.

## Important Behavioral Notes

**Category variables default to `true` when unset.** Both `lib/symlink.sh` and `platforms/macos/homebrew.sh` use `${!category_var:-true}`. This means:
- Adding a new package list file auto-enables it for all existing profiles
- Adding a new manifest entry without a condition variable installs it everywhere
- To restrict a category, profiles must explicitly set it to `"false"`

**Package installation continues on failure.** Individual package failures are logged but don't abort the run. Results are summarized at the end.

**Backups are timestamped on both platforms.** Bash and PowerShell both move
replaced files into `~/.dotfiles_backup/YYYYMMDD_HHMMSS/`, one directory per
run, so history is preserved.

**Windows symlinks require Developer Mode or Administrator.** The dotfiles script tests symlink capability before proceeding.

**Manifest entries are skipped when their target app is missing.** If creating
the destination would require inventing more than one directory level,
`New-Symlink` skips the entry rather than fabricating something like
`AppData\Local\Packages\Microsoft.WindowsTerminal_*\LocalState\`. Use `-Force`
to override.

**Never name a PowerShell parameter `-Profile`.** `$PROFILE` is an automatic
variable, and a parameter of that name shadows it for the whole script. The
Windows scripts take `-ProfileName` with a `-Profile` alias for compatibility.
For the same reason, never assign to `$HOME` — it is read-only and assigning
throws at runtime.

## Commands

```bash
# Entry-point verbs: ./setup.sh --help, .\setup.ps1 -Help
bash tests/bash/smoke.sh             # Smoke tests
(cd app/src-tauri && cargo test)     # Rust unit tests
(cd app/src-tauri && cargo test -- --ignored --nocapture)  # + live repo scan
(cd app/src-tauri && cargo test <name>)                    # one Rust test
python3 tests/bash/blender_install.py      # blender.sh against fake apps
python3 tests/bash/download_progress.py    # installer curl progress pipe
python3 tests/bash/blender_install.py InstallTests.<test_name>  # one test
```

```powershell
pwsh tests\windows\smoke.ps1         # Smoke tests
```

The smoke tests run on any platform: syntax, helper-function and
config-consistency checks work everywhere, and the dry-run invocations are
skipped off Windows. Both smoke suites are flat scripts with no single-test
selector; run one check by commenting out the rest. The two Python files are
`unittest` suites and never touch `/Applications`. `smoke.ps1` also parses
`bridge.ps1` and asserts its verb set. The Rust side is covered only by
`cargo test`.

## Code Style

### PowerShell (Windows)

- Library modules in `lib/windows/` (`.psm1` files) with explicit `Export-ModuleMember`
- A native command inside a function that returns `$true`/`$false` pipes to
  `Write-NativeOutput` (`& tool 2>&1 | Write-NativeOutput`). Left uncaptured its
  output joins the return value, and `-not @('text', $false)` is `$false` - the
  job then reports success when it failed
- `-DryRun` switch parameter threaded through function calls (not a global variable)
- Profile parsed into hashtable by `Read-Profile`, checked with `Test-ProfileFlag`

Stages report failures through exit codes: each stage script exits non-zero when
anything failed, `platforms/windows/setup.ps1` counts failing stages without
aborting the run, and the root `setup.ps1` propagates the final code.

## Profile Variable Naming

Variables map to package directories via naming convention:
- `FORMULAE_CORE` → `config/packages/macos/formulae/core.txt`
- `GITHUB_GAMING` → `config/packages/windows/github/gaming.txt`
- Underscores in variable names map to hyphens in filenames: `FORMULAE_SOFTWARE_DEV` → `software-dev.txt`
- Conversion: `lib/common.sh:get_category_var()` (bash) / `lib/windows/common.psm1:Get-CategoryVar` (PowerShell)

## Security Considerations

This repo is public-safe:
- Personal data goes in `.local` files (gitignored)
- No personal hostnames, domains, IPs, share paths, webhook URLs or emails in
  tracked files. Ask for them at runtime (as `tea_login` does) or read them
  from a gitignored `*.local` file (as `config/sidefx.local` is)
- Git user.email is set in `~/.gitconfig.local`
- Before committing, grep the diff for domains, IPs and emails. Public vendor
  URLs (github.com, sidefx.com, ...) are fine
