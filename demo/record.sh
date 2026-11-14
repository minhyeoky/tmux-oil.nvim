#!/bin/sh
# Records demo/demo.gif and demo/demo.mp4 from a real terminal window. macOS + Alacritty only:
#   sh demo/record.sh        (from a shell running inside Alacritty)
# Needs swiftc, ffmpeg (with ffprobe), python3 and git, and the programs it shows: nvim,
# lazygit and node. Also: a running default tmux server (its look and environment are
# copied), a Neovim config that loads this checkout's tmux-oil (checked below), and a 2x
# display with Alacritty's default window decorations (the crop below).
#
# What is real: the terminal, the tmux look (display options copied from the default server),
# the Neovim config in the popup, and nvim, lazygit, node and tail in the windows. What is not:
# the server (-L tmux-oil-demo, in a scratch workspace, never the default server), the host
# name in the status line, and the two agent windows (stand-ins, see real/setup.sh).
#
# The window must stay visible while this runs (about 40 s); it does not need focus.
# DEMO_POSITION='{x=2600,y=120}' places it (Alacritty's window.position).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${TMPDIR:-/tmp}/tmux-oil-demo-rec"
ALACRITTY="${ALACRITTY:-/Applications/Alacritty.app/Contents/MacOS/alacritty}"
TMUX_BIN="$(command -v tmux)"
SOCK=tmux-oil-demo
BG=0x282828   # the terminal background
T() { env -u TMUX -u TMUX_PANE "$TMUX_BIN" -L "$SOCK" "$@"; }
rm -rf "$OUT"; mkdir -p "$OUT"

# The popup's Neovim is the machine's own: what it loads must be this checkout's code.
LOADED="$(nvim --headless -i NONE -c 'lua io.write(debug.getinfo(require("tmux-oil").open, "S").source:sub(2))' -c 'qa!' 2> /dev/null || true)"
LOADED="${LOADED%/lua/tmux-oil/init.lua}"
if [ -z "$LOADED" ] || ! diff -rq "$LOADED/lua" "$ROOT/lua" > /dev/null || ! cmp -s "$LOADED/bin/tmux-oil-popup" "$ROOT/bin/tmux-oil-popup"; then
  echo "record.sh: Neovim loads tmux-oil from '${LOADED:-nowhere}': not the code of this checkout" >&2
  exit 1
fi

swiftc -O -o "$OUT/winid" "$HERE/real/winid.swift"
sh "$HERE/real/setup.sh" "$ROOT" "$SOCK" > /dev/null || { T kill-server 2> /dev/null; exit 1; }

# The new window is the one Alacritty window id that was not there before. Anything else
# (none, or two) stops here: a still of the wrong window would show someone's real terminal.
"$OUT/winid" | sort > "$OUT/before"
"$ALACRITTY" msg create-window -o window.dimensions.columns=100 -o window.dimensions.lines=28 \
  -o font.size=20 ${DEMO_POSITION:+-o "window.position=$DEMO_POSITION"} \
  -e "$TMUX_BIN" -L "$SOCK" attach -t dev
sleep 2
"$OUT/winid" | sort > "$OUT/after"
WID="$(comm -13 "$OUT/before" "$OUT/after")"
CLIENT="$(T list-clients -F '#{client_name}')"
if [ "$(printf '%s\n' "$WID" | grep -c .)" != 1 ] || [ "$(printf '%s\n' "$CLIENT" | grep -c .)" != 1 ]; then
  T kill-server
  echo "record.sh: expected one new Alacritty window and one demo client, got '$WID' and '$CLIENT'" >&2
  exit 1
fi

python3 "$HERE/real/record.py" "$TMUX_BIN" "$SOCK" "$WID" "$CLIENT" "$OUT" || { T kill-server; exit 1; }
T kill-server   # the window closes with its client

# A still is the window at 2x: the top 46 px are its empty title strip, the corners are
# transparent. Both go: cropped, and laid over the background colour.
SIZE="$(ffprobe -loglevel error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$(ls "$OUT"/frames/*.png | head -1)")"
LAY="[1][0]overlay=shortest=1,crop=iw:ih-46:0:46"
gif="$LAY,fps=12,scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
mp4="$LAY,fps=30,scale=1200:-2:flags=lanczos,format=yuv420p"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$OUT/frames.txt" -f lavfi -i "color=c=$BG:s=$SIZE:r=30" \
  -filter_complex "$gif" "$HERE/demo.gif"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$OUT/frames.txt" -f lavfi -i "color=c=$BG:s=$SIZE:r=30" \
  -filter_complex "$mp4" -c:v libx264 -crf 20 -movflags +faststart "$HERE/demo.mp4"
ls -l "$HERE/demo.gif" "$HERE/demo.mp4"
