-- tmux wrapper: argv arrays only (no shell strings). See design-v2 §4.
local M = {}

M.socket = nil

local SEP = "\31"
local FIELDS = {
  "#{session_id}", "#{session_name}", "#{session_attached}", "#{window_id}",
  "#{window_index}", "#{window_name}", "#{window_active}", "#{window_panes}",
  "#{automatic-rename}", "#{pane_current_command}", "#{pane_title}", "#{pane_current_path}",
}

-- Returns stdout (trailing newlines stripped) or nil, err.
function M.run(args)
  local cmd = { "tmux" }
  if M.socket then
    vim.list_extend(cmd, { "-L", M.socket })
  end
  vim.list_extend(cmd, args)
  local ok, res = pcall(function() return vim.system(cmd, { text = true }):wait() end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    local msg = vim.trim(res.stderr or "")
    return nil, msg ~= "" and msg or ("tmux exited with " .. res.code)
  end
  return (res.stdout or ""):gsub("\n+$", ""), nil
end

local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local i = s:find(sep, pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      return out
    end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = i + #sep
  end
end

-- Builds the state tree from the list-windows output lines.
function M.build_state(lines)
  local state = { sessions = {}, by_id = {}, session_of = {} }
  for _, line in ipairs(lines) do
    local f = split(line, SEP)
    if #f >= #FIELDS then
      local sess = state.by_id[f[1]]
      if not sess then
        sess = { id = f[1], name = f[2], attached = (tonumber(f[3]) or 0) > 0, windows = {} }
        state.by_id[sess.id] = sess
        state.sessions[#state.sessions + 1] = sess
      end
      local win = {
        id = f[4], index = tonumber(f[5]), name = f[6], active = f[7] == "1",
        panes = tonumber(f[8]), auto_rename = f[9] == "1" or f[9] == "on",
        command = f[10], title = f[11], cwd = f[12],
      }
      sess.windows[#sess.windows + 1] = win
      state.by_id[win.id] = win
      state.session_of[win.id] = sess.id
    end
  end
  return state
end

-- One tmux call (§4, §0 #12). Returns state or nil, err.
function M.read()
  local out, err = M.run({ "list-windows", "-a", "-F", table.concat(FIELDS, SEP) })
  if not out then
    return nil, err
  end
  return M.build_state(out == "" and {} or split(out, "\n"))
end

return M
