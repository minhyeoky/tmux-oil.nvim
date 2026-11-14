-- tmux-oil:// is not a file, so nothing about it belongs in ShaDa. The first two cases start
-- real nvim processes on a ShaDa file of their own: only an exit writes the file.
local oil = require("tmux-oil")
local tmux = require("tmux-oil.tmux")

local SOCK = "tmux-oil-shada"
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function t(...)
  local r = vim.system({ "tmux", "-L", SOCK, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
end

local function kill_server()
  vim.system({ "tmux", "-L", SOCK, "kill-server" }):wait()
end

local function nvim(shada, ...)
  local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", shada, ... },
    { text = true }):wait()
  assert(r.code == 0, r.stderr)
end

-- An nvim that opens the buffer, jumps twice and exits with the buffer still shown, as the
-- popup does on q and <CR>. "%" in 'shada' saves the buffer list too.
local function open_and_exit(shada, popup)
  nvim(shada, "--cmd", "lua vim.opt.rtp:prepend(" .. vim.inspect(root) .. ")",
    "--cmd", "set shada+=%",
    "-c", "lua require('tmux-oil').setup({ socket = '" .. SOCK .. "' })",
    "-c", "lua require('tmux-oil').open({ popup = " .. tostring(popup) .. " })",
    "-c", "normal! G", "-c", "normal! gg", "-c", "qa!")
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ShaDa is a stream of msgpack objects: type, timestamp, length, data. Returns the number of
-- entries in all, and the file names (`f`) of those stored for a buffer: jumps, marks and
-- changes (one map each) and the buffer list (an array of maps).
local function entries(shada)
  local s = read(shada)
  local unpack, pos, all, names = vim.mpack.Unpacker(), 1, 0, {}
  while pos <= #s do
    local data
    for _ = 1, 4 do
      data, pos = unpack(s, pos)
    end
    all = all + 1
    if type(data) == "table" then
      for _, d in ipairs(data.f and { data } or data) do
        if type(d) == "table" and d.f then
          names[#names + 1] = d.f
        end
      end
    end
  end
  return all, names
end

local function with_windows(fn)
  kill_server()
  local shada = vim.fn.tempname()
  local ok, err = pcall(function()
    t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
    for _ = 1, 4 do
      t("new-window", "-d", "-t", "a:")
    end
    fn(shada)
  end)
  kill_server()
  os.remove(shada)
  assert(ok, err)
end

return {
  { "the popup's exit leaves ShaDa as it was", function()
    with_windows(function(shada)
      local file = vim.fn.tempname()
      vim.fn.writefile(vim.fn.range(1, 50), file)
      nvim(shada, file, "-c", "normal! G", "-c", "normal! gg", "-c", "qa!") -- the editor's ShaDa
      os.remove(file)
      local before = read(shada)
      assert(#before > 0, "ShaDa was not written")
      for _ = 1, 2 do
        open_and_exit(shada, true)
      end
      assert(read(shada) == before, "the popup rewrote ShaDa")
    end)
  end },

  { "outside a popup, exiting with the buffer open stores no jump, mark or buffer-list entry for it", function()
    with_windows(function(shada)
      -- Three opens: the entries of one open come back in the next, shifted by its first draw.
      for _ = 1, 3 do
        open_and_exit(shada, false)
      end
      -- These nvims show no other buffer: an entry with a file name can only be ours.
      local all, names = entries(shada)
      assert(all > 0, "ShaDa was not written")
      assert(#names == 0, #names .. " entries in ShaDa: " .. table.concat(names, " "))
    end)
  end },

  { "an empty 'shada' (ShaDa off) stays empty", function()
    local saved = vim.o.shada
    kill_server()
    local ok, err = pcall(function()
      t("-f", "/dev/null", "new-session", "-d", "-s", "a", "-n", "one", "-x", "80", "-y", "24")
      vim.o.shada = ""
      oil.setup({ socket = SOCK })
      oil.open()
      assert(vim.o.shada == "", "'shada' is now " .. vim.o.shada)
    end)
    pcall(vim.cmd, "bwipeout!")
    kill_server()
    vim.o.shada = saved
    oil.config.socket = nil
    tmux.socket = nil
    assert(ok, err)
  end },
}
