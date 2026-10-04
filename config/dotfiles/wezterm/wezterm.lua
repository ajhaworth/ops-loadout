-- WezTerm on Windows, styled after config/dotfiles/ghostty/config: Ghostty has
-- no Windows build. Both bundle JetBrains Mono as the default font.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.color_scheme = 'Catppuccin Mocha'

-- Ghostty's 16 is macOS points; Windows renders the same number larger.
-- ponytail: eyeballed, tune on the box.
config.font_size = 12
-- Ligatures off for a consistent grid, as in Ghostty.
config.harfbuzz_features = { 'calt=0', 'clig=0', 'liga=0' }

config.default_cursor_style = 'SteadyBlock'
config.hide_tab_bar_if_only_one_tab = true
config.window_background_opacity = 0.7
config.win32_system_backdrop = 'Acrylic'
config.window_padding = { left = 10, right = 10, top = 10, bottom = 10 }
config.window_close_confirmation = 'NeverPrompt'

-- PowerShell 7 when installed, else the built-in Windows PowerShell.
local pwsh = 'C:\\Program Files\\PowerShell\\7\\pwsh.exe'
local f = io.open(pwsh)
if f then f:close() end
config.default_prog = { f and pwsh or 'powershell.exe', '-NoLogo' }

-- Claude Code: Shift+Enter inserts a newline instead of submitting.
config.keys = {
  { key = 'Enter', mods = 'SHIFT', action = wezterm.action.SendString '\n' },
}

return config
