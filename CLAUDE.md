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
- `workstation.conf` - Work macOS device: Blender, Houdini, Fork, Ghostty and core CLI tools, from Loadout
- `linux.conf` - Full dev station setup for Linux (Debian/Ubuntu)
- `windows.conf` - Gaming workstation setup for Windows

Two profile-wide switches sit above the per-category flags. `PROFILE_HOMEBREW="false"`
disables every formula, cask and MAS app at once, makes `homebrew.sh` and
Loadout's prerequisites row skip Homebrew entirely, and stops Loadout
executing `brew`/`mas` at all - not even for status - so a Mac without Homebrew
never sees a "command not found". `INSTALLERS_<CATEGORY>` gates
`config/packages/macos/installers/<category>.txt` the same way `CASKS_*` gates
casks. `workstation.conf` keeps Homebrew (core and shell formulae only, no
casks, no MAS) and leaves `installers/3D.txt` (Blender, Houdini) and
`installers/development.txt` (Fork, Ghostty) visible; the user installs those
by hand from the Loadout tiles. Apps added for the work Mac go in as installer
scripts, not casks, so the allow-list stays explicit.

`.github/workflows/release.yml` builds Loadout for every `v*` tag - the
macOS dmg on a macOS runner and the Windows installer on a Windows runner - and
attaches both to a GitHub Release (`tauri-apps/tauri-action`).
It is unsigned, so README tells downloaders to use Open Anyway or clear the
quarantine flag. The app still needs the repo checkout for its UI and scripts.

### Package Lists

Packages are defined in text files under `config/packages/` — one package per line, comments start with `#`.

- `macos/formulae/*.txt` / `macos/casks/*.txt` - Homebrew CLI tools and GUI apps
- `macos/mas/*.txt` - Mac App Store apps (`ID|Name` format); one list per category like casks, all gated by `PROFILE_MAS`
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
install records its tag under `HKCU:\Software\ops-loadout\GitHubReleases`
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

### macOS Installer Scripts

`config/packages/macos/installers/*.txt` (`token | display-name | homepage`)
lists apps with no Homebrew cask. Each token is
`platforms/macos/installers/<token>.sh`, taking one of
`status|install|update|reinstall|uninstall`: `status` prints the `.app` (or
package directory) path and exits 0 when installed, and must stay fast and
offline because Loadout runs it at startup. Only Loadout consumes
this kind (`catalog.rs` kind `installer`, `platform/macos.rs`); `setup.sh`
does not. Root work goes through `sudo -A` so Loadout's askpass dialog
can answer it.

`houdini.sh` resolves the latest production build through the SideFX download
API, which needs `config/sidefx.local` (`SIDEFX_CLIENT_ID`,
`SIDEFX_CLIENT_SECRET`; gitignored via `*.local`). Loadout's Settings
dialog writes that file (`get_settings`/`set_settings` in `main.rs`); the
script only reads it and points at Settings when it is missing. The dmg holds
`Houdini.pkg`, installed with `installer -pkg ... -target /`. The Apprentice
license cannot be scripted: a post-install dialog explains the License
Administrator -> "Activate Apprentice" step and offers to open Houdini; no
account is required. That dialog is shown only when `SUDO_ASKPASS` is set,
which Loadout alone does, so it doubles as "a GUI is present".
`outdated` is never set for this kind; Update simply installs the latest.
`sidefxlabs.sh` takes Labs from GitHub releases (tags match Houdini
`X.Y.ZZZ`) into `~/Library/Preferences/houdini/<X.Y>/packages/`
and records the tag in `.ops-tag` for its own already-current check.

### DCC Configs (`config/dcc/`)

`config/dcc/<app>/` holds a DCC application's own config, tracked here; one
installer script per app installs the app and links that directory into it.

**Blender.** `platforms/macos/installers/blender.sh` installs the portable
build into `/Applications/Blender.app` and symlinks
`Contents/Resources/portable` -> `config/dcc/blender/portable`. Blender treats a
`portable/` dir beside its resources as its config root, so everything it saves
(prefs, startup file, keymap presets, extensions) lands in the repo and shows in
`git status`; that directory's own `.gitignore` filters the noise (`extensions/`,
`cache/`, `recent-*.txt`, `platform_support.txt`, `scripts/addons/`,
`bookmarks.txt`). `status` requires that symlink, so a cask-installed or
hand-downloaded Blender reads as *not installed* and `install` refuses to
replace it rather than `rm -rf`-ing someone else's app.

