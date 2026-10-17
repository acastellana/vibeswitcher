import json, os, subprocess, time, tempfile
HOOK = "/Applications/VibeSwitcher.app/Contents/MacOS/vibeswitcher-hook"
fake = tempfile.mkdtemp(prefix="vshook-"); env = dict(os.environ, HOME=fake, CFFIXED_USER_HOME=fake)
base = {"session_id": "s", "cwd": "/tmp/demo", "transcript_path": fake + "/t.jsonl"}
def run(d):
    t = time.perf_counter(); subprocess.run([HOOK, "claude"], input=json.dumps(d).encode(), env=env, capture_output=True); return (time.perf_counter()-t)*1000
for size in [10_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000]:
    a = run({**base, "hook_event_name": "UserPromptSubmit", "prompt": "word " * (size // 5)})
    b = run({**base, "hook_event_name": "UserPromptSubmit", "prompt": "x" * size})
    c = run({**base, "hook_event_name": "Stop", "last_assistant_message": "word " * (size // 5)})
    d = run({**base, "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "cat"}, "tool_response": {"stdout": "word " * (size // 5)}})
    e = run({**base, "hook_event_name": "PreToolUse", "tool_name": "Write", "tool_input": {"file_path": "/tmp/x", "content": "word " * (size // 5)}})
    print(f"{size:>9} B  prompt(words)={a:8.1f}  prompt(xxxx)={b:8.1f}  stop.last_msg={c:8.1f}  post.tool_response={d:8.1f}  pre.Write.content={e:8.1f} ms")
