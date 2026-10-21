#!/usr/bin/env python3 -I
"""Records the pickers and dialogs Claude Code's slash commands open (/mcp, /model, ...) byte for byte from a SCRATCH
session: a scratch HOME (made here, removed after) with two scratch MCP servers (one a tiny stdio server written
here, one whose command fails), a scratch project folder, and a fake Messages API on 127.0.0.1, so no real account,
session or credential is touched. Built on capture-claude-status-rows.py's scratch session.

    python3 -I Tests/Tools/capture-claude-pickers.py COLS ROWS OUT.raw STEP... [--claude PATH] [--tui fullscreen|default]

A STEP is `/command` (typed, then Enter), `down`, `up`, `enter`, `esc`, `tab`, or `type:TEXT` (typed, no Enter). After
each the output is read for a moment and its byte offset recorded under `NN-step` (`01-/mcp`, `02-down`, ...) in
OUT.marks.json, beside `idle` (the idle screen before the first step). OUT.raw gets everything the program printed.
"""
import argparse
import importlib.util
import json
import os
import pty
import select
import shutil
import signal
import struct
import fcntl
import sys
import tempfile
import termios
import threading
import time
import http.server

HERE = os.path.dirname(os.path.abspath(__file__))
# No __pycache__ beside the tools for the module loaded here.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("status_rows", os.path.join(HERE, "capture-claude-status-rows.py"))
status_rows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status_rows)

# A stdio MCP server with one tool: enough for /mcp to list it as connected.
FAKE_MCP = r'''import json, sys
for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "id" not in message:
        continue
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": message["params"].get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "scratch-notes", "version": "1.0.0"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "add_note", "description": "Adds a note",
                             "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}) + "\n")
    sys.stdout.flush()
'''

KEYS = {"down": b"\x1b[B", "up": b"\x1b[A", "right": b"\x1b[C", "left": b"\x1b[D", "enter": b"\r", "esc": b"\x1b", "tab": b"\t"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cols", type=int)
    parser.add_argument("rows", type=int)
    parser.add_argument("out")
    parser.add_argument("steps", nargs="+")
    parser.add_argument("--claude", default=shutil.which("claude") or "claude")
    parser.add_argument("--tui", default="fullscreen", choices=["fullscreen", "default"])
    args = parser.parse_args()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), status_rows.FakeAPI)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = tempfile.mkdtemp(prefix="claude-picker-capture.", dir="/tmp")
    project = os.path.realpath(os.path.join(root, "scratch-project"))
    os.makedirs(project)
    with open(os.path.join(project, "README.md"), "w") as f:
        f.write("scratch\n")
    home = status_rows.scratch_home(root, project, args.tui)
    server_script = os.path.join(root, "scratch-notes-mcp.py")
    with open(server_script, "w") as f:
        f.write(FAKE_MCP)
    # The two scratch MCP servers, for the project (user scope would need a config Claude migrates).
    state_path = os.path.join(home, ".claude.json")
    with open(state_path) as f:
        state = json.load(f)
    state["mcpServers"] = {
        "scratch-notes": {"type": "stdio", "command": sys.executable, "args": ["-I", server_script]},
        "scratch-broken": {"type": "stdio", "command": os.path.join(root, "no-such-server")},
    }
    with open(state_path, "w") as f:
        json.dump(state, f)
    # One allow rule, for /permissions' rule list and its "Delete allowed tool?" yes/no dialog.
    settings_path = os.path.join(home, ".claude", "settings.json")
    with open(settings_path) as f:
        settings = json.load(f)
    settings["permissions"]["allow"] = ["Bash(ls:*)"]
    with open(settings_path, "w") as f:
        json.dump(settings, f)
    env = {"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8",
           "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "VibeSwitcher", "SHELL": "/bin/zsh",
           "TMPDIR": os.path.join(root, "tmp") + "/", "USER": os.environ.get("USER", "scratch"),
           "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "ANTHROPIC_API_KEY": status_rows.API_KEY,
           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
           "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"}
    os.makedirs(env["TMPDIR"])

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(project)
        os.execve(args.claude, [args.claude], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))
    os.kill(pid, signal.SIGWINCH)

    out = bytearray()
    marks = {}

    def pump(seconds, until=None):
        start, deadline, seen = len(out), time.time() + seconds, None
        while time.time() < deadline and (seen is None or time.time() - seen < 1.5):
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    return False
                out.extend(chunk)
            if until is not None and seen is None and until in out[start:]:
                seen = time.time()
        return until is None or seen is not None

    def type_(text):
        for ch in text:
            os.write(fd, ch.encode())
            time.sleep(0.03)

    ok = pump(30, until=b"manual mode on")
    if b"Make auto mode your default" in out:
        os.write(fd, b"\x1b[B")
        pump(1)
        os.write(fd, b"\r")
        ok = pump(10, until=b"manual mode") and ok
    pump(3)                                            # the MCP servers connect
    marks["idle"] = len(out)
    for number, step in enumerate(args.steps, 1):
        if step.startswith("/"):
            type_(step)
            pump(0.8)
            os.write(fd, b"\r")
            pump(3)
        elif step.startswith("type:"):
            type_(step[5:])
            pump(1.5)
        else:
            os.write(fd, KEYS[step])
            pump(1.5)
        marks[f"{number:02d}-{step}"] = len(out)
    for _ in range(2):
        os.write(fd, b"\x03")
        pump(1.5)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)
    with open(args.out, "wb") as f:
        f.write(out)
    with open(os.path.splitext(args.out)[0] + ".marks.json", "w") as f:
        json.dump(dict(marks, cols=args.cols, rows=args.rows, tui=args.tui, steps=args.steps), f, indent=1)
    print(f"{len(out)} bytes, marks {marks}, {'ok' if ok else 'INCOMPLETE'}")


if __name__ == "__main__":
    main()
