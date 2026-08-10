# packages.psm1 - Package management functions for Windows setup
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force
# ComfyUI custom nodes install into the app's own tree
Import-Module (Join-Path $PSScriptRoot "comfyui.psm1") -Global -Force

# Track installation results
$script:Results = @{
    Installed = @()
    Skipped   = @()
    Failed    = @()
}

# Cache of locally installed Chocolatey package names (lowercase).
# Querying choco once beats spawning it per package.
$script:ChocoInstalled = $null
$script:ChocoListArgs = $null

# Winget exit codes that are not real failures.
# See https://learn.microsoft.com/windows/package-manager/winget/returnCodes
$script:WingetBenignExit = @{
    0           = 'installed'
    -1978335189 = 'no applicable upgrade'   # 0x8A15002B UPDATE_NOT_APPLICABLE
    -1978335135 = 'already installed'       # 0x8A150061 PACKAGE_ALREADY_INSTALLED
    3010        = 'installed (reboot required)'
    1641        = 'installed (reboot initiated)'
}

# Chocolatey exit codes that indicate success.
$script:ChocoBenignExit = @{
    0    = 'installed'
    3010 = 'installed (reboot required)'
    1641 = 'installed (reboot initiated)'
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
    $script:ChocoInstalled = $null
}

function Get-Results {
    return $script:Results
}

# Check if winget is available
function Test-Winget {
    return $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
}

# Check if chocolatey is available
function Test-Chocolatey {
    return $null -ne (Get-Command choco -ErrorAction SilentlyContinue)
}

# Chocolatey 2.x removed --local-only ("choco list" is local by default) and
# errors out when it is passed. Pick the argument set that matches the
# installed major version.
function Get-ChocoListArgs {
    if ($null -ne $script:ChocoListArgs) {
        return $script:ChocoListArgs
    }

    $major = 0
    try {
        $version = (& choco --version 2>$null | Select-Object -First 1)
        if ($version -match '^(\d+)') {
            $major = [int]$matches[1]
        }
    } catch {
        $major = 0
    }

    if ($major -ge 2) {
        $script:ChocoListArgs = @('--limit-output')
    } else {
        $script:ChocoListArgs = @('--local-only', '--limit-output')
    }

    return $script:ChocoListArgs
}

# Build (and cache) the set of locally installed Chocolatey packages.
function Get-ChocoInstalled {
    if ($null -ne $script:ChocoInstalled) {
        return $script:ChocoInstalled
    }

    $installed = @{}

    if (Test-Chocolatey) {
        $listArgs = @('list') + (Get-ChocoListArgs)
        try {
            $output = & choco @listArgs 2>$null
            foreach ($line in $output) {
                if (-not $line) { continue }
                # --limit-output emits "name|version"
                $name = ($line -split '\|')[0].Trim()
                if ($name) {
                    $installed[$name.ToLower()] = $true
                }
            }
        } catch {
            # Leave the cache empty; callers fall back to attempting installs.
        }
    }

    $script:ChocoInstalled = $installed
    return $script:ChocoInstalled
}

# Install Chocolatey if not present
function Install-Chocolatey {
    param(
        [switch]$DryRun
    )

    if (Test-Chocolatey) {
        Write-Skip "Chocolatey already installed"
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would install Chocolatey"
        return $true
    }

    Write-Status "Installing Chocolatey..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        $installScript = Invoke-RestMethod -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing
        Invoke-Expression $installScript

        # Refresh environment so choco is visible in this session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        if (Test-Chocolatey) {
            Write-Success "Chocolatey installed successfully"
            return $true
        } else {
            Write-Err "Chocolatey installation failed"
            return $false
        }
    } catch {
        Write-Err "Failed to install Chocolatey: $_"
        return $false
    }
}

