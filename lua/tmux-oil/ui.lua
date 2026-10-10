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

local function kill_line(k, state)
  if k.kind == "session" then
    local s = state.by_id[k.id]
    local n = k.windows or (s and #s.windows) or 0
    return string.format('✗ kill session %s "%s" — %d window%s', k.id, k.name, n,
      n == 1 and "" or "s")
  end
  local detail = (k.title and k.title ~= "") and (k.title .. ", ") or ""
  return string.format('✗ kill %s "%s" — %s%d panes', k.id, k.name, detail, k.panes or 0)
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
    add(string.format('✗ session %s "%s" ends (all windows moved out)', e.id, e.name))
  end
  for _, r in ipairs(plan.renames) do
    add(string.format('✎ rename %s "%s" → "%s"', r.id, name_of(state, r.id), r.name))
  end
  for _, a in ipairs(plan.autos) do
    add(string.format("✎ auto %s (automatic-rename on)", a.id))
  end
  for _, r in ipairs(plan.session_renames) do
    add(string.format('✎ session %s "%s" → "%s"', r.id, name_of(state, r.id), r.name))
  end
  for _, n in ipairs(plan.news) do
    add(string.format('+ new "%s" in %s', n.name, n.session_id))
  end
  for _, m in ipairs(plan.moves) do
    local line = "↕ move " .. m.id .. " → " .. anchor_text(m)
    if state.session_of[m.id] ~= m.session_id then
      line = line .. " → session " .. m.session_id
    end
    add(line)
  end
  for _, id in ipairs(plan.untouched) do
    add("· untouched: " .. id)
  end
  for _, id in ipairs(plan.vanished) do
    add("· vanished: " .. id)
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
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded", title = title, footer = footer,
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
  return buf, win
end

-- Non-blocking: y -> cb(true); n / q / <Esc> -> cb(false). Closing the float any other way
-- (WinClosed / BufLeave) is cb(false). cb runs exactly once.
function M.confirm(plan, state, cb)
  local lines = M.plan_lines(plan, state)
  local footer = " y: apply   n/q/<Esc>: cancel "
  local buf, win = open_float(lines, " tmux-oil ", footer)
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
  map("y", true)
  for _, k in ipairs({ "n", "q", "<Esc>" }) do
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
end

M.HELP = {
  "<CR>  jump to the window/session on this line",
  "q     close (asks when modified)",
  "R     re-read tmux (asks when modified)",
  "gc    toggle cwd",
  "gt    copy this window's title into its name",
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
