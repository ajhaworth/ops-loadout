# platforms/windows

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
Unelevated, a dry-run write under `HKLM:` or a `Policies` branch lands in
`NeedsAdmin` instead (`Test-RegistryWriteNeedsAdmin`), since that is what the
apply would hit.

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

`security.ps1` (`DEFAULTS_SECURITY`) is the hardening module: Remote
Assistance off, a 15-minute idle lock, `RestrictAnonymous`, PowerShell
script-block logging, and pinned values for LSA-PPL/WDigest/LLMNR, plus
tracked steps for Defender (ASR rules in Block mode, network protection, cloud
block level High), firewall drop logging, and scoping the Apollo/Vibepollo
installer's inbound rules (which it creates as Any address, Any profile) to
`LocalSubnet`/`Private`. The ASR list leaves out the PSExec/WMI and
"prevalence/age" rules, which fire on build tools and fresh installers.
`SECURITY_DISABLE_SPOOLER` (default false) adds a Print Spooler row. BitLocker
and Secure Boot are only warned about, never tracked: they need a recovery-key
decision and a firmware change, and a row whose apply does nothing would lie.
Controlled Folder Access is deliberately absent (it breaks DCCs and games), as
is anything ops-server's Ansible owns (its firewall rules and accounts).

Filenames map to profile variables like package lists: `taskbar.ps1` →
`DEFAULTS_TASKBAR`. `power.ps1` and the HKLM half of `privacy.ps1` need
Administrator and skip cleanly without it.

Every module is invoked as `Apply-<Name> -ProfileConfig $config -DryRun:$DryRun`,
so each must accept both parameters even if it ignores `-ProfileConfig`. The
smoke tests assert this — a missing parameter is a runtime binding error, not a
parse error. Note the name is `ProfileConfig`, not `Profile`, to avoid shadowing
the `$PROFILE` automatic variable.

Not every module writes to the registry; the "defaults" concept is machine/app preferences generally, mirroring
`platforms/macos/defaults/apps.sh`. Config that belongs to one app goes with
that app's install/update instead (`Invoke-AppConfig`, keyed on the winget id or
GitHub repo), not here - ComfyUI's model library and LAN access and Vibepollo's
`sunshine.conf` were defaults modules once, and showed up as
confusing Updates-tab rows that duplicated the app's own update.


Adding a module: define `Apply-<Filename>` in `platforms/windows/defaults/`, build `@{ Path; Name; Value; Type; Label }` entries for `Set-RegistryValueSet`, and add `DEFAULTS_<FILENAME>` to `config/profiles/windows.conf` - the smoke tests assert the file and the variable stay in sync. Test with `.\setup.ps1 defaults -DryRun`.
