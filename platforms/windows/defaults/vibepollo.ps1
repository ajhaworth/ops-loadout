# vibepollo.ps1 - Keys in Vibepollo's sunshine.conf (github/gaming.txt)
#
# Sets individual keys, never the whole file: the rest of sunshine.conf is
# written by Vibepollo's own web UI (encoder, display, paired-client state
# lives beside it in sunshine_state.json, which holds credentials and is never
# touched here).
#
# update_check_interval = 0: Vibepollo's updater compares its internal version
# with the repo's git tags, which never agree (see CLAUDE.md, GitHub Release
# Packages), so it nags about an update forever. Loadout tracks the release.
#
# The file sits under Program Files, so writes need Administrator. Vibepollo
# reads it at service start: a change applies on its next restart or reboot.

function Get-VibepolloConfigPath {
    # The bootstrapper installs to %ProgramFiles%\Apollo by default; plain
    # Sunshine-layout installs use Sunshine.
    foreach ($dir in @('Apollo', 'Vibepollo', 'Sunshine')) {
        $path = Join-Path $env:ProgramFiles "$dir\config\sunshine.conf"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

# Current value of `key = value` in a sunshine.conf, or $null when unset.
function Get-SunshineConfValue {
    param([string]$Path, [string]$Key)

    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*?)\s*$") { return $matches[1] }
    }
    return $null
}

function Set-SunshineConfValue {
    param([string]$Path, [string]$Key, [string]$Value)

    $pattern = "^\s*$([regex]::Escape($Key))\s*="
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines | Where-Object { $_ -match $pattern }) {
        $lines = $lines -replace "$pattern.*$", "$Key = $Value"
    } else {
        $lines += "$Key = $Value"
    }
    Set-Content -LiteralPath $Path -Value $lines -ErrorAction Stop
}

function Apply-Vibepollo {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $conf = Get-VibepolloConfigPath
    if (-not $conf) {
        Write-Skip "Vibepollo not installed (no sunshine.conf under Program Files)"
        return
    }

    $keys = @(
        @{ Key = 'update_check_interval'; Value = '0'; Label = 'Vibepollo: no update nag (Loadout tracks releases)' }
    )

    # -Check/-Apply run synchronously inside this iteration, so closing over
    # the loop variable is safe.
    foreach ($k in $keys) {
        Invoke-TrackedStep -Id "vibepollo\$($k.Key)" -Label $k.Label -RequiresAdmin -DryRun:$DryRun `
            -Check { (Get-SunshineConfValue -Path $conf -Key $k.Key) -eq $k.Value } `
            -Apply { Set-SunshineConfValue -Path $conf -Key $k.Key -Value $k.Value } | Out-Null
    }
}
