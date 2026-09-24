#!/usr/bin/env bash
# Houdini installer: status | versions | install | update | reinstall | uninstall | config
# Uses the SideFX Web API to resolve the latest production daily build, and
# also installs/updates SideFX Labs per Houdini X.Y (folded in from the old
# sidefxlabs.sh, since Labs is just another Houdini package tied to a build).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
CREDS="${SIDEFX_CREDENTIALS:-$REPO/config/sidefx.local}"
HOUDINI_DIR="${HOUDINI_DIR:-/Applications/Houdini}"
API="https://www.sidefx.com/api/"
TOKEN_URL="https://www.sidefx.com/oauth2/application_token"

# HOUDINI_LICENSE (apprentice|indie|server), HOUDINI_LICENSE_SERVER and
# HOUDINI_VERSION (a major.minor pin) live alongside the SideFX API
# credentials in the same file; every verb needs to see them, not just
# install, so source it once up front.
# shellcheck disable=SC1090
[[ -f "$CREDS" ]] && source "$CREDS"

case "$(uname -m)" in
    arm64) PLATFORM="macosx_arm64" ;;
    *)     PLATFORM="macos" ;;
esac

# --- installed state (network-free) ----------------------------------------

# Newest installed build dir, or the newest build matching the HOUDINI_VERSION
# major.minor pin when one is set.
installed_dir() {
    local d pin="${HOUDINI_VERSION:-}"
    if [[ -n "$pin" ]]; then
        d="$(printf '%s\n' "$HOUDINI_DIR"/Houdini"$pin".* | sort -V | tail -1)"
    else
        d="$(printf '%s\n' "$HOUDINI_DIR"/Houdini[0-9]* | sort -V | tail -1)"
    fi
    [[ -d "$d" ]] || return 1
    printf '%s\n' "$d"
}

# Falls back to Apprentice/FX in every mode so something launches even if
# the requested edition isn't installed.
installed_app() {
    local dir="$1" a
    case "${HOUDINI_LICENSE:-apprentice}" in
        indie)
            for a in "$dir"/"Houdini Indie"*.app "$dir"/"Houdini FX"*.app \
                     "$dir"/"Houdini Apprentice"*.app; do
                [[ -d "$a" ]] && { printf '%s\n' "$a"; return 0; }
            done
            ;;
        server)
            for a in "$dir"/"Houdini FX"*.app "$dir"/"Houdini Core"*.app \
                     "$dir"/"Houdini Apprentice"*.app; do
                [[ -d "$a" ]] && { printf '%s\n' "$a"; return 0; }
            done
            ;;
        *)
            for a in "$dir"/"Houdini Apprentice"*.app "$dir"/"Houdini FX"*.app; do
                [[ -d "$a" ]] && { printf '%s\n' "$a"; return 0; }
            done
            ;;
    esac
    return 1
}

do_status() {
    local dir app
    dir="$(installed_dir)" || return 1
    app="$(installed_app "$dir")" || return 1
    printf '%s\n' "$app"
    apply_config check >/dev/null 2>&1 || echo outdated
}

# One edition .app path per installed build, newest first. Loadout lists one
# Open row per build. Offline, like status.
do_versions() {
    local dir app found=1
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        app="$(installed_app "$dir")" || continue
        printf '%s\n' "$app"
        found=0
    done < <(printf '%s\n' "$HOUDINI_DIR"/Houdini[0-9]* | sort -Vr)
    return $found
}

# --- config: repo dir on HOUDINI_PATH, desktop set to ALX, SideFX Labs -----

