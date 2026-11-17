#!/usr/bin/env python3
"""Count how often this project's workers rediscover the same pitfall or fact.

Read-only. It reads the Claude Code session files (~/.claude/projects/<folder>/*.jsonl)
of this repository's worktrees only (.vibeswitcher/worktrees/*), keeps the worker
sessions (first prompt "Start on your task") that started in the last --days days,
and prints counts only: no transcript text, no paths outside the repository.

    python3 -I scripts/worker-rediscovery.py            # last 7 days, table + totals
    python3 -I scripts/worker-rediscovery.py --days 14 --json

How time is measured (all from the transcripts' own timestamps):
- Worker time: per session, the sum of the gaps between consecutive events, each gap
  capped at IDLE_CAP_S, so a worker waiting on the lead or the user doesn't count.
- A hit: the first event of a category in a task, plus every later burst of it (events of
  that category more than BURST_S apart start a new burst; one task counts once per
  category in "tasks", every burst counts in "hits").
- Minutes lost per hit: from the burst's first event to the first event after the burst's
  last event that isn't of the same category (the recovery), each gap capped at
  IDLE_CAP_S. For a merge conflict: from the conflicted `git merge` to the next
  successful `git commit` (the conflict's resolution).
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time

IDLE_CAP_S = 600        # a gap longer than this is waiting, not work
BURST_S = 300           # events of one category closer than this are one hit
MAX_RECOVERY_S = 1800   # a recovery longer than this is capped (the worker moved on)


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def repo_root():
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.dirname(common)


def project_folders(root):
    # Claude Code names a project folder after its cwd with "/" and "." replaced by "-".
    prefix = re.sub(r"[/.]", "-", os.path.join(root, ".vibeswitcher", "worktrees")) + "-"
    base = os.path.expanduser("~/.claude/projects")
    return [d for d in glob.glob(os.path.join(base, "*")) if os.path.basename(d).startswith(prefix)], prefix


def load(path):
    """One session's events: tool calls with their results, and message timestamps."""
    first, events, uses = None, [], {}
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            t = o.get("timestamp")
            msg = o.get("message") or {}
            content = msg.get("content")
            if first is None and o.get("type") == "user" and isinstance(content, str):
                first = content
            if not t:
                continue
            if not isinstance(content, list):
                events.append({"t": ts(t), "kind": "msg"})
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    e = {"t": ts(t), "kind": "use", "tool": b.get("name", ""),
                         "cmd": str(inp.get("command", "")), "file": str(inp.get("file_path", "")),
                         "pattern": str(inp.get("pattern", "")), "err": False, "res": ""}
                    uses[b.get("id")] = e
                    events.append(e)
                elif b.get("type") == "tool_result":
                    e = uses.get(b.get("tool_use_id"))
                    r = b.get("content")
                    if isinstance(r, list):
                        r = " ".join(x.get("text", "") for x in r if isinstance(x, dict))
                    if e is not None:
                        e["err"] = bool(b.get("is_error"))
                        e["res"] = str(r)[:4000]
                else:
                    events.append({"t": ts(t), "kind": "msg"})
    events.sort(key=lambda e: e["t"])
    return first, events


def is_search(e, rx):
    """A grep for rx that isn't part of a test run's log filtering."""
    return (e["tool"] == "Bash" and not re.search(r"scripts/test\.sh|vs-heavy|test-under-load", e["cmd"])
            and re.search(r"(grep|rg)\b[^|;]*(" + rx + ")", e["cmd"]))


SESSION = {"saw_lead_red": False}  # set per session before matching


def lead_red(e):
    """PrivateNamesLint failing on the lead's record on main: the failure names docs/lead/, or names no
    file (output cut short) in a session that saw it name docs/lead/."""
    if not lint_failed(e, "PrivateNamesLint"):
        return False
    named = re.findall(r"\"([\w./-]+\.\w+):\d+", e["res"])
    return "docs/lead/" in e["res"] or (not named and SESSION["saw_lead_red"])


