local tmux = require("tmux-oil.tmux")
local apply = require("tmux-oil.apply")
local parse = require("tmux-oil.parse").parse
local diff = require("tmux-oil.diff")

local SOCK = "tmux-oil-apply"
local FMT = "#{session_name}:#{window_index} #{window_id} #{window_name} #{automatic-rename}"

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

-- "%name%" -> id of the initial server state
local function subst(s, ids)
  return (s:gsub("%%(%w+)%%", ids))
end

-- Initial state: a = {one, two, three} (manual names), b = {bee}. renumber-windows on keeps
-- indexes contiguous so listings are deterministic.
local function with_server(fn)
  tmux.socket = SOCK
  kill_server()
  local ok, err = pcall(function()
    t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
    t("set-option", "-g", "renumber-windows", "on")
    t("new-window", "-d", "-t", "a:", "-n", "two")
    t("new-window", "-d", "-t", "a:", "-n", "three")
    t("new-session", "-d", "-s", "b", "-n", "bee")
    local ids = {}
    for name, target in pairs({ one = "a:0", two = "a:1", three = "a:2", bee = "b:0" }) do
      t("set-option", "-w", "-t", target, "automatic-rename", "off")
      ids[name] = t("display-message", "-p", "-t", target, "#{window_id}")
    end
    ids.a = t("display-message", "-p", "-t", "a:", "#{session_id}")
    ids.b = t("display-message", "-p", "-t", "b:", "#{session_id}")
    fn(ids)
  end)
  kill_server()
  assert(ok, err)
end

local function listing()
  return t("list-windows", "-a", "-F", FMT)
end

local function plan_for(ids, lines)
  local l = {}
  for i, line in ipairs(lines) do
    l[i] = subst(line, ids)
  end
  local fresh = assert(tmux.read())
  local rows, errs = parse(l)
  eq(errs, {})
  local rendered = {}
  for id in pairs(fresh.by_id) do
    rendered[id] = true
  end
  local plan, perrs = diff.compute(rows, fresh, rendered)
  assert(plan, vim.inspect(perrs))
  return plan
end

local BASE_A = { "%a% a", "%one% one", "%two% two", "%three% three" }
local BASE_B = { "%b% b", "%bee% bee" }

