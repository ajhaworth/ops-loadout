# comfyui.psm1 - ComfyUI Desktop's config: custom nodes, model library, LAN access
#
# All of it is applied with the app (packages.psm1 Invoke-WingetAppConfig), on
# every install/update from Loadout or `setup.ps1 packages`, not as a separate
# setting.
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

# Every node in the comfynodes lists the profile enables, into every local
# backend. The nodes are ComfyUI's config rather than apps of their own:
# Loadout applies them whenever it installs or updates Comfy Desktop (winget),
# and setup.ps1 packages after its winget stage. A fresh Desktop has no backend
# until it has been launched once, so that case skips with a pointer.
function Install-ComfyNodeLists {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [hashtable]$ProfileConfig,
        [switch]$DryRun,
        [switch]$Force
    )

    $specs = @()
    $dir = Join-Path $RepoRoot 'config\packages\windows\comfynodes'
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $flag = Get-CategoryVar -Prefix 'COMFYNODES' -Category $file.BaseName
        if (Test-ProfileFlag -Profile $ProfileConfig -Flag $flag) {
            $specs += @(Read-PackageList -FilePath $file.FullName)
        }
    }
    if ($specs.Count -eq 0) { return }

    Write-Step "ComfyUI custom nodes"
    $backends = @(Get-ComfyBackends)
    if ($backends.Count -eq 0) {
        Write-Skip "No ComfyUI install found - launch Comfy Desktop once, then update it to add its nodes"
        return
    }
    # Nodes load at startup, so a running backend would not see them
    if ((Test-ComfyDesktopRunning) -and -not $DryRun) {
        Write-Warn "Comfy Desktop is running - restart it once this finishes"
    }

    foreach ($backend in $backends) {
        foreach ($spec in $specs) {
            Install-ComfyNode -PackageSpec $spec -BaseDir $backend.BaseDir -DryRun:$DryRun -Force:$Force | Out-Null
        }
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

# --- Model library -----------------------------------------------------------
# Point ComfyUI Desktop at a shared model library.
#
# Desktop stores its own state in %APPDATA%\Comfy Desktop, and generates
# shared_model_paths.yaml there from the modelsDirs list in settings.json.
# That file is explicitly "do not edit manually", and modelsDirs is a flat list
# of directories - neither can express a folder rename, which is what a share
# using A1111 names (Stable-diffusion\, Lora\, ESRGAN\) needs.
#
# The bundled backend still auto-loads extra_model_paths.yaml from its own
# directory (ComfyUI's main.py does this when the file exists), and Desktop
# never writes that file - only an .example ships. So that is where a mapped
# library belongs, and the two mechanisms coexist: Desktop keeps its local
# shared folder for downloads, this adds the network library on top.
#
# The model root comes from COMFYUI_MODEL_PATH. Folder names under it are
# resolved against what is actually on disk at apply time rather than assumed,
# so the same module works against a local library or a UNC share.

# ComfyUI's model type -> folder names seen in the wild, best match first.
# The ComfyUI name is always tried first so a already-correct share wins.
function Get-ComfyModelFolderMap {
    return @(
        @{ Key = 'checkpoints';           Candidates = @('checkpoints', 'Stable-diffusion') }
        @{ Key = 'loras';                 Candidates = @('loras', 'Lora') }
        @{ Key = 'upscale_models';        Candidates = @('upscale_models', 'ESRGAN', 'RealESRGAN') }
        @{ Key = 'vae';                   Candidates = @('vae', 'VAE') }
        @{ Key = 'controlnet';            Candidates = @('controlnet', 'ControlNet') }
        @{ Key = 'embeddings';            Candidates = @('embeddings', 'textual_inversion') }
        @{ Key = 'clip';                  Candidates = @('clip') }
        @{ Key = 'clip_vision';           Candidates = @('clip_vision') }
        @{ Key = 'configs';               Candidates = @('configs') }
        @{ Key = 'diffusion_models';      Candidates = @('diffusion_models') }
        @{ Key = 'gligen';                Candidates = @('gligen') }
        @{ Key = 'hypernetworks';         Candidates = @('hypernetworks') }
        @{ Key = 'latent_upscale_models'; Candidates = @('latent_upscale_models') }
        @{ Key = 'photomaker';            Candidates = @('photomaker') }
        @{ Key = 'style_models';          Candidates = @('style_models') }
        @{ Key = 'text_encoders';         Candidates = @('text_encoders', 'encoders') }
        @{ Key = 'unet';                  Candidates = @('unet') }
        @{ Key = 'vae_approx';            Candidates = @('vae_approx') }
        # Not core ComfyUI, but the custom nodes that use these look them up by
        # exactly these names, and a share that has them means they are wanted.
        @{ Key = 'ipadapter';             Candidates = @('ipadapter') }
        @{ Key = 'tensorrt';              Candidates = @('tensorrt') }
    )
}

# Match the map against real directory names. Returns @{ Key; Folder } pairs for
# the types the share actually has, preserving the on-disk casing.
#
# $FolderNames is taken as a parameter rather than listed here so the mapping
# is testable without a share to point at.
function Resolve-ComfyModelFolders {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$FolderNames
    )

    $lookup = @{}
    foreach ($name in $FolderNames) {
        if ($name) {
            $lookup[$name.ToLower()] = $name
        }
    }

    $resolved = @()
    foreach ($entry in (Get-ComfyModelFolderMap)) {
        foreach ($candidate in $entry.Candidates) {
            $key = $candidate.ToLower()
            if ($lookup.ContainsKey($key)) {
                $resolved += @{ Key = $entry.Key; Folder = $lookup[$key] }
                break
            }
        }
    }

    return $resolved
}

