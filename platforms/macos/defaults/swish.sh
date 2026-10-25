#!/usr/bin/env bash
# macos/defaults/swish.sh - Swish snapping
#
# Native snapping makes Swish tile through macOS's own Window > Move & Resize,
# so a snapped window gets macOS's tiled-window margins (EnableTiledWindowMargins,
# dock.sh): the same 8 px gaps Loadout WM leaves (config/dotfiles/wm/rules.txt).
# Swish's own snapping leaves none.

apply_swish() {
    [[ -d /Applications/Swish.app ]] || return 0
    local changed_before="${TASK_CHANGED:-0}"

    defaults_set co.highlyopinionated.swish snappingNativeTiling bool true "Snap with macOS tiling (8 px margins)"

    # Swish reads its settings at launch; relaunch only if the row was written.
    if [[ "${TASK_MODE:-apply}" != "status" ]] && (( ${TASK_CHANGED:-0} > changed_before )) \
        && ! is_dry_run && pgrep -xq Swish; then
        osascript -e 'quit app "Swish"' >/dev/null 2>&1 || true
        local _
        for _ in {1..50}; do pgrep -xq Swish || break; sleep 0.2; done
        open -a Swish
        log_substep "Relaunched Swish"
    fi
}
