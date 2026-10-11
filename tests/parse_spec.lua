local parse = require("tmux-oil.parse").parse

local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. "\n  ~=\n" .. vim.inspect(b))
end

local function one(line)
  local rows, errors = parse({ "$0 s", line })
  eq(errors, {})
  return rows[2]
end

return {
  { "three line kinds", function()
    local rows, errors = parse({ "$0 main", "@1 vim", "scratch" })
    eq(errors, {})
    eq(rows, {
      { kind = "session", id = "$0", name = "main", lnum = 1, session_lnum = 1 },
      { kind = "window", id = "@1", name = "vim", lnum = 2, session_lnum = 1 },
      { kind = "new", name = "scratch", lnum = 3, session_lnum = 1 },
    })
  end },
  { "blank lines are ignored but lnum counts them", function()
    local rows, errors = parse({ "$0 a", "", "   ", "@2 x" })
    eq(errors, {})
    eq(#rows, 2)
    eq(rows[2].lnum, 4)
  end },
  { "session_lnum follows the nearest session above", function()
    local rows = parse({ "$0 a", "@1 x", "$1 b", "@2 y", "n" })
    eq(rows[2].session_lnum, 1)
    eq(rows[4].session_lnum, 3)
    eq(rows[5].session_lnum, 3)
  end },
  { "name containing @3 verbatim", function()
    eq(one("@5 foo @3 bar").name, "foo @3 bar")
  end },
  { "name containing %101 and pipe", function()
    eq(one("@5 Pane %101 | x").name, "Pane %101 | x")
  end },
  { "extra spaces after anchor are trimmed", function()
    eq(one("@5    spaced  ").name, "spaced")
  end },
  { "anchor-only line is a window with empty name", function()
    local r = one("@34")
    eq({ r.kind, r.id, r.name }, { "window", "@34", "" })
  end },
  { "anchor plus trailing space is empty name", function()
    local r = one("@34 ")
    eq({ r.kind, r.id, r.name }, { "window", "@34", "" })
  end },
  { "anchor without a space still anchors (the space after it is optional)", function()
    local r = one("@34foo")
    eq({ r.kind, r.id, r.name }, { "window", "@34", "foo" })
  end },
  { "J-joined line swallows the second id", function()
    local r = one("@34 foo @36 bar")
    eq({ r.kind, r.id, r.name }, { "window", "@34", "foo @36 bar" })
  end },
  { "anchorless line is new, trimmed", function()
    local r = one("   hello world  ")
    eq({ r.kind, r.id, r.name }, { "new", nil, "hello world" })
  end },
  { "empty session name is an error, other lines still parse", function()
    local rows, errors = parse({ "$0 ", "@1 a", "$1 b" })
    eq(errors, { { lnum = 1, msg = "session line has an empty name" } })
    eq(#rows, 2)
  end },
  { "no session line is an error", function()
    local _, errors = parse({})
    eq(#errors, 1)
    eq(errors[1].lnum, 1)
  end },
  { "window above any session is an error", function()
    local rows, errors = parse({ "@1 a", "$0 s", "@2 b" })
    eq(#errors, 1)
    eq(errors[1].lnum, 1)
    eq(#rows, 2)
  end },
  { "new line above any session is an error", function()
    local _, errors = parse({ "orphan", "$0 s" })
    eq(errors[1].lnum, 1)
  end },
  { "duplicate id is an error on the second line only", function()
    local rows, errors = parse({ "$0 s", "@1 a", "@1 b", "@2 c" })
    eq(#errors, 1)
    eq(errors[1].lnum, 3)
    eq(#rows, 3)
    eq(rows[2].name, "a")
  end },
  { "errors do not block later lines", function()
    local rows, errors = parse({ "@1 a", "$0 s", "@1 b", "@1 c", "n" })
    eq(#errors, 2)
    eq(#rows, 3)
    eq(rows[3].kind, "new")
  end },
  { "deleted anchor turns the line into a new window", function()
    local r = one("foo")
    eq(r.kind, "new")
  end },
  { "a character before the concealed space still belongs to the anchored window", function()
    local rows = parse({ "$0 main", "@2X ", "@3foo", "@4" })
    eq(#rows, 4)
    eq(rows[2].id, "@2"); eq(rows[2].name, "X")
    eq(rows[3].id, "@3"); eq(rows[3].name, "foo")
    eq(rows[4].id, "@4"); eq(rows[4].name, "")
  end },
  { "trailing slash makes a new session row", function()
    local rows, errors = parse({ "$0 a", "work/", "  work /" })
    eq(errors, {})
    eq(rows[2], { kind = "newsession", name = "work", lnum = 2, session_lnum = 2 })
    eq(rows[3].name, "work")
  end },
  { "new session line errors", function()
    for line, msg in pairs({
      ["/"] = "new session line has an empty name",
      ["a:b/"] = "session name cannot contain ':' or '.'",
      ["a.b/"] = "session name cannot contain ':' or '.'",
    }) do
      local rows, errors = parse({ "$0 a", line })
      eq(errors, { { lnum = 2, msg = msg } })
      eq(#rows, 1)
    end
  end },
  { "a new session line opens the buffer and owns the lines below", function()
    local rows, errors = parse({ "work/", "api" })
    eq(errors, {})
    eq(rows[2], { kind = "new", name = "api", lnum = 2, session_lnum = 1 })
  end },
}
