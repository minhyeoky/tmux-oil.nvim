-- Minimal runner: nvim --headless -u NONE -l tests/run.lua
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

local total, failed = 0, 0
for _, path in ipairs(vim.fn.glob(root .. "/tests/*_spec.lua", false, true)) do
  local spec = dofile(path)
  local file = vim.fn.fnamemodify(path, ":t")
  for _, t in ipairs(spec) do
    total = total + 1
    local ok, err = xpcall(t[2], debug.traceback)
    if ok then
      print("ok   " .. file .. ": " .. t[1])
    else
      failed = failed + 1
      print("FAIL " .. file .. ": " .. t[1] .. "\n" .. tostring(err))
    end
  end
end
print(string.format("%d tests, %d failed", total, failed))
os.exit(failed > 0 and 1 or 0)
