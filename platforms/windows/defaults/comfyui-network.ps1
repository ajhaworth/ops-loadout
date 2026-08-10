# comfyui-network.ps1 - Reach ComfyUI from other machines on the LAN
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

$script:ComfyFirewallRule = 'ComfyUI (ops-workstation)'

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
        Write-Skip "No installations.json - finish Desktop's setup, then re-run"
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
        Write-Skip "Comfy Desktop is running - close it and re-run to change launch arguments"
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
            -Description 'Managed by ops-workstation' -ErrorAction Stop | Out-Null
        Write-Success "Firewall allows inbound TCP $Port from the local subnet"
    } catch {
        Write-Warn "Failed to create the firewall rule: $_"
    }
}

function Apply-ComfyuiNetwork {
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
        Write-Skip "Comfy Desktop config not found - launch it once, then re-run"
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
    # something is enforcing a login - a full run installs the auth node in the
    # packages stage first, but `setup.ps1 defaults` on its own would not.
    $requireAuth = 'true'
    if ($ProfileConfig.ContainsKey('COMFYUI_REQUIRE_AUTH')) {
        $requireAuth = $ProfileConfig['COMFYUI_REQUIRE_AUTH']
    }

    if ($requireAuth -eq 'true' -and -not (Test-ComfyAuthInstalled)) {
        Write-Warn "No ComfyUI auth node installed - not opening the firewall"
        Write-Status "Run '.\setup.ps1 packages' to install $((Get-ComfyAuthNodeNames) -join ', '), or set COMFYUI_REQUIRE_AUTH=`"false`" to expose it anyway"
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
