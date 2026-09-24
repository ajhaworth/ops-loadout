#!/usr/bin/env bash
# Fork installer: status | install | update | reinstall | uninstall
# Copies Fork.app out of the latest Sparkle-appcast dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Fork"
APP="/Applications/Fork.app"
APPCAST="https://git-fork.com/update/feed.xml"

resolve_latest() {
    URL="$(curl -fsSL "$APPCAST" | grep -o 'url="[^"]*\.dmg"' | head -1 | cut -d'"' -f2 || true)"
    [[ -n "$URL" ]] || { echo "No dmg enclosure found in Fork's appcast" >&2; return 1; }
    VERSION="$(sed -n 's/.*Fork-\([0-9][0-9.]*\)\.dmg/\1/p' <<<"$URL")"
    [[ -n "$VERSION" ]] || { echo "Could not parse a version out of: $URL" >&2; return 1; }
}

dmg_app_main "$@"