function Get-ComfyShareFolderNames {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath
    )

    try {
        return @(Get-ChildItem -LiteralPath $BasePath -Directory -ErrorAction Stop |
            ForEach-Object { $_.Name })
    } catch {
        return @()
    }
}

function New-ComfyModelsConfig {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Folders
    )

    $lines = @()
    $lines += '# Managed by ops-loadout (lib/windows/comfyui.psm1).'
    $lines += '# Edits here are overwritten whenever Loadout installs or updates ComfyUI.'
    $lines += '#'
    $lines += '# Only the model types present in the library are listed. Downloads still'
    $lines += "# go to Comfy Desktop's own folder - add 'is_default: true' below to"
    $lines += '# send them here instead.'
    $lines += 'ops_workstation:'
    $lines += "    base_path: $BasePath"

    foreach ($entry in $Folders) {
        $lines += "    $($entry.Key): $($entry.Folder)"
    }

    return (($lines -join "`r`n") + "`r`n")
}

function Set-ComfyModelLibrary {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $basePath = ''
    if ($ProfileConfig.ContainsKey('COMFYUI_MODEL_PATH')) {
        $basePath = $ProfileConfig['COMFYUI_MODEL_PATH']
    }

    if (-not $basePath) {
        Write-Skip "COMFYUI_MODEL_PATH is not set in the profile"
        return
    }

    $configDir = Get-ComfyDesktopConfigDir

    if (-not $configDir -or -not (Test-Path -LiteralPath $configDir)) {
        Write-Skip "Comfy Desktop config not found - launch it once, then update ComfyUI"
        return
    }

    $installPaths = @(Get-ComfyInstallPaths -ConfigDir $configDir)
    if ($installPaths.Count -eq 0) {
        Write-Skip "No local ComfyUI install recorded - finish Desktop's setup, then update ComfyUI"
        return
    }

    # Folder names have to be read off the library; writing a mapping that was
    # guessed would point ComfyUI at directories that do not exist.
    if (-not (Test-ComfyPathReachable -Path $basePath)) {
        Write-Warn "$basePath is not reachable - skipping rather than writing a guessed mapping"
        Write-Status "Re-run once it is available"
        return
    }

    $folderNames = Get-ComfyShareFolderNames -BasePath $basePath
    $folders = @(Resolve-ComfyModelFolders -FolderNames $folderNames)

    if ($folders.Count -eq 0) {
        Write-Warn "$basePath has no recognisable model folders - nothing to map"
        return
    }

    $renamed = @($folders | Where-Object { $_.Key -ne $_.Folder })
    Write-Status "Mapped $($folders.Count) model folders from $basePath"
    foreach ($entry in $renamed) {
        Write-SubStep "$($entry.Key) -> $($entry.Folder)"
    }

    $desired = New-ComfyModelsConfig -BasePath $basePath -Folders $folders

    foreach ($installPath in $installPaths) {
        $baseDir = Resolve-ComfyBaseDir -InstallPath $installPath
        if (-not $baseDir) {
            Write-Warn "No ComfyUI backend found under $installPath"
            continue
        }

        $configFile = Join-ComfyPath -Base $baseDir -Child 'extra_model_paths.yaml'

        if (Test-Path -LiteralPath $configFile) {
            $current = Get-Content -LiteralPath $configFile -Raw -ErrorAction SilentlyContinue
            if ($current -eq $desired) {
                Write-Skip "extra_model_paths.yaml already points at $basePath"
                continue
            }
        }

        if ($DryRun) {
            Write-DryRun "Would write $configFile (base_path: $basePath)"
            continue
        }

        try {
            # Preserve anything that was already there, once
            if ((Test-Path -LiteralPath $configFile) -and -not (Test-Path -LiteralPath "$configFile.orig")) {
                Copy-Item -LiteralPath $configFile -Destination "$configFile.orig"
                Write-Status "Saved original to extra_model_paths.yaml.orig"
            }

            Set-Content -LiteralPath $configFile -Value $desired -Encoding UTF8 -NoNewline
            Write-Success "ComfyUI models -> $basePath"
            Write-Status "Restart ComfyUI for this to take effect"
        } catch {
            Write-Warn "Failed to write ${configFile}: $_"
        }
    }
}