# Check if a winget package is installed.
# Uses an ordinal substring test rather than -match: package ids contain dots,
# which -match would treat as "any character" and produce false positives.
function Test-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (-not (Test-Winget)) {
        return $false
    }

    $output = & winget list --id $PackageId --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    if (-not $output) {
        return $false
    }

    $joined = ($output | Out-String)
    return $joined.IndexOf($PackageId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Check if a chocolatey package is installed
function Test-ChocoPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageName
    )

    $installed = Get-ChocoInstalled
    return $installed.ContainsKey($PackageName.ToLower())
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

# Install a single winget package
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [switch]$DryRun,
        [switch]$Force
    )

    # Check if already installed
    if (-not $Force -and (Test-WingetPackage -PackageId $PackageId)) {
        Write-Skip "$PackageId (already installed)"
        $script:Results.Skipped += $PackageId
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would install: $PackageId"
        return $true
    }

    Write-Status "Installing $PackageId..."
    try {
        $installArgs = @(
            'install',
            '--id', $PackageId,
            '--exact',
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements'
        )
        if ($Force) {
            $installArgs += '--force'
        }

        $output = & winget @installArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($script:WingetBenignExit.ContainsKey($exitCode)) {
            Write-Success "$PackageId $($script:WingetBenignExit[$exitCode])"
            $script:Results.Installed += $PackageId
            return $true
        }

        Write-Err "Failed to install $PackageId - exit $(Format-ExitCode -Code $exitCode)"
        $detail = ($output | Select-Object -Last 3 | Out-String).Trim()
        if ($detail) {
            Write-Host "    $detail" -ForegroundColor DarkGray
        }
        $script:Results.Failed += $PackageId
        return $false
    } catch {
        Write-Err "Error installing ${PackageId}: $_"
        $script:Results.Failed += $PackageId
        return $false
    }
}

# Install a single chocolatey package
function Install-ChocoPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSpec,
        [switch]$DryRun,
        [switch]$Force
    )

    # Parse package spec (may include flags like --pre)
    $parts = $PackageSpec -split '\s+'
    $packageName = $parts[0]
    $extraArgs = @()
    if ($parts.Count -gt 1) {
        $extraArgs = $parts[1..($parts.Count - 1)]
    }

    # Check if already installed
    if (-not $Force -and (Test-ChocoPackage -PackageName $packageName)) {
        Write-Skip "$packageName (already installed)"
        $script:Results.Skipped += $packageName
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would install: $PackageSpec"
        return $true
    }

    Write-Status "Installing $packageName..."
    try {
        $installArgs = @('install', $packageName, '-y', '--no-progress')
        if ($Force) {
            $installArgs += '--force'
        }
        $installArgs += $extraArgs

        $output = & choco @installArgs 2>&1
        $exitCode = $LASTEXITCODE

        if ($script:ChocoBenignExit.ContainsKey($exitCode)) {
            Write-Success "$packageName $($script:ChocoBenignExit[$exitCode])"
            $script:Results.Installed += $packageName
            # Keep the cache in step so later lookups stay accurate
            if ($null -ne $script:ChocoInstalled) {
                $script:ChocoInstalled[$packageName.ToLower()] = $true
            }
            return $true
        }

        Write-Err "Failed to install $packageName - exit $(Format-ExitCode -Code $exitCode)"
        $detail = ($output | Select-Object -Last 3 | Out-String).Trim()
        if ($detail) {
            Write-Host "    $detail" -ForegroundColor DarkGray
        }
        $script:Results.Failed += $packageName
        return $false
    } catch {
        Write-Err "Error installing ${packageName}: $_"
        $script:Results.Failed += $packageName
        return $false
    }
}

