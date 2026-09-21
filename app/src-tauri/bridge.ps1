# bridge.ps1 - Ops Launcher <-> lib/windows/packages.psm1
#
# Invoked as:
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 status  <repo>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 install <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 uninstall <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 update <repo> <kind> <spec>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 open    <url>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 icon    <exe> <outpng>
#   pwsh -NoProfile -NonInteractive -File bridge.ps1 launch  <exe>
#
# `status` prints one JSON array; `install`/`uninstall` stream plain text.

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'install', 'uninstall', 'update', 'icon', 'launch', 'open')]
    [string]$Verb,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Args2
)

$ErrorActionPreference = 'Stop'

function Import-OpsModules {
    param([string]$RepoRoot)
    Import-Module (Join-Path $RepoRoot 'lib\windows\common.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\packages.psm1') -Force
    Import-Module (Join-Path $RepoRoot 'lib\windows\comfyui.psm1') -Force
}

# owner/repo from a pipe-delimited spec line
function Get-SpecRepo {
    param([string]$Spec)
    return ($Spec -split '\|')[0].Trim()
}

function Get-SpecsIn {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $specs = @()
    Get-ChildItem -LiteralPath $Dir -Filter '*.txt' | Sort-Object Name | ForEach-Object {
        $specs += @(Read-PackageList -FilePath $_.FullName)
    }
    return $specs
}

# Get-InstalledProgram returns only Name/Version, so re-read the Uninstall key
# here for the launch target and the uninstall string.
function Get-ProgramProps {
    param([string]$DisplayName)

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            if ([string]$props.DisplayName -eq $DisplayName) { return $props }
        }
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
    if ($argList.Count -gt 0) {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    } else {
        $proc = Start-Process -FilePath $exe -Wait -PassThru
    }
    return $proc.ExitCode
}

switch ($Verb) {
    'status' {
        $repoRoot = $Args2[0]
        Import-OpsModules -RepoRoot $repoRoot
        $result = @()

        foreach ($spec in Get-SpecsIn (Join-Path $repoRoot 'config\packages\windows\github')) {
            $parsed = $null
            try { $parsed = ConvertFrom-GitHubPackageSpec -Spec $spec } catch { continue }
            $existing = Get-InstalledProgram -NamePattern $parsed.DisplayName
            $exe = ''
            $outdated = $false
            if ($null -ne $existing) {
                $exe = Get-ProgramExe -DisplayName $existing.Name
                $outdated = Test-GitHubOutdated -Spec $parsed -InstalledVersion $existing.Version
            }
            $result += [pscustomobject]@{
                id        = "github:$(Get-SpecRepo $spec)"
                installed = ($null -ne $existing)
                outdated  = $outdated
                exe       = $exe
            }
        }

        $nodeSpecs = @(Get-SpecsIn (Join-Path $repoRoot 'config\packages\windows\comfynodes'))
        if ($nodeSpecs.Count -gt 0) {
            $backends = @(Get-ComfyBackends)
            $customNodes = ''
            if ($backends.Count -gt 0) {
                $customNodes = Join-ComfyPath -Base $backends[0].BaseDir -Child 'custom_nodes'
            }
            foreach ($spec in $nodeSpecs) {
                $installed = $false
                if ($customNodes) {
                    $installed = Test-ComfyNodeInstalled -PackageSpec $spec -CustomNodesDir $customNodes
                }
                # No cheap way to know a node checkout is behind without fetching.
                $result += [pscustomobject]@{
                    id        = "comfynode:$(Get-SpecRepo $spec)"
                    installed = $installed
                    outdated  = $false
                    exe       = ''
                }
            }
        }

        # @() keeps a single entry from serialising as a bare object
        ConvertTo-Json -InputObject @($result) -Depth 4 -Compress
    }

    { $_ -in 'install', 'update' } {
        # -Force is the repo's upgrade path: it reinstalls a GitHub release at
        # the latest tag and fast-forwards a node checkout.
        $force = ($Verb -eq 'update')
        $repoRoot = $Args2[0]
        $kind = $Args2[1]
        $spec = $Args2[2]
        Import-OpsModules -RepoRoot $repoRoot

        if ($kind -eq 'github') {
            Install-GitHubRelease -PackageSpec $spec -Force:$force | Out-Null
        } else {
            $backends = @(Get-ComfyBackends)
            if ($backends.Count -eq 0) {
                Write-Host 'No ComfyUI install found - launch Comfy Desktop once, then retry'
                exit 1
            }
            foreach ($backend in $backends) {
                Install-ComfyNode -PackageSpec $spec -BaseDir $backend.BaseDir -Force:$force | Out-Null
            }
        }

        if ((Get-FailureCount) -gt 0) { exit 1 }
    }

    'uninstall' {
        $repoRoot = $Args2[0]
        $kind = $Args2[1]
        $spec = $Args2[2]
        Import-OpsModules -RepoRoot $repoRoot

        if ($kind -eq 'github') {
            $parsed = ConvertFrom-GitHubPackageSpec -Spec $spec
            $existing = Get-InstalledProgram -NamePattern $parsed.DisplayName
            if ($null -eq $existing) {
                Write-Host "$($parsed.DisplayName) is not in Add/Remove Programs"
                exit 0
            }

            $props = Get-ProgramProps -DisplayName $existing.Name
            $command = ''
            if ($null -ne $props) {
                $command = [string]$props.QuietUninstallString
                if (-not $command) { $command = [string]$props.UninstallString }
            }
            if (-not $command) {
                Write-Host "No uninstall string recorded for $($existing.Name)"
                exit 1
            }

            $code = Invoke-UninstallString -Command $command -QuietArgs $parsed.InstallArgs
            if ($code -ne 0) {
                Write-Host "Uninstaller exited $(Format-ExitCode -Code $code)"
                exit 1
            }
            Write-Host "Removed $($existing.Name)"
        } else {
            $parsed = ConvertFrom-ComfyNodeSpec -Spec $spec
            $backends = @(Get-ComfyBackends)
            if ($backends.Count -eq 0) {
                Write-Host 'No ComfyUI install found'
                exit 1
            }
            foreach ($backend in $backends) {
                $customNodes = Join-ComfyPath -Base $backend.BaseDir -Child 'custom_nodes'
                $target = Join-ComfyPath -Base $customNodes -Child $parsed.Directory
                if (Test-ComfyPathReachable -Path $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                    Write-Host "Removed $target"
                } else {
                    Write-Host "Not present: $target"
                }
            }
            Write-Host 'Restart Comfy Desktop to unload the node'
        }
    }

    'launch' {
        # -FilePath with a literal path: nothing here is re-parsed as script,
        # so spaces and metacharacters in the path are inert.
        Start-Process -FilePath $Args2[0]
    }

    'open' {
        $url = $Args2[0]
        # The shell handler will run anything; only web URLs get through.
        if ($url -notmatch '^https?://') {
            Write-Host "Refusing to open $url"
            exit 1
        }
        Start-Process -FilePath $url
    }

    'icon' {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Args2[0])
        if ($null -eq $icon) { exit 1 }
        $icon.ToBitmap().Save($Args2[1], [System.Drawing.Imaging.ImageFormat]::Png)
    }
}
