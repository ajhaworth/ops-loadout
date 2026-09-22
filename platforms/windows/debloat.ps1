# debloat.ps1 - Remove Windows bloatware
#
# Removes pre-installed Windows apps, disables Xbox services, Game DVR,
# Game Bar protocol handlers, and suggested apps. Safe to re-run (idempotent).
# Gated behind PROFILE_DEBLOAT flag for safety.
#
# Every check-then-act group below (bloat AppX list, Xbox services, Game DVR,
# Game Bar protocols, Wake-on-LAN, suggested apps) is also its own
# Invoke-Debloat<X>Group function returning @{ Pending; NeedsAdmin; Failed }.
# bridge.ps1 dot-sources this file (which only defines functions - see the
# InvocationName guard at the bottom) and calls those directly, one per
# Setup-tab row, instead of re-running the whole script. -Only runs a single
# group from the CLI the same way.

param(
    [switch]$DryRun,
    [ValidateSet('', 'bloat', 'xbox', 'gamedvr', 'gamebar', 'wol', 'suggested')]
    [string]$Only = ''
)

$ErrorActionPreference = "Stop"

# Import modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
Import-Module (Join-Path $repoRoot "lib\windows\common.psm1") -Force
Import-Module (Join-Path $repoRoot "lib\windows\registry.psm1") -Force

# --- AppX packages to remove ---

$BloatwareApps = @(
    # Microsoft bloatware (modern)
    "Clipchamp.Clipchamp"
    "Microsoft.BingNews"
    "Microsoft.BingSearch"
    "Microsoft.BingWeather"
    "Microsoft.GetHelp"
    "Microsoft.LinkedIn"
    "Microsoft.MicrosoftOfficeHub"
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.OutlookForWindows"
    "Microsoft.Paint"
    "Microsoft.PowerAutomateDesktop"
    "Microsoft.Todos"
    "Microsoft.Windows.DevHome"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.WindowsSoundRecorder"
    "Microsoft.YourPhone"
    "Microsoft.ZuneMusic"
    "MicrosoftCorporationII.QuickAssist"
    "MicrosoftWindows.Client.WebExperience"
    "MicrosoftWindows.CrossDevice"
    "MSTeams"

    # Microsoft bloatware (legacy — may not be present on newer builds)
    "Microsoft.3DBuilder"
    "Microsoft.BingFinance"
    "Microsoft.BingSports"
    "Microsoft.Getstarted"
    "Microsoft.Messaging"
    "Microsoft.Microsoft3DViewer"
    "Microsoft.MixedReality.Portal"
    "Microsoft.NetworkSpeedTest"
    "Microsoft.News"
    "Microsoft.Office.Lens"
    "Microsoft.Office.OneNote"
    "Microsoft.Office.Sway"
    "Microsoft.OneConnect"
    "Microsoft.People"
    "Microsoft.Print3D"
    "Microsoft.SkypeApp"
    "Microsoft.Wallet"
    "Microsoft.WindowsAlarms"
    "Microsoft.WindowsMaps"
    "Microsoft.ZuneVideo"

    # Sponsored apps
    "Disney.37853FC22B2CE"
    "Facebook.Facebook"
    "king.com.BubbleWitch3Saga"
    "king.com.CandyCrushSaga"
    "king.com.CandyCrushSodaSaga"
    "Netflix.Netflix"
    "SpotifyAB.SpotifyMusic"
    "Twitter.Twitter"

    # Cortana
    "Microsoft.549981C3F5F10"
)

$XboxApps = @(
    "Microsoft.GamingApp"
    "Microsoft.Xbox.TCUI"
    "Microsoft.XboxGameOverlay"
    "Microsoft.XboxGamingOverlay"
    "Microsoft.XboxIdentityProvider"
    "Microsoft.XboxSpeechToTextOverlay"
)

# Win32 apps to uninstall via winget (not AppX packages). Not one of the six
# Setup-tab groups below - it stays a plain stage in the full run.
$WingetAppsToRemove = @(
    "Microsoft.OneDrive"
)

$XboxServiceNames = @("XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc")

$WakeOnLanSettings = @(
    @{ Name = "Wake on Magic Packet";      Desired = "Enabled" }
    @{ Name = "Wake on Pattern Match";     Desired = "Disabled" }
    @{ Name = "Wake from power off state"; Desired = "Enabled" }
    @{ Name = "Wake on Link";              Desired = "Disabled" }
    @{ Name = "Wake on Ping";              Desired = "Disabled" }
)

# --- Functions ---

