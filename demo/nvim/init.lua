-- Minimal config for the demo recording (NVIM_APPNAME=tmux-oil-demo).
local root = vim.env.TMUX_OIL_ROOT or vim.fn.expand("~/tmux-oil.nvim")
vim.opt.rtp:prepend(root)
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
