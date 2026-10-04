# blender.ps1 - Blender installer: status | install | update | reinstall | configure | uninstall
#
# Windows twin of platforms/macos/installers/blender.sh; the logic lives in
# lib/windows/blender.psm1. status prints the launch target and exits 0 when
# installed, plus a second line `outdated` when the applied config has drifted.

param(
    [ValidateSet('status', 'install', 'update', 'reinstall', 'configure', 'uninstall')]
    [string]$Verb = 'status'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'lib\windows\common.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\windows\blender.psm1') -Force

switch ($Verb) {
    'status' {
        $status = Get-BlenderStatus -RepoRoot $repoRoot
        if (-not $status) { exit 1 }
        Write-Output $status.Exe
        if ($status.Outdated) { Write-Output 'outdated' }
    }
    'uninstall' { if (-not (Uninstall-Blender)) { exit 1 } }
    default { if (-not (Install-Blender -RepoRoot $repoRoot -Action $Verb)) { exit 1 } }
}
exit 0
