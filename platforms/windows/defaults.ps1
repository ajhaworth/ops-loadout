# defaults.ps1 - Windows system preferences
#
# Mirrors platforms/macos/defaults.sh: every file in defaults/ defines an
# Apply-<Name> function that is discovered dynamically and invoked here.
#
# Each file maps to a profile variable via its filename:
#   defaults/explorer.ps1 -> DEFAULTS_EXPLORER
#   defaults/power.ps1    -> DEFAULTS_POWER
# Unset variables default to enabled, matching the rest of the repo.

param(
    [Alias('Profile')]
    [string]$ProfileName = "windows",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$List
)

$ErrorActionPreference = "Stop"

# Import modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\registry.psm1") -Force
# defaults/comfyui*.ps1 locate the app through this
Import-Module (Join-Path $repoRoot "lib\windows\comfyui.psm1") -Force

# Load profile
$config = Read-Profile -ProfileName $ProfileName
if (-not $config) {
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $ProfileName)) {
    exit 1
}

$defaultsDir = Join-Path $scriptDir "defaults"

# Get-ApplyFunctionName (explorer -> Apply-Explorer) lives in common.psm1 so
# the test suite can verify each module against the same mapping.

function Get-DefaultsFiles {
    if (-not (Test-Path -LiteralPath $defaultsDir)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $defaultsDir -Filter "*.ps1" | Sort-Object Name)
}

function Show-DefaultsList {
    Write-Step "Windows Defaults"

    $files = Get-DefaultsFiles
    if ($files.Count -eq 0) {
        Write-Skip "No defaults modules found"
        return
    }

    foreach ($file in $files) {
        $category = $file.BaseName
        $varName = Get-CategoryVar -Prefix 'DEFAULTS' -Category $category
        if (Test-ProfileFlag -Profile $config -Flag $varName) {
            Write-Host "    [" -NoNewline
            Write-Host "X" -ForegroundColor Green -NoNewline
            Write-Host "] $category ($varName)"
        } else {
            Write-Host "    [ ] $category ($varName)" -ForegroundColor DarkGray
        }
    }
}

function Invoke-Defaults {
    $files = Get-DefaultsFiles
    if ($files.Count -eq 0) {
        Write-Skip "No defaults modules found"
        return 0
    }

    if (-not (Test-Administrator)) {
        Write-Warn "Not running as Administrator - machine-wide settings (power, telemetry) will be skipped"
    }

    Reset-RegistryResults

    foreach ($file in $files) {
        $category = $file.BaseName
        $varName = Get-CategoryVar -Prefix 'DEFAULTS' -Category $category

        if (-not (Test-ProfileFlag -Profile $config -Flag $varName)) {
            Write-Skip "$category (disabled by $varName)"
            continue
        }

        Write-Step $category

        . $file.FullName

        $funcName = Get-ApplyFunctionName -BaseName $category
        $func = Get-Command -Name $funcName -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $func) {
            Write-Warn "$($file.Name) does not define $funcName - skipping"
            continue
        }

        try {
            # Every module takes -ProfileConfig so it can read profile
            # variables (e.g. COMFYUI_MODEL_PATH) without re-reading the file.
            & $funcName -ProfileConfig $config -DryRun:$DryRun
        } catch {
            Write-Err "$category failed: $_"
        }
    }

    $results = Get-RegistryResults
    $changed = $results.Changed.Count

    Write-Host ""
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    Write-Host "Defaults Summary" -ForegroundColor White
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Changed: " -NoNewline
    Write-Host $changed -ForegroundColor Green
    Write-Host "  Skipped: " -NoNewline
    Write-Host $results.Skipped.Count -ForegroundColor DarkGray
    if ($results.Failed.Count -gt 0) {
        Write-Host "  Failed:  " -NoNewline
        Write-Host $results.Failed.Count -ForegroundColor Red
    }
    Write-Host ""

    if ($changed -gt 0 -and -not $DryRun) {
        Write-Status "Some settings need Explorer restarted to take effect."
        if ($Force) {
            Write-SubStep "Restarting Explorer"
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        } else {
            Write-SubStep "Run with -Force to restart Explorer automatically, or sign out and back in."
        }
    }

    return $results.Failed.Count
}

# Main
if ($List) {
    Show-DefaultsList
    exit 0
}

$failures = Invoke-Defaults
if ($failures -gt 0) {
    exit 1
}
exit 0
