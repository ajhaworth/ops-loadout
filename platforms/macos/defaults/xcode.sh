#!/usr/bin/env bash
# macos/defaults/xcode.sh - Xcode first-run steps a fresh Mac needs
#
# Xcode comes from the App Store with the Command Line Tools still selected
# (prereqs install those first), its licence unaccepted and no simulators.
# Every row is skipped until Xcode.app exists. Checks pin DEVELOPER_DIR so they
# ask Xcode.app itself, not whatever xcode-select points at.

apply_xcode() {
    local dev=/Applications/Xcode.app/Contents/Developer
    [[ -d "$dev" ]] || return 0

    defaults_hook "select" "Use Xcode.app for developer tools" \
        "[[ \"\$(xcode-select -p)\" == $dev ]]" \
        "sudo \${SUDO_ASKPASS:+-A} xcode-select -s $dev"

    defaults_hook "license" "Accept the Xcode licence" \
        "DEVELOPER_DIR=$dev xcodebuild -license check" \
        "sudo \${SUDO_ASKPASS:+-A} env DEVELOPER_DIR=$dev xcodebuild -license accept"

    defaults_hook "first-launch" "Install Xcode's additional components" \
        "DEVELOPER_DIR=$dev xcodebuild -checkFirstLaunchStatus" \
        "sudo \${SUDO_ASKPASS:+-A} env DEVELOPER_DIR=$dev xcodebuild -runFirstLaunch"

    # Several GB each; the latest runtime for the installed Xcode.
    local platform
    for platform in iOS tvOS; do
        defaults_hook "runtime-$platform" "$platform Simulator runtime" \
            "DEVELOPER_DIR=$dev xcrun simctl list runtimes | grep -q '^$platform '" \
            "DEVELOPER_DIR=$dev xcodebuild -downloadPlatform $platform"
    done
}
