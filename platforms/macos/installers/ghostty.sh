#!/usr/bin/env bash
# Ghostty installer: status | install | update | reinstall | uninstall
# Copies Ghostty.app out of the latest GitHub release dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

APP="/Applications/Ghostty.app"
# Ghostty has no "latest" GitHub release; macOS builds come from its Sparkle
# appcast, whose items are oldest-first, so pick the highest version.
APPCAST="https://release.files.ghostty.org/appcast.xml"

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
    local action="$1" tag url current

    echo "==> Resolving latest Ghostty release"
    url="$(curl -fsSL "$APPCAST" | grep -o 'url="[^"]*/Ghostty\.dmg"' | cut -d'"' -f2 | sort -V | tail -1 || true)"
    [[ -n "$url" ]] || { echo "No Ghostty.dmg in the appcast" >&2; return 1; }
    tag="$(sed -n 's|.*/\([0-9][0-9.]*\)/Ghostty\.dmg$|\1|p' <<<"$url")"
    echo "    latest: $tag"

    if [[ -d "$APP" ]]; then
        current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "${tag#v}" ]]; then
            echo "Ghostty $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading $url"
    dl "$url" "$TMP/Ghostty.dmg"

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$TMP/Ghostty.dmg")"
    [[ -d "$MOUNT/Ghostty.app" ]] || {
        echo "No Ghostty.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    rm -rf "$APP"
    ditto "$MOUNT/Ghostty.app" "$APP"

    echo "Ghostty $tag installed."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Ghostty is not installed."; return 1; }
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
