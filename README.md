# ops-desktop

Cross-platform workstation setup using simple shell scripts with profile-based customization.

For Claude Code, Codex, tmux, and agentic coding configuration, see [ops-agents](../ops-agents).

## Quick Start

```bash
# Clone the repository
git clone <your-repo-url>
cd ops-workstation

# macOS/Linux
./setup.sh --profile personal
./setup.sh --dry-run --profile work
```

```powershell
# Windows (PowerShell)
.\setup.ps1
.\setup.ps1 -DryRun
```

## Features

- **Profile-based configuration**: Different setups for personal vs work devices
- **Modular commands**: Run specific components (homebrew, dotfiles, defaults)
- **Idempotent**: Safe to run multiple times
- **Dry-run mode**: Preview changes before applying
- **Dotfiles management**: Symlinked configs with backup support
- **Status checking**: List commands show what's installed vs missing
- **Strict profile validation**: Profiles now fail fast when used on the wrong OS

## Supported Platforms

| Platform | Status |
|----------|--------|
| macOS    | Supported |
| Linux    | Supported |
| Windows  | Supported |

## Profiles

Profiles control which package categories get installed. Edit `config/profiles/*.conf` to customize.

### Personal (`--profile personal`)

Full installation for personal macOS devices including all package categories, Mac App Store apps, and system preferences.

### Work (`--profile work`)

Minimal installation for work macOS devices - core development tools only, skips media/graphics apps and Mac App Store.

### Linux (`--profile linux`)

Full dev station setup for Debian/Ubuntu Linux including core tools, shell enhancements, and web development stack.

### Windows (`--profile windows`)

Gaming workstation setup for Windows: dotfiles, GitHub-release apps, ComfyUI
custom nodes, and system preferences, with optional bloatware removal. Winget
and Chocolatey package installation (core dev tools, browsers, productivity
apps, gaming clients, emulators) has moved to Ansible in the `ops-server`
repo (`roles/windows/packages`, run via `./scripts/homelab setup windows`).

## Usage

```bash
# Full setup (interactive profile selection)
./setup.sh

# Full setup with profile
./setup.sh --profile personal

# Install specific components (macOS)
./setup.sh homebrew            # All Homebrew packages
./setup.sh formulae            # CLI tools only
./setup.sh casks               # GUI apps only
./setup.sh mas                 # Mac App Store apps only
./setup.sh dotfiles            # Dotfiles only
./setup.sh defaults            # System preferences only

# Install specific components (Linux)
./setup.sh packages            # System packages (apt)
./setup.sh dotfiles            # Dotfiles only

# Check status without making changes
./setup.sh homebrew ls         # Show package status (macOS)
./setup.sh formulae ls         # Show formulae status (macOS)
./setup.sh casks ls            # Show cask status (macOS)
./setup.sh mas ls              # Show MAS app status (macOS)
./setup.sh packages ls         # Show package status (Linux)
./setup.sh dotfiles ls         # Show symlink status
```

```powershell
# Windows
.\setup.ps1                    # Full setup
.\setup.ps1 -DryRun            # Preview changes
.\setup.ps1 dotfiles           # Dotfiles only
.\setup.ps1 dotfiles ls        # Check symlink status
.\setup.ps1 packages           # GitHub releases + ComfyUI custom nodes
.\setup.ps1 packages ls        # Show package status
.\setup.ps1 defaults           # System preferences
.\setup.ps1 defaults ls        # Show preference categories
.\setup.ps1 debloat            # Remove bloatware
.\setup.ps1 -Debloat -Force    # Full setup with debloat
.\setup.ps1 -Help              # Show help message
```

### Options

**macOS/Linux:**
```
--profile <name>    Use specified profile (personal, work, linux, windows)
--dry-run           Show what would be done without making changes
--force             Skip confirmation prompts
--help              Show help message
```

Profiles are OS-specific. A mismatched profile now exits immediately instead of running a partial setup.

**Windows:**
```
-ProfileName <name> Profile to use (default: windows). Alias: -Profile
-DryRun             Show what would be done without making changes
-Force              Reinstall packages, replace mismatched symlinks, and
                    restart Explorer after applying defaults
-Debloat            Include bloatware removal in full setup
-Help               Show help message
```

Each stage exits non-zero if anything in it failed, and the overall run
propagates that, so `.\setup.ps1` is usable from CI or a scheduled task.

### Tests

```powershell
pwsh tests\windows\smoke.ps1   # Windows
bash tests/bash/smoke.sh       # macOS/Linux
```

The Windows suite checks syntax, helper functions, and that profiles, package
lists, manifest entries and defaults modules all stay in sync. It runs on any
platform — the dry-run invocations, which need the registry, are skipped when
not on Windows.

## Customization

### Adding Packages

Packages are defined in text files under `config/packages/`:

**macOS** (`config/packages/macos/`):
- `formulae/*.txt` - Homebrew CLI tools (one package per line)
- `casks/*.txt` - Homebrew GUI apps (one package per line)
- `mas/apps.txt` - Mac App Store apps (`ID|Name` format)

**Linux** (`config/packages/linux/`):
- `apt/*.txt` - APT packages (Debian/Ubuntu only)

**Windows** (`config/packages/windows/`):
- `github/*.txt` - Apps published only as GitHub release assets, for the
  handful with no winget or Chocolatey package. Pipe-delimited:
  `owner/repo | asset-pattern | display-name | install-args`, where every field
  after the repo is optional (defaults: `*.exe`, the repo name, `/quiet`).
  Install state is read from Add/Remove Programs, and an app already present is
  upgraded when the latest release is newer (semver-aware, so `1.18.4` beats
  `1.18.3-beta.7`). `-Force` reinstalls regardless.
