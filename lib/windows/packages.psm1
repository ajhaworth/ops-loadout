# packages.psm1 - Package management functions for Windows setup
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Track installation results
$script:Results = @{
    Installed = @()
    Skipped   = @()
    Failed    = @()
}

# Installer exit codes that indicate success for GitHub release installers.
# Most Windows installers follow the MSI convention here.
$script:GitHubBenignExit = @{
    0    = 'installed'
    3010 = 'installed (reboot required)'
    1641 = 'installed (reboot initiated)'
}

function Reset-Results {
    $script:Results = @{
        Installed = @()
        Skipped   = @()
        Failed    = @()
    }
}

function Get-Results {
    return $script:Results
}

# Format an exit code for humans (decimal plus hex, which is how winget
# documents its codes).
function Format-ExitCode {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [int]$Code
    )

    $hex = '0x{0:X8}' -f $Code
    return "$Code ($hex)"
}

# --- GitHub release installs -------------------------------------------------
#
# Some apps ship only as a GitHub release asset, with no winget or Chocolatey
# package (those are managed by Ansible in ops-server). Entries in
# config/packages/windows/github/*.txt are pipe-delimited:
#
#   owner/repo | asset-pattern | display-name | install-args
#
#   asset-pattern  wildcard matched against release asset names (default *.exe)
#   display-name   matched against Add/Remove Programs to detect an existing
#                  install; wildcards honoured, otherwise substring (default:
#                  the repo name)
#   install-args   passed to the downloaded installer (default /quiet)
#
# Only the repo is required. Unlike a package manager there is no version
# negotiation: an app already in Add/Remove Programs is skipped, and -Force
# reinstalls it at the latest release.

function ConvertFrom-GitHubPackageSpec {
    param(
        [Parameter(Mandatory)]
        [string]$Spec
    )

    $parts = $Spec -split '\|'
    $repo = $parts[0].Trim()

    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') {
        throw "Invalid GitHub package spec '$Spec' - expected 'owner/repo | asset-pattern | display-name | install-args'"
    }

    $assetPattern = '*.exe'
    if ($parts.Count -ge 2 -and $parts[1].Trim()) {
        $assetPattern = $parts[1].Trim()
    }

    $displayName = ($repo -split '/')[1]
    if ($parts.Count -ge 3 -and $parts[2].Trim()) {
        $displayName = $parts[2].Trim()
    }

    $installArgs = @('/quiet')
    if ($parts.Count -ge 4 -and $parts[3].Trim()) {
        $installArgs = @($parts[3].Trim() -split '\s+')
    }

    return @{
        Repo         = $repo
        AssetPattern = $assetPattern
        DisplayName  = $displayName
        InstallArgs  = $installArgs
    }
}

# Split a version string into its numeric core and semver prerelease suffix.
# Returns $null when the string is not version-shaped.
function ConvertTo-VersionParts {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    if (-not $Version) { return $null }

    $trimmed = $Version.Trim() -replace '^[vV]', ''
    if ($trimmed -notmatch '^(\d+(?:\.\d+)*)(?:[-+](.+))?$') { return $null }

    $numbers = @()
    foreach ($piece in ($matches[1] -split '\.')) {
        $numbers += [int]$piece
    }

    $pre = ''
    if ($matches.ContainsKey(2) -and $matches[2]) {
        $pre = $matches[2]
    }

    return @{
        Numbers    = $numbers
        PreRelease = $pre
    }
}

