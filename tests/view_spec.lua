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
    eq(on.virt_text[2][1], view.ICONS.claude .. " ")
    local cfg = vim.tbl_extend("force", CFG, { icons = false })
    local off = find(select(2, view.render(sample(), cfg)), 2, "inline")[1]
    eq(#off.virt_text, 1)
  end },
  { "icon_map overrides the fixed table", function()
    local cfg = vim.tbl_extend("force", CFG, { icon_map = { claude = "C" } })
    local m = find(select(2, view.render(sample(), cfg)), 2, "inline")[1]
    eq(m.virt_text[2][1], "C ")
  end },
  { "title mark skipped when empty or equal to host", function()
    local _, marks = view.render(sample(), CFG)
    eq(#find(marks, 2, "eol"), 1)
    eq(find(marks, 2, "eol")[1].virt_text[1][1], "✳ work")
    eq(#find(marks, 3, "eol"), 0) -- title == host
    eq(#find(marks, 4, "eol"), 0) -- empty title
  end },
  { "cwd mark only when show_cwd, with ~ substitution", function()
    eq(#find(select(2, view.render(sample(), CFG)), 4, "eol"), 0)
    local cfg = vim.tbl_extend("force", CFG, { show_cwd = true })
    local eols = find(select(2, view.render(sample(), cfg)), 4, "eol")
    eq(eols[1].virt_text[1][1], "~/proj")
    eq(find(select(2, view.render(sample(), cfg)), 3, "eol")[1].virt_text[1][1], "/tmp")
  end },
}
