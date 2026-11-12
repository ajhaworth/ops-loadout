---
paths:
  - "**/*.ps1"
  - "**/*.psm1"
---

# PowerShell (Windows)

Moved out of the root `CLAUDE.md`; loads when you touch any PowerShell file.
Subsystem detail stays in `lib/windows/CLAUDE.md` and `platforms/windows/CLAUDE.md`.

## Code style

- Library modules in `lib/windows/` (`.psm1` files) with explicit `Export-ModuleMember`
- A native command inside a function that returns `$true`/`$false` pipes to
  `Write-NativeOutput` (`& tool 2>&1 | Write-NativeOutput`). Left uncaptured its
  output joins the return value, and `-not @('text', $false)` is `$false` - the
  job then reports success when it failed
- `-DryRun` switch parameter threaded through function calls (not a global variable)
- Profile parsed into hashtable by `Read-Profile`, checked with `Test-ProfileFlag`

Stages report failures through exit codes: each stage script exits non-zero when
anything failed, `platforms/windows/setup.ps1` counts failing stages without
aborting the run, and the root `setup.ps1` propagates the final code.

## Traps

**Never name a PowerShell parameter `-Profile`.** `$PROFILE` is an automatic
variable, and a parameter of that name shadows it for the whole script. The
Windows scripts take `-ProfileName` with a `-Profile` alias for compatibility.
For the same reason, never assign to `$HOME` — it is read-only and assigning
throws at runtime.
