# houdini.psm1 - Houdini on Windows, installed and configured from the repo
#
# The Windows twin of platforms/macos/installers/houdini.sh, driven by
# platforms/windows/installers/houdini.ps1 (Loadout kind `installer`):
#
#   - resolves the latest production build (or the HOUDINI_VERSION pin)
#     through the SideFX Web API, with the credentials Loadout's Settings
#     writes to config/sidefx.local, downloads it (md5-checked) and runs the
#     installer silently, elevated - one UAC prompt
#   - per installed X.Y, in Documents\houdiniX.Y (Houdini's own pref dir on
#     Windows): packages\loadout.json puts config/dcc/houdini on HOUDINI_PATH,
#     houdini.pref opens the ALX desk, SideFX Labs is installed from GitHub
#   - installs fxhoudinimcp as a uv tool and registers it with Claude Code
#   - server licensing points hserver at HOUDINI_LICENSE_SERVER
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

$script:Api = 'https://www.sidefx.com/api/'
$script:TokenUrl = 'https://www.sidefx.com/oauth2/application_token'
$script:LabsReleases = 'https://api.github.com/repos/sideeffects/SideFXLabs/releases?per_page=100'
$script:LabsZipball = 'https://api.github.com/repos/sideeffects/SideFXLabs/zipball'
$script:Desk = 'general.desk.val := "ALX";'
# The EULA revision the silent installer must be told was accepted.
$script:Eula = '2021-10-13'

function Get-HoudiniSettings {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Read-ConfFile -Path (Join-Path $RepoRoot 'config\sidefx.local'))
}

function Get-HoudiniRoot { return (Join-Path $env:ProgramFiles 'Side Effects Software') }

# Every installed build dir ("Houdini 22.0.459"), oldest first.
function Get-HoudiniBuilds {
    return @(Get-ChildItem -LiteralPath (Get-HoudiniRoot) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Houdini (\d+\.\d+\.\d+)$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'bin')) } |
        Sort-Object { [version]($_.Name -replace '^Houdini ', '') })
}

function Get-BuildVersion { param($Dir) return ($Dir.Name -replace '^Houdini ', '') }
function Get-BuildXY { param($Dir) return ((Get-BuildVersion $Dir) -replace '\.\d+$', '') }

# Newest build, or the newest matching the HOUDINI_VERSION X.Y pin.
function Get-HoudiniBuild {
    param([hashtable]$Settings)
    $builds = Get-HoudiniBuilds
    $pin = $Settings['HOUDINI_VERSION']
    if ($pin) { $builds = @($builds | Where-Object { (Get-BuildXY $_) -eq $pin }) }
    if ($builds.Count -eq 0) { return $null }
    return $builds[-1]
}

