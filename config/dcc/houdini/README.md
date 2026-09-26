# Houdini config

`platforms/macos/installers/houdini.sh` puts this directory on `HOUDINI_PATH`
by writing `~/Library/Preferences/houdini/<X.Y>/packages/loadout.json`, so
`desktop/` and `otls/` auto-load on next launch. Drop new HDAs straight into
`otls/`.

The HDAs are the Immersive Optimization Toolkit, re-hosted from the WWDC25
session "Optimize your 3D assets for spatial computing"
(https://developer.apple.com/videos/play/wwdc2025/305/). Built on Houdini 20.5
with a Production license — Apprentice converts them to non-commercial on
load. They appear under the tab-menu category "Optimize". A sample scene is in
`examples/`.

**Caveat:** Houdini's "Save Current Desktop" writes to the user prefs
`desktop/`, not here — it shadows this copy. Copy the file back into this repo
to keep a desktop change.

`nodethemes.json` selects Houdini's stock "Rounded Wire Style Theme", so new
networks get rounded wires; existing `.hip` files keep the style they were
saved with. Changing a theme in Houdini writes `nodethemes.json` to the user
prefs dir, which shadows this one.

`MainMenuCommon.xml` adds Edit > Toggle Auto Update / Manual, and
`python3.13libs/uiready.py` binds it to Ctrl+U (the Control key, not Cmd). A
Houdini built on another Python needs that folder under its own
`pythonX.Ylibs` name.
