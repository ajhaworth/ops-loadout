# taskbar.ps1 - Taskbar and Start preferences (per-user, no admin required)
#
# TaskbarAl / TaskbarDa / TaskbarMn are Windows 11 keys. Setting them on
# Windows 10 is harmless - Explorer simply ignores them.

function Apply-Taskbar {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $advanced = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $search   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    $policies = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"

    $settings = @(
        @{ Path = $advanced; Name = 'TaskbarAl';                  Value = 0; Label = 'Align taskbar left' }
        @{ Path = $advanced; Name = 'TaskbarDa';                  Value = 0; Label = 'Hide widgets button' }
        @{ Path = $advanced; Name = 'TaskbarMn';                  Value = 0; Label = 'Hide chat button' }
        @{ Path = $advanced; Name = 'ShowTaskViewButton';         Value = 0; Label = 'Hide Task View button' }
        @{ Path = $advanced; Name = 'TaskbarGlomLevel';           Value = 0; Label = 'Always combine taskbar buttons' }
        @{ Path = $search;   Name = 'SearchboxTaskbarMode';       Value = 0; Label = 'Hide taskbar search box' }
        @{ Path = $policies; Name = 'DisableSearchBoxSuggestions'; Value = 1; Label = 'Disable web results in Start search' }
    )

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}
