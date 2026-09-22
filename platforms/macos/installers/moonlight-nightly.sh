#!/usr/bin/env bash
# Moonlight nightly installer: status | install | update | reinstall | uninstall
# Installs the newest successful master build of moonlight-qt from GitHub
# Actions as "Moonlight Nightly.app", beside the stable `moonlight` cask.
# Artifacts are only downloadable when logged in, so this needs `gh` (formula
# in software-dev.txt) with an active `gh auth login`.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

REPO="moonlight-stream/moonlight-qt"
APP="/Applications/Moonlight Nightly.app"
# Nightlies all report the same CFBundleShortVersionString, so the installed
# commit is stamped here instead. Kept outside the bundle to leave its
# signature seal intact.
STAMP="$HOME/Library/Application Support/ops-loadout/moonlight-nightly.sha"

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
    local action="$1" run sha current dmg

    command -v gh >/dev/null || { echo "gh is required: brew install gh && gh auth login" >&2; return 1; }

    echo "==> Resolving latest Moonlight master build"
    read -r run sha < <(gh api "repos/$REPO/actions/workflows/build.yml/runs?branch=master&status=success&per_page=1" \
        --jq '.workflow_runs[0] | "\(.id) \(.head_sha)"')
    [[ -n "${sha:-}" ]] || { echo "No successful master build found" >&2; return 1; }
    echo "    latest: ${sha:0:7} (run $run)"

    if [[ -d "$APP" ]]; then
        current="$(cat "$STAMP" 2>/dev/null || echo '?')"
        echo "    installed: ${current:0:7}"
        if [[ "$action" != "reinstall" && "$current" == "$sha" ]]; then
            echo "Moonlight Nightly ${sha:0:7} is already the latest build."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading macOS artifact"
    gh run download "$run" -R "$REPO" -p 'Moonlight-macOS-*' -D "$TMP"
    dmg="$(find "$TMP" -name '*.dmg' | head -1)"
    [[ -n "$dmg" ]] || { echo "No dmg in the macOS artifact" >&2; return 1; }

    echo "==> Mounting"
    MOUNT="$(dmg_attach "$dmg")"
    [[ -d "$MOUNT/Moonlight.app" ]] || {
        echo "No Moonlight.app on the mounted image. Contents:" >&2
        ls -1 "${MOUNT:-$TMP}" >&2
        return 1
    }

    echo "==> Installing into $APP"
    rm -rf "$APP"
    ditto "$MOUNT/Moonlight.app" "$APP"
    # Nightlies carry no Developer ID, so drop the quarantine flag ourselves.
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    mkdir -p "$(dirname "$STAMP")"
    printf '%s\n' "$sha" > "$STAMP"

    echo "Moonlight Nightly ${sha:0:7} installed."
}

do_uninstall() {
    [[ -d "$APP" ]] || { echo "Moonlight Nightly is not installed."; return 1; }
    rm -rf "$APP" "$STAMP"
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
