#!/usr/bin/env bash
# Blender installer: status | install | update | reinstall | uninstall
# Installs the latest release into /Applications and points its portable config dir at config/dcc/blender/portable.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_dmg.sh"

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="/Applications/Blender.app"
CFG="$REPO/config/dcc/blender"
PORTABLE="$APP/Contents/Resources/portable"
BASE=https://ftp.nluug.nl/pub/graphics/blender/release   # download.blender.org sits behind a Cloudflare JS challenge and mirrors.dotsrc.org started 403ing listings (Sep 2026); official mirror

get() { curl -fsSL "$@"; }

# Ours only when the portable dir is our symlink: a cask Blender reads as not installed.
do_status() {
    [[ -d "$APP" ]] || return 1
    [[ "$(readlink "$PORTABLE" 2>/dev/null)" == "$CFG/portable" ]] || return 1
    printf '%s\n' "$APP"
}

TMP=""
MOUNT=""
cleanup() {
    dmg_detach "$MOUNT"
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    return 0
}

do_install() {
    local action="$1" arch series dmg version current

    # Never rm -rf a Blender we did not install (cask, manual download). A portable symlink
    # is ours even when it points at another checkout (a worktree); install just relinks it.
    if [[ -d "$APP" && ! -L "$PORTABLE" ]]; then
        echo "another Blender is installed at $APP; remove it first (rm the symlink, or brew uninstall --cask blender)" >&2
        return 1
    fi

    echo "==> Resolving latest Blender release"
    arch=$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)
    series=$(get $BASE/ | grep -oE 'Blender[0-9]+\.[0-9]+/' | sort -uV | tail -1 || true)   # || true: an empty grep would kill set -e before the check below
    dmg=$(get "$BASE/$series" | grep -oE "blender-[0-9.]+-macos-$arch\.dmg" | sort -uV | tail -1 || true)
    [[ -n "$dmg" ]] || { echo "no dmg found in $series" >&2; return 1; }
    version="${dmg#blender-}"; version="${version%-macos-$arch.dmg}"
    echo "    latest: $version"

    current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | grep -oE '^[0-9.]+' || true)"   # numeric core only, so a suffix never forces a redownload
    [[ -n "$current" ]] && echo "    installed: $current"

    if [[ "$action" == "reinstall" || "$current" != "$version" ]]; then
        TMP="$(mktemp -d)"
        trap cleanup EXIT
        echo "==> Downloading $dmg"
        get -o "$TMP/b.dmg" "$BASE/$series$dmg"
        MOUNT=$(dmg_attach "$TMP/b.dmg")
        echo "==> Installing into $APP"
        rm -rf "$APP"                       # one statement per line so set -e aborts before the link is rewritten
        ditto "$MOUNT/Blender.app" "$APP"
        dmg_detach "$MOUNT"; MOUNT=""
        rm -rf "$TMP"; TMP=""
    else
        echo "Blender $current is already the latest release."
    fi

    # Config dir -> repo. Before the extensions, so they land in the repo's portable/extensions/.
    ln -sfn "$CFG/portable" "$PORTABLE"
    b() { "$APP/Contents/MacOS/Blender" --online-mode "$@"; }

    echo "==> Installing extensions"
    { grep -vE '^\s*(#|$)' "$CFG/extensions.txt" || true; } | while read -r kind ref; do
        case $kind in
            blender_org)
                # Blender reports an already-installed id as "Error: No installable packages marked".
                if [[ -d "$CFG/portable/extensions/blender_org/$ref" ]]; then echo "$ref already installed"; continue; fi
                b --command extension install "$ref" --sync --enable ;;
            github|forgejo)   # forgejo (e.g. projects.blender.org) serves the same releases API under /api/v1
                api=$([ "$kind" = github ] && echo "https://api.github.com/repos/$ref" || echo "https://${ref%%/*}/api/v1/repos/${ref#*/}")
                url=$(get "$api/releases/latest" | grep -oE '"browser_download_url": *"[^"]+\.zip"' | head -1 | cut -d'"' -f4 || true)
                tmp=$(mktemp -d); zip=$tmp/$(basename "$ref").zip
                get -o "$zip" "${url:-$api/zipball}"
                # zipballs unpack to owner-repo-sha/, not a valid module name; rename the top dir to the repo name
                [ -n "$url" ] || (cd "$tmp" && unzip -q "$zip" && rm "$zip" && mv "$(ls -d */)" "$(basename "$ref")" && zip -qr "$zip" "$(basename "$ref")")
                id=$(unzip -p "$zip" '*/blender_manifest.toml' 2>/dev/null | sed -n 's/^id *= *"\(.*\)".*/\1/p' | head -1)
                if [[ -n "$id" && -d "$CFG/portable/extensions/user_default/$id" ]]; then echo "$ref already installed ($id)"; continue; fi
                b --command extension install-file -r user_default --enable "$zip" ;;
            *) echo "unknown kind: $kind"; exit 1 ;;
        esac
    done

    # Blender Lab MCP server for Claude Code (add-on comes from extensions.txt). Not vendored: uvx runs it
    # straight from upstream git, and --refresh-package re-pulls main on every launch so it's always latest.
    if command -v claude >/dev/null && command -v uvx >/dev/null; then
        claude mcp remove -s user blender >/dev/null 2>&1 || true
        claude mcp add -s user blender -- uvx --refresh-package blender-mcp \
            --from 'git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp' blender-mcp
    else echo "skip MCP registration: need claude + uvx"; fi

    echo "done: Blender $version"
}

# Config stays in the repo; only the app bundle goes.
do_uninstall() {
    do_status >/dev/null || { echo "Blender was not installed by this tool." >&2; return 1; }
    rm -rf "$APP"
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
