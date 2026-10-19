#!/usr/bin/env python3
"""Summarizes run_shape.py runs: what the window showed from the prompt on, whether the model got the hook's text
(and replied ACK), how it reached the model, and how the transcript recorded it.

Usage: summarize.py RUNS_DIR [SHAPE...]
"""
import glob
import json
import os
import sys

runs = sys.argv[1]
shapes = sys.argv[2:] or sorted(os.listdir(runs))


def texts(content):
    if isinstance(content, str):
        return [content]
    return [b.get("text", "") for b in content or [] if b.get("type") == "text"]


for shape in shapes:
    out = f"{runs}/{shape}"
    marker = f"VSTEST-{shape}"
    print(f"## {shape}\n")
    screen = open(f"{out}/screen.txt").read().splitlines() if os.path.exists(f"{out}/screen.txt") else []
    start = next((i for i, l in enumerate(screen) if l.startswith("❯ hello")), 0)
    end = next((i for i, l in enumerate(screen) if l.startswith("────")), len(screen))
    print("window:")
    for line in screen[start:end]:
        if line.strip():
            print("    " + line)
    requests = [json.loads(l) for l in open(f"{out}/requests.jsonl")] if os.path.exists(f"{out}/requests.jsonl") else []
    reached = []
    for index, body in enumerate(requests):
        for message in body.get("messages", []):
            for text in texts(message.get("content")):
                if marker in text:
                    reached.append((index, message.get("role"), text.replace("\n", "\\n")[:220]))
    print(f"requests: {len(requests)}; the text reached the model in:")
    for index, role, text in reached[:4]:
        print(f"    request {index} ({role}): {text[:160]}")
    acted = any(marker in l and "ACK" in l for l in screen)
    print(f"model replied ACK: {acted}")
    print("transcript records holding it:")
    for path in glob.glob(f"{out}/home/.claude/projects/*/*.jsonl"):
        for line in open(path):
            if marker not in line:
                continue
            record = json.loads(line)
            kind = record.get("type")
            detail = record.get("attachment", {}).get("type") if kind == "attachment" else record.get("subtype") or ""
            meta = " isMeta" if record.get("isMeta") else ""
            if kind not in ("assistant", "api-request-blob"):
                print(f"    {kind} {detail}{meta}".rstrip())
    print()
