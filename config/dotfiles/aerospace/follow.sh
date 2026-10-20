#!/bin/bash
# Follows a newly detected window (AEROSPACE_WINDOW_ID) to the workspace its aerospace.toml rule just moved it to, but
# only once its app is frontmost. An app that opens a window in the background (a launch with open -g, an Xcode test
# host, a notification) must not pull AeroSpace away: macOS keeps the current app frontmost, so AeroSpace would show the
# new workspace while the app you were in stays hidden, and clicking it changes nothing macOS reports. It stayed
# unreachable until another app was clicked first. A launching app can activate just after its window appears, hence
# the short wait.
PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid=$(lsappinfo info -only pid "$(lsappinfo front)" | sed -n 's/.*pid = \([0-9]*\).*/\1/p')
    if [ -n "$pid" ] && aerospace list-windows --monitor all --pid "$pid" --format %{window-id} | grep -qx "$AEROSPACE_WINDOW_ID"; then
        exec aerospace focus --window-id "$AEROSPACE_WINDOW_ID"
    fi
    sleep 0.1
done
