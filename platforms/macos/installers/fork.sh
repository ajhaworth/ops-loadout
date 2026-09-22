#!/usr/bin/env bash
# Fork installer: status | install | update | reinstall | uninstall
# Copies Fork.app out of the latest Sparkle-appcast dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_dmg.sh"

APP="/Applications/Fork.app"
APPCAST="https://git-fork.com/update/feed.xml"

do_status() {
    [[ -d "$APP" ]] || return 1
    printf '%s\n' "$APP"
}

MOUNT=""
TMP=""
cleanup() {
    dmg_detach "$MOUNT"
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" url version current

    echo "==> Resolving latest Fork release"
    url="$(curl -fsSL "$APPCAST" | grep -o 'url="[^"]*\.dmg"' | head -1 | cut -d'"' -f2 || true)"
    [[ -n "$url" ]] || { echo "No dmg enclosure found in Fork's appcast" >&2; return 1; }
    version="$(sed -n 's/.*Fork-\([0-9][0-9.]*\)\.dmg/\1/p' <<<"$url")"
    [[ -n "$version" ]] || { echo "Could not parse a version out of: $url" >&2; return 1; }
    echo "    latest: $version"

    if [[ -d "$APP" ]]; then
        current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$version" ]]; then
            echo "Fork $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading $url"
    curl -fsSL -o "$TMP/Fork.dmg" "$url"

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$TMP/Fork.dmg")"
    [[ -d "$MOUNT/Fork.app" ]] || {
        echo "No Fork.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    rm -rf "$APP"
    ditto "$MOUNT/Fork.app" "$APP"

    echo "Fork $version installed."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Fork is not installed."; return 1; }
    rm -rf "$APP"
    echo "Removed $APP"
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
