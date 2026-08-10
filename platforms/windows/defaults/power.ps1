# power.ps1 - Power and sleep behaviour
#
# Requires Administrator. Fast Startup is disabled deliberately: it puts the
# machine into a hybrid shutdown that leaves the NIC unable to answer a magic
# packet, which breaks the Wake-on-LAN setup configured in debloat.ps1 for
# Moonlight/Apollo streaming.

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$Label,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-DryRun "Would run: powercfg $($Arguments -join ' ')  ($Label)"
        return
    }

    try {
        $output = & powercfg @Arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success $Label
        } else {
            $detail = ($output | Out-String).Trim()
            Write-Warn "${Label}: powercfg exited $LASTEXITCODE - $detail"
        }
    } catch {
        Write-Warn "${Label}: $_"
    }
}

function Apply-Power {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    if (-not (Test-Administrator)) {
        Write-Skip "Power settings need Administrator"
        return
    }

    # Disable Fast Startup so shutdown is a real shutdown (see note above)
    Set-RegistryValue `
        -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" `
        -Name 'HiberbootEnabled' -Value 0 -Type DWord `
        -Label 'Disable Fast Startup (required for Wake-on-LAN)' -DryRun:$DryRun | Out-Null

    Invoke-PowerCfg -Arguments @('/change', 'standby-timeout-ac', '0') `
        -Label 'Never sleep on AC power' -DryRun:$DryRun

    Invoke-PowerCfg -Arguments @('/change', 'hibernate-timeout-ac', '0') `
        -Label 'Never hibernate on AC power' -DryRun:$DryRun

    Invoke-PowerCfg -Arguments @('/change', 'monitor-timeout-ac', '20') `
        -Label 'Turn off display after 20 minutes on AC power' -DryRun:$DryRun

    Invoke-PowerCfg -Arguments @('/change', 'disk-timeout-ac', '0') `
        -Label 'Never spin down disks on AC power' -DryRun:$DryRun
}
