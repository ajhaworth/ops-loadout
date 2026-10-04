# blender.psm1 - Blender on Windows, installed and configured from the repo
#
# The Windows twin of platforms/macos/installers/blender.sh, driven by
# platforms/windows/installers/blender.ps1 (Loadout kind `installer`). Not
# winget: BlenderFoundation.Blender's manifest downloads from
# download.blender.org, which sits behind a Cloudflare challenge and answers
# 403, so winget cannot install it at all. Instead:
#
#   1. the portable .zip comes from the same mirror blender.sh uses, into
#      %LOCALAPPDATA%\Programs\Blender - per user, no MSI, no admin
#   2. <that dir>\portable is a junction to config/dcc/blender/portable;
#      Blender treats a portable\ dir beside blender.exe as its config root,
#      so everything it saves lands in the repo, exactly as on macOS
#   3. extensions.txt is installed into it, setup.py runs windowed to
#      regenerate prefs, keymap and startup layout, and the Blender Lab MCP
#      server is registered with Claude Code
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

$script:Mirror = 'https://ftp.nluug.nl/pub/graphics/blender/release'

function Get-BlenderDir { return (Join-Path $env:LOCALAPPDATA 'Programs\Blender') }

# The installed version, recorded at install time (blender --version is slow).
function Get-BlenderVersion {
    $dir = Get-BlenderDir
    $file = Join-Path $dir 'loadout-version.txt'
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'blender.exe')) -or -not (Test-Path -LiteralPath $file)) { return '' }
    return (Get-Content -LiteralPath $file -Raw).Trim()
}

# Latest release on the mirror as @{ Version; Url }, or $null.
function Get-BlenderLatest {
    $ProgressPreference = 'SilentlyContinue'
    try {
        $listing = (Invoke-WebRequest -Uri "$script:Mirror/" -UseBasicParsing -TimeoutSec 35).Content
        $series = @([regex]::Matches($listing, 'Blender(\d+\.\d+)/') | ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique | Sort-Object { [version]$_ })[-1]
        if (-not $series) { return $null }
        $listing = (Invoke-WebRequest -Uri "$script:Mirror/Blender$series/" -UseBasicParsing -TimeoutSec 35).Content
        $version = @([regex]::Matches($listing, 'blender-([\d.]+)-windows-x64\.zip') | ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique | Sort-Object { [version]$_ })[-1]
        if (-not $version) { return $null }
        return @{ Version = $version; Url = "$script:Mirror/Blender$series/blender-$version-windows-x64.zip" }
    } catch {
        return $null
    }
}

# A junction's target, without the \\?\ prefix PowerShell 5.1 can report.
function Get-JunctionTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.LinkType) { return '' }
    return ((@($item.Target)[0]) -replace '^\\\\\?\\', '').TrimEnd('\')
}

# Remove a junction itself. Never Remove-Item -Recurse a tree that still holds
# the portable junction: Windows PowerShell can follow it into the repo.
function Remove-Junction {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) { $item.Delete() }
}

