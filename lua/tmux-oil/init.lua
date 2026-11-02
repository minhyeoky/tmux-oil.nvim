-- setup, buffer lifecycle, autocmds, keymaps. design-v2 §3.
local tmux = require("tmux-oil.tmux")
local parse = require("tmux-oil.parse")
local diff = require("tmux-oil.diff")
local view = require("tmux-oil.view")
local apply = require("tmux-oil.apply")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")
local render = require("tmux-oil.render")
local effects = require("tmux-oil.effects")

local M = {}

local ns_preview = render.ns_preview
local redraw_marks = render.redraw_marks
local load = render.load
local error_marks = render.error_marks
local refresh_now = render.refresh_now
local refresh_soon = render.refresh_soon
local follow_active = effects.follow_active
local switch_client = effects.switch_client
local restore_origin = effects.restore_origin
local stop_follow_timer = effects.stop
local follow_soon = effects.follow_soon

M.config = config.values

local group = vim.api.nvim_create_augroup("TmuxOil", { clear = true })

function M.setup(opts)
  config.setup(opts)
  M.config = config.values
  tmux.socket = config.values.socket
end

local function report_text(ok, r)
  if ok then
    return string.format("applied %d", r.done)
  end
  return string.format("applied %d / failed 1 (%s: %s) / skipped %d", r.done,
    table.concat(vim.tbl_map(function(a)
      return type(a) == "table" and vim.inspect(a, { newline = " ", indent = "" }) or a
    end, r.failed.cmd), " "), r.failed.err or "?", r.skipped)
end