local function lines_of(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    vim.list_extend(out, part)
  end
  return out
end

-- move-window leaves index gaps even with renumber-windows, so order-only cases drop ":index".
local function strip_index(s)
  return (s:gsub(":%d+ ", " "))
end

-- Applies the plan built from `lines`, asserts the listing equals `want` (ids substituted).
local function case(lines, want, noindex)
  with_server(function(ids)
    local ok, report = apply.apply(plan_for(ids, lines), tmux, nil, nil)
    assert(ok, vim.inspect(report))
    local got, exp = listing(), subst(table.concat(want, "\n"), ids)
    if noindex then
      got, exp = strip_index(got), strip_index(exp)
    end
    eq(got, exp)
  end)
end

local function empty_plan()
  return { renames = {}, autos = {}, session_renames = {}, news = {}, moves = {}, kills = {},
    untouched = {}, vanished = {} }
end

return {
  { "rename window and session", function()
    case({ "%a% alpha", "%one% ONE", "%two% two", "%three% three", "%b% b", "%bee% bee" }, {
      "alpha:0 %one% ONE 0", "alpha:1 %two% two 0", "alpha:2 %three% three 0",
      "b:0 %bee% bee 0" })
  end },
  { "empty name re-enables automatic-rename", function()
    with_server(function(ids)
      local plan = plan_for(ids, lines_of({ "%a% a", "%one% one", "%two% ", "%three% three" },
        BASE_B))
      assert(apply.apply(plan, tmux, nil, nil))
      eq(t("show-options", "-wv", "-t", ids.two, "automatic-rename"), "on")
    end)
  end },
  { "new window first / middle / end with names", function()
    case(lines_of({ "%a% a", "NEW", "%one% one", "%two% two", "%three% three" }, BASE_B), {
      "a:0 @4 NEW 0", "a:1 %one% one 0", "a:2 %two% two 0", "a:3 %three% three 0",
      "b:0 %bee% bee 0" }, true)
    case(lines_of({ "%a% a", "%one% one", "NEW", "%two% two", "%three% three" }, BASE_B), {
      "a:0 %one% one 0", "a:1 @4 NEW 0", "a:2 %two% two 0", "a:3 %three% three 0",
      "b:0 %bee% bee 0" })
    case(lines_of(BASE_A, { "NEW" }, BASE_B), {
      "a:0 %one% one 0", "a:1 %two% two 0", "a:2 %three% three 0", "a:3 @4 NEW 0",
      "b:0 %bee% bee 0" })
  end },
  { "new window without a name keeps automatic-rename 1", function()
    with_server(function(ids)
      local plan = plan_for(ids, lines_of({ "%a% a", "%one% one", "", "NEW2", "%two% two",
        "%three% three" }, BASE_B))
      -- blank line is ignored; make the unnamed one explicit
      plan.news[1].name = ""
      assert(apply.apply(plan, tmux, nil, nil))
      local out = listing()
      local second = vim.split(out, "\n")[2]
      assert(second:match("^a:1 @%d+ .+ 1$") or second:match("^a:1 @%d+ .+ on$"), out)
    end)
  end },
  { "reorder adjacent / to first / non-adjacent", function()
    case(lines_of({ "%a% a", "%two% two", "%one% one", "%three% three" }, BASE_B), {
      "a:0 %two% two 0", "a:1 %one% one 0", "a:2 %three% three 0", "b:0 %bee% bee 0" }, true)
    case(lines_of({ "%a% a", "%three% three", "%one% one", "%two% two" }, BASE_B), {
      "a:0 %three% three 0", "a:1 %one% one 0", "a:2 %two% two 0", "b:0 %bee% bee 0" }, true)
    case(lines_of({ "%a% a", "%two% two", "%three% three", "%one% one" }, BASE_B), {
      "a:0 %two% two 0", "a:1 %three% three 0", "a:2 %one% one 0", "b:0 %bee% bee 0" }, true)
  end },
  { "cross-session move", function()
    case({ "%a% a", "%one% one", "%three% three", "%b% b", "%bee% bee", "%two% two" }, {
      "a:0 %one% one 0", "a:1 %three% three 0", "b:0 %bee% bee 0", "b:1 %two% two 0" }, true)
    case({ "%a% a", "%one% one", "%three% three", "%b% b", "%two% two", "%bee% bee" }, {
      "a:0 %one% one 0", "a:1 %three% three 0", "b:0 %two% two 0", "b:1 %bee% bee 0" }, true)
  end },
  { "kill window and kill session", function()
    case(lines_of({ "%a% a", "%one% one", "%three% three" }, BASE_B), {
      "a:0 %one% one 0", "a:1 %three% three 0", "b:0 %bee% bee 0" })
    case(BASE_A, { "a:0 %one% one 0", "a:1 %two% two 0", "a:2 %three% three 0" })
  end },
  { "after_new resolves to the created window id", function()
    with_server(function(ids)
      local plan = empty_plan()
      plan.news = { { name = "N", session_id = ids.a, after = ids.one } }
      plan.moves = { { id = ids.three, session_id = ids.a, after_new = 1 } }
      local ok, report = apply.apply(plan, tmux, nil, nil)
      assert(ok, vim.inspect(report))
      eq(report.done, 2)
      eq(strip_index(listing()), strip_index(subst(table.concat({ "a:0 %one% one 0",
        "a:1 @4 N 0", "a:2 %three% three 0", "a:3 %two% two 0", "b:0 %bee% bee 0" }, "\n"),
        ids)))
    end)
  end },
  { "before_new resolves to the created window id", function()
    with_server(function(ids)
      local plan = empty_plan()
      plan.news = { { name = "N", session_id = ids.a, before = ids.one } }
      plan.moves = { { id = ids.three, session_id = ids.a, before_new = 1 } }
      assert(apply.apply(plan, tmux, nil, nil))
      eq(strip_index(listing()), strip_index(subst(table.concat({ "a:0 %three% three 0",
        "a:1 @4 N 0", "a:2 %one% one 0", "a:3 %two% two 0", "b:0 %bee% bee 0" }, "\n"),
        ids)))
    end)
  end },
  { "failure injection stops and reports", function()
    with_server(function(ids)
      local plan = plan_for(ids, lines_of({ "%a% a", "%one% ONE", "%two% TWO", "%three% THREE" },
        BASE_B))
      t("kill-window", "-t", ids.two) -- vanishes between plan and apply
      local ok, report = apply.apply(plan, tmux, nil, nil)
      eq(ok, false)
      eq(report.done, 1)
      eq(report.skipped, 1)
      eq(report.failed.cmd, { "rename-window", "-t", ids.two, "--", "TWO" })
      assert(report.failed.err and report.failed.err ~= "")
      eq(listing(), subst(table.concat({ "a:0 %one% ONE 0", "a:1 %three% three 0",
        "b:0 %bee% bee 0" }, "\n"), ids))
    end)
  end },
  { "own window / session is killed last", function()
    with_server(function(ids)
      local plan = plan_for(ids, lines_of({ "%a% a", "%three% three" }, BASE_B))
      local seen = {}
      local spy = { run = function(argv)
        seen[#seen + 1] = argv
        return tmux.run(argv)
      end }
      assert(apply.apply(plan, spy, ids.one, ids.a))
      eq(seen, { { "kill-window", "-t", ids.two }, { "kill-window", "-t", ids.one } })
    end)
    with_server(function(ids)
      local plan = plan_for(ids, lines_of({ "%a% a", "%one% one", "%two% two" }, {}))
      local seen = {}
      local spy = { run = function(argv)
        seen[#seen + 1] = argv
        return tmux.run(argv)
      end }
      assert(apply.apply(plan, spy, ids.three, ids.a))
      eq(seen[#seen], { "kill-window", "-t", ids.three })
    end)
  end },
  { "swap of two single-window sessions: placeholders created, used and removed", function()
    with_server(function(ids)
      t("kill-window", "-t", ids.two)
      t("kill-window", "-t", ids.three)
      local plan = plan_for(ids, { "%a% a", "%bee% bee", "%b% b", "%one% one" })
      eq(plan.holds, { [ids.a] = true, [ids.b] = true })
      local seen = {}
      local spy = { run = function(argv)
        local out, e = tmux.run(argv)
        seen[#seen + 1] = { argv = argv, out = out }
        return out, e
      end }
      local ok, report = apply.apply(plan, spy, nil, nil)
      assert(ok, vim.inspect(report))
      local created = {}
      for _, c in ipairs(seen) do
        if c.argv[1] == "new-window" then
          created[#created + 1] = c.out
        end
      end
      eq(#created, 2) -- exactly the two placeholders
      eq(report.done, #plan.moves + #plan.news + #plan.renames + #plan.kills) -- holds are invisible
      eq(report.skipped, 0)
      local killed = {}
      for _, c in ipairs(seen) do
        if c.argv[1] == "kill-window" then
          killed[c.argv[3]] = true
        end
      end
      for _, id in ipairs(created) do
        assert(killed[id], "placeholder " .. id .. " not removed")
      end
      eq(strip_index(listing()), strip_index(subst("a:0 %bee% bee 0\nb:0 %one% one 0", ids)))
    end)
  end },
  { "names go after -- and may start with a dash", function()
    with_server(function(ids)
      local plan = plan_for(ids, { "%a% -sess", "%one% -foo", "%two% two", "%three% three", "-baz",
        "%b% b", "%bee% bee" })
      local seen = {}
      local spy = { run = function(argv)
        seen[#seen + 1] = argv
        return tmux.run(argv)
      end }
      local ok, report = apply.apply(plan, spy, nil, nil)
      assert(ok, vim.inspect(report))
      eq(seen[1], { "rename-session", "-t", ids.a, "--", "-sess" })
      eq(seen[2], { "rename-window", "-t", ids.one, "--", "-foo" })
      eq(t("list-windows", "-a", "-F", "#{session_name}:#{window_name}"),
        "-sess:-foo\n-sess:two\n-sess:three\n-sess:-baz\nb:bee")
    end)
  end },
  { "server pid is present and changes after a restart", function()
    tmux.socket = SOCK
    kill_server()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-x", "80", "-y", "24")
      local p1 = assert(tmux.read()).server_pid
      assert(p1 and p1:match("^%d+$"))
      kill_server()
      t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-x", "80", "-y", "24")
      local p2 = assert(tmux.read()).server_pid
      assert(p2 ~= p1, p1 .. " == " .. p2)
    end)
    kill_server()
    assert(ok, err)
  end },
  { "# in names is literal (rename / session / new-window)", function()
    with_server(function(ids)
      local plan = plan_for(ids, { "%a% #S", "%one% issue #W done", "%two% two", "%three% three",
        "NEW #{window_id}", "%b% b", "%bee% bee" })
      local ok, report = apply.apply(plan, tmux, nil, nil)
      assert(ok, vim.inspect(report))
      eq(t("list-windows", "-a", "-F", "#{session_name}:#{window_name}"),
        "#S:issue #W done\n#S:two\n#S:three\n#S:NEW #{window_id}\nb:bee")
    end)
  end },
  { "failed apply leaves a placeholder that is its session's last window", function()
    tmux.socket = SOCK
    kill_server()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "main", "-x", "80", "-y", "24")
      t("new-window", "-d", "-t", "main:")
      t("new-window", "-d", "-t", "main:")
      t("new-session", "-d", "-s", "other")
      t("new-session", "-d", "-s", "third")
      local function id(target)
        return t("display-message", "-p", "-t", target, "#{window_id}")
      end
      local w = { id("main:0"), id("main:1"), id("main:2"), id("other:0"), id("third:0") }
      local sid = { main = t("display-message", "-p", "-t", "main:", "#{session_id}"),
        other = t("display-message", "-p", "-t", "other:", "#{session_id}") }
      local fresh = assert(tmux.read())
      local rendered = {}
      for k in pairs(fresh.by_id) do
        rendered[k] = true
      end
      local rows, errs = parse({ sid.main .. " main", w[1], w[4], w[5], w[2], sid.other .. " other", w[3] })
      eq(errs, {})
      local plan = assert(diff.compute(rows, fresh, rendered))
      t("kill-session", "-t", "third") -- @4 dies between plan and apply
      local okk, report = apply.apply(plan, tmux, nil, nil)
      eq(okk, false)
      assert(report.failed)
      eq(#report.leftover_holds, 1)
      eq(report.leftover_holds[1].session_id, sid.other)
      eq(t("list-sessions", "-F", "#{session_name}"), "main\nother")
      eq(t("list-windows", "-t", "other", "-F", "#{window_id}"), report.leftover_holds[1].window_id)
    end)
    kill_server()
    assert(ok, err)
  end },
}
