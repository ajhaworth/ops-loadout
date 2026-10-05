# vibepollo.psm1 - Keys in Vibepollo's sunshine.conf (github/gaming.txt)
#
# Applied with the app (packages.psm1 Invoke-AppConfig), after every
# install/update. Sets individual keys, never the whole file: the rest of
# sunshine.conf is written by Vibepollo's own web UI, and sunshine_state.json
# beside it holds credentials and is never touched.
#
# update_check_interval = 0: Vibepollo's updater compares its internal version
# with the repo's git tags, which never agree (see CLAUDE.md, GitHub Release
# Packages), so it nags about an update forever. Loadout tracks the release.
#
# The file sits under Program Files. Loadout runs unelevated, so a key that
# needs changing is written by one elevated child process (one UAC prompt);
# once set, later updates find it already right and never prompt. Vibepollo
# reads the file at service start, so a change applies on its next restart.

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

function Set-VibepolloConfig {
    param([switch]$DryRun)

    $conf = Get-VibepolloConfigPath
    if (-not $conf) {
        Write-Skip "No sunshine.conf yet - start Vibepollo once, then update it"
        return
    }

    $wanted = [ordered]@{ update_check_interval = '0' }
    $changes = @($wanted.Keys | Where-Object { (Get-SunshineConfValue -Path $conf -Key $_) -ne $wanted[$_] })
    if ($changes.Count -eq 0) {
        Write-Skip "sunshine.conf already set (no update nag)"
        return
    }

    if ($DryRun) {
        foreach ($k in $changes) { Write-DryRun "Would set $k = $($wanted[$k]) in $conf" }
        return
    }

    if (Test-Administrator) {
        foreach ($k in $changes) { Set-SunshineConfValue -Path $conf -Key $k -Value $wanted[$k] }
    } else {
        # The child imports this same module and makes the same calls. Values
        # are single-quoted with quotes doubled, so paths with spaces survive.
        $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
        $body = "`$ErrorActionPreference = 'Stop'; Import-Module $(& $q $PSCommandPath)"
        foreach ($k in $changes) {
            $body += "; Set-SunshineConfValue -Path $(& $q $conf) -Key $(& $q $k) -Value $(& $q $wanted[$k])"
        }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        Write-Status "Setting sunshine.conf (accept the Windows administrator prompt)"
        try {
            $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
                -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded)
        } catch {
            Write-Warn "sunshine.conf not changed (administrator prompt declined?): $_"
            return
        }
        if ($proc.ExitCode -ne 0) {
            Write-Warn "sunshine.conf not changed: the elevated write exited $($proc.ExitCode)"
            return
        }
    }
    Write-Success "sunshine.conf: $(($changes | ForEach-Object { "$_ = $($wanted[$_])" }) -join ', ') (applies when Vibepollo restarts)"
}

Export-ModuleMember -Function @(
    'Get-VibepolloConfigPath',
    'Get-SunshineConfValue',
    'Set-SunshineConfValue',
    'Set-VibepolloConfig'
)