# --- Network access ------------------------------------------------------------
# Reach ComfyUI from other machines on the LAN.
#
# Two things have to line up:
#
#   1. The backend binds 127.0.0.1 unless told otherwise, so `--listen 0.0.0.0`
#      goes into the launchArgs Desktop records per install.
#   2. Windows Firewall has to allow inbound TCP on the port. That needs
#      Administrator and is scoped to the local subnet on private networks.
#
# The port is pinned rather than left to Desktop's automatic selection: a
# firewall rule and a bookmark on another machine both need it to stay put.
#
# ComfyUI has no authentication of its own. Anything that can reach this port
# can drive the GPU, read generated images and browse the model library, so:
#
#   - the firewall rule is LocalSubnet/Private rather than Any
#   - the rule is not created at all unless an auth node is installed
#     (COMFYUI_REQUIRE_AUTH, on by default)
#
# Auth comes from ComfyUI-Login in comfynodes/core.txt, which adds a login page
# and accepts `Authorization: Bearer <token>` for API calls.

$script:ComfyFirewallRule = 'ComfyUI (ops-loadout)'
# The repo was called ops-workstation, then ops-desktop, then ops-loadout. A
# rule left under an older name still holds the port open and nothing here
# manages it, so it is adopted rather than abandoned.
$script:ComfyFirewallRuleLegacy = @('ComfyUI (ops-desktop)', 'ComfyUI (ops-workstation)')