# Applies loadout.json + desk pref + SideFX Labs for one Houdini X.Y.
# action="check": writes nothing, fails when anything doesn't match (also
# used by do_status's "outdated" line). Any other action performs the writes
# and installs/updates Labs for that X.Y, passing the action through.
apply_config_xy() {
    local action="$1" xy="$2"
    local prefs="$HOME/Library/Preferences/houdini/$xy"
    local pkgdir="$prefs/packages"
    local pref_file="$prefs/houdini.pref"
    local json desk
    json="$(printf '{"path": "%s"}' "$REPO/config/dcc/houdini")"
    desk='general.desk.val := "ALX";'

    if [[ "$action" == check ]]; then
        [[ "$(cat "$pkgdir/loadout.json" 2>/dev/null)" == "$json" ]] \
            && grep -qxF "$desk" "$pref_file" 2>/dev/null \
            && [[ -d "$pkgdir/SideFXLabs$xy" && -f "$pkgdir/SideFXLabs$xy.json" ]]
        return
    fi

    # The .pkg installer runs as root and creates this X.Y's prefs dir
    # root-owned; every later user write fails silently unless it's fixed
    # (do_install chowns it after installing, but a bare `config` run or an
    # install that ran before that fix needs the same message).
    if [[ -d "$prefs" && ! -w "$prefs" ]]; then
        echo "Houdini config: $prefs is not writable (root-owned by the .pkg installer)." >&2
        echo "    fix: sudo chown -R \$(id -un) ~/Library/Preferences/houdini" >&2
        return 1
    fi

    mkdir -p "$pkgdir" || { echo "Could not create $pkgdir" >&2; return 1; }
    printf '%s\n' "$json" > "$pkgdir/loadout.json" \
        || { echo "Could not write $pkgdir/loadout.json" >&2; return 1; }
    echo "==> Wrote $pkgdir/loadout.json (HOUDINI_PATH -> $REPO/config/dcc/houdini)"

    mkdir -p "$prefs" || { echo "Could not create $prefs" >&2; return 1; }
    if [[ -f "$pref_file" ]] && grep -q '^general\.desk\.val' "$pref_file"; then
        sed -i '' "s|^general\\.desk\\.val.*|$desk|" "$pref_file" \
            || { echo "Could not update $pref_file" >&2; return 1; }
    else
        printf '%s\n' "$desk" >> "$pref_file" \
            || { echo "Could not write $pref_file" >&2; return 1; }
    fi
    echo "==> Set general.desk.val := \"ALX\" in $pref_file for Houdini $xy"

    install_labs "$xy" "$action" \
        || echo "==> SideFX Labs step failed for Houdini $xy; continuing" >&2
}

# Applies config to every installed Houdini build's X.Y (deduped), then
# points hserver at the license server for the status build. `apply_config
# check` targets only the status build (installed_dir) and writes nothing.
apply_config() {
    local action="${1:-config}"

    if [[ "$action" == check ]]; then
        local dir xy
        dir="$(installed_dir)" || return 1
        installed_app "$dir" >/dev/null || return 1
        xy="${dir##*/Houdini}"; xy="${xy%.*}"
        apply_config_xy check "$xy"
        return
    fi

    local dir version xy seen=() found=0 failed=0
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        installed_app "$dir" >/dev/null 2>&1 || continue
        version="${dir##*/Houdini}"
        xy="${version%.*}"
        case " ${seen[*]-} " in *" $xy "*) continue ;; esac
        seen+=("$xy")
        found=1
        apply_config_xy "$action" "$xy" || failed=1
    done < <(printf '%s\n' "$HOUDINI_DIR"/Houdini[0-9]* | sort -V)

    apply_license || echo "Houdini license not applied; see above" >&2
    [[ $found -eq 1 && $failed -eq 0 ]]
}

# --- SideFX API ------------------------------------------------------------

