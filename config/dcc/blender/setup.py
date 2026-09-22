# Environment-artist startup. Run once: `bin/blender --python setup.py` (opens a window briefly), then commit portable/config.
import bpy, os, traceback
setup_errors = []
bpy.ops.wm.read_homefile(use_factory_startup=True)  # start from the factory scene, not the previous startup.blend, so this script is the whole truth (prefs untouched)

# preferences
# keymap: dcc.py is a full preset (Industry Compatible + our edits). Change keys in Preferences > Keymap, then `bin/keymap-export` and commit.
if not bpy.utils.keyconfig_set(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'portable', 'scripts', 'presets', 'keyconfig', 'dcc.py')):
    raise RuntimeError('Could not activate custom dcc keymap')
p = bpy.context.preferences
# Asset library: config/dcc/blender/assets, registered idempotently (drop any stale "Loadout" entry first).
assets_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets')
for lib in list(p.filepaths.asset_libraries):
    if lib.name == 'Loadout':
        p.filepaths.asset_libraries.remove(lib)
p.filepaths.asset_libraries.new(name='Loadout', directory=assets_dir)
p.view.show_splash = False
p.view.show_navigate_ui = False   # drop the zoom/pan/camera/persp buttons; the axis gizmo stays
p.inputs.use_zoom_to_mouse = True
p.edit.undo_steps = 128
p.system.use_online_access = True  # MCP add-on refuses to open its socket offline
p.inputs.use_rotate_around_active = True   # orbit around the selected prop, not the view centre, when placing/inspecting assets
p.inputs.use_mouse_depth_navigate = True   # orbit/pan pivot on the surface under the cursor: navigate big scenes without selecting first
# Re-enable installed extensions too, including plugins disabled in preferences.
for module in ['node_wrangler', *os.environ.get('OPS_BLENDER_ADDONS', '').split()]:
    try:
        if 'FINISHED' not in bpy.ops.preferences.addon_enable(module=module):
            raise RuntimeError('enable operator did not finish')
        print(f'Enabled {module}', flush=True)
    except Exception as exc:
        setup_errors.append(module)
        print(f'Failed to enable {module}: {exc}', flush=True)
bpy.ops.preferences.addon_disable(module='pose_library')  # character-animation tool, no use for environment work

# scene: metric shown in cm (Unreal), empty but for a linked scale-reference mannequin
sc = bpy.context.scene
sc.unit_settings.system, sc.unit_settings.scale_length = 'METRIC', 1.0
sc.unit_settings.length_unit = 'CENTIMETERS'  # display only; 1 BU stays 1 m so glTF/USD/physics are untouched. FBX scale is a per-export arg, not a pref.
ts = sc.tool_settings
ts.use_mesh_automerge = True                     # snap modular pieces together without leaving doubles
ts.snap_elements_base = ts.snap_elements = {'INCREMENT'}  # idle snap = world grid for kit pieces; vertex/edge/face via the Shift+X snap pie
ts.use_snap_grid_absolute = True                 # absolute grid, not relative offsets: kit-bash placement
ts.use_transform_correct_face_attributes = True  # keep UVs from stretching on vertex transforms
bpy.data.batch_remove(list(bpy.data.objects) + list(bpy.data.collections))
# linked (not appended) from the asset library, so rebuilding reference.blend updates it; path is resolved per machine
with bpy.data.libraries.load(os.path.join(assets_dir, 'reference.blend'), link=True) as (src, dst):
    dst.collections = ['Stylised Base Mesh Male']
mannequin = bpy.data.objects.new('Stylised Base Mesh Male', None)
mannequin.instance_type, mannequin.instance_collection = 'COLLECTION', dst.collections[0]
sc.collection.objects.link(mannequin)

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
            sh.show_backface_culling = True  # flipped normals and one-sided planes show as holes, as in engine
            sh.color_type, sh.wireframe_color_type = 'RANDOM', 'RANDOM'  # tell adjacent kit pieces apart at a glance
            sh.show_xray_wireframe = False  # wireframe mode hides occluded edges, so dense kits stay readable
            if win.workspace.name == 'Layout':
                sp.show_region_ui = True   # N panel open: exact transforms for placement
                r3d = sp.region_3d         # framed on the mannequin
                r3d.view_location, r3d.view_rotation, r3d.view_distance = (0.3279, -0.2473, 0.8698), (0.7374, 0.543, 0.2382, 0.3235), 5.5783
        elif area.ui_type == 'ASSETS' and area.spaces[0].params:  # params exist only once the browser has drawn
            area.spaces[0].params.catalog_id = '5b1e6f2a-6b1a-4e9e-9c1a-9b6f9a2b6c1e'  # "Reference", see assets/build.py
    for area in [a for a in win.screen.areas if a.ui_type == 'TIMELINE']:
        with bpy.context.temp_override(window=win, area=area):
            bpy.ops.screen.area_close()
    if win.workspace.name == 'Layout' and not any(a.ui_type == 'ASSETS' for a in win.screen.areas):
        # asset browser for drag-and-drop kit placement, collapsed to its header (drag the edge up to browse).
        # Split rather than resize: area_move refuses to run while the mouse is over any region.
        view = next(a for a in win.screen.areas if a.type == 'VIEW_3D')
        with bpy.context.temp_override(window=win, area=view):
            bpy.ops.screen.area_split(direction='HORIZONTAL', factor=0.01)
        min((a for a in win.screen.areas if a.type == 'VIEW_3D'), key=lambda a: a.y).ui_type = 'ASSETS'
    if todo:
        win.workspace = todo.pop()
        return 0.1
    if win.workspace.name != 'Layout':       # switch is deferred a tick; save only once Layout is live
        win.workspace = bpy.data.workspaces['Layout']
        return 0.1
    bpy.ops.wm.save_userpref()
    bpy.ops.wm.save_homefile()
    print('Custom configuration saved', flush=True)
    os._exit(1 if setup_errors else 0)  # skip the "unsaved changes" quit prompt

def guarded_step():
    try:
        return step()
    except Exception:
        traceback.print_exc()
        # Timer exceptions otherwise leave the installer waiting on an open window.
        import sys
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1)

bpy.app.timers.register(guarded_step, first_interval=0.5)