- **Update reapplies setup.** Download only if the resolved version is newer;
  a failed version check keeps a usable installed build and still runs setup.
  Reinstall explicitly forces the download. Every successful app-selection path
  relinks portable scripts, installs missing extensions, re-enables configured
  extensions, and runs windowed `setup.py` to regenerate the managed preferences,
  keymap, and startup layout. Extension failures do not skip the remaining setup.
- **The real config is binary.** `portable/config/startup.blend` and
  `userpref.blend` are the source of truth for scene/UI/prefs and are committed
  as binaries. They are *generated* by `setup.py`: edit `setup.py` and re-run
  `bin/blender --python setup.py` (windowed, not `-b` — it needs a live window
  to walk the workspaces), then commit both `.blend` files.
- **The keymap lives in `dcc.py`.** `portable/scripts/presets/keyconfig/dcc.py`
  is a full preset (Industry Compatible plus our edits) and the source of truth;
  `setup.py` activates it. Change keys in Preferences > Keymap, run
  `bin/keymap-export`, commit. Export must run windowed too: headless Blender
  never activates the preset, so it would export the stock keymap. No per-hotkey
  Python; operators the keymap calls that Blender lacks live in
  `portable/scripts/startup/`, which Blender auto-loads.
- **Extensions are declared, not committed.** `extensions.txt` lists
  `blender_org <id>`, `github <owner/repo>` or `forgejo <host/owner/repo>` lines
  (Forgejo serves the same releases API under `/api/v1`); the installer puts them
  in the ignored `portable/extensions/`. GitHub/Forgejo entries prefer the latest
  release `.zip` asset and fall back to the repo zipball, which is re-zipped
  because zipballs unpack to `owner-repo-sha/` — not a valid module name. An optional
  third field gives the manifest id, allowing installed plugins to be reused offline.
- **Download mirror.** `ftp.nluug.nl` rather than `download.blender.org`, which
  sits behind a Cloudflare JS challenge (`mirrors.dotsrc.org` started 403ing
  listings in Sep 2026).
- **MCP.** `extensions.txt` installs the official Blender Lab MCP add-on, which
  autostarts a socket on localhost:9876 when Blender opens. The installer's last
  step re-registers the `blender` server at Claude Code user scope, run via `uvx`
  from upstream git so it is never vendored (skipped without `claude` + `uvx`).
  Blender must be open for the tools to work.
- **Keymap viewer.** `keymap.html`/`keymap.js` are served by Loadout at
  `loadout://localhost/dcc/blender/keymap.html` (`serve_ui` maps `dcc/*` to
  `config/dcc/*`) and opened from the Blender tile's Keymap menu item. They read
  `dcc.py` at runtime — never export a JSON copy, one source of truth.

**Who Blender's config is for: an environment artist.** Weigh every config,
hotkey and extension decision against environment-art work: modeling, placement,
snapping, asset workflows. Leave out animation features (keyframes, timeline,
frame stepping), as `setup.py` already does by dropping the Animation workspace
and closing timelines. Industry Compatible is the keymap base only because it is
the closest stock preset — never justify a setting or a key by "that's how Maya
or Max does it", justify it by what it does for environment work. Target engine
is Unreal (scene displays centimeters, 1 BU stays 1 m).

**Houdini.** `platforms/macos/installers/houdini.sh` writes
`~/Library/Preferences/houdini/<X.Y>/packages/loadout.json` pointing at
`config/dcc/houdini`, putting it on `HOUDINI_PATH` so `desktop/` and `otls/`
auto-load; new HDAs go straight into `otls/`. It also sets
`general.desk.val := "ALX";` in that version's `houdini.pref`, replacing an
existing line or appending one, so Houdini opens on the repo's desktop layout.
Both are reapplied on every successful install and on Update's
already-latest short-circuit, so a version bump or a config edit both take
effect without a reinstall. Houdini's own "Save Current Desktop" writes to
the user prefs `desktop/`, not the repo — copy that file back into
`config/dcc/houdini/desktop/` to keep a layout change. A sample scene lives in
`examples/`.

