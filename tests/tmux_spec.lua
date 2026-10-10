local tmux = require("tmux-oil.tmux")

local SOCK = "tmux-oil-test"

local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. "\n  ~=\n" .. vim.inspect(b))
end

local function t(...)
  local out, err = tmux.run({ ... })
  assert(out, err)
  return out
end

local function cleanup()
  vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
end

return {
  { "read() builds the state tree from an isolated server", function()
    tmux.socket = SOCK
    cleanup()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "alpha", "-n", "교정 | 집필", "-x", "80", "-y", "24")
      t("set-option", "-w", "-t", "alpha:0", "automatic-rename", "off")
      t("split-window", "-d", "-t", "alpha:0")
      t("new-window", "-d", "-t", "alpha:", "-n", "plain")
      t("set-option", "-w", "-t", "alpha:1", "automatic-rename", "off")
      t("new-session", "-d", "-s", "beta")
      t("set-option", "-w", "-t", "beta:0", "automatic-rename", "on")
      local st = assert(tmux.read())
      eq(#st.sessions, 2)
      local a, b = st.sessions[1], st.sessions[2]
      eq({ a.name, b.name }, { "alpha", "beta" })
      assert(a.id:match("^%$%d+$") and b.id:match("^%$%d+$"))
      eq(a.attached, false)
      eq(#a.windows, 2)
      local w1, w2, w3 = a.windows[1], a.windows[2], b.windows[1]
      eq(w1.name, "교정 | 집필")
      eq(w1.panes, 2)
      eq(w1.auto_rename, false)
      eq(w1.index, 0)
      eq(w2.name, "plain")
      eq(w2.index, 1)
      eq(w2.panes, 1)
      eq(w3.auto_rename, true)
      for _, w in ipairs({ w1, w2, w3 }) do
        assert(w.id:match("^@%d+$"), w.id)
        eq(st.by_id[w.id], w)
        assert(type(w.command) == "string" and w.command ~= "")
        assert(type(w.cwd) == "string" and w.cwd:sub(1, 1) == "/")
      end
      eq(st.session_of[w1.id], a.id)
      eq(st.session_of[w3.id], b.id)
      eq(st.by_id[a.id], a)
    end)
    cleanup()
    tmux.socket = nil
    assert(ok, err)
  end },
  { "read() reports tmux errors when no server runs", function()
    tmux.socket = SOCK
    cleanup()
    local st, err = tmux.read()
    tmux.socket = nil
    assert(st == nil and type(err) == "string" and err ~= "")
  end },
}
