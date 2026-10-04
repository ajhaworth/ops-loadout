# gaming.ps1 - Input and update behaviour for a gaming and streaming host
#
# The mouse and accessibility values are per-user strings, read at sign-in, so
# they take effect after signing out and back in. The HKLM half needs
# Administrator and reports needs_admin without it. Game DVR and the Game Bar
# are debloat.ps1's, not this module's.

function Apply-Gaming {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $mouse         = "HKCU:\Control Panel\Mouse"
    $accessibility = "HKCU:\Control Panel\Accessibility"

    # Flags values are the stock ones with only the "hotkey active" bit cleared,
    # so the features themselves still work from Settings.
    $settings = @(
        @{ Path = $mouse; Name = 'MouseSpeed';      Value = '0'; Type = 'String'; Label = 'Turn off mouse acceleration' }
        @{ Path = $mouse; Name = 'MouseThreshold1'; Value = '0'; Type = 'String'; Label = 'Mouse acceleration threshold 1 off' }
        @{ Path = $mouse; Name = 'MouseThreshold2'; Value = '0'; Type = 'String'; Label = 'Mouse acceleration threshold 2 off' }
        @{ Path = "$accessibility\StickyKeys";        Name = 'Flags'; Value = '506'; Type = 'String'; Label = 'No Sticky Keys prompt on Shift x5' }
        @{ Path = "$accessibility\ToggleKeys";        Name = 'Flags'; Value = '58';  Type = 'String'; Label = 'No Toggle Keys prompt on Num Lock hold' }
        @{ Path = "$accessibility\Keyboard Response"; Name = 'Flags'; Value = '122'; Type = 'String'; Label = 'No Filter Keys prompt on Right Shift hold' }

        # Takes a reboot. Needed by DLSS frame generation on NVIDIA.
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
           Name = 'HwSchMode'; Value = 2; Label = 'Hardware-accelerated GPU scheduling' }
        # Overnight renders and stream sessions should not be cut by an update
        # restart. Microsoft documents this policy against scheduled installs;
        # if Windows still restarts on its own, that scoping is why.
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
           Name = 'NoAutoRebootWithLoggedOnUsers'; Value = 1; Label = 'No update restarts while signed in' }
    )

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}
