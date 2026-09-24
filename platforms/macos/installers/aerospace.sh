#!/usr/bin/env bash
# AeroSpace installer: status | install | update | reinstall | uninstall
# Copies AeroSpace.app out of the latest GitHub release zip into /Applications and
# its CLI into ~/.local/bin. Its config is the aerospace dotfile (manifest.txt).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

APP="/Applications/AeroSpace.app"
CLI="$HOME/.local/bin/aerospace"
# Every AeroSpace release is a prerelease, so releases/latest 404s: take the newest.
RELEASES="https://api.github.com/repos/nikitabobko/AeroSpace/releases?per_page=1"

do_status() {
    [[ -d "$APP" ]] || return 1
    printf '%s\n' "$APP"
}

TMP=""
cleanup() {
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" url tag current

    echo "==> Resolving latest AeroSpace release"
    url="$(curl -fsSL "$RELEASES" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4 || true)"
    [[ -n "$url" ]] || { echo "No zip asset on the latest AeroSpace release" >&2; return 1; }
    tag="$(sed -n 's|.*/download/v\([^/]*\)/.*|\1|p' <<<"$url")"
    echo "    latest: $tag"

    if [[ -d "$APP" ]]; then
        current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$tag" ]]; then
            echo "AeroSpace $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading $url"
    dl "$url" "$TMP/aerospace.zip"
    ditto -x -k "$TMP/aerospace.zip" "$TMP"
    local dir
    dir="$(find "$TMP" -maxdepth 1 -type d -name 'AeroSpace-*' | head -1)"
    [[ -d "$dir/AeroSpace.app" && -f "$dir/bin/aerospace" ]] || {
        echo "Unexpected zip layout. Contents:" >&2
        ls -1R "$TMP" | head -20 >&2
        return 1
    }

    echo "==> Installing into $APP and $CLI"
    osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
    rm -rf "$APP"
    ditto "$dir/AeroSpace.app" "$APP"
    mkdir -p "$(dirname "$CLI")"
    install -m 0755 "$dir/bin/aerospace" "$CLI"
    # Stage Manager hides and shows window groups too, and fights AeroSpace. dock.sh sets this as well, but profiles
    # without system defaults (workstation) only get it here.
    defaults write com.apple.WindowManager GloballyEnabled -bool false
    open -a "$APP"

    echo "AeroSpace $tag installed and Stage Manager turned off. Allow AeroSpace under"
    echo "Privacy & Security > Accessibility when asked, and apply the AeroSpace dotfiles (Updates tab)."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "AeroSpace is not installed."; return 1; }
    osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
    rm -rf "$APP" "$CLI"
    echo "Removed $APP and $CLI"
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
