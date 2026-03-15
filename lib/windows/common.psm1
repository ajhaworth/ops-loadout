# common.psm1 - Logging utilities and common functions for Windows setup

# Logging functions
function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Color = 'Blue'
    )
    Write-Host "[INFO] " -ForegroundColor $Color -NoNewline
    Write-Host $Message
}

function Write-Success {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Skip {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "[SKIP] " -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

function Write-Warn {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-DryRun {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "[DRY-RUN] " -ForegroundColor Magenta -NoNewline
    Write-Host $Message
}

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host ""
    Write-Host "==> " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-SubStep {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    Write-Host "  -> " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Header {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    $width = 60
    $line = "=" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor Blue
    Write-Host $Title.PadLeft(($width + $Title.Length) / 2).PadRight($width) -ForegroundColor Blue
    Write-Host $line -ForegroundColor Blue
    Write-Host ""
}

function Write-Banner {
    Write-Host ""
    Write-Host "   ============================================" -ForegroundColor Magenta
    Write-Host "              D E V B O X" -ForegroundColor Magenta
    Write-Host "   ============================================" -ForegroundColor Magenta
    Write-Host "   Cross-platform workstation setup" -ForegroundColor DarkGray
    Write-Host "   Windows Edition" -ForegroundColor DarkGray
    Write-Host ""
}

# Get repository root
function Get-RepoRoot {
    $scriptDir = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $scriptDir)
}

# Read profile configuration
function Read-Profile {
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $repoRoot = Get-RepoRoot
    $profilePath = Join-Path $repoRoot "config\profiles\$ProfileName.conf"

    if (-not (Test-Path $profilePath)) {
        Write-Err "Profile not found: $profilePath"
        return $null
    }

    $config = @{}
    Get-Content $profilePath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            # Remove trailing comments (anything after # not in quotes)
            $line = $line -replace '\s+#.*$', ''
            if ($line -match '^([A-Z_]+)="([^"]*)"') {
                $config[$matches[1]] = $matches[2]
            } elseif ($line -match '^([A-Z_]+)=([^\s]*)') {
                $config[$matches[1]] = $matches[2]
            }
        }
    }

    return $config
}

# Check if a profile flag is enabled
function Test-ProfileFlag {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Profile,
        [Parameter(Mandatory)]
        [string]$Flag
    )

    $value = if ($Profile.ContainsKey($Flag)) { $Profile[$Flag] } else { 'true' }
    return $value -eq 'true'
}

function Assert-ProfileOS {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Profile,
        [Parameter(Mandatory)]
        [string]$ExpectedOS,
        [string]$ProfileName = ''
    )

    $profileOS = if ($Profile.ContainsKey('PROFILE_OS')) { $Profile['PROFILE_OS'] } else { '' }
    if ($profileOS -and $profileOS -ne $ExpectedOS) {
        $label = if ($ProfileName) { $ProfileName } else { '<unknown>' }
        Write-Err "Profile '$label' targets $profileOS, but this script is running on $ExpectedOS."
        return $false
    }

    return $true
}

# Read package list from file
function Read-PackageList {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return @()
    }

    $packages = @()
    Get-Content $FilePath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            $line = ($line -split '#', 2)[0].Trim()
            if ($line) {
                $packages += $line
            }
        }
    }

    return $packages
}

# Convert category name to profile variable name
function Get-CategoryVar {
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,
        [Parameter(Mandatory)]
        [string]$Category
    )

    $upper = $Category.ToUpper() -replace '-', '_'
    return "${Prefix}_${upper}"
}

# Check if running as administrator
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Require administrator privileges
function Assert-Administrator {
    if (-not (Test-Administrator)) {
        Write-Err "This script requires administrator privileges."
        Write-Status "Please run PowerShell as Administrator and try again."
        exit 1
    }
}

Export-ModuleMember -Function @(
    'Write-Status',
    'Write-Success',
    'Write-Skip',
    'Write-Warn',
    'Write-Err',
    'Write-DryRun',
    'Write-Step',
    'Write-SubStep',
    'Write-Header',
    'Write-Banner',
    'Get-RepoRoot',
    'Read-Profile',
    'Test-ProfileFlag',
    'Assert-ProfileOS',
    'Read-PackageList',
    'Get-CategoryVar',
    'Test-Administrator',
    'Assert-Administrator'
)