load_credentials() {
    [[ -n "${SIDEFX_CLIENT_ID:-}" && -n "${SIDEFX_CLIENT_SECRET:-}" ]] && return 0

    cat <<'MSG'
SideFX API credentials are not set. In Loadout, open Settings (gear icon, top right) and follow the steps there.
(From a terminal: write config/sidefx.local with SIDEFX_CLIENT_ID="..." and SIDEFX_CLIENT_SECRET="...", from https://www.sidefx.com/oauth2/applications/)
MSG
    return 1
}

api_call() {
    curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" \
        --data-urlencode "json=$1" "$API"
}

get_token() {
    ACCESS_TOKEN="$(curl -fsS -u "$SIDEFX_CLIENT_ID:$SIDEFX_CLIENT_SECRET" \
        -X POST "$TOKEN_URL" | jq -r '.access_token')"
    [[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || {
        echo "Could not get a SideFX access token - check the Client ID and secret in Settings." >&2
        return 1
    }
}

# --- SideFX Labs (folded in from the old sidefxlabs.sh) --------------------

LABS_RELEASES="https://api.github.com/repos/sideeffects/SideFXLabs/releases?per_page=100"
LABS_ZIPBALL="https://api.github.com/repos/sideeffects/SideFXLabs/zipball"

labs_latest_tag() {
    local xy="$1" tag
    tag="$(curl -fsS "$LABS_RELEASES" | jq -r --arg xy "$xy." '
        [ .[].tag_name
          | select(startswith($xy))
          | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) ]
        | max_by(split(".")[2] | tonumber) // empty')"
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
}

# Installs/updates SideFX Labs for one Houdini X.Y. Never fails the run: a
# missing release for a new X.Y or a network error is a warning, since Labs
# failing must not sink the rest of `config`.
install_labs() {
    local xy="$1" action="$2"
    local pkgdir="$HOME/Library/Preferences/houdini/$xy/packages"
    local dir="$pkgdir/SideFXLabs$xy"
    local json="$pkgdir/SideFXLabs$xy.json"
    local tagfile="$dir/.ops-tag"
    local tag current src

    tag="$(labs_latest_tag "$xy")" || {
        echo "==> SideFX Labs: no release for Houdini $xy yet; skipping" >&2
        return 0
    }

    if [[ -f "$tagfile" ]]; then
        current="$(cat "$tagfile")"
        [[ "$action" != reinstall && "$current" == "$tag" ]] && return 0
    fi

    echo "==> Installing SideFX Labs $tag for Houdini $xy"
    LABS_TMP="$(mktemp -d)"
    if ! curl -fsSL -o "$LABS_TMP/labs.zip" "$LABS_ZIPBALL/$tag" \
        || ! unzip -q "$LABS_TMP/labs.zip" -d "$LABS_TMP"; then
        echo "    SideFX Labs $tag failed to download" >&2
        rm -rf "$LABS_TMP"; LABS_TMP=""
        return 1
    fi

    # The zipball holds a single top-level sideeffects-SideFXLabs-<sha> dir.
    src="$(printf '%s\n' "$LABS_TMP"/sideeffects-SideFXLabs-* | head -1)"
    if [[ ! -d "$src" ]]; then
        echo "    SideFX Labs $tag: unexpected zipball layout" >&2
        rm -rf "$LABS_TMP"; LABS_TMP=""
        return 1
    fi

    if ! mkdir -p "$pkgdir" || ! rm -rf "$dir" || ! mv "$src" "$dir"; then
        echo "    SideFX Labs $tag failed to install into $dir" >&2
        rm -rf "$LABS_TMP"; LABS_TMP=""
        return 1
    fi

    if ! jq --arg p "\$HOUDINI_PACKAGE_PATH/SideFXLabs$xy" \
            '.env = [{"SIDEFXLABS": $p}]' "$dir/SideFXLabs.json" > "$json.tmp" \
        || ! mv "$json.tmp" "$json"; then
        echo "    SideFX Labs $tag failed writing $json" >&2
        rm -rf "$LABS_TMP"; LABS_TMP=""
        return 1
    fi

    if ! printf '%s\n' "$tag" > "$tagfile"; then
        echo "    SideFX Labs $tag installed but could not record $tagfile" >&2
        rm -rf "$LABS_TMP"; LABS_TMP=""
        return 1
    fi

    rm -rf "$LABS_TMP"; LABS_TMP=""
    echo "    SideFX Labs $tag installed for Houdini $xy"
}

# --- license -----------------------------------------------------------

# ponytail: switching away from server mode does not clear hserver's server
# list; clear it by hand in License Administrator, or add an `hserver` clear
# call here once verified against a real install. License is deliberately
# not part of `apply_config check` - querying hserver can start the
# licensing daemon, and check must stay offline and side-effect-free.
apply_license() {
    local mode="${HOUDINI_LICENSE:-apprentice}" dir full xy hserver
    dir="$(installed_dir)" || return 0
    full="${dir##*/Houdini}"
    xy="${full%.*}"
    # hserver ships inside the versioned build, not under /Library/Frameworks.
    hserver="$dir/Frameworks/Houdini.framework/Versions/$xy/Resources/bin/hserver"
    [[ -x "$hserver" ]] || {
        echo "==> hserver not found for Houdini $full; skipping license step" >&2
        return 0
    }

    case "$mode" in
        server)
            if [[ -z "${HOUDINI_LICENSE_SERVER:-}" ]]; then
                echo "HOUDINI_LICENSE_SERVER is not set; cannot configure a license server." >&2
                return 1
            fi
            "$hserver" -S "$HOUDINI_LICENSE_SERVER"
            echo "License: server -> $HOUDINI_LICENSE_SERVER"
            ;;
        indie)
            echo "License: indie - activate/log in via License Administrator"
            ;;
        *)
            echo "License: apprentice - activate/log in via License Administrator"
            ;;
    esac
}

