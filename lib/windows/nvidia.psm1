# nvidia.psm1 - the NVIDIA app on Windows
#
# Driven by platforms/windows/installers/nvidia-app.ps1 (Loadout kind
# `installer`). There is no winget package. NVIDIA's own download page links
# the current installer (us.download.nvidia.com/nvapp/client/<v>/...), which
# installs with -s and removes with -uninstall -s - the flags Chocolatey's
# nvidia-app package uses. The app also updates itself, so status reports no
# drift; Update installs the page's build when it is newer than the installed one.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force
Import-Module (Join-Path $PSScriptRoot "packages.psm1") -Global -Force

$script:Page = 'https://www.nvidia.com/en-us/software/nvidia-app/'

# "NVIDIA App 11.0.9.251" - the version in the name keeps "NVIDIA App driver
# settings", which registers alongside it, from matching.
function Get-NvidiaAppInstalled { return (Get-InstalledProgram -NamePattern 'NVIDIA App [0-9]*') }

function Get-NvidiaAppStatus {
    $installed = Get-NvidiaAppInstalled
    if (-not $installed) { return $null }
    $exe = Get-ShortcutTarget -Name 'NVIDIA App'
    if (-not $exe) {
        $exe = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe'
        if (-not (Test-Path -LiteralPath $exe)) { $exe = '' }
    }
    return @{ Exe = $exe; Version = $installed.Version }
}

# The build NVIDIA's page currently offers, as @{ Version; Url }, or $null.
function Get-NvidiaAppLatest {
    $ProgressPreference = 'SilentlyContinue'
    try {
        $html = (Invoke-WebRequest -Uri $script:Page -UserAgent 'Mozilla/5.0' -UseBasicParsing -TimeoutSec 35).Content
    } catch {
        return $null
    }
    $m = [regex]::Match($html, 'https://us\.download\.nvidia\.com/nvapp/client/([\d.]+)/[^"'']+\.exe')
    if (-not $m.Success) { return $null }
    return @{ Version = $m.Groups[1].Value; Url = $m.Value }
}

# Download the installer and run it elevated (one UAC prompt). Returns the exit code.
function Invoke-NvidiaInstaller {
    param([string]$Url, [string[]]$Arguments)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "loadout-nvapp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $exe = Join-Path $tmp (Split-Path $Url -Leaf)
        Write-Step "Downloading $(Split-Path $Url -Leaf)"
        & curl.exe -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o $exe $Url
        if ($LASTEXITCODE -ne 0) { Write-Err "Download failed (curl exit $LASTEXITCODE)"; return 1 }
        Write-Step 'Running the NVIDIA installer (accept the Windows administrator prompt)'
        try {
            return (Start-Process -FilePath $exe -ArgumentList $Arguments -Verb RunAs -Wait -PassThru).ExitCode
        } catch {
            Write-Err "The installer did not start (administrator prompt declined?): $_"
            return 1
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-NvidiaApp {
    param([Parameter(Mandatory)][ValidateSet('install', 'update', 'reinstall', 'configure')][string]$Action)

    $current = Get-NvidiaAppInstalled
    if ($current) { Write-Host "    installed: $($current.Version)" }
    if ($Action -eq 'configure') { Write-Host 'The NVIDIA app has no repo config.'; return $true }

    $latest = Get-NvidiaAppLatest
    if (-not $latest) { Write-Err "Could not find the installer link on $script:Page"; return $false }
    Write-Host "    latest: $($latest.Version)"
    if ($current -and $Action -ne 'reinstall' -and [version]$latest.Version -le [version]$current.Version) {
        Write-Host 'The NVIDIA app is already up to date.'
        return $true
    }

    $code = Invoke-NvidiaInstaller -Url $latest.Url -Arguments @('-s')
    $after = Get-NvidiaAppInstalled
    if (-not $after) { Write-Err "The installer exited $code without installing the NVIDIA app"; return $false }
    Write-Success "NVIDIA app $($after.Version) installed"
    return $true
}

function Uninstall-NvidiaApp {
    if (-not (Get-NvidiaAppInstalled)) { Write-Host 'The NVIDIA app is not installed.'; return $true }
    $latest = Get-NvidiaAppLatest
    if (-not $latest) { Write-Err "Could not find the installer link on $script:Page"; return $false }
    $code = Invoke-NvidiaInstaller -Url $latest.Url -Arguments @('-uninstall', '-s')
    if (Get-NvidiaAppInstalled) { Write-Err "The uninstaller exited $code and the NVIDIA app is still installed"; return $false }
    Write-Host 'Removed the NVIDIA app'
    return $true
}

Export-ModuleMember -Function @(
    'Get-NvidiaAppStatus',
    'Install-NvidiaApp',
    'Uninstall-NvidiaApp'
)
