# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cross-platform workstation setup tool. Automates installation of packages, dotfiles, and system preferences across macOS, Linux, and Windows.

Agentic coding setup (Claude Code, Codex, tmux, Ghostty, Claude dotfiles) lives in the sibling [ops-agents](../ops-agents) repository.

## Key Concepts

### Profiles

Profiles (`config/profiles/*.conf`) control what gets installed. Profile variables are bash-style `KEY="value"` pairs parsed by both bash (source) and PowerShell (regex).

- `personal.conf` - Full installation for personal macOS devices
- `work.conf` - Minimal installation for work macOS devices
- `linux.conf` - Full dev station setup for Linux (Debian/Ubuntu)
- `windows.conf` - Gaming workstation setup for Windows

### Package Lists

Packages are defined in text files under `config/packages/` — one package per line, comments start with `#`.

- `macos/formulae/*.txt` / `macos/casks/*.txt` - Homebrew CLI tools and GUI apps
- `macos/mas/apps.txt` - Mac App Store apps (`ID|Name` format)
- `linux/apt/*.txt` - APT packages
- `windows/github/*.txt` - GitHub release installers (see below)
- `windows/comfynodes/*.txt` - ComfyUI custom nodes (see below)

Windows winget and Chocolatey packages are **not** managed here — they moved
to Ansible in the sibling `ops-server` repo (`roles/windows/packages`, run via
`./scripts/homelab setup windows`), to keep the package lists in one place.
This repo deliberately keeps the GitHub-release and ComfyUI-node paths, since
their version-stamp/compare logic has no clean Ansible equivalent.

### GitHub Release Packages

For the handful of Windows apps published only as a GitHub release asset.
Entries are pipe-delimited and parsed by `ConvertFrom-GitHubPackageSpec`:

```
owner/repo | asset-pattern | display-name | install-args
```

Everything after the repo is optional, defaulting to `*.exe`, the repo name and
`/quiet`. `Install-GitHubRelease` resolves the latest release through the GitHub
API, downloads the first asset matching the pattern into a temp directory, runs
it, and cleans up.

Install detection reads Add/Remove Programs (`Get-InstalledProgram`) rather than
a package manager. Display-name patterns without a wildcard match as substrings,
so `Vibepollo` finds `Vibepollo 1.18.3-beta.7`.

An installed app is upgraded when the latest release is newer.
`Compare-VersionString` does the comparison, handling a leading `v` and semver
prerelease suffixes — a prerelease ranks below the plain release, so `1.18.4`
beats both `1.18.3-beta.7` and `1.18.4-rc.1`. It returns `$null` when either
side is unparseable, and the caller treats that as "cannot tell" and skips:
guessing "newer" there would reinstall the package on every run. `-Force`
reinstalls regardless.

**Do not compare a release tag against the app's own DisplayVersion.** The two
are different schemes and need not agree. Vibepollo's `v1.18.4` release installs
a binary that registers itself as `1.18.4-beta.3`, which reads as "older than
the release" forever — the package reinstalls on every run. So a successful
install records its tag under `HKCU:\Software\ops-workstation\GitHubReleases`
(`Get-`/`Set-GitHubReleaseStamp`), and later runs compare tag against tag.

Without a stamp — an install this tool did not perform — it falls back to
DisplayVersion with `-IgnorePreRelease`, comparing numeric cores only, and
records a stamp on the way past so the next run is exact.

(That same mismatch is why Vibepollo itself nags about an available update: its
updater compares its internal version to the repo's git tags. Setting
`update_check_interval = 0` in `sunshine.conf` disables the check.)

Resolving the latest release requires the API, so this path is not offline —
but a failed lookup during `-DryRun` degrades to a notice rather than an error,
which keeps the smoke tests runnable without network access. `GITHUB_TOKEN` is
used when set, lifting the 60/hour unauthenticated rate limit.

`packages ls` reports only installed-or-not, without the API call.