# --- install ---------------------------------------------------------------

MOUNT=""
TMP=""
LABS_TMP=""

cleanup() {
    dmg_detach "$MOUNT"
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    [[ -n "$LABS_TMP" ]] && rm -rf "$LABS_TMP"
    return 0
}
trap cleanup EXIT

do_install() {
    local action="$1"
    local dir current latest version build url filename hash size gb dmg

    load_credentials

    echo "==> Resolving latest production build${HOUDINI_VERSION:+ ($HOUDINI_VERSION)}"
    get_token
    latest="$(api_call '["download.get_daily_builds_list", ["houdini"], {"platform":"'"$PLATFORM"'","only_production":true}]' \
        | jq -r --arg pin "${HOUDINI_VERSION:-}" '[.[] | select(.status == "good") | select($pin == "" or .version == $pin)]
                 | max_by((.version | split(".") | map(tonumber)) + [(.build | tonumber)])
                 | "\(.version) \(.build)"')"
    if [[ -z "$latest" || "$latest" == "null null" ]]; then
        if [[ -n "${HOUDINI_VERSION:-}" ]]; then
            echo "No production build of Houdini $HOUDINI_VERSION for $PLATFORM." >&2
        else
            echo "No good production build found for $PLATFORM." >&2
        fi
        return 1
    fi
    read -r version build <<<"$latest"
    echo "    latest: $version.$build ($PLATFORM)"

    if dir="$(installed_dir)"; then
        current="${dir##*/Houdini}"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$version.$build" ]]; then
            echo "Houdini $current is already the latest production build."
            apply_config "$action" || echo "Houdini config not applied; see above" >&2
            return 0
        fi
    fi

    TMP="$(mktemp -d)"

    local info
    info="$(api_call '["download.get_daily_build_download", ["houdini", "'"$version"'", "'"$build"'", "'"$PLATFORM"'"], {}]')"
    url="$(jq -r '.download_url' <<<"$info")"
    filename="$(jq -r '.filename' <<<"$info")"
    hash="$(jq -r '.hash' <<<"$info")"
    size="$(jq -r '.size' <<<"$info")"
    gb="$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1073741824 }')"

    dmg="$TMP/$filename"
    echo "==> Downloading $filename ($gb GB)"
    dl "$url" "$dmg"

    echo "==> Verifying checksum"
    local actual
    actual="$(md5 -q "$dmg")"
    if [[ "$actual" != "$hash" ]]; then
        echo "Checksum mismatch: expected $hash, got $actual" >&2
        return 1
    fi

    echo "==> Mounting $filename"
    MOUNT="$(dmg_attach "$dmg")"
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

    # The .pkg runs as root and leaves this X.Y's prefs dir root-owned;
    # reclaim it now so apply_config's writes below don't fail silently.
    if [[ -d "$HOME/Library/Preferences/houdini" ]]; then
        sudo -A chown -R "$(id -un)" "$HOME/Library/Preferences/houdini"
    fi

    dmg_detach "$MOUNT"
    MOUNT=""

    echo "Houdini $version.$build installed."
    case "${HOUDINI_LICENSE:-apprentice}" in
        server)
            echo "Licensing: server mode - config will point hserver at HOUDINI_LICENSE_SERVER."
            ;;
        indie)
            echo "Licensing: open \"Houdini Indie\", then in License Administrator log in with your SideFX account (Indie license)."
            ;;
        *)
            echo "Licensing: open \"Houdini Apprentice\", then in License Administrator choose \"Activate Apprentice\" (SideFX login optional; renews every 30 days)."
            ;;
    esac
    apply_config "$action" || echo "Houdini config not applied; see above" >&2
    [[ -n "${SUDO_ASKPASS:-}" ]] && license_dialog "$(installed_app "$HOUDINI_DIR/Houdini$version.$build")"
    return 0
}