function Remove-BloatApp {
    param(
        [Parameter(Mandatory)]
        [string]$AppName,
        [switch]$DryRun
    )

    $app = Get-AppxPackage -Name $AppName -ErrorAction SilentlyContinue

    if (-not $app) {
        Write-Skip "$AppName (not installed)"
        return $true
    }

    if ($DryRun) {
        Write-DryRun "Would remove: $AppName"
        return $true
    }

    try {
        Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
        Write-Success "$AppName removed"
        return $true
    } catch {
        Write-Warn "Could not remove ${AppName}: $_"
        return $false
    }
}

# DisplayName -> PackageName for every provisioned app, in one query. The
# online enumeration takes seconds, so the caller does it once per pass rather
# than once per name - there are ~70 names in the list.
function Get-ProvisionedAppMap {
    $map = @{}
    foreach ($package in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
        if ($package.DisplayName) { $map[$package.DisplayName] = $package.PackageName }
    }
    return $map
}

function Remove-ProvisionedApp {
    param(
        [Parameter(Mandatory)]
        [string]$AppName,
        [Parameter(Mandatory)]
        [string]$PackageName,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-DryRun "Would deprovision: $AppName"
        return
    }

    try {
        Remove-AppxProvisionedPackage -Online -PackageName $PackageName -ErrorAction Stop | Out-Null
        Write-Success "Deprovisioned $AppName"
    } catch {
        Write-Warn "Could not deprovision ${AppName}: $_"
    }
}

# ponytail: pending/failed counts here are best-effort - Set-Service and
# Remove-AppxProvisionedPackage need Administrator but this does not
# specifically detect an access-denied failure the way registry.psm1 does, so
# NeedsAdmin always reports $false for these three groups. Upgrade path: teach
# them Test-AccessDeniedError if the Setup tab needs to be precise here.

function Invoke-DebloatBloatGroup {
    param([switch]$DryRun)

    $pending = 0
    $failedCount = 0
    $provisioned = Get-ProvisionedAppMap
    foreach ($app in ($BloatwareApps + $XboxApps)) {
        if (Get-AppxPackage -Name $app -ErrorAction SilentlyContinue) { $pending++ }
        if (Remove-BloatApp -AppName $app -DryRun:$DryRun) {
            if ($provisioned.ContainsKey($app)) {
                Remove-ProvisionedApp -AppName $app -PackageName $provisioned[$app] -DryRun:$DryRun
            }
        } else {
            $failedCount++
        }
    }

    return @{ Pending = $pending; NeedsAdmin = $false; Failed = $failedCount }
}

function Remove-WingetApp {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,
        [switch]$DryRun
    )

    $result = winget list --id $PackageId --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Skip "$PackageId (not installed)"
        return
    }

    if ($DryRun) {
        Write-DryRun "Would uninstall: $PackageId"
        return
    }

    winget uninstall --id $PackageId --silent --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "$PackageId uninstalled"
    } else {
        Write-Warn "Failed to uninstall $PackageId"
    }
}

function Disable-XboxServices {
    param([switch]$DryRun)

    Write-SubStep "Xbox services"

    foreach ($svc in $XboxServiceNames) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $service -or $service.StartType -eq 'Disabled') {
            Write-Skip "Service $svc already disabled or not found"
            continue
        }

        if ($DryRun) {
            Write-DryRun "Would disable service: $svc"
            continue
        }

        try {
            Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
            Write-Success "Disabled service: $svc"
        } catch {
            Write-Warn "Failed to disable service ${svc}: $_"
        }
    }

    Write-SubStep "Xbox scheduled tasks"

    $task = Get-ScheduledTask -TaskPath '\Microsoft\XblGameSave\' -TaskName 'XblGameSaveTask' -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Disabled') {
        if ($DryRun) {
            Write-DryRun "Would disable task: XblGameSaveTask"
        } else {
            try {
                Disable-ScheduledTask -TaskPath '\Microsoft\XblGameSave\' -TaskName 'XblGameSaveTask' -ErrorAction Stop | Out-Null
                Write-Success "Disabled task: XblGameSaveTask"
            } catch {
                Write-Warn "Failed to disable task XblGameSaveTask: $_"
            }
        }
    } else {
        Write-Skip "Task XblGameSaveTask already disabled or not found"
    }
}

function Invoke-DebloatXboxGroup {
    param([switch]$DryRun)

    $pending = 0
    foreach ($svc in $XboxServiceNames) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service -and $service.StartType -ne 'Disabled') { $pending++ }
    }
    $task = Get-ScheduledTask -TaskPath '\Microsoft\XblGameSave\' -TaskName 'XblGameSaveTask' -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Disabled') { $pending++ }

    Disable-XboxServices -DryRun:$DryRun

    return @{ Pending = $pending; NeedsAdmin = $false; Failed = 0 }
}

