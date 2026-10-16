# common.psm1 - Logging utilities and common functions for Windows setup
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# Avoid PS7-only syntax (ternary, ??, chain operators) in this file.

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

# Relay a native command's output to the host, one line per line, so it
# reaches the console or Loadout's log without becoming part of the calling
# function's return value. Left uncaptured, a native call inside a function
# that returns $true/$false makes the result an array, and `-not @('...', $false)`
# is $false - a failed job then reports success. Drops blank lines and
# winget's spinner/progress-bar redraws.
#   & winget @args 2>&1 | Write-NativeOutput
function Write-NativeOutput {
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        foreach ($line in ("$InputObject" -split "`r")) {
            $line = $line.TrimEnd()
            if (-not $line.Trim()) { continue }
            if ($line -match '^\s*[-\\|/]\s*$') { continue }
            # Progress-bar blocks; escaped so 5.1 reading this file as ANSI
            # still sees them.
            if ($line -match '[\u2588\u2592]') { continue }
            Write-Host $line
        }
    }
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

# True when running on Windows.
# $IsWindows only exists on PowerShell Core; on Windows PowerShell 5.1 its
# absence implies Windows. Set-StrictMode makes a bare reference throw, so
# probe the variable instead of reading it directly.
function Test-IsWindowsPlatform {
    $var = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $var) {
        return $true
    }
    return [bool]$var.Value
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

    return (Read-ConfFile -Path $profilePath)
}

# Bash-style KEY="value" lines (profiles, config/sidefx.local) into a
# hashtable. A missing file is an empty one.
function Read-ConfFile {
    param([Parameter(Mandatory)][string]$Path)

    $config = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $config }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            # Remove trailing comments (anything after # not in quotes)
            $line = $line -replace '\s+#.*$', ''
            if ($line -match '^([A-Z0-9_]+)="([^"]*)"') {
                $config[$matches[1]] = $matches[2]
            } elseif ($line -match "^([A-Z0-9_]+)='([^']*)'") {
                # Loadout's Settings writes sidefx.local single-quoted
                $config[$matches[1]] = $matches[2]
            } elseif ($line -match '^([A-Z0-9_]+)=([^\s]*)') {
                $config[$matches[1]] = $matches[2]
            }
        }
    }

    return $config
}

# Check if a profile flag is enabled.
# Unset flags default to enabled, matching lib/symlink.sh and homebrew.sh.
function Test-ProfileFlag {
    param(
        # Not $Profile: that shadows the $PROFILE automatic variable.
        [Parameter(Mandatory)]
        [Alias('Profile')]
        [hashtable]$ProfileConfig,
        [Parameter(Mandatory)]
        [string]$Flag
    )

    $value = 'true'
    if ($ProfileConfig.ContainsKey($Flag)) {
        $value = $ProfileConfig[$Flag]
    }
    return $value -eq 'true'
}

function Assert-ProfileOS {
    param(
        [Parameter(Mandatory)]
        [Alias('Profile')]
        [hashtable]$ProfileConfig,
        [Parameter(Mandatory)]
        [string]$ExpectedOS,
        [string]$ProfileName = ''
    )

    $profileOS = ''
    if ($ProfileConfig.ContainsKey('PROFILE_OS')) {
        $profileOS = $ProfileConfig['PROFILE_OS']
    }

    if ($profileOS -and $profileOS -ne $ExpectedOS) {
        $label = '<unknown>'
        if ($ProfileName) {
            $label = $ProfileName
        }
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

# Map a defaults module filename to the function it must define.
#   explorer      -> Apply-Explorer
#   file-explorer -> Apply-FileExplorer
function Get-ApplyFunctionName {
    param(
        [Parameter(Mandatory)]
        [string]$BaseName
    )

    $parts = $BaseName -split '[-_]'
    $pascal = ''
    foreach ($part in $parts) {
        if (-not $part) { continue }
        $pascal += $part.Substring(0, 1).ToUpper() + $part.Substring(1).ToLower()
    }
    return "Apply-$pascal"
}

# Check if running as administrator
function Test-Administrator {
    if (-not (Test-IsWindowsPlatform)) {
        return $false
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    'Write-NativeOutput',
    'Write-Banner',
    'Get-RepoRoot',
    'Test-IsWindowsPlatform',
    'Read-Profile',
    'Read-ConfFile',
    'Test-ProfileFlag',
    'Assert-ProfileOS',
    'Read-PackageList',
    'Get-CategoryVar',
    'Get-ApplyFunctionName',
    'Test-Administrator'
)
