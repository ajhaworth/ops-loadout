# dotfiles.psm1 - Dotfiles symlink management for Windows
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Track symlink results
$script:Results = @{
    Linked  = @()
    Skipped = @()
    Failed  = @()
}

# One backup directory per run, matching the bash implementation's
# ~/.dotfiles_backup/YYYYMMDD_HHMMSS/ layout so history is preserved.
$script:BackupDir = $null

function Reset-DotfilesResults {
    $script:Results = @{
        Linked  = @()
        Skipped = @()
        Failed  = @()
    }
    $script:BackupDir = $null
}

function Get-DotfilesResults {
    return $script:Results
}

function Get-UserHome {
    if ($env:USERPROFILE) {
        return $env:USERPROFILE
    }
    # Non-Windows fallback keeps the module importable for cross-platform tests
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-BackupDir {
    if ($null -eq $script:BackupDir) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:BackupDir = Join-Path (Join-Path (Get-UserHome) '.dotfiles_backup') $stamp
    }
    return $script:BackupDir
}

# Read Windows manifest file
function Read-WindowsManifest {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [hashtable]$Profile
    )

    if (-not (Test-Path $ManifestPath)) {
        Write-Err "Manifest not found: $ManifestPath"
        return @()
    }

    $entries = @()
    Get-Content $ManifestPath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            $parts = $line -split '\|'
            if ($parts.Count -ge 2) {
                $source = $parts[0].Trim()
                $dest = $parts[1].Trim()
                $condition = $null
                if ($parts.Count -ge 3) {
                    $condition = $parts[2].Trim()
                }

                # Check condition if specified
                $shouldInclude = $true
                if ($condition) {
                    $shouldInclude = Test-ProfileFlag -Profile $Profile -Flag $condition
                }

                if ($shouldInclude) {
                    $entries += @{
                        Source    = $source
                        Dest      = $dest
                        Condition = $condition
                    }
                }
            }
        }
    }

    return $entries
}

# Case-insensitive literal token substitution.
function Expand-PathToken {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $offset = 0
    while ($true) {
        if ($offset -gt $Text.Length) { break }
        $idx = $Text.IndexOf($Token, $offset, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { break }
        $Text = $Text.Substring(0, $idx) + $Value + $Text.Substring($idx + $Token.Length)
        # Resume past the substituted value so a token inside $Value cannot loop
        $offset = $idx + $Value.Length
    }

    return $Text
}

# Expand destination path.
#
# Supports:
#   ~                 -> user profile
#   %USERPROFILE%     -> user profile
#   %LOCALAPPDATA%    -> local app data
#   %APPDATA%         -> roaming app data
#   %DOCUMENTS%       -> the real Documents folder, which is NOT always
#                        <profile>\Documents (OneDrive Known Folder Move
#                        relocates it), so it is resolved via the shell API
#   anything else relative -> joined to the user profile
#
# NOTE: $HOME is a read-only automatic variable in PowerShell. Assigning to it
# throws, so this function must never do so.
function Expand-DestPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $userHome = Get-UserHome

    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }

    $roamingAppData = $env:APPDATA
    if (-not $roamingAppData) {
        $roamingAppData = [Environment]::GetFolderPath('ApplicationData')
    }

    $documents = [Environment]::GetFolderPath('MyDocuments')
    if (-not $documents) {
        $documents = Join-Path $userHome 'Documents'
    }

    # Literal, case-insensitive substitution. -replace is deliberately avoided:
    # Windows paths contain backslashes and may contain '$', both of which have
    # meaning in regex replacement strings.
    $expanded = $Path
    $expanded = Expand-PathToken -Text $expanded -Token '%USERPROFILE%'  -Value $userHome
    $expanded = Expand-PathToken -Text $expanded -Token '%LOCALAPPDATA%' -Value $localAppData
    $expanded = Expand-PathToken -Text $expanded -Token '%APPDATA%'      -Value $roamingAppData
    $expanded = Expand-PathToken -Text $expanded -Token '%DOCUMENTS%'    -Value $documents

    if ($expanded.StartsWith('~')) {
        return (Join-Path $userHome $expanded.Substring(1).TrimStart('\', '/'))
    }

    if ([IO.Path]::IsPathRooted($expanded)) {
        return $expanded
    }

    return (Join-Path $userHome $expanded)
}

# Check if path is a symlink
function Test-Symlink {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $false
    }
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

# Get symlink target
function Get-SymlinkTarget {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Symlink -Path $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -Force
    return $item.Target
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$BasePath = ''
    )

    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate) -and $BasePath) {
        $candidate = Join-Path $BasePath $candidate
    }

    return [IO.Path]::GetFullPath($candidate)
}

function Resolve-SymlinkComparableTarget {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $target = Get-SymlinkTarget -Path $Path
    if ($target -is [array]) {
        $target = $target[0]
    }

    if (-not $target) {
        return $null
    }

    return Get-NormalizedPath -Path $target -BasePath (Split-Path -Parent $Path)
}

