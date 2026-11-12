# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Loop
- **Verify:** `make verify` (bash smoke, the two Python suites, `smoke.ps1`, `cargo test` for `app/src-tauri` and `wm`; `NO_RUST=1`/`NO_PWSH=1` opt out of a missing toolchain, and say so)
- **Ship:** commit to `main`, gate, bump the version as the last commit (`release: X.Y.Z (<summary>)`), push `main`, then push the `vX.Y.Z` tag, which runs `release.yml`; once a shipped change is done and verified, push main and the tag without asking. Which bump, which files: `.claude/bindings/ship.md`
- **Deploy check:** `gh run watch <release.yml run> --exit-status`, then `gh release view vX.Y.Z` lists the dmg, the setup exe and both `loadout-wm-*.zip`
- **Branching:** main checkout only. No feature branches, worktrees or merge commits in this repo: commit to `main`, then bump, push and tag
- **Tasks:** Agenda, project Loadout (Homelab folder)

## Project Overview

Loadout: the set of apps a workstation runs, plus their configuration, kept in
one repo. It tracks what is installed, installs it, and configures both the apps
themselves (dotfiles, DCC configs, keymaps) and the OS around them - across
macOS, Linux and Windows, for work and personal machines. The desktop app in
`app/` is the primary interface; the shell/PowerShell entry points do the same
work headlessly. Releases are unsigned Tauri builds published by
`.github/workflows/release.yml` on a `v*` tag.

## Key Concepts

### Profiles

Profiles (`config/profiles/*.conf`) control what gets installed. Profile variables are bash-style `KEY="value"` pairs parsed by both bash (source) and PowerShell (regex).

- `personal.conf` - Full installation for personal macOS devices
- `workstation.conf` - Work macOS device: Blender, Houdini, ComfyUI Desktop, Fork, Ghostty, Loadout WM, Swish, Vorssaint and core CLI tools, from Loadout
- `linux.conf` - Full dev station setup for Linux (Debian/Ubuntu)
- `windows.conf` - Gaming workstation setup for Windows

Profile-wide switches (`PROFILE_HOMEBREW`, `INSTALLERS_*`) and the variable-to-file
naming convention: `.claude/rules/profiles.md`.

### Package Lists

Packages are defined in text files under `config/packages/` — one package per line, comments start with `#`.

### Where the detail lives

Subsystem notes live in nested `CLAUDE.md` files, loaded when you work under that directory:

- `app/CLAUDE.md` - Loadout internals: Rust modules, `serve_ui`, repo bundling/seeding, self-update, background checks
- `lib/windows/CLAUDE.md` - winget, GitHub releases, ComfyUI (nodes, LAN access, auth, model library), Windows installer scripts, Blender/Houdini on Windows
- `platforms/windows/CLAUDE.md` - Windows defaults modules and the registry helpers
- `platforms/macos/installers/CLAUDE.md` - macOS installer-script contract, `houdini.sh`, `blender.sh` install/update
- `config/dcc/CLAUDE.md` - Blender and Houdini config (portable prefs, `setup.py`, keymap, extensions, asset library)
- `wm/CLAUDE.md` - Loadout WM, the repo's own window manager (replaced AeroSpace; GlazeWM on Windows until it is proven there): rules, AX/WinEvent backends, install, version rule

Cross-directory topics live in `.claude/rules/`, loaded when you touch the files they govern:

- `setup-tasks.md` - the Updates-tab status/apply verbs and their JSON contract, macOS defaults helpers, wallpaper
- `dotfiles.md` - the two manifests, Windows dotfile scope, GlazeWM config, T3 settings, backups and symlink rules
- `powershell.md` - PowerShell code style, stage exit codes, the `-Profile`/`$HOME` traps
- `profiles.md` - profile-wide switches and profile variable naming
- `release.md` - `release.yml` and its `verify` gate (the release procedure itself is in `.claude/bindings/ship.md`)

Rules that hold even before you open those files:

- **No credential belongs in this repo.** ComfyUI's login password is chosen at first visit; there is no profile variable for it by design.
- **Never pin `bcrypt<5`** for ComfyUI-Login: it restores silent 72-byte truncation.
- **The ComfyUI firewall rule stays gated on an installed auth node** (`Test-ComfyAuthInstalled`) and scoped `LocalSubnet`/`Private`. Anything that changes the listen address must keep Manager's `network_mode = personal_cloud` in step.
- **Remove the Blender portable junction before any recursive delete** of its Windows install dir (`Remove-Junction`): Windows PowerShell can follow it into the repo.
- **Never compare a GitHub release tag against an app's own DisplayVersion**; compare stamped tag against tag.

## Important Behavioral Notes

**Category variables default to `true` when unset.** Both `lib/symlink.sh` and `platforms/macos/homebrew.sh` use `${!category_var:-true}`. This means:
- Adding a new package list file auto-enables it for all existing profiles
- Adding a new manifest entry without a condition variable installs it everywhere
- To restrict a category, profiles must explicitly set it to `"false"`

**Package installation continues on failure.** Individual package failures are logged but don't abort the run. Results are summarized at the end.

## Commands

```bash
make verify                          # the gate: everything below except --ignored
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

## Security Considerations

This repo is public-safe:
- Personal data goes in `.local` files (gitignored)
- No personal hostnames, domains, IPs, share paths, webhook URLs or emails in
  tracked files. Ask for them at runtime (as `tea_login` does) or read them
  from a gitignored `*.local` file (as `config/sidefx.local` is)
- Git user.email is set in `~/.gitconfig.local`
- Before committing, grep the diff for domains, IPs and emails. Public vendor
  URLs (github.com, sidefx.com, ...) are fine
