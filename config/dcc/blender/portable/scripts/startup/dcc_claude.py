# Viewport sidebar tab "Loadout" for this repo's own tools. Any panel with bl_category 'Loadout' joins it, so a new tool
# adds its own panel in its own startup script. First tool: open Claude Code in Ghostty at the project root and tile
# Ghostty 1/4 left, Blender 3/4 right. Claude reaches the scene through the blender MCP that install.sh registers.
import os
import shlex
import subprocess

import bpy

GHOSTTY = '/Applications/Ghostty.app'

# ponytail: fixed 1/4 : 3/4 split on the screen Blender is on; add a split preference if one is ever wanted.
# The launch lives in the script so it can tell the new Ghostty apart from any already running (by pid): `open -n`
# always starts a fresh instance, and window-save-state=never stops it restoring old windows.
# NSScreen is bottom-left origin, System Events top-left, hence the flip against the primary screen's height.
TILE = '''
use framework "AppKit"
use scripting additions
on run {launchCmd, bid}
    set bid to bid as integer
    set {{fx, fy}, {fw, fh}} to current application's NSScreen's mainScreen()'s visibleFrame()
    set {{_x, _y}, {_w, sh}} to current application's NSScreen's screens()'s firstObject()'s frame()
    set top to sh - (fy + fh)
    set gw to round (fw * 0.25)
    tell application "System Events"
        -- Address processes by unix id every time: System Events turns a saved process reference back into
        -- `application process "ghostty"`, which matches the first Ghostty by name, i.e. one already running.
        set old to unix id of every application process whose bundle identifier is "com.mitchellh.ghostty"
        do shell script launchCmd
        set gid to missing value
        repeat 100 times
            set ids to unix id of every application process whose bundle identifier is "com.mitchellh.ghostty"
            repeat with i in ids
                set n to contents of i
                if old does not contain n and (exists window 1 of (first application process whose unix id is n)) then set gid to n
            end repeat
            if gid is not missing value then exit repeat
            delay 0.1
        end repeat
        if gid is missing value then error "Ghostty window did not appear"
        tell window 1 of (first application process whose unix id is gid)
            set position to {fx, top}
            set size to {gw, fh}
        end tell
        tell window 1 of (first application process whose unix id is bid)
            set position to {fx + gw, top}
            set size to {fw - gw, fh}
        end tell
    end tell
end run
'''


def _project_root():
    if not bpy.data.filepath:
        return os.path.expanduser('~')
    folder = os.path.dirname(bpy.data.filepath)
    git = subprocess.run(['git', '-C', folder, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return git.stdout.strip() if git.returncode == 0 else folder


def _watch(proc):
    # Tiling runs in the background so Blender never blocks; report a failure once osascript exits.
    if proc.poll() is None:
        return 0.25
    if proc.returncode:
        err = proc.stderr.read().strip()
        msg = 'Could not tile windows.'
        if 'assistive' in err or '-25211' in err or '-1719' in err:
            msg += ' Allow Blender under Privacy & Security > Accessibility.'

        def draw(self, _context):
            self.layout.label(text=msg)
            self.layout.label(text=err[-120:])
        bpy.context.window_manager.popup_menu(draw, title='Claude Code', icon='ERROR')
    return None


class DCC_OT_claude_terminal(bpy.types.Operator):
    """Open Claude Code in Ghostty at the project root, beside Blender"""
    bl_idname = 'dcc.claude_terminal'
    bl_label = 'Launch Claude Code'

    def execute(self, context):
        if not os.path.isdir(GHOSTTY):
            self.report({'ERROR'}, 'Ghostty is not installed')
            return {'CANCELLED'}
        # Login shell: Blender started from Finder has no ~/.local/bin on PATH. exec zsh keeps the window after exit.
        launch = shlex.join(['open', '-na', GHOSTTY, '--args', '--window-save-state=never',
                             f'--working-directory={_project_root()}', '-e', '/bin/zsh', '-lic', 'claude; exec zsh -l'])
        proc = subprocess.Popen(['osascript', '-e', TILE, launch, str(os.getpid())], stderr=subprocess.PIPE, text=True)
        bpy.app.timers.register(lambda: _watch(proc), first_interval=0.5)
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