# The edition the license calls for, falling back so something launches.
function Get-HoudiniEditionExe {
    param($Dir, [hashtable]$Settings)
    $order = switch ($Settings['HOUDINI_LICENSE']) {
        'indie'       { 'hindie', 'houdinifx', 'happrentice' }
        'server'      { 'houdinifx', 'houdinicore', 'happrentice' }
        'server-core' { 'houdinicore', 'houdinifx', 'happrentice' }
        default       { 'happrentice', 'houdinifx' }
    }
    foreach ($name in $order) {
        $exe = Join-Path $Dir.FullName "bin\$name.exe"
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return ''
}

function Get-HoudiniPrefDir {
    param([string]$XY)
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "houdini$XY")
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# --- MCP -------------------------------------------------------------------

# fxhoudinimcp's Houdini plugin ships inside the wheel, so the path Houdini
# loads must stay stable: `uv tool install` gives that, uvx's cache does not.
function Get-HoudiniMcpPluginDir {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { return '' }
    $toolDir = (& $uv.Source tool dir 2>$null | Select-Object -First 1)
    if (-not $toolDir) { return '' }
    $dir = Join-Path $toolDir 'fxhoudinimcp\Lib\site-packages\fxhoudinimcp\houdini'
    if (Test-Path -LiteralPath $dir) { return $dir }
    return ''
}

# Shared by the writer and the checker so they cannot drift.
function Get-HoudiniMcpJson {
    param([string]$PluginDir)
    return ('{"env": [{"FXHOUDINIMCP": "' + ($PluginDir -replace '\\', '/') + '"}], "path": "$FXHOUDINIMCP"}')
}

function Get-HoudiniLoadoutJson {
    param([string]$RepoRoot)
    return ('{"path": "' + ((Join-Path $RepoRoot 'config\dcc\houdini') -replace '\\', '/') + '"}')
}

# Never fails the run: a broken or offline MCP step must not sink config.
function Install-HoudiniMcp {
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { Write-Skip 'Houdini MCP: uv not found'; return }

    $ErrorActionPreference = 'Continue'
    Write-Step 'Installing fxhoudinimcp'
    & $uv.Source tool install --upgrade fxhoudinimcp 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LASTEXITCODE -ne 0) {
        if (Get-HoudiniMcpPluginDir) { Write-Warn 'fxhoudinimcp upgrade failed; keeping the existing install' }
        else { Write-Warn 'fxhoudinimcp install failed; skipping MCP'; return }
    }

    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { Write-Skip 'Houdini MCP registration: claude not found'; return }
    $python = Join-Path (& $uv.Source tool dir | Select-Object -First 1) 'fxhoudinimcp\Scripts\python.exe'
    Write-Step 'Registering Houdini MCP with Claude Code'
    & $claude.Source mcp remove -s user houdini *> $null
    & $claude.Source mcp add -s user houdini -- $python -m fxhoudinimcp
    if ($LASTEXITCODE -ne 0) { Write-Warn 'Houdini MCP registration failed' }
}

# --- SideFX Labs -----------------------------------------------------------

# Latest Labs release for one Houdini X.Y (tags are X.Y.ZZZ), or ''.
function Get-LabsLatestTag {
    param([string]$XY)
    try {
        $releases = Invoke-RestMethod -Uri $script:LabsReleases -UseBasicParsing
    } catch {
        return ''
    }
    $tags = @($releases | ForEach-Object { $_.tag_name } |
        Where-Object { $_ -match "^$([regex]::Escape($XY))\.\d+$" } |
        Sort-Object { [int]($_ -replace '^.*\.', '') })
    if ($tags.Count -eq 0) { return '' }
    return $tags[-1]
}

