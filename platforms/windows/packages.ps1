# packages.ps1 - Windows package installation
#
# Installs packages using Winget (primary) and Chocolatey (fallback).
# Reads package lists from config/packages/windows/

param(
    [string]$Profile = "windows",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$List
)

$ErrorActionPreference = "Stop"

# Import modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\packages.psm1") -Force

# Load profile
$config = Read-Profile -ProfileName $Profile
if (-not $config) {
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $Profile)) {
    exit 1
}

# Package list directory
$packagesDir = Join-Path $repoRoot "config\packages\windows"

# Get enabled categories and their packages
function Get-EnabledPackages {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('winget', 'choco')]
        [string]$Manager
    )

    $prefix = if ($Manager -eq 'winget') { 'WINGET' } else { 'CHOCO' }
    $managerDir = Join-Path $packagesDir $Manager
    $enabledPackages = @{}

    if (-not (Test-Path $managerDir)) {
        return $enabledPackages
    }

    Get-ChildItem -Path $managerDir -Filter "*.txt" | ForEach-Object {
        $categoryFile = $_.Name
        $categoryName = $_.BaseName
        $varName = Get-CategoryVar -Prefix $prefix -Category $categoryName

        if (Test-ProfileFlag -Profile $config -Flag $varName) {
            $packages = Read-PackageList -FilePath $_.FullName
            if ($packages.Count -gt 0) {
                $enabledPackages[$categoryName] = $packages
            }
        }
    }

    return $enabledPackages
}

# List package status
function Show-AllPackageStatus {
    Write-Step "Winget Packages"

    $wingetPackages = Get-EnabledPackages -Manager 'winget'
    if ($wingetPackages.Count -eq 0) {
        Write-Skip "No winget categories enabled"
    } else {
        foreach ($category in $wingetPackages.Keys | Sort-Object) {
            Show-PackageStatus -Packages $wingetPackages[$category] -Manager 'winget' -Category $category
        }
    }

    Write-Step "Chocolatey Packages"

    $chocoPackages = Get-EnabledPackages -Manager 'choco'
    if ($chocoPackages.Count -eq 0) {
        Write-Skip "No chocolatey categories enabled"
    } else {
        foreach ($category in $chocoPackages.Keys | Sort-Object) {
            Show-PackageStatus -Packages $chocoPackages[$category] -Manager 'choco' -Category $category
        }
    }
}

# Install all enabled packages
function Install-AllPackages {
    Reset-Results

    # Check for winget
    if (-not (Test-Winget)) {
        Write-Err "Winget is not available. Please install it from the Microsoft Store (App Installer)."
        exit 1
    }

    # Install Chocolatey if needed
    $chocoPackages = Get-EnabledPackages -Manager 'choco'
    if ($chocoPackages.Count -gt 0 -and -not (Test-Chocolatey)) {
        Write-Step "Installing Chocolatey"
        if (-not (Install-Chocolatey -DryRun:$DryRun)) {
            Write-Warn "Chocolatey installation failed. Chocolatey packages will be skipped."
        }
    }

    # Install winget packages
    Write-Step "Installing Winget Packages"
    $wingetPackages = Get-EnabledPackages -Manager 'winget'

    if ($wingetPackages.Count -eq 0) {
        Write-Skip "No winget categories enabled"
    } else {
        foreach ($category in $wingetPackages.Keys | Sort-Object) {
            Write-SubStep $category
            Install-PackageBatch -Packages $wingetPackages[$category] -Manager 'winget' -DryRun:$DryRun -Force:$Force
        }
    }

    # Install chocolatey packages
    if ((Test-Chocolatey) -or $DryRun) {
        Write-Step "Installing Chocolatey Packages"

        if ($chocoPackages.Count -eq 0) {
            Write-Skip "No chocolatey categories enabled"
        } else {
            foreach ($category in $chocoPackages.Keys | Sort-Object) {
                Write-SubStep $category
                Install-PackageBatch -Packages $chocoPackages[$category] -Manager 'choco' -DryRun:$DryRun -Force:$Force
            }
        }
    }

    Write-ResultsSummary -Title "Package Installation Summary"
}

# Main
if ($List) {
    Show-AllPackageStatus
} else {
    Install-AllPackages
}
