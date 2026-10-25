# lib/windows

Windows package, app-config and DCC logic. The thin scripts under `platforms/windows/` and `app/src-tauri/bridge.ps1` call into these modules. Repo-wide rules are in the root `CLAUDE.md`.

### winget Packages

Windows apps install through winget from Loadout (and `setup.ps1 packages`),
not Ansible - the user does not want Windows apps installed by Ansible. The
`ops-server` repo's `roles/windows/packages` predates this and still lists
many of the same ids. One package per line:

```
Winget.Id | name | installer args
```

`installer args`, optional, go to `winget --custom` on install/upgrade (GlazeWM
uses it to skip its bundled Zebar bar). `name` is the tile name *and* the Start Menu shortcut Loadout launches
(`Get-ShortcutTarget`), defaulting to the id after its first dot. The shortcut,
not Add/Remove Programs, is the launch target because ARP is unreliable for
it: Steam and GOG record their uninstaller as `DisplayIcon`, 1Password and
Nextcloud record nothing, and ARP names drift from the app name (P4V registers
as "P4 Apps").

Installed/outdated come from one `winget list` (`Get-WingetState`, ~2 s), keyed
on the id token in each row; an extra token for the Available column means
outdated, and a `<`/`>` version prefix is skipped. `winget list` correlates ARP
entries winget did not install, so Chocolatey-installed apps read as installed
and `winget upgrade` updates them in place. Install/update/uninstall run
`winget install|upgrade|uninstall --id <id> --exact --silent`; the exit codes
for "already installed"/"no applicable update" count as success
(`$script:WingetNoop`). No winget package exists for the NVIDIA app.

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
updater compares its internal version to the repo's git tags.
`lib/windows/vibepollo.psm1` disables the check by setting
`update_check_interval = 0` in `sunshine.conf` with every Vibepollo
install/update (`Invoke-AppConfig`), editing that one key, never the whole file.
The file is under Program Files and Loadout runs unelevated, so a key that needs
changing is written by one elevated child process - one UAC prompt, and none
once the key is set.)

Resolving the latest release requires the API, so this path is not offline —
but a failed lookup during `-DryRun` degrades to a notice rather than an error,
which keeps the smoke tests runnable without network access. `GITHUB_TOKEN` is
used when set, lifting the 60/hour unauthenticated rate limit.

`packages ls` reports only installed-or-not, without the API call.


These installers are not silent by contract the way winget and Chocolatey are:
the flags come from the entry, and a wrong flag means a GUI appears mid-run.
Verify a new entry interactively before trusting it in an unattended run.
### ComfyUI Custom Nodes

Nodes are ComfyUI's config, not apps: Loadout has no tile per node. They
install with the `Comfy.ComfyUI-Desktop` winget entry (`winget/creative.txt`) -
`bridge.ps1` calls `Install-ComfyNodeLists` after every install/update of it,
the way `blender.sh` applies Blender's extensions - and `setup.ps1 packages`
runs the same function after its winget stage. Lists stay gated by
`COMFYNODES_<CATEGORY>`; Loadout passes its saved profile to jobs as
`LOADOUT_PROFILE` for that. A fresh Desktop has no backend until launched once,
so the first install skips the nodes and says to update ComfyUI afterwards.

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
startup, so the stage warns to restart Desktop when it is running. Update on
the ComfyUI tile is the `-Force` path.

### ComfyUI Network Access

`Set-ComfyNetworkAccess` (`lib/windows/comfyui.psm1`) makes the backend reachable from the LAN, driven
by `COMFYUI_LISTEN` and `COMFYUI_PORT`:

- writes `--listen 0.0.0.0 --port <port>` into each install's `launchArgs` in
  `installations.json`, merging rather than replacing (`Merge-ComfyLaunchArgs`
  keeps `--enable-manager` and is idempotent across re-runs)
- opens inbound TCP on that port, scoped to `LocalSubnet` on `Private`
  networks. Needs Administrator and warns without it. An enabled inbound
  Allow rule that already covers the port (`Get-ComfyPortAllowRule`; this
  machine has one named `ComfyUI`, made outside this repo) counts as open and
  is left alone.

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
this machine includes the whole NAS share.

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

`Set-ComfyNetworkAccess` will not create the firewall rule unless one of
`Get-ComfyAuthNodeNames` is installed (`Test-ComfyAuthInstalled`). Binding
0.0.0.0 is inert while the firewall blocks the port, so the rule is the step
that actually publishes ComfyUI, and it is the one gated. The node lists install
just before it in the same hook, so this trips only when the node failed to
install. `COMFYUI_REQUIRE_AUTH` turns it off deliberately.

