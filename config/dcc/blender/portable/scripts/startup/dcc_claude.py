# Viewport sidebar tab "Loadout" for this repo's own tools. Any panel with bl_category 'Loadout' joins it, so a new tool
# adds its own panel in its own startup script. First tool: open Claude Code in Ghostty at the project root. Claude
# reaches the scene through the blender MCP that install.sh registers. Loadout WM (wm/) places the window: it joins
# Ghostty's split, and Cmd-Tab goes between it and Blender.
import os
import subprocess

import bpy

GHOSTTY = '/Applications/Ghostty.app'


def _project_root():
    if not bpy.data.filepath:
        return os.path.expanduser('~')
    folder = os.path.dirname(bpy.data.filepath)
    git = subprocess.run(['git', '-C', folder, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return git.stdout.strip() if git.returncode == 0 else folder


class DCC_OT_claude_terminal(bpy.types.Operator):
    """Open Claude Code in Ghostty at the project root"""
    bl_idname = 'dcc.claude_terminal'
    bl_label = 'Launch Claude Code'

    def execute(self, context):
        if not os.path.isdir(GHOSTTY):
            self.report({'ERROR'}, 'Ghostty is not installed')
            return {'CANCELLED'}
        # Login shell: Blender started from Finder has no ~/.local/bin on PATH. exec zsh keeps the window after exit.
        # `open -n` starts a fresh Ghostty, and window-save-state=never stops it restoring old windows.
        subprocess.Popen(['open', '-na', GHOSTTY, '--args', '--window-save-state=never',
                          f'--working-directory={_project_root()}', '-e', '/bin/zsh', '-lic', 'claude; exec zsh -l'])
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
