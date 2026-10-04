# houdini.ps1 - Houdini installer: status | install | update | reinstall | configure | uninstall
#
# Windows twin of platforms/macos/installers/houdini.sh; the logic lives in
# lib/windows/houdini.psm1. status prints the edition exe and exits 0 when
# installed, plus a second line `outdated` when the applied config has drifted.

param(
    [ValidateSet('status', 'install', 'update', 'reinstall', 'configure', 'uninstall')]
    [string]$Verb = 'status'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repoRoot 'lib\windows\common.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\windows\houdini.psm1') -Force

switch ($Verb) {
    'status' {
        $status = Get-HoudiniStatus -RepoRoot $repoRoot
        if (-not $status) { exit 1 }
        Write-Output $status.Exe
        if ($status.Outdated) { Write-Output 'outdated' }
    }
    'configure' { if (-not (Set-HoudiniConfig -RepoRoot $repoRoot)) { exit 1 } }
    'uninstall' { if (-not (Uninstall-Houdini -RepoRoot $repoRoot)) { exit 1 } }
    default { if (-not (Install-Houdini -RepoRoot $repoRoot -Action $Verb)) { exit 1 } }
}
exit 0