Adding another auth node means adding its directory name to
`Get-ComfyAuthNodeNames`, or the interlock will not recognise it. A smoke test
asserts that at least one recognised auth node is actually in the node list.

The rule stays LocalSubnet/Private rather than Any regardless — the login is
defence in depth, not a reason to widen the scope.
### Windows installer scripts

**Windows installer scripts.** Windows has the `installer` kind too:
`config/packages/windows/installers/*.txt` (`token | name | homepage`, gated by
`INSTALLERS_<CATEGORY>`), each token `platforms/windows/installers/<token>.ps1`
taking `status|install|update|reinstall|configure|uninstall` with the same
status contract as macOS (launch target, optional `outdated` line, exit 1 when
absent). The scripts are thin; the logic is in `lib/windows/<token>.psm1`.
`bridge.ps1` runs them for status and jobs, so the ids match macOS
(`installer:blender`, `installer:houdini`) and the UI's Blender menu items work
unchanged. `setup.ps1` does not run them, like `setup.sh` on macOS.

**Blender on Windows** (`blender.psm1`). Not winget: `BlenderFoundation.Blender`'s
manifest downloads from download.blender.org, which answers 403 (the same
Cloudflare block `blender.sh` avoids). The portable zip comes from the
`ftp.nluug.nl` mirror into `%LOCALAPPDATA%\Programs\Blender` (per user, no
admin; `loadout-version.txt` records the version), and `<that dir>\portable` is
a junction to `config/dcc/blender/portable` - Blender's portable mode, as on
macOS. Then extensions.txt, windowed `setup.py` (`blender.exe`, the console
build, so output streams; the tile launches `blender-launcher.exe`, which opens
no console) and MCP. The `.configured` stamp drives `outdated` as on macOS.
**Remove the portable junction before any recursive delete of the install
dir** (`Remove-Junction`): Windows PowerShell can follow it into the repo.
Module functions run under the global `Continue` error preference, not the
calling script's `Stop` - wrap calls whose failure must be counted in
try/catch. `dcc_claude.py`'s Ghostty button is macOS-only.

**Houdini on Windows** (`houdini.psm1`), a port of `houdini.sh`. Same SideFX
API and `config/sidefx.local` (written single-quoted by Settings, which
`Read-ConfFile` handles), platform `win64`. The `.exe` installer runs silently
and elevated (`Start-Process -Verb RunAs`: one UAC prompt) into
`Program Files\Side Effects Software\Houdini X.Y.Z`, with
`/AcceptEULA=2021-10-13`; success is judged by that dir existing, not the exit
code. Per X.Y the prefs live in `Documents\houdiniX.Y` (Known Folder path, so
OneDrive redirection is respected): `packages\loadout.json`, the ALX desk,
SideFX Labs and `fxhoudinimcp.json` (uv tool layout `Lib\site-packages`,
`Scripts\python.exe`). Editions are `bin\happrentice|hindie|houdinifx|houdinicore.exe`.
`Start-Process -ArgumentList` does not quote, so values with spaces are quoted by hand.

### ComfyUI

Installed as `Comfy.ComfyUI-Desktop` through winget (`winget/creative.txt`),
at its own default location. Every install/update (and the tile's Reapply
Settings) then runs `Invoke-AppConfig`: custom nodes, the model library and
LAN access, in that order, all in `lib/windows/comfyui.psm1`. A fresh Desktop
has no config until launched once, so the first install skips them and says to
update ComfyUI afterwards. Only the model library is redirected.

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

`Set-ComfyModelLibrary` writes that file from `COMFYUI_MODEL_PATH`. It:
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

`COMFYUI_MODEL_PATH` is empty in `windows.conf`: the user sets up the model
library by hand in ComfyUI, so this step skips and an existing
`extra_model_paths.yaml` is left as it is. Don't point it at a path again
without being asked.

The alias candidates in `Get-ComfyModelFolderMap` (`Stable-diffusion` →
`checkpoints`, `Lora` → `loras`, `ESRGAN` → `upscale_models`) are **kept
deliberately** even though nothing uses them now — they cost nothing and make the
module work against an A1111-style library on another machine.

`unet\` and `clip\` are left alone rather than folded into `diffusion_models\`
and `text_encoders\`. They are supported ComfyUI aliases, not mistakes:
`folder_paths.py` maps them via `map_legacy()`, and `add_model_folder_path()`
applies that to `extra_model_paths.yaml` keys too, so both directories are
searched under the canonical key.
