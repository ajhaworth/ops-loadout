# AeroSpace

**AeroSpace = one workspace per app.** `config/dotfiles/aerospace/aerospace.toml`
(-> `~/.aerospace.toml`, `DOTFILES_AEROSPACE`) gives each everyday app its own
AeroSpace workspace, named after it, where its windows tile to fill the screen
like a full-screen Space: Blender, Houdini, Godot and Unreal (main window only,
by title ` - Blender <digit>` / ` - Houdini <edition> <digit>` / `Godot Engine` /
` - Unreal Editor`; the Houdini and Unreal patterns are unverified), Ghostty, Zen, Mail, Messages, Calendar, Agenda, Digest, Pulse,
ChatGPT, Claude, Slack, Safari, Obsidian, Spotify, Fork, Simulator and
Loadout. Everything else floats, Finder included (AeroSpace sees each native tab as a window, so tiled tabs
leave holes). Each per-app move then runs `follow.sh` (-> `~/.config/aerospace/`), which focuses the new
window only once its app is frontmost (polling ~1 s for a launching app). Not following leaves a new window on a
hidden workspace while its app is frontmost, and clicking an already-frontmost app in the Dock does nothing; but
a plain `--focus-follows-window` also followed windows opened in the background (`open -g`, Xcode test hosts
sharing Agenda/Digest/Pulse's bundle ids), showing their workspace while macOS kept the current app frontmost -
that app then stayed hidden and clicking it did nothing until another app was clicked first. Closing a window does the mirror image: AeroSpace returns to that window's (now empty) workspace while macOS makes another app frontmost, so `on-focus-changed` moves focus off an empty workspace to the frontmost app's window (`lsappinfo front`). Opening or clicking an app switches to its
workspace because AeroSpace follows macOS focus. A matched app's normal windows tile, so a second one
(compose window) splits that workspace; its dialogs, panels and
picture-in-picture float there by AeroSpace's own heuristic, which is why the
plain per-app rules carry no `layout tiling` (it would override that). 8 px gaps all round, like
macOS's own tiling. Loadout's rule matches the title `Loadout` exactly: its tray
popup is titled "Loadout Tray" (never shown, it has no decorations) so it keeps
floating. A window with a max width (Loadout 550 px) would tile
against the left edge, so it floats on its workspace instead and
`center.js` (-> `~/.config/aerospace/`, run by `exec-and-forget`) centers it
at full height; Messages gets the same, narrowed to 760 px by `center.js`'s
width argument, and the iOS Simulator likewise (its width follows the device's aspect ratio). `exec-on-workspace-change` re-runs `center.js` whenever one of
those workspaces is shown, so a window dragged aside snaps back; that is also what centers a new one, once `follow.sh` shows its
workspace - moving a window on a hidden workspace does not stick, AeroSpace restores its old spot when the
workspace shows. Rules fire only for new windows; `reload-config` leaves open ones
where they are. AeroSpace parks other workspaces' windows in a screen corner, so
Mission Control groups windows by app (`expose-group-apps`, set by `dock.sh` and,
for profiles without defaults, `installers/aerospace.sh`), which also turn off
Stage Manager, macOS's edge-drag tiling (both fight AeroSpace) and separate Spaces per display (AeroSpace's
docs tie it to focus bugs; takes a logout) and turn on
Ctrl-Cmd-drag from anywhere in a window. A Ghostty window tiles on workspace "Ghostty" unless it opens
while workspace "Blender" is focused - that is the Claude window, keyed on
`%{workspace}` because Ghostty sets its title only after AeroSpace detects it.
The menu bar stays: on a notched display the strip beside the notch is
off-limits to normal windows (macOS clamps them to y=32) even with the menu bar
auto-hidden.
Key bindings sit behind Caps Lock - AeroSpace's sample Option chords steal
Blender keys. `capslock-f18.plist` (-> `~/Library/LaunchAgents/`) runs
`hidutil` at login to remap Caps Lock to F18 (no Karabiner; `hidutil` forgets
mappings on reboot), and F18 enters AeroSpace mode `window`, where one key
runs a command. F18 cannot be seen held, so Enter, F and R drop back to `main`
while arrows and Minus/Equal move on to mode `repeat`, which binds only those
(F and Enter reach the app again) for repeated presses until Caps Lock or Esc.
No mode shows on screen, so `on-focus-changed` drops back to `main` on any
focus change. Caps Lock, Enter moves the focused
window to the previous workspace, tiled (one-off side-by-side);
`exec-on-workspace-change` records that workspace in
`/tmp/aerospace-prev-workspace`, since `move-node-to-workspace` has no
"previous" target. F toggles floating, R flattens and rebalances a tangled
workspace, Left/Right swap tiles, Minus/Equal resize. The
launcher's `AERO_TILE` finds the new Claude window as the Ghostty window id
that was not there before, takes Blender out of macOS native full screen if
needed (AeroSpace cannot tile across Spaces, and only sees the current one),
then tiles, `move left`s and `resize width`s it to 1/4 of the screen.
`list-windows` filters need `--monitor all`: `--all` rejects them. Native
full screen was tried first and dropped: nothing public can script Split View.
AeroSpace is not notarized; `installers/aerospace.sh` curls the release zip
(no quarantine) and puts the CLI in `~/.local/bin`.