### ComfyUI Custom Nodes

`config/packages/windows/comfynodes/*.txt`, one node per line:

```
owner/repo | directory-name
```

The directory defaults to the repo name, matching what ComfyUI Manager would
have cloned. Nodes install into every local backend's `custom_nodes\`, and their
`requirements.txt` goes into that backend's **own `.venv`** — not the
`standalone-env` it was seeded from, and not any python on PATH
(`Get-ComfyVenvPython`). Installing into the wrong interpreter leaves the node
importable but broken at runtime.

An existing node directory is skipped; `-Force` runs `git pull --ff-only`, so
local edits surface as a failure instead of a silent merge. Nodes load at
startup, so the stage warns to restart Desktop when it is running.

### ComfyUI Network Access

`defaults/comfyui-network.ps1` makes the backend reachable from the LAN, driven
by `COMFYUI_LISTEN` and `COMFYUI_PORT`:

- writes `--listen 0.0.0.0 --port <port>` into each install's `launchArgs` in
  `installations.json`, merging rather than replacing (`Merge-ComfyLaunchArgs`
  keeps `--enable-manager` and is idempotent across re-runs)
- opens inbound TCP on that port, scoped to `LocalSubnet` on `Private`
  networks. Needs Administrator and skips cleanly without it.

The port is pinned rather than left to Desktop's automatic selection, because a
firewall rule and a bookmark on another machine both need it to stay put.

**Binding 0.0.0.0 silently breaks ComfyUI Manager's model installs.** Manager
gates them on risk level `middle+`, which it grants only when the listen address
is loopback (`is_local_mode`) or `network_mode` is `personal_cloud`:

```python
elif level == RiskLevel.middle_.value:      # 'middle+'
    if is_local_mode or is_personal_cloud:
        return security_level in [weak, normal, normal_]
    else:
        return False
```

Listening on the LAN makes the first false, so an install fails with no queue
entry, no history row and nothing in Manager's log — the "missing models" dialog
just sits at "waiting". Raising `security_level` does not help; that branch
never reads it. So `Set-ComfyManagerNetworkMode` writes
`network_mode = personal_cloud` into `<backend>\user\__manager\config.ini`,
which describes this deployment accurately and restores installs while
`high`/`high+` operations still require the `weak` level.

Anything that changes the listen address has to keep this in step.

**The `launchArgs` write is skipped while Comfy Desktop is running** — the app
rewrites its JSON state on exit, so a write made underneath it is discarded.
That check gates only that write. The firewall rule is ordinary Windows state
and is unaffected by whether Desktop is open, so it must not sit behind the same
guard: doing so made an elevated run silently fail to open the port just because
the app happened to be running.

`installations.json` is rewritten through `ConvertTo-Json -Depth 32`. The depth
matters: the nested torch-stack objects serialise as type names rather than data
at the default depth of 2, which would corrupt the file.

### ComfyUI Authentication

**ComfyUI has no authentication of its own.** Anything that can reach the port
can drive the GPU, read generated images and browse the model library — which on
this machine includes the whole TrueNAS share.

`liusida/ComfyUI-Login` in `comfynodes/core.txt` supplies it: a login page for
the UI, and `Authorization: Bearer <token>` (or a `token=` argument) for API
calls. The password is chosen on first visit and hashed into
`<backend>\login\PASSWORD`. **No credential belongs in this repo** — it is
public-safe, and there is no profile variable for the password by design.

**The password must be 72 characters or fewer.** `password.py` hashes it with
bcrypt and never checks the length; bcrypt 5 raises `ValueError` above 72 bytes
where older versions silently truncated, so a longer passphrase surfaces as an
unexplained HTTP 500 on first login. The exception fires before the file write,
so a failed attempt leaves no state — just log in again with a shorter one.

Do not "fix" this by pinning `bcrypt<5`: that restores silent truncation, so a
long passphrase becomes its first 72 bytes and the stored credential is not the
password the user thinks they set.

