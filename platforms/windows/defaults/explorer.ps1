# explorer.ps1 - File Explorer preferences (per-user, no admin required)

function Apply-Explorer {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $advanced = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $explorer = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
    $cabinet  = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"

    $settings = @(
        @{ Path = $advanced; Name = 'HideFileExt';           Value = 0; Label = 'Show file extensions' }
        @{ Path = $advanced; Name = 'Hidden';                Value = 1; Label = 'Show hidden files' }
        # Protected OS files stay hidden on purpose - showing them is noisy and
        # invites accidental edits.
        @{ Path = $advanced; Name = 'ShowSuperHidden';       Value = 0; Label = 'Hide protected OS files' }
        @{ Path = $advanced; Name = 'LaunchTo';              Value = 1; Label = 'Open Explorer to This PC' }
        @{ Path = $advanced; Name = 'NavPaneShowAllFolders'; Value = 1; Label = 'Show all folders in nav pane' }
        @{ Path = $advanced; Name = 'SeparateProcess';       Value = 1; Label = 'Explorer windows in separate processes' }
        @{ Path = $cabinet;  Name = 'FullPath';              Value = 1; Label = 'Full path in title bar' }
        @{ Path = $explorer; Name = 'ShowRecent';            Value = 0; Label = 'Hide recent files in Quick Access' }
        @{ Path = $explorer; Name = 'ShowFrequent';          Value = 0; Label = 'Hide frequent folders in Quick Access' }
    )

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}
