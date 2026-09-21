# Remove the sidebar's Animation tab (Global Transform: copy/paste for keyed poses). It is core UI in Blender 5.x, not an
# add-on, so the only way to hide it is to unregister the panels after bl_ui loads. Environment work never keys transforms.
import bpy
from bl_ui import space_view3d_sidebar


def register():
    for cls in reversed(space_view3d_sidebar.classes):
        if getattr(cls, 'bl_category', None) == 'Animation' and cls.is_registered:
            bpy.utils.unregister_class(cls)


def unregister():
    for cls in space_view3d_sidebar.classes:
        if getattr(cls, 'bl_category', None) == 'Animation' and not cls.is_registered:
            bpy.utils.register_class(cls)
