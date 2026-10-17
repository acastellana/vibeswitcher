import json, os, subprocess, sys, time, statistics, tempfile, pathlib
HOOK = "/Applications/VibeSwitcher.app/Contents/MacOS/vibeswitcher-hook"
fake = tempfile.mkdtemp(prefix="vshook-")
env = dict(os.environ, HOME=fake, CFFIXED_USER_HOME=fake)
base = {"session_id": "00000000-1111-2222-3333-444444444444",
        "transcript_path": fake + "/.claude/projects/-tmp-demo/00000000-1111-2222-3333-444444444444.jsonl",
        "cwd": "/tmp/demo", "permission_mode": "default"}
events = [
  {"hook_event_name": "SessionStart", "source": "startup"},
  {"hook_event_name": "UserPromptSubmit", "prompt": "Refactor the parser so it handles nested lists, then run the tests " * 3},
  {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "swift test --filter ParserTests", "description": "Run parser tests"}},
  {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "swift test"}, "tool_response": {"stdout": "x" * 4000, "stderr": "", "interrupted": False}},
  {"hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": {"file_path": "/tmp/demo/Sources/Parser.swift", "old_string": "a" * 300, "new_string": "b" * 300}},
  {"hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "rm -rf build"}},
  {"hook_event_name": "Notification", "message": "Claude is waiting for your input", "notification_type": "idle_prompt"},
  {"hook_event_name": "Stop", "stop_hook_active": False, "last_assistant_message": "Done. All 42 tests pass." * 10},
]
def run(data: bytes, args=("claude",)):
    t = time.perf_counter()
    p = subprocess.run([HOOK, *args], input=data, env=env, capture_output=True)
    return (time.perf_counter() - t) * 1000, p.returncode, p.stdout, p.stderr
# safety check: one run must land in the fake home
_, rc, _, _ = run(json.dumps({**base, **events[0]}).encode())
states = list(pathlib.Path(fake, ".vibeswitcher/state").glob("*.json"))
if not states:
    sys.exit("hook did not write into fake home; aborting")
print("fake home:", fake, "state files:", [s.name for s in states])
N = int(sys.argv[1]) if len(sys.argv) > 1 else 400
res = {}
allt = []
for i in range(N):
    ev = events[i % len(events)]
    ms, rc, out, err = run(json.dumps({**base, **ev}).encode())
    res.setdefault(ev["hook_event_name"], []).append(ms); allt.append(ms)
    assert rc == 0, (ev, rc, err)
def pct(xs, q):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]
print(f"ALL n={len(allt)} p50={pct(allt,.5):.1f} p95={pct(allt,.95):.1f} p99={pct(allt,.99):.1f} max={max(allt):.1f} mean={statistics.mean(allt):.1f} ms")
for k, v in res.items():
    print(f"  {k:18s} n={len(v):3d} p50={pct(v,.5):.1f} p95={pct(v,.95):.1f} max={max(v):.1f}")
# baseline: /usr/bin/true spawn cost
bt = []
for _ in range(100):
    t = time.perf_counter(); subprocess.run(["/usr/bin/true"]); bt.append((time.perf_counter() - t) * 1000)
print(f"baseline /usr/bin/true n=100 p50={pct(bt,.5):.1f} p95={pct(bt,.95):.1f} ms")
# malformed / edge inputs
cases = {
  "empty stdin": b"",
  "whitespace": b"   \n",
  "truncated json": b'{"hook_event_name": "Stop", "session_id": "ab',
  "json array": b"[1,2,3]",
  "json string": b'"hello"',
  "no hook_event_name": json.dumps(base).encode(),
  "unknown event": json.dumps({**base, "hook_event_name": "Bogus"}).encode(),
  "wrong types": json.dumps({**base, "hook_event_name": "PreToolUse", "tool_name": 5, "tool_input": "x", "cwd": 7}).encode(),
  "binary garbage": os.urandom(2048),
  "huge prompt 5MB": json.dumps({**base, "hook_event_name": "UserPromptSubmit", "prompt": "p" * 5_000_000}).encode(),
  "deep nesting": (b'{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":' + b'[' * 100000 + b']' * 100000 + b'}'),
  "transcript_path 5KB": json.dumps({**base, "hook_event_name": "Stop", "transcript_path": "/" + "a" * 5000}).encode(),
  "no agent arg": json.dumps({**base, **events[1]}).encode(),
  "codex arg": json.dumps({**base, **events[1]}).encode(),
}
for name, data in cases.items():
    args = () if name == "no agent arg" else (("codex",) if name == "codex arg" else ("claude",))
    ms, rc, out, err = run(data, args)
    st = sorted(pathlib.Path(fake, ".vibeswitcher/state").glob("*.json"))
    size = st[0].stat().st_size if st else 0
    print(f"  edge {name:22s} rc={rc} {ms:7.1f} ms stdout={len(out)}B stderr={err[:80]!r} state_size={size}")
print("final state files:", [(s.name, s.stat().st_size) for s in pathlib.Path(fake, ".vibeswitcher/state").iterdir()])