# Never fails the run: no release for a new X.Y yet, or a network error, is a warning.
function Install-HoudiniLabs {
    param([string]$XY, [string]$Action)

    $pkgdir = Join-Path (Get-HoudiniPrefDir $XY) 'packages'
    $dir = Join-Path $pkgdir "SideFXLabs$XY"
    $json = Join-Path $pkgdir "SideFXLabs$XY.json"
    $tagFile = Join-Path $dir '.ops-tag'

    $tag = Get-LabsLatestTag -XY $XY
    if (-not $tag) { Write-Warn "SideFX Labs: no release for Houdini $XY yet; skipping"; return }
    if ($Action -ne 'reinstall' -and (Test-Path -LiteralPath $tagFile) -and
        (Get-Content -LiteralPath $tagFile -Raw).Trim() -eq $tag) { return }

    Write-Step "Installing SideFX Labs $tag for Houdini $XY"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadout-labs-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "$script:LabsZipball/$tag" -OutFile "$tmp\labs.zip" -UseBasicParsing
        & tar.exe -xf "$tmp\labs.zip" -C $tmp
        # The zipball holds a single sideeffects-SideFXLabs-<sha> dir.
        $src = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'sideeffects-SideFXLabs-*')[0]
        if (-not $src) { Write-Warn "SideFX Labs ${tag}: unexpected zipball layout"; return }

        New-Item -ItemType Directory -Path $pkgdir -Force | Out-Null
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        Move-Item -LiteralPath $src.FullName -Destination $dir

        $pkg = Get-Content -LiteralPath (Join-Path $dir 'SideFXLabs.json') -Raw | ConvertFrom-Json
        $pkg | Add-Member -NotePropertyName env -NotePropertyValue @(@{ SIDEFXLABS = "`$HOUDINI_PACKAGE_PATH/SideFXLabs$XY" }) -Force
        Write-Utf8 -Path $json -Text ($pkg | ConvertTo-Json -Depth 8)
        Write-Utf8 -Path $tagFile -Text $tag
        Write-Host "    SideFX Labs $tag installed for Houdini $XY"
    } catch {
        Write-Warn "SideFX Labs $tag failed: $_"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- config ----------------------------------------------------------------

# Whether one X.Y's config matches the repo. Offline and write-free: status
# runs it at Loadout startup.
function Test-HoudiniConfigXY {
    param([string]$RepoRoot, [string]$XY)

    $prefs = Get-HoudiniPrefDir $XY
    $pkgdir = Join-Path $prefs 'packages'
    $loadout = Join-Path $pkgdir 'loadout.json'
    $pref = Join-Path $prefs 'houdini.pref'
    if (-not (Test-Path -LiteralPath $loadout) -or
        (Get-Content -LiteralPath $loadout -Raw).Trim() -ne (Get-HoudiniLoadoutJson -RepoRoot $RepoRoot)) { return $false }
    if (-not (Test-Path -LiteralPath $pref) -or
        -not (@(Get-Content -LiteralPath $pref) -contains $script:Desk)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $pkgdir "SideFXLabs$XY")) -or
        -not (Test-Path -LiteralPath (Join-Path $pkgdir "SideFXLabs$XY.json"))) { return $false }
    # No uv -> MCP is not required, so the machine is never permanently
    # outdated; uv present but the tool missing -> outdated, so Update installs it.
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $plugin = Get-HoudiniMcpPluginDir
        if (-not $plugin) { return $false }
        $mcp = Join-Path $pkgdir 'fxhoudinimcp.json'
        if (-not (Test-Path -LiteralPath $mcp) -or
            (Get-Content -LiteralPath $mcp -Raw).Trim() -ne (Get-HoudiniMcpJson -PluginDir $plugin)) { return $false }
    }
    return $true
}