# Launch target and drift, for the bridge's status: ours only when portable\
# is our junction, so a Blender unpacked by hand reads as not installed.
function Get-BlenderStatus {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $dir = Get-BlenderDir
    $portable = Join-Path $RepoRoot 'config\dcc\blender\portable'
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'blender.exe'))) { return $null }
    if ((Get-JunctionTarget -Path (Join-Path $dir 'portable')) -ne $portable.TrimEnd('\')) { return $null }
    # blender-launcher.exe is the GUI build: no console window behind Blender.
    $launcher = Join-Path $dir 'blender-launcher.exe'
    if (-not (Test-Path -LiteralPath $launcher)) { $launcher = Join-Path $dir 'blender.exe' }
    return @{ Exe = $launcher; Outdated = -not (Test-BlenderConfigCurrent -RepoRoot $RepoRoot) }
}

# What setup applies once rather than reading live through the junction. A
# successful setup records this hash; status reports outdated when it drifts.
function Get-BlenderConfigHash {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($name in 'setup.py', 'extensions.txt') {
        $path = Join-Path $RepoRoot "config\dcc\blender\$name"
        if (Test-Path -LiteralPath $path) { $bytes.AddRange([IO.File]::ReadAllBytes($path)) }
    }
    $sha = [Security.Cryptography.SHA1]::Create()
    return (($sha.ComputeHash($bytes.ToArray()) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-BlenderConfigCurrent {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $stamp = Join-Path $RepoRoot 'config\dcc\blender\.configured'
    if (-not (Test-Path -LiteralPath $stamp)) { return $false }
    return ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq (Get-BlenderConfigHash -RepoRoot $RepoRoot))
}

# Run Blender, streaming its output without the per-chunk PROGRESS lines.
# blender.exe (not blender-launcher.exe) is the console build, so its output
# reaches this pipe. Returns the exit code.
function Invoke-Blender {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # Native stderr through 2>&1 must not trip a caller's Stop preference.
    $ErrorActionPreference = 'Continue'
    $env:PYTHONUNBUFFERED = '1'
    & $Exe --online-mode @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^PROGRESS' } | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}

# The manifest id inside an extension zip (root or one folder down), or ''.
function Get-ZipManifestId {
    param([Parameter(Mandatory)][string]$Zip)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -match '^([^/]+/)?blender_manifest\.toml$' } |
            Select-Object -First 1
        if (-not $entry) { return '' }
        $reader = New-Object IO.StreamReader($entry.Open())
        $text = $reader.ReadToEnd()
        $reader.Dispose()
        if ($text -match '(?m)^id\s*=\s*"([^"]+)"') { return $Matches[1] }
        return ''
    } finally {
        $archive.Dispose()
    }
}

# One extensions.txt entry. Adds its module to $Addons (for setup.py to
# re-enable) and returns $false on failure.
function Install-BlenderExtension {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Portable,
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Addons
    )

    $kind, $ref, $id = @($Line -split '\s+')
    switch ($kind) {
        'blender_org' {
            $Addons.Add("bl_ext.blender_org.$ref")
            if (Test-Path -LiteralPath (Join-Path $Portable "extensions\blender_org\$ref\blender_manifest.toml")) {
                Write-Host "$ref already installed; will re-enable during setup"
                return $true
            }
            return ((Invoke-Blender -Exe $Exe -Arguments @('--command', 'extension', 'install', $ref, '--sync', '--enable')) -eq 0)
        }
        { $_ -in 'github', 'forgejo' } {
            # An optional manifest id avoids re-downloading an installed plugin
            # just to discover its id (which need not match its repository name).
            if ($id -and (Test-Path -LiteralPath (Join-Path $Portable "extensions\user_default\$id\blender_manifest.toml"))) {
                $Addons.Add("bl_ext.user_default.$id")
                Write-Host "$ref already installed ($id); will re-enable during setup"
                return $true
            }

            if ($kind -eq 'github') {
                $api = "https://api.github.com/repos/$ref"
            } else {
                $hostName, $path = $ref -split '/', 2
                $api = "https://$hostName/api/v1/repos/$path"
            }
            $name = Split-Path $ref -Leaf
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadout-ext-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tmp | Out-Null
            try {
                $url = ''
                try {
                    $release = Invoke-RestMethod -Uri "$api/releases/latest" -UseBasicParsing
                    $url = @($release.assets | Where-Object { $_.browser_download_url -like '*.zip' })[0].browser_download_url
                } catch {
                    # No releases: fall back to the zipball below
                }
                $zip = Join-Path $tmp "$name.zip"
                if ($url) {
                    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                } else {
                    # A zipball unpacks to owner-repo-sha/, not a valid module
                    # name, so re-zip it under the repo name.
                    Invoke-WebRequest -Uri "$api/zipball" -OutFile "$tmp\ball.zip" -UseBasicParsing
                    Expand-Archive -LiteralPath "$tmp\ball.zip" -DestinationPath "$tmp\ball"
                    $top = @(Get-ChildItem -LiteralPath "$tmp\ball" -Directory)[0]
                    Rename-Item -LiteralPath $top.FullName -NewName $name
                    Compress-Archive -Path (Join-Path "$tmp\ball" $name) -DestinationPath $zip
                }

                $id = Get-ZipManifestId -Zip $zip
                if ($id) { $Addons.Add("bl_ext.user_default.$id") }
                if ($id -and (Test-Path -LiteralPath (Join-Path $Portable "extensions\user_default\$id\blender_manifest.toml"))) {
                    Write-Host "$ref already installed ($id); will re-enable during setup"
                    return $true
                }
                return ((Invoke-Blender -Exe $Exe -Arguments @('--command', 'extension', 'install-file', '-r', 'user_default', '--enable', $zip)) -eq 0)
            } catch {
                Write-Err "${ref}: $_"
                return $false
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        default {
            Write-Err "unknown extension kind: $kind"
            return $false
        }
    }
}

# install | update | reinstall | configure. Update downloads only when the
# mirror has a newer build, and a failed check keeps a working install and
# still reapplies config; reinstall always downloads; configure never does.
function Install-Blender {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('install', 'update', 'reinstall', 'configure')][string]$Action
    )

    $dir = Get-BlenderDir
    $cfg = Join-Path $RepoRoot 'config\dcc\blender'
    $portable = Join-Path $cfg 'portable'
    $current = Get-BlenderVersion
    if ($current) { Write-Host "    installed: $current" }

    if ($Action -eq 'configure') {
        if (-not $current) { Write-Err 'Blender is not installed; install it first'; return $false }
    } else {
        Write-Step 'Resolving latest Blender release'
        $latest = Get-BlenderLatest
        if ($latest) {
            Write-Host "    latest: $($latest.Version)"
        } elseif ($current -and $Action -ne 'reinstall') {
            Write-Warn "Could not check for a newer Blender; keeping $current and reapplying configuration"
        } else {
            Write-Err 'Could not resolve a Blender release on the mirror'
            return $false
        }

        if ($latest -and ($Action -eq 'reinstall' -or -not $current -or ([version]$latest.Version -gt [version]$current))) {
            if (Get-Process -Name 'blender', 'blender-launcher' -ErrorAction SilentlyContinue) {
                Write-Err 'Blender is running; close it and try again'
                return $false
            }
            if (-not (Install-BlenderBuild -Url $latest.Url -Version $latest.Version -Dir $dir)) { return $false }
            $current = $latest.Version
        } else {
            Write-Host "Keeping Blender $current; no download needed."
        }
    }

    # Before the extensions, so they land in the repo's portable\extensions\.
    $link = Join-Path $dir 'portable'
    Remove-Junction -Path $link
    if (Test-Path -LiteralPath $link) {
        Rename-Item -LiteralPath $link -NewName "portable.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }
    New-Item -ItemType Junction -Path $link -Target $portable | Out-Null

    return (Invoke-BlenderSetup -Exe (Join-Path $dir 'blender.exe') -RepoRoot $RepoRoot -Version $current)
}

# Download and unpack one build, then swap it in for the old one, which is
# restored if the swap fails.
function Install-BlenderBuild {
    param([string]$Url, [string]$Version, [string]$Dir)

    $parent = Split-Path $Dir -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ".blender-install-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        $zip = Join-Path $stage 'blender.zip'
        # ponytail: no progress lines for the ~400MB download; curl's own bar is not line-based.
        Write-Step "Downloading Blender $Version"
        & curl.exe -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o $zip $Url
        if ($LASTEXITCODE -ne 0) { Write-Err "Download failed (curl exit $LASTEXITCODE): $Url"; return $false }

        Write-Step 'Unpacking'
        # bsdtar reads zips, and is far faster than Expand-Archive on 400MB.
        & tar.exe -xf $zip -C $stage
        if ($LASTEXITCODE -ne 0) { Write-Err 'Could not unpack the Blender zip'; return $false }
        $build = @(Get-ChildItem -LiteralPath $stage -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'blender.exe') })[0]
        if (-not $build) { Write-Err 'The zip holds no blender.exe'; return $false }
        Set-Content -LiteralPath (Join-Path $build.FullName 'loadout-version.txt') -Value $Version -NoNewline

        Write-Step "Installing into $Dir"
        $old = ''
        if (Test-Path -LiteralPath $Dir) {
            Remove-Junction -Path (Join-Path $Dir 'portable')
            $old = Join-Path $stage 'previous'
            Move-Item -LiteralPath $Dir -Destination $old
        }
        try {
            Move-Item -LiteralPath $build.FullName -Destination $Dir
        } catch {
            if ($old) { Move-Item -LiteralPath $old -Destination $Dir }
            Write-Err "Could not move the new build into place: $_"
            return $false
        }
        return $true
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Config stays in the repo; only the app goes.
function Uninstall-Blender {
    $dir = Get-BlenderDir
    if (-not (Test-Path -LiteralPath $dir)) { Write-Host 'Blender is not installed'; return $true }
    Remove-Junction -Path (Join-Path $dir 'portable')
    Remove-Item -LiteralPath $dir -Recurse -Force
    Write-Host "Removed $dir"
    return $true
}

# extensions.txt, setup.py, MCP, stamp. Returns $false when any step failed.
function Invoke-BlenderSetup {
    param([string]$Exe, [string]$RepoRoot, [string]$Version)

    $cfg = Join-Path $RepoRoot 'config\dcc\blender'
    $portable = Join-Path $cfg 'portable'
    $failures = 0

    Write-SubStep 'Checking extensions'
    $addons = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Read-PackageList -FilePath (Join-Path $cfg 'extensions.txt'))) {
        # try: a module function runs under the global (Continue) error
        # preference, so an error would otherwise skip the count silently.
        $ok = $false
        try { $ok = Install-BlenderExtension -Exe $Exe -Portable $portable -Line $line -Addons $addons } catch { Write-Err "$_" }
        if (-not $ok) {
            Write-Err "Failed to set up extension: $line; continuing with custom configuration"
            $failures++
        }
    }

    Write-SubStep 'Reapplying custom preferences, keymap, plugins and startup layout'
    # setup.py needs a real window to activate the keymap and visit workspaces;
    # it saves the managed configuration and exits. Maximized, because
    # startup.blend records the window it was saved from.
    $env:OPS_BLENDER_ADDONS = $addons -join ' '
    $code = Invoke-Blender -Exe $exe -Arguments @('--window-maximized', '--python-exit-code', '1', '--python', (Join-Path $cfg 'setup.py'))
    if ($code -ne 0) {
        Write-Err "Blender custom configuration failed (exit $code)"
        $failures++
    }

    # Blender Lab MCP server for Claude Code (the add-on comes from
    # extensions.txt). Not vendored: uvx runs it from upstream git.
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    $uvx = Get-Command uvx -ErrorAction SilentlyContinue
    if ($claude -and $uvx) {
        Write-SubStep 'Registering Blender MCP with Claude Code'
        $ErrorActionPreference = 'Continue'
        & $claude.Source mcp remove -s user blender *> $null
        & $claude.Source mcp add -s user blender -- $uvx.Source --refresh-package blender-mcp `
            --from 'git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp' blender-mcp
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'Blender MCP registration failed'
            $failures++
        }
    } else {
        Write-Skip 'MCP registration: claude or uvx not found'
    }

    if ($failures -gt 0) {
        Write-Err "Blender $Version retained, but $failures setup step(s) failed; see above"
        return $false
    }
    Set-Content -LiteralPath (Join-Path $cfg '.configured') -Value (Get-BlenderConfigHash -RepoRoot $RepoRoot) -NoNewline
    Write-Success "Blender $Version configured"
    return $true
}

Export-ModuleMember -Function @(
    'Get-BlenderConfigHash',
    'Test-BlenderConfigCurrent',
    'Get-BlenderStatus',
    'Install-Blender',
    'Uninstall-Blender'
)
