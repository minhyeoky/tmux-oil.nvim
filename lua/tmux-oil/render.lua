-- Everything that redraws the buffer, incl. the live plan: marks, cursor placement, load, preview.
local tmux = require("tmux-oil.tmux")
local parse = require("tmux-oil.parse")
local diff = require("tmux-oil.diff")
local view = require("tmux-oil.view")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")

local M = {}

local ns = vim.api.nvim_create_namespace("tmux-oil")
local ns_preview = vim.api.nvim_create_namespace("tmux-oil-preview")

local function view_cfg()
  return vim.tbl_extend("force", config.values, { show_cwd = state.S.show_cwd, host = state.S.state and state.S.state.host })
end

-- Marks come from the buffer text as it is now: every line whose anchor names a known id gets
-- that object's marks at that line's own positions. Other lines get none.
-- reserved[lnum] = cells a preview mark takes on that line; the title shrinks to leave them.
local function redraw_marks(buf, reserved)
  if not state.S or not state.S.state or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = view_cfg()
  local marks = {}
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or nil
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local kind, id = parse.classify(line)
    local obj = kind and id and state.S.state.by_id[id]
    if obj then
      local avail = nil
      if width and reserved and reserved[i] then
        avail = width - 1 - reserved[i] -- 1: the gap nvim draws before eol text
      end
      vim.list_extend(marks, view.marks_for(line, i, obj, cfg, avail))
    end
  end
  view.apply_marks(buf, ns, marks)
end

-- Puts the cursor on the line anchored by target.id (first column of the name). Not found:
-- target.line clamped to the buffer, or untouched when target.line is nil.
local function place_cursor(target)
  local win = vim.fn.bufwinid(state.S.buf)
  if win == -1 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.S.buf, 0, -1, false)
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
  local fresh_state, err = tmux.read()
  if not fresh_state then
    ui.notify("cannot read tmux: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local lines, _, ids = view.render(fresh_state, view_cfg())
  state.S.state, state.S.rendered = fresh_state, ids
  view.draw(state.S.buf, lines, {}, ns)
  redraw_marks(state.S.buf)
  vim.api.nvim_buf_clear_namespace(state.S.buf, ns_preview, 0, -1)
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
    elseif r.kind == "newsession" then
      marks[#marks + 1] = { lnum = r.lnum, col = 0, pos = "eol",
        virt_text = { { "+ new session", "DiagnosticOk" } } }
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
    if m.session_new then
      eol(m.id, "→ new session " .. plan.new_sessions[m.session_new].name, "DiagnosticHint")
    elseif state.S.state.session_of[m.id] ~= m.session_id then
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

-- nvim draws virtual lines above line 1 only once the view is scrolled up into them, so the
-- summary at the top would stay hidden: scroll it into view in every window showing line 1.
-- Without a summary the row goes again; nvim drops it by itself only in the current window.
local function reveal_summary(buf, shown)
  local fill = shown and 1 or 0
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function()
      local v = vim.fn.winsaveview()
      if v.topline == 1 and v.topfill ~= fill then
        vim.fn.winrestview({ topfill = fill })
      end
    end)
  end
end

local preview_timer = nil -- a pending debounced refresh, or nil

local function preview()
  if not state.S or not vim.api.nvim_buf_is_valid(state.S.buf) then
    return
  end
  local rows, errors = parse.parse(vim.api.nvim_buf_get_lines(state.S.buf, 0, -1, false))
  local marks = error_marks(errors)
  local plan, perrs = diff.compute(rows, state.S.state, state.S.rendered)
  if plan then
    vim.list_extend(marks, plan_marks(rows, plan, #errors > 0))
  else
    vim.list_extend(marks, error_marks(perrs))
  end
  -- The popup is sized to the lines without marks. nvim draws eol marks in creation order,
  -- so a preview mark lands before the title (or session info) and that text gives up the
  -- mark's cells, cut with "…" at the edge; on a line with nothing to cut, the launcher's own
  -- reserve covers the mark.
  local reserved = {}
  for _, m in ipairs(marks) do
    if m.pos == "eol" then
      local wdt = 1 -- the gap before the mark
      for _, c in ipairs(m.virt_text) do
        wdt = wdt + vim.fn.strdisplaywidth(c[1])
      end
      reserved[m.lnum] = (reserved[m.lnum] or 0) + wdt
    end
  end
  redraw_marks(state.S.buf, reserved)
  view.apply_marks(state.S.buf, ns_preview, marks)
  local shown = false
  for _, m in ipairs(marks) do
    shown = shown or (m.lnum == 1 and m.above == true)
  end
  reveal_summary(state.S.buf, shown)
end

-- Marks + preview, once, now. Cancels a pending debounced refresh.
local function refresh_now()
  if preview_timer then
    preview_timer:stop()
    preview_timer:close()
    preview_timer = nil
  end
  if state.S then
    preview() -- redraws the base marks too, with room for the preview marks
  end
end

-- Edits restart one timer; both run once when typing pauses.
local function refresh_soon()
  local delay = config.values.preview_delay or 0
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

function M.cancel()
  if preview_timer then
    preview_timer:stop()
    preview_timer:close()
    preview_timer = nil
  end
end

M.ns_preview = ns_preview
M.redraw_marks = redraw_marks
M.load = load
M.error_marks = error_marks
M.refresh_now = refresh_now
M.refresh_soon = refresh_soon

return M
