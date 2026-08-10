# comfyui.psm1 - Locating a ComfyUI Desktop install
#
# Shared by platforms/windows/defaults/comfyui*.ps1 and the comfynodes half of
# packages.ps1, so all of them agree on where the app and its backend live.
#
# Desktop keeps its state in %APPDATA%\Comfy Desktop (note the space - there is
# no %APPDATA%\ComfyUI) and records each install in installations.json.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

Import-Module (Join-Path $PSScriptRoot "common.psm1") -Global -Force

# Join without Join-Path: that cmdlet parses the drive/provider qualifier and
# throws on UNC paths under non-Windows PowerShell, which makes these helpers
# untestable and would hard-fail on a malformed model path.
function Join-ComfyPath {
    param(
        [Parameter(Mandatory)]
        [string]$Base,
        [Parameter(Mandatory)]
        [string]$Child
    )

    return ($Base.TrimEnd('\', '/') + '\' + $Child)
}

# Test-Path on a bad path can throw as well as return false
function Test-ComfyPathReachable {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        return (Test-Path -LiteralPath $Path)
    } catch {
        return $false
    }
}

function Get-ComfyDesktopConfigDir {
    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath('ApplicationData')
    }
    if (-not $appData) {
        return ''
    }

    return (Join-ComfyPath -Base $appData -Child 'Comfy Desktop')
}

# Desktop rewrites its own JSON state when it exits, so anything this repo
# writes while the app is open is liable to be thrown away.
function Test-ComfyDesktopRunning {
    if (-not (Test-IsWindowsPlatform)) {
        return $false
    }

    $procs = @(Get-Process -Name 'Comfy Desktop' -ErrorAction SilentlyContinue)
    return $procs.Count -gt 0
}

# Local installs recorded by Desktop. Cloud entries have no installPath.
function Get-ComfyInstallPaths {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigDir
    )

    $manifest = Join-ComfyPath -Base $ConfigDir -Child 'installations.json'
    if (-not (Test-ComfyPathReachable -Path $manifest)) {
        return @()
    }

    try {
        $entries = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $paths = @()
    foreach ($entry in @($entries)) {
        $prop = $entry.PSObject.Properties['installPath']
        if ($null -ne $prop -and $prop.Value) {
            $paths += [string]$prop.Value
        }
    }

    return $paths
}

# The backend directory is the one holding main.py, which sits one level below
# the recorded install path.
function Resolve-ComfyBaseDir {
    param(
        [Parameter(Mandatory)]
        [string]$InstallPath
    )

    foreach ($candidate in @((Join-ComfyPath -Base $InstallPath -Child 'ComfyUI'), $InstallPath)) {
        if (Test-ComfyPathReachable -Path (Join-ComfyPath -Base $candidate -Child 'main.py')) {
            return $candidate
        }
    }

    return $null
}

# Custom node requirements have to be installed into the interpreter ComfyUI
# actually runs, which is the .venv beside main.py - not the standalone-env it
# was seeded from, and not any python on PATH.
function Get-ComfyVenvPython {
    param(
        [Parameter(Mandatory)]
        [string]$BaseDir
    )

    $python = Join-ComfyPath -Base $BaseDir -Child '.venv\Scripts\python.exe'
    if (Test-ComfyPathReachable -Path $python) {
        return $python
    }

    return ''
}

# Every local backend on this machine, as @{ InstallPath; BaseDir }.
function Get-ComfyBackends {
    $configDir = Get-ComfyDesktopConfigDir
    if (-not $configDir -or -not (Test-ComfyPathReachable -Path $configDir)) {
        return @()
    }

    $backends = @()
    foreach ($installPath in (Get-ComfyInstallPaths -ConfigDir $configDir)) {
        $baseDir = Resolve-ComfyBaseDir -InstallPath $installPath
        if ($baseDir) {
            $backends += @{ InstallPath = $installPath; BaseDir = $baseDir }
        }
    }

    return $backends
}

# Custom nodes that put authentication in front of ComfyUI. ComfyUI has none of
# its own, so opening the port without one of these publishes an unauthenticated
# GPU and model library to the network.
function Get-ComfyAuthNodeNames {
    return @('ComfyUI-Login')
}

function Test-ComfyAuthInstalled {
    foreach ($backend in (Get-ComfyBackends)) {
        $customNodes = Join-ComfyPath -Base $backend.BaseDir -Child 'custom_nodes'
        foreach ($name in (Get-ComfyAuthNodeNames)) {
            if (Test-ComfyPathReachable -Path (Join-ComfyPath -Base $customNodes -Child $name)) {
                return $true
            }
        }
    }

    return $false
}

Export-ModuleMember -Function @(
    'Get-ComfyAuthNodeNames',
    'Test-ComfyAuthInstalled',
    'Join-ComfyPath',
    'Test-ComfyPathReachable',
    'Get-ComfyDesktopConfigDir',
    'Test-ComfyDesktopRunning',
    'Get-ComfyInstallPaths',
    'Resolve-ComfyBaseDir',
    'Get-ComfyVenvPython',
    'Get-ComfyBackends'
)
