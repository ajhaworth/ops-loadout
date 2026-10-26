# loadout-wm.psm1 - Loadout WM, this repo's own window manager (wm/), on Windows
#
# Driven by platforms/windows/installers/loadout-wm.ps1 (Loadout kind
# `installer`). release.yml attaches loadout-wm-windows.zip (the exe plus
# version.txt) to every Loadout release; this copies it into
# %LOCALAPPDATA%\Programs\LoadoutWM and starts it at login from the HKCU Run
# key. Its rules are the config/dotfiles/wm/rules.txt dotfile.
#
# $script:WmVersion is the wm/Cargo.toml version this checkout expects
# (smoke.sh keeps it in step with platforms/macos/installers/loadout-wm.sh);
# the installed copy is replaced only when it differs.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

$script:WmVersion = '0.3.1'
$script:Dir = Join-Path $env:LOCALAPPDATA 'Programs\LoadoutWM'
$script:Exe = Join-Path $script:Dir 'loadout-wm.exe'
$script:VersionFile = Join-Path $script:Dir 'version.txt'
$script:Url = 'https://github.com/ajhaworth/ops-loadout/releases/latest/download/loadout-wm-windows.zip'
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-InstalledWmVersion {
    if (-not (Test-Path -LiteralPath $script:VersionFile)) { return '' }
    return (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
}

function Get-LoadoutWmStatus {
    if (-not (Test-Path -LiteralPath $script:Exe)) { return $null }
    return @{ Exe = $script:Exe; Outdated = ((Get-InstalledWmVersion) -ne $script:WmVersion) }
}

function Stop-LoadoutWm {
    Get-Process -Name 'loadout-wm' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-LoadoutWm {
    Set-ItemProperty -Path $script:RunKey -Name 'LoadoutWM' -Value "`"$script:Exe`""
    Start-Process -FilePath $script:Exe
}

function Install-LoadoutWm {
    param([Parameter(Mandatory)][ValidateSet('install', 'update', 'reinstall', 'configure')][string]$Action)

    $current = Get-InstalledWmVersion
    if ($Action -eq 'configure') { Write-Host 'Loadout WM is configured by the wm dotfile (Updates tab).'; return $true }
    if ((Test-Path -LiteralPath $script:Exe) -and $Action -ne 'reinstall' -and $current -eq $script:WmVersion) {
        Write-Host "Loadout WM $current is current; restarting it."
        Stop-LoadoutWm
        Start-LoadoutWm
        return $true
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadout-wm-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'loadout-wm.zip'
        Write-Step "Downloading $script:Url"
        & curl.exe -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o $zip $script:Url
        if ($LASTEXITCODE -ne 0) { Write-Err "Download failed (curl exit $LASTEXITCODE)"; return $false }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $got = (Get-Content -LiteralPath (Join-Path $tmp 'version.txt') -Raw -ErrorAction SilentlyContinue)
        if (-not $got -or -not (Test-Path -LiteralPath (Join-Path $tmp 'loadout-wm.exe'))) {
            Write-Err 'Unexpected zip layout: want loadout-wm.exe and version.txt'
            return $false
        }
        if ($got.Trim() -ne $script:WmVersion) {
            Write-Err "The latest release has Loadout WM $($got.Trim()) but this checkout expects $script:WmVersion; the release with it has not been built yet."
            return $false
        }

        Write-Step "Installing into $script:Dir"
        Stop-LoadoutWm
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $tmp 'loadout-wm.exe'), (Join-Path $tmp 'version.txt') -Destination $script:Dir -Force
        Start-LoadoutWm
        Write-Success "Loadout WM $script:WmVersion installed and running at login. Apply the wm dotfile (Updates tab), and quit GlazeWM: the two would fight over windows."
        return $true
    } catch {
        Write-Err "Installing Loadout WM failed: $_"
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-LoadoutWm {
    if (-not (Test-Path -LiteralPath $script:Exe)) { Write-Host 'Loadout WM is not installed.'; return $false }
    Stop-LoadoutWm
    Remove-ItemProperty -Path $script:RunKey -Name 'LoadoutWM' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Dir -Recurse -Force
    Write-Host "Removed $script:Dir"
    return $true
}

Export-ModuleMember -Function @(
    'Get-LoadoutWmStatus',
    'Install-LoadoutWm',
    'Uninstall-LoadoutWm'
)
