-- rows x fresh state x rendered ids -> plan. Pure; design-v2 §2.
-- A new session is an anchorless line ending in "/" (kind "newsession"); its group key is "new#k".
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

-- First fresh window of sess that is still in sess when moves run: not killed, and its final
-- session (from the buffer) is sess. ctx.stays(w, sid) answers that.
local function first_staying(sess, ctx, skip_id)
  for _, w in ipairs(sess.windows) do
    if w.id ~= skip_id and ctx.stays(w, sess.id) then
      return w.id
    end
  end
end

-- Groups rows into { {row=session_row, items={window/new rows}} } in buffer order.
local function group_rows(rows, fresh, rendered)
  local groups, by_lnum, nsess = {}, {}, 0
  for _, r in ipairs(rows) do
    if r.kind == "newsession" then
      nsess = nsess + 1
      local g = { row = r, new_session = nsess, items = {} }
      groups[#groups + 1] = g
      by_lnum[r.lnum] = g
    elseif r.kind == "session" then
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
local function plan_order(g, fresh, plan, ctx)
  local k_sess = g.new_session
  local sess = k_sess and { id = nil, windows = {} } or fresh.by_id[g.row.id]
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
      local n = { name = it.name, session_id = sess.id, session_new = k_sess }
      if anchor and anchor.id then
        n.after = anchor.id
      elseif anchor then
        n.after_new = anchor.new
      elseif k_sess then
        n.before = { newhold = k_sess }
      else
        -- first in session: a window that stays, else the placeholder
        n.before = first_staying(sess, ctx) or (plan.holds[sess.id] and { hold = sess.id }) or nil
      end
      plan.news[#plan.news + 1] = n
      anchor = { new = newidx[i] }
    elseif stable[i] then
      anchor = { id = it.id }
    else
      local m = { id = it.id, session_id = sess.id, session_new = k_sess,
        from = fresh.session_of[it.id] }
      local prev = g.items[i - 1]
      if prev and prev.kind == "window" then
        m.after = prev.id
      elseif prev then
        m.after_new = newidx[i - 1]
      elseif front_new then
        m.before_new = front_new
      elseif k_sess then
        m.before = { newhold = k_sess }
      else
        m.before = first_staying(sess, ctx, it.id) or { hold = sess.id }
      end
      plan.moves[#plan.moves + 1] = m
    end
  end
end

-- windows: for a session kill, the number of windows that actually die with it.
local function kill_entry(obj, kind, windows)
  local panes = obj.panes
  if kind == "session" then
    panes = 0
    for _, w in ipairs(obj.windows) do
      panes = panes + (w.panes or 0)
    end
  end
  return { id = obj.id, kind = kind, name = obj.name, title = obj.title, panes = panes,
    windows = windows }
end

function M.compute(rows, fresh, rendered_ids)
  local plan = {
    renames = {}, autos = {}, session_renames = {}, news = {}, moves = {}, kills = {},
    untouched = {}, vanished = {}, own_id = nil, empty = true, destructive = false,
    ends = {}, holds = {}, new_sessions = {},
  }
  local errors = {}
  local in_rows, final_session, placed = {}, {}, {}
  for _, r in ipairs(rows) do
    if r.id then
      in_rows[r.id] = true
    end
  end

  local groups = group_rows(rows, fresh, rendered_ids)

  -- Where every placed window ends up, and which windows die individually: both are needed
  -- before any anchor is chosen.
  local new_sessions, seen_new = {}, {}
  -- Names a new session may not take: what every surviving session is called after this
  -- save — the buffer name for kept sessions, the tmux name for untouched ones; killed and
  -- ended sessions free theirs.
  local existing_names = {}
  for _, s in ipairs(fresh.sessions) do
    if not rendered_ids[s.id] then
      existing_names[vim.trim(s.name)] = true
    end
  end
  for _, g in ipairs(groups) do
    if not g.new_session then
      existing_names[g.row.name] = true
    end
  end
  for _, g in ipairs(groups) do
    if g.new_session then
      local name = g.row.name
      if existing_names[name] then
        errors[#errors + 1] = { lnum = g.row.lnum, msg = "session " .. name .. " already exists" }
      elseif seen_new[name] then
        errors[#errors + 1] = { lnum = g.row.lnum, msg = "new session " .. name .. " appears twice" }
      end
      seen_new[name] = true
      new_sessions[g.new_session] = { name = name, key = g.new_session }
    end
    for _, it in ipairs(g.items) do
      if it.kind == "window" then
        final_session[it.id] = g.new_session and ("new#" .. g.new_session) or g.row.id
      end
    end
  end
  local killed_win = {}
  for _, s in ipairs(fresh.sessions) do
    if not (rendered_ids[s.id] and not in_rows[s.id]) then
      for _, w in ipairs(s.windows) do
        if rendered_ids[w.id] and not in_rows[w.id] then
          killed_win[w.id] = true
        end
      end
    end
  end
  local ctx = { stays = function(w, sid)
    return not killed_win[w.id] and (final_session[w.id] or sid) == sid
  end }

  plan.new_sessions = new_sessions
  local empty_err = {}
  -- Placeholders (§2): a kept session whose windows all leave or die keeps one while it receives.
  for _, g in ipairs(groups) do
    local sess = fresh.by_id[g.row.id]
    if g.new_session then
      sess = nil
    elseif not first_staying(sess, ctx) then
      if #g.items > 0 then
        plan.holds[sess.id] = true
      else
        -- A kept session line with nothing left in it is unrepresentable: tmux destroys
        -- an empty session, whether its windows moved out or were killed.
        empty_err[sess.id] = true
        errors[#errors + 1] = { msg = "session " .. sess.name .. " would be left empty"
          .. " — delete its line or keep a window in it" }
      end
    end
  end

  for _, g in ipairs(groups) do
    local sess = fresh.by_id[g.row.id]
    if sess and g.row.name ~= vim.trim(sess.name) then
      plan.session_renames[#plan.session_renames + 1] = { id = sess.id, name = g.row.name }
    end
    for _, it in ipairs(g.items) do
      if it.kind == "window" then
        placed[it.id] = true
        local w = fresh.by_id[it.id]
        local fname = vim.trim(w.name) -- buffer names are trimmed by parse; so is the fresh side
        if it.name == "" then
          -- §2 rename: empty buffer name == automatic-rename on (or a blank name)
          if not w.auto_rename and fname ~= "" then
            plan.autos[#plan.autos + 1] = { id = w.id }
          end
        elseif it.name ~= fname or w.auto_rename then -- typing the shown name pins it
          plan.renames[#plan.renames + 1] = { id = w.id, name = it.name }
        end
      end
    end
    plan_order(g, fresh, plan, ctx)
  end

  -- §2 kill: rendered, still in fresh, gone from the buffer. Session kill subsumes windows.
  local killed_session = {}
  for _, s in ipairs(fresh.sessions) do
    if rendered_ids[s.id] and not in_rows[s.id] then
      local leftover = 0
      for _, w in ipairs(s.windows) do
        if not placed[w.id] then
          leftover = leftover + 1
        end
      end
      if leftover == 0 then
        -- every window moved out: tmux destroys the session itself, kill-session would fail
        plan.ends[#plan.ends + 1] = { id = s.id, name = s.name }
      else
        killed_session[s.id] = true
        plan.kills[#plan.kills + 1] = kill_entry(s, "session", leftover)
      end
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
      if not killed_window[w.id] and (not killed_session[s.id] or final_session[w.id]) then
        local fs = final_session[w.id] or s.id
        count[fs] = (count[fs] or 0) + 1
      end
    end
  end
  for _, n in ipairs(plan.news) do
    if not n.session_new then
      count[n.session_id] = (count[n.session_id] or 0) + 1
    end
  end
  for _, s in ipairs(fresh.sessions) do
    if s.attached and not empty_err[s.id] and (killed_session[s.id] or (count[s.id] or 0) == 0) then
      errors[#errors + 1] = { msg = "cannot empty attached session " .. s.name
        .. " - move its windows to another session first" }
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  plan.destructive = #plan.kills + #plan.ends > 0
  -- holds alone never make a plan non-empty
  plan.empty = #plan.renames + #plan.autos + #plan.session_renames + #plan.news
    + #plan.moves + #plan.kills + #plan.ends + #plan.new_sessions == 0
  return plan, errors
end

return M
