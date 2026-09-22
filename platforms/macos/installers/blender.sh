#!/usr/bin/env bash
# Blender installer: status | install | update | reinstall | uninstall
# Installs the latest release into /Applications and points its portable config dir at config/dcc/blender/portable.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Finder launches do not read shell profiles. Claude's native installer and uv's
# standalone installer use ~/.local/bin; Homebrew uses the other two directories.
export PATH="${HOME:?}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="/Applications/Blender.app"
CFG="$REPO/config/dcc/blender"
PORTABLE="$APP/Contents/Resources/portable"
BASE=https://ftp.nluug.nl/pub/graphics/blender/release   # download.blender.org sits behind a Cloudflare JS challenge and mirrors.dotsrc.org started 403ing listings (Sep 2026); official mirror

get() { curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 "$@"; }

# Ours only when the portable dir is our symlink: a cask Blender reads as not installed.
do_status() {
    [[ -d "$APP" ]] || return 1
    [[ "$(readlink "$PORTABLE" 2>/dev/null)" == "$CFG/portable" ]] || return 1
    printf '%s\n' "$APP"
}

TMP=""
MOUNT=""
STAGE=""
cleanup() {
    dmg_detach "$MOUNT"
    [[ -n "$TMP" ]] && rm -rf "$TMP"
    if [[ -n "$STAGE" ]]; then
        if [[ -e "$STAGE/previous.app" && ! -e "$APP" ]]; then
            mv "$STAGE/previous.app" "$APP" || echo "previous Blender preserved at $STAGE/previous.app" >&2
        fi
        [[ -e "$STAGE/previous.app" ]] || rm -rf "$STAGE"
    fi
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

    current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | grep -oE '^[0-9.]+' || true)"
    [[ -x "$APP/Contents/MacOS/Blender" ]] || current=""
    [[ -n "$current" ]] && echo "    installed: $current"

    echo "==> Resolving latest Blender release"
    arch=$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)
    version=""; series=""; dmg=""
    # A failed check must not block configuration of a working installation.
    # Keep latest unknown on failure instead of claiming the current build is latest.
    if series=$(get --max-time 35 "$BASE/" | grep -oE 'Blender[0-9]+\.[0-9]+/' | sort -uV | tail -1) &&
       [[ -n "$series" ]] &&
       dmg=$(get --max-time 35 "$BASE/$series" | grep -oE "blender-[0-9.]+-macos-$arch\.dmg" | sort -uV | tail -1) &&
       [[ -n "$dmg" ]]; then
        version="${dmg#blender-}"; version="${version%-macos-$arch.dmg}"
        echo "    latest: $version"
    elif [[ -n "$current" && "$action" != reinstall ]]; then
        echo "Warning: could not check for a newer Blender; keeping $current and reapplying configuration." >&2
    else
        echo "could not resolve Blender release; cannot download Blender" >&2
        return 1
    fi

    TMP="$(mktemp -d)"
    trap cleanup EXIT

    if [[ "$action" == reinstall || -z "$current" ]] ||
       { [[ -n "$version" && "$version" != "$current" ]] &&
         [[ "$(printf '%s\n' "$current" "$version" | sort -V | tail -1)" == "$version" ]]; }; then
        echo "==> Downloading $dmg"
        dl "$BASE/$series$dmg" "$TMP/b.dmg"
        echo "==> Mounting $dmg"
        MOUNT=$(dmg_attach "$TMP/b.dmg")
        [[ -n "$MOUNT" && -x "$MOUNT/Blender.app/Contents/MacOS/Blender" ]] || {
            echo "downloaded image does not contain Blender.app" >&2; return 1;
        }
        echo "==> Installing into $APP"
        # Copy on the destination volume before moving the working installation.
        STAGE=$(mktemp -d "/Applications/.blender-install.XXXXXX")
        ditto "$MOUNT/Blender.app" "$STAGE/Blender.app"
        [[ -x "$STAGE/Blender.app/Contents/MacOS/Blender" ]] || return 1
        if [[ -e "$APP" ]]; then mv "$APP" "$STAGE/previous.app"; fi
        if ! mv "$STAGE/Blender.app" "$APP"; then
            if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$APP"; fi
            return 1
        fi
        rm -rf "$STAGE"; STAGE=""
        dmg_detach "$MOUNT"; MOUNT=""
        rm -f "$TMP/b.dmg"
        current="$version"
    else
        echo "Keeping Blender $current; no application download needed."
    fi

    # Config dir -> repo. Before the extensions, so they land in the repo's portable/extensions/.
    ln -sfn "$CFG/portable" "$PORTABLE"
    # Unbuffered so the launcher sees lines as they happen; drop the per-chunk
    # PROGRESS spam and keep the STATUS lines (awk, not grep -v: an all-PROGRESS
    # run must not read as a failure under pipefail).
    b() { PYTHONUNBUFFERED=1 "$APP/Contents/MacOS/Blender" --online-mode "$@" 2>&1 | awk '!/^PROGRESS/ { print; fflush() }'; }

    echo "==> Linking custom scripts and keymaps"
    local failures=0 kind ref id api url tmp zip
    local addons=()
    install_extension() {
        case "$kind" in
            blender_org)
                addons+=("bl_ext.blender_org.$ref")
                if [[ -f "$CFG/portable/extensions/blender_org/$ref/blender_manifest.toml" ]]; then
                    echo "$ref already installed; will re-enable during setup"
                else
                    b --command extension install "$ref" --sync --enable || return 1
                fi ;;
            github|forgejo)
                # An optional manifest id avoids re-downloading an installed plugin
                # just to discover its id (which need not match its repository name).
                if [[ -n "$id" && -f "$CFG/portable/extensions/user_default/$id/blender_manifest.toml" ]]; then
                    addons+=("bl_ext.user_default.$id")
                    echo "$ref already installed ($id); will re-enable during setup"
                    return 0
                fi
                api=$([ "$kind" = github ] && echo "https://api.github.com/repos/$ref" || echo "https://${ref%%/*}/api/v1/repos/${ref#*/}")
                url=$(get "$api/releases/latest" | grep -oE '"browser_download_url": *"[^"]+\.zip"' | head -1 | cut -d'"' -f4 || true)
                tmp=$(mktemp -d "$TMP/extension.XXXXXX") || return 1
                zip=$tmp/$(basename "$ref").zip
                get -o "$zip" "${url:-$api/zipball}" || return 1
                if [[ -z "$url" ]]; then
                    (cd "$tmp" && unzip -q "$zip" && rm "$zip" && mv "$(ls -d */)" "$(basename "$ref")" && zip -qr "$zip" "$(basename "$ref")") || return 1
                fi
                id=$({ unzip -p "$zip" blender_manifest.toml '*/blender_manifest.toml' 2>/dev/null || true; } | sed -n 's/^id *= *"\(.*\)".*/\1/p' | head -1)
                if [[ -n "$id" ]]; then addons+=("bl_ext.user_default.$id"); fi
                if [[ -n "$id" && -f "$CFG/portable/extensions/user_default/$id/blender_manifest.toml" ]]; then
                    echo "$ref already installed ($id); will re-enable during setup"
                else
                    b --command extension install-file -r user_default --enable "$zip" || return 1
                fi
                rm -rf "$tmp" ;;
            *) echo "unknown extension kind: $kind" >&2; return 1 ;;
        esac
    }

    echo "==> Checking extensions"
    while read -r kind ref id || [[ -n "$kind" ]]; do
        [[ -n "$kind" && "$kind" != \#* ]] || continue
        if ! install_extension; then
            echo "Failed to set up extension: $ref; continuing with custom configuration" >&2
            failures=$((failures + 1))
        fi
    done < "$CFG/extensions.txt"

    echo "==> Reapplying custom preferences, keymap, plugins and startup layout"
    # setup.py needs a real window to activate the keymap and visit workspaces.
    # It saves the managed configuration and exits automatically.
    if ! OPS_BLENDER_ADDONS="${addons[*]-}" b --python-exit-code 1 --python "$CFG/setup.py"; then
        echo "Blender custom configuration failed" >&2
        failures=$((failures + 1))
    fi

    # Blender Lab MCP server for Claude Code (add-on comes from extensions.txt). Not vendored: uvx runs it
    # straight from upstream git, and --refresh-package re-pulls main on every launch so it's always latest.
    local claude_bin uvx_bin missing=""
    claude_bin=$(command -v claude || true)
    uvx_bin=$(command -v uvx || true)
    [[ -n "$claude_bin" ]] || missing="claude"
    [[ -n "$uvx_bin" ]] || missing="${missing:+$missing + }uvx"
    if [[ -z "$missing" ]]; then
        echo "==> Registering Blender MCP with Claude Code"
        "$claude_bin" mcp remove -s user blender >/dev/null 2>&1 || true
        if ! "$claude_bin" mcp add -s user blender -- "$uvx_bin" --refresh-package blender-mcp \
            --from 'git+https://projects.blender.org/lab/blender_mcp.git#subdirectory=mcp' blender-mcp; then
            echo "Blender MCP registration failed" >&2
            failures=$((failures + 1))
        fi
    else echo "skip MCP registration: $missing not found (checked ~/.local/bin, Homebrew and PATH)"; fi

    if (( failures > 0 )); then
        echo "Blender $current retained, but $failures setup step(s) failed; see errors above." >&2
        return 1
    fi
    echo "done: Blender $current configured"
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
