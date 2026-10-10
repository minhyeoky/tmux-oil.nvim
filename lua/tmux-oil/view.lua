-- state -> lines + extmark specs (pure) and draw helpers. design-v2 §1, §3.
local M = {}

M.ICONS = {
  claude = "󰚩",
  nvim = "",
  vim = "",
  zsh = "",
  bash = "",
  fish = "",
  python = "",
  python3 = "",
  node = "",
  ssh = "󰣀",
  git = "",
  htop = "",
  cat = "",
}
M.DEFAULT_ICON = ""

local function icon_for(cmd, cfg)
  local map = vim.tbl_extend("force", M.ICONS, cfg.icon_map or {})
  return map[cmd] or M.DEFAULT_ICON
end

local function shorten_home(path, home)
  if home and home ~= "" then
    if path == home then
      return "~"
    elseif path:sub(1, #home + 1) == home .. "/" then
      return "~" .. path:sub(#home + 1)
    end
  end
  return path
end

-- Marks for one buffer line, derived from that line's text (never from render-time positions).
-- obj is the session or window the line's anchor names; cfg.host is tmux's #{host}.
function M.marks_for(line, lnum, obj, cfg)
  local marks = {}
  if obj.windows then -- session
    marks[1] = { lnum = lnum, col = 0, line_hl = "TmuxOilSession" }
    local n = #obj.windows
    local tag = string.format("%d window%s%s", n, n == 1 and "" or "s", obj.attached and " · attached" or "")
    marks[2] = { lnum = lnum, col = #line, virt_text = { { "  " .. tag, "TmuxOilSessionInfo" } },
      pos = "eol" }
    if lnum > 1 then -- a blank rule between sessions instead of indenting their windows
      marks[3] = { lnum = lnum, col = 0, virt_lines = { { { "", "NonText" } } }, above = true }
    end
    return marks
  end
  local w = obj
  local anchor_len = #(line:match("^[$@]%d+ ?") or "")
  local chunks = { { string.format("%s%2d ", (" "):rep(cfg.indent or 0), w.index or 0), "TmuxOilIndex" } }
  if cfg.icons ~= false then
    chunks[#chunks + 1] = { icon_for(w.command, cfg) .. " ", "Special" }
  end
  marks[#marks + 1] = { lnum = lnum, col = anchor_len, virt_text = chunks, pos = "inline",
    right_gravity = false }
  local post = {}
  if w.active then
    post[#post + 1] = { " ●", "DiagnosticOk" }
  end
  if (w.panes or 1) >= 2 then
    post[#post + 1] = { " ⊞" .. w.panes, "Comment" }
  end
  if #post > 0 then
    marks[#marks + 1] = { lnum = lnum, col = #line, virt_text = post, pos = "inline" }
  end
  if w.title and w.title ~= "" and w.title ~= cfg.host then
    marks[#marks + 1] = { lnum = lnum, col = #line, virt_text = { { w.title, "Comment" } },
      pos = "eol" }
  end
  if cfg.show_cwd and w.cwd and w.cwd ~= "" then
    marks[#marks + 1] = { lnum = lnum, col = #line,
      virt_text = { { shorten_home(w.cwd, cfg.home), "NonText" } }, pos = "eol" }
  end
  return marks
end

-- Returns lines, marks, rendered_ids. Marks are marks_for() of the rendered lines; a live
-- buffer recomputes them from its current text (init.lua redraw_marks).
function M.render(state, cfg)
  cfg = vim.tbl_extend("force", cfg, { host = state.host or cfg.host })
  local lines, marks, ids = {}, {}, {}
  for _, s in ipairs(state.sessions) do
    lines[#lines + 1] = s.id .. " " .. s.name
    ids[s.id] = true
    vim.list_extend(marks, M.marks_for(lines[#lines], #lines, s, cfg))
    for _, w in ipairs(s.windows) do
      -- §1: auto-rename windows render an empty name, so the line is exactly "@N "
      lines[#lines + 1] = w.id .. " " .. (w.auto_rename and "" or w.name)
      ids[w.id] = true
      vim.list_extend(marks, M.marks_for(lines[#lines], #lines, w, cfg))
    end
  end
  return lines, marks, ids
end

-- Replaces all marks in ns. Spec fields: lnum, col, virt_text, pos, line_hl, virt_lines, above.
function M.apply_marks(buf, ns, marks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  for _, m in ipairs(marks) do
    if m.lnum >= 1 and m.lnum <= count then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.lnum - 1, m.col or 0, {
        virt_text = m.virt_text,
        virt_text_pos = m.pos,
        line_hl_group = m.line_hl,
        virt_lines = m.virt_lines,
        virt_lines_above = m.above,
        right_gravity = m.right_gravity,
        strict = false,
      })
    end
  end
end

-- Not undoable, leaves the buffer unmodified.
function M.draw(buf, lines, marks, ns)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = ul
  vim.bo[buf].modified = false
  M.apply_marks(buf, ns, marks)
end

return M
