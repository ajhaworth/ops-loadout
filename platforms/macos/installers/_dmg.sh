#!/usr/bin/env bash
# Shared by the installer scripts: mount a dmg read-only and unmount it again.
# hdiutil is deprecated as of macOS 27; `diskutil image` replaces it, so prefer
# that and fall back on older systems. Not an installer token (leading `_`).

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
