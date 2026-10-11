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

local function with_buffer(fn, before, opts_for_open)
  oil.setup({ socket = SOCK, preview_delay = 0 })
  kill_server()
  local ok, err = pcall(function()
    t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
    t("new-window", "-d", "-t", "a:", "-n", "two")
    t("new-window", "-d", "-t", "a:")
    if before then
      before()
    end
    oil.open(opts_for_open)
    fn(oil._state())
  end)
  pcall(vim.cmd, "bwipeout!")
  kill_server()
  oil.config.socket = nil
  oil.config.follow_cursor, oil.config.follow_delay = false, 0
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

-- Stubs the client identity ($TMUX set, display-message answers) and records every
-- non-read tmux command. Returns the call log and a restore function.
local function stub_client(window, session)
  local orig_run, orig_env = tmux.run, vim.env.TMUX
  local calls = {}
  vim.env.TMUX = "stub"
  tmux.run = function(args)
    if args[1] == "display-message" and #args == 3 then
      if args[3] == "#{window_id}" then
        return window, nil
      elseif args[3] == "#{session_id}" then
        return session, nil
      elseif args[3] == "#{client_name}" then
        return "/dev/ttys9", nil
      end
      -- #{pid} and the rest go to the real server: the restart guard stays armed
    end
    local verb = args[1]
    if verb == "select-window" or verb == "switch-client" then
      calls[#calls + 1] = table.concat(args, " ")
      return "", nil -- never move a real client
    end
    return orig_run(args)
  end
  return calls, function()
    tmux.run, vim.env.TMUX = orig_run, orig_env
  end
end

local function goto_line(S, lnum)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = S.buf })
end

