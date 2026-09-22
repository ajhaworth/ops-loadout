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
# Custom-node installs record into the same Installed/Skipped/Failed tracker
# as GitHub-release packages (Get-Results) and share its exit-code formatter.
Import-Module (Join-Path $PSScriptRoot "packages.psm1") -Global -Force

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
        (Get-Results).Failed += $PackageSpec
        return $false
    }

    $label = $spec.Repo

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git is required to install $label"
        (Get-Results).Failed += $label
        return $false
    }

    $customNodes = Join-ComfyPath -Base $BaseDir -Child 'custom_nodes'
    $target = Join-ComfyPath -Base $customNodes -Child $spec.Directory
    $exists = Test-ComfyPathReachable -Path $target

    if ($exists -and -not $Force) {
        Write-Skip "$label (already installed)"
        (Get-Results).Skipped += $label
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
            (Get-Results).Failed += $label
            return $false
        }

        if (-not (Install-ComfyNodeRequirements -Label $label -NodeDir $target -BaseDir $BaseDir)) {
            (Get-Results).Failed += $label
            return $false
        }

        Write-Success "$label installed"
        (Get-Results).Installed += $label
        return $true
    } catch {
        Write-Err "Error installing ${label}: $_"
        (Get-Results).Failed += $label
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
    'Get-ComfyBackends',
    'ConvertFrom-ComfyNodeSpec',
    'Test-ComfyNodeInstalled',
    'Install-ComfyNode',
    'Install-ComfyNodeRequirements'
)
