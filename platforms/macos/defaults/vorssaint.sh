#!/usr/bin/env bash
# macos/defaults/vorssaint.sh - Vorssaint features and capture shortcuts
#
# Keys come from Vorssaint's source (github.com/vorssaint/vorssaint-utils):
# Core/Defaults.swift, Core/FeatureCatalog.swift and Core/GlobalShortcut.swift.
# A feature is installed by featureAvailable.<id>; most also have an
# <x>Enabled switch that ships off. Features not listed here are left to the app.

VORSSAINT_TAKEOVER_KEYS="screenshotShortcut screenshotFullScreenShortcut recorderShortcut"

apply_vorssaint() {
    [[ -d /Applications/Vorssaint.app ]] || return 0
    local d=com.vorssaint.utils entry changed_before="${TASK_CHANGED:-0}"

    defaults_set $d launchAtLoginWanted bool true "Open at login"

    for entry in \
        "switcher|App switcher" "dockPreview|Dock previews" "mixer|Volume mixer" \
        "soundOutputSwitcher|Output switcher" "micMute|Mute microphones" "musicBlock|Music app blocker" \
        "keepAwake|Keep awake" "monitorCPU|CPU monitor" "monitorGPU|GPU monitor" \
        "monitorMemory|Memory monitor" "monitorNetwork|Network monitor" "monitorDisk|Disk monitor" \
        "monitorPower|Power monitor" "shelf|Shelf" "finderCutPaste|Finder cut and paste" \
        "finderRename|Finder rename with F2" "pastePlain|Paste as plain text" "urlCleaner|Clean URLs" \
        "diskImageInstaller|Disk image installer" "portManager|Port manager" "screenshot|Screenshot" \
        "screenRecorder|Screen recording" "screenOCR|Copy text from screen" "colorPicker|Color picker" \
        "cleaningMode|Cleaning mode" \
        "extraBrightness|Extra brightness control" "bluetoothSleep|Bluetooth off during sleep" \
        "appUpdates|App updates" "homebrew|Homebrew manager"; do
        defaults_set $d "featureAvailable.${entry%%|*}" bool true "Install ${entry#*|}"
    done

    defaults_set $d soundOutputSwitcherEnabled bool true "Output switcher on"
    defaults_set $d micMuteShortcutEnabled bool true "Mute microphones on Ctrl-Option-Cmd-M"
    defaults_set $d musicBlockEnabled bool true "Play key no longer launches Music"
    defaults_set $d finderRenameEnabled bool true "F2 renames in Finder"
    defaults_set $d pastePlainEnabled bool true "Paste as plain text on"
    defaults_set $d screenOCRShortcutEnabled bool true "Copy text from screen on Ctrl-Option-Cmd-T"
    defaults_set $d colorPickerShortcutEnabled bool true "Color picker on Ctrl-Option-Cmd-C"
    defaults_set $d featureAvailable.quitWindowProtection bool false "No quit protection (Cmd-Q quits at once)"
    defaults_set $d bluetoothSleepEnabled bool true "Bluetooth off during sleep, back on wake"

    defaults_set $d featureAvailable.superKey bool false "No Super key"
    # Loadout WM places windows.
    for entry in "windowLayout|Window layout" "windowMaximizer|Maximize windows" \
                 "focusFollowsMouse|Focus follows mouse" "autoQuit|Quit on close"; do
        defaults_set $d "featureAvailable.${entry%%|*}" bool false "No ${entry#*|} (Loadout WM manages windows)"
    done
    # Raycast keeps clipboard history, snippets and the launcher.
    for entry in "clipboardHistory|Clipboard history" "textSnippets|Text snippets" \
                 "commandBar|Command Bar" "quickLauncher|Quick panel"; do
        defaults_set $d "featureAvailable.${entry%%|*}" bool false "No ${entry#*|} (Raycast owns it)"
    done
    # Mole (mo) uninstalls and cleans.
    for entry in "uninstaller|Uninstaller" "cleaner|Cleaner"; do
        defaults_set $d "featureAvailable.${entry%%|*}" bool false "No ${entry#*|} (Mole owns it)"
    done
    # A three-finger press is a Swish gesture.
    defaults_set $d featureAvailable.middleClick bool false "No middle click (Swish owns three-finger presses)"

    # Default screenshot tool: the macOS keys, taken over from the system while
    # Vorssaint runs (it restores them on quit). Key codes: 3=20, 4=21, 5=23.
    defaults_set $d screenshotShortcutEnabled bool true "Screenshot shortcut on"
    defaults_set $d screenshotShortcut string "shift+command:21" "Screenshot an area on Cmd-Shift-4"
    defaults_set $d screenshotFullScreenShortcutEnabled bool true "Full-screen screenshot shortcut on"
    defaults_set $d screenshotFullScreenShortcut string "shift+command:20" "Screenshot the screen on Cmd-Shift-3"
    defaults_set $d recorderShortcutEnabled bool true "Screen recording shortcut on"
    defaults_set $d recorderShortcut string "shift+command:23" "Record the screen on Cmd-Shift-5"
    defaults_hook "takeover" "Take Cmd-Shift-3/4/5 over from macOS" \
        "out=\$(defaults read $d systemShortcutTakeOverKeys) && for k in $VORSSAINT_TAKEOVER_KEYS; do grep -qw \"\$k\" <<<\"\$out\" || exit 1; done" \
        "for k in $VORSSAINT_TAKEOVER_KEYS; do defaults read $d systemShortcutTakeOverKeys 2>/dev/null | grep -qw \"\$k\" || defaults write $d systemShortcutTakeOverKeys -array-add \"\$k\"; done"

    # Features and shortcut claims load at launch; relaunch only if a row was written.
    if [[ "${TASK_MODE:-apply}" != "status" ]] && (( ${TASK_CHANGED:-0} > changed_before )) \
        && ! is_dry_run && pgrep -xq Vorssaint; then
        osascript -e 'quit app "Vorssaint"' >/dev/null 2>&1 || true
        local _
        for _ in {1..50}; do pgrep -xq Vorssaint || break; sleep 0.2; done
        open -a Vorssaint
        log_substep "Relaunched Vorssaint"
    fi
}
