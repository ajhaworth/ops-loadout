#!/usr/bin/env bash
# ComfyUI Desktop installer: status | install | update | reinstall | uninstall
# Copies "Comfy Desktop.app" out of the latest dmg into /Applications.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

NAME="Comfy Desktop"
APP="/Applications/Comfy Desktop.app"
QUIT_FIRST=1

# The endpoint redirects to a fixed per-arch URL; the version is only in the
# Content-Disposition filename ("Comfy Desktop 1.1.3 - arm64.dmg").
resolve_latest() {
    local arch=arm64
    [[ "$(uname -m)" == "arm64" ]] || arch=x64
    URL="https://download.comfy.org/mac/dmg/$arch"
    VERSION="$(curl -fsSIL "${CURL_STALL[@]}" "$URL" | tr -d '\r' \
        | sed -n 's/^content-disposition:.*Comfy Desktop \([0-9][0-9.]*\) - .*/\1/Ip' | tail -1)"
    [[ -n "$VERSION" ]] || { echo "Could not read a version from $URL" >&2; return 1; }
}

dmg_app_main "$@"
