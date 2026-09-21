#!/usr/bin/env bash
# macos/defaults/screenshots.sh - Screenshot preferences

apply_screenshots() {
    defaults_hook "screenshots-dir" "Create ~/Pictures/Screenshots" \
        '[[ -d "$HOME/Pictures/Screenshots" ]]' \
        'mkdir -p "$HOME/Pictures/Screenshots"'

    # Save screenshots to ~/Pictures/Screenshots
    defaults_set com.apple.screencapture location string "$HOME/Pictures/Screenshots" "Save screenshots to ~/Pictures/Screenshots"

    # Save screenshots in PNG format (other options: BMP, GIF, JPG, PDF, TIFF, HEIC)
    # NOTE: macOS 26 Tahoe defaults to HEIC format. This explicitly sets PNG.
    defaults_set com.apple.screencapture type string png "Save screenshots in PNG format (macOS 26 Tahoe defaults to HEIC; this explicitly sets PNG)"

    defaults_set com.apple.screencapture disable-shadow bool true "Disable shadow in screenshots"
    defaults_set com.apple.screencapture include-date bool true "Include date in screenshot filename"
}