# Merge a flag into an existing launchArgs string, replacing the value when the
# flag is already there so re-runs do not accumulate duplicates.
function Merge-ComfyLaunchArgs {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Existing,
        [Parameter(Mandatory)]
        [string]$Flag,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value = ''
    )

    $tokens = @()
    if ($Existing) {
        $tokens = @($Existing -split '\s+' | Where-Object { $_ })
    }

    $merged = @()
    $index = 0
    $found = $false

    while ($index -lt $tokens.Count) {
        $token = $tokens[$index]

        if ($token -eq $Flag) {
            $found = $true
            $merged += $Flag
            if ($Value) { $merged += $Value }
            $index++
            # Drop the old value, which is any following non-flag token
            if ($index -lt $tokens.Count -and -not $tokens[$index].StartsWith('-')) {
                $index++
            }
            continue
        }

        $merged += $token
        $index++
    }

    if (-not $found) {
        $merged += $Flag
        if ($Value) { $merged += $Value }
    }

    return ($merged -join ' ')
}

function Set-ComfyLaunchArgs {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigDir,
        [Parameter(Mandatory)]
        [string]$Port,
        [switch]$DryRun
    )

    $manifest = Join-ComfyPath -Base $ConfigDir -Child 'installations.json'
    if (-not (Test-ComfyPathReachable -Path $manifest)) {
        Write-Skip "No installations.json - finish Desktop's setup, then update ComfyUI"
        return
    }

    try {
        $raw = Get-Content -LiteralPath $manifest -Raw
        $entries = @($raw | ConvertFrom-Json)
    } catch {
        Write-Warn "Could not read installations.json: $_"
        return
    }

    # Work out what needs changing before writing anything, so a blocked write
    # does not leave half the entries reported as updated.
    $planned = @()
    foreach ($entry in $entries) {
        $installProp = $entry.PSObject.Properties['installPath']
        if ($null -eq $installProp -or -not $installProp.Value) {
            continue
        }

        $current = ''
        $argsProp = $entry.PSObject.Properties['launchArgs']
        if ($null -ne $argsProp -and $argsProp.Value) {
            $current = [string]$argsProp.Value
        }

        $updated = Merge-ComfyLaunchArgs -Existing $current -Flag '--listen' -Value '0.0.0.0'
        $updated = Merge-ComfyLaunchArgs -Existing $updated -Flag '--port' -Value $Port

        if ($updated -eq $current) {
            Write-Skip "$($entry.name) already launches with $updated"
            continue
        }

        $planned += @{ Entry = $entry; Args = $updated }
    }

    if ($planned.Count -eq 0) {
        return
    }

    if ($DryRun) {
        foreach ($plan in $planned) {
            Write-DryRun "Would set $($plan.Entry.name) launchArgs: $($plan.Args)"
        }
        return
    }

    # Only this write is unsafe while the app is open - Desktop rewrites its own
    # JSON state on exit and would discard it. The firewall rule is unaffected,
    # so it must not be blocked by this.
    if (Test-ComfyDesktopRunning) {
        Write-Skip "Comfy Desktop is running - close it and update ComfyUI to change launch arguments"
        return
    }

    foreach ($plan in $planned) {
        $argsProp = $plan.Entry.PSObject.Properties['launchArgs']
        if ($null -eq $argsProp) {
            $plan.Entry | Add-Member -NotePropertyName 'launchArgs' -NotePropertyValue $plan.Args
        } else {
            $plan.Entry.launchArgs = $plan.Args
        }
        Write-Success "$($plan.Entry.name) launchArgs: $($plan.Args)"
    }

    try {
        if (-not (Test-ComfyPathReachable -Path "$manifest.orig")) {
            Copy-Item -LiteralPath $manifest -Destination "$manifest.orig"
            Write-Status "Saved original to installations.json.orig"
        }

        # Depth has to clear the nested torch-stack objects or they serialise as
        # type names instead of data, which would corrupt the file.
        $json = $entries | ConvertTo-Json -Depth 32
        Set-Content -LiteralPath $manifest -Value $json -Encoding UTF8
        Write-Status "Restart Comfy Desktop for the new launch arguments"
    } catch {
        Write-Warn "Failed to write installations.json: $_"
    }
}