# Compare two version strings: -1 when Left is older, 0 when equal, 1 when Left
# is newer. Returns $null when either side is unparseable, which callers treat
# as "cannot tell" rather than "upgrade" - guessing would reinstall every run.
#
# Follows the semver precedence rule that a prerelease ranks below the plain
# release, so 1.18.4 is newer than both 1.18.3-beta.7 and 1.18.4-rc.1.
function Compare-VersionString {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Left,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Right,
        # Compare numeric cores only. Needed when the two sides come from
        # different versioning schemes and their suffixes are not comparable.
        [switch]$IgnorePreRelease
    )

    $leftParts = ConvertTo-VersionParts -Version $Left
    $rightParts = ConvertTo-VersionParts -Version $Right
    if ($null -eq $leftParts -or $null -eq $rightParts) {
        return $null
    }

    $count = [Math]::Max($leftParts.Numbers.Count, $rightParts.Numbers.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = 0
        if ($i -lt $leftParts.Numbers.Count) { $l = $leftParts.Numbers[$i] }
        $r = 0
        if ($i -lt $rightParts.Numbers.Count) { $r = $rightParts.Numbers[$i] }

        if ($l -gt $r) { return 1 }
        if ($l -lt $r) { return -1 }
    }

    if ($IgnorePreRelease) { return 0 }

    if ($leftParts.PreRelease -eq $rightParts.PreRelease) { return 0 }
    if (-not $leftParts.PreRelease) { return 1 }
    if (-not $rightParts.PreRelease) { return -1 }

    $ordering = [string]::Compare($leftParts.PreRelease, $rightParts.PreRelease, [System.StringComparison]::OrdinalIgnoreCase)
    if ($ordering -gt 0) { return 1 }
    if ($ordering -lt 0) { return -1 }
    return 0
}

# Read a registry property without tripping Set-StrictMode on absent values.
function Get-RegistryProperty {
    param(
        $Properties,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Properties) { return '' }
    $prop = $Properties.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

# Shared walk over the three Uninstall registry roots that list installed
# programs, yielding each key's properties (skipping ones that fail to read).
# Get-InstalledProgram and Get-ProgramProps are the public surface - this is
# not exported.
function Get-UninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $props
        }
    }
}

# Find an app in Add/Remove Programs. Patterns without wildcards are matched as
# substrings, so "Vibepollo" finds "Vibepollo 1.18.4".
function Get-InstalledProgram {
    param(
        [Parameter(Mandatory)]
        [string]$NamePattern
    )

    if (-not (Test-IsWindowsPlatform)) {
        return $null
    }

    $isWildcard = $NamePattern.Contains('*') -or $NamePattern.Contains('?')

    foreach ($props in Get-UninstallEntries) {
        $name = Get-RegistryProperty -Properties $props -Name 'DisplayName'
        if (-not $name) { continue }

        $hit = $false
        if ($isWildcard) {
            $hit = $name -like $NamePattern
        } else {
            $hit = $name.IndexOf($NamePattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }

        if ($hit) {
            return @{
                Name    = $name
                Version = (Get-RegistryProperty -Properties $props -Name 'DisplayVersion')
            }
        }
    }

    return $null
}

# Check if a GitHub-sourced package is installed
function Test-GitHubPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSpec
    )

    try {
        $spec = ConvertFrom-GitHubPackageSpec -Spec $PackageSpec
    } catch {
        return $false
    }

    return $null -ne (Get-InstalledProgram -NamePattern $spec.DisplayName)
}

# Release tags this tool has installed, so later runs can compare tag to tag.
# An app's own DisplayVersion is not a reliable stand-in: Vibepollo's v1.18.4
# release registers itself as 1.18.4-beta.3, which reads as "older than the
# release" forever and reinstalls on every run.
$script:GitHubStampKey = 'HKCU:\Software\ops-loadout\GitHubReleases'

function Get-GitHubReleaseStamp {
    param(
        [Parameter(Mandatory)]
        [string]$Repo
    )

    if (-not (Test-IsWindowsPlatform)) { return '' }
    if (-not (Test-Path -LiteralPath $script:GitHubStampKey)) { return '' }

    $props = Get-ItemProperty -LiteralPath $script:GitHubStampKey -ErrorAction SilentlyContinue
    return Get-RegistryProperty -Properties $props -Name $Repo
}

