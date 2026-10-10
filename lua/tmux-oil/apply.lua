-- plan -> tmux commands, executed one at a time. design-v2 §2, §0 #11.
local M = {}

-- tmux expands #-formats in name arguments; "##" is a literal "#".
local function esc(name)
  return (name:gsub("#", "##"))
end

-- argv elements may be { new = k }: resolved to the window id created by plan.news[k], or
-- { hold = session_id }: resolved to that session's placeholder window (plan.holds).
local function new_window_step(n)
  local argv = { "new-window", "-d", "-P", "-F", "#{window_id}" }
  if n.name ~= "" then -- empty name: omit -n so automatic-rename stays on
    vim.list_extend(argv, { "-n", esc(n.name) })
  end
  local ref = n.after or n.before -- window id or { hold = sid }
  if n.after_new then
    ref = { new = n.after_new }
  elseif n.before_new then
    ref = { new = n.before_new }
  end
  if n.after or n.after_new then
    vim.list_extend(argv, { "-a", "-t", ref })
  elseif ref then
    vim.list_extend(argv, { "-b", "-t", ref })
  else
    vim.list_extend(argv, { "-t", n.session_id .. ":" })
  end
  return { argv = argv, creates = true }
end

local function move_step(m)
  local argv = { "move-window", "-s", m.id }
  if m.after or m.after_new then
    vim.list_extend(argv, { "-a", "-t", m.after or { new = m.after_new } })
  else
    vim.list_extend(argv, { "-b", "-t", m.before or { new = m.before_new } })
  end
  return { argv = argv }
end

-- §2 kill order: the entry holding the running nvim goes last. Placeholders are removed before
-- it: killing the own window may end this process.
local function kill_steps(kills, holds, own_id, own_session)
  local steps, own = {}, {}
  for _, k in ipairs(kills) do
    local argv = { k.kind == "session" and "kill-session" or "kill-window", "-t", k.id }
    local is_own = k.id == own_id or (k.kind == "session" and k.id == own_session)
    table.insert(is_own and own or steps, { argv = argv })
  end
  for _, sid in ipairs(holds) do
    steps[#steps + 1] = { argv = { "kill-window", "-t", { hold = sid } }, hidden = true }
  end
  vim.list_extend(steps, own)
  return steps
end

local function build_steps(plan, own_id, own_session)
  local steps = {}
  local function add(argv)
    steps[#steps + 1] = { argv = argv }
  end
  for _, r in ipairs(plan.session_renames) do
    add({ "rename-session", "-t", r.id, "--", esc(r.name) })
  end
  for _, r in ipairs(plan.renames) do
    add({ "rename-window", "-t", r.id, "--", esc(r.name) })
  end
  for _, a in ipairs(plan.autos) do
    add({ "set-option", "-w", "-t", a.id, "automatic-rename", "on" })
  end
  -- Placeholders keep a session alive while its windows move out (tmux destroys a session the
  -- moment its last window leaves).
  local holds = vim.tbl_keys(plan.holds or {})
  table.sort(holds)
  for _, sid in ipairs(holds) do
    steps[#steps + 1] = {
      argv = { "new-window", "-d", "-P", "-F", "#{window_id}", "-t", sid .. ":" }, hold = sid,
      hidden = true,
    }
  end
  for _, n in ipairs(plan.news) do
    steps[#steps + 1] = new_window_step(n)
  end
  for _, m in ipairs(plan.moves) do
    steps[#steps + 1] = move_step(m)
  end
  vim.list_extend(steps, kill_steps(plan.kills, holds, own_id, own_session))
  return steps
end

local function resolve(argv, created, holds)
  local out = {}
  for i, a in ipairs(argv) do
    if type(a) == "table" then
      a = a.hold and holds[a.hold] or created[a.new]
      if not a then
        return nil, "anchor window was not created"
      end
    end
    out[i] = a
  end
  return out
end

-- Failed apply: a placeholder is removed only while its session still has another window;
-- killing the last window would destroy the session. Returns the placeholders left behind.
local function release_holds(holds, tmux)
  local left = {}
  local sids = vim.tbl_keys(holds)
  table.sort(sids)
  for _, sid in ipairs(sids) do
    local out = tmux.run({ "list-windows", "-t", sid, "-F", "#{window_id}" })
    if out then
      if #vim.split(out, "\n", { trimempty = true }) > 1 then
        tmux.run({ "kill-window", "-t", holds[sid] })
      else
        left[#left + 1] = { session_id = sid, window_id = holds[sid] }
      end
    end
  end
  return left
end

-- Returns ok, report = { done, failed = { cmd, err } | nil, skipped, leftover_holds? }.
-- done/skipped count user-visible steps only (not placeholder creation/removal).
function M.apply(plan, tmux, own_id, own_session)
  local steps = build_steps(plan, own_id, own_session)
  local report = { done = 0, skipped = 0 }
  local created, new_count, holds = {}, 0, {}
  for i, step in ipairs(steps) do
    local argv, err = resolve(step.argv, created, holds)
    local out
    if argv then
      out, err = tmux.run(argv)
    end
    if not out then
      report.failed = { cmd = argv or step.argv, err = err }
      for j = i + 1, #steps do
        if not steps[j].hidden then
          report.skipped = report.skipped + 1
        end
      end
      local left = release_holds(holds, tmux)
      if #left > 0 then
        report.leftover_holds = left
      end
      return false, report
    end
    if step.hold then
      holds[step.hold] = out
    elseif step.creates then
      new_count = new_count + 1
      created[new_count] = out
    end
    if not step.hidden then
      report.done = report.done + 1
    end
  end
  return true, report
end

return M