def lint_failed(e, suite):
    return e["tool"] == "Bash" and re.search(suite + r"\w*\.swift:\d+:\d+: Expectation failed|Suite " + suite + r"\w* failed", e["res"])


def is_git_combined(cmd):
    c = cmd.strip()
    return bool(re.search(r"(^|[;&|(]\s*)git\s", c)) and bool(re.search(r"[|;>]|&&|\$\(|^\w+=", c))


# Each category: key, own-words label, matcher(event) -> bool, bucket, and how to tell
# whether AGENTS.md or the worker brief (Sources/VibeCore/LeadWorkflow.swift) says it today:
# a regex over those texts.  Buckets: a = a tip from an earlier or concurrent worker would
# have prevented it; b = a line in AGENTS.md or the brief (or a fix to the tool) would
# prevent it better; c = two concurrent tasks changed the same file.
CATEGORIES = [
    ("git-combined", "a git command with a pipe, redirect, `;` or `&&` around it is refused",
     lambda e: e["tool"] == "Bash" and e["err"] and "Permission to use Bash" in e["res"] and is_git_combined(e["cmd"]),
     "b", r"type each of these commands exactly as written, on its own"),
    ("restore-blocked", "putting a file back with git checkout/restore after a revert check is blocked by the safety hook",
     lambda e: e["tool"] == "Bash" and e["err"] and "BLOCKED by dcg" in e["res"] and re.search(r"git (checkout|restore)", e["res"]),
     "b", r"git checkout --|git restore"),
    ("lead-scratch-denied", "the merge log path the lead sends is in a folder workers can't read",
     lambda e: e["err"] and ".vibeswitcher/lead" in (e["file"] + e["cmd"]) and "denied" in e["res"],
     "b", r"merge-test\.log.*(can't|cannot) read|copy of the merge log"),
    ("sleep-blocked", "a foreground sleep to wait for a background job is refused",
     lambda e: e["tool"] == "Bash" and e["err"] and "Blocked: sleep" in e["res"],
     "b", r"Foreground `sleep` is blocked|never on a fixed sleep"),
    ("report-load", "report refused: changed tests not yet run under load",
     lambda e: e["tool"].endswith("__report") and e["err"] and "adds or changes tests" in e["res"],
     "b", r"run every test your branch adds or changes under load"),
    ("report-evidence", "report refused: evidence missing an acceptance check",
     lambda e: e["tool"].endswith("__report") and e["err"] and "evidence has no entry" in e["res"],
     "b", r"one entry per acceptance check"),
    ("lead-code-dir", "looking for the Lead*.swift sources under the app target (they live in VibeCore)",
     lambda e: e["tool"] == "Bash" and re.search(r"Sources/VibeSwitcher/Lead\w*\.swift", e["cmd"]) and "No such file" in e["res"],
     "b", r"Sources/VibeCore/Lead"),
    ("lead-fixture", "where the lead test fixture is and what it offers (LeadTeamFixture)",
     lambda e: is_search(e, r"LeadTeamFixture"),
     "b", r"LeadTeamFixture"),
    ("wait-helper", "which helper a test waits with (until / eventually / hangGuard)",
     lambda e: is_search(e, r"func until|func eventually|hangGuard"),
     "b", r"func until|eventually\(|hangGuard"),
    ("scratch-home", "which helper gives a test its scratch home (Scratch)",
     lambda e: is_search(e, r"(struct|class) Scratch"),
     "b", r"struct Scratch|Scratch\("),
    ("sandbox-sheets", "where the sandbox's sheet list lives",
     lambda e: is_search(e, r"[Ss]heet") and "Sandbox" in e["cmd"],
     "b", r"sheet list in `Sources/VibeSwitcher/Sandbox\.swift`|Sources/VibeSwitcher/Sandbox\.swift"),
    ("lint-red-on-main", "a lint is red on main itself (another project's name in the lead's record), not on the branch",
     lead_red,
     "a", r"(?!)", "until"),
    ("lint-private-names", "PrivateNamesLint rejects a name or email the branch added",
     lambda e: lint_failed(e, "PrivateNamesLint") and not lead_red(e),
     "b", r"PrivateNamesLint|other projects'? names|project-b", "until"),
    ("lint-private-write", "PrivateWriteLint: a new raw file write needs VibePaths.writePrivate or an allow-list entry",
     lambda e: lint_failed(e, "PrivateWriteLint"),
     "b", r"PrivateWriteLint|writePrivate", "until"),
    ("lint-temp-folder", "TemporaryFolderLint: a test or script used the system temporary folder instead of a Scratch",
     lambda e: lint_failed(e, "TemporaryFolderLint"),
     "b", r"TemporaryFolderLint|scratchRoot", "until"),
]
MERGE_KEY = "merge-conflict"
MERGE_LABEL = "bringing the branch up to date with main hits a conflict"