local function run_plan(plan)
  -- The followed window may be about to die: put the client back first. An origin that dies
  -- too cannot be restored — skip, and forget the follow so nothing targets a dead id.
  effects.before_apply(plan)
  local ok, report = apply.apply(plan, tmux, state.S.own_id, state.S.own_session)
  ui.notify(report_text(ok, report), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  state.S.apply_failed = not ok
  for _, h in ipairs(report.leftover_holds or {}) do
    local sess = state.S.state.by_id[h.session_id]
    ui.notify(string.format("placeholder window %s left in session %s — close it by hand",
      h.window_id, sess and sess.name or h.session_id), vim.log.levels.WARN)
  end
  -- Keep the cursor on its window, not its line number: the reload reorders lines.
  local win = vim.fn.bufwinid(state.S.buf)
  local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or nil
  local id = cur and vim.api.nvim_buf_get_lines(state.S.buf, cur - 1, cur, false)[1]:match("^([$@]%d+)")
  state.S.reloaded = load({ id = id, line = cur })
  effects.after_reload()
end

local function write()
  refresh_now() -- :w never sees a stale preview
  local rows, errors = parse.parse(vim.api.nvim_buf_get_lines(state.S.buf, 0, -1, false))
  if #errors > 0 then
    view.apply_marks(state.S.buf, ns_preview, error_marks(errors))
    ui.notify(string.format("fix %d error(s) before saving", #errors), vim.log.levels.ERROR)
    return
  end
  local fresh, err = tmux.read()
  if not fresh then
    ui.notify("cannot read tmux: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if fresh.server_pid ~= state.S.state.server_pid then
    ui.notify("tmux server restarted since the buffer was rendered — press R",
      vim.log.levels.ERROR)
    return
  end
  effects.patch_attached(fresh)
  local plan, perrs = diff.compute(rows, fresh, state.S.rendered)
  if not plan then
    local msgs = {}
    for _, e in ipairs(perrs) do
      msgs[#msgs + 1] = e.msg
    end
    ui.notify(table.concat(msgs, "; "), vim.log.levels.ERROR)
    return
  end
  if plan.empty then
    vim.bo[state.S.buf].modified = false
    return
  end
  stop_follow_timer() -- a pending follow must not move the client under the confirm float
  state.S.apply_failed = false
  if config.values.skip_confirm then
    run_plan(plan)
  else
    ui.confirm(plan, fresh, function(yes)
      if yes then
        run_plan(plan)
      end
    end)
  end
  if state.S.apply_failed then
    -- A failed write must not let :wq/:x quit over the error. When load() showed tmux's real
    -- state, clear the flag once the quit check is past: q has nothing to discard. An edit
    -- queued behind the :w (a macro, a mapping) bumps changedtick and keeps the flag.
    local buf = state.S.buf
    vim.bo[buf].modified = true
    if state.S.reloaded then
      local tick = vim.b[buf].changedtick
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].changedtick == tick then
          vim.bo[buf].modified = false
        end
      end)
    end
  end
end

-- Returns true when it is fine to throw the buffer text away.
local function discard_ok()
  if not vim.bo[state.S.buf].modified then
    return true
  end
  return vim.fn.confirm("Discard changes?", "&Yes\n&No", 2) == 1
end

local function id_under_cursor()
  local line = vim.api.nvim_get_current_line()
  return line:match("^([$@]%d+)")
end

local function jump()
  local id = id_under_cursor()
  if not id then
    ui.notify("not created yet")
    return
  end
  if state.S.popup and not discard_ok() then
    return
  end
  local _, err = switch_client(id)
  if err then
    ui.notify(err, vim.log.levels.ERROR)
  elseif state.S.popup then
    stop_follow_timer()
    state.S.confirmed = true -- the jump keeps the followed selection (VimLeavePre must not restore)
    vim.bo[state.S.buf].modified = false -- the discard was confirmed above
    local ok, qerr = pcall(vim.cmd, "qa") -- other modified buffers block instead of being lost
    if not ok then
      state.S.confirmed = false -- still open: a later q restores as usual
      ui.notify(tostring(qerr), vim.log.levels.ERROR)
    end
  end
end

local function quit()
  if not discard_ok() then
    return
  end
  if state.S.popup then
    stop_follow_timer()
    restore_origin()
    -- Same as jump(): our buffer is discarded on purpose, other modified buffers still block.
    vim.bo.modified = false
    local ok, err = pcall(vim.cmd, "qa")
    if not ok then
      ui.notify(tostring(err))
    end
  else
    vim.cmd("bwipeout!")
  end
end

local function toggle_cwd()
  state.S.show_cwd = not state.S.show_cwd
  refresh_now() -- keeps the cut titles of lines that carry a preview mark
end

local function copy_title()
  local id = id_under_cursor()
  local w = id and id:sub(1, 1) == "@" and state.S.state.by_id[id]
  if not w or w.title == "" then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_get_current_line()
  local anchor = line:match("^@%d+ ?")
  local text = (anchor:sub(-1) == " " and "" or " ") .. w.title
  vim.api.nvim_buf_set_text(state.S.buf, row, #anchor, row, #line, { text })
  redraw_marks(state.S.buf)
end

local function set_keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "tmux-oil: " .. desc })
  end
  map("<CR>", jump, "jump")
  map("q", quit, "close")
  map("R", function()
    if discard_ok() then
      local cur = vim.api.nvim_win_get_cursor(0)[1]
      load({ id = id_under_cursor(), line = cur })
    end
  end, "reload")
  -- The anchor is concealed, so line-wise edits must stop at the name (§1: anchor = identity).
  local function name_start()
    local anchor = vim.api.nvim_get_current_line():match("^[$@]%d+ ?") or ""
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], #anchor })
  end
  local function clear_name()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local line = vim.api.nvim_get_current_line()
    local anchor = line:match("^[$@]%d+ ?") or ""
    if anchor ~= "" and anchor:sub(-1) ~= " " then
      anchor = anchor .. " "
    end
    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { anchor })
    vim.api.nvim_win_set_cursor(0, { row + 1, #anchor })
    vim.cmd("startinsert!")
  end
  map("cc", clear_name, "retype name")
  map("S", clear_name, "retype name")
  map("0", name_start, "name start")
  map("^", name_start, "name start")
  map("I", function()
    local line = vim.api.nvim_get_current_line()
    local anchor = line:match("^[$@]%d+ ?") or ""
    name_start()
    -- An empty name: the cursor sits on the concealed space, so append instead of insert.
    vim.cmd(#anchor >= #line and "startinsert!" or "startinsert")
  end, "insert at name start")
  map("gc", toggle_cwd, "toggle cwd")
  map("gt", copy_title, "copy title")
  map("g?", ui.help, "help")
end

local function set_autocmds(buf)
  local function au(events, fn)
    vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn })
  end
  au("BufWriteCmd", write)
  -- Normal-mode edits (dd, p, J) move whole lines: their marks must follow at once, or the
  -- deleted line's decorations sit on the next line until the timer fires. Only typing
  -- in insert mode is debounced.
  au("TextChanged", refresh_now)
  au("TextChangedI", refresh_soon)
  au("InsertLeave", refresh_now)
  au("CursorMoved", follow_soon)
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    stop_follow_timer()
    restore_origin()
  end })
  au("BufWipeout", function()
    restore_origin()
    stop_follow_timer()
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
    if not discard_ok() then
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
  load({ id = state.S.own_id, line = 1 })
end

M._state = function() return state.S end
M._report_text = report_text

return M
