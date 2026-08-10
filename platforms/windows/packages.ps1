# packages.ps1 - Windows package installation
#
# Installs packages using Winget (primary) and Chocolatey (fallback).
# Reads package lists from config/packages/windows/

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
Import-Module (Join-Path $repoRoot "lib\windows\packages.psm1") -Force

# Load profile
$config = Read-Profile -ProfileName $ProfileName
if (-not $config) {
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $ProfileName)) {
    exit 1
}

# Package list directory
$packagesDir = Join-Path $repoRoot "config\packages\windows"

# Get enabled categories and their packages
function Get-EnabledPackages {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('winget', 'choco', 'github', 'comfynodes')]
        [string]$Manager
    )

    $prefix = 'CHOCO'
    if ($Manager -eq 'winget') {
        $prefix = 'WINGET'
    } elseif ($Manager -eq 'github') {
        $prefix = 'GITHUB'
    } elseif ($Manager -eq 'comfynodes') {
        $prefix = 'COMFYNODES'
    }

    $managerDir = Join-Path $packagesDir $Manager
    $enabledPackages = @{}

    if (-not (Test-Path -LiteralPath $managerDir)) {
        return $enabledPackages
    }

    Get-ChildItem -LiteralPath $managerDir -Filter "*.txt" | ForEach-Object {
        $categoryName = $_.BaseName
        $varName = Get-CategoryVar -Prefix $prefix -Category $categoryName

        if (Test-ProfileFlag -Profile $config -Flag $varName) {
            # @() matters: a single-entry list unwraps to a bare string, and
            # .Count on a scalar throws under Set-StrictMode -Version Latest.
            $packages = @(Read-PackageList -FilePath $_.FullName)
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

    Write-Step "GitHub Release Packages"

    $githubPackages = Get-EnabledPackages -Manager 'github'
    if ($githubPackages.Count -eq 0) {
        Write-Skip "No github categories enabled"
    } else {
        foreach ($category in $githubPackages.Keys | Sort-Object) {
            Show-PackageStatus -Packages $githubPackages[$category] -Manager 'github' -Category $category
        }
    }

    $nodePackages = Get-EnabledPackages -Manager 'comfynodes'
    if ($nodePackages.Count -gt 0) {
        Write-Step "ComfyUI Custom Nodes"

        $backends = @(Get-ComfyBackends)
        if ($backends.Count -eq 0) {
            Write-Skip "No ComfyUI install found"
        } else {
            $customNodes = Join-ComfyPath -Base $backends[0].BaseDir -Child 'custom_nodes'
            foreach ($category in $nodePackages.Keys | Sort-Object) {
                Write-SubStep $category
                foreach ($package in $nodePackages[$category]) {
                    $display = ($package -split '\|')[0].Trim()
                    if (Test-ComfyNodeInstalled -PackageSpec $package -CustomNodesDir $customNodes) {
                        Write-Host "    [" -NoNewline
                        Write-Host "X" -ForegroundColor Green -NoNewline
                        Write-Host "] $display"
                    } else {
                        Write-Host "    [ ] $display" -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
}

# ComfyUI custom nodes. These install into the app's own tree rather than
# through a package manager, so they are handled apart from Install-PackageBatch
# and are simply skipped on a machine with no ComfyUI.
function Install-AllComfyNodes {
    $nodePackages = Get-EnabledPackages -Manager 'comfynodes'
    if ($nodePackages.Count -eq 0) {
        return
    }

    Write-Step "Installing ComfyUI Custom Nodes"

    $backends = @(Get-ComfyBackends)
    if ($backends.Count -eq 0) {
        Write-Skip "No ComfyUI install found - launch Comfy Desktop once, then re-run"
        return
    }

    # Nodes are loaded at startup, so a running backend would not see them
    if ((Test-ComfyDesktopRunning) -and -not $DryRun) {
        Write-Warn "Comfy Desktop is running - restart it once this finishes"
    }

    foreach ($backend in $backends) {
        foreach ($category in $nodePackages.Keys | Sort-Object) {
            Write-SubStep $category
            foreach ($package in $nodePackages[$category]) {
                Install-ComfyNode -PackageSpec $package -BaseDir $backend.BaseDir `
                    -DryRun:$DryRun -Force:$Force | Out-Null
            }
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

    # GitHub release installers. These need no package manager, but the
    # installers they download will prompt for elevation when not already admin.
    $githubPackages = Get-EnabledPackages -Manager 'github'
    if ($githubPackages.Count -gt 0) {
        Write-Step "Installing GitHub Release Packages"

        foreach ($category in $githubPackages.Keys | Sort-Object) {
            Write-SubStep $category
            Install-PackageBatch -Packages $githubPackages[$category] -Manager 'github' -DryRun:$DryRun -Force:$Force
        }
    }

    Install-AllComfyNodes

    Write-ResultsSummary -Title "Package Installation Summary"
}

# Main
if ($List) {
    Show-AllPackageStatus
    exit 0
}

Install-AllPackages

if ((Get-FailureCount) -gt 0) {
    exit 1
}
exit 0
