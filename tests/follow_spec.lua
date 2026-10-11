-- Integration: real attached clients on an isolated server. follow moves the popup's client,
-- q restores it and every session follow passed through; a second client is never moved.
local oil = require("tmux-oil")
local tmux = require("tmux-oil.tmux")

local SOCK = "tmux-oil-follow"

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

local function clients()
  return t("list-clients", "-F", "#{client_session}:#{window_id}")
end

local function current(sess)
  return t("display-message", "-p", "-t", sess .. ":", "#{window_id}")
end

-- Attaches a client to `sess` through a pty; returns the job so the whole group can be killed.
local function attach(sess, n)
  local n0 = #vim.split(tmux.run({ "list-clients" }) or "", "\n", { trimempty = true })
  local job = vim.system({ "sh", "-c",
    "sleep 30 | script -q /dev/null tmux -L " .. SOCK .. " attach -t " .. sess },
    { env = { TERM = "xterm-256color" }, detach = true })
  assert(vim.wait(3000, function()
    return #vim.split(tmux.run({ "list-clients" }) or "", "\n", { trimempty = true }) == n
  end, 50), "client did not attach")
  return job
end

local function kill(job)
  if job and job.pid then
    pcall(vim.uv.kill, -job.pid, "sigterm")
  end
end

local function line_of(S, id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
    if l:match("^([$@]%d+)") == id then
      return i
    end
  end
end

local function follow_to(S, id)
  vim.api.nvim_win_set_cursor(0, { line_of(S, id), 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = S.buf })
end

local function press(key)
  local orig_cmd = vim.cmd
  vim.cmd = function(c) if c == "qa" then return end return orig_cmd(c) end
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
  vim.cmd = orig_cmd
end

-- Server: a = one two three (current: one), b = bee buzz (current: bee). Client 1 on a.
local function with_server(fn)
  if vim.fn.executable("script") == 0 then
    return
  end
  oil.setup({ socket = SOCK, preview_delay = 0, follow_cursor = true })
  kill_server()
  local env = vim.env.TMUX
  local jobs = {}
  local ok, err = pcall(function()
    t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
    t("new-window", "-d", "-t", "a:", "-n", "two")
    t("new-window", "-d", "-t", "a:", "-n", "three")
    t("new-session", "-d", "-s", "b", "-n", "bee", "-x", "80", "-y", "24")
    t("new-window", "-d", "-t", "b:", "-n", "buzz")
    jobs[1] = attach("a", 1)
    vim.env.TMUX = "x"
    fn(jobs)
  end)
  vim.env.TMUX = env
  pcall(vim.cmd, "bwipeout!")
  kill_server()
  for _, j in ipairs(jobs) do
    kill(j)
  end
  oil.config.socket, oil.config.follow_cursor = nil, false
  tmux.socket = nil
  assert(ok, err)
end

return {
  { "follow: moves the client, q restores it", function()
    with_server(function()
      local origin = clients()
      oil.open({ popup = true })
      local S = oil._state()
      assert(S.client and S.client ~= "", "client name not resolved")
      local bee = current("b")
      follow_to(S, bee)
      eq(clients(), "b:" .. bee)
      press("q")
      eq(clients(), origin)
    end)
  end },
  { "follow: q also restores the other session's current window", function()
    with_server(function()
      local origin, bee = clients(), current("b")
      local a_two = t("display-message", "-p", "-t", "a:two", "#{window_id}")
      local b_buzz = t("display-message", "-p", "-t", "b:buzz", "#{window_id}")
      oil.open({ popup = true })
      local S = oil._state()
      follow_to(S, a_two)
      follow_to(S, b_buzz)
      eq(current("b"), b_buzz)
      press("q")
      eq(clients(), origin)
      eq(current("b"), bee)
    end)
  end },
  { "follow: restore finds the origin window after :w moved it to another session", function()
    with_server(function()
      local origin_id = current("a")
      oil.open({ popup = true })
      local S = oil._state()
      local buzz = t("display-message", "-p", "-t", "b:buzz", "#{window_id}")
      follow_to(S, buzz)
      -- Move origin's line under buzz (origin sits above buzz, so buzz shifts up by one).
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      local o = table.remove(lines, line_of(S, origin_id))
      table.insert(lines, line_of(S, buzz), o)
      vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
      oil.config.skip_confirm = true
      vim.cmd("write")
      oil.config.skip_confirm = false
      eq(S.state.session_of[origin_id], t("display-message", "-p", "-t", "b:", "#{session_id}"))
      press("q")
      eq(clients(), "b:" .. origin_id)
    end)
  end },
  { "follow: the visited session can be emptied, the origin session cannot", function()
    with_server(function()
      local origin = clients()
      oil.open({ popup = true })
      local S = oil._state()
      local bee = current("b")
      follow_to(S, bee)
      local function cut(sess)
        local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
        local kept = {}
        for _, l in ipairs(lines) do
          local id = l:match("^([$@]%d+)")
          if not (id == sess or (id and S.state.session_of[id] == sess)) then
            kept[#kept + 1] = l
          end
        end
        vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, kept)
      end
      local msgs = {}
      local ui = require("tmux-oil.ui")
      local orig_notify = ui.notify
      ui.notify = function(m) msgs[#msgs + 1] = m end
      oil.config.skip_confirm = true
      local rendered = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      cut(S.state.session_of[S.origin.window])
      vim.cmd("write")
      assert(vim.tbl_filter(function(m) return m:find("cannot empty attached session a", 1, true) end, msgs)[1],
        vim.inspect(msgs))
      vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, rendered)
      cut(S.state.session_of[bee])
      vim.cmd("write")
      ui.notify, oil.config.skip_confirm = orig_notify, false
      assert(t("list-sessions", "-F", "#{session_name}") == "a", vim.inspect(msgs))
      eq(clients(), origin) -- restored before b died
    end)
  end },
  { "follow: a second client is never moved, even when the popup's client is gone", function()
    with_server(function(jobs)
      jobs[2] = attach("b", 2)
      local before = clients()
      oil.open({ popup = true })
      local S = oil._state()
      local three = t("display-message", "-p", "-t", "a:three", "#{window_id}")
      follow_to(S, three)
      -- The popup's terminal dies: restore runs with that client already gone.
      kill(jobs[1])
      assert(vim.wait(3000, function()
        return #vim.split(clients(), "\n", { trimempty = true }) == 1
      end, 50), "client 1 did not detach")
      press("q")
      eq(clients(), before:match("\n(.*)$")) -- client 2 still on b:bee
    end)
  end },
}