# Binding 0.0.0.0 has a side effect on ComfyUI Manager: it gates model installs
# on risk level "middle+", which is granted only when the listen address is
# loopback (is_local_mode) or network_mode is personal_cloud. Listening on the
# LAN makes the first false, so installs fail with no queue entry and no error -
# the "missing models" dialog just sits at "waiting" forever. Raising
# security_level does not help; that branch never reads it.
#
# personal_cloud describes this deployment accurately (a private service behind
# a login) and restores installs, while high/high+ operations still require the
# weak level.
function Set-ComfyManagerNetworkMode {
    param(
        [Parameter(Mandatory)]
        [string]$BaseDir,
        [string]$Mode = 'personal_cloud',
        [switch]$DryRun
    )

    $config = Join-ComfyPath -Base $BaseDir -Child 'user\__manager\config.ini'
    if (-not (Test-ComfyPathReachable -Path $config)) {
        # Manager has not run yet; it writes this file on first start
        return
    }

    $lines = @(Get-Content -LiteralPath $config)
    $current = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*network_mode\s*=\s*(.*?)\s*$') {
            $current = $matches[1]
            break
        }
    }

    if ($current -eq $Mode) {
        Write-Skip "ComfyUI Manager network_mode already $Mode"
        return
    }

    if ($DryRun) {
        Write-DryRun "Would set ComfyUI Manager network_mode = $Mode (was '$current')"
        return
    }

    try {
        if (-not (Test-ComfyPathReachable -Path "$config.orig")) {
            Copy-Item -LiteralPath $config -Destination "$config.orig"
        }

        if ($current) {
            $updated = $lines -replace '^\s*network_mode\s*=.*$', "network_mode = $Mode"
        } else {
            # No key present - add it under the [default] section header
            $updated = @()
            $added = $false
            foreach ($line in $lines) {
                $updated += $line
                if (-not $added -and $line -match '^\s*\[default\]\s*$') {
                    $updated += "network_mode = $Mode"
                    $added = $true
                }
            }
            if (-not $added) {
                $updated += "network_mode = $Mode"
            }
        }

        Set-Content -LiteralPath $config -Value $updated -Encoding UTF8
        Write-Success "ComfyUI Manager network_mode = $Mode (model installs work when listening on the LAN)"
    } catch {
        Write-Warn "Failed to update ComfyUI Manager config: $_"
    }
}

function Set-ComfyFirewallRule {
    param(
        [Parameter(Mandatory)]
        [string]$Port,
        [switch]$DryRun
    )

    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Write-Skip "Firewall cmdlets unavailable - open TCP $Port manually"
        return
    }

    foreach ($stale in $script:ComfyFirewallRuleLegacy) {
        if (-not (Get-NetFirewallRule -DisplayName $stale -ErrorAction SilentlyContinue)) { continue }
        if ($DryRun) {
            Write-DryRun "Would rename the firewall rule '$stale' to '$script:ComfyFirewallRule'"
        } elseif (-not (Test-Administrator)) {
            Write-Skip "Renaming the firewall rule '$stale' needs Administrator"
        } else {
            try {
                Set-NetFirewallRule -DisplayName $stale -NewDisplayName $script:ComfyFirewallRule -ErrorAction Stop
                Write-Success "Adopted the firewall rule from '$stale'"
            } catch {
                Write-Warn "Failed to rename the firewall rule '$stale': $_"
            }
        }
    }

    $existing = Get-NetFirewallRule -DisplayName $script:ComfyFirewallRule -ErrorAction SilentlyContinue

    if ($existing) {
        $currentPort = ''
        try {
            $currentPort = [string]($existing | Get-NetFirewallPortFilter -ErrorAction Stop).LocalPort
        } catch {
            $currentPort = ''
        }

        if ($currentPort -eq $Port) {
            Write-Skip "Firewall already allows TCP $Port on the local subnet"
            return
        }

        if ($DryRun) {
            Write-DryRun "Would move the firewall rule from TCP $currentPort to $Port"
            return
        }

        if (-not (Test-Administrator)) {
            Write-Skip "Updating the firewall rule needs Administrator"
            return
        }

        try {
            Set-NetFirewallRule -DisplayName $script:ComfyFirewallRule -LocalPort $Port -Protocol TCP -ErrorAction Stop
            Write-Success "Firewall rule moved to TCP $Port"
        } catch {
            Write-Warn "Failed to update the firewall rule: $_"
        }
        return
    }

    if ($DryRun) {
        Write-DryRun "Would allow inbound TCP $Port from the local subnet (private networks)"
        return
    }

    if (-not (Test-Administrator)) {
        Write-Skip "Opening TCP $Port needs Administrator"
        return
    }

    try {
        New-NetFirewallRule -DisplayName $script:ComfyFirewallRule `
            -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
            -Profile Private -RemoteAddress LocalSubnet `
            -Description 'Managed by ops-loadout' -ErrorAction Stop | Out-Null
        Write-Success "Firewall allows inbound TCP $Port from the local subnet"
    } catch {
        Write-Warn "Failed to create the firewall rule: $_"
    }
}

