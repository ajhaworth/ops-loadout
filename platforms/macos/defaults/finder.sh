#!/usr/bin/env bash
# macos/defaults/finder.sh - Finder preferences

apply_finder() {
    defaults_set com.apple.finder AppleShowAllFiles bool true "Show hidden files"
    defaults_set NSGlobalDomain AppleShowAllExtensions bool true "Show all filename extensions"
    defaults_set com.apple.finder ShowStatusBar bool true "Show status bar"
    defaults_set com.apple.finder ShowPathbar bool true "Show path bar"
    defaults_set com.apple.finder _FXSortFoldersFirst bool true "Keep folders on top when sorting by name"
    defaults_set com.apple.finder FXDefaultSearchScope string SCcf "When performing a search, search the current folder by default"
    defaults_set com.apple.finder FXEnableExtensionChangeWarning bool false "Disable the warning when changing a file extension"
    defaults_set com.apple.desktopservices DSDontWriteNetworkStores bool true "Avoid creating .DS_Store files on network volumes"
    defaults_set com.apple.desktopservices DSDontWriteUSBStores bool true "Avoid creating .DS_Store files on USB volumes"
    defaults_set com.apple.finder FXPreferredViewStyle string Nlsv "Use list view in all Finder windows by default"

    defaults_hook "library-visible" "Show the ~/Library folder" \
        '! ls -lOd ~/Library | grep -q hidden' \
        'chflags nohidden ~/Library'

    defaults_hook "volumes-visible" "Show the /Volumes folder" \
        '! ls -lOd /Volumes | grep -q hidden' \
        'sudo ${SUDO_ASKPASS:+-A} chflags nohidden /Volumes'

    defaults_set NSGlobalDomain NSNavPanelExpandedStateForSaveMode bool true "Expand save panel by default"
    defaults_set NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 bool true "Expand save panel by default"
    defaults_set NSGlobalDomain PMPrintingExpandedStateForPrint bool true "Expand print panel by default"
    defaults_set NSGlobalDomain PMPrintingExpandedStateForPrint2 bool true "Expand print panel by default"
    defaults_set com.apple.finder NewWindowTarget string PfDe "Set Desktop as the default location for new Finder windows"
    defaults_set com.apple.finder NewWindowTargetPath string "file://${HOME}/Desktop/" "Set Desktop as the default location for new Finder windows"
    defaults_set com.apple.finder DisableAllAnimations bool true "Disable window and Get Info animations"
}
