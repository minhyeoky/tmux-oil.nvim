-- What keys and commands do: write path (write, run_plan), reload, jump, quit, name edits, toggles.
local parse = require("tmux-oil.parse")
local diff = require("tmux-oil.diff")
local view = require("tmux-oil.view")
local apply = require("tmux-oil.apply")
local tmux = require("tmux-oil.tmux")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")
local render = require("tmux-oil.render")
local effects = require("tmux-oil.effects")

local ns_preview = render.ns_preview
local redraw_marks = render.redraw_marks
local load = render.load
local error_marks = render.error_marks
local refresh_now = render.refresh_now
local switch_client = effects.switch_client
local restore_origin = effects.restore_origin
local stop_follow_timer = effects.stop

local M = {}

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

local function reload()
  if discard_ok() then
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    load({ id = id_under_cursor(), line = cur })
  end
end

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
  vim.api.nvim_buf_set_lines(state.S.buf, row, row + 1, false, { anchor })
  vim.api.nvim_win_set_cursor(0, { row + 1, #anchor })
  vim.cmd("startinsert!")
end

local function insert_at_name()
  local line = vim.api.nvim_get_current_line()
  local anchor = line:match("^[$@]%d+ ?") or ""
  name_start()
  -- An empty name: the cursor sits on the concealed space, so append instead of insert.
  vim.cmd(#anchor >= #line and "startinsert!" or "startinsert")
end

M.write = write
M.report_text = report_text
M.discard_ok = discard_ok
M.jump = jump
M.quit = quit
M.reload = reload
M.name_start = name_start
M.clear_name = clear_name
M.insert_at_name = insert_at_name
M.toggle_cwd = toggle_cwd
M.copy_title = copy_title

return M
