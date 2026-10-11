local SOCK = "tmux-oil-popup"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function t(...)
  local r = vim.system({ "tmux", "-L", SOCK, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
end

local function run(env)
  return vim.system({ root .. "/bin/tmux-oil-popup", "--print" }, { text = true, env = env }):wait()
end

return {
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
      -- windows: {name, title}; sessions: {name, count}
      local w = vim.fn.strdisplaywidth
      local longest = math.max(
        w("work") + w("  2 windows · attached"),
        w("다른") + w("  2 windows · attached"),
        1 + 3 + 2 + w("두번째 창") + 2 + w("a title") + 4,
        1 + 3 + 2 + w("ssh box") + 2 + w("✳ 리서치 노트 진행 상황 정리") + 4,
        1 + 3 + 2 + w("one") + 2 + 0 + 4)
      assert(longest > 38, "fixture must exceed the 40-col floor")
      local env = vim.tbl_extend("force", vim.fn.environ(), { TMUX_OIL_SOCKET = SOCK })
      env.TMUX = nil
      local r = run(env)
      assert(r.code == 0, r.stderr)
      assert(vim.trim(r.stdout) == string.format("%d %d", 2 + 4 + 1 + 2, 2 + math.max(longest, 38)),
        "got " .. r.stdout .. " longest " .. longest)
    end)
    vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
    assert(ok, err)
  end },
}
