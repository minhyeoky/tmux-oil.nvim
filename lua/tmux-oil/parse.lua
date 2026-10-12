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
  -- §1: the anchor is `$N` / `@N` at the start of the line; leading whitespace is ignored so
  -- an indented line (`>>`) still edits its window instead of creating "@2 name". The single
  -- space after it is optional, so a character typed before the concealed space (`@2X `) still
  -- edits the name of @2.
  for _, a in ipairs({ { "%$", "session" }, { "@", "window" } }) do
    local digits, rest = line:match("^%s*" .. a[1] .. "(%d+) ?(.*)$")
    if digits then
      return a[2], (a[1] == "@" and "@" or "$") .. digits, trim(rest)
    end
  end
  local text = trim(line)
  if text:sub(-1) == "/" then -- oil's `dir/` rule: a trailing slash makes a session
    return "newsession", nil, trim(text:sub(1, -2))
  end
  return "new", nil, text
end

M.classify = classify

-- Rows hold only valid lines (dup ids, empty session names, orphans are errors, not rows),
-- so a diff over rows is a diff over the valid lines only (§1: errors block saving).
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
      elseif kind == "newsession" then
        sessions = sessions + 1
        session_lnum = lnum
        if name == "" then
          err(lnum, "new session line has an empty name")
          ok = false
        elseif name:find("[:.]") then
          err(lnum, "session name cannot contain ':' or '.'")
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
          session_lnum = (kind == "session" or kind == "newsession") and lnum or session_lnum,
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
