-- rows x fresh state x rendered ids -> plan. Pure; design-v2 §2.
-- New sessions are not expressible by text (a session line always carries a "$N" anchor),
-- so only new windows are supported.
local M = {}

-- Managed = known to the buffer (rendered) and still present (§2 untouched / vanished).
local function managed(id, fresh, rendered)
  return fresh.by_id[id] ~= nil and rendered[id] == true
end

-- Longest strictly increasing subsequence of pos[]; returns set of kept indices.
-- Starts-at DP with earliest-start tie-break, so a window that is first in both
-- orders is always stable.
local function stable_set(pos)
  local n, len = #pos, {}
  for i = n, 1, -1 do
    len[i] = 1
    for j = i + 1, n do
      if pos[j] > pos[i] and len[j] + 1 > len[i] then
        len[i] = len[j] + 1
      end
    end
  end
  local best = 0
  for i = 1, n do
    if len[i] > (len[best] or 0) then
      best = i
    end
  end
  local set, cur = {}, best
  while cur > 0 and cur <= n do
    set[cur] = true
    local nxt = 0
    for j = cur + 1, n do
      if pos[j] > pos[cur] and len[j] == len[cur] - 1 then
        nxt = j
        break
      end
    end
    cur = nxt
  end
  return set
end

local function first_fresh_other(sess, skip_id)
  for _, w in ipairs(sess.windows) do
    if w.id ~= skip_id then
      return w.id
    end
  end
end

