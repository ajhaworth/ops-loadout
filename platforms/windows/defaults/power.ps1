# power.ps1 - Power and sleep behaviour
#
# Requires Administrator. Fast Startup is disabled deliberately: it puts the
# machine into a hybrid shutdown that leaves the NIC unable to answer a magic
# packet, which breaks the Wake-on-LAN setup configured in debloat.ps1 for
# Moonlight/Apollo streaming.
#
# The four timeouts are powercfg calls rather than registry writes, so they go
# through Invoke-TrackedStep - that is what gives them result rows (and a
# needs_admin state) in the launcher's Setup tab.

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & powercfg @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $($Arguments -join ' ') exited ${LASTEXITCODE}: $(($output | Out-String).Trim())"
    }
}

# Current AC timeout for one setting, in seconds, or $null when it cannot be
# read. `powercfg /query` prints
#     Current AC Power Setting Index: 0x00000000
# for the requested subgroup/setting. That label is localised, so on a
# non-English Windows this returns $null and the step reports pending forever -
# re-applying is idempotent, so that degrades to noise rather than breakage.
function Get-PowerCfgAcSeconds {
    param(
        [Parameter(Mandatory)]
        [string]$SubGroup,
        [Parameter(Mandatory)]
        [string]$Setting
    )

    try {
        $output = & powercfg /query SCHEME_CURRENT $SubGroup $Setting 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch {
        return $null
    }

    foreach ($line in @($output)) {
        if ($line -match 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
            return [Convert]::ToInt64($matches[1], 16)
        }
    }
    return $null
}

function Apply-Power {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    # Disable Fast Startup so shutdown is a real shutdown (see note above).
    # Set-RegistryValue reports its own needs-Administrator state.
    Set-RegistryValue `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
        -Name 'HiberbootEnabled' -Value 0 -Type DWord `
        -Label 'Disable Fast Startup (required for Wake-on-LAN)' -DryRun:$DryRun | Out-Null

    # /change takes minutes, /query reports seconds.
    $timeouts = @(
        @{ Key = 'standby-timeout-ac';   SubGroup = 'SUB_SLEEP'; Setting = 'STANDBYIDLE';   Minutes = 0;  Label = 'Never sleep on AC power' }
        @{ Key = 'hibernate-timeout-ac'; SubGroup = 'SUB_SLEEP'; Setting = 'HIBERNATEIDLE'; Minutes = 0;  Label = 'Never hibernate on AC power' }
        @{ Key = 'monitor-timeout-ac';   SubGroup = 'SUB_VIDEO'; Setting = 'VIDEOIDLE';     Minutes = 20; Label = 'Turn off display after 20 minutes on AC power' }
        @{ Key = 'disk-timeout-ac';      SubGroup = 'SUB_DISK';  Setting = 'DISKIDLE';      Minutes = 0;  Label = 'Never spin down disks on AC power' }
    )

    # -Check/-Apply run synchronously inside this iteration, so closing over
    # the loop variable is safe.
    foreach ($t in $timeouts) {
        Invoke-TrackedStep -Id "powercfg\$($t.Key)" -Label $t.Label -RequiresAdmin -DryRun:$DryRun `
            -Check { (Get-PowerCfgAcSeconds -SubGroup $t.SubGroup -Setting $t.Setting) -eq ($t.Minutes * 60) } `
            -Apply { Invoke-PowerCfg -Arguments @('/change', $t.Key, "$($t.Minutes)") } | Out-Null
    }
}
