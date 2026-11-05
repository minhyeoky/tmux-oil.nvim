-- Tmux client moves outside apply, i.e. follow_cursor (select the window under the cursor,
-- restore the origin on quit, settle last-window and the client's last session on close,
-- keep the :w guard and the follow state consistent).
local tmux = require("tmux-oil.tmux")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")
local parse = require("tmux-oil.parse")

local M = {}

local function follow_active()
  return state.S ~= nil and state.S.popup == true and config.values.follow_cursor == true and state.S.origin ~= nil
end

-- Does the plan destroy this window (directly, or by killing its session)?
local function killed_by(plan, id)
  for _, k in ipairs(plan.kills) do
    if k.id == id or (k.kind == "session" and state.S.state.session_of[id] == k.id) then
      return true
    end
  end
  return false
end

-- switch-client pinned to the popup's own client: once that client is gone (terminal closed),
-- an unpinned switch-client would grab the most recently active client instead.
local function switch_client(target)
  local args = { "switch-client" }
  if state.S.client then
    vim.list_extend(args, { "-c", state.S.client })
  end
  vim.list_extend(args, { "-t", target })
  return tmux.run(args)
end

-- The session's last window (what last-window selects), or nil.
local function last_window(sess)
  local out = tmux.run({ "list-windows", "-t", sess, "-F", "#{window_last_flag}\31#{window_id}" }) or ""
  for _, rec in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local flag, id = rec:match("^(.-)\31(.*)$")
    if flag == "1" then
      return id
    end
  end
end

-- Called as the popup opens, before follow moves anything: the origin session's last window
-- and the client's last session (switch-client -l), so settle can put them back.
function M.remember()
  if not follow_active() then
    return
  end
  state.S.lasts = { [state.S.origin.session] = last_window(state.S.origin.session) }
  local name = tmux.run({ "display-message", "-p", "#{client_last_session}" })
  local out = tmux.run({ "list-sessions", "-F", "#{session_name}\31#{session_id}" }) or ""
  for _, rec in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local n, id = rec:match("^(.-)\31(.*)$")
    if name and name ~= "" and n == name then
      state.S.last_session = id
    end
  end
end

