#!/usr/bin/env bash
# SideFX Labs installer: status | install | update | reinstall | uninstall
# Installs the Houdini-version-matched release as a Houdini package.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASES="https://api.github.com/repos/sideeffects/SideFXLabs/releases?per_page=100"
ZIPBALL="https://api.github.com/repos/sideeffects/SideFXLabs/zipball"

require_houdini() {
    local app
    if ! app="$("$HERE/houdini.sh" status)"; then
        echo "Install Houdini first."
        return 1
    fi

    local full
    full="$(sed -n 's|.*/Houdini\([0-9][0-9.]*\)/.*|\1|p' <<<"$app")"
    if [[ -z "$full" ]]; then
        echo "Could not read the Houdini version from: $app"
        return 1
    fi

    XY="${full%.*}"
    PKG="$HOME/Library/Preferences/houdini/$XY/packages"
    DIR="$PKG/SideFXLabs$XY"
    JSON="$PKG/SideFXLabs$XY.json"
    TAGFILE="$DIR/.ops-tag"
}

do_status() {
    require_houdini >/dev/null || return 1
    [[ -d "$DIR" && -f "$JSON" ]] || return 1
    printf '%s\n' "$DIR"
}

latest_tag() {
    local tag
    tag="$(curl -fsS "$RELEASES" | jq -r --arg xy "$XY." '
        [ .[].tag_name
          | select(startswith($xy))
          | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) ]
        | max_by(split(".")[2] | tonumber) // empty')"
    if [[ -z "$tag" ]]; then
        echo "No SideFX Labs release for Houdini $XY yet" >&2
        return 1
    fi
    printf '%s\n' "$tag"
}

TMP=""
cleanup() {
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" tag current src

    require_houdini

    echo "==> Resolving latest SideFX Labs release for Houdini $XY"
    tag="$(latest_tag)"
    echo "    latest: $tag"

    if [[ -f "$TAGFILE" ]]; then
        current="$(cat "$TAGFILE")"
        echo "    installed: $current"
        if [[ "$action" != "reinstall" && "$current" == "$tag" ]]; then
            echo "SideFX Labs $current is already the latest release."
            return 0
        fi
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    echo "==> Downloading SideFXLabs $tag"
    curl -fsSL -o "$TMP/labs.zip" "$ZIPBALL/$tag"

    echo "==> Extracting"
    unzip -q "$TMP/labs.zip" -d "$TMP"
    # The zipball holds a single top-level sideeffects-SideFXLabs-<sha> directory.
    src="$(printf '%s\n' "$TMP"/sideeffects-SideFXLabs-* | head -1)"
    [[ -d "$src" ]] || {
        echo "Unexpected zipball layout under $TMP" >&2
        return 1
    }

    echo "==> Installing into $DIR"
    mkdir -p "$PKG"
    rm -rf "$DIR"
    mv "$src" "$DIR"

    jq --arg p "\$HOUDINI_PACKAGE_PATH/SideFXLabs$XY" \
        '.env = [{"SIDEFXLABS": $p}]' "$DIR/SideFXLabs.json" > "$JSON.tmp" && mv "$JSON.tmp" "$JSON"

    printf '%s\n' "$tag" > "$TAGFILE"

    echo "SideFX Labs $tag installed for Houdini $XY. Restart Houdini to load it."
}

do_uninstall() {
    require_houdini

    if [[ ! -d "$DIR" && ! -f "$JSON" ]]; then
        echo "SideFX Labs is not installed for Houdini $XY."
        return 1
    fi

    rm -rf "$DIR" "$JSON"
    echo "Removed $DIR"
    echo "Removed $JSON"
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
