-- setup, buffer lifecycle, autocmds, keymaps. design-v2 §3.
local tmux = require("tmux-oil.tmux")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")
local render = require("tmux-oil.render")
local effects = require("tmux-oil.effects")
local actions = require("tmux-oil.actions")

local M = {}

M.config = config.values

local group = vim.api.nvim_create_augroup("TmuxOil", { clear = true })

function M.setup(opts)
  config.setup(opts)
  M.config = config.values
  tmux.socket = config.values.socket
end

local function set_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "tmux-oil: " .. desc })
  end
  map("<CR>", actions.jump, "jump")
  map("q", actions.quit, "close")
  map("R", actions.reload, "reload")
  map("cc", actions.clear_name, "retype name")
  map("S", actions.clear_name, "retype name")
  map("0", actions.name_start, "name start")
  map("^", actions.name_start, "name start")
  map("I", actions.insert_at_name, "insert at name start")
  map("gc", actions.toggle_cwd, "toggle cwd")
  map("gt", actions.copy_title, "copy title")
  map("g?", ui.help, "help")
end

local function set_autocmds(buf)
  local function au(events, fn)
    vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn })
  end
  au("BufWriteCmd", actions.write)
  -- Normal-mode edits (dd, p, J) move whole lines: their marks must follow at once, or the
  -- deleted line's decorations sit on the next line until the timer fires. Only typing
  -- in insert mode is debounced.
  au("TextChanged", render.refresh_now)
  au("TextChangedI", render.refresh_soon)
  au("InsertLeave", render.refresh_now)
  au("CursorMoved", effects.follow_soon)
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    effects.stop()
    effects.restore_origin()
  end })
  au("BufWipeout", function()
    effects.restore_origin()
    effects.stop()
    render.cancel()
    state.S = nil
    vim.api.nvim_clear_autocmds({ group = group })
  end)
end

-- Local-scope window options (never the global value): they do not leak to the next buffer
-- shown in this window. Needs the buffer to be current in the window.
local function setup_window(buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].conceallevel = 3
  vim.wo[win][0].concealcursor = "nvic"
  vim.wo[win][0].wrap = false
  vim.wo[win][0].number = false
  vim.wo[win][0].relativenumber = false
  vim.wo[win][0].signcolumn = "no"
  vim.wo[win][0].foldcolumn = "0"
  vim.wo[win][0].list = false
end

local function set_highlights()
  vim.api.nvim_set_hl(0, "TmuxOilSession", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "TmuxOilSessionInfo", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "TmuxOilIndex", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "TmuxOilAnchor", { link = "Conceal", default = true })
  vim.api.nvim_set_hl(0, "TmuxOilAgent", { fg = "#D97757", default = true })
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "tmux-oil://")
  for opt, v in pairs({ buftype = "acwrite", bufhidden = "wipe", swapfile = false,
    filetype = "tmux-oil" }) do
    vim.bo[buf][opt] = v
  end
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { buffer = buf, callback = set_highlights })
  vim.api.nvim_set_current_buf(buf)
  setup_window(buf)
  vim.cmd([[syntax match TmuxOilAnchor /^[$@]\d\+ / conceal]])
  set_keymaps(buf)
  set_autocmds(buf)
  return buf
end

local function display(fmt)
  if not vim.env.TMUX then
    return nil
  end
  return (tmux.run({ "display-message", "-p", fmt }))
end

-- opts.popup: caller declares it runs inside display-popup. own_id/own_session are then the
-- window/session the popup was opened from (display-message resolves via the client).
function M.open(opts)
  tmux.socket = config.values.socket
  local popup = opts and opts.popup or false
  if state.S and vim.api.nvim_buf_is_valid(state.S.buf) then
    vim.api.nvim_set_current_buf(state.S.buf)
    setup_window(state.S.buf)
    state.S.popup = popup
    if not actions.discard_ok() then
      return -- keep the edited text; just show it
    end
  else
    state.S = { show_cwd = config.values.show_cwd }
    state.S.buf = create_buffer()
  end
  state.S.popup = popup
  if popup then
    -- The popup's nvim shows only this buffer: the status line is a wasted row. Set again
    -- after startup, since a config may set laststatus on VimEnter/VeryLazy.
    vim.o.laststatus = 0
    vim.schedule(function() vim.o.laststatus = 0 end)
  end
  state.S.own_id = display("#{window_id}")
  state.S.own_session = display("#{session_id}")
  state.S.client = display("#{client_name}")
  state.S.confirmed = false
  state.S.origin, state.S.follow_last, state.S.touched = nil, nil, {}
  if state.S.own_id and state.S.own_session then
    state.S.origin = { session = state.S.own_session, window = state.S.own_id }
    state.S.follow_last = state.S.own_id
  end
  render.load({ id = state.S.own_id, line = 1 })
end

M._state = function() return state.S end
M._report_text = actions.report_text

return M
