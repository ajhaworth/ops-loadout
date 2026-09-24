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
    # AeroSpace (Blender + Claude Code tiling) and Stage Manager both hide and show window groups, and fight.
    defaults_set com.apple.WindowManager GloballyEnabled bool false "Stage Manager off (AeroSpace manages windows)"
    # AeroSpace parks other workspaces' windows in a screen corner; grouped by app, Mission Control stays readable.
    defaults_set com.apple.dock expose-group-apps bool true "Group windows by app in Mission Control"
}
