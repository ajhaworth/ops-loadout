# blender.psm1 - Blender's repo config on Windows
#
# The Windows half of platforms/macos/installers/blender.sh. winget installs
# the app (BlenderFoundation.Blender, an MSI per X.Y series under
# Program Files); this applies the repo's config to it, on every install,
# update and "Reapply Settings":
#
#   1. %APPDATA%\Blender Foundation\Blender\<X.Y> becomes a junction to
#      config/dcc/blender/portable, so everything Blender saves lands in the
#      repo - the same tree macOS reaches through its portable/ symlink
#   2. extensions.txt is installed into it
#   3. setup.py runs windowed to regenerate prefs, keymap and startup layout
#   4. the Blender Lab MCP server is registered with Claude Code
#
# A junction rather than a portable/ folder beside blender.exe: that one sits
# in Program Files and would need Administrator. Junctions need neither admin
# nor Developer Mode.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Newest installed series, e.g. C:\Program Files\Blender Foundation\Blender 5.2\blender.exe
function Get-BlenderExe {
    $root = Join-Path $env:ProgramFiles 'Blender Foundation'
    $dir = Get-ChildItem -LiteralPath $root -Directory -Filter 'Blender *' -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -match '^Blender \d+\.\d+$') -and (Test-Path -LiteralPath (Join-Path $_.FullName 'blender.exe')) } |
        Sort-Object { [version]($_.Name -replace '^Blender ', '') } -Descending |
        Select-Object -First 1
    if ($dir) { return (Join-Path $dir.FullName 'blender.exe') }
    return ''
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

# The series' user config dir -> the repo. A real directory already there (a
# Blender run before this) is moved aside, never deleted.
function Set-BlenderConfigLink {
    param(
        [Parameter(Mandatory)][string]$Series,
        [Parameter(Mandatory)][string]$Target
    )

    $root = Join-Path $env:APPDATA 'Blender Foundation\Blender'
    $link = Join-Path $root $Series
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.LinkType) {
            # DirectoryInfo.Delete() on a junction removes the link, not the repo files
            $item.Delete()
        } else {
            $aside = "$Series.bak-$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Rename-Item -LiteralPath $link -NewName $aside
            Write-Host "Moved the existing Blender $Series config aside to $aside"
        }
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Junction -Path $link -Target $Target | Out-Null
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
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Addons
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

function Install-BlenderConfig {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$DryRun
    )

    $cfg = Join-Path $RepoRoot 'config\dcc\blender'
    $portable = Join-Path $cfg 'portable'
    # Before the exe lookup: a dry run never installed the Blender it would configure.
    if ($DryRun) {
        Write-DryRun "Would link %APPDATA%\Blender Foundation\Blender\<X.Y> -> $portable, install extensions.txt and run setup.py"
        return $true
    }

    $exe = Get-BlenderExe
    if (-not $exe) {
        Write-Err 'Blender is not installed (no Program Files\Blender Foundation\Blender X.Y\blender.exe)'
        (Get-Results).Failed += 'blender config'
        return $false
    }
    $series = (Split-Path (Split-Path $exe -Parent) -Leaf) -replace '^Blender ', ''

    Write-Step "Blender $series configuration"

    # Before the extensions, so they land in the repo's portable\extensions\.
    Set-BlenderConfigLink -Series $series -Target $portable
    $failures = 0

    Write-SubStep 'Checking extensions'
    $addons = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Read-PackageList -FilePath (Join-Path $cfg 'extensions.txt'))) {
        if (-not (Install-BlenderExtension -Exe $exe -Portable $portable -Line $line -Addons $addons)) {
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
        Write-Err "Blender $series is installed, but $failures setup step(s) failed; see above"
        (Get-Results).Failed += 'blender config'
        return $false
    }
    Set-Content -LiteralPath (Join-Path $cfg '.configured') -Value (Get-BlenderConfigHash -RepoRoot $RepoRoot) -NoNewline
    Write-Success "Blender $series configured"
    return $true
}

Export-ModuleMember -Function @(
    'Get-BlenderExe',
    'Get-BlenderConfigHash',
    'Test-BlenderConfigCurrent',
    'Install-BlenderConfig'
)
