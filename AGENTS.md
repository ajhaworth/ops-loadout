# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Cross-platform workstation setup tool. Automates installation of packages, dotfiles, and system preferences across macOS, Linux, and Windows.

## Key Concepts

### Profiles

Profiles (`config/profiles/*.conf`) control what gets installed. Profile variables are bash-style `KEY="value"` pairs parsed by both bash (source) and PowerShell (regex).

- `personal.conf` - Full installation for personal macOS devices
- `work.conf` - Minimal installation for work macOS devices
- `linux.conf` - Full dev station setup for Linux (Debian/Ubuntu)
- `windows.conf` - Gaming workstation setup for Windows

### Package Lists

Packages are defined in text files under `config/packages/` — one package per line, comments start with `#`. Chocolatey entries can include flags after the package name (e.g., `package --pre`).

- `macos/formulae/*.txt` / `macos/casks/*.txt` - Homebrew CLI tools and GUI apps
- `macos/mas/apps.txt` - Mac App Store apps (`ID|Name` format)
- `linux/apt/*.txt` - APT packages
- `windows/winget/*.txt` - Winget packages
- `windows/choco/*.txt` - Chocolatey packages

### Dotfiles

Dotfiles use symlinks managed via two platform-specific manifests:

**`manifest.txt`** (macOS/Linux): `source|destination|backup|condition`
- Destinations use `~` for `$HOME`
- Backup field exists but is currently unused; leave empty

**`manifest.windows.txt`** (Windows): `source|destination|condition`
- Destinations are relative to `$HOME` (`%USERPROFILE%`), no tilde
- Only 3 fields (no backup field)

Both manifests: condition is a profile variable name; entry is skipped when that variable is `"false"`.

### macOS Defaults

System preferences are set via `defaults write` commands in `platforms/macos/defaults/*.sh`. Each file defines an `apply_<name>()` function that is dynamically discovered and invoked.

## Important Behavioral Notes

**Category variables default to `true` when unset.** Both `lib/symlink.sh` and `platforms/macos/homebrew.sh` use `${!category_var:-true}`. This means:
- Adding a new package list file auto-enables it for all existing profiles
- Adding a new manifest entry without a condition variable installs it everywhere
- To restrict a category, profiles must explicitly set it to `"false"`

**Package installation continues on failure.** Individual package failures are logged but don't abort the run. Results are summarized at the end.

**Backup strategies differ by platform.** Bash creates timestamped directories (`~/.dotfiles_backup/YYYYMMDD_HHMMSS/`), preserving history. PowerShell renames in-place with `.backup` suffix, overwriting previous backups.

**Windows symlinks require Developer Mode or Administrator.** The dotfiles script tests symlink capability before proceeding.

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
.\setup.ps1 packages                 # Winget + Chocolatey
.\setup.ps1 packages ls              # Package status
.\setup.ps1 debloat                  # Remove bloatware
.\setup.ps1 -Debloat -Force          # Full setup with debloat
```

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
        ├── lib/windows/common.psm1, packages.psm1, dotfiles.psm1
        ├── packages.ps1 (winget + chocolatey)
        ├── dotfiles.ps1 (manifest.windows.txt processing)
        └── debloat.ps1 (optional bloatware removal)
```

### Profile Variable Naming

Variables map to package directories via naming convention:
- `FORMULAE_CORE` → `config/packages/macos/formulae/core.txt`
- `WINGET_GAMING` → `config/packages/windows/winget/gaming.txt`
- Underscores in variable names map to hyphens in filenames: `FORMULAE_SOFTWARE_DEV` → `software-dev.txt`
- Conversion: `lib/common.sh:get_category_var()` (bash) / `lib/windows/common.psm1:Get-CategoryVar` (PowerShell)

## Security Considerations

This repo is public-safe:
- Personal data goes in `.local` files (gitignored)
- Git user.email is set in `~/.gitconfig.local`
