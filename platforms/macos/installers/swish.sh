#!/usr/bin/env bash
# Swish installer: status | install | update | reinstall | uninstall
# Copies Swish.app out of the latest GitHub release dmg (the cask's source) into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Swish"
APP="/Applications/Swish.app"
QUIT_FIRST=1
RELEASE_API="https://api.github.com/repos/chrenn/swish-dl/releases/latest"

resolve_latest() {
    local json
    json="$(curl -fsSL "$RELEASE_API")" || { echo "GitHub release lookup failed" >&2; return 1; }
    URL="$(grep -o '"browser_download_url": *"[^"]*/Swish\.dmg"' <<<"$json" | cut -d'"' -f4 | head -1 || true)"
    [[ -n "$URL" ]] || { echo "No Swish.dmg on the latest release" >&2; return 1; }
    VERSION="$(sed -n 's|.*/download/\([^/]*\)/Swish\.dmg$|\1|p' <<<"$URL")"
}

dmg_app_main "$@"
