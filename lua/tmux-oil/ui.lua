-- confirm float, help float, notifications. design-v2 §2, §3.
local M = {}

function M.notify(msg, level)
  vim.notify("tmux-oil: " .. msg, level or vim.log.levels.INFO)
end

local function name_of(state, id)
  local o = state.by_id[id]
  return o and o.name or "?"
end

local function anchor_text(m)
  if m.after then
    return "after " .. m.after
  elseif type(m.before) == "table" then
    return "before placeholder of " .. m.before.hold
  elseif m.before then
    return "before " .. m.before
  elseif m.after_new then
    return "after new #" .. m.after_new
  end
  return "before new #" .. tostring(m.before_new)
end

-- oil style: an uppercase verb column, then the subject.
local function verb(v, rest)
  return string.format("%-8s%s", v, rest)
end

local function kill_line(k, state)
  if k.kind == "session" then
    local s = state.by_id[k.id]
    local n = k.windows or (s and #s.windows) or 0
    return verb("KILL", string.format('session %s "%s"  (%d window%s)', k.id, k.name, n,
      n == 1 and "" or "s"))
  end
  -- A title equal to the host name is the shell's default: not information, hide it like the view does.
  local title = (k.title ~= "" and k.title ~= state.host) and k.title or nil
  local detail = title and (title .. ", ") or ""
  return verb("KILL", string.format('%s "%s"  (%s%d pane%s)', k.id, k.name, detail,
    k.panes or 0, (k.panes or 0) == 1 and "" or "s"))
end

-- Order: what dies first, then edits, then creations and moves, then what is left alone.
function M.plan_lines(plan, state)
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  for _, k in ipairs(plan.kills) do
    add(kill_line(k, state))
  end
  for _, e in ipairs(plan.ends or {}) do
    add(verb("END", string.format('session %s "%s"  (all windows moved out)', e.id, e.name)))
  end
  for _, r in ipairs(plan.renames) do
    add(verb("RENAME", string.format('%s "%s" → "%s"', r.id, name_of(state, r.id), r.name)))
  end
  for _, a in ipairs(plan.autos) do
    add(verb("AUTO", a.id .. "  (automatic-rename on)"))
  end
  for _, r in ipairs(plan.session_renames) do
    add(verb("RENAME", string.format('session %s "%s" → "%s"', r.id, name_of(state, r.id), r.name)))
  end
  for _, n in ipairs(plan.news) do
    add(verb("CREATE", string.format('"%s" in %s', n.name, n.session_id)))
  end
  for _, m in ipairs(plan.moves) do
    local line = m.id .. " → " .. anchor_text(m)
    if state.session_of[m.id] ~= m.session_id then
      line = line .. " → session " .. m.session_id
    end
    add(verb("MOVE", line))
  end
  for _, id in ipairs(plan.untouched) do
    add(verb("KEEP", id .. "  (not in buffer, left alone)"))
  end
  for _, id in ipairs(plan.vanished) do
    add(verb("GONE", id .. "  (already closed)"))
  end
  return out
end

local function open_float(lines, title, footer)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local available = vim.o.lines - vim.o.cmdheight
  local height = math.max(1, math.min(#lines, available - 2))
  -- zindex above a popup's own float title, like oil's confirmation window.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded", title = title, footer = footer,
    footer_pos = footer and "center" or nil, zindex = 152,
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.wo[win][0].cursorline = false
  vim.wo[win][0].wrap = false -- one action per line; a wrapped KILL line would hide the next action
  return buf, win
end

-- Non-blocking, oil's keys: y Y o O -> cb(true); n N c C q <C-c> <Esc> -> cb(false). Closing any other way
-- (WinClosed / BufLeave) is cb(false). cb runs exactly once.
-- schedule_wrap: called from BufWriteCmd the float would not take focus (oil does the same).
M.confirm = vim.schedule_wrap(function(plan, state, cb)
  local lines = M.plan_lines(plan, state)
  local footer = " [Y]es  [N]o "
  local buf, win = open_float(lines, " tmux-oil will perform the following actions ", footer)
  vim.api.nvim_set_current_win(win)
  local finished = false
  local function finish(yes)
    if finished then
      return
    end
    finished = true
    pcall(vim.api.nvim_win_close, win, true)
    cb(yes)
  end
  local function map(lhs, yes)
    vim.keymap.set("n", lhs, function() finish(yes) end, { buffer = buf, nowait = true })
  end
  for _, k in ipairs({ "y", "Y", "o", "O" }) do
    map(k, true)
  end
  for _, k in ipairs({ "n", "N", "c", "C", "q", "<C-c>", "<Esc>" }) do
    map(k, false)
  end
  -- Window changes are not allowed inside these events: cancel now, close after.
  local function lost()
    if finished then
      return
    end
    finished = true
    vim.schedule(function() pcall(vim.api.nvim_win_close, win, true) end)
    cb(false)
  end
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = lost })
  vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = lost })
end)

M.HELP = {
  "<CR>  jump to the window/session on this line",
  "q     close (asks when modified)",
  "R     re-read tmux (asks when modified)",
  "gc    toggle cwd",
  "gt    copy this window's title into its name",
  "cc S  clear the name and retype it (the window is kept)",
  "0 ^ I go to the start of the name",
  "g?    this help",
  "",
  ":w    review and apply",
}

function M.help()
  local buf, win = open_float(M.HELP, " tmux-oil keys ")
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, k in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
