# security.ps1 - Defender, firewall and local attack-surface hardening
#
# Requires Administrator. Registry values go through Set-RegistryValueSet, which
# reports its own needs-Administrator state; Defender and firewall changes are
# cmdlet calls, so they go through Invoke-TrackedStep to get Setup tab rows.
#
# Deliberately left alone:
#   - Controlled Folder Access: blocks dev tools, DCCs and game saves.
#   - BitLocker and Secure Boot: one needs a recovery-key plan, the other a
#     firmware change. Both are only reported (Write-Warn), never applied, so
#     the Setup tab cannot offer an "apply" that does nothing.
#   - Firewall rules and accounts that ops-server's Ansible owns.

# Attack Surface Reduction rules put into Block mode. These are the rules
# Microsoft lists as low-impact for a workstation. The PSExec/WMI process
# creation and "prevalence, age or trusted list" rules are left out: they
# fire on build tools, DCC plugins and freshly downloaded installers.
$script:SecurityAsrRules = [ordered]@{
    'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Office apps creating child processes'
    '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Office apps injecting into other processes'
    '3b576869-a4ec-4529-8536-b80a7769e899' = 'Office apps creating executable content'
    '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Win32 API calls from Office macros'
    '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Office communication apps creating child processes'
    '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Adobe Reader creating child processes'
    '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Potentially obfuscated scripts'
    'd3e037e1-3eb8-44c8-a917-57927947596d' = 'JS/VBS launching downloaded executables'
    'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Executable content from email and webmail'
    '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Credential stealing from LSASS'
    '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Exploited vulnerable signed drivers'
    'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Persistence through WMI event subscription'
    'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Untrusted and unsigned processes from USB'
}

# ASR rule IDs from $script:SecurityAsrRules that are not in Block (1) mode.
function Get-SecurityAsrRulesToBlock {
    $pref = Get-MpPreference -ErrorAction Stop
    $ids = @($pref.AttackSurfaceReductionRules_Ids)
    $actions = @($pref.AttackSurfaceReductionRules_Actions)

    $current = @{}
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if ($ids[$i]) { $current[$ids[$i].ToLowerInvariant()] = $actions[$i] }
    }

    return @($script:SecurityAsrRules.Keys | Where-Object { $current[$_] -ne 1 })
}

# Enabled inbound Allow rules created by the Apollo/Vibepollo installer. It
# adds them for Any address on Any profile, which exposes the streaming host
# and its web UI on every network. Matched by display name or by a program
# under the Apollo install directory, since the installer uses both shapes.
#
# The program filters come from one -All query keyed by rule: asking per rule
# costs ~60 ms each, which over a few hundred inbound rules made this module
# alone take ~15 s of every Updates-tab load.
function Get-SecurityApolloRules {
    $apolloDir = Join-Path $env:ProgramFiles 'Apollo'
    $apolloRuleIds = @{}
    foreach ($filter in @(Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue)) {
        $program = $filter.Program
        if (-not $program -or $program -eq 'Any') { continue }
        $program = [Environment]::ExpandEnvironmentVariables($program)
        if ($program.StartsWith($apolloDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $apolloRuleIds[$filter.InstanceID] = $true
        }
    }

    $rules = @()
    foreach ($rule in @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)) {
        if ($rule.DisplayName -match '^(Apollo|Vibepollo)( |$)' -or $apolloRuleIds.ContainsKey($rule.Name)) {
            $rules += $rule
        }
    }
    return $rules
}

function Test-SecurityApolloRulesScoped {
    foreach ($rule in @(Get-SecurityApolloRules)) {
        $remote = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
        if ("$($rule.Profile)" -ne 'Private' -or $remote.Count -ne 1 -or $remote[0] -ne 'LocalSubnet') {
            return $false
        }
    }
    return $true
}

# Only on a real, elevated, whole-module run: unelevated both checks throw
# (Get-BitLockerVolume only after ~5 s), and status and single-row applies
# discard or don't need the warnings.
function Write-SecurityAdvisories {
    if (-not (Test-Administrator)) { return }
    try {
        if (-not (Confirm-SecureBootUEFI -ErrorAction Stop)) {
            Write-Warn "Secure Boot is off - enable it in the firmware setup (manual)"
        }
    } catch {
        # Legacy BIOS, or not elevated: nothing reliable to report.
    }

    try {
        $os = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ("$($os.ProtectionStatus)" -ne 'On') {
            Write-Warn "BitLocker is off on $env:SystemDrive - enable it and store the recovery key (manual)"
        }
    } catch {
        # BitLocker cmdlets need Administrator; skip quietly without it.
    }
}

