# platforms/windows/setup.ps1 - Windows setup coordinator
#
# Main setup script for Windows platform. Installs GitHub-release apps and
# ComfyUI custom nodes, symlinks dotfiles, and applies system preferences.
# Winget/Chocolatey packages are installed separately, by Ansible in the
# ops-server repo.

param(
    [Alias('Profile')]
    [string]$ProfileName = "windows",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Debloat,

    # Subcommands
    [Parameter(Position = 0)]
    [ValidateSet('', 'packages', 'dotfiles', 'defaults', 'debloat')]
    [string]$Command = '',

    [Parameter(Position = 1)]
    [ValidateSet('', 'ls')]
    [string]$SubCommand = ''
)

$ErrorActionPreference = "Stop"

# Get script directory and repo root
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

# Import common module
Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\packages.psm1") -Force

if (-not (Test-IsWindowsPlatform)) {
    Write-Err "This script only runs on Windows."
    exit 1
}

# Load profile
$config = Read-Profile -ProfileName $ProfileName
if (-not $config) {
    Write-Err "Failed to load profile: $ProfileName"
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $ProfileName)) {
    exit 1
}

# Tracks whether any stage reported a failure, so the overall run can exit
# non-zero without aborting the remaining stages.
$script:StageFailures = 0

function Invoke-Stage {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        # MUST be a hashtable, never an array. Array splatting passes elements
        # POSITIONALLY: @('-ProfileName', 'windows') binds the literal string
        # '-ProfileName' as the profile name, and any '-DryRun' element is
        # silently swallowed into $args instead of setting the switch.
        [Parameter(Mandatory)]
        [hashtable]$Arguments
    )

    $global:LASTEXITCODE = 0
    & $Path @Arguments
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $script:StageFailures++
    }
}

# Switch values are passed explicitly rather than conditionally added, so a
# stage can never silently run in the wrong mode.
function Get-StageArgs {
    if ($SubCommand -eq 'ls') {
        return @{
            ProfileName = $ProfileName
            List        = $true
        }
    }

    return @{
        ProfileName = $ProfileName
        DryRun      = [bool]$DryRun
        Force       = [bool]$Force
    }
}

function Invoke-PackagesCommand {
    Invoke-Stage -Path (Join-Path $scriptDir "packages.ps1") -Arguments (Get-StageArgs)
}

function Invoke-DotfilesCommand {
    Invoke-Stage -Path (Join-Path $scriptDir "dotfiles.ps1") -Arguments (Get-StageArgs)
}

function Invoke-DefaultsCommand {
    Invoke-Stage -Path (Join-Path $scriptDir "defaults.ps1") -Arguments (Get-StageArgs)
}

function Invoke-DebloatCommand {
    # debloat.ps1 takes no profile or -List
    Invoke-Stage -Path (Join-Path $scriptDir "debloat.ps1") -Arguments @{
        DryRun = [bool]$DryRun
        Force  = [bool]$Force
    }
}

function Invoke-FullSetup {
    Write-Banner

    Write-Status "Profile: $($config['PROFILE_DESCRIPTION'])"
    if ($DryRun) {
        Write-DryRun "Dry run mode - no changes will be made"
    }
    Write-Host ""

    $wantDebloat = $Debloat -or (Test-ProfileFlag -Profile $config -Flag 'PROFILE_DEBLOAT')

    # Check for admin if debloating
    if ($wantDebloat -and -not (Test-Administrator)) {
        Write-Warn "Debloat requires administrator privileges for some operations"
    }

    # Stage 1: Debloat (if enabled)
    if ($wantDebloat) {
        Invoke-DebloatCommand
    }

    # Stage 2: Install packages
    if (Test-ProfileFlag -Profile $config -Flag 'PROFILE_PACKAGES') {
        Invoke-PackagesCommand
    }

    # Stage 3: Dotfiles
    if (Test-ProfileFlag -Profile $config -Flag 'PROFILE_DOTFILES') {
        Invoke-DotfilesCommand
    }

    # Stage 4: System preferences
    if (Test-ProfileFlag -Profile $config -Flag 'PROFILE_APPLY_DEFAULTS') {
        Invoke-DefaultsCommand
    }

    Write-Host ""
    if ($script:StageFailures -gt 0) {
        Write-Warn "Setup finished with $($script:StageFailures) stage(s) reporting failures."
    } else {
        Write-Success "Setup complete!"
    }
    Write-Host ""
}

# Main dispatch
switch ($Command) {
    'packages' {
        Invoke-PackagesCommand
    }
    'dotfiles' {
        Invoke-DotfilesCommand
    }
    'defaults' {
        Invoke-DefaultsCommand
    }
    'debloat' {
        Invoke-DebloatCommand
    }
    default {
        Invoke-FullSetup
    }
}

if ($script:StageFailures -gt 0) {
    exit 1
}
exit 0