def until_green(events, i, match):
    """(seconds, next index): from a failed lint run to the next run of the lints that doesn't fail
    the same way, or the next report or ask_lead call, whichever comes first."""
    k = i + 1
    while k < len(events):
        e = events[k]
        if e["kind"] == "use" and (
                (e["tool"] == "Bash" and "Lint" in e["cmd"] and e["res"] and not match(e))
                or e["tool"].endswith(("__report", "__ask_lead"))):
            break
        k += 1
    end = min(k, len(events) - 1)
    secs = sum(min(b["t"] - a["t"], IDLE_CAP_S) for a, b in zip(events[i:end], events[i + 1:end + 1]))
    return min(secs, MAX_RECOVERY_S), k


def recovery(events, i, match):
    """(seconds, next index): from events[i] through its burst to the first tool call after it
    that isn't of the same category, each gap capped at IDLE_CAP_S."""
    last, k = events[i]["t"], i + 1
    while k < len(events):
        e = events[k]
        if e["kind"] == "use":
            if match(e) and e["t"] - last <= BURST_S:
                last = e["t"]
            elif not match(e) and e["t"] > last:
                break
            elif match(e):
                break  # a new burst starts here
        k += 1
    end = min(k, len(events) - 1)
    lead_in = min(events[i]["t"] - events[i - 1]["t"], IDLE_CAP_S) if i else 0  # writing the call that hit
    secs = lead_in + sum(min(b["t"] - a["t"], IDLE_CAP_S) for a, b in zip(events[i:end], events[i + 1:end + 1]))
    return min(secs, MAX_RECOVERY_S), k