function Apply-Security {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

    # WDigest, RunAsPPL and LLMNR are already the Windows 11 defaults or set by
    # other tooling; pinning them here catches drift.
    $settings = @(
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance"; Name = 'fAllowToGetHelp'; Value = 0; Label = 'Disable Remote Assistance' }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'InactivityTimeoutSecs'; Value = 900; Label = 'Lock after 15 minutes idle' }
        @{ Path = $lsa; Name = 'RestrictAnonymous'; Value = 1; Label = 'Restrict anonymous enumeration of shares' }
        @{ Path = $lsa; Name = 'RunAsPPL';          Value = 1; Label = 'Run LSA as a protected process' }
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest"; Name = 'UseLogonCredential'; Value = 0; Label = 'Keep WDigest from caching plaintext credentials' }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; Name = 'EnableMulticast'; Value = 0; Label = 'Disable LLMNR' }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"; Name = 'EnableScriptBlockLogging'; Value = 1; Label = 'PowerShell script block logging' }
    )

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun

    if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
        Invoke-TrackedStep -Id 'defender\asr' -Label 'Defender ASR rules in Block mode' -RequiresAdmin -DryRun:$DryRun `
            -Check { @(Get-SecurityAsrRulesToBlock).Count -eq 0 } `
            -Apply {
                $ids = @(Get-SecurityAsrRulesToBlock)
                $actions = @($ids | ForEach-Object { 'Enabled' })
                Add-MpPreference -AttackSurfaceReductionRules_Ids $ids -AttackSurfaceReductionRules_Actions $actions -ErrorAction Stop
            } | Out-Null

        Invoke-TrackedStep -Id 'defender\network-protection' -Label 'Defender network protection' -RequiresAdmin -DryRun:$DryRun `
            -Check { (Get-MpPreference -ErrorAction Stop).EnableNetworkProtection -eq 1 } `
            -Apply { Set-MpPreference -EnableNetworkProtection Enabled -ErrorAction Stop } | Out-Null

        Invoke-TrackedStep -Id 'defender\cloud-block-level' -Label 'Defender cloud block level High' -RequiresAdmin -DryRun:$DryRun `
            -Check { (Get-MpPreference -ErrorAction Stop).CloudBlockLevel -ge 2 } `
            -Apply { Set-MpPreference -CloudBlockLevel High -ErrorAction Stop } | Out-Null
    } else {
        Write-Skip "Defender cmdlets not available"
    }

    if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        Invoke-TrackedStep -Id 'firewall\log-blocked' -Label 'Log dropped firewall packets' -RequiresAdmin -DryRun:$DryRun `
            -Check { @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { "$($_.LogBlocked)" -ne 'True' }).Count -eq 0 } `
            -Apply { Set-NetFirewallProfile -All -LogBlocked True -LogMaxSizeKilobytes 16384 -ErrorAction Stop } | Out-Null

        Invoke-TrackedStep -Id 'firewall\apollo-scope' -Label 'Limit Apollo firewall rules to the local subnet' -RequiresAdmin -DryRun:$DryRun `
            -Check { Test-SecurityApolloRulesScoped } `
            -Apply {
                foreach ($rule in @(Get-SecurityApolloRules)) {
                    $rule | Set-NetFirewallRule -Profile Private -RemoteAddress LocalSubnet -ErrorAction Stop
                }
            } | Out-Null
    } else {
        Write-Skip "Firewall cmdlets not available"
    }

    # Off by default: a machine with a printer needs the spooler.
    if ($ProfileConfig['SECURITY_DISABLE_SPOOLER'] -eq 'true') {
        Invoke-TrackedStep -Id 'service\spooler' -Label 'Disable the Print Spooler' -RequiresAdmin -DryRun:$DryRun `
            -Check {
                $svc = Get-Service Spooler -ErrorAction SilentlyContinue
                $null -eq $svc -or ("$($svc.StartType)" -eq 'Disabled' -and "$($svc.Status)" -eq 'Stopped')
            } `
            -Apply {
                Stop-Service Spooler -Force -ErrorAction Stop
                Set-Service Spooler -StartupType Disabled -ErrorAction Stop
            } | Out-Null
    }

    if (-not $DryRun -and -not (Get-RegistryOnlyId)) { Write-SecurityAdvisories }
}
