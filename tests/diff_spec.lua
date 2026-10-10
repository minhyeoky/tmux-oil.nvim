local parse = require("tmux-oil.parse").parse
local diff = require("tmux-oil.diff")

local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. "\n  ~=\n" .. vim.inspect(b))
end

-- fresh({ {"$0", "0", attached=true, { {"@1","a"}, {"@2","b",auto=true} }}, ... })
local function fresh(spec)
  local st = { sessions = {}, by_id = {}, session_of = {} }
  for _, s in ipairs(spec) do
    local sess = { id = s[1], name = s[2], attached = s.attached or false, windows = {} }
    for i, w in ipairs(s[3]) do
      local win = { id = w[1], index = i, name = w[2], active = false, panes = w.panes or 1,
        auto_rename = w.auto or false, command = "zsh", title = w.title or "t", cwd = "/" }
      sess.windows[#sess.windows + 1] = win
      st.by_id[win.id] = win
      st.session_of[win.id] = sess.id
    end
    st.sessions[#st.sessions + 1] = sess
    st.by_id[sess.id] = sess
  end
  return st
end

local function ids_of(st)
  local set = {}
  for id in pairs(st.by_id) do
    set[id] = true
  end
  return set
end

-- Parses lines and diffs; rendered defaults to every id in fresh.
local function run(st, lines, rendered)
  local rows, perrs = parse(lines)
  eq(perrs, {})
  return diff.compute(rows, st, rendered or ids_of(st))
end

local function base()
  return fresh({
    { "$0", "main", attached = true, { { "@1", "a" }, { "@2", "b", auto = true }, { "@3", "c" } } },
    { "$1", "side", { { "@4", "d" } } },
  })
end

local function kill_ids(plan)
  local out = {}
  for _, k in ipairs(plan.kills) do
    out[#out + 1] = k.id
  end
  return out
end

return {
  { "no change is empty", function()
    local plan, errs = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "$1 side", "@4 d" })
    eq(errs, {})
    assert(plan.empty and not plan.destructive)
  end },
  { "rename window", function()
    local plan = run(base(), { "$0 main", "@1 z", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.renames, { { id = "@1", name = "z" } })
    assert(not plan.empty and not plan.destructive)
  end },
  { "rename session", function()
    local plan = run(base(), { "$0 big", "@1 a", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.session_renames, { { id = "$0", name = "big" } })
  end },
  { "empty name equals auto-rename on: no op", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2 ", "@3 c", "$1 side", "@4 d" })
    assert(plan.empty)
  end },
  { "typing a name on an auto window renames it", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2 fixed", "@3 c", "$1 side", "@4 d" })
    eq(plan.renames, { { id = "@2", name = "fixed" } })
  end },
  { "clearing a name on a non-auto window re-enables automatic-rename", function()
    local plan = run(base(), { "$0 main", "@1", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.autos, { { id = "@1" } })
    eq(plan.renames, {})
  end },
  { "reorder adjacent: one move", function()
    local plan = run(base(), { "$0 main", "@2", "@1 a", "@3 c", "$1 side", "@4 d" })
    eq(#plan.moves, 1)
    eq(plan.moves[1], { id = "@1", session_id = "$0", after = "@2" })
  end },
  { "reorder to first: move_before", function()
    local plan = run(base(), { "$0 main", "@3 c", "@1 a", "@2", "$1 side", "@4 d" })
    eq(plan.moves, { { id = "@3", session_id = "$0", before = "@1" } })
  end },
  { "reorder non-adjacent: minimal ops", function()
    -- a b c d e -> e b c d a needs 2 moves
    local st = fresh({ { "$0", "s", attached = true, {
      { "@1", "a" }, { "@2", "b" }, { "@3", "c" }, { "@4", "d" }, { "@5", "e" } } } })
    local plan = run(st, { "$0 s", "@5 e", "@2 b", "@3 c", "@4 d", "@1 a" })
    eq(#plan.moves, 2)
    -- moving the first of three to the end is a single op
    local plan2 = run(st, { "$0 s", "@2 b", "@3 c", "@4 d", "@5 e", "@1 a" })
    eq(plan2.moves, { { id = "@1", session_id = "$0", after = "@5" } })
  end },
  { "cross-session move", function()
    local plan = run(base(), { "$0 main", "@1 a", "@3 c", "$1 side", "@2", "@4 d" })
    eq(plan.moves, { { id = "@2", session_id = "$1", before = "@4" } })
    eq(plan.kills, {})
  end },
  { "cross-session move after a window", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "$1 side", "@4 d", "@3 c" })
    eq(plan.moves, { { id = "@3", session_id = "$1", after = "@4" } })
  end },
  { "new window first in session", function()
    local plan = run(base(), { "$0 main", "fresh", "@1 a", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.news, { { name = "fresh", session_id = "$0", before = "@1" } })
    eq(plan.moves, {})
  end },
  { "new window in the middle", function()
    local plan = run(base(), { "$0 main", "@1 a", "mid", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.news, { { name = "mid", session_id = "$0", after = "@1" } })
  end },
  { "new window at the end", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "end", "$1 side", "@4 d" })
    eq(plan.news, { { name = "end", session_id = "$0", after = "@3" } })
  end },
  { "two new windows chain on each other", function()
    local plan = run(base(), { "$0 main", "@1 a", "n1", "n2", "@2", "@3 c", "$1 side", "@4 d" })
    eq(plan.news, {
      { name = "n1", session_id = "$0", after = "@1" },
      { name = "n2", session_id = "$0", after_new = 1 },
    })
  end },
  { "move after a new window refers to it by index", function()
    local plan = run(base(), { "$0 main", "@1 a", "n1", "@3 c", "@2", "$1 side", "@4 d" })
    eq(plan.news, { { name = "n1", session_id = "$0", after = "@1" } })
    eq(#plan.moves, 1)
    eq(plan.moves[1].id, "@2")
    eq(plan.moves[1].after, "@3")
  end },
  { "first moved window goes before a front new window", function()
    local plan = run(base(), { "$0 main", "@3 c", "n1", "@1 a", "@2", "$1 side", "@4 d" })
    -- buffer c n1 a b: n1 has nothing stable above it, so it is created first in the session
    eq(plan.news, { { name = "n1", session_id = "$0", before = "@1" } })
    eq(plan.moves, { { id = "@3", session_id = "$0", before_new = 1 } })
  end },
  { "delete window kills it", function()
    local plan = run(base(), { "$0 main", "@1 a", "@3 c", "$1 side", "@4 d" })
    eq(kill_ids(plan), { "@2" })
    eq(plan.kills[1].kind, "window")
    eq(plan.kills[1].name, "b")
    assert(plan.destructive and not plan.empty)
  end },
  { "delete session line kills one session, no per-window kills", function()
    -- window lines follow the session above them, so remove them too
    local plan = run(base(), { "$0 main", "@1 a", "@2", "@3 c" })
    eq(kill_ids(plan), { "$1" })
    eq(plan.kills[1].kind, "session")
    eq(plan.kills[1].name, "side")
    eq(plan.kills[1].panes, 1)
  end },
  { "deleting only the session line moves its windows up", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "@4 d" })
    eq(kill_ids(plan), { "$1" })
    eq(plan.moves, { { id = "@4", session_id = "$0", after = "@3" } })
  end },
  { "untouched is never killed", function()
    local st = base()
    local rendered = ids_of(st)
    rendered["@2"] = nil -- born outside after render
    local plan = run(st, { "$0 main", "@1 a", "@3 c", "$1 side", "@4 d" }, rendered)
    eq(plan.kills, {})
    eq(plan.untouched, { "@2" })
    assert(plan.empty)
  end },
  { "untouched session is reported as one id", function()
    local st = base()
    local rendered = ids_of(st)
    rendered["$1"], rendered["@4"] = nil, nil
    local plan = run(st, { "$0 main", "@1 a", "@2", "@3 c" }, rendered)
    eq(plan.kills, {})
    eq(plan.untouched, { "$1" })
  end },
  { "vanished ids report without ops", function()
    local st = base()
    local rows = parse({ "$0 main", "@1 a", "@2", "@3 c", "@99 ghost", "$1 side", "@4 d" })
    local plan = diff.compute(rows, st, ids_of(st))
    eq(plan.vanished, { "@99" })
    assert(plan.empty)
  end },
  { "attached session emptied is an error", function()
    local plan, errs = run(base(), { "$1 side", "@4 d" })
    assert(plan == nil)
    eq(#errs, 1)
    assert(errs[1].msg:find("attached"))
  end },
  { "attached session emptied by moves is an error", function()
    local plan, errs = run(base(), { "$0 main", "$1 side", "@4 d", "@1 a", "@2", "@3 c" })
    assert(plan == nil and #errs == 1)
  end },
  { "attached session kept alive by untouched window", function()
    local st = base()
    local rendered = ids_of(st)
    rendered["@3"] = nil
    local plan = run(st, { "$0 main", "$1 side", "@4 d" }, rendered)
    assert(plan ~= nil)
    eq(kill_ids(plan), { "@1", "@2" })
  end },
  { "attached session kept alive by a new window", function()
    local plan = run(base(), { "$0 main", "n", "$1 side", "@4 d" })
    assert(plan ~= nil)
    eq(#plan.kills, 3)
  end },
  { "killing a session with an untouched window is an error", function()
    local st = base()
    local rendered = ids_of(st)
    rendered["@4"] = nil
    local plan, errs = run(st, { "$0 main", "@1 a", "@2", "@3 c" }, rendered)
    assert(plan == nil and #errs == 1)
  end },
  { "J-joined line kills the swallowed window", function()
    local plan = run(base(), { "$0 main", "@1 a @2 b", "@3 c", "$1 side", "@4 d" })
    eq(plan.renames, { { id = "@1", name = "a @2 b" } })
    eq(kill_ids(plan), { "@2" })
  end },
  { "deleted anchor: old window killed, new window created", function()
    local plan = run(base(), { "$0 main", "a", "@2", "@3 c", "$1 side", "@4 d" })
    eq(kill_ids(plan), { "@1" })
    eq(plan.news, { { name = "a", session_id = "$0", before = "@1" } })
  end },
}
