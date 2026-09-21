#!/usr/bin/env bash
# macos/defaults/trackpad.sh - Trackpad preferences

apply_trackpad() {
    defaults_set NSGlobalDomain com.apple.swipescrolldirection bool true "Enable natural scrolling"
    defaults_set com.apple.AppleMultitouchTrackpad TrackpadRightClick bool true "Enable secondary click (right click)"
    defaults_set com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick bool true "Enable secondary click (right click)"
}
