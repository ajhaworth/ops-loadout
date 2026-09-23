#!/usr/bin/env bash
# Swish installer: status | install | update | reinstall | uninstall
# Copies Swish.app out of the latest GitHub release dmg (the cask's source) into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

APP="/Applications/Swish.app"
RELEASE_API="https://api.github.com/repos/chrenn/swish-dl/releases/latest"

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

    echo "==> Resolving latest Swish release"
    local json
    json="$(curl -fsSL "$RELEASE_API")" || { echo "GitHub release lookup failed" >&2; return 1; }
    url="$(grep -o '"browser_download_url": *"[^"]*/Swish\.dmg"' <<<"$json" | cut -d'"' -f4 | head -1 || true)"
    [[ -n "$url" ]] || { echo "No Swish.dmg on the latest release" >&2; return 1; }
    version="$(sed -n 's|.*/download/\([^/]*\)/Swish\.dmg$|\1|p' <<<"$url")"
    echo "    latest: $version"

    if [[ -d "$APP" ]]; then
        current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$version" ]]; then
            echo "Swish $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading $url"
    dl "$url" "$TMP/Swish.dmg"

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$TMP/Swish.dmg")"
    [[ -d "$MOUNT/Swish.app" ]] || {
        echo "No Swish.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    pkill -x Swish || true
    rm -rf "$APP"
    ditto "$MOUNT/Swish.app" "$APP"

    echo "Swish $version installed."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Swish is not installed."; return 1; }
    pkill -x Swish || true
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
