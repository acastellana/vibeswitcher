#!/usr/bin/env python3 -I
"""Records Claude Code's status rows byte for byte from a SCRATCH session: a scratch HOME (made here, removed after),
a scratch project folder, and a fake Messages API on 127.0.0.1, so no real account, session or credential is touched.

    python3 -I Tests/Tools/capture-claude-status-rows.py COLS ROWS OUT.raw [--claude PATH] [--tui fullscreen|default]

The session runs on a PTY of COLS x ROWS with the environment the session host gives a window session (TERM,
COLORTERM, TERM_PROGRAM=VibeSwitcher). It waits for the idle screen (status line under the box), sends a prompt the
fake API answers slowly (the spinner row), then with a Bash tool call (the permission prompt), and quits. OUT.raw gets
everything the program printed; OUT.marks.json the byte offsets of `idle`, `spinner` and `permission`.
CAPTURE_LOG=FILE: a line per request the fake API answered. Then terminal-app-reference.py reads Terminal.app's
screen for the same bytes.
"""
import argparse
import contextlib
import fcntl
import http.server
import json
import os
import pty
import select
import shutil
import signal
import struct
import tempfile
import termios
import threading
import time

API_KEY = "sk-ant-api03-scratch-capture-not-a-real-key-0000000000AA"
# Two lines like claude-hud's (the user's status line): colors, block bars, no-break spaces, an emoji with VS16.
STATUS_LINE = r"""#!/bin/sh
cat >/dev/null
printf '\033[0m\033[36m[Opus 5.5]\033[0m\302\240\033[32m\342\226\210\342\226\210\033[2m\342\226\221\342\226\221\342\226\221\342\226\221\342\226\221\342\226\221\342\226\221\342\226\221\033[0m\302\240\033[32m23%%\033[0m | \033[33mscratch-project\033[0m git:(\033[35mmain*\033[0m) | 2 CLAUDE.md | 5 MCPs | \342\217\261\357\270\217 12m\n'
printf '\033[2m\342\227\220 Bash: ls -la\033[0m | \033[32m\342\234\223\033[0m Read \303\2273 | \033[32m\342\234\223\033[0m Edit \303\2272 | \342\226\270 Explore: find the resize path (14s)\n'
"""


