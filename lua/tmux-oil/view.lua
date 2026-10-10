-- state -> lines + extmark specs (pure) and draw helpers. design-v2 §1, §3.
local M = {}

local AGENT = { icon = "󰚩", hl = "TmuxOilAgent", ascii = "ai" }
local SSH = { icon = "󰣀", hl = "DiagnosticWarn", ascii = "ssh" }
local TOP = { icon = "", hl = "Comment", ascii = "top" }

-- Exact pane_current_command -> { key = <devicons extension key> } or { icon, hl, ascii }.
M.PROGRAMS = {}
local function add(cmds, entry)
  for _, c in ipairs(cmds) do
    M.PROGRAMS[c] = entry
  end
end
add({ "claude", "claude.exe", "codex", "opencode", "aider", "pi", "gemini", "amp", "goose", "crush",
  "copilot" }, AGENT)
for _, sh in ipairs({ "zsh", "bash", "sh", "fish" }) do
  M.PROGRAMS[sh] = { key = sh }
end
add({ "nvim", "vim", "vi" }, { key = "vim" })
add({ "python", "python3", "uv", "ipython" }, { key = "py" })
add({ "node", "bun", "deno", "npm", "pnpm", "yarn" }, { key = "js" })
add({ "go" }, { key = "go" })
add({ "cargo", "rustc" }, { key = "rs" })
add({ "lua" }, { key = "lua" })
add({ "git", "lazygit", "gh", "tig" }, { key = "git" })
add({ "docker", "docker-compose", "kubectl", "k9s" }, { key = "Dockerfile" })
add({ "make", "cmake", "ninja" }, { key = "Makefile" })
add({ "tail", "less", "journalctl" }, { key = "log" })
add({ "tmux" }, { key = "tmux" })
add({ "ssh", "mosh" }, SSH)
add({ "htop", "btop", "top" }, TOP)

-- Static Nerd Font glyphs, used when nvim-web-devicons is absent or lacks the key.
M.GLYPHS = {
  zsh = "", bash = "", sh = "", fish = "", vim = "", py = "", js = "", go = "",
  rs = "", lua = "", git = "", Dockerfile = "󰡨", Makefile = "", log = "󰌱", tmux = "",
}

-- icons = "ascii" codes by devicons key.
M.ASCII = {
  zsh = "sh", bash = "sh", sh = "sh", fish = "sh", vim = "vi", py = "py", js = "js", go = "go",
  rs = "rs", lua = "lua", git = "git", Dockerfile = "dk", Makefile = "mk", log = "log", tmux = "tm",
}
local ASCII_WIDTH = 3

-- Returns the icon glyph/code and its highlight group, or nil when the command has no icon.
local function icon_for(cmd, cfg)
  local entry = (cfg.icon_map or {})[cmd] or M.PROGRAMS[cmd]
  if type(entry) == "string" then
    entry = { icon = entry, hl = "Special" }
  end
  if not entry then
    return nil
  end
  if cfg.icons == "ascii" then
    return entry.ascii or M.ASCII[entry.key] or entry.icon, "Comment"
  end
  if entry.icon then
    return entry.icon, entry.hl or "Special"
  end
  local ok, dev = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = dev.get_icon(entry.key, entry.key, { default = false })
    if icon then
      return icon, hl or "Special"
    end
  end
  return M.GLYPHS[entry.key], "Special"
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
    local icon, hl = icon_for(w.command, cfg)
    if icon then
      if cfg.icons == "ascii" then
        icon = icon .. (" "):rep(ASCII_WIDTH - vim.fn.strdisplaywidth(icon))
      end
      chunks[#chunks + 1] = { icon .. " ", hl }
    else -- unknown command: keep the column width so names stay aligned
      chunks[1][1] = chunks[1][1] .. (" "):rep((cfg.icons == "ascii" and ASCII_WIDTH or 1) + 1)
    end
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