function Set-HoudiniConfigXY {
    param([string]$RepoRoot, [string]$XY, [string]$Action)

    $prefs = Get-HoudiniPrefDir $XY
    $pkgdir = Join-Path $prefs 'packages'
    New-Item -ItemType Directory -Path $pkgdir -Force | Out-Null

    Write-Utf8 -Path (Join-Path $pkgdir 'loadout.json') -Text (Get-HoudiniLoadoutJson -RepoRoot $RepoRoot)
    Write-Host "Wrote $pkgdir\loadout.json (HOUDINI_PATH -> config\dcc\houdini)"

    $plugin = Get-HoudiniMcpPluginDir
    if ($plugin) {
        Write-Utf8 -Path (Join-Path $pkgdir 'fxhoudinimcp.json') -Text (Get-HoudiniMcpJson -PluginDir $plugin)
        Write-Host "Wrote $pkgdir\fxhoudinimcp.json"
    }

    $pref = Join-Path $prefs 'houdini.pref'
    $lines = @()
    if (Test-Path -LiteralPath $pref) { $lines = @(Get-Content -LiteralPath $pref | Where-Object { $_ -notmatch '^general\.desk\.val' }) }
    Write-Utf8 -Path $pref -Text ((@($lines) + $script:Desk) -join "`r`n")
    Write-Host "Set general.desk.val := `"ALX`" for Houdini $XY"

    Install-HoudiniLabs -XY $XY -Action $Action
}

# hserver ships inside the build. Not part of the check: querying hserver can
# start the licensing daemon, and status must stay side-effect-free.
function Set-HoudiniLicense {
    param([hashtable]$Settings)

    $build = Get-HoudiniBuild -Settings $Settings
    if (-not $build) { return $true }
    $mode = $Settings['HOUDINI_LICENSE']
    if (-not $mode) { $mode = 'apprentice' }
    if ($mode -notlike 'server*') {
        Write-Host "License: $mode - activate it in Houdini's License Administrator (Houdini opens it on first launch)"
        return $true
    }
    if (-not $Settings['HOUDINI_LICENSE_SERVER']) {
        Write-Err 'HOUDINI_LICENSE_SERVER is not set; set it in Loadout Settings'
        return $false
    }
    $hserver = Join-Path $build.FullName 'bin\hserver.exe'
    if (-not (Test-Path -LiteralPath $hserver)) { Write-Warn 'hserver.exe not found; skipping license step'; return $true }
    & $hserver -S $Settings['HOUDINI_LICENSE_SERVER']
    Write-Host "License: server -> $($Settings['HOUDINI_LICENSE_SERVER'])"
    return $true
}

# Config for every installed build's X.Y, then the license.
function Set-HoudiniConfig {
    param([string]$RepoRoot, [string]$Action = 'configure')

    $settings = Get-HoudiniSettings -RepoRoot $RepoRoot
    $xys = @(Get-HoudiniBuilds | ForEach-Object { Get-BuildXY $_ } | Select-Object -Unique)
    if ($xys.Count -eq 0) { Write-Err 'Houdini is not installed'; return $false }

    Install-HoudiniMcp
    $ok = $true
    foreach ($xy in $xys) {
        try { Set-HoudiniConfigXY -RepoRoot $RepoRoot -XY $xy -Action $Action } catch { Write-Err "Houdini $xy config: $_"; $ok = $false }
    }
    if (-not (Set-HoudiniLicense -Settings $settings)) { $ok = $false }
    return $ok
}

# Launch target and drift for the status build, or $null when not installed.
function Get-HoudiniStatus {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $settings = Get-HoudiniSettings -RepoRoot $RepoRoot
    $build = Get-HoudiniBuild -Settings $settings
    if (-not $build) { return $null }
    $exe = Get-HoudiniEditionExe -Dir $build -Settings $settings
    if (-not $exe) { return $null }
    return @{ Exe = $exe; Outdated = -not (Test-HoudiniConfigXY -RepoRoot $RepoRoot -XY (Get-BuildXY $build)) }
}

# --- install ---------------------------------------------------------------

function Invoke-SideFXApi {
    param([string]$Token, [string]$Json)
    return (Invoke-RestMethod -Uri $script:Api -Method Post -Headers @{ Authorization = "Bearer $Token" } `
        -Body @{ json = $Json } -UseBasicParsing)
}