def merge_hits(events):
    out = []
    for i, e in enumerate(events):
        if e["kind"] == "use" and e["tool"] == "Bash" and re.match(r"\s*git merge\b", e["cmd"]) and "CONFLICT" in e["res"]:
            files = sorted(set(re.findall(r"Merge conflict in (\S+)", e["res"])))
            end = None
            for f in events[i + 1:]:
                if f["kind"] == "use" and f["tool"] == "Bash" and re.match(r"\s*git (commit|merge --continue)", f["cmd"]) and not f["err"]:
                    end = f["t"]
                    break
            if end is None:
                continue
            seg = [x for x in events if e["t"] <= x["t"] <= end]
            secs = sum(min(b["t"] - a["t"], IDLE_CAP_S) for a, b in zip(seg, seg[1:]))
            out.append((e["t"], min(secs, MAX_RECOVERY_S * 2), files))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = repo_root()
    folders, prefix = project_folders(root)
    since = time.time() - args.days * 86400
    docs = ""
    for rel in ("AGENTS.md", "Sources/VibeCore/LeadWorkflow.swift"):
        try:
            with open(rel) as fh:  # this checkout's copy: what workers are told today
                docs += fh.read()
        except OSError:
            pass

    # This checkout's own session reads the others' output, so it is left out.
    own = os.path.realpath(os.path.join(os.path.expanduser("~/.claude/projects"), re.sub(r"[/.]", "-", os.getcwd())))
    roles = collections.Counter()
    sessions = []
    for d in folders:
        for f in glob.glob(os.path.join(d, "*.jsonl")):
            if os.path.getmtime(f) < since:
                continue
            first, events = load(f)
            if not events or events[0]["t"] < since:
                continue
            role = "worker" if (first or "").startswith("Start on your task") else (
                "verifier" if (first or "").startswith("Verify the task") else "other")
            roles[role] += 1
            if role == "worker" and os.path.realpath(d) != own:
                task = os.path.basename(d)[len(prefix):]
                sessions.append((task, events))

    total_s = 0.0
    tasks = set()
    hits = collections.defaultdict(list)  # category -> [(start time, task, seconds lost)]
    conflict_files = collections.defaultdict(set)
    for task, events in sessions:
        tasks.add(task)
        SESSION["saw_lead_red"] = any(e["kind"] == "use" and lint_failed(e, "PrivateNamesLint") and "docs/lead/" in e["res"]
                                      for e in events)
        total_s += sum(min(b["t"] - a["t"], IDLE_CAP_S) for a, b in zip(events, events[1:]))
        for key, _label, match, _bucket, _doc, *how in CATEGORIES:
            i = 0
            while i < len(events):
                e = events[i]
                if e["kind"] == "use" and match(e):
                    secs, nxt = (until_green if how else recovery)(events, i, match)
                    hits[key].append((e["t"], task, secs))
                    i = max(nxt, i + 1)
                else:
                    i += 1
        for t0, secs, files in merge_hits(events):
            hits[MERGE_KEY].append((t0, task, secs))
            for f in files:
                conflict_files[f].add(task)

    rows = []
    buckets = collections.Counter()
    for key, label, _m, bucket, doc, *_how in CATEGORIES + [(MERGE_KEY, MERGE_LABEL, None, "c", r"(?!)")]:
        hs = sorted(hits[key])
        if not hs:
            continue
        # A repeat is a hit in any task but the first one to hit it: that first hit is the
        # discovery a tip would have come from.
        first_task = hs[0][1]
        repeat_s = sum(s for _t, task, s in hs if task != first_task)
        secs = sorted(s for *_x, s in hs)
        n = len(secs)
        rows.append({
            "key": key, "label": label, "bucket": bucket, "tasks": len({t for _x, t, _s in hs}), "hits": n,
            "median_min": round(secs[n // 2] / 60, 1), "mean_min": round(sum(secs) / n / 60, 1),
            "total_min": round(sum(secs) / 60, 1), "repeat_min": round(repeat_s / 60, 1),
            "said": bool(re.search(doc, docs)),
        })
        buckets[bucket] += repeat_s
    rows.sort(key=lambda r: -r["tasks"])
    conflict_files = {f: len(t) for f, t in conflict_files.items() if len(t) > 1}

    out = {"days": args.days, "sessions": dict(roles), "worker_sessions": len(sessions), "tasks": len(tasks),
           "worker_min": round(total_s / 60), "rows": rows,
           "buckets_min": {k: round(v / 60, 1) for k, v in buckets.items()},
           "buckets_pct": {k: round(100 * v / total_s, 2) for k, v in buckets.items()} if total_s else {},
           "conflict_files_hit_by_2plus_tasks": dict(sorted(conflict_files.items(), key=lambda x: -x[1]))}
    if args.json:
        json.dump(out, sys.stdout, indent=1)
        print()
        return
    print(f"sessions in the window: {dict(roles)}; worker sessions read: {len(sessions)} ({len(tasks)} tasks); "
          f"worker time: {out['worker_min']} min")
    print("| category | bucket | tasks | hits | median min/hit | mean min/hit | total min | repeat min | said today |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for r in rows:
        print(f"| {r['label']} | {r['bucket']} | {r['tasks']} | {r['hits']} | {r['median_min']} | {r['mean_min']} | "
              f"{r['total_min']} | {r['repeat_min']} | {'yes' if r['said'] else 'no'} |")
    print("repeat minutes by bucket:", out["buckets_min"], "share of worker time (%):", out["buckets_pct"])
    print("files that conflicted in 2+ tasks:", out["conflict_files_hit_by_2plus_tasks"])


if __name__ == "__main__":
    main()
