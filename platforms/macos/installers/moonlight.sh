#!/usr/bin/env bash
# Moonlight installer: status | install | update | reinstall | uninstall
#                      | channels | channel <name>
# Installs moonlight-qt as /Applications/Moonlight.app from one channel:
#   release - the latest GitHub release dmg (default)
#   nightly - the newest successful master build. Artifacts are only
#             downloadable when logged in, so this needs `gh` (formula in
#             software-dev.txt) with an active `gh auth login`.
# `channels` lists them, the current one prefixed `* ` (Loadout's right-click
# menu); `channel <name>` saves the choice and installs that build.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

REPO="moonlight-stream/moonlight-qt"
APP="/Applications/Moonlight.app"
CHANNELS=(release nightly)
STATE="$HOME/Library/Application Support/ops-loadout"
CHANNEL_FILE="$STATE/moonlight.channel"
# "<channel> <tag|sha>" of the installed build: nightlies all report the same
# CFBundleShortVersionString. Kept outside the bundle to leave its seal intact.
STAMP="$STATE/moonlight.build"
# Left behind by the old nightly-only installer, removed on install.
LEGACY=("/Applications/Moonlight Nightly.app" "$STATE/moonlight-nightly.sha")

current_channel() {
    local c
    c="$(cat "$CHANNEL_FILE" 2>/dev/null || true)"
    echo "${c:-release}"
}

do_status() {
    [[ -d "$APP" ]] || return 1
    printf '%s\n' "$APP"
}

do_channels() {
    local c current
    current="$(current_channel)"
    for c in "${CHANNELS[@]}"; do
        [[ "$c" == "$current" ]] && echo "* $c" || echo "  $c"
    done
}

# Sets BUILD (tag or sha) and either URL (release dmg) or RUN (nightly run id).
resolve() {
    case "$1" in
        release)
            read -r BUILD URL < <(curl -fsS "https://api.github.com/repos/$REPO/releases/latest" \
                | jq -r '"\(.tag_name) \(.assets[] | select(.name | endswith(".dmg")) | .browser_download_url)"')
            ;;
        nightly)
            command -v gh >/dev/null || { echo "gh is required: brew install gh && gh auth login" >&2; return 1; }
            read -r RUN BUILD < <(gh api "repos/$REPO/actions/workflows/build.yml/runs?branch=master&status=success&per_page=1" \
                --jq '.workflow_runs[0] | "\(.id) \(.head_sha)"')
            ;;
    esac
    [[ -n "${BUILD:-}" ]] || { echo "No $1 build found" >&2; return 1; }
}

MOUNT=""
TMP=""
cleanup() {
    dmg_detach "$MOUNT"
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" channel dmg installed
    channel="$(current_channel)"

    echo "==> Resolving latest Moonlight $channel build"
    resolve "$channel" || return 1
    echo "    latest: ${BUILD:0:12}"

    if [[ -d "$APP" ]]; then
        installed="$(cat "$STAMP" 2>/dev/null || echo '?')"
        echo "    installed: $installed"
        if [[ "$action" != "reinstall" && "$installed" == "$channel $BUILD" ]]; then
            echo "Moonlight ${BUILD:0:12} is already the latest $channel build."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    if [[ "$channel" == nightly ]]; then
        echo "==> Downloading macOS artifact"
        gh run download "$RUN" -R "$REPO" -p 'Moonlight-macOS-*' -D "$TMP"
        dmg="$(find "$TMP" -name '*.dmg' | head -1)"
        [[ -n "$dmg" ]] || { echo "No dmg in the macOS artifact" >&2; return 1; }
    else
        dmg="$TMP/Moonlight.dmg"
        dl "$URL" "$dmg"
    fi

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$dmg")"
    [[ -d "$MOUNT/Moonlight.app" ]] || {
        echo "No Moonlight.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    pkill -x Moonlight || true
    rm -rf "$APP" "${LEGACY[@]}"
    ditto "$MOUNT/Moonlight.app" "$APP"
    # Nightlies carry no Developer ID, so drop the quarantine flag ourselves.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    mkdir -p "$STATE"
    printf '%s %s\n' "$channel" "$BUILD" > "$STAMP"

    echo "Moonlight $channel ${BUILD:0:12} installed."
}

do_set_channel() {
    [[ " ${CHANNELS[*]} " == *" ${1:-} "* ]] || { echo "unknown channel: ${1:-} (${CHANNELS[*]})" >&2; return 2; }
    mkdir -p "$STATE"
    printf '%s\n' "$1" > "$CHANNEL_FILE"
    echo "Moonlight channel: $1"
    do_install update
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Moonlight is not installed."; return 1; }
    pkill -x Moonlight || true
    rm -rf "$APP" "$STAMP"
    echo "Removed $APP"
}

case "${1:-status}" in
    status)                    do_status ;;
    channels)                  do_channels ;;
    channel)                   do_set_channel "${2:-}" ;;
    install|update|reinstall)  do_install "$1" ;;
    uninstall)                 do_uninstall ;;
    *)
        echo "usage: $(basename "$0") <status|install|update|reinstall|uninstall|channels|channel <name>>" >&2
        exit 2
        ;;
esac