- `comfynodes/*.txt` - ComfyUI custom nodes, `owner/repo | directory-name` (the
  directory defaults to the repo name). Cloned into every local ComfyUI
  backend's `custom_nodes/`, with `requirements.txt` installed into that
  backend's own `.venv`. Existing nodes are skipped; `-Force` fast-forwards
  them. Skipped entirely on a machine with no ComfyUI.

Winget and Chocolatey packages are managed by Ansible in the `ops-server`
repo (`roles/windows/packages`, run via `./scripts/homelab setup windows`),
not here. The GitHub-release and ComfyUI-node paths stay in this repo because
their version-stamp/compare logic has no clean Ansible equivalent.

### Local Overrides

Machine-specific settings go in `.local` files (not tracked by git):
- `~/.zshrc.local` - Shell customizations
- `~/.gitconfig.local` - Git user info and signing key

### Creating a New Profile

1. Copy an existing profile:
   ```bash
   cp config/profiles/personal.conf config/profiles/myprofile.conf
   ```

2. Edit the boolean flags to enable/disable package categories

3. Use the new profile:
   ```bash
   ./setup.sh --profile myprofile
   ```

## Project Structure

```
ops-workstation/
├── setup.sh                    # Entry point (macOS/Linux)
├── setup.ps1                   # Entry point (Windows)
├── lib/                        # Shared libraries
│   ├── common.sh               # Colors, logging
│   ├── detect.sh               # OS detection
│   ├── prompt.sh               # User interaction
│   ├── symlink.sh              # Symlink utilities
│   ├── packages.sh             # Package parsing
│   └── windows/                # PowerShell modules
│       ├── common.psm1         # Logging, profile parsing
│       ├── dotfiles.psm1       # Symlink management
│       ├── packages.psm1       # GitHub-release/ComfyUI-node helpers
│       └── registry.psm1       # Idempotent registry writes
├── config/
│   ├── profiles/               # Profile configs
│   ├── packages/
│   │   ├── macos/              # macOS package lists
│   │   │   ├── formulae/       # CLI tools
│   │   │   ├── casks/          # GUI apps
│   │   │   └── mas/            # App Store apps
│   │   ├── linux/              # Linux package lists
│   │   │   └── apt/            # APT packages
│   │   └── windows/            # Windows package lists (winget/choco moved to ops-server)
│   │       ├── github/         # GitHub release installers
│   │       └── comfynodes/     # ComfyUI custom nodes
│   └── dotfiles/               # Configuration files and manifests
└── platforms/
    ├── macos/                  # macOS-specific scripts
    │   ├── setup.sh            # Orchestrator
    │   ├── homebrew.sh         # Package installer
    │   ├── dotfiles.sh         # Symlink installer
    │   ├── defaults.sh         # Preferences loader
    │   └── defaults/           # Individual preference scripts
    ├── linux/                  # Linux-specific scripts
    │   ├── setup.sh            # Orchestrator
    │   ├── packages.sh         # APT package installer
    │   ├── repositories.sh     # Third-party repos (NodeSource, etc.)
    │   ├── extras.sh           # Extra tools (starship, eza, etc.)
    │   └── dotfiles.sh         # Symlink installer
    └── windows/                # Windows-specific scripts
        ├── setup.ps1           # Orchestrator
        ├── packages.ps1        # GitHub releases + ComfyUI custom nodes
        ├── dotfiles.ps1        # Symlink installer
        ├── defaults.ps1        # Preferences loader
        ├── defaults/           # Individual preference scripts
        └── debloat.ps1         # Bloatware removal
```

## Security

This repository is designed to be public and contains no secrets. Personal information is stored in local override files (`~/.gitconfig.local`, `~/.zshrc.local`).

## Troubleshooting

**Homebrew installation fails** - Ensure Xcode Command Line Tools are installed: `xcode-select --install`

**MAS apps won't install** - Sign into the Mac App Store app first, then run setup again.

**Dotfile symlinks fail** - Existing files and third-party symlinks are backed up automatically. Check for conflicts with `./setup.sh dotfiles ls`.

**Linux package setup exits immediately on Fedora/Arch/etc.** - Linux package automation is intentionally limited to Debian/Ubuntu because repository and extra-tool setup is APT-based.

**Windows symlinks fail** - Enable Developer Mode (Settings > Privacy & security > For developers) or run PowerShell as Administrator.

**A Windows dotfile is skipped as "is the app installed?"** - The destination
folder is more than one level away from anything that exists, which usually
means the owning app isn't installed yet (Windows Terminal is the common case).
Install it and re-run, or pass `-Force` to create the tree anyway.

**ComfyUI still shows no models** - The model config is only written once
ComfyUI Desktop has run its first-time setup. Launch it once, then re-run
`.\setup.ps1 defaults`, then restart ComfyUI. Note that Desktop reads
`%APPDATA%\ComfyUI\extra_models_config.yaml`, not the `extra_model_paths.yaml`
that portable-install guides describe.

**ComfyUI models missing after a reboot** - If `COMFYUI_MODEL_PATH` is a network
share, it must be reachable when ComfyUI starts. The setup warns if the path
can't be reached at the time it runs.

**Windows power/telemetry settings skipped** - `defaults` writes those to HKLM.
Run PowerShell as Administrator to apply them.

**Preferences not applying** - Some preferences require a logout/login or restart to take effect. `.\setup.ps1 defaults -Force` restarts Explorer for you.

## License

MIT License - See [LICENSE](LICENSE) for details.