function Set-ComfyNetworkAccess {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $enabled = 'true'
    if ($ProfileConfig.ContainsKey('COMFYUI_LISTEN')) {
        $enabled = $ProfileConfig['COMFYUI_LISTEN']
    }
    if ($enabled -ne 'true') {
        Write-Skip "COMFYUI_LISTEN is not enabled"
        return
    }

    $port = '8188'
    if ($ProfileConfig.ContainsKey('COMFYUI_PORT') -and $ProfileConfig['COMFYUI_PORT']) {
        $port = $ProfileConfig['COMFYUI_PORT']
    }
    if ($port -notmatch '^\d+$') {
        Write-Warn "COMFYUI_PORT '$port' is not a port number - skipping"
        return
    }

    $configDir = Get-ComfyDesktopConfigDir
    if (-not $configDir -or -not (Test-ComfyPathReachable -Path $configDir)) {
        Write-Skip "Comfy Desktop config not found - launch it once, then update ComfyUI"
        return
    }

    # Whether Desktop is running gates only the launchArgs write, inside
    # Set-ComfyLaunchArgs - the firewall rule below is independent of it.
    Set-ComfyLaunchArgs -ConfigDir $configDir -Port $port -DryRun:$DryRun

    # Listening on the LAN breaks ComfyUI Manager's model installs unless it is
    # told this is a personal cloud rather than a public server.
    foreach ($backend in (Get-ComfyBackends)) {
        Set-ComfyManagerNetworkMode -BaseDir $backend.BaseDir -DryRun:$DryRun
    }

    # Binding 0.0.0.0 is inert while the firewall still blocks the port, so the
    # rule is the step that actually publishes ComfyUI. Refuse to take it until
    # something is enforcing a login. Invoke-WingetAppConfig installs the node
    # lists first, so this only trips when the node failed to install.
    $requireAuth = 'true'
    if ($ProfileConfig.ContainsKey('COMFYUI_REQUIRE_AUTH')) {
        $requireAuth = $ProfileConfig['COMFYUI_REQUIRE_AUTH']
    }

    if ($requireAuth -eq 'true' -and -not (Test-ComfyAuthInstalled)) {
        Write-Warn "No ComfyUI auth node installed - not opening the firewall"
        Write-Status "Update ComfyUI to retry installing $((Get-ComfyAuthNodeNames) -join ', '), or set COMFYUI_REQUIRE_AUTH=`"false`" to expose it anyway"
        return
    }

    Set-ComfyFirewallRule -Port $port -DryRun:$DryRun

    if (-not $DryRun) {
        $addresses = @(
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
        )
        foreach ($address in $addresses) {
            Write-SubStep "http://$($address.IPAddress):$port"
        }
    }
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
    'Install-ComfyNodeLists',
    'Install-ComfyNodeRequirements',
    'Resolve-ComfyModelFolders',
    'New-ComfyModelsConfig',
    'Set-ComfyModelLibrary',
    'Merge-ComfyLaunchArgs',
    'Set-ComfyNetworkAccess'
)
