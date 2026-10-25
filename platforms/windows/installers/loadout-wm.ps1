# loadout-wm.ps1 - Loadout WM installer: status | install | update | reinstall | configure | uninstall
#
# Windows twin of platforms/macos/installers/loadout-wm.sh; the logic lives in
# lib/windows/loadout-wm.psm1. status prints the exe and exits 0 when
# installed, plus a second line `outdated` when it is not the version this
# checkout expects.

param(
    [ValidateSet('status', 'install', 'update', 'reinstall', 'configure', 'uninstall')]
    [string]$Verb = 'status'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'lib\windows\loadout-wm.psm1') -Force

switch ($Verb) {
    'status' {
        $status = Get-LoadoutWmStatus
        if (-not $status) { exit 1 }
        Write-Output $status.Exe
        if ($status.Outdated) { Write-Output 'outdated' }
    }
    'uninstall' { if (-not (Uninstall-LoadoutWm)) { exit 1 } }
    default { if (-not (Install-LoadoutWm -Action $Verb)) { exit 1 } }
}
exit 0
