-- Tmux client moves outside apply, i.e. follow_cursor (select the window under the cursor,
-- restore the origin on quit, keep the :w guard and the follow state consistent).
local tmux = require("tmux-oil.tmux")
local ui = require("tmux-oil.ui")
local config = require("tmux-oil.config")
local state = require("tmux-oil.state")

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

-- Puts the client back on the window the popup was opened from and every session follow
-- passed through back on its own current window. Idempotent; does nothing unless follow
-- moved away, and never after <CR> confirmed a target.
local function restore_origin()
  if not state.S or not state.S.origin or state.S.confirmed or not state.S.follow_last
    or state.S.follow_last == state.S.origin.window then
    return
  end
  for sess, active in pairs(state.S.touched or {}) do
    if sess ~= state.S.origin.session then
      tmux.run({ "select-window", "-t", active }) -- may be dead after :w; nothing to do then
    end
  end
  -- The window id alone finds the session it lives in now (a :w may have moved it).
  local _, err = switch_client(state.S.origin.window)
  if err then
    switch_client(state.S.origin.session)
  end
  state.S.follow_last, state.S.touched = state.S.origin.window, {}
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
  local id = line:match("^(@%d+)")
  if not id or id == state.S.follow_last then
    return -- session lines and anchorless lines do nothing
  end
  local sess = state.S.state and state.S.state.session_of[id]
  if sess and sess ~= state.S.origin.session and not state.S.touched[sess] then
    for _, w in ipairs(state.S.state.by_id[sess].windows) do
      if w.active then
        state.S.touched[sess] = w.id -- remembered once, before follow changes it
      end
    end
  end
  local _, err = switch_client(id)
  state.S.follow_last = id -- also on failure: no retry on every cursor move
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

M.switch_client = switch_client
M.restore_origin = restore_origin
M.stop = stop_follow_timer
M.follow_soon = follow_soon
M.after_reload = resync_follow

return M
