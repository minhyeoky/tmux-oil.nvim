# tmux-oil.nvim

Edit your tmux windows the way [oil.nvim](https://github.com/stevearc/oil.nvim) edits directories: one line per window, sessions as headers, `:w` applies.

```
0
  1 󰚩                  ✳ Workspace 장비 접근   ⊞2
  2 󰚩 영상/음성 제작   ✳ 리서치
  3 󰚩 카톡봇           ✳ 카카오톡 봇 진행 상황
1
  1  zsh
```

- The only editable text is the window or session **name**. Everything else (index, icon, title, pane count) is virtual text.
- Rename a line → `rename-window`. Empty name → tmux `automatic-rename` stays on.
- Move lines (`ddp`) → window order. Move a line under another session header → `move-window` across sessions.
- Delete a line → `kill-window`. Write a new line → `new-window`.
- Changes are listed and confirmed on `:w`, oil style. Windows created outside the buffer are never killed.

Requires Neovim ≥ 0.10 and tmux ≥ 3.3. No dependencies; nvim-web-devicons is used for icon colours when present.

## Install

```lua
{ "minhyeoky/tmux-oil.nvim", opts = {} }
```

tmux popup:

```tmux
bind T display-popup -E -w 80% -h 80% "nvim -c 'lua require(\"tmux-oil\").open({ popup = true })'"
```

## Keys (buffer-local)

| Key | Action |
|---|---|
| `<CR>` | switch to the window under the cursor (closes the popup) |
| `q` | close (asks if there are unsaved edits) |
| `R` | reload from tmux |
| `gc` | toggle cwd column |
| `gt` | copy the pane title into the name |
| `g?` | help |

## Options

```lua
require("tmux-oil").setup({
  skip_confirm = false,
  icons = true,
  icon_map = {},      -- command → icon
  show_cwd = false,
  socket = nil,       -- tmux -L <socket>
})
```

## Tests

```sh
make test   # isolated tmux server: tmux -L tmux-oil-test
```
