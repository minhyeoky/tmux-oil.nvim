local view = require("tmux-oil.view")
local parse = require("tmux-oil.parse").parse
local diff = require("tmux-oil.diff")

local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. "\n  ~=\n" .. vim.inspect(b))
end

local function win(id, index, name, o)
  o = o or {}
  return { id = id, index = index, name = name, active = o.active or false,
    panes = o.panes or 1, auto_rename = o.auto or false, command = o.command or "zsh",
    title = o.title or "", cwd = o.cwd or "/tmp" }
end

local function state_of(spec)
  local st = { sessions = {}, by_id = {}, session_of = {} }
  for _, s in ipairs(spec) do
    local sess = { id = s[1], name = s[2], attached = false, windows = s[3] }
    st.sessions[#st.sessions + 1] = sess
    st.by_id[sess.id] = sess
    for _, w in ipairs(sess.windows) do
      st.by_id[w.id] = w
      st.session_of[w.id] = sess.id
    end
  end
  return st
end

local CFG = { icons = true, icon_map = {}, show_cwd = false, host = "myhost", home = "/home/u" }

local function sample()
  return state_of({
    { "$0", "main", {
      win("@34", 1, "zsh", { auto = true, command = "claude", title = "✳ work", active = true }),
      win("@36", 2, "영상 🎬 제작", { panes = 2, title = "myhost" }),
      win("@37", 3, "교정 | 집필", { cwd = "/home/u/proj" }),
    } },
    { "$1", "second", { win("@15", 1, "x", { auto = true }) } },
  })
end

local function find(marks, lnum, pos)
  local out = {}
  for _, m in ipairs(marks) do
    if m.lnum == lnum and m.pos == pos then
      out[#out + 1] = m
    end
  end
  return out
end

return {
  { "render -> parse -> diff is empty", function()
    local st = sample()
    local lines, _, ids = view.render(st, CFG)
    eq(lines, { "$0 main", "@34 ", "@36 영상 🎬 제작", "@37 교정 | 집필", "$1 second", "@15 " })
    local rows, errs = parse(lines)
    eq(errs, {})
    local plan = diff.compute(rows, st, ids)
    assert(plan.empty, vim.inspect(plan))
    eq(ids["@34"] and ids["$1"] and ids["@15"], true)
  end },
  { "anchor mark col is the byte length of the anchor", function()
    local _, marks = view.render(sample(), CFG)
    local inline = find(marks, 2, "inline")
    eq(inline[1].col, #"@34 ")
    eq(inline[1].virt_text[1][1], " 1 ")
    local pre3 = find(marks, 3, "inline")[1]
    eq(pre3.col, #"@36 ")
    eq(find(marks, 3, "inline")[2].col, #"@36 영상 🎬 제작")
  end },
  { "active and pane-count marks", function()
    local _, marks = view.render(sample(), CFG)
    eq(find(marks, 2, "inline")[2].virt_text, { { " ●", "DiagnosticOk" } })
    eq(find(marks, 3, "inline")[2].virt_text, { { " ⊞2", "Comment" } })
  end },
  { "icon omitted when icons=false", function()
    local on = find(select(2, view.render(sample(), CFG)), 2, "inline")[1]
    eq(#on.virt_text, 2)
    local cfg = vim.tbl_extend("force", CFG, { icons = false })
    local off = find(select(2, view.render(sample(), cfg)), 2, "inline")[1]
    eq(#off.virt_text, 1)
    eq(off.virt_text[1][1], " 1 ")
  end },
  { "claude.exe -> agent glyph with TmuxOilAgent", function()
    local st = state_of({ { "$0", "m", { win("@1", 1, "a", { command = "claude.exe" }) } } })
    local m = find(select(2, view.render(st, CFG)), 2, "inline")[1]
    eq(m.virt_text[2], { "󰚩 ", "TmuxOilAgent" })
  end },
  { "unknown command: no icon chunk, padding keeps the name column aligned", function()
    local st = state_of({ { "$0", "m", {
      win("@1", 1, "a", { command = "claude" }), win("@2", 2, "b", { command = "mystery" }) } } })
    local marks = select(2, view.render(st, CFG))
    local known, unknown = find(marks, 2, "inline")[1], find(marks, 3, "inline")[1]
    eq(#unknown.virt_text, 1)
    local function width(m)
      local w = 0
      for _, c in ipairs(m.virt_text) do
        w = w + vim.fn.strdisplaywidth(c[1])
      end
      return w
    end
    eq(width(unknown), width(known))
    eq(unknown.virt_text[1][1], " 2   ")
  end },
  { "devicons absent -> static glyph with Special", function()
    package.loaded["nvim-web-devicons"] = nil
    local m = find(select(2, view.render(sample(), CFG)), 3, "inline")[1]
    eq(m.virt_text[2], { "\u{e795} ", "Special" })
  end },
  { "devicons present -> its icon and hl are used", function()
    package.loaded["nvim-web-devicons"] = { get_icon = function(name, ext, o)
      eq(o, { default = false })
      return "Z", "DevIconZsh"
    end }
    local ok, err = pcall(function()
      local m = find(select(2, view.render(sample(), CFG)), 3, "inline")[1]
      eq(m.virt_text[2], { "Z ", "DevIconZsh" })
    end)
    package.loaded["nvim-web-devicons"] = nil
    assert(ok, err)
  end },
  { "devicons returning nil falls back to the static glyph", function()
    package.loaded["nvim-web-devicons"] = { get_icon = function() return nil end }
    local ok, err = pcall(function()
      local m = find(select(2, view.render(sample(), CFG)), 3, "inline")[1]
      eq(m.virt_text[2], { "\u{e795} ", "Special" })
    end)
    package.loaded["nvim-web-devicons"] = nil
    assert(ok, err)
  end },
  { "icons=ascii: codes with equal widths, unknown padded", function()
    local st = state_of({ { "$0", "m", {
      win("@1", 1, "a", { command = "claude" }), win("@2", 2, "b", { command = "zsh" }),
      win("@3", 3, "c", { command = "ssh" }), win("@4", 4, "d", { command = "mystery" }) } } })
    local cfg = vim.tbl_extend("force", CFG, { icons = "ascii" })
    local marks = select(2, view.render(st, cfg))
    eq(find(marks, 2, "inline")[1].virt_text[2], { "ai  ", "Comment" })
    eq(find(marks, 3, "inline")[1].virt_text[2], { "sh  ", "Comment" })
    eq(find(marks, 4, "inline")[1].virt_text[2], { "ssh ", "Comment" })
    local u = find(marks, 5, "inline")[1]
    eq(#u.virt_text, 1)
    eq(u.virt_text[1][1], " 4     ")
  end },
  { "icon_map overrides by exact command", function()
    local cfg = vim.tbl_extend("force", CFG, { icon_map = { claude = "C" } })
    local m = find(select(2, view.render(sample(), cfg)), 2, "inline")[1]
    eq(m.virt_text[2], { "C ", "Special" })
    local st = state_of({ { "$0", "m", { win("@1", 1, "a", { command = "foo" }) } } })
    cfg = vim.tbl_extend("force", CFG, { icon_map = { foo = "X" } })
    eq(find(select(2, view.render(st, cfg)), 2, "inline")[1].virt_text[2], { "X ", "Special" })
    cfg.icon_map = { foo = { icon = "Y", hl = "Title" } }
    eq(find(select(2, view.render(st, cfg)), 2, "inline")[1].virt_text[2], { "Y ", "Title" })
    cfg.icon_map = { foo = { key = "go" } }
    eq(find(select(2, view.render(st, cfg)), 2, "inline")[1].virt_text[2], { view.GLYPHS.go .. " ", "Special" })
  end },
  { "title mark skipped when empty or equal to host", function()
    local _, marks = view.render(sample(), CFG)
    eq(#find(marks, 2, "eol"), 1)
    eq(find(marks, 2, "eol")[1].virt_text[1][1], "✳ work")
    eq(#find(marks, 3, "eol"), 0) -- title == host
    eq(#find(marks, 4, "eol"), 0) -- empty title
  end },
  { "title is cut to the cells left beside a preview mark", function()
    eq(view.cut("abcdef", nil), "abcdef")
    eq(view.cut("abcdef", 6), "abcdef")
    eq(view.cut("abcdef", 4), "abc…")
    eq(view.cut("한글제목", 5), "한글…") -- wide chars count 2
    eq(view.cut("abcdef", 1), nil)
    -- line 2: anchor concealed, index 3 + icon 2 + " ●" 2 = 7 cells; title "✳ work" (6)
    local st = sample()
    local w = st.by_id["@34"]
    local line = "@34 "
    local m = view.marks_for(line, 2, w, CFG, 7 + 6)
    eq(find(m, 2, "eol")[1].virt_text[1][1], "✳ work") -- fits exactly
    m = view.marks_for(line, 2, w, CFG, 7 + 4)
    eq(find(m, 2, "eol")[1].virt_text[1][1], "✳ w…")
    m = view.marks_for(line, 2, w, CFG, 7 + 1)
    eq(#find(m, 2, "eol"), 0) -- no room: title dropped, mark keeps its place
    -- session line: the "N windows · attached" info is cut the same way ("$0 " concealed, "main" 4)
    local sess = st.by_id["$0"]
    m = view.marks_for("$0 main", 1, sess, CFG, 4 + 2 + 7)
    eq(find(m, 1, "eol")[1].virt_text[1][1], "  3 wind…")
    m = view.marks_for("$0 main", 1, sess, CFG, nil)
    eq(find(m, 1, "eol")[1].virt_text[1][1], "  3 windows")
  end },
  { "cwd mark only when show_cwd, with ~ substitution", function()
    eq(#find(select(2, view.render(sample(), CFG)), 4, "eol"), 0)
    local cfg = vim.tbl_extend("force", CFG, { show_cwd = true })
    local eols = find(select(2, view.render(sample(), cfg)), 4, "eol")
    eq(eols[1].virt_text[1][1], "~/proj")
    eq(find(select(2, view.render(sample(), cfg)), 3, "eol")[1].virt_text[1][1], "/tmp")
  end },
  { "static glyphs are real single-cell Nerd Font codepoints", function()
    for k, g in pairs(view.GLYPHS) do
      assert(g ~= "", k .. " is empty")
      assert(vim.fn.char2nr(g) >= 0xE000, k .. " is not a private-use glyph")
      eq(vim.fn.strdisplaywidth(g), 1)
    end
  end },
  { "oversized or empty icon_map values keep the icon cell width", function()
    local st = state_of({ { "$0", "s", {
      { id = "@1", index = 1, name = "a", command = "foo", panes = 1 },
      { id = "@2", index = 2, name = "b", command = "bar", panes = 1 },
      { id = "@3", index = 3, name = "c", command = "zsh", panes = 1 },
    } } })
    local function width(cfg, lnum)
      local lines, marks = view.render(st, cfg)
      local total = 0
      for _, m in ipairs(marks) do
        if m.lnum == lnum and m.pos == "inline" and m.right_gravity == false then
          for _, c in ipairs(m.virt_text) do total = total + vim.fn.strdisplaywidth(c[1]) end
        end
      end
      return total
    end
    local cfg = vim.tbl_extend("force", CFG, { icon_map = { foo = "LONGER", bar = "" } })
    eq(width(cfg, 2), width(cfg, 4))
    eq(width(cfg, 3), width(cfg, 4))
    cfg.icons = "ascii"
    eq(width(cfg, 2), width(cfg, 4))
    eq(width(cfg, 3), width(cfg, 4))
  end },
  { "apply_marks: identical marks are not touched; a changed line replaces only its own", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "$0 a", "@1 one", "@2 two" })
    local ns = vim.api.nvim_create_namespace("view-spec-diff")
    local function marks(title)
      return {
        { lnum = 1, col = 0, line_hl = "TmuxOilSession" },
        { lnum = 2, col = 3, virt_text = { { " 1 ", "TmuxOilIndex" } }, pos = "inline",
          right_gravity = false },
        { lnum = 2, col = 6, virt_text = { { "t", "Comment" } }, pos = "eol" },
        { lnum = 3, col = 6, virt_text = { { title, "Comment" } }, pos = "eol" },
        { lnum = 3, col = 0, virt_lines = { { { "", "NonText" } } }, above = true },
      }
    end
    local sets, dels = 0, 0
    local set, del = vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark
    vim.api.nvim_buf_set_extmark = function(...) sets = sets + 1 return set(...) end
    vim.api.nvim_buf_del_extmark = function(...) dels = dels + 1 return del(...) end
    local ok, err = pcall(function()
      view.apply_marks(buf, ns, marks("x"))
      eq({ sets, dels }, { 5, 0 })
      sets, dels = 0, 0
      view.apply_marks(buf, ns, marks("x"))
      eq({ sets, dels }, { 0, 0 })
      view.apply_marks(buf, ns, marks("y"))
      eq({ sets, dels }, { 1, 1 })
      eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 5)
    end)
    vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark = set, del
    assert(ok, err)
    eq(view.mark_key(marks("x")[3]), view.mark_key(marks("x")[3]))
    assert(view.mark_key(marks("x")[3]) ~= view.mark_key(marks("y")[4]))
  end },
}
