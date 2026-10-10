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
  icons = true,
  icon_map = {},
  show_cwd = false,
  socket = nil,
  home = vim.uv.os_homedir(),
}

local ns = vim.api.nvim_create_namespace("tmux-oil")
local ns_preview = vim.api.nvim_create_namespace("tmux-oil-preview")
local group = vim.api.nvim_create_augroup("TmuxOil", { clear = true })

-- Single buffer: { buf, state, rendered, own_id, own_session, popup, show_cwd }
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

local function load()
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
    parts[#parts + 1] = string.format("%d untouched", #plan.untouched)
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
  local ok, report = apply.apply(plan, tmux, S.own_id, S.own_session)
  ui.notify(report_text(ok, report), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  for _, h in ipairs(report.leftover_holds or {}) do
    local sess = S.state.by_id[h.session_id]
    ui.notify(string.format("placeholder window %s left in session %s — close it by hand",
      h.window_id, sess and sess.name or h.session_id), vim.log.levels.WARN)
  end
  load()
end

local function write()
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
  if M.config.skip_confirm then
    run_plan(plan)
  else
    ui.confirm(plan, fresh, function(yes)
      if yes then
        run_plan(plan)
      end
    end)
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
  local _, err = tmux.run({ "switch-client", "-t", id })
  if err then
    ui.notify(err, vim.log.levels.ERROR)
  elseif S.popup then
    vim.bo[S.buf].modified = false -- the discard was confirmed above
    local ok, qerr = pcall(vim.cmd, "qa") -- other modified buffers block instead of being lost
    if not ok then
      ui.notify(tostring(qerr), vim.log.levels.ERROR)
    end
  end
end

local function quit()
  if not discard_ok() then
    return
  end
  if S.popup then
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
      load()
    end
  end, "reload")
  map("gc", toggle_cwd, "toggle cwd")
  map("gt", copy_title, "copy title")
  map("g?", ui.help, "help")
end

local function set_autocmds(buf)
  local function au(events, fn)
    vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, callback = fn })
  end
  au("BufWriteCmd", write)
  au({ "TextChanged", "TextChangedI" }, function()
    redraw_marks(buf)
    preview()
  end)
  au("BufWipeout", function()
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
end

local function create_buffer()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "tmux-oil://")
  for opt, v in pairs({ buftype = "acwrite", bufhidden = "wipe", swapfile = false,
    filetype = "tmux-oil" }) do
    vim.bo[buf][opt] = v
  end
  vim.api.nvim_set_hl(0, "TmuxOilSession", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "TmuxOilAnchor", { link = "Conceal", default = true })
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
  load()
end

M._state = function() return S end
M._report_text = report_text

return M
