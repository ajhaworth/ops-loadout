# Viewport sidebar tab "Loadout" for this repo's own tools. Any panel with bl_category 'Loadout' joins it, so a new tool
# adds its own panel in its own startup script. First tool: open Claude Code in Ghostty at the project root, beside
# Blender: Loadout WM (wm/) pairs the two, Ghostty on the left quarter and Blender on the rest, and switching to either
# brings both up. Claude reaches the scene through the blender MCP that install.sh registers.
import os
import subprocess
import threading
import time

import bpy

GHOSTTY = '/Applications/Ghostty.app'
GHOSTTY_BIN = GHOSTTY + '/Contents/MacOS/ghostty'
SPLIT = '0.25'
# The installed Loadout WM, else a dev build in the checkout this script lives in (portable/ is a symlink into it).
_REPO = os.path.realpath(__file__)
for _ in range(7):
    _REPO = os.path.dirname(_REPO)
WM = (os.path.expanduser('~/Applications/Loadout WM.app/Contents/MacOS/loadout-wm'),
      os.path.join(_REPO, 'wm', 'target', 'release', 'loadout-wm'))


def _ghostty_pids():
    out = subprocess.run(['pgrep', '-f', GHOSTTY_BIN], capture_output=True, text=True).stdout
    return {int(p) for p in out.split()}


def _pair(before, blender):
    # `open -n` starts a fresh Ghostty: its pid is the one not running before. The WM places its window once it opens.
    for _ in range(100):
        new = _ghostty_pids() - before
        if new:
            break
        time.sleep(0.1)
    else:
        return
    wm = next((w for w in WM if os.access(w, os.X_OK)), None)
    if wm:
        subprocess.run([wm, 'pair', str(min(new)), str(blender), SPLIT])


def _project_root():
    if not bpy.data.filepath:
        return os.path.expanduser('~')
    folder = os.path.dirname(bpy.data.filepath)
    git = subprocess.run(['git', '-C', folder, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return git.stdout.strip() if git.returncode == 0 else folder


class DCC_OT_claude_terminal(bpy.types.Operator):
    """Open Claude Code in Ghostty at the project root, beside Blender"""
    bl_idname = 'dcc.claude_terminal'
    bl_label = 'Launch Claude Code'

    def execute(self, context):
        if not os.path.isdir(GHOSTTY):
            self.report({'ERROR'}, 'Ghostty is not installed')
            return {'CANCELLED'}
        # Login shell: Blender started from Finder has no ~/.local/bin on PATH. exec zsh keeps the window after exit.
        # `open -n` starts a fresh Ghostty, and window-save-state=never stops it restoring old windows. Pairing waits
        # for it in a thread, so Blender never blocks; without Loadout WM, Ghostty just opens where it likes.
        before = _ghostty_pids()
        subprocess.Popen(['open', '-na', GHOSTTY, '--args', '--window-save-state=never',
                          f'--working-directory={_project_root()}', '-e', '/bin/zsh', '-lic', 'claude; exec zsh -l'])
        threading.Thread(target=_pair, args=(before, os.getpid()), daemon=True).start()
        return {'FINISHED'}


class VIEW3D_PT_loadout_claude(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = 'Loadout'
    bl_label = 'Claude Code'

    def draw(self, context):
        self.layout.operator(DCC_OT_claude_terminal.bl_idname, icon='CONSOLE')


classes = (DCC_OT_claude_terminal, VIEW3D_PT_loadout_claude)


def register():
    for c in classes:
        bpy.utils.register_class(c)


def unregister():
    for c in reversed(classes):
        bpy.utils.unregister_class(c)
