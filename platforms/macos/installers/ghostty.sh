#!/usr/bin/env bash
# Ghostty installer: status | install | update | reinstall | uninstall
# Copies Ghostty.app out of the latest GitHub release dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Ghostty"
APP="/Applications/Ghostty.app"
# Ghostty has no "latest" GitHub release; macOS builds come from its Sparkle
# appcast, whose items are oldest-first, so pick the highest version.
APPCAST="https://release.files.ghostty.org/appcast.xml"

resolve_latest() {
    URL="$(curl -fsSL "$APPCAST" | grep -o 'url="[^"]*/Ghostty\.dmg"' | cut -d'"' -f2 | sort -V | tail -1 || true)"
    [[ -n "$URL" ]] || { echo "No Ghostty.dmg in the appcast" >&2; return 1; }
    VERSION="$(sed -n 's|.*/\([0-9][0-9.]*\)/Ghostty\.dmg$|\1|p' <<<"$URL")"
}

dmg_app_main "$@"
