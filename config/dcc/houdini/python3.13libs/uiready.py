# Houdini runs every pythonX.Ylibs/uiready.py on HOUDINI_PATH once the UI is up.
import hou

# Ctrl+U (Control, not Cmd) runs Edit > Toggle Auto Update / Manual (MainMenuCommon.xml); unbound in every stock context.
hou.hotkeys.addAssignment("h", "h.loadout_toggle_update_mode", "ctrl+u")
