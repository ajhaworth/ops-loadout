#!/usr/bin/env bash
# macos/defaults/dock.sh - Dock preferences

apply_dock() {
    defaults_set com.apple.dock autohide bool true "Auto-hide the Dock"
    defaults_set com.apple.dock tilesize int 128 "Set the icon size of Dock items (max: 128)"
    defaults_set com.apple.dock magnification bool false "Magnification"
    defaults_set com.apple.dock minimize-to-application bool true "Minimize windows into their application's icon"
    defaults_set com.apple.dock show-process-indicators bool true "Show indicator lights for open applications"
    defaults_set com.apple.dock launchanim bool false "Don't animate opening applications"
    defaults_set com.apple.dock show-recents bool false "Don't show recent applications in Dock"
    defaults_set com.apple.dock mineffect string scale "Minimize windows using scale effect (faster than genie)"
    defaults_set com.apple.dock orientation string bottom "Position on screen (left, bottom, right)"
    defaults_set com.apple.dock showhidden bool true "Make Dock icons of hidden applications translucent"
    defaults_set com.apple.dock mru-spaces bool false "Don't rearrange Spaces based on most recent use"
    # Stage Manager moves windows into and out of its strip, which Loadout WM would take for drags and undo.
    defaults_set com.apple.WindowManager GloballyEnabled bool false "Stage Manager off (Loadout WM manages windows)"
    # Swish snaps windows (and Loadout WM pads its snaps); macOS's own edge tiling would compete with it.
    defaults_set com.apple.WindowManager EnableTilingByEdgeDrag bool false "Don't tile windows dragged to screen edges"
    defaults_set com.apple.WindowManager EnableTopTilingByEdgeDrag bool false "Don't fill the screen when dragging to the top"
    defaults_set com.apple.WindowManager EnableTilingOptionAccelerator bool false "Don't tile windows on Option-drag"
    # Ctrl-Cmd-drag moves a window from anywhere in it (applies after logout): swaps Loadout WM split columns by
    # dropping one on another, without hunting for a title bar in Blender or Houdini.
    defaults_set NSGlobalDomain NSWindowShouldDragOnGesture bool true "Ctrl-Cmd-drag moves windows from anywhere"
}
