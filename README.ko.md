[English](README.md) | 한국어

# tmux-oil.nvim

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Neovim >= 0.10](https://img.shields.io/badge/Neovim-%E2%89%A5%200.10-57A143.svg?logo=neovim&logoColor=white)

**tmux window를 텍스트처럼 편집한다.** window 하나에 한 줄, session은 헤더, `:w`로 적용한다.

![demo](demo/demo.gif)

## Why

[oil.nvim](https://github.com/stevearc/oil.nvim)은 디렉토리를 buffer로 바꾼다. 텍스트를 고치면 파일 시스템이 따라온다. tmux-oil.nvim은 같은 모델을 tmux window에 적용한다. buffer가 원하는 상태이고, `:w`는 모든 action을 보여준 뒤 tmux를 그 상태에 맞춘다. 한 줄의 identity는 이름이 아니라 숨겨진 `@id` anchor라서 이름에는 무엇이든 들어갈 수 있다. heuristic은 없다. anchor가 있는 줄은 그 window이고, anchor가 없는 줄은 새 window이며, 사라진 줄은 kill이다.

## Features

- 줄을 고쳐 window 이름 변경
- `ddp`로 window 순서 변경
- 다른 session 헤더 아래로 줄을 옮겨 window를 session 간 이동
- `dd`로 window kill
- 새 줄을 입력해 window 생성
- `/`로 끝나는 줄로 새 session 생성, 그 아래 줄의 window가 들어간다
- 이름을 비우면 tmux `automatic-rename` 유지
- 실행 전에 모든 action을 나열하는 oil 방식의 확인창
- buffer 밖에서 만든 window는 절대 kill하지 않음
- active pane의 프로그램 아이콘
- cursor가 현재 window에 놓임
- popup에서 쓰는 선택 기능: cursor를 따라가는 live preview

## Requirements

- Neovim ≥ 0.10
- tmux ≥ 3.3
- Nerd Font (선택, 아이콘용. [Icons](#icons) 참고)
- `python3` (popup launcher에만 필요)

Lua 의존성은 없다. [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons)가 있으면 아이콘 색에 쓴다.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "minhyeoky/tmux-oil.nvim", opts = {} }
```

### tmux popup

popup 크기는 내용(session 수, window 수, 가장 긴 줄)에 맞추고 client 크기로 제한한다. `display-popup`은 실행 시점에 크기를 받으므로 `bin/tmux-oil-popup`이 nvim을 띄우기 전에 크기를 계산한다.

```tmux
bind s run-shell "~/.local/share/nvim/lazy/tmux-oil.nvim/bin/tmux-oil-popup"
```

경로는 lazy.nvim의 기본 설치 디렉토리다. 다른 plugin manager를 쓰면 plugin의 `bin/tmux-oil-popup`을 가리키게 바꾼다. `prefix s`는 tmux 기본 session chooser(`choose-tree`)를 덮어쓰니, 그걸 남기려면 다른 키를 고른다.

border와 title은 `display-popup` flag를 그대로 넘긴다.

```tmux
bind s run-shell "~/.local/share/nvim/lazy/tmux-oil.nvim/bin/tmux-oil-popup --border rounded --border-style 'fg=#665c54' --title ''"
```

`--border`는 `single`·`rounded`·`double`·`heavy`·`simple`·`padded`·`none` 중 하나이고, 없으면 tmux의 `popup-border-lines` 옵션을 따른다. `--title ''`은 위쪽 테두리의 제목을 뺀다.

고정 크기를 원하면:

```tmux
bind T display-popup -E -w 80% -h 80% "nvim -c 'lua require(\"tmux-oil\").open({ popup = true })'"
```

## Usage

buffer는 다음으로 연다.

- `:TmuxOil`
- 직접 만든 mapping. 예: `vim.keymap.set("n", "<leader>tw", "<cmd>TmuxOil<cr>")`
- tmux의 `prefix s` (위 popup binding 사용)

편집할 수 있는 텍스트는 window 또는 session **이름**뿐이다. 나머지(index, 아이콘, title, pane 수)는 virtual text다. 열면 cursor는 client가 있는 window에 놓인다(`$TMUX`가 있어야 하고, 없으면 1행). `R`은 cursor를 같은 window에 유지하고, 그 window가 사라졌으면 같은 행 번호에 둔다.

### Keys (buffer-local)

| Key | Action |
|---|---|
| `<CR>` | cursor 아래 window로 전환 (popup을 닫음) |
| `q` | 닫기 (저장하지 않은 편집이 있으면 물어봄) |
| `R` | tmux에서 다시 읽기 |
| `gc` | cwd 열 토글 |
| `gt` | pane title을 이름으로 복사 |
| `cc` `S` | 이름을 지우고 다시 입력 (window는 유지) |
| `0` `^` `I` | 이름의 시작으로 이동 / 거기서 입력 시작 |
| `g?` | 도움말 |
| `:w` `:wq` `:x` | 검토 후 적용(`:wq`·`:x`는 적용 뒤 닫는다) |

확인창에서는 `y` `Y` `o` `O`가 수락, `n` `N` `c` `C` `q` `<Esc>` `<C-c>`가 취소다.

### Edits

한 줄의 identity는 줄 머리에 숨겨진 `$N` / `@N` anchor다(앞의 공백은 무시한다). anchor를 유지하는 편집(`cw`, `cc`, `:s`, `ddp`)은 그 window를 편집하고, 줄 전체를 지우면 kill, anchor 없는 줄은 window 생성이다.

| Edit | tmux command |
|---|---|
| window 이름 변경 | `rename-window` |
| session 이름 변경 | `rename-session` |
| window 이름 비우기 | `set-option -w automatic-rename on` |
| 줄 이동 (`ddp`) | `move-window` (순서) |
| 다른 session 헤더 아래로 줄 이동 | `move-window` (session 간) |
| 줄 삭제 (`dd`) | `kill-window` (session 헤더는 `kill-session`) |
| 새 줄 입력 | `new-window` (이름이 비면 `-n` 생략) |
| `/`로 끝나는 줄 입력 | `new-session` (그 아래 줄의 window를 생성하거나 이동해 넣는다; 이름에 `:`·`.` 불가) |

### Follow cursor (popup 전용)

`follow_cursor = true`이면 cursor를 window 줄로 옮길 때 popup 뒤에서 그 window가 선택되고, 필요하면 session도 전환된다. session 줄에서는 아무 일도 없다.

![follow cursor](demo/follow.gif)

- `q`, `:q` 등 `<CR>` 없이 닫는 모든 경우에 client는 popup을 연 window로 돌아간다. `<CR>`은 선택을 유지한다.
- 따라가던 window를 kill하는 `:w`는 먼저 원래 window로 복원한다(원래 window도 kill되면 생략).
- popup 밖에서는 무시된다. window를 선택하면 nvim 자신의 window를 떠나게 되기 때문이다.

## Configuration

```lua
require("tmux-oil").setup({
  skip_confirm = false,   -- apply on :w without the confirmation float
  icons = true,           -- true (Nerd Font / devicons) | "ascii" | false
  icon_map = {},          -- command → "glyph" | { icon = "", hl = "Group" } | { key = "py" } (devicons key)
  show_cwd = false,       -- show the cwd column (toggle per buffer with gc)
  indent = 0,             -- spaces before a window's index; sessions are separated by a rule
  socket = nil,           -- tmux -L <socket>
  preview_delay = 40,     -- ms of insert-mode typing before marks and the preview redraw; normal-mode edits redraw at once; 0 = always immediately
  follow_cursor = false,  -- popup only: select the window under the cursor; cancel restores the origin
  follow_delay = 0,       -- ms the cursor must rest before following; 0 = on every line change
})
```

## Icons

아이콘은 active pane의 `pane_current_command`를 정확히 일치시켜 고른다. 색은 nvim-web-devicons가 있으면 거기서, 없으면 `Special`을 쓴다.

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

Fallback 순서:

- 그 외 명령어는 아이콘이 없고, 이름이 정렬되도록 칸은 비워 둔다.
- Nerd Font가 없으면 `icons = "ascii"`가 `ai`, `sh`, `vi`, `py`, `js`, `go`, `rs`, `lua`, `git`, `dk`, `mk`, `log`, `tm`, `ssh`, `top`을 보여준다.
- `icons = false`는 아이콘 열을 없앤다.

## How it works

1. **Read.** tmux에서 session과 window를 읽는다.
2. **Render.** 각 객체를 숨겨진 anchor(`$N` / `@N`)로 시작하는 줄로 그린다. index, 아이콘, title, pane 수는 virtual text다.
3. **Edit.** 자유롭게 편집한다. 편집을 따라 mark와 보류 중인 action의 preview가 갱신된다.
4. **Parse.** `:w`에서 buffer를 anchor가 있는 줄, 없는 줄, 그 줄이 속한 session으로 다시 파싱한다.
5. **Diff.** 화면에 보이던 낡은 상태가 아니라 새로 읽은 tmux 상태와 비교한다. 그 사이 다른 곳에서 만든 window는 kill되지 않는다.
6. **Apply.** action은 정해진 순서(rename → new → move → kill)로 하나씩 실행한다. session에서 window를 빼내기 전에 placeholder window가 그 session을 살려 두고(tmux는 마지막 window가 떠나면 session을 없앤다) 끝나면 제거한다. nvim이 실행 중인 window는 마지막에 kill한다.

buffer를 그린 뒤 tmux server가 재시작됐다면 `:w`는 거부하고 `R`을 누르라고 알린다.

## Limitations

- pane layout은 편집할 수 없다. pane 수는 표시 전용이다.
- linked window(한 window가 여러 session에 속함)는 지원하지 않는다.
- `bin/tmux-oil-popup`은 이름과 title을 East Asian width로 재고, buffer처럼 host 이름과 같은 title은 숨긴다. Lua 설정은 읽지 않는다. `show_cwd = true`, `indent > 2`, `ambiwidth=double`이면 popup이 몇 칸 좁을 수 있다(buffer는 `nowrap`이라 긴 줄은 줄바꿈 없이 잘린다). popup 크기는 렌더된 줄 기준이고, 변경 미리보기 마크(`✎ rename`, `→ session`)는 그 줄의 title 자리를 빌려 쓴다 — 마크가 보이는 동안 title이 `…`로 줄어든다.
- anchor처럼 보이는 이름(`$9`, `@9x`)은 새 window·session 이름으로 쓸 수 없다 — 그 id의 줄로 읽힌다. window 이름은 `/`로 끝날 수 없다.
- tmux 3.3 미만은 지원하지 않는다.

## Development

```sh
make test   # isolated tmux server: tmux -L tmux-oil-test
```

테스트는 기본 tmux server를 건드리지 않는다. `demo/`의 demo도 별도 server(`tmux -L tmux-oil-demo`)에서 돌며 [VHS](https://github.com/charmbracelet/vhs)로 녹화한다.

```sh
vhs demo/demo.tape     # repo 루트에서: demo/demo.gif, demo/demo.mp4, demo/frames/ 를 쓴다
vhs demo/follow.tape   # demo/follow.gif
ffmpeg -y -ss 16.5 -i demo/demo.mp4 -frames:v 1 -vf pad=1400:700:100:0:0x282828 demo/hero.png  # social preview 이미지
```

녹화에는 VHS(ttyd·ffmpeg 포함), zsh, JetBrainsMono Nerd Font가 필요하고, `~/.local/share/nvim/lazy/`에 gruvbox.nvim과 nvim-web-devicons가 있으면 그걸 쓴다. `demo/setup.sh`가 `demo/nvim/init.lua`를 `~/.config/tmux-oil-demo/`에 링크한다.

## Related

- [oil.nvim](https://github.com/stevearc/oil.nvim): 이 아이디어의 파일 시스템 버전이자 영감의 원천.
- [asdf8601/tmux-oil.nvim](https://github.com/asdf8601/tmux-oil.nvim): 같은 아이디어를 pane 단위 한 줄로 푼 구현.
- [tmux-sessionizer](https://github.com/ThePrimeagen/tmux-sessionizer), [sesh](https://github.com/joshmedeski/sesh): 편집이 아니라 이동을 위한 session switcher.

## License

[MIT](LICENSE)
