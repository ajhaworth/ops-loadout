# blender

My Blender config, tracked in this repo.

Install it with the launcher's Blender tile, or:

```sh
platforms/macos/installers/blender.sh install
```

That downloads the latest Blender into `/Applications`, points its portable config dir at
this one, and installs everything in `extensions.txt`. Re-run it any time to upgrade.

Everything Blender saves lands in `portable/`, so it shows up in `git status`:

| In Blender | File |
| --- | --- |
| Preferences → Save Preferences | `portable/config/userpref.blend` |
| File → Defaults → Save Startup File | `portable/config/startup.blend` |
| Preferences → Keymap → "+" add preset | `portable/scripts/presets/keyconfig/<name>.py` |
| `bin/keymap-export` | `portable/scripts/presets/keyconfig/dcc.py` (user changes only, text diff) |
| Blender tile → Keymap in the launcher | opens `keymap.html`, a keyboard view of `dcc.py` (reads it live, nothing to regenerate) |

`setup.py` is how the startup file/prefs were first generated (Industry Compatible keymap, no timeline, env-art workspaces only); re-run it to reset.

Extensions install into `portable/extensions/` (ignored); the source of truth is `extensions.txt`.