# --- GitHub release installs -------------------------------------------------
#
# Some apps ship only as a GitHub release asset, with no winget or Chocolatey
# package. Entries in config/packages/windows/github/*.txt are pipe-delimited:
#
#   owner/repo | asset-pattern | display-name | install-args
#
#   asset-pattern  wildcard matched against release asset names (default *.exe)
#   display-name   matched against Add/Remove Programs to detect an existing
#                  install; wildcards honoured, otherwise substring (default:
#                  the repo name)
#   install-args   passed to the downloaded installer (default /quiet)
#
# Only the repo is required. Unlike winget and Chocolatey there is no version
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

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $isWildcard = $NamePattern.Contains('*') -or $NamePattern.Contains('?')

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $keys = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        foreach ($key in $keys) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
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
$script:GitHubStampKey = 'HKCU:\Software\ops-workstation\GitHubReleases'

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
        'User-Agent' = 'ops-workstation-setup'
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

# --- ComfyUI custom nodes ---------------------------------------------------
#
# Custom nodes are git repos cloned into ComfyUI's custom_nodes\ directory, with
# their Python requirements installed into the backend's own .venv. Entries in
# config/packages/windows/comfynodes/*.txt are:
#
#   owner/repo | directory-name
#
# The directory name defaults to the repo name, which is what ComfyUI Manager
# would have used. Installed nodes are skipped; -Force fast-forwards them.

function ConvertFrom-ComfyNodeSpec {
    param(
        [Parameter(Mandatory)]
        [string]$Spec
    )

    $parts = $Spec -split '\|'
    $repo = $parts[0].Trim()

    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') {
        throw "Invalid ComfyUI node spec '$Spec' - expected 'owner/repo | directory-name'"
    }

    $directory = ($repo -split '/')[1]
    if ($parts.Count -ge 2 -and $parts[1].Trim()) {
        $directory = $parts[1].Trim()
    }

    return @{
        Repo      = $repo
        Directory = $directory
        Url       = "https://github.com/$repo.git"
    }
}

function Test-ComfyNodeInstalled {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSpec,
        [Parameter(Mandatory)]
        [string]$CustomNodesDir
    )

    try {
        $spec = ConvertFrom-ComfyNodeSpec -Spec $PackageSpec
    } catch {
        return $false
    }

    $target = Join-ComfyPath -Base $CustomNodesDir -Child $spec.Directory
    return (Test-ComfyPathReachable -Path $target)
}

# Install (or fast-forward) one custom node into a single backend.
function Install-ComfyNode {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSpec,
        [Parameter(Mandatory)]
        [string]$BaseDir,
        [switch]$DryRun,
        [switch]$Force
    )

    try {
        $spec = ConvertFrom-ComfyNodeSpec -Spec $PackageSpec
    } catch {
        Write-Err $_.Exception.Message
        $script:Results.Failed += $PackageSpec
        return $false
    }

    $label = $spec.Repo

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git is required to install $label"
        $script:Results.Failed += $label
        return $false
    }

    $customNodes = Join-ComfyPath -Base $BaseDir -Child 'custom_nodes'
    $target = Join-ComfyPath -Base $customNodes -Child $spec.Directory
    $exists = Test-ComfyPathReachable -Path $target

    if ($exists -and -not $Force) {
        Write-Skip "$label (already installed)"
        $script:Results.Skipped += $label
        return $true
    }

    if ($DryRun) {
        if ($exists) {
            Write-DryRun "Would update: $label"
        } else {
            Write-DryRun "Would install: $label -> custom_nodes\$($spec.Directory)"
        }
        return $true
    }

    try {
        if ($exists) {
            Write-Status "Updating $label..."
            # --ff-only so local edits surface as a failure instead of a merge
            $output = & git -C $target pull --ff-only 2>&1
        } else {
            Write-Status "Installing $label..."
            if (-not (Test-ComfyPathReachable -Path $customNodes)) {
                New-Item -ItemType Directory -Path $customNodes -Force | Out-Null
            }
            $output = & git clone --depth 1 $spec.Url $target 2>&1
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Err "git failed for $label - exit $(Format-ExitCode -Code $LASTEXITCODE)"
            $detail = ($output | Select-Object -Last 3 | Out-String).Trim()
            if ($detail) {
                Write-Host "    $detail" -ForegroundColor DarkGray
            }
            $script:Results.Failed += $label
            return $false
        }

        if (-not (Install-ComfyNodeRequirements -Label $label -NodeDir $target -BaseDir $BaseDir)) {
            $script:Results.Failed += $label
            return $false
        }

        Write-Success "$label installed"
        $script:Results.Installed += $label
        return $true
    } catch {
        Write-Err "Error installing ${label}: $_"
        $script:Results.Failed += $label
        return $false
    }
}

