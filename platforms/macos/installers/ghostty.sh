#!/usr/bin/env bash
# Ghostty installer: status | install | update | reinstall | uninstall
# Copies Ghostty.app out of the latest GitHub release dmg into /Applications.

set -euo pipefail

APP="/Applications/Ghostty.app"
LATEST="https://api.github.com/repos/ghostty-org/ghostty/releases/latest"

do_status() {
    [[ -d "$APP" ]] || return 1
    printf '%s\n' "$APP"
}

MOUNT=""
TMP=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" tag url current
    local -a curl_headers=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && curl_headers=(-H "Authorization: Bearer $GITHUB_TOKEN")

    echo "==> Resolving latest Ghostty release"
    read -r tag url < <(curl -fsS "${curl_headers[@]}" "$LATEST" | jq -r '"\(.tag_name) \(.assets[] | select(.name == "Ghostty.dmg") | .browser_download_url)"')
    [[ -n "${url:-}" ]] || { echo "No Ghostty.dmg asset in the latest release" >&2; return 1; }
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
    curl -fsSL -o "$TMP/Ghostty.dmg" "$url"

    echo "==> Mounting"
    MOUNT="$(hdiutil attach -nobrowse -noverify -readonly "$TMP/Ghostty.dmg" 2>/dev/null \
        | tail -1 | awk -F'\t' '{ print $NF }')"
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