`comfyui-network.ps1` will not create the firewall rule unless one of
`Get-ComfyAuthNodeNames` is installed (`Test-ComfyAuthInstalled`). Binding
0.0.0.0 is inert while the firewall blocks the port, so the rule is the step
that actually publishes ComfyUI, and it is the one gated. A full run installs
the node in the packages stage first, but `setup.ps1 defaults` on its own would
not — hence the check rather than relying on stage order. `COMFYUI_REQUIRE_AUTH`
turns it off deliberately.

Adding another auth node means adding its directory name to
`Get-ComfyAuthNodeNames`, or the interlock will not recognise it. A smoke test
asserts that at least one recognised auth node is actually in the node list.

The rule stays LocalSubnet/Private rather than Any regardless — the login is
defence in depth, not a reason to widen the scope.

These installers are not silent by contract the way winget and Chocolatey are:
the flags come from the entry, and a wrong flag means a GUI appears mid-run.
Verify a new entry interactively before trusting it in an unattended run.

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
- Windows is deliberately git-only. Shell, prompt and terminal config are not
  managed here — that box isn't terminal-driven. Don't add them back without
  asking.

Both manifests: condition is a profile variable name; entry is skipped when that variable is `"false"`.

### macOS Defaults

System preferences are set via `defaults write` commands in `platforms/macos/defaults/*.sh`. Each file defines an `apply_<name>()` function that is dynamically discovered and invoked.

### Windows Defaults

Same pattern in PowerShell. `platforms/windows/defaults/*.ps1` each define an
`Apply-<Name>` function (`explorer.ps1` → `Apply-Explorer`, mapped by
`Get-ApplyFunctionName`), discovered and invoked by `platforms/windows/defaults.ps1`.

Registry writes go through `lib/windows/registry.psm1` (`Set-RegistryValue`,
`Set-RegistryValueSet`, `Remove-RegistryKey`), which is idempotent, dry-run
aware, and records changed/skipped/failed counts. `debloat.ps1` uses the same
helpers.

`Label` states the *outcome*, not the registry value — `HideFileExt = 0` is
labelled "Show file extensions". So the log prints the label alone; printing
`Show file extensions = 0` reads as the exact opposite of what happened. Dry-run
still shows the key and value, since that output exists to be verified against.

Access-denied errors are reported as "needs Administrator" and counted as
skipped, not failed (`Test-AccessDeniedError`). Policy branches like
`HKCU:\SOFTWARE\Policies` require an elevated token despite living under HKCU,
so a non-elevated run legitimately cannot write them.

Filenames map to profile variables like package lists: `taskbar.ps1` →
`DEFAULTS_TASKBAR`. `power.ps1` and the HKLM half of `privacy.ps1` need
Administrator and skip cleanly without it.

Every module is invoked as `Apply-<Name> -ProfileConfig $config -DryRun:$DryRun`,
so each must accept both parameters even if it ignores `-ProfileConfig`. The
smoke tests assert this — a missing parameter is a runtime binding error, not a
parse error. Note the name is `ProfileConfig`, not `Profile`, to avoid shadowing
the `$PROFILE` automatic variable.

Not every module writes to the registry. `comfyui.ps1` writes a YAML file; the
"defaults" concept is machine/app preferences generally, mirroring
`platforms/macos/defaults/apps.sh`.

### ComfyUI

Installed as `Comfy.ComfyUI-Desktop` via Ansible in `ops-server`
(`roles/windows/packages`), at its own default location. Only the model
library is redirected.

Desktop keeps its state in `%APPDATA%\Comfy Desktop` (note the space — there is
no `%APPDATA%\ComfyUI`). Two files there matter:

- `settings.json` — `modelsDirs` is the app's own list of model directories
- `shared_model_paths.yaml` — **generated** from `modelsDirs`, and marked "do
  not edit manually"

