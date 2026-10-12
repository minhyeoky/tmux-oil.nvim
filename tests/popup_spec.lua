local SOCK = "tmux-oil-popup"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function t(...)
  local r = vim.system({ "tmux", "-L", SOCK, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
end

local function run(env)
  return vim.system({ root .. "/bin/tmux-oil-popup", "--print" }, { text = true, env = env, clear_env = true }):wait()
end

-- A fake tmux on PATH prints the display-popup argv instead of running it.
local function popup_argv(flags)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local real = vim.fn.exepath("tmux")
  vim.fn.writefile({ "#!/bin/sh", 'case "$*" in *display-popup*) printf "%s\\n" "$@"; exit 0;; esac',
    'exec "' .. real .. '" "$@"' }, dir .. "/tmux")
  vim.fn.setfperm(dir .. "/tmux", "rwxr-xr-x")
  local r = vim.system(vim.list_extend({ root .. "/bin/tmux-oil-popup" }, flags),
    { text = true, clear_env = true, env = { TMUX_OIL_SOCKET = SOCK, PATH = dir .. ":" .. vim.env.PATH,
      HOME = vim.env.HOME } }):wait()
  assert(r.code == 0, r.stderr)
  return vim.split(r.stdout, "\n", { trimempty = false })
end

local function has(list, ...)
  local want = { ... }
  for i = 1, #list - #want + 1 do
    local all = true
    for j, w in ipairs(want) do
      if list[i + j - 1] ~= w then
        all = false
      end
    end
    if all then
      return true
    end
  end
  return false
end

return {
  { "popup --border/--border-style/--title map to display-popup flags", function()
    vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "work", "-n", "one", "-x", "80", "-y", "24")
      local a = popup_argv({})
      assert(has(a, "-T", " tmux-oil ") and not has(a, "-b") and not has(a, "-s"), vim.inspect(a))
      a = popup_argv({ "--border", "none", "--title", "" })
      assert(has(a, "-b", "none") and not has(a, "-T"), vim.inspect(a))
      a = popup_argv({ "--border-style", "fg=red", "--title", "x" })
      assert(has(a, "-S", "fg=red") and has(a, "-T", "x"), vim.inspect(a))
      a = popup_argv({ "--title", "#S" })
      assert(has(a, "-T", "##S"), vim.inspect(a))
      local r = vim.system({ root .. "/bin/tmux-oil-popup", "--border", "dotted" },
        { text = true, clear_env = true, env = { TMUX_OIL_SOCKET = SOCK, PATH = vim.env.PATH } }):wait()
      assert(r.code ~= 0 and r.stderr:find("invalid choice", 1, true), r.stderr)
    end)
    vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
    assert(ok, err)
  end },
  { "popup --print: rows and cols fit the content", function()
    vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "work", "-n", "one", "-x", "80", "-y", "24")
      t("new-window", "-d", "-t", "work:", "-n", "두번째 창")
      t("select-pane", "-t", "work:두번째 창", "-T", "a title")
      t("new-session", "-d", "-s", "다른", "-n", "x")
      t("new-window", "-d", "-t", "다른:", "-n", "ssh box")
      t("select-pane", "-t", "다른:ssh box", "-T", "✳ 리서치 노트 진행 상황 정리")
      t("select-pane", "-t", "work:one", "-T", "")
      t("select-pane", "-t", "다른:x", "-T", "")
      t("split-window", "-d", "-t", "다른:ssh box") -- 2 panes: " ⊞2" joins the line
      -- windows: {name, title}; sessions: {name, count}
      local w = vim.fn.strdisplaywidth
      -- active windows carry " ●", 2+ panes " ⊞N"; after the gap comes the title or, when the
      -- title is shorter, room for the widest preview mark ("→ session $N")
      local mark = w("→ session ") + 2
      local longest = math.max(
        w("work") + 1 + w("  2 windows · attached"),
        w("다른") + 1 + w("  2 windows · attached"),
        1 + 3 + 2 + w("두번째 창") + 0 + 1 + math.max(w("a title"), mark),
        1 + 3 + 2 + w("ssh box") + 3 + 1 + math.max(w("✳ 리서치 노트 진행 상황 정리"), mark), -- ⊞2
        1 + 3 + 2 + w("one") + 2 + 1 + mark, -- active, no title: the mark needs its own room
        1 + 3 + 2 + w("x") + 2 + 1 + mark)
      assert(longest > 38, "fixture must exceed the 40-col floor")
      -- clear_env: vim.system merges env with the parent's, so TMUX would survive `env.TMUX = nil`.
      local env = { TMUX_OIL_SOCKET = SOCK, PATH = vim.env.PATH, HOME = vim.env.HOME }
      local r = run(env)
      assert(r.code == 0, r.stderr)
      -- rows: 2 sessions + 4 windows + 1 gap + border 2 + cmdline 1 + headroom 2
      assert(vim.trim(r.stdout) == string.format("%d %d", 2 + 4 + 1 + 2 + 1 + 2, 2 + 1 + math.max(longest, 37)),
        "got " .. r.stdout .. " longest " .. longest)
    end)
    vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
    assert(ok, err)
  end },
}