function Disable-GameDvr {
    param([switch]$DryRun)

    $gameDvrSettings = @(
        @{ Path = "HKCU:\System\GameConfigStore";                                  Name = "GameDVR_Enabled";           Value = 0 }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR";             Name = "AllowGameDVR";              Value = 0 }
        @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR";        Name = "AppCaptureEnabled";         Value = 0 }
        @{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar";                              Name = "UseNexusForGameBarEnabled";  Value = 0 }
        @{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar";                              Name = "AutoGameModeEnabled";        Value = 0 }
        @{ Path = "HKCU:\SOFTWARE\Microsoft\GameBar";                              Name = "ShowStartupPanel";           Value = 0 }
    )

    Set-RegistryValueSet -Settings $gameDvrSettings -DryRun:$DryRun
}

# Registry-based groups already report through registry.psm1's buckets, so
# their status is a before/after diff of Get-RegistryResults rather than a
# second, separately-maintained counter.
function Invoke-DebloatRegistryGroup {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $before = Get-RegistryResults
    $counts = @{ Pending = $before.Pending.Count; Failed = $before.Failed.Count; NeedsAdmin = $before.NeedsAdmin.Count }

    & $Action

    $after = Get-RegistryResults
    return @{
        Pending    = $after.Pending.Count - $counts.Pending
        Failed     = $after.Failed.Count - $counts.Failed
        NeedsAdmin = ($after.NeedsAdmin.Count - $counts.NeedsAdmin) -gt 0
    }
}

function Invoke-DebloatGameDvrGroup {
    param([switch]$DryRun)

    return Invoke-DebloatRegistryGroup -Action { Disable-GameDvr -DryRun:$DryRun }
}

function Remove-GameBarProtocols {
    param([switch]$DryRun)

    $protocols = @("ms-gamebar", "ms-gamebarservices", "ms-gamingoverlay")
    foreach ($protocol in $protocols) {
        Remove-RegistryKey -Path "Registry::HKEY_CLASSES_ROOT\$protocol" `
            -Label "protocol handler $protocol" -DryRun:$DryRun | Out-Null
    }
}

function Invoke-DebloatGameBarGroup {
    param([switch]$DryRun)

    return Invoke-DebloatRegistryGroup -Action { Remove-GameBarProtocols -DryRun:$DryRun }
}

function Disable-SuggestedApps {
    param([switch]$DryRun)

    $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"

    $names = @(
        "ContentDeliveryAllowed"
        "FeatureManagementEnabled"
        "OemPreInstalledAppsEnabled"
        "PreInstalledAppsEnabled"
        "PreInstalledAppsEverEnabled"
        "SilentInstalledAppsEnabled"
        "SoftLandingEnabled"
        "SubscribedContent-310093Enabled"
        "SubscribedContent-338387Enabled"
        "SubscribedContent-338388Enabled"
        "SubscribedContent-338389Enabled"
        "SubscribedContent-338393Enabled"
        "SubscribedContent-353694Enabled"
        "SubscribedContent-353696Enabled"
        "SubscribedContentEnabled"
        "SystemPaneSuggestionsEnabled"
    )

    $settings = @()
    foreach ($name in $names) {
        $settings += @{ Path = $regPath; Name = $name; Value = 0 }
    }

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}

function Invoke-DebloatSuggestedGroup {
    param([switch]$DryRun)

    return Invoke-DebloatRegistryGroup -Action { Disable-SuggestedApps -DryRun:$DryRun }
}

# Find Marvell AQtion 10GbE adapter by description (avoids hardcoding "Ethernet 3")
function Get-WakeOnLanAdapter {
    return Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'AQtion' }
}

function Set-WakeOnLan {
    param([switch]$DryRun)

    $adapter = Get-WakeOnLanAdapter

    if (-not $adapter) {
        Write-Skip "Marvell AQtion adapter not found"
        return
    }

    $adapterName = $adapter.Name

    foreach ($setting in $WakeOnLanSettings) {
        $prop = Get-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $setting.Name -ErrorAction SilentlyContinue
        if (-not $prop) {
            Write-Skip "$($setting.Name) not available on $adapterName"
            continue
        }

        if ($prop.DisplayValue -eq $setting.Desired) {
            Write-Skip "$($setting.Name) already $($setting.Desired)"
            continue
        }

        if ($DryRun) {
            Write-DryRun "Would set $($setting.Name) = $($setting.Desired) on $adapterName"
            continue
        }

        try {
            Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $setting.Name -DisplayValue $setting.Desired -ErrorAction Stop
            Write-Success "$($setting.Name) = $($setting.Desired)"
        } catch {
            Write-Warn "Failed to set $($setting.Name): $_"
        }
    }
}

function Invoke-DebloatWolGroup {
    param([switch]$DryRun)

    $pending = 0
    $adapter = Get-WakeOnLanAdapter
    if ($adapter) {
        foreach ($setting in $WakeOnLanSettings) {
            $prop = Get-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $setting.Name -ErrorAction SilentlyContinue
            if ($prop -and $prop.DisplayValue -ne $setting.Desired) { $pending++ }
        }
    }

    Set-WakeOnLan -DryRun:$DryRun

    return @{ Pending = $pending; NeedsAdmin = $false; Failed = 0 }
}

# --- Main ---
#
# Wrapped in a function, called only when this file is run directly (not
# dot-sourced), so bridge.ps1 can `. debloat.ps1` to pick up the functions
# above without triggering a full bloatware removal run as a side effect.

function Invoke-DebloatMain {
    param(
        [switch]$DryRun,
        [string]$Only = ''
    )

    if (-not (Test-IsWindowsPlatform)) {
        Write-Err "This script only runs on Windows."
        exit 1
    }

    if (-not (Test-Administrator)) {
        Write-Warn "Some operations require administrator privileges."
    }

    Reset-RegistryResults
    $failed = 0
    $allApps = $BloatwareApps + $XboxApps

    if ($Only) {
        $status = switch ($Only) {
            'bloat'     { Invoke-DebloatBloatGroup -DryRun:$DryRun }
            'xbox'      { Invoke-DebloatXboxGroup -DryRun:$DryRun }
            'gamedvr'   { Invoke-DebloatGameDvrGroup -DryRun:$DryRun }
            'gamebar'   { Invoke-DebloatGameBarGroup -DryRun:$DryRun }
            'wol'       { Invoke-DebloatWolGroup -DryRun:$DryRun }
            'suggested' { Invoke-DebloatSuggestedGroup -DryRun:$DryRun }
        }
        if ($status.Failed -gt 0) { exit 1 }
        exit 0
    }

    # Stage 1: Remove AppX bloatware
    Write-Step "Removing AppX Bloatware"
    $bloatStatus = Invoke-DebloatBloatGroup -DryRun:$DryRun
    $failed += $bloatStatus.Failed

    # Stage 2: Remove Win32 apps via winget
    Write-Step "Removing Win32 Applications"
    foreach ($pkg in $WingetAppsToRemove) {
        Remove-WingetApp -PackageId $pkg -DryRun:$DryRun
    }

    # Stage 3: Disable Xbox services and tasks
    Write-Step "Disabling Xbox Services"
    Invoke-DebloatXboxGroup -DryRun:$DryRun | Out-Null

    # Stage 4: Disable Game DVR and Game Bar (fixes ms-gamebar protocol errors)
    Write-Step "Disabling Game DVR and Game Bar"
    Invoke-DebloatGameDvrGroup -DryRun:$DryRun | Out-Null

    # Stage 5: Remove Game Bar protocol handlers (prevents "find an app" popup)
    Write-Step "Removing Game Bar Protocol Handlers"
    Invoke-DebloatGameBarGroup -DryRun:$DryRun | Out-Null

    # Stage 6: Fix Wake on LAN (prevents unwanted wakes from pattern match)
    Write-Step "Configuring Wake on LAN"
    Invoke-DebloatWolGroup -DryRun:$DryRun | Out-Null

    # Stage 7: Disable suggested apps
    Write-Step "Disabling Suggested Apps"
    Invoke-DebloatSuggestedGroup -DryRun:$DryRun | Out-Null

    # Summary
    Write-Host ""
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    Write-Host "Debloat Summary" -ForegroundColor White
    Write-Host "--------------------------------------" -ForegroundColor DarkGray
    $registryResults = Get-RegistryResults
    Write-Host "  AppX processed:    $($allApps.Count)"
    Write-Host "  Registry changed:  $($registryResults.Changed.Count)"
    Write-Host "  Registry unchanged: $($registryResults.Skipped.Count + $registryResults.NeedsAdmin.Count)"
    if ($failed -gt 0) {
        Write-Host "  AppX failed:       $failed" -ForegroundColor Yellow
    }
    if ($registryResults.Failed.Count -gt 0) {
        Write-Host "  Registry failed:   $($registryResults.Failed.Count)" -ForegroundColor Yellow
    }
    Write-Host ""

    # AppX removal failures are common and mostly benign (provisioned-only apps,
    # apps owned by another user). Only registry failures fail the stage.
    if ($registryResults.Failed.Count -gt 0) {
        exit 1
    }
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DebloatMain -DryRun:$DryRun -Only $Only
}
