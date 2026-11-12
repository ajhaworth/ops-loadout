---
paths:
  - "config/dotfiles/**"
  - "lib/symlink.sh"
  - "lib/dotfiles.sh"
  - "lib/windows/dotfiles.psm1"
  - "platforms/windows/dotfiles.ps1"
---

# Dotfiles

Moved out of the root `CLAUDE.md`; loads when you touch the manifests, the
dotfiles themselves or the symlink code.

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

## Behaviour

**Backups are timestamped on both platforms.** Bash and PowerShell both move
replaced files into `~/.dotfiles_backup/YYYYMMDD_HHMMSS/`, one directory per
run, so history is preserved.

**Windows symlinks require Developer Mode or Administrator.** The dotfiles script tests symlink capability before proceeding.

**Manifest entries are skipped when their target app is missing.** If creating
the destination would require inventing more than one directory level,
`New-Symlink` skips the entry rather than fabricating something like
`AppData\Local\Packages\Microsoft.WindowsTerminal_*\LocalState\`. Use `-Force`
to override.
