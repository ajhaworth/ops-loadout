# comfyui.ps1 - Point ComfyUI Desktop at a shared model library
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

# Locating the app and its backend lives in lib/windows/comfyui.psm1, which
# defaults.ps1 imports - the comfynodes packages stage needs the same lookups.

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
    $lines += '# Managed by ops-workstation (platforms/windows/defaults/comfyui.ps1).'
    $lines += '# Edits here are overwritten on the next `.\setup.ps1 defaults` run.'
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

function Apply-Comfyui {
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

    $appData = $env:APPDATA
    if (-not $appData) {
        $appData = [Environment]::GetFolderPath('ApplicationData')
    }
    $configDir = Join-Path $appData 'Comfy Desktop'

    if (-not (Test-Path -LiteralPath $configDir)) {
        Write-Skip "Comfy Desktop config not found - launch it once, then re-run"
        return
    }

    $installPaths = @(Get-ComfyInstallPaths -ConfigDir $configDir)
    if ($installPaths.Count -eq 0) {
        Write-Skip "No local ComfyUI install recorded - finish Desktop's setup, then re-run"
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