# Move an existing real file into this run's timestamped backup directory.
function Backup-ExistingPath {
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,
        [switch]$DryRun
    )

    $backupDir = Get-BackupDir
    $name = Split-Path -Leaf $TargetPath
    $backupPath = Join-Path $backupDir $name

    # Avoid collisions when two manifest entries share a leaf name
    $suffix = 1
    while ((Test-Path -LiteralPath $backupPath) -or ($DryRun -and $suffix -gt 1)) {
        $backupPath = Join-Path $backupDir "$name.$suffix"
        $suffix++
        if ($suffix -gt 50) { break }
    }

    if ($DryRun) {
        Write-DryRun "Would back up: $TargetPath -> $backupPath"
        return
    }

    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    Write-Status "Backing up: $name -> $backupPath"
    Move-Item -LiteralPath $TargetPath -Destination $backupPath -Force
}

# How many directory levels above $Path do not exist yet.
#
# One missing level is normal (~/.config, Documents\PowerShell). Two or more
# usually means the owning application is not installed - e.g. Windows
# Terminal's ...\Packages\Microsoft.WindowsTerminal_*\LocalState\ - and
# fabricating that tree is worse than skipping the entry.
function Get-MissingAncestorCount {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $count = 0
    $current = Split-Path -Parent $Path
    while ($current -and -not (Test-Path -LiteralPath $current)) {
        $count++
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $count
}

# Create a symlink
function New-Symlink {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination,
        [switch]$DryRun,
        [switch]$Force
    )

    $sourceFull = $Source
    $destFull = Expand-DestPath -Path $Destination
    $destDir = Split-Path -Parent $destFull
    $destName = Split-Path -Leaf $destFull

    # Check if source exists
    if (-not (Test-Path -LiteralPath $sourceFull)) {
        Write-Err "Source not found: $sourceFull"
        $script:Results.Failed += $destName
        return $false
    }

    # Check if already correctly linked
    if (Test-Symlink -Path $destFull) {
        $normalizedTarget = Resolve-SymlinkComparableTarget -Path $destFull
        $normalizedSource = Get-NormalizedPath -Path $sourceFull
        if ($normalizedTarget -eq $normalizedSource) {
            Write-Skip "$destName (already linked)"
            $script:Results.Skipped += $destName
            return $true
        } elseif (-not $Force) {
            Write-Warn "$destName exists but points to: $normalizedTarget"
            Write-Status "Re-run with -Force to replace it"
            $script:Results.Skipped += $destName
            return $true
        }
    }

    # Bail out when the destination tree looks like an app that isn't installed
    $missingLevels = Get-MissingAncestorCount -Path $destFull
    if ($missingLevels -gt 1 -and -not $Force) {
        Write-Skip "$destName ($destDir does not exist - is the app installed?)"
        $script:Results.Skipped += $destName
        return $true
    }

    # Existing real file (not a symlink) - back it up before replacing
    if ((Test-Path -LiteralPath $destFull) -and -not (Test-Symlink -Path $destFull)) {
        Backup-ExistingPath -TargetPath $destFull -DryRun:$DryRun
    }

    # Create parent directory if needed
    if (-not (Test-Path -LiteralPath $destDir)) {
        if ($DryRun) {
            Write-DryRun "Would create directory: $destDir"
        } else {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
    }

    # Remove a stale symlink so New-Item can recreate it
    if ((Test-Path -LiteralPath $destFull) -and (Test-Symlink -Path $destFull)) {
        if ($DryRun) {
            Write-DryRun "Would remove existing link: $destFull"
        } else {
            Remove-Item -LiteralPath $destFull -Force -Recurse
        }
    }

    # Create symlink
    if ($DryRun) {
        Write-DryRun "Would link: $destFull -> $sourceFull"
        return $true
    }

    try {
        New-Item -ItemType SymbolicLink -Path $destFull -Target $sourceFull -Force -ErrorAction Stop | Out-Null
        Write-Success "$destName -> $sourceFull"
        $script:Results.Linked += $destName
        return $true
    } catch {
        Write-Err "Failed to create symlink ${destName}: $_"
        $script:Results.Failed += $destName
        return $false
    }
}

# Show status of dotfiles
function Show-DotfilesStatus {
    param(
        [Parameter(Mandatory)]
        [array]$Entries,
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    foreach ($entry in $Entries) {
        $sourceFull = Join-Path $RepoRoot $entry.Source
        $destFull = Expand-DestPath -Path $entry.Dest
        $destName = Split-Path -Leaf $destFull

        if (-not (Test-Path -LiteralPath $sourceFull)) {
            Write-Host "    [" -NoNewline
            Write-Host "!" -ForegroundColor Red -NoNewline
            Write-Host "] $destName (source missing)"
            continue
        }

        if (Test-Symlink -Path $destFull) {
            $normalizedTarget = Resolve-SymlinkComparableTarget -Path $destFull
            $normalizedSource = Get-NormalizedPath -Path $sourceFull
            if ($normalizedTarget -eq $normalizedSource) {
                Write-Host "    [" -NoNewline
                Write-Host "X" -ForegroundColor Green -NoNewline
                Write-Host "] $destName"
            } else {
                Write-Host "    [" -NoNewline
                Write-Host "~" -ForegroundColor Yellow -NoNewline
                Write-Host "] $destName (wrong target: $normalizedTarget)"
            }
        } elseif (Test-Path -LiteralPath $destFull) {
            Write-Host "    [" -NoNewline
            Write-Host "F" -ForegroundColor Yellow -NoNewline
            Write-Host "] $destName (file exists)"
        } else {
            Write-Host "    [ ] $destName" -ForegroundColor DarkGray
        }
    }
}

# Write dotfiles summary
function Write-DotfilesSummary {
    $results = Get-DotfilesResults
    $total = $results.Linked.Count + $results.Skipped.Count + $results.Failed.Count

    if ($total -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    Write-Host "Dotfiles Summary" -ForegroundColor White
    Write-Host "--------------------------------------" -ForegroundColor DarkGray

    if ($results.Linked.Count -gt 0) {
        Write-Host "  Linked:  " -NoNewline
        Write-Host $results.Linked.Count -ForegroundColor Green
    }

    if ($results.Skipped.Count -gt 0) {
        Write-Host "  Skipped: " -NoNewline
        Write-Host $results.Skipped.Count -ForegroundColor DarkGray
    }

    if ($results.Failed.Count -gt 0) {
        Write-Host "  Failed:  " -NoNewline
        Write-Host $results.Failed.Count -ForegroundColor Red
    }

    if ($null -ne $script:BackupDir -and (Test-Path -LiteralPath $script:BackupDir)) {
        Write-Host "  Backups: $script:BackupDir" -ForegroundColor DarkGray
    }

    Write-Host ""
}

function Get-DotfilesFailureCount {
    return (Get-DotfilesResults).Failed.Count
}

# Create ~/.gitconfig.local, prompting for user info if interactive
function New-GitConfigLocal {
    param(
        [switch]$DryRun
    )

    $file = Join-Path (Get-UserHome) ".gitconfig.local"

    if (Test-Path -LiteralPath $file) {
        Write-SubStep "Already exists: $file"
        return
    }

    Write-SubStep "Creating: $file"

    if ($DryRun) {
        Write-DryRun "Would prompt for git name and email (interactive) or create template"
        return
    }

    # Interactive: prompt for git user info
    if ([Environment]::UserInteractive) {
        Write-Status "Setting up git configuration..."
        Write-Host ""

        $gitName = Read-Host "  Git user name"
        $gitEmail = Read-Host "  Git email"

        @"
# ~/.gitconfig.local - Machine-specific git configuration
# This file is included by .gitconfig and is not tracked by git

[user]
    name = $gitName
    email = $gitEmail

# Credential helper
# [credential]
#     helper = manager    # Git Credential Manager (recommended on Windows)

# Optional: signing key
# [user]
#     signingkey = YOUR_GPG_KEY_ID
# [commit]
#     gpgsign = true
"@ | Set-Content -Path $file -Encoding UTF8

        Write-Success "Git configuration saved to $file"
    } else {
        # Non-interactive: copy the template
        $repoRoot = Get-RepoRoot
        $template = Join-Path $repoRoot "config\dotfiles\git\config.local.template"

        if (Test-Path -LiteralPath $template) {
            Copy-Item -LiteralPath $template -Destination $file
        } else {
            @"
# ~/.gitconfig.local - Machine-specific git configuration
# This file is included by .gitconfig and is not tracked by git

# IMPORTANT: Set your user info here
[user]
    name = Your Name
    email = your.email@example.com

# Credential helper
# [credential]
#     helper = manager    # Git Credential Manager (recommended on Windows)

# Optional: signing key
# [user]
#     signingkey = YOUR_GPG_KEY_ID
# [commit]
#     gpgsign = true
"@ | Set-Content -Path $file -Encoding UTF8
        }

        Write-Status "Please edit $file with your settings"
    }
}

Export-ModuleMember -Function @(
    'Reset-DotfilesResults',
    'Get-DotfilesResults',
    'Get-DotfilesFailureCount',
    'Get-UserHome',
    'Get-BackupDir',
    'Read-WindowsManifest',
    'Expand-PathToken',
    'Expand-DestPath',
    'Test-Symlink',
    'Get-SymlinkTarget',
    'Get-NormalizedPath',
    'Resolve-SymlinkComparableTarget',
    'Backup-ExistingPath',
    'Get-MissingAncestorCount',
    'New-Symlink',
    'Show-DotfilesStatus',
    'Write-DotfilesSummary',
    'New-GitConfigLocal'
)
