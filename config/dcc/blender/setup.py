# Environment-artist startup. Run once: `bin/blender --python setup.py` (opens a window briefly), then commit portable/config.
import bpy, os
bpy.ops.wm.read_homefile(use_factory_startup=True)  # start from the factory scene, not the previous startup.blend, so this script is the whole truth (prefs untouched)

# preferences
# keymap: dcc.py is a full preset (Industry Compatible + our edits). Change keys in Preferences > Keymap, then `bin/keymap-export` and commit.
bpy.ops.preferences.keyconfig_activate(filepath=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'portable', 'scripts', 'presets', 'keyconfig', 'dcc.py'))
p = bpy.context.preferences
p.view.show_splash = False
p.view.show_navigate_ui = False   # drop the zoom/pan/camera/persp buttons; the axis gizmo stays
p.inputs.use_zoom_to_mouse = True
p.edit.undo_steps = 128
p.system.use_online_access = True  # MCP add-on refuses to open its socket offline
p.inputs.use_rotate_around_active = True   # orbit around the selected prop, not the view centre, when placing/inspecting assets
p.inputs.use_mouse_depth_navigate = True   # orbit/pan pivot on the surface under the cursor: navigate big scenes without selecting first
bpy.ops.preferences.addon_enable(module='node_wrangler')  # still a bundled legacy add-on, not on extensions.blender.org

# scene: metric shown in cm (Unreal), completely empty (no objects, no collections)
sc = bpy.context.scene
sc.unit_settings.system, sc.unit_settings.scale_length = 'METRIC', 1.0
sc.unit_settings.length_unit = 'CENTIMETERS'  # display only; 1 BU stays 1 m so glTF/USD/physics are untouched. FBX scale is a per-export arg, not a pref.
ts = sc.tool_settings
ts.use_mesh_automerge = True                     # snap modular pieces together without leaving doubles
ts.snap_elements_base = ts.snap_elements = {'INCREMENT'}  # idle snap = world grid for kit pieces; vertex/edge/face via the Shift+X snap pie
ts.use_snap_grid_absolute = True                 # absolute grid, not relative offsets: kit-bash placement
ts.use_transform_correct_face_attributes = True  # keep UVs from stretching on vertex transforms
bpy.data.batch_remove(list(bpy.data.objects) + list(bpy.data.collections))

# workspaces not needed for environment art
bpy.data.batch_remove([ws for ws in bpy.data.workspaces if ws.name in ('Animation', 'Compositing', 'Scripting')])

# area edits need the workspace live in the window, so visit each one per event-loop tick
todo = list(bpy.data.workspaces)
def step():
    win = bpy.context.window_manager.windows[0]
    for area in win.screen.areas:
        if area.type == 'VIEW_3D':
            sp, sh = area.spaces[0], area.spaces[0].shading
            sp.overlay.show_stats = True   # poly/vert counts in viewport
            sp.clip_end = 10000            # large outdoor environments
            sh.light, sh.show_cavity, sh.cavity_type = 'MATCAP', True, 'BOTH'  # read surface form while modeling
    for area in [a for a in win.screen.areas if a.ui_type == 'TIMELINE']:
        if win.workspace.name == 'Layout':
            area.ui_type = 'ASSETS'    # asset shelf for drag-and-drop kit placement, instead of a timeline we never use
        else:
            with bpy.context.temp_override(window=win, area=area):
                bpy.ops.screen.area_close()
    if todo:
        win.workspace = todo.pop()
        return 0.1
    if win.workspace.name != 'Layout':       # switch is deferred a tick; save only once Layout is live
        win.workspace = bpy.data.workspaces['Layout']
        return 0.1
    bpy.ops.wm.save_userpref()
    bpy.ops.wm.save_homefile()
    os._exit(0)  # skip the "unsaved changes" quit prompt
bpy.app.timers.register(step, first_interval=0.5)
