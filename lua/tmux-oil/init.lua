-- setup, buffer lifecycle, autocmds, keymaps. design-v2 §3.
local tmux = require("tmux-oil.tmux")
local parse = require("tmux-oil.parse")
local diff = require("tmux-oil.diff")
local view = require("tmux-oil.view")
local apply = require("tmux-oil.apply")
local ui = require("tmux-oil.ui")

local M = {}

M.config = {
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

local ns = vim.api.nvim_create_namespace("tmux-oil")
local ns_preview = vim.api.nvim_create_namespace("tmux-oil-preview")
local group = vim.api.nvim_create_augroup("TmuxOil", { clear = true })

-- Single buffer: { buf, state, rendered, own_id, own_session, popup, show_cwd, client,
--   origin = { session, window }, follow_last, touched = { [session_id] = active window },
--   confirmed }
local S = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  tmux.socket = M.config.socket
end

local function view_cfg()
  return vim.tbl_extend("force", M.config, { show_cwd = S.show_cwd, host = S.state and S.state.host })
end

-- Marks come from the buffer text as it is now: every line whose anchor names a known id gets
-- that object's marks at that line's own positions. Other lines get none.
local function redraw_marks(buf)
  if not S or not S.state or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = view_cfg()
  local marks = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local kind, id = parse.classify(line)
    local obj = kind and id and S.state.by_id[id]
    if obj then
      vim.list_extend(marks, view.marks_for(line, i, obj, cfg))
    end
  end
  view.apply_marks(buf, ns, marks)
end

-- Puts the cursor on the line anchored by target.id (first column of the name). Not found:
-- target.line clamped to the buffer, or untouched when target.line is nil.
local function place_cursor(target)
  local win = vim.fn.bufwinid(S.buf)
  if win == -1 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
  local lnum
  for i, line in ipairs(lines) do
    if target.id and line:match("^([$@]%d+)") == target.id then
      lnum = i
      break
    end
  end
  lnum = lnum or (target.line and math.max(1, math.min(target.line, #lines)))
  if lnum then
    local col = #(lines[lnum]:match("^[$@]%d+ ?") or "")
    vim.api.nvim_win_set_cursor(win, { lnum, math.min(col, math.max(#lines[lnum] - 1, 0)) })
  end
end

-- target: see place_cursor; nil leaves the cursor wherever the redraw put it.
local function load(target)
  local state, err = tmux.read()
  if not state then
    ui.notify("cannot read tmux: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local lines, _, ids = view.render(state, view_cfg())
  S.state, S.rendered = state, ids
  view.draw(S.buf, lines, {}, ns)
  redraw_marks(S.buf)
  vim.api.nvim_buf_clear_namespace(S.buf, ns_preview, 0, -1)
  if target then
    place_cursor(target)
  end
  return true
end

local function error_marks(errors)
  local marks = {}
  for _, e in ipairs(errors) do
    marks[#marks + 1] = { lnum = e.lnum or 1, col = 0, pos = "eol",
      virt_text = { { "✗ " .. e.msg, "DiagnosticError" } } }
  end
  return marks
end

-- no_kills: parse errors exist, so kills may be artifacts of the errored lines.
local function summary_text(plan, no_kills)
  local parts = {}
  local killed = 0
  for _, k in ipairs(plan.kills) do
    killed = killed + (k.kind == "session" and k.windows or 1)
  end
  if killed > 0 and not no_kills then
    parts[#parts + 1] = string.format("✗ %d window%s will be killed", killed,
      killed == 1 and "" or "s")
  end
  if #plan.untouched > 0 then
    parts[#parts + 1] = string.format("%d kept", #plan.untouched)
  end
  return table.concat(parts, " · ")
end

local function plan_marks(rows, plan, no_kills)
  local marks = {}
  local lnum_of = {}
  for _, r in ipairs(rows) do
    if r.id then
      lnum_of[r.id] = r.lnum
    elseif r.kind == "new" then
      marks[#marks + 1] = { lnum = r.lnum, col = 0, pos = "eol",
        virt_text = { { "+ new", "DiagnosticOk" } } }
    end
  end
  local function eol(id, text, hl)
    if lnum_of[id] then
      marks[#marks + 1] = { lnum = lnum_of[id], col = 0, pos = "eol",
        virt_text = { { text, hl } } }
    end
  end
  for _, r in ipairs(plan.session_renames) do
    eol(r.id, "✎ rename", "DiagnosticWarn")
  end
  for _, r in ipairs(plan.renames) do
    eol(r.id, "✎ rename", "DiagnosticWarn")
  end
  for _, a in ipairs(plan.autos) do
    eol(a.id, "✎ auto", "DiagnosticWarn")
  end
  for _, m in ipairs(plan.moves) do
    if S.state.session_of[m.id] ~= m.session_id then
      eol(m.id, "→ session " .. m.session_id, "DiagnosticHint")
    else
      eol(m.id, "↕ move", "DiagnosticHint")
    end
  end
  local text = summary_text(plan, no_kills)
  if text ~= "" then
    marks[#marks + 1] = { lnum = 1, col = 0, above = true,
      virt_lines = { { { text, "DiagnosticError" } } } }
  end
  return marks
end

local preview_timer = nil -- a pending debounced refresh, or nil

local function preview()
  if not S or not vim.api.nvim_buf_is_valid(S.buf) then
    return
  end
  local rows, errors = parse.parse(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false))
  local marks = error_marks(errors)
  local plan, perrs = diff.compute(rows, S.state, S.rendered)
  if plan then
    vim.list_extend(marks, plan_marks(rows, plan, #errors > 0))
  else
    vim.list_extend(marks, error_marks(perrs))
  end
  view.apply_marks(S.buf, ns_preview, marks)
end

-- Marks + preview, once, now. Cancels a pending debounced refresh.
local function refresh_now()
  if preview_timer then
    preview_timer:stop()
    preview_timer:close()
    preview_timer = nil
  end
  if S then
    redraw_marks(S.buf)
    preview()
  end
end

-- Edits restart one timer; both run once when typing pauses.
local function refresh_soon()
  local delay = M.config.preview_delay or 0
  if delay <= 0 then
    return refresh_now()
  end
  if preview_timer then
    preview_timer:stop()
    preview_timer:close()
  end
  local timer = vim.uv.new_timer()
  preview_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if preview_timer == timer then
      refresh_now()
    end
  end))
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

local function follow_active()
  return S ~= nil and S.popup == true and M.config.follow_cursor == true and S.origin ~= nil
end

-- Does the plan destroy this window (directly, or by killing its session)?
local function killed_by(plan, id)
  for _, k in ipairs(plan.kills) do
    if k.id == id or (k.kind == "session" and S.state.session_of[id] == k.id) then
      return true
    end
  end
  return false
end

-- switch-client pinned to the popup's own client: once that client is gone (terminal closed),
-- an unpinned switch-client would grab the most recently active client instead.
local function switch_client(target)
  local args = { "switch-client" }
  if S.client then
    vim.list_extend(args, { "-c", S.client })
  end
  vim.list_extend(args, { "-t", target })
  return tmux.run(args)
end

-- Puts the client back on the window the popup was opened from and every session follow
-- passed through back on its own current window. Idempotent; does nothing unless follow
-- moved away, and never after <CR> confirmed a target.
local function restore_origin()
  if not S or not S.origin or S.confirmed or not S.follow_last
    or S.follow_last == S.origin.window then
    return
  end
  for sess, active in pairs(S.touched or {}) do
    if sess ~= S.origin.session then
      tmux.run({ "select-window", "-t", active }) -- may be dead after :w; nothing to do then
    end
  end
  -- The window id alone finds the session it lives in now (a :w may have moved it).
  local _, err = switch_client(S.origin.window)
  if err then
    switch_client(S.origin.session)
  end
  S.follow_last, S.touched = S.origin.window, {}
end

local follow_timer = nil

local function stop_follow_timer()
  if follow_timer then
    follow_timer:stop()
    follow_timer:close()
    follow_timer = nil
  end
end

local function follow_now()
  stop_follow_timer()
  if not follow_active() then
    return
  end
  local win = vim.fn.bufwinid(S.buf)
  if win == -1 then
    return
  end
  local line = vim.api.nvim_buf_get_lines(S.buf, vim.api.nvim_win_get_cursor(win)[1] - 1,
    vim.api.nvim_win_get_cursor(win)[1], false)[1] or ""
  local id = line:match("^(@%d+)")
  if not id or id == S.follow_last then
    return -- session lines and anchorless lines do nothing
  end
  local sess = S.state and S.state.session_of[id]
  if sess and sess ~= S.origin.session and not S.touched[sess] then
    for _, w in ipairs(S.state.by_id[sess].windows) do
      if w.active then
        S.touched[sess] = w.id -- remembered once, before follow changes it
      end
    end
  end
  local _, err = switch_client(id)
  S.follow_last = id -- also on failure: no retry on every cursor move
  if err then
    ui.notify("follow: " .. err, vim.log.levels.WARN)
  end
end

local function follow_soon()
  if not follow_active() then
    return
  end
  local delay = M.config.follow_delay or 0
  if delay <= 0 then
    return follow_now()
  end
  stop_follow_timer()
  local timer = vim.uv.new_timer()
  follow_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if follow_timer == timer then
      follow_now()
    end
  end))
end

local function run_plan(plan)
  -- The followed window may be about to die: put the client back first. An origin that dies
  -- too cannot be restored — skip, and forget the follow so nothing targets a dead id.
  if follow_active() and S.follow_last and S.follow_last ~= S.origin.window
    and killed_by(plan, S.follow_last) then
    if killed_by(plan, S.origin.window) then
      S.follow_last = nil
    else
      restore_origin()
    end
  end
  local ok, report = apply.apply(plan, tmux, S.own_id, S.own_session)
  ui.notify(report_text(ok, report), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  S.apply_failed = not ok
  for _, h in ipairs(report.leftover_holds or {}) do
    local sess = S.state.by_id[h.session_id]
    ui.notify(string.format("placeholder window %s left in session %s — close it by hand",
      h.window_id, sess and sess.name or h.session_id), vim.log.levels.WARN)
  end
  load()
end

local function write()
  refresh_now() -- :w never sees a stale preview
  local rows, errors = parse.parse(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false))
  if #errors > 0 then
    view.apply_marks(S.buf, ns_preview, error_marks(errors))
    ui.notify(string.format("fix %d error(s) before saving", #errors), vim.log.levels.ERROR)
    return
  end
  local fresh, err = tmux.read()
  if not fresh then
    ui.notify("cannot read tmux: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if fresh.server_pid ~= S.state.server_pid then
    ui.notify("tmux server restarted since the buffer was rendered — press R",
      vim.log.levels.ERROR)
    return
  end
  if follow_active() and S.follow_last and S.follow_last ~= S.origin.window then
    -- The client is only visiting the followed session: for the guard it still sits on origin.
    local here, there = fresh.by_id[S.origin.session], fresh.by_id[fresh.session_of[S.follow_last]]
    if here then
      here.attached = true
    end
    if there and there ~= here then
      there.attached = there.attached_n > 1
    end
  end
  local plan, perrs = diff.compute(rows, fresh, S.rendered)
  if not plan then
    local msgs = {}
    for _, e in ipairs(perrs) do
      msgs[#msgs + 1] = e.msg
    end
    ui.notify(table.concat(msgs, "; "), vim.log.levels.ERROR)
    return
  end
  if plan.empty then
    vim.bo[S.buf].modified = false
    return
  end
  stop_follow_timer() -- a pending follow must not move the client under the confirm float
  S.apply_failed = false
  if M.config.skip_confirm then
    run_plan(plan)
  else
    ui.confirm(plan, fresh, function(yes)
      if yes then
        run_plan(plan)
      end
    end)
  end
  if S.apply_failed then
    vim.bo[S.buf].modified = true -- a failed write must not let :wq/:x quit over the error
  end
end

-- Returns true when it is fine to throw the buffer text away.
local function discard_ok()
  if not vim.bo[S.buf].modified then
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
  if S.popup and not discard_ok() then
    return
  end
  local _, err = switch_client(id)
  if err then
    ui.notify(err, vim.log.levels.ERROR)
  elseif S.popup then
    stop_follow_timer()
    S.confirmed = true -- the jump keeps the followed selection (VimLeavePre must not restore)
    vim.bo[S.buf].modified = false -- the discard was confirmed above
    local ok, qerr = pcall(vim.cmd, "qa") -- other modified buffers block instead of being lost
    if not ok then
      S.confirmed = false -- still open: a later q restores as usual
      ui.notify(tostring(qerr), vim.log.levels.ERROR)
    end
  end
end

local function quit()
  if not discard_ok() then
    return
  end
  if S.popup then
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
  S.show_cwd = not S.show_cwd
  redraw_marks(S.buf)
end

local function copy_title()
  local id = id_under_cursor()
  local w = id and id:sub(1, 1) == "@" and S.state.by_id[id]
  if not w or w.title == "" then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line = vim.api.nvim_get_current_line()
  local anchor = line:match("^@%d+ ?")
  local text = (anchor:sub(-1) == " " and "" or " ") .. w.title
  vim.api.nvim_buf_set_text(S.buf, row, #anchor, row, #line, { text })
  redraw_marks(S.buf)
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
    if preview_timer then
      preview_timer:stop()
      preview_timer:close()
      preview_timer = nil
    end
    S = nil
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
  tmux.socket = M.config.socket
  local popup = opts and opts.popup or false
  if S and vim.api.nvim_buf_is_valid(S.buf) then
    vim.api.nvim_set_current_buf(S.buf)
    setup_window(S.buf)
    S.popup = popup
    if not discard_ok() then
      return -- keep the edited text; just show it
    end
  else
    S = { show_cwd = M.config.show_cwd }
    S.buf = create_buffer()
  end
  S.popup = popup
  S.own_id = display("#{window_id}")
  S.own_session = display("#{session_id}")
  S.client = display("#{client_name}")
  S.confirmed = false
  S.origin, S.follow_last, S.touched = nil, nil, {}
  if S.own_id and S.own_session then
    S.origin = { session = S.own_session, window = S.own_id }
    S.follow_last = S.own_id
  end
  load({ id = S.own_id, line = 1 })
end

M._state = function() return S end
M._report_text = report_text

return M
