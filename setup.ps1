# setup.ps1 - Windows setup entry point
#
# This is the main entry point for Windows setup. It delegates to
# the platform-specific setup script.
#
# Usage:
#   .\setup.ps1                      # Full setup
#   .\setup.ps1 -DryRun              # Preview changes
#   .\setup.ps1 packages             # Install packages only
#   .\setup.ps1 packages ls          # List package status
#   .\setup.ps1 dotfiles             # Dotfiles only
#   .\setup.ps1 dotfiles ls          # Check symlink status
#   .\setup.ps1 defaults             # System preferences only
#   .\setup.ps1 defaults ls          # List preference categories
#   .\setup.ps1 -Debloat             # Full setup with debloat
#   .\setup.ps1 debloat              # Debloat only
#   .\setup.ps1 debloat -DryRun      # Preview debloat

[CmdletBinding()]
param(
    # Named -ProfileName rather than -Profile: $Profile is a PowerShell
    # automatic variable (the path to the user's profile script) and a
    # parameter of that name shadows it for the whole script. The alias keeps
    # -Profile working on the command line.
    [Alias('Profile')]
    [string]$ProfileName = "windows",
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Debloat,
    [switch]$Help,

    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Remaining
)

function Show-Usage {
    Write-Host @"
Usage: .\setup.ps1 [command] [subcommand] [options]

Commands:
  (none)              Full setup
  packages            Install GitHub-release apps + ComfyUI custom nodes
  dotfiles            Symlink dotfiles
  defaults            Apply system preferences
  debloat             Remove Windows bloatware

Subcommands:
  ls                  Show status instead of making changes
                      (packages, dotfiles, defaults)

Options:
  -ProfileName <name> Profile to use (default: windows). Alias: -Profile
  -DryRun             Show what would be done without making changes
  -Force              Reinstall packages, replace mismatched symlinks,
                      restart Explorer after applying defaults
  -Debloat            Include bloatware removal in full setup
  -Help               Show this message
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$platformScript = Join-Path $scriptDir "platforms\windows\setup.ps1"

if (-not (Test-Path -LiteralPath $platformScript)) {
    Write-Host "[ERROR] Platform script not found: $platformScript" -ForegroundColor Red
    exit 1
}

# Build arguments
$scriptArgs = @{
    ProfileName = $ProfileName
    DryRun      = $DryRun
    Force       = $Force
    Debloat     = $Debloat
}

# Pass positional arguments
if ($Remaining -and $Remaining.Count -gt 0) {
    $scriptArgs['Command'] = $Remaining[0]
}
if ($Remaining -and $Remaining.Count -gt 1) {
    $scriptArgs['SubCommand'] = $Remaining[1]
}

$global:LASTEXITCODE = 0
& $platformScript @scriptArgs

$exitCode = 0
if ($null -ne $LASTEXITCODE) {
    $exitCode = $LASTEXITCODE
}
exit $exitCode
