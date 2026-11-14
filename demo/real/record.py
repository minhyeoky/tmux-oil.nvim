#!/usr/bin/env python3
"""Plays the demo in the demo client and captures its terminal window as stills.

usage: record.py <tmux> <socket> <window-id> <client> <out-dir>

Keys are typed with `tmux -L <socket> send-keys -K -c <client>`: they reach the popup,
need no focus, and can only reach the demo server. Stills come from `screencapture -l`, which
captures that one window whatever is in front of it. Writes <out-dir>/frames/ and
<out-dir>/frames.txt, an ffmpeg concat list with each still's real duration.
"""
import os
import subprocess
import sys
import threading
import time

TMUX, SOCK, WID, CLIENT, OUT = sys.argv[1:6]
SERVER = [TMUX, "-L", SOCK]
ENV = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
FRAMES = os.path.join(OUT, "frames")
os.makedirs(FRAMES, exist_ok=True)
stop = False


def capture():
    while not stop:
        path = os.path.join(FRAMES, "f_%d.png" % int(time.time() * 1000))
        subprocess.run(["screencapture", "-x", "-o", "-l", WID, path])


def keys(*names):
    subprocess.run(SERVER + ["send-keys", "-K", "-c", CLIENT, *names], env=ENV, check=True)


def typ(text, delay=0.07):
    for ch in text:
        keys("-l", ch)
        time.sleep(delay)


rest = time.sleep
thread = threading.Thread(target=capture)
thread.start()
try:
    rest(1.5)
    keys("C-a")
    keys("s")
    rest(2.5)
    # Edits follow: go on only if the popup belongs to the demo server.
    if subprocess.run(["pgrep", "-f", "tmux -L %s display-popup" % SOCK], capture_output=True).returncode != 0:
        raise SystemExit("no popup on the demo server: stopped before any edit")
    # a new window under the current one
    typ("o"); rest(0.3); typ("tests"); rest(0.3); keys("Escape"); rest(1.2)
    # rename the unnamed window
    typ("jj", 0.3); rest(0.4); typ("cc"); rest(0.3); typ("release-notes"); rest(0.3); keys("Escape"); rest(1.2)
    # move "editor" to the bottom of its session
    typ("k"); rest(0.5); typ("dd"); rest(0.6); typ("jp", 0.3); rest(1.2)
    # send "git" to the infra session
    typ("k"); rest(0.5); typ("dd"); rest(0.6); typ("G"); rest(0.6); typ("p"); rest(1.5)
    # close "logs"
    typ("k"); rest(0.5); typ("dd"); rest(1.6)
    # apply
    typ(":w"); rest(0.5); keys("Enter"); rest(3.5); typ("y"); rest(2.5)
    # jump to the renamed window: same window, still running
    typ("gg"); typ("jjj", 0.25); rest(0.9); keys("Enter"); rest(3.0)
finally:
    stop = True
    thread.join()

names = sorted(os.listdir(FRAMES))
stamps = [int(n[2:-4]) for n in names]
with open(os.path.join(OUT, "frames.txt"), "w") as out:
    for i, name in enumerate(names):
        out.write("file '%s'\n" % os.path.join(FRAMES, name))
        out.write("duration %.3f\n" % ((stamps[i + 1] - stamps[i]) / 1000 if i + 1 < len(names) else 0.5))
    out.write("file '%s'\n" % os.path.join(FRAMES, names[-1]))  # concat needs the last file twice
print("%d stills, %.1f s" % (len(names), (stamps[-1] - stamps[0]) / 1000))
