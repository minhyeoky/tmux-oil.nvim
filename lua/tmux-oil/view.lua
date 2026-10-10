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

local function window_marks(w, lnum, line, anchor_len, cfg, marks)
  local pre = string.format("  %2d ", w.index or 0)
  local chunks = { { pre, "Comment" } }
  if cfg.icons ~= false then
    chunks[#chunks + 1] = { icon_for(w.command, cfg) .. " ", "Special" }
  end
  marks[#marks + 1] = { lnum = lnum, col = anchor_len, virt_text = chunks, pos = "inline" }
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
  if w.title and w.title ~= "" and w.title ~= cfg.hostname then
    marks[#marks + 1] = { lnum = lnum, col = #line, virt_text = { { w.title, "Comment" } },
      pos = "eol" }
  end
  if cfg.show_cwd and w.cwd and w.cwd ~= "" then
    marks[#marks + 1] = { lnum = lnum, col = #line,
      virt_text = { { shorten_home(w.cwd, cfg.home), "NonText" } }, pos = "eol" }
  end
end

-- Returns lines, marks, rendered_ids.
function M.render(state, cfg)
  local lines, marks, ids = {}, {}, {}
  for _, s in ipairs(state.sessions) do
    lines[#lines + 1] = s.id .. " " .. s.name
    ids[s.id] = true
    marks[#marks + 1] = { lnum = #lines, col = 0, line_hl = "TmuxOilSession" }
    for _, w in ipairs(s.windows) do
      local anchor = w.id .. " "
      -- §1: auto-rename windows render an empty name, so the line is exactly "@N "
      local line = anchor .. (w.auto_rename and "" or w.name)
      lines[#lines + 1] = line
      ids[w.id] = true
      window_marks(w, #lines, line, #anchor, cfg, marks)
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
