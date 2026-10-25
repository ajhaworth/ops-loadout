# wm (Loadout WM)

This repo's own window manager, replacing AeroSpace (macOS) and GlazeWM (Windows). The normal windows of apps
listed in `config/dotfiles/wm/rules.txt` (-> `~/.loadout-wm.txt` on both platforms, `DOTFILES_WM`) fill their
screen, inset by a padding. Every other window is never touched, so it floats. **There are no virtual
workspaces.** An app is its own workspace, and you reach it by switching apps the normal way, which brings its
filled windows to the front. That is why none of AeroSpace's workarounds exist here: `follow.sh`, the
empty-workspace focus fix, parked windows, Mission Control grouping and GlazeWM's game-ignore list.

- **`src/main.rs`** is the platform-neutral part, unit-tested with `cargo test`:
  - The rules parser (`app | title contains | layout | padding`).
  - `plan`, which turns windows and screens into target frames. `fill` fills every window, `first` fills only
    the remembered first window, and `split` makes equal columns sorted by current x.
  - The rules file is re-read when its mtime changes, so edits apply on the next event.
- **"Normal window" is the OS's call, not a rule.** That's how dialogs, panels and sheets float:
  - macOS: `AXSubrole == AXStandardWindow`, not minimised or full screen.
  - Windows: visible, unowned, has `WS_CAPTION` and `WS_THICKFRAME`, not a tool window, not cloaked.
- **`src/macos.rs`** uses raw AX and CoreFoundation FFI, plus objc2 for NSWorkspace, NSScreen and NSApplication.
  - Each listed app gets an `AXObserver` for `AXWindowCreated`. Every laid-out window also gets
    `AXUIElementDestroyed`, so closing one rebalances `split` and hands `first` over.
  - NSWorkspace launch and quit events trigger a resync. Activating an app relays out its windows. A screen-parameters change relays out every app.
  - **Drag snap-back:** each laid-out window also gets `AXWindowMoved` and `AXWindowResized`. A move we didn't make
    (within 500 ms of our own `set_frame` counts as ours, which also covers an app clamping our size) polls every
    100 ms until the mouse is up (`CGEventSourceButtonState`), then relays out the app. `dragging` makes a drag's
    stream of notifications schedule only one poll.
  - Each layout runs twice, once at once and again 400 ms later (`dispatch_after_f`), because a new window often
    moves itself again right after it appears.
  - Frames are AX top-left points. `NSScreen.visibleFrame` is flipped against the primary screen's height.
  - A window is set to size, then position, then size again.
- **`src/windows.rs`** runs WinEvent hooks with a `GetMessage` loop:
  - Hooks: foreground, minimize-end, and destroy/show/hide (`EVENT_OBJECT_DESTROY..EVENT_OBJECT_HIDE`).
  - Every relevant event runs a full pass over `EnumWindows`, so the snap-back hits every listed window, not just
    the activated app as on macOS.
  - The process is per-monitor DPI aware, and the padding is scaled by monitor DPI / 96.
  - `SetWindowPos` widens the target by the `DWMWA_EXTENDED_FRAME_BOUNDS` border so the padding you see is
    exact.
  - A pass already running is skipped (`try_borrow_mut`): moving another process's window can re-enter the hook,
    and the delayed `SetTimer` pass catches up.
  - `EVENT_SYSTEM_MOVESIZEEND` (sent only for a user's drag or resize) gives the drag snap-back.
  - Display changes have no hook, so the next foreground event fixes them.

**Install.** `release.yml` builds `wm/` on both runners and attaches `loadout-wm-macos.zip` (`Loadout WM.app`,
ad-hoc signed, with the version inserted into `Info.plist`) and `loadout-wm-windows.zip` (`loadout-wm.exe` plus
`version.txt`) to every Loadout release, under fixed names. The installers fetch from
`releases/latest/download/`:
- `platforms/macos/installers/loadout-wm.sh` installs to `~/Applications` with a LaunchAgent that has
  `KeepAlive` on crash only. It logs to `~/Library/Logs/loadout-wm.log`.
- `lib/windows/loadout-wm.psm1` installs to `%LOCALAPPDATA%\Programs\LoadoutWM` and adds an HKCU Run value.

**Bump `version` in `wm/Cargo.toml` only when `wm/` changes**, and bump `WM_VERSION` in `loadout-wm.sh` and
`$script:WmVersion` in `loadout-wm.psm1` with it (`smoke.sh` checks that they match):
- The installers replace the app only when the version differs. A replaced binary is a new ad-hoc signature, and
  macOS then asks for Accessibility again. That is the reason the WM is not a thread inside Loadout, whose
  binary changes with every release.
- The installers refuse a downloaded build whose version isn't the expected one. That happens when the release
  with the new version hasn't finished building yet.

**Develop.** Run `cargo run` from `wm/`. The terminal running it needs Accessibility, and AeroSpace or GlazeWM
must be quit, or they fight over windows. To try it without touching your real apps, point `HOME` at a scratch
directory whose `.loadout-wm.txt` lists only TextEdit, then read the frames back with System Events. Type-check
Windows from a Mac with rustup's toolchain, since Homebrew's cargo has no Windows std:
`RUSTC=~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc ~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo check --target x86_64-pc-windows-msvc`.

**Not built yet:** Caps Lock bindings, centered narrow windows (Messages, Simulator, Loadout), split resizing and
a tray icon. AeroSpace and GlazeWM are still configured alongside it until the switch is made. Removing them also
means removing `AERO_TILE` from `dcc_claude.py`.