Neither can express a folder *rename*. But the bundled backend still auto-loads
`extra_model_paths.yaml` from its own directory — `main.py` does this whenever
the file exists — and Desktop never writes that file, only shipping an
`.example`. So the mapped library goes there, and the two mechanisms coexist:
Desktop keeps its local folder for downloads, this adds the library on top.

`defaults/comfyui.ps1` writes that file from `COMFYUI_MODEL_PATH`. It:
- skips until `%APPDATA%\Comfy Desktop` exists and `installations.json` records
  a local install (cloud entries have no `installPath`)
- finds the backend directory by looking for `main.py` under the recorded
  install path, and writes one config per install
- resolves folder names against what is actually on disk
  (`Resolve-ComfyModelFolders`), preserving on-disk casing and trying ComfyUI's
  own name before any alias, so an already-correct library is left alone
- **skips rather than guessing when the path is unreachable** — a mapping
  written blind points ComfyUI at directories that do not exist
- omits `is_default`, leaving Desktop's own folder as the download target
- preserves any pre-existing file once as `.orig` before first overwrite

`COMFYUI_MODEL_PATH` is `D:\diffusion`, which uses ComfyUI's own folder names, so
the mapping is 1:1 and the generated yaml is plain identity entries. It was
`\\TRUENAS\apps\diffusion` until loading models over SMB proved too slow; that
copy is kept as a manual archive and the "unreachable" branch above no longer
fires in practice.

The alias candidates in `Get-ComfyModelFolderMap` (`Stable-diffusion` →
`checkpoints`, `Lora` → `loras`, `ESRGAN` → `upscale_models`) are **kept
deliberately** even though nothing uses them now — they cost nothing and make the
module work against an A1111-style library on another machine.

`unet\` and `clip\` are left alone rather than folded into `diffusion_models\`
and `text_encoders\`. They are supported ComfyUI aliases, not mistakes:
`folder_paths.py` maps them via `map_legacy()`, and `add_model_folder_path()`
applies that to `extra_model_paths.yaml` keys too, so both directories are
searched under the canonical key.

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
# macOS/Linux
./setup.sh --profile personal       # Full setup with profile
./setup.sh --dry-run --profile work  # Preview changes
./setup.sh dotfiles                  # Dotfiles only
./setup.sh dotfiles ls               # Check symlink status
./setup.sh homebrew                  # All Homebrew packages (macOS)
./setup.sh formulae                  # CLI tools only (macOS)
./setup.sh casks                     # GUI apps only (macOS)
./setup.sh defaults                  # System preferences (macOS)
./setup.sh packages                  # APT packages (Linux)
```

```powershell
# Windows
.\setup.ps1                          # Full setup
.\setup.ps1 -DryRun                  # Preview changes
.\setup.ps1 dotfiles                 # Dotfiles only
.\setup.ps1 dotfiles ls              # Check symlink status
.\setup.ps1 packages                 # GitHub releases + ComfyUI custom nodes
.\setup.ps1 packages ls              # Package status
.\setup.ps1 defaults                 # System preferences
.\setup.ps1 defaults ls              # Preference categories
.\setup.ps1 debloat                  # Remove bloatware
.\setup.ps1 -Debloat -Force          # Full setup with debloat
.\setup.ps1 -Help                    # Usage

pwsh tests\windows\smoke.ps1         # Smoke tests
```

The smoke tests run on any platform: syntax, helper-function and
config-consistency checks work everywhere, and the dry-run invocations are
skipped off Windows.

## Common Tasks

### Adding a new package

Add to the appropriate category file in `config/packages/<platform>/`. The filename maps to a profile variable: `software-dev.txt` → `FORMULAE_SOFTWARE_DEV`. If you add a new file, existing profiles will auto-enable it unless they explicitly set the variable to `"false"`.

### Adding a new dotfile

