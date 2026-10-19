#!/usr/bin/env python3
"""Runs a scratch Claude Code in a pty against mock_api.py with probe_hook.sh answering in one shape, and saves what
the window shows (and the transcript view, ctrl+o) after one prompt.

Usage: run_shape.py CLAUDE_BINARY SHAPE OUT_DIR [PROJECT_DIR]   (needs pyte; PROJECT_DIR outside your home)

Nothing of the user's is touched: HOME and CFFIXED_USER_HOME are OUT_DIR/home, the API is the mock on 127.0.0.1, the
key is a dummy. OUT_DIR gets screen.txt, transcript.txt, requests.jsonl (what Claude Code sent the "model") and
payloads.jsonl (what the hook was given).
"""
import json
import os
import pty
import select
import signal
import socket
import subprocess
import sys
import time

import pyte

CLAUDE, SHAPE, OUT = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
# The project folder: outside any folder of the user's, so Claude Code finds no CLAUDE.md above it.
PROJECT = os.path.abspath(sys.argv[4]) if len(sys.argv) > 4 else f"{OUT}/project"
HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "sk-ant-api03-" + "x" * 80 + "-mockAA"
COLS, ROWS = 140, 60

home, project = f"{OUT}/home", PROJECT
os.makedirs(f"{home}/.claude", exist_ok=True)
os.makedirs(project, exist_ok=True)
for name in ("answered", "requests.jsonl", "payloads.jsonl"):
    if os.path.exists(f"{OUT}/{name}"):
        os.remove(f"{OUT}/{name}")
hook = {"type": "command", "command": f"{HERE}/probe_hook.sh"}
if SHAPE == "async-rewake":  # an @internal option of 2.1.302: runs in the background, exit 2 wakes the model
    hook.update(asyncRewake=True, rewakeSummary="VibeSwitcher · from the user")
settings = {"hooks": {event: [{"hooks": [hook]}] for event in ("Stop", "UserPromptSubmit")}}
json.dump(settings, open(f"{home}/.claude/settings.json", "w"))
json.dump({"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
           "customApiKeyResponses": {"approved": [KEY[-20:]], "rejected": []},
           "projects": {project: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}}},
          open(f"{home}/.claude.json", "w"))

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
mock = subprocess.Popen([sys.executable, f"{HERE}/mock_api.py", str(port), f"{OUT}/requests.jsonl"])

env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC", "VIBESWITCHER"))}
env.update(HOME=home, CFFIXED_USER_HOME=home, ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}", ANTHROPIC_API_KEY=KEY,
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1", TERM="xterm-256color",
           VSTEST_SHAPE=SHAPE, VSTEST_OUT=OUT)

screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(project)
    import fcntl, struct, termios
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    os.execve(CLAUDE, [CLAUDE], env)
import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))


def pump(quiet, limit):
    """Feeds output to the screen until `quiet` seconds pass with none, or `limit` seconds in all."""
    start = last = time.time()
    while time.time() - start < limit and time.time() - last < quiet:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            stream.feed(data)
            last = time.time()


def dump(name):
    with open(f"{OUT}/{name}", "w") as f:
        f.write("\n".join(line.rstrip() for line in screen.display).rstrip() + "\n")


try:
    pump(quiet=5, limit=40)
    dump("start.txt")
    for ch in "hello":
        os.write(fd, ch.encode())
        time.sleep(0.05)
    time.sleep(0.5)
    os.write(fd, b"\r")
    pump(quiet=8, limit=90)
    dump("screen.txt")
    os.write(fd, b"\x0f")  # ctrl+o: transcript view
    pump(quiet=3, limit=15)
    dump("transcript.txt")
finally:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    mock.terminate()
