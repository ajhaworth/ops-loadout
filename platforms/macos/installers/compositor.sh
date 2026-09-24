#!/usr/bin/env bash
# Compositor installer: status | install | update | reinstall | uninstall
# Copies Compositor.app out of the latest GitHub release dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Compositor"
APP="/Applications/Compositor.app"
LATEST="https://api.github.com/repos/robbietilton/Compositor/releases/latest"

resolve_latest() {
    read -r VERSION URL < <(curl -fsS "$LATEST" | jq -r '"\(.tag_name) \(.assets[] | select(.name | endswith(".dmg")) | .browser_download_url)"')
    [[ -n "${URL:-}" ]] || { echo "No dmg asset in the latest release" >&2; return 1; }
}

dmg_app_main "$@"