# Apprentice/Indie licensing cannot be scripted, so explain it and offer to
# open Houdini. Server mode has nothing to click through, so no dialog.
license_dialog() {
    local app="$1" mode="${HOUDINI_LICENSE:-apprentice}"
    [[ "$mode" == server ]] && return 0

    local msg
    if [[ "$mode" == indie ]]; then
        msg=$'Houdini is installed. It still needs an Indie license, which only Houdini itself can activate:\n\n1. Open Houdini Indie (button below).\n2. If it asks for a license, click Use License Administrator; otherwise open Utilities > License Administrator.\n3. Log in with your SideFX account (Indie license).'
    else
        msg=$'Houdini is installed. It still needs the free Apprentice license, which only Houdini itself can activate:\n\n1. Open Houdini Apprentice (button below).\n2. If it asks for a license, click Use License Administrator; otherwise open Utilities > License Administrator.\n3. In the top-right menu, or under General, click Activate Apprentice. Logging in to SideFX is optional.\n4. Repeat step 3 every 30 days when Houdini asks again.'
    fi

    osascript - "$app" "$msg" <<'EOF' >/dev/null 2>&1 || true
on run argv
set r to display dialog (item 2 of argv) with title "Loadout" buttons {"Later", "Open Houdini"} default button "Open Houdini"
if button returned of r is "Open Houdini" then do shell script "open -a " & quoted form of (item 1 of argv)
end run
EOF
}

# ponytail: older Houdini versions are left in place on update; delete them by hand.

do_uninstall() {
    local dir version xy other d loadout_json labs_dir labs_json
    if ! dir="$(installed_dir)"; then
        echo "Houdini is not installed."
        return 1
    fi
    version="${dir##*/Houdini}"
    xy="${version%.*}"

    # Only drop this X.Y's shared config/Labs when no other installed build
    # (e.g. a pinned older version) still shares it.
    other=0
    for d in "$HOUDINI_DIR"/Houdini"$xy".*; do
        [[ -d "$d" && "$d" != "$dir" ]] && other=1
    done

    if [[ "$other" -eq 0 ]]; then
        loadout_json="$HOME/Library/Preferences/houdini/$xy/packages/loadout.json"
        if [[ -f "$loadout_json" ]]; then
            rm -f "$loadout_json"
            echo "Removed $loadout_json"
        fi

        labs_dir="$HOME/Library/Preferences/houdini/$xy/packages/SideFXLabs$xy"
        labs_json="$HOME/Library/Preferences/houdini/$xy/packages/SideFXLabs$xy.json"
        if [[ -d "$labs_dir" || -f "$labs_json" ]]; then
            rm -rf "$labs_dir" "$labs_json"
            echo "Removed $labs_dir"
            echo "Removed $labs_json"
        fi
    fi

    # The Houdini framework lives inside this build dir (Frameworks/), not
    # under /Library/Frameworks, so removing the build dir is enough.
    echo "==> Removing Houdini $version (password prompt)"
    sudo -A rm -rf "$HOUDINI_DIR/Houdini$version"
    echo "Removed $HOUDINI_DIR/Houdini$version"
    echo "Left ~/Library/Preferences/houdini alone."
}

case "${1:-status}" in
    status)                    do_status ;;
    versions)                  do_versions ;;
    install|update|reinstall)  do_install "$1" ;;
    uninstall)                 do_uninstall ;;
    config|configure)          apply_config ;;
    *)
        echo "usage: $(basename "$0") <status|versions|install|update|reinstall|uninstall|config>" >&2
        exit 2
        ;;
esac