**Asset library.** `config/dcc/blender/assets/` is registered by `setup.py`
as Blender asset library "Loadout" (the Layout asset browser shows all
libraries; `params` is unset while `setup.py` runs, so it cannot pin one). `assets/build.py` (run via `bin/blender -b --factory-startup
--python assets/build.py`) regenerates `reference.blend` from
`assets/reference/*.fbx`, each FBX becoming an asset collection in the
"Reference" catalog. Add assets by extending `build.py` or by dropping
already-marked `.blend` files into `assets/`.

### Loadout (`app/`)

Named "Ops Launcher", then "Launchbay" (2026-09-21), then "Loadout"
(2026-09-22) - the repo went `ops-workstation` -> `ops-desktop` -> `ops-loadout`
alongside it. "Launcher" was retired because launching is the smallest thing
this does: it tracks the apps a workstation runs, installs them, and configures
them and the OS around them.

Each identifier change (`dev.alx.ops-launcher` -> `dev.alx.launchbay` ->
`dev.alx.loadout`) strands the previous install: the app config dir, the seeded
repo copy and the Launch-at-Login agent are all keyed off the identifier, so
settings reset and the old `.app` has to be deleted by hand. The tray updater
was stranded too, because it looked for the *running* bundle's file name inside
the downloaded dmg - `update.rs` now takes whatever single `.app` the dmg
contains, so the next rename updates in place. A machine still on Launchbay
predates that fix and needs one manual download.

The Tauri desktop app the README calls the primary interface. Plain
HTML/CSS/vanilla JS in `app/ui/` (no framework, no bundler; `frontendDist`
points straight at `../ui`) over a Rust backend in `app/src-tauri/src/`:

- `main.rs` — Tauri commands (`list_apps`, `refresh`, `install`/`update`/
  `uninstall`/`reinstall`, `launch`, `tasks_status`, `run_task`,
  `get_settings`/`set_settings`, ...), invoked from `main.js` as
  `window.__TAURI__.core.invoke("<name>")`. Job output streams over
  `install-log`/`install-done` events.
- `catalog.rs` — pure parser of `config/packages/**` into `App` structs; never
  shells out. Kinds: `formula`, `cask`, `mas`, `installer` (macOS) and
  `github`, `comfynode` (Windows). `scan` reads every list file;
  `filter_by_profile` then drops what the profile saved in Settings disables,
  using the same `<PREFIX>_<CATEGORY>` / `PROFILE_MAS` / `PROFILE_HOMEBREW`
  semantics as the bash side, before `hydrate` runs. `hydrate` only shells to
  `brew`/`mas` when the filtered set still contains an app of that kind. With
  no profile saved Loadout opens Settings first so one gets picked.
- `platform.rs` picks `platform/macos.rs` or `platform/windows.rs` by
  `cfg(target_os)`; Linux is a stub that errors. macOS talks to `brew`/`mas`/
  the installer scripts directly. Windows shells *everything* to
  `app/src-tauri/bridge.ps1` (verbs: `status|install|uninstall|update|icon|
  launch|open|tasks-status|tasks-apply`), which is bundled as a Tauri
  resource so the built app can find it. Package/task logic lives in
  `lib/windows/*.psm1`, not in the bridge or in Rust — add features there.

The UI is served off disk, not from the binary. `serve_ui` in `main.rs`
registers a `loadout://` scheme (`http://loadout.localhost` on Windows, hence
`tauri.windows.conf.json` restating the window URLs) that reads
`<repo>/app/ui/<path>` and falls back to the embedded `frontendDist` copy when
the repo isn't found. So HTML/CSS/JS edits and `git pull` reach the installed
app on the next window load; only Rust changes need `./setup.sh launcher`.

Repo discovery (`find_repo`): `OPS_LOADOUT_DIR` → saved config → the checkout
it was built from → `~/Developer/ops/ops-loadout` → the copy seeded from the
bundle → folder picker. Settings (`repo`, `profile`) persist in the app config
dir as `config.json`; the SideFX credentials go to `<repo>/config/sidefx.local`
at mode 0600.

