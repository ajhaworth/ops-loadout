# dotfiles.ps1 - Windows dotfiles symlink management
#
# Creates symlinks for configuration files based on the Windows manifest.
# Requires Administrator privileges to create symlinks (or Developer Mode enabled).

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
Import-Module (Join-Path $repoRoot "lib\windows\dotfiles.psm1") -Force

# Load profile
$config = Read-Profile -ProfileName $ProfileName
if (-not $config) {
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $ProfileName)) {
    exit 1
}

# Manifest path
$manifestPath = Join-Path $repoRoot "config\dotfiles\manifest.windows.txt"

# Read manifest entries
$entries = Read-WindowsManifest -ManifestPath $manifestPath -Profile $config

if ($entries.Count -eq 0) {
    Write-Skip "No dotfiles enabled in profile"
    exit 0
}

# List mode - show status
if ($List) {
    Write-Step "Dotfiles Status"
    Show-DotfilesStatus -Entries $entries -RepoRoot $repoRoot
    exit 0
}

# Install mode
Write-Step "Installing Dotfiles"

# Check for symlink capability
$canSymlink = $false
try {
    $testPath = Join-Path $env:TEMP "symlink_test_$(Get-Random)"
    New-Item -ItemType SymbolicLink -Path $testPath -Target $env:TEMP -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $testPath -Force
    $canSymlink = $true
} catch {
    $canSymlink = $false
}

if (-not $canSymlink -and -not $DryRun) {
    Write-Err "Cannot create symlinks. Enable Developer Mode or run as Administrator."
    Write-Status "Settings > Privacy & security > For developers > Developer Mode"
    exit 1
}

Reset-DotfilesResults

foreach ($entry in $entries) {
    $sourceFull = Join-Path $repoRoot $entry.Source
    New-Symlink -Source $sourceFull -Destination $entry.Dest -DryRun:$DryRun -Force:$Force | Out-Null
}

# Create local override files
if (Test-ProfileFlag -Profile $config -Flag 'DOTFILES_GIT') {
    New-GitConfigLocal -DryRun:$DryRun
}

Write-DotfilesSummary

if ((Get-DotfilesFailureCount) -gt 0) {
    exit 1
}
exit 0