-- Groups rows into { {row=session_row, items={window/new rows}} } in buffer order.
local function group_rows(rows, fresh, rendered)
  local groups, by_lnum = {}, {}
  for _, r in ipairs(rows) do
    if r.kind == "session" then
      if managed(r.id, fresh, rendered) then
        local g = { row = r, items = {} }
        groups[#groups + 1] = g
        by_lnum[r.lnum] = g
      end
    elseif r.kind == "window" then
      local g = by_lnum[r.session_lnum]
      if g and managed(r.id, fresh, rendered) then
        g.items[#g.items + 1] = r
      end -- else: foreign/vanished window or ungoverned: no ops
    else
      local g = by_lnum[r.session_lnum]
      if g then
        g.items[#g.items + 1] = r
      end
    end
  end
  return groups
end

-- Orders one session's items: emits news and minimal moves (§2 new / move).
local function plan_order(g, fresh, plan, final_session)
  local sess = fresh.by_id[g.row.id]
  local fpos = {}
  for i, w in ipairs(sess.windows) do
    fpos[w.id] = i
  end
  local cand, cand_idx = {}, {}
  for i, it in ipairs(g.items) do
    if it.kind == "window" and fpos[it.id] then
      cand[#cand + 1] = fpos[it.id]
      cand_idx[#cand_idx + 1] = i
    end
  end
  local stable = {}
  for k in pairs(stable_set(cand)) do
    stable[cand_idx[k]] = true
  end
  -- Pass 1: number the new windows; find the first one that has no stable/new above it.
  local base, k, front_new, anchored = #plan.news, 0, nil, false
  local newidx = {}
  for i, it in ipairs(g.items) do
    if it.kind == "new" then
      k = k + 1
      newidx[i] = base + k
      if not anchored and not front_new then
        front_new = base + k
      end
      anchored = true
    elseif stable[i] then
      anchored = true
    end
  end
  -- Pass 2: emit in buffer order.
  local anchor = nil
  for i, it in ipairs(g.items) do
    if it.kind == "new" then
      local n = { name = it.name, session_id = sess.id }
      if anchor and anchor.id then
        n.after = anchor.id
      elseif anchor then
        n.after_new = anchor.new
      else
        n.before = sess.windows[1] and sess.windows[1].id or nil -- first in session
      end
      plan.news[#plan.news + 1] = n
      anchor = { new = newidx[i] }
    elseif stable[i] then
      anchor = { id = it.id }
    else
      local m = { id = it.id, session_id = sess.id }
      local prev = g.items[i - 1]
      if prev and prev.kind == "window" then
        m.after = prev.id
      elseif prev then
        m.after_new = newidx[i - 1]
      elseif front_new then
        m.before_new = front_new
      else
        m.before = first_fresh_other(sess, it.id)
      end
      plan.moves[#plan.moves + 1] = m
    end
    if it.kind == "window" then
      final_session[it.id] = sess.id
    end
  end
end

local function kill_entry(obj, kind)
  local panes = obj.panes
  if kind == "session" then
    panes = 0
    for _, w in ipairs(obj.windows) do
      panes = panes + (w.panes or 0)
    end
  end
  return { id = obj.id, kind = kind, name = obj.name, title = obj.title, panes = panes }
end

function M.compute(rows, fresh, rendered_ids)
  local plan = {
    renames = {}, autos = {}, session_renames = {}, news = {}, moves = {}, kills = {},
    untouched = {}, vanished = {}, own_id = nil, empty = true, destructive = false,
  }
  local errors = {}
  local in_rows, final_session, placed = {}, {}, {}
  for _, r in ipairs(rows) do
    if r.id then
      in_rows[r.id] = true
    end
  end

  local groups = group_rows(rows, fresh, rendered_ids)
  for _, g in ipairs(groups) do
    local sess = fresh.by_id[g.row.id]
    if g.row.name ~= sess.name then
      plan.session_renames[#plan.session_renames + 1] = { id = sess.id, name = g.row.name }
    end
    for _, it in ipairs(g.items) do
      if it.kind == "window" then
        placed[it.id] = true
        local w = fresh.by_id[it.id]
        if it.name == "" then
          -- §2 rename: empty buffer name == automatic-rename on
          if not w.auto_rename then
            plan.autos[#plan.autos + 1] = { id = w.id }
          end
        elseif it.name ~= w.name then
          plan.renames[#plan.renames + 1] = { id = w.id, name = it.name }
        end
      end
    end
    plan_order(g, fresh, plan, final_session)
  end

  -- §2 kill: rendered, still in fresh, gone from the buffer. Session kill subsumes windows.
  local killed_session = {}
  for _, s in ipairs(fresh.sessions) do
    if rendered_ids[s.id] and not in_rows[s.id] then
      killed_session[s.id] = true
      plan.kills[#plan.kills + 1] = kill_entry(s, "session")
      for _, w in ipairs(s.windows) do
        if not rendered_ids[w.id] then
          errors[#errors + 1] = { msg = "killing session " .. s.name .. " would also kill "
            .. w.id .. ", which is not in the buffer" }
        elseif in_rows[w.id] and not placed[w.id] then
          errors[#errors + 1] = { msg = "window " .. w.id .. " would die with session "
            .. s.name .. " (its line is not under a known session)" }
        end
      end
    else
      for _, w in ipairs(s.windows) do
        if rendered_ids[w.id] and not in_rows[w.id] then
          plan.kills[#plan.kills + 1] = kill_entry(w, "window")
        end
      end
    end
  end

  -- untouched (§2): never kill, report only. Windows of an untouched session are subsumed.
  for _, s in ipairs(fresh.sessions) do
    if not rendered_ids[s.id] then
      plan.untouched[#plan.untouched + 1] = s.id
    elseif not killed_session[s.id] then
      for _, w in ipairs(s.windows) do
        if not rendered_ids[w.id] then
          plan.untouched[#plan.untouched + 1] = w.id
        end
      end
    end
  end

  -- vanished (§2): in the buffer, gone from tmux. Report only.
  local vseen = {}
  for _, r in ipairs(rows) do
    if r.id and not fresh.by_id[r.id] and not vseen[r.id] then
      vseen[r.id] = true
      plan.vanished[#plan.vanished + 1] = r.id
    end
  end

  -- §2 apply guard: an attached session must keep at least one window.
  local count = {}
  local killed_window = {}
  for _, k in ipairs(plan.kills) do
    killed_window[k.id] = true
  end
  for _, s in ipairs(fresh.sessions) do
    for _, w in ipairs(s.windows) do
      if not killed_session[s.id] and not killed_window[w.id] then
        local fs = final_session[w.id] or s.id
        count[fs] = (count[fs] or 0) + 1
      end
    end
  end
  for _, n in ipairs(plan.news) do
    count[n.session_id] = (count[n.session_id] or 0) + 1
  end
  for _, s in ipairs(fresh.sessions) do
    if s.attached and (killed_session[s.id] or (count[s.id] or 0) == 0) then
      errors[#errors + 1] = { msg = "cannot empty attached session " .. s.name
        .. " - move its windows to another session first" }
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  plan.destructive = #plan.kills > 0
  plan.empty = #plan.renames + #plan.autos + #plan.session_renames + #plan.news
    + #plan.moves + #plan.kills == 0
  return plan, errors
end

return M
