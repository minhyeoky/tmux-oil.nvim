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
    return "before placeholder of " .. (m.before.hold or "new session")
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
  local new_sessions = plan.new_sessions or {}
  for _, s in ipairs(new_sessions) do
    add(verb("CREATE", string.format('session "%s"', s.name)))
  end
  for _, n in ipairs(plan.news) do
    local where = n.session_new and ('new session "' .. new_sessions[n.session_new].name .. '"')
      or n.session_id
    add(verb("CREATE", string.format('"%s" in %s', n.name, where)))
  end
  for _, m in ipairs(plan.moves) do
    local line = m.id .. " → " .. anchor_text(m)
    if m.session_new then
      line = line .. ' → new session "' .. new_sessions[m.session_new].name .. '"'
    elseif state.session_of[m.id] ~= m.session_id then
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

-- titles: the first that fits is used. The float is as wide as its widest line and its first
-- title, up to the editor; a popup is sized to the buffer, not to the plan, so a longer line
-- wraps, its continuation shifted by `shift` columns, and the height counts the wrapped rows.
-- Returns buf, win and whether the rows did not fit (the float then scrolls, see M.confirm).
local function open_float(lines, titles, footer, shift)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 2, vim.fn.strdisplaywidth(titles[1])), vim.o.columns - 4)
  local title = titles[#titles]
  for _, t in ipairs(titles) do
    if vim.fn.strdisplaywidth(t) <= width then
      title = t
      break
    end
  end
  -- zindex above a popup's own float title, like oil's confirmation window.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded", title = title, footer = footer,
    footer_pos = footer and "center" or nil, zindex = 152,
    width = width, height = 1, row = 0, col = 0,
  })
  vim.wo[win][0].cursorline = false
  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  vim.wo[win][0].breakindent = true
  vim.wo[win][0].breakindentopt = "shift:" .. shift
  vim.wo[win][0].smoothscroll = true
  local rows = vim.api.nvim_win_text_height(win, {}).all
  local height = math.max(1, math.min(rows, vim.o.lines - vim.o.cmdheight - 2))
  vim.api.nvim_win_set_config(win, {
    relative = "editor", height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
  return buf, win, rows > height
end

-- Screen rows a key scrolls a confirm float by; "half" is half its height, like <C-d>.
-- "\5" "\25" "\4" "\21" are <C-e> <C-y> <C-d> <C-u>.
local SCROLL = {
  j = 1, k = -1, ["\5"] = 1, ["\25"] = -1, ["\4"] = "half", ["\21"] = "-half",
  [vim.keycode("<Down>")] = 1, [vim.keycode("<Up>")] = -1,
}

-- Scrolls win by screen rows (smoothscroll is on, so one action taller than the float can be
-- read to its end), never past the view that shows the last row at the bottom.
local function scroll(win, rows)
  local height = vim.api.nvim_win_get_height(win)
  if rows == "half" or rows == "-half" then
    rows = (rows == "half" and 1 or -1) * math.max(1, math.floor(height / 2))
  end
  if rows > 0 then
    local v = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    local below = vim.api.nvim_win_text_height(win, { start_row = v.topline - 1, start_vcol = v.skipcol }).all
    rows = math.min(rows, below - height)
  end
  if rows ~= 0 then
    local cmd = rows > 0 and "\5" or "\25"
    vim.api.nvim_win_call(win, function() vim.cmd("normal! " .. math.abs(rows) .. cmd) end)
  end
end

-- Blocks until one of oil's keys is read: y Y o O -> cb(true); n N c C q <C-c> <Esc> -> cb(false).
-- SCROLL keys scroll a float taller than the editor; other keys are ignored. Reading keys here
-- instead of mapping them in the float keeps the whole `:w` inside BufWriteCmd, so `:wq` and
-- `:x` apply and then quit like on any file.
function M.confirm(plan, state, cb)
  local lines = M.plan_lines(plan, state)
  local _, win, scrolls = open_float(lines,
    { " tmux-oil will perform the following actions ", " tmux-oil " }, " [Y]es  [N]o ", 8) -- 8: verb
  if scrolls then
    vim.api.nvim_win_set_config(win, { footer = " [Y]es  [N]o  j/k scroll ", footer_pos = "center" })
  end
  -- :wq/:x set nvim's `exiting` flag before the write, and while it is set window redraws are
  -- dropped: `redraw` leaves the float blank. `mode` clears and repaints the whole screen.
  vim.cmd("mode")
  local yes
  while yes == nil do
    local ok, c = pcall(vim.fn.getcharstr) -- <C-c> raises an interrupt
    if not ok or c == "\27" or c == "\3" or c:match("^[nNcCq]$") then
      yes = false
    elseif c:match("^[yYoO]$") then
      yes = true
    elseif scrolls and SCROLL[c] then
      scroll(win, SCROLL[c])
      vim.cmd("mode")
    end
  end
  pcall(vim.api.nvim_win_close, win, true)
  vim.schedule(function() vim.cmd("redraw!") end) -- after `mode` + cancel the buffer stays blank
  cb(yes)
end

M.HELP = {
  "<CR>  jump to the window/session on this line",
  "q     close (asks when modified)",
  "R     re-read tmux (asks when modified)",
  "gc    toggle cwd",
  "gt    copy this window's title into its name",
  "cc S  clear the name and retype it (the window is kept)",
  "0 ^ I go to the start of the name",
  "name/  create a session (lines below it go in)",
  "g?    this help",
  "",
  ":w    review and apply (:wq, :x then close)",
}

function M.help()
  local buf, win = open_float(M.HELP, { " tmux-oil keys " }, nil, 6) -- 6: the key column
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, k in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
