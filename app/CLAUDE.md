# app (Loadout)

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
  `uninstall`/`reinstall`, `launch`, `tasks_status`, `run_task`, ...), invoked from `main.js` as
  `window.__TAURI__.core.invoke("<name>")`. Job output streams over
  `install-log`/`install-done` events.
- `catalog.rs` — pure parser of `config/packages/**` into `App` structs; never
  shells out. Kinds: `formula`, `cask`, `mas`, `installer` (macOS) and
  `winget`, `github` (Windows). `scan` reads every list file;
  `filter_by_profile` then drops what the profile saved in Settings disables,
  using the same `<PREFIX>_<CATEGORY>` / `PROFILE_MAS` / `PROFILE_HOMEBREW`
  semantics as the bash side, before `hydrate` runs. `hydrate` only shells to
  `brew`/`mas` when the filtered set still contains an app of that kind. With
  no profile saved Loadout opens Settings first so one gets picked.
- `platform.rs` picks `platform/macos.rs` or `platform/windows.rs` by
  `cfg(target_os)`; Linux is a stub that errors. macOS talks to `brew`/`mas`/
  the installer scripts directly. Windows shells *everything* to
  `app/src-tauri/bridge.ps1` (verbs: `status|install|uninstall|update|configure|
  icon|launch|open|tasks-status|tasks-apply`, plus `reinstall`; `status` takes an
  optional catalog id to answer for one app), which is bundled as a Tauri
  resource so the built app can find it. Package/task logic lives in
  `lib/windows/*.psm1`, not in the bridge or in Rust — add features there.
- `settings.rs` — `config.json`, repo discovery (`find_repo`), bundled-repo
  seeding and the `get_settings`/`set_settings` commands.
- `window.rs` — the `serve_ui` scheme handler and window commands
  (`open_full`, `open_page`, `hide_quick`).
- `update.rs` — tray self-update (see below).

The UI is served off disk, not from the binary. `serve_ui` in `window.rs`
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
**never deleting** - except what the bundle owns outright and no longer ships:
`config/packages/**/*.txt` (a renamed list would otherwise list its apps twice)
and any file under `lib/` and `platforms/` (scripts are discovered by listing
their directory, so a removed defaults module kept running from the seeded copy
as a permanently failed row) - see `prune` - so local state survives an update.
"Ships" means listed in `bundled/.bundle-files`, which `bundle-repo.js` writes,
not "present in the resource dir": the Windows NSIS installer updates in place
and never deletes a file a newer version dropped, so the resource dir keeps
old scripts forever (`Shipped`). The seed runs before the
candidate list is walked, since a saved path pointing at the seeded copy matches
earlier. A real checkout still wins, so development is unaffected -
`OPS_LOADOUT_DIR=bundled` forces the seeded copy instead, unsaved, for testing a
release build on a machine that has one. The seeded
copy has no `app/` — `serve_ui` finds no file there and falls back to the
embedded UI, which is the built-in behaviour.

**Self-update.** The tray's "Check for Updates..." (`src/update.rs`) reads the
latest tag from where `github.com/<repo>/releases/latest` redirects and compares
it with the running version, then downloads the asset by its tauri-action name
(`Loadout_<v>_aarch64.dmg`, `Loadout_<v>_x64-setup.exe`). **Not the REST API**:
its 60/hour unauthenticated limit is per IP and shared with every other GitHub
lookup on the network, and once spent it answered 403 on both platforms. On macOS it `curl`s the `.dmg`, mounts it with `hdiutil` and replaces
the running bundle with `ditto`, then `AppHandle::restart` - no
tauri-plugin-process, since restart is core Tauri. On Windows it runs the NSIS
`.exe` with `/P /R` (passive install, relaunch) and exits. `release.yml` builds
dmg on macOS and nsis on Windows, and its `prune` job deletes every other
release and tag, so only the latest exists; GitHub's automatic "Source code"
archives are attached to a release regardless and cannot be removed. Nothing is
signed - neither by Apple nor minisign. The check compares against the running
app's version, so an unbumped release is invisible to it - see Versioning.

**Background checks (macOS).** A thread started in `setup` waits 2 minutes, then
every 4 hours runs `brew update` (only when the catalog has formulae/casks -
`brew_env` sets `HOMEBREW_NO_AUTO_UPDATE`, so nothing else refreshes brew's
index), `rescan`s and emits `apps-changed`. It notifies (tauri-plugin-notification)
only when the outdated set is not a subset of the last notified one
(`should_notify`), so updating things never re-notifies, and once per new
Loadout release tag (`update::latest_release`, shared with the tray updater). It
skips ticks while the catalog is empty, so it never triggers repo discovery or
Settings. `set_dock_badge` also puts the count in the tray title, the only
visible signal while the app runs as an Accessory.

**Session presets.** `config/presets.txt` (`name | id id ...`, catalog ids)
launches a group of apps from a button row on the Apps tab or the quick panel.
Ids the profile drops or that are not installed are skipped; a preset with none
left is hidden. All but the first open with `open -g`; the first opens last so
it takes focus, and AeroSpace follows focus to its workspace.

**Quick-panel actions.** While the tray panel's search box has text it also
lists actions (Update all, Reapply Blender settings, Pull repo, Open repo in
Fork/Ghostty). Job actions open the main window and `emit("quick-action")`, so
their output streams into its log drawer; `pull_repo` refuses the seeded copy,
which has no `.git`.

`capabilities/default.json` grants no shell/fs plugin permissions: all process
execution is native `std::process::Command`, so the capabilities file does not
gate it. The CSP allows no external scripts or styles; images only from
`data:` and Google's favicon hosts. `src-tauri/gen/` and `target/` are build
output and gitignored.