**A release ships the repo content, so a downloaded app needs no checkout.**
`app/scripts/bundle-repo.js` (npm `bundle-repo`, run by `beforeBuildCommand` in
`tauri.conf.json` on every `tauri build`, local or CI) stages `config/`, `lib/` and `platforms/`
into the gitignored `app/src-tauri/bundled/` via `git archive HEAD` plus tracked working-file edits — tracked
files only, so gitignored Blender extensions and `*.local` can never ship — and
`tauri.conf.json` bundles it as a resource.

`seed_bundled_repo` copies that out to `<app data>/repo` on launch, because the
scripts write back into the repo (`config/sidefx.local`, Blender's portable
prefs) and editing the .app would break its ad-hoc seal. `.bundled-version`
holds the app version and content revision: a mismatch re-copies, preserving existing
Blender `.blend` preferences/startup files and overwriting other tracked files but
**never deleting**, so local state survives an update. The seed runs before the
candidate list is walked, since a saved path pointing at the seeded copy matches
earlier. A real checkout still wins, so development is unaffected -
`OPS_LOADOUT_DIR=bundled` forces the seeded copy instead, unsaved, for testing a
release build on a machine that has one. The seeded
copy has no `app/` — `serve_ui` finds no file there and falls back to the
embedded UI, which is the built-in behaviour.

**Self-update.** The tray's "Check for Updates..." (`src/update.rs`) asks the
GitHub releases API for the latest release and compares its tag with the running
version. On macOS it `curl`s the `.dmg`, mounts it with `hdiutil` and replaces
the running bundle with `ditto`, then `AppHandle::restart` - no
tauri-plugin-process, since restart is core Tauri. On Windows it runs the NSIS
`.exe` with `/P /R` (passive install, relaunch) and exits. `release.yml` builds
dmg on macOS and nsis on Windows, and its `prune` job deletes every other
release and tag, so only the latest exists; GitHub's automatic "Source code"
archives are attached to a release regardless and cannot be removed. Nothing is
signed - neither by Apple nor minisign. The check compares against the running
app's version, so an unbumped release is invisible to it - see Versioning.

**Versioning.** Every change that reaches main and touches something a release
ships gets a version bump: `app/`, `config/`, `lib/`, `platforms/` (the bundle),
plus `setup.sh`/`setup.ps1`. That includes package-list edits, installer
scripts, DCC configs, keymaps and `.blend` prefs - a downloaded app sees none of
it until a new version exists. No bump for docs (`README`, `CLAUDE.md`),
`tests/`, or CI-only changes. One bump per merge to main, not per commit on the
branch: bump as the branch's last commit, before review.

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
`vX.Y.Z` tag push, which runs `release.yml` - push it only after the signed-off
merge.

`capabilities/default.json` grants no shell/fs plugin permissions: all process
execution is native `std::process::Command`, so the capabilities file does not
gate it. The CSP allows no external scripts or styles; images only from
`data:` and Google's favicon hosts. `src-tauri/gen/` and `target/` are build
output and gitignored.

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

Sections: `prereq`, `dotfiles`, `defaults`, `debloat` (Windows only).

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

Each `apply_<name>()` is built from two declarative helpers in `lib/tasks.sh`:
`defaults_set <domain> <key> <type> <value> <label>` compares the current
`defaults read` value against the desired one and writes only on a mismatch;
`defaults_hook <hook-id> <label> <check-cmd> <apply-cmd>` covers anything that
isn't a scalar `defaults write` (an `-array` write, a `chflags`, a `mkdir -p`).
Both branch on the same code path for status (writes off) and apply, per
"Setup Tasks (Loadout)" above - there is no separate checker to keep in sync.

### Windows Defaults

Same pattern in PowerShell. `platforms/windows/defaults/*.ps1` each define an
`Apply-<Name>` function (`explorer.ps1` → `Apply-Explorer`, mapped by
`Get-ApplyFunctionName`), discovered and invoked by `platforms/windows/defaults.ps1`.

Registry writes go through `lib/windows/registry.psm1` (`Set-RegistryValue`,
`Set-RegistryValueSet`, `Remove-RegistryKey`), which is idempotent, dry-run
aware, and buckets every setting into `Changed`/`Skipped`/`Pending`/`Failed`/
`NeedsAdmin` (`Get-RegistryResults`). `debloat.ps1` uses the same helpers.
Each bucket entry is `@{ Id; Label; Detail }`, not a bare string — `Id` is the
stable `"$Path\$Name"` (or bare `$Path` for `Remove-RegistryKey`) that
Loadout's Setup tab uses to target one setting.

