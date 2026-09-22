#!/usr/bin/env bash
# Shared by the installer scripts: download with progress, mount a dmg
# read-only and unmount it again. Not an installer token (leading `_`).
#
# The launcher streams each output line to its log drawer, so progress has to
# arrive as whole lines: curl's \r-driven bar is turned into one line per 10%.

# Usage: dl <url> <out-file>
dl() {
    echo "  downloading $(basename "$2")"
    curl -fL -# -o "$2" "$1" 2>&1 | tr '\r' '\n' \
        | awk '/^[#= ]*$/ { next }              # the bar itself, before any percentage
               !/%/ { print; fflush(); next }   # curl errors have no % in them
               { p = int($NF); if (p >= next_) { printf "  %d%%\n", p; fflush(); next_ += 10 } }'
}

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
