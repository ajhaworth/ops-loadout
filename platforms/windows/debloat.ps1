# debloat.ps1 - Remove Windows bloatware
#
# Removes pre-installed Windows apps, disables Xbox services, Game DVR,
# Game Bar protocol handlers, and suggested apps. Safe to re-run (idempotent).
# Gated behind PROFILE_DEBLOAT flag for safety.

param(
    [switch]$DryRun,
    [switch]$Force
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

# Win32 apps to uninstall via winget (not AppX packages)
$WingetAppsToRemove = @(
    "Microsoft.OneDrive"
)

# --- Functions ---

function Remove-BloatApp {
    param(
        [Parameter(Mandatory)]
        [string]$AppName
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

function Remove-ProvisionedApp {
    param(
        [Parameter(Mandatory)]
        [string]$AppName
    )

    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $AppName }

    if (-not $provisioned) {
        return
    }

    if ($DryRun) {
        Write-DryRun "Would deprovision: $AppName"
        return
    }

    try {
        Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction Stop | Out-Null
        Write-Success "Deprovisioned $AppName"
    } catch {
        Write-Warn "Could not deprovision ${AppName}: $_"
    }
}

function Remove-WingetApp {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
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
    Write-SubStep "Xbox services"

    $xboxServices = @("XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc")
    foreach ($svc in $xboxServices) {
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

function Disable-GameDvr {
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

function Remove-GameBarProtocols {
    $protocols = @("ms-gamebar", "ms-gamebarservices", "ms-gamingoverlay")
    foreach ($protocol in $protocols) {
        Remove-RegistryKey -Path "Registry::HKEY_CLASSES_ROOT\$protocol" `
            -Label "protocol handler $protocol" -DryRun:$DryRun | Out-Null
    }
}

function Disable-SuggestedApps {
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

function Fix-WakeOnLan {
    # Find Marvell AQtion 10GbE adapter by description (avoids hardcoding "Ethernet 3")
    $adapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'AQtion' }

    if (-not $adapter) {
        Write-Skip "Marvell AQtion adapter not found"
        return
    }

    $adapterName = $adapter.Name

    # Desired wake settings: only magic packet enabled (for Moonlight WoL)
    $wakeSettings = @(
        @{ Name = "Wake on Magic Packet";      Desired = "Enabled" }
        @{ Name = "Wake on Pattern Match";     Desired = "Disabled" }
        @{ Name = "Wake from power off state"; Desired = "Enabled" }
        @{ Name = "Wake on Link";              Desired = "Disabled" }
        @{ Name = "Wake on Ping";              Desired = "Disabled" }
    )

    foreach ($setting in $wakeSettings) {
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

# --- Main ---

if (-not (Test-IsWindowsPlatform)) {
    Write-Err "This script only runs on Windows."
    exit 1
}

if (-not (Test-Administrator)) {
    Write-Warn "Some operations require administrator privileges."
}

Reset-RegistryResults
$failed = 0

# Stage 1: Remove AppX bloatware
Write-Step "Removing AppX Bloatware"

$allApps = $BloatwareApps + $XboxApps
foreach ($app in $allApps) {
    if (Remove-BloatApp -AppName $app) {
        Remove-ProvisionedApp -AppName $app
    } else {
        $failed++
    }
}

# Stage 2: Remove Win32 apps via winget
Write-Step "Removing Win32 Applications"

foreach ($pkg in $WingetAppsToRemove) {
    Remove-WingetApp -PackageId $pkg
}

# Stage 3: Disable Xbox services and tasks
Write-Step "Disabling Xbox Services"
Disable-XboxServices

# Stage 4: Disable Game DVR and Game Bar (fixes ms-gamebar protocol errors)
Write-Step "Disabling Game DVR and Game Bar"
Disable-GameDvr

# Stage 5: Remove Game Bar protocol handlers (prevents "find an app" popup)
Write-Step "Removing Game Bar Protocol Handlers"
Remove-GameBarProtocols

# Stage 6: Fix Wake on LAN (prevents unwanted wakes from pattern match)
Write-Step "Configuring Wake on LAN"
Fix-WakeOnLan

# Stage 7: Disable suggested apps
Write-Step "Disabling Suggested Apps"
Disable-SuggestedApps

# Summary
Write-Host ""
Write-Host "--------------------------------------" -ForegroundColor DarkGray
Write-Host "Debloat Summary" -ForegroundColor White
Write-Host "--------------------------------------" -ForegroundColor DarkGray
$registryResults = Get-RegistryResults
Write-Host "  AppX processed:    $($allApps.Count)"
Write-Host "  Registry changed:  $($registryResults.Changed.Count)"
Write-Host "  Registry unchanged: $($registryResults.Skipped.Count)"
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