function Set-GitHubReleaseStamp {
    param(
        [Parameter(Mandatory)]
        [string]$Repo,
        [Parameter(Mandatory)]
        [string]$Tag
    )

    if (-not (Test-IsWindowsPlatform)) { return }

    try {
        if (-not (Test-Path -LiteralPath $script:GitHubStampKey)) {
            New-Item -Path $script:GitHubStampKey -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $script:GitHubStampKey -Name $Repo -Value $Tag -PropertyType String -Force | Out-Null
    } catch {
        Write-Warn "Could not record the installed release for ${Repo}: $_"
    }
}

# Resolve the latest release for a repo via the GitHub API.
# Unauthenticated calls are rate limited to 60/hour; GITHUB_TOKEN lifts that.
function Get-GitHubLatestRelease {
    param(
        [Parameter(Mandatory)]
        [string]$Repo
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'ops-loadout-setup'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -UseBasicParsing
}

# Install a single package from its latest GitHub release
function Install-GitHubRelease {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSpec,
        [switch]$DryRun,
        [switch]$Force
    )

    try {
        $spec = ConvertFrom-GitHubPackageSpec -Spec $PackageSpec
    } catch {
        Write-Err $_.Exception.Message
        $script:Results.Failed += $PackageSpec
        return $false
    }

    $label = $spec.Repo

    $existing = Get-InstalledProgram -NamePattern $spec.DisplayName
    $installedVersion = ''
    if ($null -ne $existing) {
        $installedVersion = $existing.Version
    }

    # The latest release has to be resolved even when the app is present: the
    # installed version alone cannot say whether an upgrade is available.
    $release = $null
    try {
        $release = Get-GitHubLatestRelease -Repo $spec.Repo
    } catch {
        if ($DryRun) {
            # Keep dry runs (and the smoke tests) usable without network access
            Write-DryRun "Would check $label for updates (release lookup failed: $($_.Exception.Message))"
            return $true
        }
        Write-Err "Could not resolve the latest release for ${label}: $_"
        $script:Results.Failed += $label
        return $false
    }

    $latestVersion = $release.tag_name -replace '^[vV]', ''

    $stamp = Get-GitHubReleaseStamp -Repo $spec.Repo

    if ($null -ne $existing -and -not $Force) {
        if ($stamp) {
            # Tag against tag: exact.
            $comparison = Compare-VersionString -Left $latestVersion -Right ($stamp -replace '^[vV]', '')
        } else {
            # No record of what we installed, so fall back to the app's own
            # DisplayVersion - and compare numeric cores only, because the two
            # schemes need not agree on suffixes.
            $comparison = Compare-VersionString -Left $latestVersion -Right $installedVersion -IgnorePreRelease
        }

        if ($null -eq $comparison) {
            $shown = $installedVersion
            if (-not $shown) { $shown = 'version unknown' }
            Write-Skip "$label (installed $shown, cannot compare to $($release.tag_name) - use -Force to reinstall)"
            $script:Results.Skipped += $label
            return $true
        }

        if ($comparison -le 0) {
            $shown = $installedVersion
            if ($stamp) { $shown = $stamp }
            Write-Skip "$label (already installed $shown)"
            # Adopt an install we did not perform, so later runs compare tags
            if (-not $stamp -and -not $DryRun) {
                Set-GitHubReleaseStamp -Repo $spec.Repo -Tag $release.tag_name
            }
            $script:Results.Skipped += $label
            return $true
        }
    }

    $verb = 'install'
    $gerund = 'Installing'
    $versionNote = $release.tag_name
    if ($null -ne $existing) {
        $verb = 'upgrade'
        $gerund = 'Upgrading'
        $versionNote = "$installedVersion -> $($release.tag_name)"
    }

    if ($DryRun) {
        Write-DryRun "Would ${verb}: $label ($versionNote)"
        return $true
    }

    Write-Status "$gerund $label ($versionNote)..."

    $downloadDir = Join-Path ([IO.Path]::GetTempPath()) ("ghrel_" + [guid]::NewGuid().ToString('N'))
    try {
        $asset = $release.assets | Where-Object { $_.name -like $spec.AssetPattern } | Select-Object -First 1

        if ($null -eq $asset) {
            Write-Err "No asset matching '$($spec.AssetPattern)' in $label $($release.tag_name)"
            $script:Results.Failed += $label
            return $false
        }

        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        $installer = Join-Path $downloadDir $asset.name

        Write-SubStep $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing

        $startArgs = @{
            FilePath = $installer
            Wait     = $true
            PassThru = $true
        }
        if ($spec.InstallArgs.Count -gt 0) {
            $startArgs['ArgumentList'] = $spec.InstallArgs
        }

        $proc = Start-Process @startArgs
        $exitCode = $proc.ExitCode

        if ($script:GitHubBenignExit.ContainsKey($exitCode)) {
            Write-Success "$label $($script:GitHubBenignExit[$exitCode]) ($($release.tag_name))"
            Set-GitHubReleaseStamp -Repo $spec.Repo -Tag $release.tag_name
            $script:Results.Installed += $label
            return $true
        }

        Write-Err "Failed to install $label - exit $(Format-ExitCode -Code $exitCode)"
        $script:Results.Failed += $label
        return $false
    } catch {
        Write-Err "Error installing ${label}: $_"
        $script:Results.Failed += $label
        return $false
    } finally {
        if (Test-Path -LiteralPath $downloadDir) {
            Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Get-InstalledProgram returns only Name/Version, so re-read the Uninstall key
# here for the launch target and the uninstall string.
function Get-ProgramProps {
    param([string]$DisplayName)

    foreach ($props in Get-UninstallEntries) {
        if ([string]$props.DisplayName -eq $DisplayName) { return $props }
    }
    return $null
}

function Get-ProgramExe {
    param([string]$DisplayName)

    $props = Get-ProgramProps -DisplayName $DisplayName
    if ($null -eq $props) { return '' }

    $icon = [string]$props.DisplayIcon
    if ($icon) {
        # "C:\path\app.exe,0"
        $icon = ($icon -split ',')[0].Trim('"', ' ')
        if ($icon -and (Test-Path -LiteralPath $icon)) { return $icon }
    }

    $loc = [string]$props.InstallLocation
    if ($loc -and (Test-Path -LiteralPath $loc)) {
        $exe = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }

    return ''
}

# Is a newer release available? This mirrors exactly how Install-GitHubRelease
# decides to upgrade: tag against the recorded stamp when there is one, else the
# app's own DisplayVersion with numeric cores only. A null comparison means
# "cannot tell", which is not an update.
function Test-GitHubOutdated {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Spec,
        [string]$InstalledVersion
    )

    try {
        $release = Get-GitHubLatestRelease -Repo $Spec.Repo
    } catch {
        # No network, rate limited, no releases: report nothing rather than guess.
        return $false
    }
    if ($null -eq $release -or -not $release.tag_name) { return $false }

    $latest = $release.tag_name -replace '^[vV]', ''
    $stamp = Get-GitHubReleaseStamp -Repo $Spec.Repo

    if ($stamp) {
        $comparison = Compare-VersionString -Left $latest -Right ($stamp -replace '^[vV]', '')
    } else {
        $comparison = Compare-VersionString -Left $latest -Right $InstalledVersion -IgnorePreRelease
    }

    if ($null -eq $comparison) { return $false }
    return ($comparison -gt 0)
}

# Run an UninstallString. These are free-form command lines, so exe and
# arguments are split here and handed to Start-Process separately - nothing is
# re-parsed as script.
function Invoke-UninstallString {
    param(
        [string]$Command,
        [string[]]$QuietArgs
    )

    $exe = ''
    $rest = ''
    if ($Command -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } elseif ($Command -match '^\s*(.*?\.exe)\s*(.*)$') {
        $exe = $Matches[1]; $rest = $Matches[2]
    } else {
        $exe = $Command.Trim()
    }

    $argList = @()
    if ($rest.Trim()) { $argList = @($rest -split '\s+' | Where-Object { $_ }) }

    if ([IO.Path]::GetFileNameWithoutExtension($exe) -eq 'msiexec') {
        # The recorded string installs (/I); the same product code uninstalls
        # under /X, and /qn is the MSI quiet switch.
        $argList = @($argList | ForEach-Object {
            if ($_ -match '^[/-][Ii]$') { '/X' }
            elseif ($_ -match '^[/-][Ii](.+)$') { '/X' + $Matches[1] }
            else { $_ }
        })
        if ($argList -notcontains '/qn') { $argList += '/qn' }
    } elseif ($QuietArgs) {
        # ponytail: best effort - reuse the entry's own quiet flag when it looks
        # like a switch. A bespoke uninstaller may still show a window.
        foreach ($flag in $QuietArgs) {
            if ($flag -match '^[/-]' -and $argList -notcontains $flag) { $argList += $flag }
        }
    }

    Write-Host "Running: $exe $($argList -join ' ')"
    try {
        if ($argList.Count -gt 0) {
            $proc = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
        } else {
            $proc = Start-Process -FilePath $exe -Wait -PassThru
        }
        return $proc.ExitCode
    } catch {
        Write-Err "Failed to run uninstaller ${exe}: $_"
        return 1
    }
}

# Install multiple GitHub-release packages from a list. Winget/choco packages
# are installed by Ansible in ops-server, not here.
function Install-PackageBatch {
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages,
        [switch]$DryRun,
        [switch]$Force
    )

    foreach ($package in $Packages) {
        Install-GitHubRelease -PackageSpec $package -DryRun:$DryRun -Force:$Force | Out-Null
    }
}

# Display status for a list of GitHub-release packages
function Show-PackageStatus {
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages,
        [string]$Category = ""
    )

    if ($Category) {
        Write-SubStep $Category
    }

    foreach ($package in $Packages) {
        # github specs are pipe-delimited; show just the repo
        $display = ($package -split '\|')[0].Trim()
        $installed = Test-GitHubPackage -PackageSpec $package

        if ($installed) {
            Write-Host "    [" -NoNewline
            Write-Host "X" -ForegroundColor Green -NoNewline
            Write-Host "] $display"
        } else {
            Write-Host "    [ ] $display" -ForegroundColor DarkGray
        }
    }
}

# Write summary of installation results
function Write-ResultsSummary {
    param(
        [string]$Title = "Installation Summary"
    )

    $results = Get-Results
    $total = $results.Installed.Count + $results.Skipped.Count + $results.Failed.Count

    if ($total -eq 0) {
        return
    }

    Write-Host ""
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor White
    Write-Host "--------------------------------------" -ForegroundColor DarkGray

    if ($results.Installed.Count -gt 0) {
        Write-Host "  Installed: " -NoNewline
        Write-Host $results.Installed.Count -ForegroundColor Green
    }

    if ($results.Skipped.Count -gt 0) {
        Write-Host "  Skipped:   " -NoNewline
        Write-Host $results.Skipped.Count -ForegroundColor DarkGray
    }

    if ($results.Failed.Count -gt 0) {
        Write-Host "  Failed:    " -NoNewline
        Write-Host $results.Failed.Count -ForegroundColor Red
        Write-Host ""
        Write-Host "  Failed packages:" -ForegroundColor Red
        foreach ($pkg in $results.Failed) {
            Write-Host "    - $pkg" -ForegroundColor Red
        }
    }

    Write-Host ""
}

# Non-zero when anything failed, for exit-code propagation.
function Get-FailureCount {
    return (Get-Results).Failed.Count
}

Export-ModuleMember -Function @(
    'Reset-Results',
    'Get-Results',
    'Get-FailureCount',
    'Test-GitHubPackage',
    'Format-ExitCode',
    'ConvertFrom-GitHubPackageSpec',
    'ConvertTo-VersionParts',
    'Compare-VersionString',
    'Get-InstalledProgram',
    'Get-GitHubReleaseStamp',
    'Set-GitHubReleaseStamp',
    'Get-GitHubLatestRelease',
    'Install-GitHubRelease',
    'Get-ProgramProps',
    'Get-ProgramExe',
    'Test-GitHubOutdated',
    'Invoke-UninstallString',
    'Install-PackageBatch',
    'Show-PackageStatus',
    'Write-ResultsSummary'
)
