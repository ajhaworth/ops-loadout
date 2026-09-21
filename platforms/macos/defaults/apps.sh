#!/usr/bin/env bash
# macos/defaults/apps.sh - App-specific preferences
#
# Safari is sandboxed since macOS Mojave (10.14) - these preferences cannot
# be set via `defaults write`. Configure it manually or via MDM profiles.

apply_apps() {
    # TextEdit: plain text mode, UTF-8
    defaults_set com.apple.TextEdit RichText int 0 "Use plain text mode for new documents"
    defaults_set com.apple.TextEdit PlainTextEncoding int 4 "Open files as UTF-8"
    defaults_set com.apple.TextEdit PlainTextEncodingForWrite int 4 "Save files as UTF-8"

    # Activity Monitor
    defaults_set com.apple.ActivityMonitor OpenMainWindow bool true "Show the main window when launching"
    defaults_set com.apple.ActivityMonitor ShowCategory int 0 "Show all processes"
    defaults_set com.apple.ActivityMonitor SortColumn string CPUUsage "Sort by CPU usage"
    defaults_set com.apple.ActivityMonitor SortDirection int 0 "Sort by CPU usage"

    # Disk Utility
    defaults_set com.apple.DiskUtility DUDebugMenuEnabled bool true "Enable the debug menu"
    defaults_set com.apple.DiskUtility advanced-image-options bool true "Enable advanced image options"
}
