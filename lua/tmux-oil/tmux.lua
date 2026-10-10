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

-- Builds the state tree from records (field strings joined by SEP, no nonce, no trailing SEP).
-- Returns state or nil, err: nothing is dropped silently.
function M.build_state(records)
  local state = { sessions = {}, by_id = {}, session_of = {} }
  for _, rec in ipairs(records) do
    local f = split(rec, SEP)
    if #f ~= #FIELDS then
      return nil, "unexpected list-windows output"
    end
    if state.by_id[f[4]] then
      return nil, "linked windows are not supported"
    end
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
  return state
end

-- 16 hex chars, fresh per read: a cwd or title cannot forge a record boundary without it.
local function nonce()
  local ok, bytes = pcall(vim.uv.random, 8)
  if ok and type(bytes) == "string" and #bytes == 8 then
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  if not M._seeded then
    math.randomseed(os.time() + math.floor(os.clock() * 1e6) + vim.uv.hrtime() % 1e9)
    M._seeded = true
  end
  return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

-- One list-windows call plus the server pid (§4, §0 #12). Returns state or nil, err.
-- Each record is nonce SEP fields SEP, so a "\n" inside a field never splits a record and the
-- last field is never at the end of the output.
function M.read()
  local n = nonce()
  local fmt = n .. SEP .. table.concat(FIELDS, SEP) .. SEP
  local out, err = M.run({ "list-windows", "-a", "-F", fmt })
  if not out then
    return nil, err
  end
  local pid, perr = M.run({ "display-message", "-p", "#{pid}" })
  if not pid then
    return nil, perr
  end
  local records = {}
  if out ~= "" then
    local head = n .. SEP
    if out:sub(1, #head) ~= head then
      return nil, "unexpected list-windows output"
    end
    for _, rec in ipairs(split(out:sub(#head + 1), "\n" .. head)) do
      if rec:sub(-1) ~= SEP then
        return nil, "unexpected list-windows output"
      end
      records[#records + 1] = rec:sub(1, -2)
    end
  end
  local state, serr = M.build_state(records)
  if not state then
    return nil, serr
  end
  state.server_pid = pid
  return state
end

return M
