#!/usr/bin/env bash
# Vorssaint installer: status | install | update | reinstall | uninstall
# Copies Vorssaint.app out of the latest GitHub release dmg (the cask's source) into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

APP="/Applications/Vorssaint.app"
RELEASE_API="https://api.github.com/repos/vorssaint/vorssaint-utils/releases/latest"

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

    echo "==> Resolving latest Vorssaint release"
    local json
    json="$(curl -fsSL "$RELEASE_API")" || { echo "GitHub release lookup failed" >&2; return 1; }
    url="$(grep -o '"browser_download_url": *"[^"]*/Vorssaint-[^/"]*\.dmg"' <<<"$json" | cut -d'"' -f4 | head -1 || true)"
    [[ -n "$url" ]] || { echo "No Vorssaint dmg on the latest release" >&2; return 1; }
    version="$(sed -n 's|.*/Vorssaint-\(.*\)\.dmg$|\1|p' <<<"$url")"
    echo "    latest: $version"

    if [[ -d "$APP" ]]; then
        current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$version" ]]; then
            echo "Vorssaint $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading $url"
    dl "$url" "$TMP/Vorssaint.dmg"

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$TMP/Vorssaint.dmg")"
    [[ -d "$MOUNT/Vorssaint.app" ]] || {
        echo "No Vorssaint.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    pkill -x Vorssaint || true
    rm -rf "$APP"
    ditto "$MOUNT/Vorssaint.app" "$APP"

    echo "Vorssaint $version installed."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Vorssaint is not installed."; return 1; }
    pkill -x Vorssaint || true
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
