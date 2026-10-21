# platforms/macos/installers

### macOS Installer Scripts

`config/packages/macos/installers/*.txt` (`token | display-name | homepage`)
lists apps with no Homebrew cask. Each token is
`platforms/macos/installers/<token>.sh`, taking one of
`status|install|update|reinstall|uninstall`: `status` prints the `.app` (or
package directory) path and exits 0 when installed, and must stay fast and
offline because Loadout runs it at startup. A script may also answer
`channels` (one build channel per line, the current one prefixed `* `; fast and
offline too, run on every right-click) and `channel <name>`, which saves the
choice and installs that build - Loadout then shows a "Build" section in the
tile's right-click menu. `moonlight.sh` does this (`release` = latest GitHub
release, the default; `nightly` = newest master build via `gh`), keeping the
choice in `~/Library/Application Support/ops-loadout/moonlight.channel`. Only Loadout consumes
this kind (`catalog.rs` kind `installer`, `platform/macos.rs`; Windows has its
own, see "Windows installer scripts"); `setup.sh`
does not. Root work goes through `sudo -A` so Loadout's askpass dialog
can answer it.

`houdini.sh` resolves the latest production build through the SideFX download
API, which needs `config/sidefx.local` (`SIDEFX_CLIENT_ID`,
`SIDEFX_CLIENT_SECRET`; gitignored via `*.local`). The same file carries
`HOUDINI_LICENSE` (apprentice|indie|server|server-core, default apprentice),
`HOUDINI_LICENSE_SERVER` and a `HOUDINI_VERSION` major.minor pin - all written
by Loadout's Settings dialog (`get_settings`/`set_settings` in `settings.rs`);
the script only reads it and points at Settings when the API credentials are
missing. `installed_app` picks the edition by `HOUDINI_LICENSE` (Apprentice,
Indie, FX for `server`, Core for `server-core`, falling back to Apprentice/FX so something
launches), and `installed_dir` picks the newest build matching the
`HOUDINI_VERSION` pin when one is set. A `versions` verb lists one edition
`.app` path per installed build, newest first, so Loadout can show a per-build
Open row when a pinned build coexists with a newer one. The dmg holds
`Houdini.pkg`, installed with `installer -pkg ... -target /`. The `.pkg` runs
as root and leaves that build's `~/Library/Preferences/houdini/<X.Y>`
root-owned, so `do_install` `chown -R`s it back to the invoking user right
after installing; `apply_config` also checks writability itself (a bare
`config` run, or an install from before that fix, hits the same problem) and
fails with the same `sudo chown -R $(id -un) ~/Library/Preferences/houdini`
message rather than silently no-oping. Every write in `apply_config_xy` and
`install_labs` is checked and only reports success once it lands - a failed
loadout.json/desk write fails `apply_config`, while SideFX Labs failing is
still just a warning. Apprentice/Indie licensing cannot be scripted: a
post-install dialog (text depends on `HOUDINI_LICENSE`) explains the License
Administrator step and offers to open Houdini; server mode instead points
`hserver` at `HOUDINI_LICENSE_SERVER` directly, with no dialog - `hserver`
ships inside the build itself
(`<build>/Frameworks/Houdini.framework/Versions/<X.Y>/Resources/bin/hserver`),
not under `/Library/Frameworks`. That dialog is shown only when
`SUDO_ASKPASS` is set, which Loadout alone does, so it doubles as "a GUI is
present".
`status` may print a second line, `outdated`, when the app's applied config has
drifted from the repo (Blender: `setup.py`/`extensions.txt` hash vs the
gitignored `config/dcc/blender/.configured` stamp written by a clean setup;
Houdini: `apply_config check`). There is no version check, so a newer release
is not flagged unless pinned; Update installs the latest (or pinned) build and
reapplies config either way. `apply_config` (the `config` verb, and what
install/update call) applies to every installed build's X.Y, not just the
pinned/status one. SideFX Labs installs from `houdini.sh` itself, one release
per Houdini X.Y (tags match Houdini `X.Y.ZZZ`) into
`~/Library/Preferences/houdini/<X.Y>/packages/`, recording the tag in
`.ops-tag` for its own already-current check - folded in from the standalone
`sidefxlabs.sh`, since Labs rides along with every installed Houdini X.Y
rather than being its own tile.

### Blender (`blender.sh`)

Blender's config side - the portable symlink, `setup.py`, the keymap, extensions - is in `config/dcc/CLAUDE.md`. `status` requires the `portable` symlink, so a cask-installed or hand-downloaded Blender reads as *not installed* and `install` refuses to replace it rather than `rm -rf`-ing someone else's app.

- **Update reapplies setup.** Download only if the resolved version is newer;
  a failed version check keeps a usable installed build and still runs setup.
  Reinstall explicitly forces the download. Every successful app-selection path
  relinks portable scripts, installs missing extensions, re-enables configured
  extensions, and runs windowed `setup.py` to regenerate the managed preferences,
  keymap, and startup layout. Extension failures do not skip the remaining setup.
- **Download mirror.** `ftp.nluug.nl` rather than `download.blender.org`, which
  sits behind a Cloudflare JS challenge (`mirrors.dotsrc.org` started 403ing
  listings in Sep 2026).
- **MCP.** `extensions.txt` installs the official Blender Lab MCP add-on, which
  autostarts a socket on localhost:9876 when Blender opens. The installer's last
  step re-registers the `blender` server at Claude Code user scope, run via `uvx`
  from upstream git so it is never vendored (skipped without `claude` + `uvx`).
  Blender must be open for the tools to work.

Houdini's package file, desk and MCP wiring are in `config/dcc/CLAUDE.md`.
