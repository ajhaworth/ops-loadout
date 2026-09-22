# Builds reference.blend: each reference/*.fbx becomes an asset collection in
# the "Reference" catalog. Run once after adding/changing FBXs in reference/:
#   config/dcc/blender/bin/blender -b --factory-startup --python config/dcc/blender/assets/build.py
import bpy, os, glob
from mathutils import Vector

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.join(ROOT_DIR, 'reference')
CATALOG_UUID = '5b1e6f2a-6b1a-4e9e-9c1a-9b6f9a2b6c1e'
CATALOG_NAME = 'Reference'
MIN_HEIGHT, MAX_HEIGHT, TARGET_HEIGHT = 1.5, 2.2, 1.8

bpy.ops.wm.read_homefile(use_empty=True)


def mesh_world_bbox_z(objs):
    bpy.context.view_layer.update()  # matrix_world is stale after scale/location edits
    zs = [(obj.matrix_world @ Vector(corner)).z
          for obj in objs if obj.type == 'MESH'
          for corner in obj.bound_box]
    return (min(zs), max(zs)) if zs else (0.0, 0.0)


def apply_scale(objs):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objs:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)


fbx_files = sorted(glob.glob(os.path.join(REF_DIR, '*.fbx')))
assert fbx_files, f'no FBX files found in {REF_DIR}'

for fbx in fbx_files:
    name = os.path.splitext(os.path.basename(fbx))[0]
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=fbx)
    imported = [o for o in bpy.data.objects if o not in before]
    assert imported, f'{fbx} imported no objects'

    coll = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(coll)
    for obj in imported:
        for c in list(obj.users_collection):
            c.objects.unlink(obj)
        coll.objects.link(obj)

    roots = [o for o in imported if o.parent is None or o.parent not in imported]

    zmin, zmax = mesh_world_bbox_z(imported)
    height = zmax - zmin
    print(f'{name}: raw height {height:.4f} m (min z {zmin:.4f})', flush=True)

    # Some references are modelled at arbitrary size (the stylised base mesh is
    # ~11 m); scale anything implausible to a 1.8 m person so it reads as scale.
    if height > 0 and not (MIN_HEIGHT <= height <= MAX_HEIGHT):
        print(f'{name}: scaling {height:.4f} m to {TARGET_HEIGHT} m', flush=True)
        for obj in roots:
            obj.scale *= TARGET_HEIGHT / height
        apply_scale(roots)
        zmin, zmax = mesh_world_bbox_z(imported)
        height = zmax - zmin

    # Ground the asset: shift roots so the mesh bbox floor sits at world Z 0.
    if abs(zmin) > 1e-4:
        for obj in roots:
            obj.location.z -= zmin
        zmin, zmax = mesh_world_bbox_z(imported)
        height = zmax - zmin

    print(f'{name}: final height {height:.4f} m (min z {zmin:.4f})', flush=True)
    assert MIN_HEIGHT <= height <= MAX_HEIGHT, f'{name}: final height {height:.4f} m out of range'

    coll.asset_mark()
    coll.asset_data.catalog_id = CATALOG_UUID
    try:
        coll.asset_generate_preview()
    except Exception as exc:
        print(f'{name}: preview generation skipped ({exc})', flush=True)

with open(os.path.join(ROOT_DIR, 'blender_assets.cats.txt'), 'w') as f:
    f.write(
        '# This is an Asset Catalog Definition file for Blender.\n'
        '#\n'
        '# Empty lines and lines starting with `#` will be ignored.\n'
        '# The first non-ignored line should be the version indicator.\n'
        '# Other lines are of the format "UUID:catalog/path/for/assets:simple catalog name"\n'
        '\n'
        'VERSION 1\n'
        '\n'
        f'{CATALOG_UUID}:{CATALOG_NAME}:{CATALOG_NAME}\n'
    )

out = os.path.join(ROOT_DIR, 'reference.blend')
bpy.ops.wm.save_as_mainfile(filepath=out, compress=True)
print(f'Saved {out}', flush=True)
