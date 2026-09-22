#!/usr/bin/env bash
# Shared by the installer scripts: download with progress, mount a dmg
# read-only and unmount it again. Not an installer token (leading `_`).
#
# Loadout reads newline-delimited output, not terminal progress bars.
# Emit at most one line per 10% milestone, without a buffering text filter.
# Usage: dl <url> <out-file>
dl() (
    set -o pipefail
    local line percent milestone last=-1 next_bytes=$((SECONDS + 2)) bytes
    echo "  downloading $(basename "$2")"
    curl -fL -# --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$2" "$1" 2>&1 \
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
