Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force

$windowsProfile = Read-Profile -ProfileName "windows"
Assert-True (Assert-ProfileOS -Profile $windowsProfile -ExpectedOS "windows" -ProfileName "windows") "windows profile should validate"

$workProfile = Read-Profile -ProfileName "work"
Assert-True (-not (Assert-ProfileOS -Profile $workProfile -ExpectedOS "windows" -ProfileName "work")) "work profile should be rejected on Windows"

$setupScript = Join-Path $repoRoot "setup.ps1"

& $setupScript -Profile windows -DryRun packages | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "packages dry-run should succeed"

& $setupScript -Profile windows -DryRun dotfiles | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "dotfiles dry-run should succeed"

$failed = $false
try {
    & $setupScript -Profile work -DryRun | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
    }
} catch {
    $failed = $true
}

Assert-True $failed "mismatched profile should fail"

Write-Host "windows smoke tests passed"
