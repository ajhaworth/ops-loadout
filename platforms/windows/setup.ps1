# platforms/windows/setup.ps1 - Windows setup coordinator
#
# Main setup script for Windows platform. Installs packages using Winget
# and Chocolatey, with optional Claude Code installation.

param(
    [string]$Profile = "windows",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Debloat,

    # Subcommands
    [Parameter(Position = 0)]
    [ValidateSet('', 'packages', 'dotfiles', 'debloat')]
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

# Load profile
$config = Read-Profile -ProfileName $Profile
if (-not $config) {
    Write-Err "Failed to load profile: $Profile"
    exit 1
}
if (-not (Assert-ProfileOS -Profile $config -ExpectedOS 'windows' -ProfileName $Profile)) {
    exit 1
}

# Handle subcommands
function Invoke-PackagesCommand {
    $packagesScript = Join-Path $scriptDir "packages.ps1"

    if ($SubCommand -eq 'ls') {
        & $packagesScript -Profile $Profile -List
    } else {
        & $packagesScript -Profile $Profile -DryRun:$DryRun -Force:$Force
    }
}

function Invoke-DotfilesCommand {
    $dotfilesScript = Join-Path $scriptDir "dotfiles.ps1"

    if ($SubCommand -eq 'ls') {
        & $dotfilesScript -Profile $Profile -List
    } else {
        & $dotfilesScript -Profile $Profile -DryRun:$DryRun -Force:$Force
    }
}

function Invoke-DebloatCommand {
    $debloatScript = Join-Path $scriptDir "debloat.ps1"
    & $debloatScript -DryRun:$DryRun -Force:$Force
}

function Install-ClaudeCode {
    if (-not (Test-ProfileFlag -Profile $config -Flag 'PROFILE_CLAUDE_CODE')) {
        return
    }

    Write-Step "Installing Claude Code"

    $result = Install-WingetPackage -PackageId 'Anthropic.ClaudeCode' -DryRun:$DryRun -Force:$Force

    if ($result -and -not $DryRun) {
        # Ensure ~/.local/bin is in user PATH (where winget installs claude)
        $localBin = Join-Path $env:USERPROFILE ".local\bin"
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$localBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$localBin", "User")
            Write-Success "Added $localBin to user PATH"
        }

        Write-Status "Run 'claude' to get started (restart terminal if needed)"
    }
}

function Invoke-FullSetup {
    Write-Banner

    Write-Status "Profile: $($config['PROFILE_DESCRIPTION'])"
    if ($DryRun) {
        Write-DryRun "Dry run mode - no changes will be made"
    }
    Write-Host ""

    # Check for admin if debloating
    if ($Debloat -or (Test-ProfileFlag -Profile $config -Flag 'PROFILE_DEBLOAT')) {
        if (-not (Test-Administrator)) {
            Write-Warn "Debloat requires administrator privileges for some operations"
        }
    }

    # Stage 1: Debloat (if enabled)
    if ($Debloat -or (Test-ProfileFlag -Profile $config -Flag 'PROFILE_DEBLOAT')) {
        Invoke-DebloatCommand
    }

    # Stage 2: Install packages
    if (Test-ProfileFlag -Profile $config -Flag 'PROFILE_PACKAGES') {
        Invoke-PackagesCommand
    }

    # Stage 3: Install Claude Code
    Install-ClaudeCode

    # Stage 4: Dotfiles
    if (Test-ProfileFlag -Profile $config -Flag 'PROFILE_DOTFILES') {
        Invoke-DotfilesCommand
    }

    Write-Host ""
    Write-Success "Setup complete!"
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
    'debloat' {
        Invoke-DebloatCommand
    }
    default {
        Invoke-FullSetup
    }
}
