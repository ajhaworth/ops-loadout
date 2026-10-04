# system.ps1 - Machine-wide prerequisites the rest of this repo leans on
#
# All HKLM, so Administrator; without it each row reports needs_admin.
#
# - Developer Mode lets the dotfiles stage create symlinks unelevated.
# - Long paths: ComfyUI node venvs, Houdini packages and git checkouts nest
#   deep enough to pass MAX_PATH.
# - Caps Lock -> F18 is GlazeWM's leader key, the Windows counterpart of
#   config/dotfiles/aerospace/capslock-f18.plist. Scancode Map is read at boot,
#   so it takes a reboot, and it applies to every user. A game that binds Caps
#   Lock (push-to-talk) sees F18 instead.

function Apply-System {
    param(
        [hashtable]$ProfileConfig = @{},
        [switch]$DryRun
    )

    $settings = @(
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
           Name = 'AllowDevelopmentWithoutDevLicense'; Value = 1; Label = 'Developer Mode (symlinks without Administrator)' }
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
           Name = 'LongPathsEnabled'; Value = 1; Label = 'Allow paths longer than 260 characters' }
    )

    # Only with GlazeWM's config managed: nothing else wants F18.
    if (Test-ProfileFlag -Profile $ProfileConfig -Flag 'DOTFILES_GLAZEWM') {
        # Header (8 zero bytes), entry count 2 (one mapping + terminator),
        # F18 (0x0069) <- Caps Lock (0x003A), null terminator. Little-endian.
        $capsToF18 = [byte[]](0,0,0,0, 0,0,0,0, 2,0,0,0, 0x69,0,0x3A,0, 0,0,0,0)
        $settings += @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout"
                        Name = 'Scancode Map'; Value = $capsToF18; Type = 'Binary'
                        Label = 'Caps Lock sends F18 (GlazeWM leader, after reboot)' }
    }

    Set-RegistryValueSet -Settings $settings -DryRun:$DryRun
}
