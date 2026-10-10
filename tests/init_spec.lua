local oil = require("tmux-oil")
local tmux = require("tmux-oil.tmux")
local ui = require("tmux-oil.ui")

local SOCK = "tmux-oil-uifix"

local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. "\n  ~=\n" .. vim.inspect(b))
end

local function t(...)
  local out, err = tmux.run({ ... })
  assert(out, err)
  return out
end

local function kill_server()
  vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
end

local function with_buffer(fn)
  oil.setup({ socket = SOCK })
  kill_server()
  local ok, err = pcall(function()
    t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
    t("new-window", "-d", "-t", "a:", "-n", "two")
    t("new-window", "-d", "-t", "a:")
    oil.open()
    fn(oil._state())
  end)
  pcall(vim.cmd, "bwipeout!")
  kill_server()
  oil.config.socket = nil
  tmux.socket = nil
  assert(ok, err)
end

local function marks_by_line(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("tmux-oil"), 0, -1, {})) do
    out[m[2] + 1] = out[m[2] + 1] or {}
    table.insert(out[m[2] + 1], m[3])
  end
  return out
end

return {
  { "marks follow the ids after ddp", function()
    with_buffer(function(S)
      local before = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      eq(#before, 4)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd("normal! ddp")
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = S.buf })
      local after = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      eq(after[2], before[3])
      eq(after[3], before[2])
      local ns = vim.api.nvim_create_namespace("tmux-oil")
      for lnum = 2, 3 do
        local id = after[lnum]:match("^(@%d+)")
        local idx = S.state.by_id[id].index
        local found = false
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(S.buf, ns, { lnum - 1, 0 }, { lnum - 1, -1 },
          { details = true })) do
          local vt = m[4].virt_text
          if vt and vt[1][1] == string.format("  %2d ", idx) then
            found = true
          end
        end
        assert(found, "line " .. lnum .. " lost its index mark for " .. id)
      end
    end)
  end },
  { "prefix mark stays at the anchor column when text is prepended to the name", function()
    with_buffer(function(S)
      local lnum
      for i, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
        if l:match("^@%d+ $") then
          lnum = i
        end
      end
      assert(lnum, "no empty-name line")
      local anchor = vim.api.nvim_buf_get_lines(S.buf, lnum - 1, lnum, false)[1]
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_feedkeys("Axyz", "nx", false)
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = S.buf })
      local ns = vim.api.nvim_create_namespace("tmux-oil")
      local cols = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(S.buf, ns, { lnum - 1, 0 }, { lnum - 1, -1 },
        { details = true })) do
        if m[4].virt_text_pos == "inline" and m[4].virt_text[1][2] == "Comment"
          and m[4].virt_text[1][1]:match("^%s+%d+ $") then
          cols[#cols + 1] = m[3]
        end
      end
      eq(cols, { #anchor })
    end)
  end },
  { "lines without a known id get no marks", function()
    with_buffer(function(S)
      vim.api.nvim_buf_set_lines(S.buf, -1, -1, false, { "brand new", "@999 ghost" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = S.buf })
      local by = marks_by_line(S.buf)
      eq(by[5], nil)
      eq(by[6], nil)
    end)
  end },
  { "preview: parse errors keep rename marks, drop kill summary", function()
    with_buffer(function(S)
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      -- delete a window line (a kill), rename another, and duplicate an id (parse error)
      local one = lines[2]:match("^(@%d+)")
      local two = lines[3]:match("^(@%d+)")
      vim.api.nvim_buf_set_lines(S.buf, 0, -1, false,
        { lines[1], one .. " ONE", two .. " two", two .. " dup" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = S.buf })
      local ns = vim.api.nvim_create_namespace("tmux-oil-preview")
      local texts = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(S.buf, ns, 0, -1, { details = true })) do
        for _, key in ipairs({ "virt_text", "virt_lines" }) do
          local vt = m[4][key]
          if vt then
            texts[#texts + 1] = vim.inspect(vt)
          end
        end
      end
      local all = table.concat(texts, "\n")
      assert(all:find("duplicate id"), all)
      assert(all:find("rename"), all)
      assert(not all:find("killed"), all)
    end)
  end },
  { "open() on a modified buffer asks before reloading", function()
    with_buffer(function(S)
      vim.api.nvim_buf_set_lines(S.buf, -1, -1, false, { "extra" })
      vim.bo[S.buf].modified = true
      local asked = 0
      local orig = vim.fn.confirm
      vim.fn.confirm = function() asked = asked + 1; return 2 end
      oil.open()
      eq(asked, 1)
      eq(vim.api.nvim_buf_get_lines(S.buf, -2, -1, false)[1], "extra")
      vim.fn.confirm = function() asked = asked + 1; return 1 end
      oil.open()
      vim.fn.confirm = orig
      eq(asked, 2)
      assert(vim.api.nvim_buf_get_lines(S.buf, -2, -1, false)[1] ~= "extra")
    end)
  end },
  { "window options are buffer-scoped", function()
    with_buffer(function(S)
      eq(vim.wo.conceallevel, 3)
      vim.cmd("enew")
      eq(vim.wo.conceallevel, 0)
    end)
  end },
  { "report_text stringifies table argv elements", function()
    local txt = oil._report_text(false, { done = 1, skipped = 0, failed = { cmd = { "kill-window", "-t", { hold = "$1" } }, err = "x" } })
    assert(txt:find('hold = "$1"', 1, true), txt)
  end },
  { "confirm: order, keys, and cb exactly once", function()
    local plan = { renames = { { id = "@1", name = "n" } }, autos = {}, session_renames = {}, news = {},
      moves = {}, kills = { { id = "@2", kind = "window", name = "b", panes = 1 } }, ends = {},
      untouched = { "@9" }, vanished = {} }
    local state = { by_id = { ["@1"] = { name = "a" } }, session_of = {} }
    local lines = ui.plan_lines(plan, state)
    assert(lines[1]:find("kill"), lines[1])
    assert(lines[#lines]:find("untouched"))
    local function run(keys)
      local calls = {}
      local before = #vim.api.nvim_list_wins()
      ui.confirm(plan, state, function(y) calls[#calls + 1] = y end)
      eq(#calls, 0) -- non-blocking
      local win = vim.api.nvim_get_current_win()
      local cfg = vim.api.nvim_win_get_config(win)
      assert(cfg.footer, "footer")
      eq(vim.bo.bufhidden, "wipe")
      eq(vim.bo.modifiable, false)
      if keys then
        vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
      else
        vim.cmd("wincmd p")
      end
      vim.wait(50)
      eq(#vim.api.nvim_list_wins(), before)
      return calls
    end
    eq(run("y"), { true })
    eq(run("n"), { false })
    eq(run("q"), { false })
    eq(run("<Esc>"), { false })
    eq(run(nil), { false })
  end },
}