-- Undoes what follow did, then goes to `target` (if given): every session follow passed
-- through back on its own current window, the client back on the origin window, each with
-- the last window and the client's last session it had. A jump then leaves tmux as a plain
-- switch-client from the origin would, so last-window and switch-client -l still work.
-- One tmux call (commands joined by ";"); each switch is pinned to the popup's client.
local function settle(target)
  local live, sessions = {}, {}
  local out = tmux.run({ "list-windows", "-a", "-F", "#{window_id}\31#{session_id}" }) or ""
  for _, rec in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local id, sess = rec:match("^(.-)\31(.*)$")
    live[id], sessions[sess] = sess, true
  end
  local lasts, cmds = state.S.lasts or {}, {}
  local function add(...)
    if #cmds > 0 then
      cmds[#cmds + 1] = ";"
    end
    vim.list_extend(cmds, { ... })
  end
  local function switch(t)
    if state.S.client then
      add("switch-client", "-c", state.S.client, "-t", t)
    else
      add("switch-client", "-t", t)
    end
  end
  -- Sessions are restored before the client moves: restoring last-window means selecting
  -- the last window, then the current one.
  local home = live[state.S.origin.window]
  local foreign = false
  for sess, active in pairs(state.S.touched or {}) do
    if sess ~= state.S.origin.session then
      foreign = true
      if live[active] == sess then -- may be dead after :w; nothing to do then
        if lasts[sess] and lasts[sess] ~= active and live[lasts[sess]] == sess then
          add("select-window", "-t", lasts[sess])
        end
        add("select-window", "-t", active)
      end
    end
  end
  if foreign and state.S.last_session and state.S.last_session ~= home and sessions[state.S.last_session] then
    switch(state.S.last_session)
  end
  -- The window id alone finds the session it lives in now (a :w may have moved it).
  if home then
    local last = lasts[home]
    if last and last ~= state.S.origin.window and live[last] == home then
      switch(last)
    end
    switch(state.S.origin.window)
  elseif sessions[state.S.origin.session] then
    switch(state.S.origin.session)
  end
  if target then
    switch(target)
  end
  -- After a jump the popup may stay open (qa blocked): touched and lasts still describe the
  -- state a later q puts back.
  if target then
    state.S.follow_last, state.S.moved = target, true
  else
    state.S.follow_last, state.S.touched, state.S.moved = state.S.origin.window, {}, false
  end
  if #cmds == 0 then
    return "", nil
  end
  local out, err = tmux.run(cmds)
  if err then
    -- tmux drops the rest of a ";" list after a failure (a window gone since list-windows):
    -- at least put the client back, then try the target alone.
    switch_client(state.S.origin.window)
    if target then
      return switch_client(target)
    end
  end
  return out, err
end

-- Has follow moved the client since the popup opened (or since the last settle)? Also true
-- when it came back to the origin window: the last window has changed by then.
local function wandered()
  return state.S.follow_last ~= nil and (state.S.moved or state.S.follow_last ~= state.S.origin.window)
end

-- Puts back what follow changed (see settle). Idempotent; does nothing unless follow moved
-- the client, and never after <CR> confirmed a target.
local function restore_origin()
  if not state.S or not state.S.origin or state.S.confirmed or not wandered() then
    return
  end
  settle(nil)
end

-- Goes to `target` for <CR>: through settle once follow has moved the client.
local function jump_to(target)
  if follow_active() and wandered() then
    return settle(target)
  end
  return switch_client(target)
end

local follow_timer = nil

local function stop_follow_timer()
  if follow_timer then
    follow_timer:stop()
    follow_timer:close()
    follow_timer = nil
  end
end

local function follow_now()
  stop_follow_timer()
  if not follow_active() then
    return
  end
  local win = vim.fn.bufwinid(state.S.buf)
  if win == -1 then
    return
  end
  local line = vim.api.nvim_buf_get_lines(state.S.buf, vim.api.nvim_win_get_cursor(win)[1] - 1,
    vim.api.nvim_win_get_cursor(win)[1], false)[1] or ""
  local _, id = parse.anchor(line)
  if not id or id:sub(1, 1) ~= "@" or id == state.S.follow_last then
    return -- session lines and anchorless lines do nothing
  end
  local sess = state.S.state and state.S.state.session_of[id]
  if sess and sess ~= state.S.origin.session and not state.S.touched[sess] then
    for _, w in ipairs(state.S.state.by_id[sess].windows) do
      if w.active then
        state.S.touched[sess] = w.id -- remembered once, before follow changes it
      end
    end
    state.S.lasts = state.S.lasts or {} -- nil when a reopen kept the buffer (discard declined)
    state.S.lasts[sess] = last_window(sess)
  end
  local _, err = switch_client(id)
  state.S.follow_last, state.S.moved = id, true -- also on failure: no retry on every cursor move
  if err then
    ui.notify("follow: " .. err, vim.log.levels.WARN)
  end
end

local function follow_soon()
  if not follow_active() then
    return
  end
  local delay = config.values.follow_delay or 0
  if delay <= 0 then
    return follow_now()
  end
  stop_follow_timer()
  local timer = vim.uv.new_timer()
  follow_timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    if follow_timer == timer then
      follow_now()
    end
  end))
end

-- A move takes the window, not the client: after a :w the client may sit in a session on a
-- window it never chose. Follow the cursor line again from wherever the client really is.
local function resync_follow()
  if not follow_active() then
    return
  end
  -- origin may have moved: guards and restores look for it in the session it lives in now
  state.S.origin.session = state.S.state.session_of[state.S.origin.window] or state.S.origin.session
  if not state.S.follow_last or not state.S.client then
    return
  end
  local out = tmux.run({ "list-clients", "-F", "#{client_name}\31#{window_id}" }) or ""
  for _, rec in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local name, here = rec:match("^(.-)\31(.*)$")
    if name == state.S.client then
      if here ~= state.S.follow_last then
        state.S.follow_last = here
        follow_now()
      end
      return
    end
  end
end

function M.before_apply(plan)
  if follow_active() and state.S.follow_last and state.S.follow_last ~= state.S.origin.window
    and killed_by(plan, state.S.follow_last) then
    if killed_by(plan, state.S.origin.window) then
      state.S.follow_last = nil
    else
      restore_origin()
    end
  end
end

function M.patch_attached(fresh)
  if follow_active() and state.S.follow_last and state.S.follow_last ~= state.S.origin.window then
    -- The client is only visiting the followed session: for the guard it still sits on origin.
    local here, there = fresh.by_id[state.S.origin.session], fresh.by_id[fresh.session_of[state.S.follow_last]]
    if here then
      here.attached = true
    end
    if there and there ~= here then
      there.attached = there.attached_n > 1
    end
  end
end

M.restore_origin = restore_origin
M.jump_to = jump_to
M.stop = stop_follow_timer
M.follow_soon = follow_soon
M.after_reload = resync_follow

return M
