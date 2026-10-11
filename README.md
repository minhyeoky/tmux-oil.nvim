# tmux-oil.nvim

Edit your tmux windows the way [oil.nvim](https://github.com/stevearc/oil.nvim) edits directories: one line per window, sessions as headers, `:w` applies.

```
0                                              3 windows · attached
 1 󰚩                ✳ Workspace 장비 접근   ⊞2
 2 󰚩 영상/음성 제작  ✳ 리서치
 3 󰚩 카톡봇          ✳ 카카오톡 봇 진행 상황

1                                              1 window
 1 
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

### tmux popup

The popup is sized to its content (sessions, windows, longest line), clamped to the client. `display-popup` takes its size at launch, so `bin/tmux-oil-popup` computes it before nvim starts:

```tmux
bind s run-shell "~/.local/share/nvim/lazy/tmux-oil.nvim/bin/tmux-oil-popup"
```

The path is lazy.nvim's default install dir; with another plugin manager, point it at the plugin's `bin/tmux-oil-popup`. Needs `python3`.

Fixed size instead:

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
| `cc` `S` | clear the name and retype it (the window is kept) |
| `0` `^` `I` | go to / insert at the start of the name |
| `g?` | help |

A line's identity is its hidden `$N` / `@N` anchor at column 0. Any edit that keeps it (`cw`, `cc`, `:s`, `ddp`) edits that window; deleting the whole line kills it; a line without an anchor creates a window.

## Options

```lua
require("tmux-oil").setup({
  skip_confirm = false,
  icons = true,       -- true (Nerd Font / devicons) | "ascii" | false
  icon_map = {},      -- command → "glyph" | { icon = "", hl = "Group" } | { key = "py" } (devicons key)
  show_cwd = false,
  indent = 0,         -- spaces before a window's index; sessions are separated by a rule
  socket = nil,       -- tmux -L <socket>
  preview_delay = 40, -- ms after an edit before marks and the change preview redraw; 0 = immediately
})
```

## Icons

The icon follows the active pane's `pane_current_command` (exact match). Colours come from nvim-web-devicons when installed, otherwise `Special`.

| Command | Icon |
|---|---|
| `claude` `claude.exe` `codex` `opencode` `aider` `pi` `gemini` `amp` `goose` `crush` `copilot` | 󰚩 (`TmuxOilAgent`) |
| `zsh` `bash` `sh` `fish` | shell |
| `nvim` `vim` `vi` | vim |
| `python` `python3` `uv` `ipython` | py |
| `node` `bun` `deno` `npm` `pnpm` `yarn` | js |
| `go` / `cargo` `rustc` / `lua` | go / rs / lua |
| `git` `lazygit` `gh` `tig` | git |
| `docker` `docker-compose` `kubectl` `k9s` | Dockerfile |
| `make` `cmake` `ninja` | Makefile |
| `tail` `less` `journalctl` | log |
| `tmux` | tmux |
| `ssh` `mosh` | 󰣀 (`DiagnosticWarn`) |
| `htop` `btop` `top` | monitor (`Comment`) |

Fallback ladder:
- Any other command gets no icon; the column stays blank so names stay aligned.
- No Nerd Font: `icons = "ascii"` shows `ai`, `sh`, `vi`, `py`, `js`, `go`, `rs`, `lua`, `git`, `dk`, `mk`, `log`, `tm`, `ssh`, `top`.
- `icons = false` removes the icon column.

## Tests

```sh
make test   # isolated tmux server: tmux -L tmux-oil-test
```