function Install-ComfyNodeRequirements {
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [string]$NodeDir,
        [Parameter(Mandatory)]
        [string]$BaseDir
    )

    $requirements = Join-ComfyPath -Base $NodeDir -Child 'requirements.txt'
    if (-not (Test-ComfyPathReachable -Path $requirements)) {
        return $true
    }

    $python = Get-ComfyVenvPython -BaseDir $BaseDir
    if (-not $python) {
        Write-Warn "$Label has requirements but ComfyUI's .venv was not found - install them from the app"
        return $true
    }

    Write-SubStep "installing requirements"
    $output = & $python -m pip install --disable-pip-version-check -r $requirements 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "pip failed for $Label - exit $(Format-ExitCode -Code $LASTEXITCODE)"
        $detail = ($output | Select-Object -Last 5 | Out-String).Trim()
        if ($detail) {
            Write-Host "    $detail" -ForegroundColor DarkGray
        }
        return $false
    }

    return $true
}

# Install multiple packages from a list
function Install-PackageBatch {
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages,
        [Parameter(Mandatory)]
        [ValidateSet('winget', 'choco', 'github')]
        [string]$Manager,
        [switch]$DryRun,
        [switch]$Force
    )

    foreach ($package in $Packages) {
        if ($Manager -eq 'winget') {
            Install-WingetPackage -PackageId $package -DryRun:$DryRun -Force:$Force | Out-Null
        } elseif ($Manager -eq 'github') {
            Install-GitHubRelease -PackageSpec $package -DryRun:$DryRun -Force:$Force | Out-Null
        } else {
            Install-ChocoPackage -PackageSpec $package -DryRun:$DryRun -Force:$Force | Out-Null
        }
    }
}

# Display package status for a list
function Show-PackageStatus {
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages,
        [Parameter(Mandatory)]
        [ValidateSet('winget', 'choco', 'github')]
        [string]$Manager,
        [string]$Category = ""
    )

    if ($Category) {
        Write-SubStep $Category
    }

    foreach ($package in $Packages) {
        # Handle choco package specs with args
        $packageName = ($package -split '\s+')[0]
        $display = $package

        if ($Manager -eq 'winget') {
            $installed = Test-WingetPackage -PackageId $packageName
        } elseif ($Manager -eq 'github') {
            # github specs are pipe-delimited; show just the repo
            $display = ($package -split '\|')[0].Trim()
            $installed = Test-GitHubPackage -PackageSpec $package
        } else {
            $installed = Test-ChocoPackage -PackageName $packageName
        }

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
    'Test-Winget',
    'Test-Chocolatey',
    'Get-ChocoListArgs',
    'Get-ChocoInstalled',
    'Install-Chocolatey',
    'Test-WingetPackage',
    'Test-ChocoPackage',
    'Test-GitHubPackage',
    'Format-ExitCode',
    'ConvertFrom-GitHubPackageSpec',
    'ConvertTo-VersionParts',
    'Compare-VersionString',
    'Get-InstalledProgram',
    'Get-GitHubReleaseStamp',
    'Set-GitHubReleaseStamp',
    'Get-GitHubLatestRelease',
    'Install-WingetPackage',
    'Install-ChocoPackage',
    'Install-GitHubRelease',
    'ConvertFrom-ComfyNodeSpec',
    'Test-ComfyNodeInstalled',
    'Install-ComfyNode',
    'Install-ComfyNodeRequirements',
    'Install-PackageBatch',
    'Show-PackageStatus',
    'Write-ResultsSummary'
)
