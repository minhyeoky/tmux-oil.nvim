#!/bin/sh
# Builds the demo tmux server (-L tmux-oil-demo). Fixture only — never the default server.
set -e
SOCK=tmux-oil-demo
HERE="$(cd "$(dirname "$0")" && pwd)"
tmux -L "$SOCK" kill-server 2>/dev/null || true
# nvim inside the popup runs with NVIM_APPNAME=tmux-oil-demo: link its config to demo/nvim.
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-oil-demo"
mkdir -p "$CFG"
ln -sfn "$HERE/nvim/init.lua" "$CFG/init.lua"
# Programs the icon table knows, so the demo shows real icons. "claude" is a renamed sleep.
BIN="${TMPDIR:-/tmp}/tmux-oil-demo-bin"
mkdir -p "$BIN"; for p in claude ipython node zsh; do cp /bin/sleep "$BIN/$p"; done
export PATH="$BIN:$PATH"
T() { tmux -L "$SOCK" "$@"; }
# Each pane prints a banner and then execs the fake program, so the screen behind the popup
# shows which window is selected (follow_cursor) and the icon still comes from the command.
screen() { # screen <prog> <lines…>: a shell command for new-session/new-window
  # lines go through sh -c inside double quotes: no `"`, backquote, backslash or $name in them
  prog=$1; shift
  printf 'printf "\\n"; '
  for l in "$@"; do printf 'printf "  %%s\\n" "%s"; ' "$l"; done
  printf 'exec "%s" 9999' "$prog"
}
T -f "$HERE/demo.conf" new-session -d -s dev -n api -x 110 -y 28 \
  "$(screen claude '✳ Refactor auth middleware' '' '⏺ Read src/auth/middleware.ts' '⏺ Edit src/auth/middleware.ts' '  Extracted verifyToken(); 3 call sites updated' '' '> ▌')"
T select-pane -t dev:api -T "✳ Refactor auth middleware"
T new-window -d -t dev -n web \
  "$(screen node 'VITE v6.0.3  ready in 412 ms' '' '➜  Local:   http://localhost:5173/' '➜  Network: use --host to expose' '' '12:04:11 [vite] hmr update /src/App.tsx')"
T select-pane -t dev:web -T "vite dev server"
T new-window -d -t dev -n "" \
  "$(screen claude '✳ Write release notes' '' '⏺ Read CHANGELOG.md' '⏺ Write docs/releases/v2.4.md' '' '> ▌')"
T select-pane -t "dev:3" -T "✳ Write release notes"
T new-window -d -t dev -n docs "$(screen zsh '~/docs' '' '$ mkdocs serve' 'INFO    -  Serving on http://127.0.0.1:8000/')"
T new-session -d -s infra -n k9s \
  "$(screen ipython ' Context: prod                    <0> all' ' Cluster: prod-eu-1               <1> default' '' ' NAME                     READY   STATUS    RESTARTS' ' api-7d9f8c6b4-2xk9p      1/1     Running   0' ' web-5c8d7f9b6-q4m2r      1/1     Running   0' ' worker-6b7c8d9e5-z8n3t   1/1     Running   2')"
T select-pane -t infra:k9s -T "cluster: prod"
T new-window -d -t infra -n logs "$(screen zsh '$ kubectl logs -f deploy/api' '' '2026-10-11T12:04:10Z INFO  request_id=a81f GET /health 200 2ms' '2026-10-11T12:04:12Z INFO  request_id=a820 POST /login 200 41ms' '2026-10-11T12:04:15Z WARN  request_id=a821 GET /me 401 3ms')"
# A window the demo creates runs a fixture too, not the recording machine's shell and prompt.
# Its PATH depends on the client that creates it, so the fake program is named by its path.
T set -g default-command "$(screen "$BIN/zsh" '~/src/app' '' '$ ▌')"
T select-window -t dev:api
echo "$BIN"
