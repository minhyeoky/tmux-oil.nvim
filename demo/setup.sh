#!/bin/sh
# Builds the demo tmux server (-L tmux-oil-demo). Fixture only — never the default server.
set -e
SOCK=tmux-oil-demo
HERE="$(cd "$(dirname "$0")" && pwd)"
tmux -L "$SOCK" kill-server 2>/dev/null || true
# Programs the icon table knows, so the demo shows real icons. "claude" is a renamed sleep.
BIN="$(mktemp -d)"; cp /bin/sleep "$BIN/claude"; cp /bin/sleep "$BIN/ipython"; cp /bin/sleep "$BIN/node"
export PATH="$BIN:$PATH"
T() { tmux -L "$SOCK" "$@"; }
T -f "$HERE/demo.conf" new-session -d -s dev -n api -x 110 -y 28 "claude 9999"
T select-pane -t dev:api -T "✳ Refactor auth middleware"
T new-window -d -t dev -n web "node 9999"
T select-pane -t dev:web -T "vite dev server"
T new-window -d -t dev -n "" "claude 9999"
T select-pane -t "dev:3" -T "✳ Write release notes"
T new-window -d -t dev -n docs
T new-session -d -s infra -n k9s "ipython 9999"
T select-pane -t infra:k9s -T "cluster: prod"
T new-window -d -t infra -n logs "zsh"
T select-window -t dev:api
echo "$BIN"