local function line_of(S, id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    if l:match("^([$@]%d+)") == id then
      return i
    end
  end
end

local function follow_test(opts, popup, fn)
  local calls, restore = stub_client("@1", "$0")
  local ok, err = pcall(with_buffer, function(S)
    fn(S, calls)
  end, function()
    oil.config.follow_cursor = opts.follow
    oil.config.follow_delay = opts.delay or 0
  end, { popup = popup })
  restore()
  assert(ok, err)
end

return {
  { "open: cursor lands on the current window's line, at the name", function()
    local _, restore = stub_client("@1", "$0")
    local ok, err = pcall(with_buffer, function(S)
      local lnum = line_of(S, "@1")
      eq(vim.api.nvim_win_get_cursor(0), { lnum, #"@1 " })
      eq(lnum, 3)
    end)
    restore()
    assert(ok, err)
  end },
  { "open: cursor on line 1 when the window id is unknown or TMUX is unset", function()
    local _, restore = stub_client("@999", "$0")
    local ok, err = pcall(with_buffer, function(S)
      eq(vim.api.nvim_win_get_cursor(0)[1], 1)
    end)
    restore()
    assert(ok, err)
    with_buffer(function(S) -- vim.env.TMUX unset by the runner? force it
      eq(vim.api.nvim_win_get_cursor(0)[1], 1)
    end, function() vim.env.TMUX = nil end)
  end },
  { "R keeps the cursor on the same anchor id, else the same clamped line", function()
    local _, restore = stub_client("@0", "$0")
    local ok, err = pcall(with_buffer, function(S)
      -- move line 2 (@0) below line 4 so the id's line changes, then reload after a real reorder
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local id = vim.api.nvim_get_current_line():match("^(@%d+)")
      t("swap-window", "-d", "-s", "a:1", "-t", "a:2")
      vim.api.nvim_feedkeys("R", "x", false)
      local lnum = line_of(S, id)
      eq(vim.api.nvim_win_get_cursor(0)[1], lnum)
      -- id gone: line number kept
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      local gone = vim.api.nvim_get_current_line():match("^(@%d+)")
      t("kill-window", "-t", gone)
      vim.api.nvim_feedkeys("R", "x", false)
      eq(vim.api.nvim_win_get_cursor(0)[1], 3) -- clamped to the new last line
    end)
    restore()
    assert(ok, err)
  end },
  { "follow: window lines switch-client, session lines do nothing, no repeats", function()
    follow_test({ follow = true }, true, function(S, calls)
      goto_line(S, 1) -- session line
      goto_line(S, 3) -- origin window (@1): already followed
      eq(calls, {})
      goto_line(S, 2)
      goto_line(S, 2)
      eq(calls, { "switch-client -c /dev/ttys9 -t " .. S.state.sessions[1].windows[1].id })
      goto_line(S, 1)
      eq(#calls, 1)
      goto_line(S, 4)
      goto_line(S, 2)
      eq(#calls, 3)
      local anchorless = vim.api.nvim_buf_set_lines(S.buf, -1, -1, false, { "brand new" })
      goto_line(S, 5)
      eq(#calls, 3)
    end)
  end },
  { "follow: switch-client first when the window is in another session", function()
    local calls, restore = stub_client("@1", "$0")
    local ok, err = pcall(with_buffer, function(S)
      t("new-session", "-d", "-s", "b", "-n", "bee")
      vim.api.nvim_feedkeys("R", "x", false)
      local bee = t("display-message", "-p", "-t", "b:", "#{window_id}")
      local bsess = t("display-message", "-p", "-t", "b:", "#{session_id}")
      goto_line(S, line_of(S, bee))
      eq(calls, { "switch-client -c /dev/ttys9 -t " .. bee })
      eq(S.touched[bsess], bee) -- b's current window, remembered for restore
    end, function()
      oil.config.follow_cursor = true
    end, { popup = true })
    restore()
    assert(ok, err)
  end },
  { "follow: no effect without popup or without the option", function()
    follow_test({ follow = true }, false, function(S, calls)
      goto_line(S, 2)
      eq(calls, {})
    end)
    follow_test({ follow = false }, true, function(S, calls)
      goto_line(S, 2)
      eq(calls, {})
    end)
  end },
  { "follow: follow_delay debounces", function()
    follow_test({ follow = true, delay = 30 }, true, function(S, calls)
      goto_line(S, 2)
      goto_line(S, 4)
      eq(calls, {})
      vim.wait(200, function() return #calls > 0 end)
      eq(calls, { "switch-client -c /dev/ttys9 -t " .. S.state.sessions[1].windows[3].id })
    end)
  end },
  { "follow: quit restores the origin, jump does not", function()
    follow_test({ follow = true }, true, function(S, calls)
      goto_line(S, 2)
      eq(#calls, 1)
      local orig_cmd = vim.cmd
      vim.cmd = function(c) if c == "qa" then return end return orig_cmd(c) end
      vim.api.nvim_feedkeys("q", "x", false)
      vim.cmd = orig_cmd
      eq(calls[2], "switch-client -c /dev/ttys9 -t @1")
      eq(#calls, 2)
      eq(oil._state().follow_last, "@1") -- idempotent: a second restore issues nothing
    end)
    follow_test({ follow = true }, true, function(S, calls)
      goto_line(S, 2)
      local orig_cmd = vim.cmd
      vim.cmd = function(c) if c == "qa" then return end return orig_cmd(c) end
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      vim.cmd = orig_cmd
      eq(calls, { "switch-client -c /dev/ttys9 -t " .. S.state.sessions[1].windows[1].id,
        "switch-client -c /dev/ttys9 -t " .. S.state.sessions[1].windows[1].id })
      eq(oil._state().confirmed, true)
    end)
  end },
  { "follow: BufWipeout without a jump restores", function()
    follow_test({ follow = true }, true, function(S, calls)
      goto_line(S, 4)
      vim.cmd("bwipeout!")
      eq(calls[#calls], "switch-client -c /dev/ttys9 -t @1")
    end)
  end },
  { "follow: apply restores first when the followed window is killed", function()
    follow_test({ follow = true }, true, function(S, calls)
      goto_line(S, 4)
      eq(#calls, 1)
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(S.buf, 3, 4, false, {}) -- delete the followed window's line
      oil.config.skip_confirm = true
      local orig = vim.fn.confirm
      vim.cmd("write")
      oil.config.skip_confirm = false
      vim.fn.confirm = orig
      eq(calls[2], "switch-client -c /dev/ttys9 -t @1")
    end)
  end },
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
          if vt and vt[1][1] == string.format("%2d ", idx) then
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
        if m[4].virt_text_pos == "inline" and m[4].virt_text[1][2] == "TmuxOilIndex"
          and m[4].virt_text[1][1]:match("^%s*%d+ $") then
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
    vim.o.number, vim.o.relativenumber, vim.o.list, vim.o.signcolumn = true, true, true, "yes"
    with_buffer(function(S)
      eq(vim.wo.conceallevel, 3)
      eq(vim.wo.number, false)
      eq(vim.wo.relativenumber, false)
      eq(vim.wo.list, false)
      eq(vim.wo.signcolumn, "no")
      vim.cmd("enew")
      eq(vim.wo.conceallevel, 0)
      eq(vim.wo.number, true)
      eq(vim.wo.relativenumber, true)
      eq(vim.wo.list, true)
      eq(vim.wo.signcolumn, "yes")
    end)
    vim.o.number, vim.o.relativenumber, vim.o.list, vim.o.signcolumn = false, false, false, "auto"
  end },
  { "I on an empty name appends after the concealed space", function()
    with_buffer(function(S)
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      local lnum
      for n, l in ipairs(lines) do
        if l:match("^@%d+ ?$") then lnum = n break end
      end
      assert(lnum, "no empty-name window line in fixture")
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_feedkeys(vim.keycode("IX<Esc>"), "x", false)
      local line = vim.api.nvim_buf_get_lines(S.buf, lnum - 1, lnum, false)[1]
      local kind, id, name = require("tmux-oil.parse").classify(line)
      eq(kind, "window")
      eq(name, "X")
    end)
  end },
  { "report_text stringifies table argv elements", function()
    local txt = oil._report_text(false, { done = 1, skipped = 0, failed = { cmd = { "kill-window", "-t", { hold = "$1" } }, err = "x" } })
    assert(txt:find('hold = "$1"', 1, true), txt)
  end },
  { ":wq applies after y and closes the window", function()
    with_buffer(function(S)
      vim.cmd("split") -- :wq closes this window, not nvim
      local wins = #vim.api.nvim_list_wins()
      local id = S.state.sessions[1].windows[1].id
      vim.api.nvim_buf_set_lines(S.buf, 1, 2, false, { id .. " renamed" })
      vim.api.nvim_feedkeys("y", "n", false)
      vim.cmd("wq")
      eq(#vim.api.nvim_list_wins(), wins - 1)
      eq(t("display-message", "-p", "-t", id, "#{window_name}"), "renamed")
    end)
  end },
  { "confirm: order, keys, and cb exactly once", function()
    local plan = { renames = { { id = "@1", name = "n" } }, autos = {}, session_renames = {}, news = {},
      moves = {}, kills = { { id = "@2", kind = "window", name = "b", panes = 1 } }, ends = {},
      untouched = { "@9" }, vanished = {} }
    local state = { by_id = { ["@1"] = { name = "a" } }, session_of = {} }
    local lines = ui.plan_lines(plan, state)
    assert(lines[1]:find("KILL"), lines[1])
    assert(lines[#lines]:find("KEEP"))
    local function run(keys)
      local calls = {}
      local before = #vim.api.nvim_list_wins()
      vim.api.nvim_feedkeys(vim.keycode(keys), "n", false) -- typeahead for getcharstr
      ui.confirm(plan, state, function(y) calls[#calls + 1] = y end)
      eq(#calls, 1) -- blocking: answered before it returns
      eq(#vim.api.nvim_list_wins(), before)
      return calls
    end
    eq(run("y"), { true })
    eq(run("n"), { false })
    eq(run("q"), { false })
    eq(run("<Esc>"), { false })
    eq(run("xjY"), { true }) -- unmapped keys are skipped
  end },
  { "insert-mode preview is debounced by preview_delay; 0 is synchronous; normal-mode edits are immediate", function()
    local function has_rename(buf)
      local ns = vim.api.nvim_create_namespace("tmux-oil-preview")
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        for _, c in ipairs(m[4].virt_text or {}) do
          if c[1]:find("rename", 1, true) then
            return true
          end
        end
      end
      return false
    end
    local function type_name(S, event)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys("$xx", "nx", false)
      vim.api.nvim_exec_autocmds(event, { buffer = S.buf }) -- headless feedkeys does not fire it
    end
    with_buffer(function(S)
      oil.config.preview_delay = 40
      type_name(S, "TextChangedI")
      assert(not has_rename(S.buf), "preview ran before the delay")
      vim.wait(100, function() return has_rename(S.buf) end)
      assert(has_rename(S.buf), "preview missing after the delay")
    end)
    with_buffer(function(S)
      oil.config.preview_delay = 40
      type_name(S, "TextChanged") -- normal-mode edits (dd, p, J) refresh at once
      assert(has_rename(S.buf), "normal-mode edit was debounced")
    end)
    with_buffer(function(S)
      oil.config.preview_delay = 0
      type_name(S, "TextChangedI")
      assert(has_rename(S.buf), "preview not synchronous with delay 0")
    end)
  end },
}
