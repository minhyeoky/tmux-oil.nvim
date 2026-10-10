-- Buffer lines -> rows + errors. Grammar is exactly design-v2 §1.
local M = {}

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Returns kind, id, name for one line; nil for blank. §1: anchor regex only, rest is the name.
local function classify(line)
  if line:match("^%s*$") then
    return nil
  end
  for _, a in ipairs({ { "%$", "session" }, { "@", "window" } }) do
    local digits, rest = line:match("^" .. a[1] .. "(%d+) (.*)$")
    if not digits then
      digits = line:match("^" .. a[1] .. "(%d+)$")
      rest = ""
    end
    if digits then
      return a[2], (a[1] == "@" and "@" or "$") .. digits, trim(rest)
    end
  end
  return "new", nil, trim(line)
end

-- Rows hold only valid lines (dup ids, empty session names, orphans are errors, not rows),
-- so callers must not run diff while errors is non-empty.
function M.parse(lines)
  local rows, errors, seen = {}, {}, {}
  local session_lnum, sessions = nil, 0
  local function err(lnum, msg)
    errors[#errors + 1] = { lnum = lnum, msg = msg }
  end
  for lnum, line in ipairs(lines) do
    local kind, id, name = classify(line)
    if kind then
      local ok = true
      if kind == "session" then
        sessions = sessions + 1
        session_lnum = lnum
        if name == "" then
          err(lnum, "session line has an empty name")
          ok = false
        end
      elseif not session_lnum then
        err(lnum, "line is above any session line")
        ok = false
      end
      if ok and id and seen[id] then
        err(lnum, "duplicate id " .. id .. " (first on line " .. seen[id] .. ")")
        ok = false
      elseif ok and id then
        seen[id] = lnum
      end
      if ok then
        rows[#rows + 1] = {
          kind = kind, id = id, name = name, lnum = lnum,
          session_lnum = kind == "session" and lnum or session_lnum,
        }
      end
    end
  end
  if sessions == 0 then
    err(1, "no session line in buffer")
  end
  return rows, errors
end

return M
