# appearance.ps1 - Theme preferences (per-user, no admin required)

function Apply-Appearance {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $personalize = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"

    $settings = @(
        @{ Path = $personalize; Name = 'AppsUseLightTheme';   Value = 0; Label = 'Dark mode for apps' }
        @{ Path = $personalize; Name = 'SystemUsesLightTheme'; Value = 0; Label = 'Dark mode for system' }
    )

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}
