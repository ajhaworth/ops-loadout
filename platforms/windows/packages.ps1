# packages.ps1 - Windows package installation
#
# Installs winget packages, GitHub-release apps and ComfyUI custom nodes.
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
Import-Module (Join-Path $repoRoot "lib\windows\comfyui.psm1") -Force

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
        [ValidateSet('winget', 'github', 'comfynodes')]
        [string]$Manager
    )

    $prefix = $Manager.ToUpper()

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
    $wingetPackages = Get-EnabledPackages -Manager 'winget'
    if ($wingetPackages.Count -gt 0) {
        Write-Step "winget Packages"
        $all = @($wingetPackages.Values | ForEach-Object { $_ } | ForEach-Object { ConvertFrom-WingetPackageSpec -Spec $_ })
        $state = Get-WingetState -Ids @($all | ForEach-Object { $_.Id })
        foreach ($category in $wingetPackages.Keys | Sort-Object) {
            Write-SubStep $category
            foreach ($package in $wingetPackages[$category]) {
                $id = (ConvertFrom-WingetPackageSpec -Spec $package).Id
                if ($state.ContainsKey($id)) {
                    Write-Host "    [" -NoNewline
                    Write-Host "X" -ForegroundColor Green -NoNewline
                    Write-Host "] $id"
                } else {
                    Write-Host "    [ ] $id" -ForegroundColor DarkGray
                }
            }
        }
    }

    Write-Step "GitHub Release Packages"

    $githubPackages = Get-EnabledPackages -Manager 'github'
    if ($githubPackages.Count -eq 0) {
        Write-Skip "No github categories enabled"
    } else {
        foreach ($category in $githubPackages.Keys | Sort-Object) {
            Show-PackageStatus -Packages $githubPackages[$category] -Category $category
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

# Install all enabled packages
function Install-AllPackages {
    Reset-Results

    # install also upgrades an installed package; -Force changes nothing here.
    $wingetPackages = Get-EnabledPackages -Manager 'winget'
    if ($wingetPackages.Count -gt 0) {
        Write-Step "Installing winget Packages"

        foreach ($category in $wingetPackages.Keys | Sort-Object) {
            Write-SubStep $category
            foreach ($package in $wingetPackages[$category]) {
                Invoke-WingetPackage -Verb 'install' -Spec $package -DryRun:$DryRun | Out-Null
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
            Install-PackageBatch -Packages $githubPackages[$category] -DryRun:$DryRun -Force:$Force
        }
    }

    # ComfyUI's custom nodes, after winget has installed ComfyUI itself.
    Install-ComfyNodeLists -RepoRoot $repoRoot -ProfileConfig $config -DryRun:$DryRun -Force:$Force

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
