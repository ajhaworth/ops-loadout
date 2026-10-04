#!/usr/bin/env bash
# macos/defaults/wallpaper.sh - Desktop picture from config/wallpapers/macos.jpg

# wallpaper_jxa get <path>: exit 0 when every screen shows <path>
# wallpaper_jxa set <path>: put <path> on every screen
# NSWorkspace runs in-process, so unlike System Events it needs no Automation
# permission. It covers the current Space on each display, which is all
# AeroSpace uses.
wallpaper_jxa() {
    osascript -l JavaScript -e '
function run(argv) {
    ObjC.import("AppKit");
    const ws = $.NSWorkspace.sharedWorkspace, screens = $.NSScreen.screens;
    const url = $.NSURL.fileURLWithPath(argv[1]);
    for (let i = 0; i < screens.count; i++) {
        const screen = screens.objectAtIndex(i);
        if (argv[0] === "set") {
            if (!ws.setDesktopImageURLForScreenOptionsError(url, screen, $.NSDictionary.dictionary, null))
                throw new Error("could not set the desktop picture");
        } else if (ws.desktopImageURLForScreen(screen).path.js !== argv[1]) {
            throw new Error("different desktop picture");
        }
    }
}' "$@"
}
export -f wallpaper_jxa

apply_wallpaper() {
    local img
    img="$(printf '%q' "$REPO_ROOT/config/wallpapers/macos.jpg")"
    defaults_hook desktop "Desktop picture from the repo" "wallpaper_jxa get $img" "wallpaper_jxa set $img"
}
