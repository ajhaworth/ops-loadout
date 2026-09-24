#!/usr/bin/env bash
# Shared by the installer scripts: download with progress, mount a dmg
# read-only and unmount it again. Not an installer token (leading `_`).
#
# Abort a stalled transfer rather than hang forever: 30s to connect, then
# killed if it drops below 1KB/s for a full minute.
CURL_STALL=(--connect-timeout 30 --speed-limit 1024 --speed-time 60)

# Loadout reads newline-delimited output, not terminal progress bars.
# Emit at most one line per 10% milestone, without a buffering text filter.
# Usage: dl <url> <out-file>
dl() (
    set -o pipefail
    local line percent milestone last=-1 next_bytes=$((SECONDS + 2)) bytes
    echo "  downloading $(basename "$2")"
    curl -fL -# "${CURL_STALL[@]}" -o "$2" "$1" 2>&1 \
        | while IFS= read -r -d $'\r' line || [[ -n "$line" ]]; do
            if [[ "$line" == *"curl:"* ]]; then
                printf '%s\n' "$line"
            elif [[ "$line" =~ ([0-9]+\.[0-9]+)% ]]; then
                percent="${BASH_REMATCH[1]}"
                milestone=$((10#${percent%.*} / 10 * 10))
                if (( milestone > last )); then
                    printf '  %d%%\n' "$milestone"
                    last=$milestone
                fi
            elif [[ -s "$2" && $last -lt 0 && $SECONDS -ge $next_bytes ]]; then
                # Chunked responses have no total: curl draws a moving bar instead.
                bytes=$(wc -c < "$2")
                printf '  %s bytes downloaded (total unknown)\n' "${bytes//[[:space:]]/}"
                next_bytes=$((SECONDS + 30))
            fi
        done || exit $?
    echo "  download complete"
)

# hdiutil is deprecated as of macOS 27; `diskutil image` replaces it, so prefer
# that and fall back on older systems.

# Usage: MOUNT=$(dmg_attach path.dmg)  -> prints the mount point
dmg_attach() {
    if diskutil image >/dev/null 2>&1; then   # exits non-zero where the verb is unknown
        diskutil image attach --nobrowse --readOnly "$1" | awk -F'\t' '/\/Volumes\//{print $NF}'
    else
        hdiutil attach -nobrowse -noverify -readonly "$1" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}'
    fi
}

# Usage: dmg_detach "$MOUNT"   (quiet, never fails)
dmg_detach() {
    [[ -n "${1:-}" ]] || return 0
    diskutil eject "$1" >/dev/null 2>&1 || hdiutil detach "$1" -quiet >/dev/null 2>&1 || true
}

# Shared body for the "copy $NAME.app out of a dmg into /Applications"
# installers (fork, ghostty, compositor, swish, vorssaint).
#
# The caller sets, before calling this:
#   NAME         - display name, and the app/dmg name inside the download
#   APP          - install path, e.g. /Applications/$NAME.app
#   QUIT_FIRST   - optional; "1" pkills $NAME before replacing/removing it
#   resolve_latest - function that sets globals URL and VERSION, or returns
#                    1 (after echoing its own error to stderr) on failure
#
# Usage: dmg_app_main "$@"
dmg_app_main() {
    do_status() {
        [[ -d "$APP" ]] || return 1
        printf '%s\n' "$APP"
    }

    MOUNT=""
    TMP=""
    cleanup() {
        dmg_detach "$MOUNT"
        [[ -n "$TMP" ]] && rm -rf "$TMP"
        return 0
    }

    do_install() {
        local action="$1" current

        echo "==> Resolving latest $NAME release"
        resolve_latest || return 1
        echo "    latest: $VERSION"

        if [[ -d "$APP" ]]; then
            current="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
            echo "    installed: $current"
            if [[ "$action" != "reinstall" && "$current" == "${VERSION#v}" ]]; then
                echo "$NAME $current is already the latest release."
                return 0
            fi
        fi

        TMP="$(mktemp -d)"
        trap cleanup EXIT

        echo "==> Downloading $URL"
        dl "$URL" "$TMP/$NAME.dmg"

        echo "==> Mounting"
        MOUNT="$(dmg_attach "$TMP/$NAME.dmg")"
        [[ -d "$MOUNT/$NAME.app" ]] || {
            echo "No $NAME.app on the mounted image. Contents:" >&2
            ls -1 "${MOUNT:-$TMP}" >&2
            return 1
        }

        echo "==> Installing into $APP"
        [[ "${QUIT_FIRST:-0}" == "1" ]] && pkill -x "$NAME" || true
        rm -rf "$APP"
        ditto "$MOUNT/$NAME.app" "$APP"

        echo "$NAME $VERSION installed."
    }

    do_uninstall() {
        [[ -d "$APP" ]] || { echo "$NAME is not installed."; return 1; }
        [[ "${QUIT_FIRST:-0}" == "1" ]] && pkill -x "$NAME" || true
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
}
