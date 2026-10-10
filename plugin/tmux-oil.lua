if vim.g.loaded_tmux_oil then
  return
end
vim.g.loaded_tmux_oil = true

vim.api.nvim_create_user_command("TmuxOil", function()
  require("tmux-oil").open()
end, { desc = "Edit tmux windows as a buffer" })