A `-DryRun` write that would change something lands in `Pending` rather than
`Skipped`, so Loadout's tasks-status (see "Setup Tasks (Loadout)") can
tell "already correct" from "would change this" without a second checker.

Not every setting is a registry write. `Invoke-TrackedStep -Id -Label -Check
-Apply [-RequiresAdmin]` is the Windows counterpart of macOS `defaults_hook`:
the caller supplies a check and an apply, and gets a row in those same buckets,
so a `powercfg` call appears in the Setup tab like any registry value. `-Check`
runs first, so an already-correct step reports `Skipped` even unelevated;
`-RequiresAdmin` only decides what a step that *would* change something reports
when the run is not elevated (`NeedsAdmin`, rather than the whole module
reporting nothing). It honours the same `Set-RegistryOnlyId` filter as the
registry helpers. `power.ps1` routes its four powercfg timeouts through it -
without that they produced no rows at all, and a non-elevated run made the
module vanish from the Setup tab instead of asking for elevation.

`Label` states the *outcome*, not the registry value — `HideFileExt = 0` is
labelled "Show file extensions". So the log prints the label alone; printing
`Show file extensions = 0` reads as the exact opposite of what happened. Dry-run
still shows the key and value, since that output exists to be verified against.

Access-denied errors are reported as "needs Administrator" and land in
`NeedsAdmin`, not `Failed` (`Test-AccessDeniedError`) — the CLI's own summary
still counts them alongside `Skipped` as unchanged. Policy branches like
`HKCU:\SOFTWARE\Policies` require an elevated token despite living under HKCU,
so a non-elevated run legitimately cannot write them.

`Set-RegistryOnlyId` (module-scoped, cleared by passing `$null`) restricts
`Set-RegistryValue`/`Remove-RegistryKey` to a single id, no-oping everything
else without recording it. That is how Loadout applies one setting from
a defaults module that writes several: it re-runs the whole module with the
filter set, so every other setting in it is inert. `Invoke-DefaultsModules`
(also in `registry.psm1`) is the discovery-and-invoke loop itself — the one
place that walks `platforms\windows\defaults\*.ps1`, gates each file by its
`DEFAULTS_<NAME>` flag, and calls `Apply-<Name>`. `defaults.ps1` (the CLI) and
`bridge.ps1` (Loadout) both call it rather than each keeping their own
copy of that loop. `-Narrate` prints the per-module header inline as the loop
goes - the CLI passes it, Loadout does not. It has to be inline: narrating
from a second loop afterwards puts every header below the output it belongs to.

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
./setup.sh --dry-run --profile workstation  # Preview changes
./setup.sh dotfiles                  # Dotfiles only
./setup.sh dotfiles ls               # Check symlink status
./setup.sh homebrew                  # All Homebrew packages (macOS)
./setup.sh formulae                  # CLI tools only (macOS)
./setup.sh casks                     # GUI apps only (macOS)
./setup.sh defaults                  # System preferences (macOS)
./setup.sh packages                  # APT packages (Linux)
./setup.sh launcher                  # Build app, install to /Applications
./setup.sh launcher dev              # Run app against this checkout
./setup.sh launcher build            # Bundle only

bash tests/bash/smoke.sh             # Smoke tests
(cd app/src-tauri && cargo test)     # Rust unit tests
(cd app/src-tauri && cargo test -- --ignored --nocapture)  # + live repo scan
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
.\setup.ps1 launcher                 # Build app (nsis) and install

pwsh tests\windows\smoke.ps1         # Smoke tests
```

The smoke tests run on any platform: syntax, helper-function and
config-consistency checks work everywhere, and the dry-run invocations are
skipped off Windows. Both suites are flat scripts with no single-test
selector; run one check by commenting out the rest. `smoke.ps1` also parses
`bridge.ps1` and asserts its verb set. The Rust side is covered only by
`cargo test`.

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

app/ (Loadout, Tauri)
    ├── ui/ (static HTML/JS, no build step)
    └── src-tauri/src/main.rs → catalog.rs (parse lists), platform/{macos,windows}.rs
        ├── macOS: brew / mas / platforms/macos/installers/*.sh / lib/tasks.sh
        └── Windows: bridge.ps1 → lib/windows/*.psm1
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