function Install-Houdini {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'reinstall')][string]$Action
    )

    $settings = Get-HoudiniSettings -RepoRoot $RepoRoot
    if (-not $settings['SIDEFX_CLIENT_ID'] -or -not $settings['SIDEFX_CLIENT_SECRET']) {
        Write-Err 'SideFX API credentials are not set. In Loadout, open Settings (gear icon) and follow the steps there.'
        return $false
    }
    $pin = $settings['HOUDINI_VERSION']

    Write-Step "Resolving latest production build$(if ($pin) { " ($pin)" })"
    $ProgressPreference = 'SilentlyContinue'
    try {
        $pair = "$($settings['SIDEFX_CLIENT_ID']):$($settings['SIDEFX_CLIENT_SECRET'])"
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        $token = (Invoke-RestMethod -Uri $script:TokenUrl -Method Post -Headers @{ Authorization = "Basic $basic" } -UseBasicParsing).access_token
    } catch {
        Write-Err 'Could not get a SideFX access token - check the Client ID and secret in Settings.'
        return $false
    }

    $builds = @(Invoke-SideFXApi -Token $token -Json '["download.get_daily_builds_list", ["houdini"], {"platform":"win64","only_production":true}]' |
        Where-Object { $_.status -eq 'good' -and (-not $pin -or $_.version -eq $pin) } |
        Sort-Object { [version]"$($_.version).$($_.build)" })
    if ($builds.Count -eq 0) { Write-Err "No good production build$(if ($pin) { " of Houdini $pin" }) for win64."; return $false }
    $version = "$($builds[-1].version).$($builds[-1].build)"
    Write-Host "    latest: $version"

    $current = Get-HoudiniBuild -Settings $settings
    if ($current) { Write-Host "    installed: $(Get-BuildVersion $current)" }
    if ($current -and $Action -ne 'reinstall' -and (Get-BuildVersion $current) -eq $version) {
        Write-Host "Houdini $version is already the latest production build."
        return (Set-HoudiniConfig -RepoRoot $RepoRoot -Action $Action)
    }

    $info = Invoke-SideFXApi -Token $token -Json "[`"download.get_daily_build_download`", [`"houdini`", `"$($builds[-1].version)`", `"$($builds[-1].build)`", `"win64`"], {}]"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadout-houdini-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $exe = Join-Path $tmp $info.filename
        Write-Step ("Downloading {0} ({1:N1} GB)" -f $info.filename, ($info.size / 1GB))
        # ponytail: no progress lines for the multi-GB download.
        & curl.exe -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o $exe $info.download_url
        if ($LASTEXITCODE -ne 0) { Write-Err "Download failed (curl exit $LASTEXITCODE)"; return $false }

        Write-Step 'Verifying checksum'
        $actual = (Get-FileHash -LiteralPath $exe -Algorithm MD5).Hash.ToLower()
        if ($actual -ne $info.hash.ToLower()) { Write-Err "Checksum mismatch: expected $($info.hash), got $actual"; return $false }

        $dir = Join-Path (Get-HoudiniRoot) "Houdini $version"
        Write-Step 'Installing (accept the Windows administrator prompt)'
        $installArgs = @('/S', "/AcceptEULA=$script:Eula", '/MainApp=Yes', '/Registry=Yes', '/LicenseServer=No',
            '/StartMenu=Yes', '/DesktopIcon=No', '/FileAssociations=Yes', '/HoudiniServer=Yes',
            '/EngineUnity=No', '/EngineMaya=No', '/EngineUnreal=No', '/SideFXLabs=No',
            '/HQueueServer=No', '/HQueueClient=No', '/IndustryFileAssociations=Yes', "/InstallDir=`"$dir`"")  # quoted: Start-Process joins these without quoting
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $installArgs -Verb RunAs -Wait -PassThru
        } catch {
            Write-Err "The installer did not start (administrator prompt declined?): $_"
            return $false
        }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'bin'))) {
            Write-Err "The installer exited $($proc.ExitCode) without installing into $dir"
            return $false
        }
        Write-Host "Houdini $version installed."
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    return (Set-HoudiniConfig -RepoRoot $RepoRoot -Action $Action)
}

# Removes the status build; its X.Y's config and Labs only when no other
# installed build shares that X.Y. Leaves Documents\houdiniX.Y otherwise alone.
function Uninstall-Houdini {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $settings = Get-HoudiniSettings -RepoRoot $RepoRoot
    $build = Get-HoudiniBuild -Settings $settings
    if (-not $build) { Write-Host 'Houdini is not installed.'; return $true }
    $xy = Get-BuildXY $build

    if (@(Get-HoudiniBuilds | Where-Object { (Get-BuildXY $_) -eq $xy -and $_.FullName -ne $build.FullName }).Count -eq 0) {
        $pkgdir = Join-Path (Get-HoudiniPrefDir $xy) 'packages'
        foreach ($item in 'loadout.json', 'fxhoudinimcp.json', "SideFXLabs$xy.json", "SideFXLabs$xy") {
            $path = Join-Path $pkgdir $item
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Host "Removed $path" }
        }
    }

    $uninstaller = @(Get-ChildItem -LiteralPath $build.FullName -Filter 'Uninstall*.exe' -ErrorAction SilentlyContinue)[0]
    if (-not $uninstaller) { Write-Err "No uninstaller found in $($build.FullName)"; return $false }
    Write-Step "Removing Houdini $(Get-BuildVersion $build) (accept the Windows administrator prompt)"
    try {
        Start-Process -FilePath $uninstaller.FullName -ArgumentList '/S' -Verb RunAs -Wait | Out-Null
    } catch {
        Write-Err "The uninstaller did not start: $_"
        return $false
    }
    Write-Host "Removed $($build.FullName)"
    return $true
}

Export-ModuleMember -Function @(
    'Get-HoudiniStatus',
    'Install-Houdini',
    'Set-HoudiniConfig',
    'Uninstall-Houdini',
    'Test-HoudiniConfigXY'
)
