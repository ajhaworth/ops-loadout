#!/usr/bin/env bash
# Houdini installer: status | install | update | reinstall | uninstall
# Uses the SideFX Web API to resolve the latest production daily build.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
CREDS="${SIDEFX_CREDENTIALS:-$REPO/config/sidefx.local}"
HOUDINI_DIR="/Applications/Houdini"
API="https://www.sidefx.com/api/"
TOKEN_URL="https://www.sidefx.com/oauth2/application_token"

case "$(uname -m)" in
    arm64) PLATFORM="macosx_arm64" ;;
    *)     PLATFORM="macos" ;;
esac

# --- installed state (network-free) ----------------------------------------

installed_dir() {
    local d
    d="$(printf '%s\n' "$HOUDINI_DIR"/Houdini[0-9]* | sort -V | tail -1)"
    [[ -d "$d" ]] || return 1
    printf '%s\n' "$d"
}

installed_app() {
    local a
    for a in "$1"/"Houdini Apprentice"*.app "$1"/"Houdini FX"*.app; do
        if [[ -d "$a" ]]; then
            printf '%s\n' "$a"
            return 0
        fi
    done
    return 1
}

do_status() {
    local dir app
    dir="$(installed_dir)" || return 1
    app="$(installed_app "$dir")" || return 1
    printf '%s\n' "$app"
}

# --- SideFX API ------------------------------------------------------------

load_credentials() {
    if [[ -f "$CREDS" ]]; then
        # shellcheck disable=SC1090
        source "$CREDS"
    fi

    if [[ -z "${SIDEFX_CLIENT_ID:-}" || -z "${SIDEFX_CLIENT_SECRET:-}" ]]; then
        cat <<MSG
SideFX API credentials are missing ($CREDS).

  1. Go to https://www.sidefx.com/services/ -> Developers API ->
     "Manage applications authentication" -> "Register a new application".
     Client type: confidential. Grant: authorization code.
     Redirect URL: https://www.sidefx.com
  2. Write config/sidefx.local with:
         SIDEFX_CLIENT_ID="..."
         SIDEFX_CLIENT_SECRET="..."
MSG
        return 1
    fi
}

api_call() {
    curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" \
        --data-urlencode "json=$1" "$API"
}

get_token() {
    ACCESS_TOKEN="$(curl -fsS -u "$SIDEFX_CLIENT_ID:$SIDEFX_CLIENT_SECRET" \
        -X POST "$TOKEN_URL" | jq -r '.access_token')"
    [[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || {
        echo "Could not get a SideFX access token - check the credentials in $CREDS." >&2
        return 1
    }
}

# --- install ---------------------------------------------------------------

MOUNT=""
TMP=""

cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1"
    local dir current latest version build url filename hash size gb dmg

    load_credentials

    echo "==> Resolving latest production build"
    get_token
    latest="$(api_call '["download.get_daily_builds_list", ["houdini"], {"platform":"'"$PLATFORM"'","only_production":true}]' \
        | jq -r '[.[] | select(.status == "good")]
                 | max_by((.version | split(".") | map(tonumber)) + [(.build | tonumber)])
                 | "\(.version) \(.build)"')"
    [[ -n "$latest" && "$latest" != "null null" ]] || {
        echo "No good production build found for $PLATFORM." >&2
        return 1
    }
    read -r version build <<<"$latest"
    echo "    latest: $version.$build ($PLATFORM)"

    if dir="$(installed_dir)"; then
        current="${dir##*/Houdini}"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$version.$build" ]]; then
            echo "Houdini $current is already the latest production build."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    local info
    info="$(api_call '["download.get_daily_build_download", ["houdini", "'"$version"'", "'"$build"'", "'"$PLATFORM"'"], {}]')"
    url="$(jq -r '.download_url' <<<"$info")"
    filename="$(jq -r '.filename' <<<"$info")"
    hash="$(jq -r '.hash' <<<"$info")"
    size="$(jq -r '.size' <<<"$info")"
    gb="$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1073741824 }')"

    dmg="$TMP/$filename"
    echo "==> Downloading $filename ($gb GB)"
    curl -fsSL -o "$dmg" "$url"

    echo "==> Verifying checksum"
    local actual
    actual="$(md5 -q "$dmg")"
    if [[ "$actual" != "$hash" ]]; then
        echo "Checksum mismatch: expected $hash, got $actual" >&2
        return 1
    fi

    echo "==> Mounting $filename"
    MOUNT="$(hdiutil attach -nobrowse -noverify -readonly "$dmg" 2>/dev/null \
        | tail -1 | awk -F'\t' '{ print $NF }')"
    [[ -d "$MOUNT" ]] || {
        echo "Could not mount $dmg" >&2
        return 1
    }

    if [[ ! -f "$MOUNT/Houdini.pkg" ]]; then
        echo "No Houdini.pkg on the mounted image. Contents:" >&2
        ls -1 "$MOUNT" >&2
        return 1
    fi

    echo "==> Installing (password prompt)"
    sudo -A installer -pkg "$MOUNT/Houdini.pkg" -target /

    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    MOUNT=""

    echo "Houdini $version.$build installed. Licensing: open \"Houdini Apprentice\", then in License Administrator choose \"Activate Apprentice\" (SideFX login optional; renews every 30 days)."
}

# ponytail: older Houdini versions are left in place on update; delete them by hand.

do_uninstall() {
    local dir version
    if ! dir="$(installed_dir)"; then
        echo "Houdini is not installed."
        return 1
    fi
    version="${dir##*/Houdini}"

    echo "==> Removing Houdini $version (password prompt)"
    sudo -A rm -rf "$HOUDINI_DIR/Houdini$version" "/Library/Frameworks/Houdini.framework/Versions/$version"
    echo "Removed $HOUDINI_DIR/Houdini$version"
    echo "Removed /Library/Frameworks/Houdini.framework/Versions/$version"
    echo "Left ~/Library/Preferences/houdini alone."
}

case "${1:-status}" in
    status)                    do_status ;;
    install|update|reinstall)  do_install "${1:-install}" ;;
    uninstall)                 do_uninstall ;;
    *)
        echo "usage: $(basename "$0") <status|install|update|reinstall|uninstall>" >&2
        exit 2
        ;;
esac
