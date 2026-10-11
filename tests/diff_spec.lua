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
    eq(plan.moves[1], { id = "@1", from = "$0", session_id = "$0", after = "@2" })
  end },
  { "reorder to first: move_before", function()
    local plan = run(base(), { "$0 main", "@3 c", "@1 a", "@2", "$1 side", "@4 d" })
    eq(plan.moves, { { id = "@3", from = "$0", session_id = "$0", before = "@1" } })
  end },
  { "reorder non-adjacent: minimal ops", function()
    -- a b c d e -> e b c d a needs 2 moves
    local st = fresh({ { "$0", "s", attached = true, {
      { "@1", "a" }, { "@2", "b" }, { "@3", "c" }, { "@4", "d" }, { "@5", "e" } } } })
    local plan = run(st, { "$0 s", "@5 e", "@2 b", "@3 c", "@4 d", "@1 a" })
    eq(#plan.moves, 2)
    -- moving the first of three to the end is a single op
    local plan2 = run(st, { "$0 s", "@2 b", "@3 c", "@4 d", "@5 e", "@1 a" })
    eq(plan2.moves, { { id = "@1", from = "$0", session_id = "$0", after = "@5" } })
  end },
  { "cross-session move", function()
    local plan = run(base(), { "$0 main", "@1 a", "@3 c", "$1 side", "@2", "@4 d" })
    eq(plan.moves, { { id = "@2", from = "$0", session_id = "$1", before = "@4" } })
    eq(plan.kills, {})
  end },
  { "cross-session move after a window", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "$1 side", "@4 d", "@3 c" })
    eq(plan.moves, { { id = "@3", from = "$0", session_id = "$1", after = "@4" } })
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
    eq(plan.moves, { { id = "@3", from = "$0", session_id = "$0", before_new = 1 } })
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
    eq(plan.kills, {})
    eq(plan.ends, { { id = "$1", name = "side" } })
    assert(plan.destructive and not plan.empty)
    eq(plan.moves, { { id = "@4", from = "$1", session_id = "$0", after = "@3" } })
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
    eq(plan.news, { { name = "a", session_id = "$0", before = "@2" } }) -- @1 is dying
  end },
  { "front move: anchor skips a window that already left the session", function()
    local st = fresh({
      { "$0", "main", attached = true, { { "@1", "a" }, { "@2", "b" }, { "@3", "c" } } },
      { "$1", "side", { { "@4", "d" }, { "@5", "e" } } },
    })
    local plan = run(st, { "$0 main", "@1 a", "@2", "@4 d", "$1 side", "@3 c", "@5 e" })
    eq(plan.moves, {
      { id = "@4", from = "$1", session_id = "$0", after = "@2" },
      { id = "@3", from = "$0", session_id = "$1", before = "@5" },
    })
    eq(plan.holds, {})
  end },
  { "front new window: anchor is a window that stays", function()
    local st = fresh({
      { "$0", "main", attached = true, { { "@1", "a" } } },
      { "$1", "side", { { "@4", "d" }, { "@5", "e" } } },
    })
    local plan = run(st, { "$0 main", "@1 a", "@4 d", "$1 side", "fresh", "@5 e" })
    eq(plan.news, { { name = "fresh", session_id = "$1", before = "@5" } })
  end },
  { "swap of two single-window sessions: both held, anchors are the placeholders", function()
    local st = fresh({ { "$0", "main", { { "@1", "a" } } }, { "$1", "side", { { "@2", "b" } } } })
    local plan, errs = run(st, { "$0 main", "@2 b", "$1 side", "@1 a" })
    eq(errs, {})
    eq(plan.holds, { ["$0"] = true, ["$1"] = true })
    eq(plan.moves, {
      { id = "@2", from = "$1", session_id = "$0", before = { hold = "$0" } },
      { id = "@1", from = "$0", session_id = "$1", before = { hold = "$1" } },
    })
    eq(plan.kills, {})
    eq(plan.ends, {})
  end },
  { "new window in a session whose windows all leave anchors on the placeholder", function()
    local st = fresh({ { "$0", "main", { { "@1", "a" } } }, { "$1", "side", { { "@2", "b" } } } })
    local plan = run(st, { "$0 main", "n", "$1 side", "@2 b", "@1 a" })
    eq(plan.holds, { ["$0"] = true })
    eq(plan.news, { { name = "n", session_id = "$0", before = { hold = "$0" } } })
  end },
  { "holds alone do not make a plan non-empty; plan.holds/ends exist and are empty", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "$1 side", "@4 d" })
    assert(plan.empty)
    eq(plan.holds, {})
    eq(plan.ends, {})
  end },
  { "deleted header with every window moved out ends, no kill-session", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "@4 d" })
    eq(plan.kills, {})
    eq(plan.ends, { { id = "$1", name = "side" } })
    assert(plan.destructive and not plan.empty)
    local lines = require("tmux-oil.ui").plan_lines(plan, base())
    assert(vim.tbl_contains(lines, 'END     session $1 "side"  (all windows moved out)'),
      vim.inspect(lines))
  end },
  { "deleted header with a window left behind still kills the session", function()
    local st = fresh({
      { "$0", "main", attached = true, { { "@1", "a" } } },
      { "$1", "side", { { "@4", "d" }, { "@5", "e" } } },
    })
    local plan, errs = run(st, { "$0 main", "@1 a", "@4 d" })
    eq(errs, {})
    eq(kill_ids(plan), { "$1" })
    eq(plan.ends, {})
  end },
  { "kept header with every window deleted is an error too", function()
    local st = fresh({ { "$0", "main", { { "@1", "a" } } }, { "$1", "side", { { "@2", "b" } } } })
    local plan, errs = run(st, { "$0 main", "@1 a", "$1 side" })
    assert(plan == nil and #errs == 1)
    assert(errs[1].msg:find("would be left empty", 1, true), errs[1].msg)
  end },
  { "kept header with every window moved out is an error", function()
    local st = fresh({ { "$0", "main", { { "@1", "a" } } }, { "$1", "side", { { "@2", "b" } } } })
    local plan, errs = run(st, { "$0 main", "$1 side", "@2 b", "@1 a" })
    assert(plan == nil and #errs == 1)
    assert(errs[1].msg:find("would be left empty", 1, true), errs[1].msg)
  end },
  { "typing the shown name of an auto window pins it", function()
    local plan = run(base(), { "$0 main", "@1 a", "@2 b", "@3 c", "$1 side", "@4 d" })
    eq(plan.renames, { { id = "@2", name = "b" } })
  end },
  { "empty fresh name on a non-auto window equals an empty buffer name", function()
    local st = fresh({ { "$0", "main", { { "@1", "" } } } })
    local plan = run(st, { "$0 main", "@1" })
    assert(plan.empty)
    eq(plan.autos, {})
  end },
  { "fresh names are trimmed like buffer names", function()
    local st = fresh({ { "$0", "m", attached = true, { { "@1", "  sp  " }, { "@2", "   " } } } })
    local plan = run(st, { "$0 m", "@1 sp", "@2 " })
    assert(plan.empty, vim.inspect(plan))
    local view = require("tmux-oil.view")
    local lines, _, ids = view.render(st, {})
    local rows = parse(lines)
    assert(diff.compute(rows, st, ids).empty)
  end },
  { "session kill counts only windows that die", function()
    local st = fresh({
      { "$0", "a", attached = true, { { "@0", "x" } } },
      { "$1", "b", { { "@1", "p" }, { "@2", "q" } } },
    })
    local plan = run(st, { "$0 a", "@0 x", "@1 p" })
    eq(#plan.kills, 1)
    eq(plan.kills[1].id, "$1")
    eq(plan.kills[1].windows, 1)
  end },
  { "new session with new windows", function()
    local plan, errs = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "work/", "one", "two", "$1 side", "@4 d" })
    eq(errs, {})
    eq(plan.new_sessions, { { name = "work", key = 1 } })
    eq(#plan.news, 2)
    eq(plan.news[1], { name = "one", session_new = 1, before = { newhold = 1 } })
    eq(plan.news[2], { name = "two", session_new = 1, after_new = 1 })
    eq(#plan.moves, 0)
    assert(not plan.empty)
  end },
  { "moving a window into a new session", function()
    local plan, errs = run(base(), { "$0 main", "@1 a", "@3 c", "work/", "@2", "$1 side", "@4 d" })
    eq(errs, {})
    eq(plan.moves, { { id = "@2", session_new = 1, from = "$0", before = { newhold = 1 } } })
    eq(plan.kills, {})
    eq(plan.holds, {})
    eq(plan.ends, {})
  end },
  { "all windows moved into a new session end the source", function()
    local st = base()
    st.sessions[1].attached = false -- an attached session may not be emptied
    local plan, errs = run(st, { "work/", "@1 a", "@2", "@3 c", "$1 side", "@4 d" })
    eq(errs, {})
    eq(#plan.moves, 3)
    eq(plan.ends, { { id = "$0", name = "main" } })
    eq(plan.kills, {})
  end },
  { "new session named like an existing one is an error", function()
    local rows = parse({ "$0 main", "@1 a", "main/", "x" })
    local plan, errs = diff.compute(rows, base(), ids_of(base()))
    eq(plan, nil)
    eq(errs[1].msg, "session main already exists")
  end },
  { "two new sessions with the same name are an error", function()
    local rows = parse({ "$0 main", "@1 a", "@2", "@3 c", "x/", "x/" })
    local plan, errs = diff.compute(rows, base(), ids_of(base()))
    eq(plan, nil)
    eq(errs[1].msg, "new session x appears twice")
  end },
  { "an empty new session is a plan of its own", function()
    local plan, errs = run(base(), { "$0 main", "@1 a", "@2", "@3 c", "ops/", "$1 side", "@4 d" })
    eq(errs, {})
    eq(plan.new_sessions, { { name = "ops", key = 1 } })
    eq(#plan.news, 0)
    eq(plan.empty, false)
  end },
}