class FakeAPI(http.server.BaseHTTPRequestHandler):
    """Answers /v1/messages: the first prompt after 6 s (the spinner meanwhile) with a Bash call, a tool result with
    a short text; anything else (titles, quota checks) at once."""

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_json({"data": [], "has_more": False})

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        model = request.get("model", "claude-opus-5-5")
        answered = "tool_result" in json.dumps(request.get("messages"))
        if os.environ.get("CAPTURE_LOG"):
            with open(os.environ["CAPTURE_LOG"], "a") as f:
                f.write(json.dumps({"path": self.path, "stream": request.get("stream"),
                                    "tools": len(request.get("tools") or []), "answered": answered}) + "\n")
        # The main loop's request (it carries the tools) on the prompt; a side request (the title) at once.
        if request.get("tools") and "make notes.txt" in json.dumps(request.get("messages")) and not answered:
            time.sleep(6)
            blocks = [{"type": "text", "text": "I will make the file."},
                      {"type": "tool_use", "id": "toolu_scratch01", "name": "Bash",
                       "input": {"command": "touch notes.txt", "description": "Create notes.txt"}}]
        else:
            blocks = [{"type": "text", "text": "Done." if answered else "ok"}]
        message = {"id": "msg_scratch", "type": "message", "role": "assistant", "model": model, "content": blocks,
                   "stop_reason": "tool_use" if blocks[-1]["type"] == "tool_use" else "end_turn",
                   "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 5}}
        if not request.get("stream"):
            return self.send_json(message)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def event(kind, data):
            # Claude may drop a request it no longer needs (an aborted title): nothing to answer then.
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(f"event: {kind}\ndata: {json.dumps(dict(data, type=kind))}\n\n".encode())
                self.wfile.flush()

        event("message_start", {"message": dict(message, content=[], stop_reason=None)})
        for index, block in enumerate(blocks):
            if block["type"] == "text":
                event("content_block_start", {"index": index, "content_block": {"type": "text", "text": ""}})
                event("content_block_delta", {"index": index, "delta": {"type": "text_delta", "text": block["text"]}})
            else:
                event("content_block_start", {"index": index, "content_block": dict(block, input={})})
                event("content_block_delta", {"index": index, "delta": {"type": "input_json_delta",
                                                                         "partial_json": json.dumps(block["input"])}})
            event("content_block_stop", {"index": index})
        event("message_delta", {"delta": {"stop_reason": message["stop_reason"], "stop_sequence": None},
                                "usage": {"output_tokens": 5}})
        event("message_stop", {})


def scratch_home(root, project, tui):
    home = os.path.join(root, "home")
    os.makedirs(os.path.join(home, ".claude"), mode=0o700)
    status = os.path.join(home, ".claude", "statusline.sh")
    with open(status, "w") as f:
        f.write(STATUS_LINE)
    os.chmod(status, 0o700)
    # Ask before running anything (the permission prompt), not auto mode.
    settings = {"statusLine": {"type": "command", "command": status}, "theme": "dark",
                "permissions": {"defaultMode": "default"}}
    if tui == "fullscreen":
        settings["tui"] = "fullscreen"
    with open(os.path.join(home, ".claude", "settings.json"), "w") as f:
        json.dump(settings, f)
    state = {"hasCompletedOnboarding": True, "theme": "dark", "numStartups": 5,
             "customApiKeyResponses": {"approved": [API_KEY[-20:]], "rejected": []},
             "projects": {project: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                                    "allowedTools": []}}}
    with open(os.path.join(home, ".claude.json"), "w") as f:
        json.dump(state, f)
    return home


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cols", type=int)
    parser.add_argument("rows", type=int)
    parser.add_argument("out")
    parser.add_argument("--claude", default=shutil.which("claude") or "claude")
    parser.add_argument("--tui", default="fullscreen", choices=["fullscreen", "default"])
    args = parser.parse_args()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeAPI)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # Short: the folder's path is on the screen.
    root = tempfile.mkdtemp(prefix="claude-status-capture.", dir="/tmp")
    project = os.path.realpath(os.path.join(root, "scratch-project"))
    os.makedirs(project)
    with open(os.path.join(project, "README.md"), "w") as f:
        f.write("scratch\n")
    home = scratch_home(root, project, args.tui)
    # Nothing of this process's environment: no Claude session variables, no keys.
    env = {"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8",
           "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "VibeSwitcher", "SHELL": "/bin/zsh",
           "TMPDIR": os.path.join(root, "tmp") + "/", "USER": os.environ.get("USER", "scratch"),
           "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}", "ANTHROPIC_API_KEY": API_KEY,
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
        """Reads output for `seconds`, or until `until` is in what came after the call started and 1.5 s more went by
        (so the frame is whole; Claude keeps blinking a dot, so output never goes quiet). False: `until` never came."""
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

    ok = pump(30, until=b"12m")                       # the status line drawn under the box
    if b"Make auto mode your default" in out:         # a first run's question: keep manual mode (asks before Bash)
        os.write(fd, b"\x1b[B")
        pump(1)
        os.write(fd, b"\r")
        ok = pump(10, until=b"manual mode")
    marks["idle"] = len(out)
    type_("please make notes.txt")
    pump(1)
    os.write(fd, b"\r")
    pump(3.5)                                         # the spinner, the answer still 2.5 s away
    marks["spinner"] = len(out)
    ok = pump(30, until=b"Do you want") and ok        # the permission prompt
    marks["permission"] = len(out)
    os.write(fd, b"\x1b")                             # no
    pump(3)
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
        json.dump(dict(marks, cols=args.cols, rows=args.rows, tui=args.tui), f, indent=1)
    print(f"{len(out)} bytes, marks {marks}, {'ok' if ok else 'INCOMPLETE'}")


if __name__ == "__main__":
    main()
