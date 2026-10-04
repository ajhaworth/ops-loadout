# nvidia-app.ps1 - NVIDIA app installer: status | install | update | reinstall | configure | uninstall
#
# No winget package exists; lib/windows/nvidia.psm1 installs NVIDIA's own
# installer from its download page. status prints the app exe and exits 0
# when installed.

param(
    [ValidateSet('status', 'install', 'update', 'reinstall', 'configure', 'uninstall')]
    [string]$Verb = 'status'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'lib\windows\nvidia.psm1') -Force

switch ($Verb) {
    'status' {
        $status = Get-NvidiaAppStatus
        if (-not $status) { exit 1 }
        Write-Output $status.Exe
    }
    'uninstall' { if (-not (Uninstall-NvidiaApp)) { exit 1 } }
    default { if (-not (Install-NvidiaApp -Action $Verb)) { exit 1 } }
}
exit 0
