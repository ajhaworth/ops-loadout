#!/usr/bin/env bash
# Loadout WM installer: status | install | update | reinstall | uninstall
# This repo's own window manager (wm/; rules are the config/dotfiles/wm/rules.txt dotfile). release.yml attaches
# it to every Loadout release as loadout-wm-macos.zip; this copies Loadout WM.app out of the latest one into
# ~/Applications and starts it at login with a LaunchAgent.
#
# WM_VERSION is the wm/Cargo.toml version this checkout expects (smoke.sh keeps them in step). The installed copy
# is replaced only when it differs: the app is ad-hoc signed, so macOS ties the Accessibility grant to that exact
# binary and every replacement asks for it again.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

WM_VERSION="0.3.1"
APP="$HOME/Applications/Loadout WM.app"
LABEL="dev.alx.loadout-wm"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
URL="https://github.com/ajhaworth/ops-loadout/releases/latest/download/loadout-wm-macos.zip"

installed_version() {
    defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?'
}

do_status() {
    [[ -d "$APP" ]] || return 1
    printf '%s\n' "$APP"
    [[ "$(installed_version)" == "$WM_VERSION" ]] || echo outdated
}

stop_wm() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    pkill -x loadout-wm 2>/dev/null || true
}

# KeepAlive only after a crash, so `launchctl bootout` (or uninstall) stops it for good.
start_wm() {
    mkdir -p "$(dirname "$AGENT")"
    cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/loadout-wm</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/loadout-wm.log</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
}

TMP=""
cleanup() {
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" current got
    current="$(installed_version)"
    if [[ -d "$APP" && "$action" != "reinstall" && "$current" == "$WM_VERSION" ]]; then
        echo "Loadout WM $current is current; restarting it."
        stop_wm
        start_wm
        return 0
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT
    echo "==> Downloading $URL"
    dl "$URL" "$TMP/loadout-wm.zip"
    ditto -x -k "$TMP/loadout-wm.zip" "$TMP"
    [[ -x "$TMP/Loadout WM.app/Contents/MacOS/loadout-wm" ]] || {
        echo "Unexpected zip layout. Contents:" >&2
        ls -1R "$TMP" | head -20 >&2
        return 1
    }
    got="$(defaults read "$TMP/Loadout WM.app/Contents/Info.plist" CFBundleShortVersionString)"
    [[ "$got" == "$WM_VERSION" ]] || {
        echo "The latest release has Loadout WM $got but this checkout expects $WM_VERSION; the release with it" >&2
        echo "has not been built yet." >&2
        return 1
    }

    echo "==> Installing into $APP (was $current)"
    stop_wm
    mkdir -p "$(dirname "$APP")"
    # Copy beside the old app first, so a failed copy leaves it in place.
    rm -rf "$APP.new"
    ditto "$TMP/Loadout WM.app" "$APP.new" || {
        rm -rf "$APP.new"
        echo "Copying Loadout WM.app failed; the installed app is unchanged." >&2
        return 1
    }
    rm -rf "$APP"
    mv "$APP.new" "$APP"
    start_wm

    echo "Loadout WM $got installed and running at login. Allow it under Privacy & Security > Accessibility when"
    echo "asked, and apply the wm dotfile (Updates tab)."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Loadout WM is not installed."; return 1; }
    stop_wm
    rm -rf "$APP" "$AGENT"
    echo "Removed $APP and its LaunchAgent"
}

case "${1:-status}" in
    status)                    do_status ;;
    install|update|reinstall)  do_install "$1" ;;
    uninstall)                 do_uninstall ;;
    *)
        echo "usage: $(basename "$0") <status|install|update|reinstall|uninstall>" >&2
        exit 2
        ;;
esac
