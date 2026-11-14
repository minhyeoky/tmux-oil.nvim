#!/bin/sh
# Real-screen demo fixture: isolated server (-L tmux-oil-demo), real programs in a neutral
# workspace, the look copied from the default server's display options (no plugins, no hooks).
set -e
ROOT="$1"                       # plugin checkout (for bin/tmux-oil-popup)
SOCK="$2"                       # socket name of the demo server
WS=/tmp/tmux-oil-demo-ws
T() { env -u TMUX -u TMUX_PANE tmux -L "$SOCK" "$@"; }
if ! tmux show-environment -g > /dev/null 2>&1; then
  echo "setup.sh: needs a running default tmux server: its look and environment are copied" >&2
  exit 1
fi
T kill-server 2>/dev/null || true
rm -rf "$WS"; mkdir -p "$WS/bin" "$WS/acme"
git clone -q --branch main "$ROOT" "$WS/acme/tmux-oil.nvim"
cp /bin/sleep "$WS/bin/claude"   # the agent windows are stand-ins: a real agent session shows account details
printf '%s\n' '2026-11-14T09:12:10Z INFO  request_id=a81f GET /health 200 2ms' \
  '2026-11-14T09:12:12Z INFO  request_id=a820 POST /login 200 41ms' \
  '2026-11-14T09:12:15Z WARN  request_id=a821 GET /me 401 3ms' > "$WS/acme/api.log"
# A pane's PATH comes from whoever creates the window: the stand-in is named by its path.
screen() { prog=$1; shift; printf 'printf "\\033[?25l\\n"; '; for l in "$@"; do printf 'printf "  %%s\\n" "%s"; ' "$l"; done; printf 'exec "%s" 9999' "$WS/bin/$prog"; }
# The server gets the environment a real popup gets: the default server's global one, and
# nothing of the recording shell.
CLEAN="env -i HOME=$HOME USER=$USER SHELL=/bin/zsh LANG=${LANG:-en_US.UTF-8} TERM=xterm-256color PATH=$PATH"
env -i /bin/sh -c 'eval "$1"; unset TMUX TMUX_PANE; shift; exec "$@"' sh "$(tmux show-environment -g -s)" \
  tmux -L "$SOCK" -f /dev/null new-session -d -s dev -n api -x 100 -y 28 -c "$WS/acme" \
  "$(screen claude '✳ Refactor auth middleware' '' '⏺ Read src/auth/middleware.ts' '⏺ Edit src/auth/middleware.ts' '  Extracted verifyToken(); 3 call sites updated' '' '> ▌')"
# The look: display options copied value by value from the default server. @cc_live and
# @cc_chip are that machine's own formats for the agent chips in the status line: a server
# without them skips them.
for o in status status-position status-style status-left status-left-length status-right-length \
  status-justify window-status-format window-status-current-format window-status-separator \
  window-status-style window-status-current-style window-status-bell-style window-status-activity-style \
  message-style mode-style pane-border-style pane-active-border-style pane-border-status \
  pane-border-format pane-border-lines popup-border-lines popup-border-style @cc_live @cc_chip \
  base-index pane-base-index renumber-windows; do
  v="$(tmux show-options -gv "$o" 2>/dev/null)" && T set-option -g "$o" "$v"
done
# status-right carries the host name: keep the date and time, name the host "demo".
T set-option -g status-right "$(tmux show-options -gv status-right | sed 's/#h/demo/')"
T set-option -g automatic-rename on
T set-option -g default-terminal "tmux-256color"
T set-option -ga terminal-overrides ",*:Tc"
T set-option -s escape-time 0
T set-option -g prefix C-a
# Windows the demo creates: a plain shell, and no host name as the pane title.
T set-option -g default-command "$CLEAN PS1='%1~ %# ' zsh -f"
T set-hook -g after-new-window 'select-pane -T ""'
T bind-key s run-shell "TMUX_OIL_SOCKET=$SOCK '$ROOT/bin/tmux-oil-popup'"
T move-window -r -t dev:
T select-pane -t dev:api -T "✳ Refactor auth middleware"
T new-window -d -t dev: -n editor -c "$WS/acme/tmux-oil.nvim" "nvim lua/tmux-oil/diff.lua"
T select-pane -t dev:editor -T "diff.lua"
W=$(T new-window -d -P -F '#{window_id}' -t dev: -c "$WS/acme" \
  "$(screen claude '✳ Write release notes' '' '⏺ Read CHANGELOG.md' '⏺ Write docs/releases/v2.4.md' '' '> ▌')")
T select-pane -t "$W" -T "✳ Write release notes"
T new-window -d -t dev: -n git -c "$WS/acme/tmux-oil.nvim" "lazygit"
T select-pane -t dev:git -T "lazygit"
T new-session -d -s infra -n repl -c "$WS/acme" "node"
T select-pane -t infra:repl -T "node"
T new-window -d -t infra: -n logs -c "$WS/acme" "tail -f api.log"
T select-pane -t infra:logs -T "tail -f api.log"
# Agent state chips, as a hook sets them on a real agent pane.
T set-option -p -t dev:api @cc_state "🧠"
T set-option -p -t "$W" @cc_state "🔔"
T select-window -t dev:api
# The recording plays fixed keys: every window must be there, running what is expected. A
# program that is not installed leaves no window; a stand-in that is not the stand-in would
# be a real agent.
sleep 1
GOT="$(T list-windows -a -F '#{session_name}:#{pane_current_command}' | tr '\n' ' ')"
WANT="dev:claude dev:nvim dev:claude dev:lazygit infra:node infra:tail "
if [ "$GOT" != "$WANT" ] || T list-panes -a -F '#{pane_start_command}' | grep claude | grep -qv "$WS/bin/claude"; then
  echo "setup.sh: the fixture runs '$GOT', expected '$WANT'" >&2
  exit 1
fi
