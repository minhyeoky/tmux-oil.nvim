-- Integration: a real attached client on an isolated server follows the cursor, restores on q.
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

local function client_window()
  return t("display-message", "-p", "-t", "a:", "#{window_id}") and
    t("list-clients", "-F", "#{client_session}:#{window_id}")
end

return {
  { "follow with an attached client: moves the client, q restores it", function()
    if vim.fn.executable("script") == 0 then
      return
    end
    oil.setup({ socket = SOCK, preview_delay = 0, follow_cursor = true })
    kill_server()
    local env = vim.env.TMUX
    local attach
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
      t("new-window", "-d", "-t", "a:", "-n", "two")
      t("new-window", "-d", "-t", "a:", "-n", "three")
      t("new-session", "-d", "-s", "b", "-n", "bee")
      attach = vim.system({ "sh", "-c",
        "sleep 30 | script -q /dev/null tmux -L " .. SOCK .. " attach -t a" }, { env = { TERM = "xterm-256color" } })
      assert(vim.wait(3000, function()
        return (tmux.run({ "list-clients" })) ~= "" and (tmux.run({ "list-clients" })) ~= nil
      end, 50), "client did not attach")
      local origin = client_window()
      vim.env.TMUX = "x"
      oil.open({ popup = true })
      local S = oil._state()
      local function line_of(id)
        for i, l in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
          if l:match("^([$@]%d+)") == id then
            return i
          end
        end
      end
      local bee = t("display-message", "-p", "-t", "b:", "#{window_id}")
      vim.api.nvim_win_set_cursor(0, { line_of(bee), 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = S.buf })
      eq(client_window(), "b:" .. bee)
      local orig_cmd = vim.cmd
      vim.cmd = function(c) if c == "qa" then return end return orig_cmd(c) end
      vim.api.nvim_feedkeys("q", "x", false)
      vim.cmd = orig_cmd
      eq(client_window(), origin)
    end)
    vim.env.TMUX = env
    pcall(vim.cmd, "bwipeout!")
    kill_server() -- detaches the client, which ends script; the sleep dies on SIGPIPE
    oil.config.socket, oil.config.follow_cursor = nil, false
    tmux.socket = nil
    assert(ok, err)
  end },
}
