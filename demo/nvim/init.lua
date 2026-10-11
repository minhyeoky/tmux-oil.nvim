-- Minimal config for the demo recording (NVIM_APPNAME=tmux-oil-demo, linked by setup.sh).
-- Reached through the symlink: resolve it to find the checkout.
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
vim.opt.rtp:prepend(root)
-- Optional: the colorscheme and icons used in the recording, if a lazy.nvim install has them.
for _, p in ipairs({ "gruvbox.nvim", "nvim-web-devicons" }) do
  local dir = vim.fn.expand("~/.local/share/nvim/lazy/" .. p)
  if vim.fn.isdirectory(dir) == 1 then vim.opt.rtp:prepend(dir) end
end
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.ruler = false
pcall(function()
  require("gruvbox").setup({ contrast = "hard", transparent_mode = false })
  vim.cmd("colorscheme gruvbox")
end)
require("tmux-oil").setup({ preview_delay = 0 })
