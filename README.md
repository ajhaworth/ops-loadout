# ops-loadout

The apps a workstation runs, and how they and the OS are configured, in one
repo. Loadout tracks what is installed, installs it, and applies the app and
system configuration that goes with it - on macOS, Linux and Windows, for work
and personal machines. Profiles decide which parts apply where.

## Quick Start

The primary way to use this repo is the Loadout GUI. One command builds
and installs it:

```bash
# Clone the repository
git clone <your-repo-url>
cd ops-loadout

# macOS
./setup.sh launcher
```

```powershell
# Windows (PowerShell)
.\setup.ps1 launcher
```

Each installs its own toolchain deps (Homebrew/Node/Rust on macOS; winget,
Node, Rust and the VC++ Build Tools on Windows) before building the app, so a
bare checkout is enough.

A macOS `.dmg` and a Windows installer are attached to the single
[GitHub release](https://github.com/ajhaworth/ops-loadout/releases)
(`.github/workflows/release.yml`, run on every `v*` tag, which also deletes the
older releases so only the latest is there). Both are standalone -
no checkout needed. The release carries `config/`, `lib/` and `platforms/`
inside the app and copies them out on first launch to a working copy at
`~/Library/Application Support/dev.alx.loadout/repo`, which is where its
scripts then read and write. Each app update refreshes that copy without
deleting anything already in it, so local state survives.

A git checkout at `~/Developer/ops/ops-loadout` takes precedence over the
copied one, so development still edits the repo live.

**Check for Updates...** in the tray menu pulls the next release: it asks the
GitHub release for the newer build, and on your go-ahead downloads, installs
and relaunches the app in place.

The app is not notarized by Apple, so macOS reports a downloaded copy as
"damaged and can't be opened". Drag it to Applications, then either allow it
under System Settings > Privacy & Security > Open Anyway, or run this once:

```bash
xattr -dr com.apple.quarantine "/Applications/Loadout.app"
```

Updates installed from the tray menu's **Check for Updates** don't need it
again; only a fresh download does.

Once installed, use the app instead of the CLI:
- **Apps tab** — browse, launch and install/update packages (Homebrew, Mac App
  Store, installer scripts, winget, GitHub releases), mirroring
  `formulae`/`casks`/`mas`/`packages`.
- **Updates tab** — outdated packages, then the non-package stages:
  prerequisites, dotfiles, CLI logins (`gh`, `tea`), system defaults, (Windows)
  debloat and (macOS) cleanup, backed by the same status/apply scripts the CLI
  uses.

The CLI documented below remains available and is what the app and this guide
both build on.

## Features

- **Profile-based configuration**: Different setups for personal vs work devices
- **Modular commands**: Run specific components (homebrew, dotfiles, defaults)
- **Idempotent**: Safe to run multiple times
- **Dry-run mode**: Preview changes before applying
- **Dotfiles management**: Symlinked configs with backup support
- **Status checking**: List commands show what's installed vs missing
- **Strict profile validation**: Profiles fail fast when used on the wrong OS

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

### Workstation (`--profile workstation`)

Work Mac, driven from Loadout: Blender, Houdini, ComfyUI Desktop, Fork, Ghostty, Loadout WM, Swish and Vorssaint (installer scripts) plus the core and shell CLI formulae, no casks, no MAS apps, no system preferences. Terminal dotfiles (zsh, bash, starship, Ghostty) and the Loadout WM rules apply, with the existing zshrc backed up and `~/.zshrc.local` for work-only lines; gitconfig is left alone.

### Linux (`--profile linux`)

Full dev station setup for Debian/Ubuntu Linux including core tools, shell enhancements, and web development stack.

### Windows (`--profile windows`)

Gaming workstation setup for Windows: winget apps, GitHub-release apps,
installer scripts (Blender, Houdini, NVIDIA app), ComfyUI custom nodes,
dotfiles (git, WezTerm, GlazeWM) and system preferences, with optional
bloatware removal.

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
.\setup.ps1 packages           # winget, GitHub releases + ComfyUI custom nodes
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
--profile <name>    Use specified profile (personal, workstation, linux)
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
python3 tests/bash/download_progress.py  # real curl streaming regression
python3 tests/bash/blender_install.py    # isolated macOS install/rollback regression
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
- `mas/*.txt` - Mac App Store apps (`ID|Name` format)
- `installers/*.txt` - Apps with no cask, `token | display-name | homepage`.
  Each token is a script `platforms/macos/installers/<token>.sh` that takes
  one of `status|install|update|reinstall|uninstall`; `status` prints the
  `.app` path and exits 0 when installed. Only Loadout runs these, not
  `setup.sh`. Root work goes through `sudo -A`.
  - `houdini` - latest production build via the SideFX download API, or the
    latest of a pinned `X.Y`. The API key, license mode (Apprentice, Indie or
    license server) and version pin are set in Loadout's Settings dialog
    (gear icon) and stored in `config/sidefx.local`. License server mode runs
    `hserver -S`; Apprentice and Indie are activated in Houdini's License
    Administrator, which a dialog explains after installing. SideFX Labs is
    installed alongside, per Houdini `X.Y`. Older versions are left in place
    on update, and the tile menu has an Open row for each installed build.
  - `blender` - latest Blender into `/Applications`, with its portable config
    dir symlinked to `config/dcc/blender/` so prefs, startup file, keymap and
    extensions are tracked in this repo. See that directory's README.

**Linux** (`config/packages/linux/`):
- `apt/*.txt` - APT packages (Debian/Ubuntu only)

**Windows** (`config/packages/windows/`):
- `winget/*.txt` - winget packages, `Winget.Id | name`, where `name` is the
  tile name and the Start Menu shortcut launched for it (default: the id after
  its first dot). Install state comes from `winget list`, which also finds apps
  installed by other means, so winget upgrades those in place.
- `github/*.txt` - Apps published only as GitHub release assets, for the
  handful with no winget package. Pipe-delimited:
  `owner/repo | asset-pattern | display-name | install-args`, where every field
  after the repo is optional (defaults: `*.exe`, the repo name, `/quiet`).
  Install state is read from Add/Remove Programs, and an app already present is
  upgraded when the latest release is newer (semver-aware, so `1.18.4` beats
  `1.18.3-beta.7`). `-Force` reinstalls regardless.
- `installers/*.txt` - Apps installed by a script of their own,
  `token | display-name | homepage`, the same shape as on macOS. Each token is
  `platforms/windows/installers/<token>.ps1`. Blender, Houdini and the NVIDIA
  app live here.
- `comfynodes/*.txt` - ComfyUI custom nodes, `owner/repo | directory-name` (the
  directory defaults to the repo name). Cloned into every local ComfyUI
  backend's `custom_nodes/`, with `requirements.txt` installed into that
  backend's own `.venv`, whenever ComfyUI Desktop is installed or updated
  (no tile of their own). Existing nodes are skipped; updating ComfyUI
  fast-forwards them. Skipped entirely on a machine with no ComfyUI.

### Local Overrides

Machine-specific settings go in `.local` files (not tracked by git):
- `~/.zshrc.local` - Shell customizations
- `~/.gitconfig.local` - Git user info and signing key
- `config/sidefx.local` - SideFX web API credentials for the Houdini installer

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
ops-loadout/
├── setup.sh                    # Entry point (macOS/Linux)
├── setup.ps1                   # Entry point (Windows)
├── app/                        # Loadout (Tauri desktop app)
├── wm/                         # Loadout WM (window manager, macOS + Windows)
├── lib/                        # Shared libraries
│   ├── common.sh               # Colors, logging
│   ├── detect.sh               # OS detection
│   ├── prompt.sh               # User interaction
│   ├── symlink.sh              # Symlink utilities
│   ├── dotfiles.sh             # Dotfiles install, gh/tea logins
│   ├── packages.sh             # Package parsing
│   ├── tasks.sh                # Status/apply verbs behind the Updates tab
│   └── windows/                # PowerShell modules
│       ├── common.psm1         # Logging, profile parsing
│       ├── dotfiles.psm1       # Symlink management
│       ├── packages.psm1       # winget/GitHub-release/ComfyUI-node helpers
│       ├── registry.psm1       # Idempotent registry writes
│       └── ...                 # Per-app modules (Blender, Houdini, ComfyUI, ...)
├── config/
│   ├── profiles/               # Profile configs
│   ├── packages/
│   │   ├── macos/              # macOS package lists
│   │   │   ├── formulae/       # CLI tools
│   │   │   ├── casks/          # GUI apps
│   │   │   ├── mas/            # App Store apps
│   │   │   └── installers/     # Apps installed by script
│   │   ├── linux/              # Linux package lists
│   │   │   └── apt/            # APT packages
│   │   └── windows/            # Windows package lists
│   │       ├── winget/         # winget packages
│   │       ├── github/         # GitHub release installers
│   │       ├── installers/     # Apps installed by script
│   │       └── comfynodes/     # ComfyUI custom nodes
│   ├── dcc/                    # Blender and Houdini config
│   ├── dotfiles/               # Configuration files and manifests
│   ├── wallpapers/             # Desktop pictures
│   └── presets.txt             # App groups Loadout launches together
└── platforms/
    ├── macos/                  # macOS-specific scripts
    │   ├── setup.sh            # Orchestrator
    │   ├── homebrew.sh         # Package installer
    │   ├── defaults.sh         # Preferences loader
    │   ├── defaults/           # Individual preference scripts
    │   └── installers/         # Installer scripts
    ├── linux/                  # Linux-specific scripts
    │   ├── setup.sh            # Orchestrator
    │   ├── packages.sh         # APT package installer
    │   ├── repositories.sh     # Third-party repos (NodeSource, etc.)
    │   └── extras.sh           # Extra tools (starship, eza, etc.)
    └── windows/                # Windows-specific scripts
        ├── setup.ps1           # Orchestrator
        ├── packages.ps1        # winget, GitHub releases + ComfyUI custom nodes
        ├── dotfiles.ps1        # Symlink installer
        ├── defaults.ps1        # Preferences loader
        ├── defaults/           # Individual preference scripts
        ├── installers/         # Installer scripts
        └── debloat.ps1         # Bloatware removal
```

## Loadout

`app/` is a small Tauri desktop app that shows every package in
`config/packages/` as an icon grid, launches the installed ones and installs
the missing ones by shelling out to the same package managers `setup.sh` uses.

```bash
./setup.sh launcher         # build and copy "Loadout.app" into /Applications
./setup.sh launcher build   # bundle to app/src-tauri/target/release/bundle/
./setup.sh launcher dev     # run against the local checkout
```

Each installs Homebrew, `node` and `rust` if they are missing, then runs
`npm install` (Tauri CLI only, no frontend dependencies).

It finds this repo through `OPS_LOADOUT_DIR`, then the path saved in its own
config directory, then the checkout it was built from, then
`~/Developer/ops/ops-loadout`, then the copy seeded from its own bundle, and
asks with a folder picker if none of those work. Package lists are read at runtime: edit a `.txt` and hit refresh.

## Loadout WM

`wm/` is a small window manager for macOS and Windows. Apps listed in
`config/dotfiles/wm/rules.txt` get their normal windows filled to the screen
with a padding, either stacked (`fill`), only the first one (`first`) or side by side (`split`).
Everything else floats untouched. There are no virtual workspaces: each listed
app is its own, reached by switching to it as usual. Install it from its
Loadout tile (it ships with each release), apply the `wm` dotfile, allow it
under Accessibility on macOS, and on Windows quit GlazeWM first. Edits to the
rules apply without a restart.

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

**ComfyUI doesn't see the model library** - `windows.conf` leaves
`COMFYUI_MODEL_PATH` empty, so the library is set up by hand in ComfyUI. When
it is set, the `extra_model_paths.yaml` for it is written with every ComfyUI
install or update (from Loadout or `.\setup.ps1 packages`), and only once
ComfyUI Desktop has run its first-time setup and the path is reachable. Launch
ComfyUI once, update it from Loadout, then restart ComfyUI.

**Windows power/telemetry settings skipped** - `defaults` writes those to HKLM.
Run PowerShell as Administrator to apply them.

**Preferences not applying** - Some preferences require a logout/login or restart to take effect. `.\setup.ps1 defaults -Force` restarts Explorer for you.
