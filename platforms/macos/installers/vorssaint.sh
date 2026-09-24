#!/usr/bin/env bash
# Vorssaint installer: status | install | update | reinstall | uninstall
# Copies Vorssaint.app out of the latest GitHub release dmg (the cask's source) into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Vorssaint"
APP="/Applications/Vorssaint.app"
QUIT_FIRST=1
RELEASE_API="https://api.github.com/repos/vorssaint/vorssaint-utils/releases/latest"

resolve_latest() {
    local json
    json="$(curl -fsSL "$RELEASE_API")" || { echo "GitHub release lookup failed" >&2; return 1; }
    URL="$(grep -o '"browser_download_url": *"[^"]*/Vorssaint-[^/"]*\.dmg"' <<<"$json" | cut -d'"' -f4 | head -1 || true)"
    [[ -n "$URL" ]] || { echo "No Vorssaint dmg on the latest release" >&2; return 1; }
    VERSION="$(sed -n 's|.*/Vorssaint-\(.*\)\.dmg$|\1|p' <<<"$URL")"
}

dmg_app_main "$@"
