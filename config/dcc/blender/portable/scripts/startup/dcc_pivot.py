# Environment-artist pivot utilities: origin-to-bounding-box and drop-to-ground, on a pie (hold S in Object Mode, see dcc.py).
import bpy
from mathutils import Vector


def _bounds_point(ob, where):
    # where = (-1|0|1) per axis: min / mid / max of the object-space bounding box (modifiers included)
    corners = [Vector(c) for c in ob.bound_box]
    lo = Vector(map(min, zip(*corners)))
    hi = Vector(map(max, zip(*corners)))
    return Vector((lo[i], (lo[i] + hi[i]) / 2, hi[i])[int(w) + 1] for i, w in enumerate(where))


def _set_origin(context, ob, point_world):
    # Cursor trick: origin_set handles every object type, parenting and shared data, so don't reimplement it.
    cursor = context.scene.cursor
    saved = cursor.location.copy()
    cursor.location = point_world
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    context.view_layer.objects.active = ob
    bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    cursor.location = saved


class DCC_OT_origin_to_bounds(bpy.types.Operator):
    """Move the origin to a point on the object's bounding box"""
    bl_idname = "dcc.origin_to_bounds"
    bl_label = "Origin to Bounds"
    bl_options = {'REGISTER', 'UNDO'}

    where: bpy.props.FloatVectorProperty(size=3, default=(0, 0, -1))  # -1/0/1 per axis; float so the pie can set it inline

    @classmethod
    def poll(cls, context):
        return context.mode == 'OBJECT' and context.selected_objects

    def execute(self, context):
        selected = list(context.selected_objects)
        active = context.view_layer.objects.active
        for ob in selected:
            _set_origin(context, ob, ob.matrix_world @ _bounds_point(ob, self.where))
        for ob in selected:
            ob.select_set(True)
        context.view_layer.objects.active = active
        return {'FINISHED'}


class DCC_OT_drop_to_ground(bpy.types.Operator):
    """Origin to bottom centre, then move the object so its lowest point sits on Z = 0"""
    bl_idname = "dcc.drop_to_ground"
    bl_label = "Drop to Ground"
    bl_options = {'REGISTER', 'UNDO'}

    poll = DCC_OT_origin_to_bounds.poll

    def execute(self, context):
        selected = list(context.selected_objects)
        bpy.ops.dcc.origin_to_bounds(where=(0, 0, -1))
        for ob in selected:
            min_z = min((ob.matrix_world @ Vector(c)).z for c in ob.bound_box)  # world-space lowest corner, so rotated objects land too
            mw = ob.matrix_world.copy()
            mw.translation.z -= min_z
            ob.matrix_world = mw  # via matrix_world so parented objects behave
        return {'FINISHED'}


class VIEW3D_MT_dcc_pivot(bpy.types.Menu):
    bl_label = "Pivot"

    def draw(self, context):
        ts = context.scene.tool_settings
        pie = self.layout.menu_pie()  # slot order: W, E, S, N, NW, NE, SW, SE; a 9th item wraps onto W, so never add one
        pie.operator("dcc.origin_to_bounds", text="Center", icon='PIVOT_BOUNDBOX').where = (0, 0, 0)
        pie.operator("dcc.origin_to_bounds", text="Bottom", icon='ANCHOR_BOTTOM').where = (0, 0, -1)

        # S: bottom-edge midpoints as a plan view, so the button's position matches its axis (+Y up the screen, +X right).
        grid = pie.box().grid_flow(columns=3, align=True)
        for y in (1, 0, -1):
            for x in (-1, 0, 1):
                if x and y or not (x or y):
                    grid.label(text="")  # corners and centre stay blank: a plus shape reads as the four sides
                else:
                    grid.operator("dcc.origin_to_bounds", text=("+X" if x > 0 else "-X") if x else ("+Y" if y > 0 else "-Y")).where = (x, y, -1)

        # N: transform pivot + origin-only toggle, then apply for Unreal export.
        box = pie.box()
        row = box.row(align=True)
        row.prop(ts, "transform_pivot_point", text="", expand=True)
        row.separator()
        row.prop(ts, "use_transform_data_origin", text="", icon='OBJECT_ORIGIN', toggle=True)  # G/R/S move only the origin
        row = box.row(align=True)
        row.label(text="Apply")
        for text, keep in (("Rot", {"rotation"}), ("Scale", {"scale"}), ("Rot+Scale", {"rotation", "scale"})):
            op = row.operator("object.transform_apply", text=text)
            op.location, op.rotation, op.scale = ("location" in keep, "rotation" in keep, "scale" in keep)

        pie.operator("dcc.drop_to_ground", icon='TRIA_DOWN_BAR')  # NW
        pie.separator()  # NE
        pie.operator("object.origin_set", text="Origin to Cursor", icon='PIVOT_CURSOR').type = 'ORIGIN_CURSOR'
        pie.operator("object.origin_set", text="Origin to Geometry", icon='PIVOT_MEDIAN').type = 'ORIGIN_GEOMETRY'


classes = (DCC_OT_origin_to_bounds, DCC_OT_drop_to_ground, VIEW3D_MT_dcc_pivot)


def register():
    for c in classes:
        bpy.utils.register_class(c)


def unregister():
    for c in reversed(classes):
        bpy.utils.unregister_class(c)
