---
paths:
  - "config/profiles/**"
  - "config/packages/**"
  - "lib/common.sh"
  - "lib/packages.sh"
  - "lib/windows/common.psm1"
  - "lib/windows/packages.psm1"
  - "platforms/macos/homebrew.sh"
  - "platforms/macos/installers/**"
  - "platforms/linux/packages.sh"
  - "platforms/windows/packages.ps1"
---

# Profiles and package lists

Moved out of the root `CLAUDE.md`; loads when you touch profiles, package lists
or the code that reads them. The profile list and the "category variables
default to `true`" rule stay in the root file.

## Profile-wide switches

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

## Profile variable naming

Variables map to package directories via naming convention:
- `FORMULAE_CORE` → `config/packages/macos/formulae/core.txt`
- `GITHUB_GAMING` → `config/packages/windows/github/gaming.txt`
- Underscores in variable names map to hyphens in filenames: `FORMULAE_SOFTWARE_DEV` → `software-dev.txt`
- Conversion: `lib/common.sh:get_category_var()` (bash) / `lib/windows/common.psm1:Get-CategoryVar` (PowerShell)