1. Create the config file in `config/dotfiles/`
2. Add mapping to `manifest.txt` (macOS/Linux) and/or `manifest.windows.txt` (Windows)
3. Platform-specific files use naming convention: `settings.macos.json`, `settings.windows.json`
4. Test with `./setup.sh dotfiles --dry-run` or `.\setup.ps1 dotfiles -DryRun`

### Adding a new macOS preference

1. Create or edit file in `platforms/macos/defaults/`
2. Define `apply_<filename>()` function
3. Check `is_dry_run` before running `defaults write` commands

### Adding a new Windows preference

1. Create or edit file in `platforms/windows/defaults/`
2. Define `Apply-<Filename>` taking a `[switch]$DryRun`
3. Build an array of `@{ Path; Name; Value; Type; Label }` and pass it to
   `Set-RegistryValueSet -Settings $settings -DryRun:$DryRun`
4. Add `DEFAULTS_<FILENAME>` to `config/profiles/windows.conf` — the smoke
   tests assert the file and the variable stay in sync
5. Test with `.\setup.ps1 defaults -DryRun`

## Code Style

### Bash (macOS/Linux)

- `set -euo pipefail` at top of scripts
- Library functions from `lib/`: `log_info`, `log_success`, `log_warn`, `log_error`, `log_step`, `log_substep`
- `is_dry_run` to check mode, `run_cmd` to execute commands respecting dry-run (returns 0 in dry-run)
- `command_exists` to check if a command is available
- Colors are only set when stdout is a terminal (safe for piping)

### PowerShell (Windows)

- `$ErrorActionPreference = "Stop"` with try-catch around risky operations
- Library modules in `lib/windows/` (`.psm1` files) with explicit `Export-ModuleMember`
- Logging functions mirror bash: `Write-Step`, `Write-SubStep`, `Write-Success`, `Write-Warn`, `Write-Err`
- `-DryRun` switch parameter threaded through function calls (not a global variable)
- Profile parsed into hashtable by `Read-Profile`, checked with `Test-ProfileFlag`

## Architecture

```
setup.sh (macOS/Linux entry point)
    ├── lib/common.sh, detect.sh, prompt.sh, symlink.sh, packages.sh, dotfiles.sh
    └── Dispatches to:
        ├── platforms/macos/setup.sh
        │   ├── homebrew.sh (formulae, casks, MAS apps)
        │   ├── dotfiles.sh (manifest.txt processing)
        │   └── defaults.sh (dynamically loads defaults/*.sh)
        └── platforms/linux/setup.sh
            ├── packages.sh, repositories.sh, extras.sh
            └── dotfiles.sh (manifest.txt processing)

setup.ps1 (Windows entry point — thin wrapper)
    └── platforms/windows/setup.ps1
        ├── lib/windows/common.psm1, packages.psm1, dotfiles.psm1, registry.psm1,
        │                comfyui.psm1
        ├── packages.ps1 (github releases + comfyui nodes)
        ├── dotfiles.ps1 (manifest.windows.txt processing)
        ├── defaults.ps1 (dynamically loads defaults/*.ps1)
        └── debloat.ps1 (optional bloatware removal)
```

Stages report failures through exit codes: each stage script exits non-zero when
anything failed, `platforms/windows/setup.ps1` counts failing stages without
aborting the run, and the root `setup.ps1` propagates the final code.

### Profile Variable Naming

Variables map to package directories via naming convention:
- `FORMULAE_CORE` → `config/packages/macos/formulae/core.txt`
- `GITHUB_GAMING` → `config/packages/windows/github/gaming.txt`
- Underscores in variable names map to hyphens in filenames: `FORMULAE_SOFTWARE_DEV` → `software-dev.txt`
- Conversion: `lib/common.sh:get_category_var()` (bash) / `lib/windows/common.psm1:Get-CategoryVar` (PowerShell)

## Security Considerations

This repo is public-safe:
- Personal data goes in `.local` files (gitignored)
- Git user.email is set in `~/.gitconfig.local`
