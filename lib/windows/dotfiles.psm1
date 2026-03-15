# dotfiles.psm1 - Dotfiles symlink management for Windows

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Track symlink results
$script:Results = @{
    Linked  = @()
    Skipped = @()
    Failed  = @()
}

function Reset-DotfilesResults {
    $script:Results = @{
        Linked  = @()
        Skipped = @()
        Failed  = @()
    }
}

function Get-DotfilesResults {
    return $script:Results
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
                $condition = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $null }

                # Check condition if specified
                $shouldInclude = if ($condition) {
                    Test-ProfileFlag -Profile $Profile -Flag $condition
                } else { $true }

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

# Expand destination path (replace ~ with $HOME)
function Expand-DestPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $home = $env:USERPROFILE
    if ($Path.StartsWith('~')) {
        return $Path -replace '^~', $home
    } elseif ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    } else {
        return Join-Path $home $Path
    }
}

# Check if path is a symlink
function Test-Symlink {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $item = Get-Item $Path -Force
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

    $item = Get-Item $Path -Force
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
    if (-not (Test-Path $sourceFull)) {
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
            Write-Warn "$destName exists but points to: $target"
            $script:Results.Skipped += $destName
            return $true
        }
    }

    # Check if destination exists and is not a symlink - backup and replace
    if ((Test-Path $destFull) -and -not (Test-Symlink -Path $destFull)) {
        $backupPath = "$destFull.backup"
        if ($DryRun) {
            Write-DryRun "Would backup: $destFull -> $backupPath"
        } else {
            Write-Status "Backing up: $destName -> $destName.backup"
            Move-Item -Path $destFull -Destination $backupPath -Force
        }
    }

    # Create parent directory if needed
    if (-not (Test-Path $destDir)) {
        if ($DryRun) {
            Write-DryRun "Would create directory: $destDir"
        } else {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
    }

    # Remove existing symlink if Force
    if ((Test-Path $destFull) -and $Force) {
        if ($DryRun) {
            Write-DryRun "Would remove existing: $destFull"
        } else {
            Remove-Item -Path $destFull -Force
        }
    }

    # Create symlink
    if ($DryRun) {
        Write-DryRun "Would link: $destName -> $sourceFull"
        return $true
    }

    try {
        New-Item -ItemType SymbolicLink -Path $destFull -Target $sourceFull -Force | Out-Null
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

        if (-not (Test-Path $sourceFull)) {
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
                Write-Host "] $destName (wrong target)"
            }
        } elseif (Test-Path $destFull) {
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

    Write-Host ""
}

# Create ~/.gitconfig.local, prompting for user info if interactive
function New-GitConfigLocal {
    param(
        [switch]$DryRun
    )

    $file = Join-Path $env:USERPROFILE ".gitconfig.local"

    if (Test-Path $file) {
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

        if (Test-Path $template) {
            Copy-Item -Path $template -Destination $file
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
    'Read-WindowsManifest',
    'Expand-DestPath',
    'Test-Symlink',
    'Get-SymlinkTarget',
    'New-Symlink',
    'Show-DotfilesStatus',
    'Write-DotfilesSummary',
    'New-GitConfigLocal'
)
