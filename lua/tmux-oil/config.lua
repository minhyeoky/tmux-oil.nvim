-- Defaults and the setup merge. config.values is replaced by setup: read it at call time.
local M = {}

M.values = {
  skip_confirm = false,
  icons = true,        -- true | "ascii" | false
  icon_map = {},
  show_cwd = false,
  indent = 0,          -- spaces before a window line's index; sessions are separated by a rule
  socket = nil,
  preview_delay = 40,  -- ms to wait after an edit before redrawing marks + preview; 0 = synchronous
  -- Popup only: moving the cursor onto a window line selects that window behind the popup;
  -- q / cancel restores the window the popup was opened from, <CR> keeps the selection.
  -- Ignored outside a popup: in a normal nvim the follow would leave nvim's own window.
  follow_cursor = false,
  follow_delay = 0,    -- ms the cursor must rest before following; 0 = on every line change
  home = vim.uv.os_homedir(),
}

function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
