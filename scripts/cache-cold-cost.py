#!/usr/bin/env python3
"""What cold prompt caches cost this project's lead, workers and verifiers.

Read-only, numbers and names only. It reads the Claude Code session files of this
repository (its root's folder and its worktrees', under ~/.claude/projects) that were
written in the last --days days, keeps the sessions VibeSwitcher started (named
lead-…, worker-…, verify-… or finder<N>-…), and prints tables: no transcript text is
read into a variable, kept or printed.

    python3 -I scripts/cache-cold-cost.py              # last 7 days, markdown tables
    python3 -I scripts/cache-cold-cost.py --days 14 --json
    python3 -I scripts/cache-cold-cost.py --until "2026-11-18 12:00" --events   # a fixed window, each re-send listed

What it takes from a transcript line, and nothing else:
- its `type`, `timestamp`, and for a session's name `customTitle` / `agentName`;
- an API response's `message.id`, `message.model`, `message.usage` (input_tokens,
  output_tokens, cache_read_input_tokens, cache_creation_input_tokens, the
  cache_creation.ephemeral_1h / ephemeral_5m buckets, speed, and the advisor's
  `iterations` of the same shape), and `requestRef` (which request it answers);
- a request's `id` and `timestamp` (`api-request` lines: when it was sent);
- which kind of sender started a turn (`turnOrigin`: human, task_notification, peer,
  scheduled), an error's kind (`error`: rate_limit…), and a compaction's `trigger`,
  `preTokens` and `postTokens`.

Causes come from outside the transcripts: the Mac's sleeps from `pmset -g log`; the
board (.vibeswitcher/board.json and board-archive.jsonl): each task's start, done
report, merge and end times and each question's asked and answered times, by slug.

Definitions:
- A session's cache line: one transcript's responses in order (a subagent's transcript is
  its own; so is a session's advisor). Each API response counts once, by message id.
- The TTL in force at a request: the bucket the line last wrote to before it (1 h when
  ephemeral_1h tokens were written, 5 min when ephemeral_5m).
- The gap: from the previous request's send time to this one's.
- What woke a lead: the board's event (a done report, a merge, an answer) or the end of a
  worker's or verifier's turn (its last request before a silence) in the 90 s before the
  wake; with none, the wake was typed in (the user, or a notice of the app's own).
- A cold re-send: a response after a gap longer than the TTL in force. Its cache-write
  tokens are "written cold"; the part of them that had been in the cache before (the
  previous prompt less what this one still read from the cache) is "re-sent".
- Prices: parsed from Sources/VibeCore/LeadReceipt.swift (`LeadPrices.table`), the ones
  the Receipts line uses; a model with no price there is listed, never guessed, unless
  --price-as says which priced model to take its rates from.
"""
import argparse
import bisect
import collections
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time

PING_EVERY_S = 55 * 60      # a keep-warm request this often holds a 1 h cache
ROTATE_IDLE_S = 50 * 60     # the idle at which a large lead would hand over, its cache still warm
FRESH_LEAD = 80_000         # a fresh lead's context once it has read its handover (its first prompt is ~58k)
REPLACED_S = 600            # a worker started this soon after its task's audit ended replaces a released one
EVENT_WINDOW_S = 90         # a team event this long before a lead's wake is what woke it (VibeSwitcher wakes it within 8 s)
TURN_END_S = 60             # a session's request followed by this long a silence ended its turn
MIN_CONTEXT = 20_000        # a miss on a smaller prompt than this isn't worth naming


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def repo_root():
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.dirname(common)


def claude_name(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


# ---------------------------------------------------------------- prices

def prices(root_here):
    """LeadPrices.table and its date, from this checkout's source."""
    path = os.path.join(root_here, "Sources", "VibeCore", "LeadReceipt.swift")
    with open(path) as fh:
        text = fh.read()
    table = {}
    block = text[text.index("public static let table"):]
    block = block[:block.index("]\n")]
    for m in re.finditer(r'"([\w.\-]+)": Price\(([^)]*)\)', block):
        args = dict((k.strip(), float(v.replace("_", ""))) for k, v in (a.split(":") for a in m.group(2).split(",")))
        args.setdefault("cacheRead", args["input"] / 10)
        table[m.group(1)] = args
    as_of = re.search(r'public static let asOf = "([^"]+)"', text).group(1)
    return table, as_of


def price_of(model, table, price_as):
    """As LeadPrices.price: the id, also with a context suffix, a date or a platform prefix."""
    mid = model.lower().split("[")[0]
    if "anthropic." in mid:
        mid = mid.rsplit("anthropic.", 1)[1]
    mid = mid.split("@")[0]
    for candidate in (mid, re.sub(r"-\d{8}$", "", mid)):
        if candidate in table:
            return table[candidate]
        if candidate in price_as and price_as[candidate] in table:
            return table[price_as[candidate]]
    return None


def rates(r, price):
    """(input, output, read, 5-minute write, 1-hour write) dollars per token for one response, as LeadPrices.cost."""
    prompt = r["in"] + r["read"] + r["cw"]
    long = price.get("longOver") is not None and prompt > price["longOver"]
    inp = price.get("longInput", price["input"]) if long else price["input"]
    out = price.get("longOutput", price["output"]) if long else price["output"]
    read = inp / 10 if long else price["cacheRead"]
    k = (2 if r["fast"] else 1) / 1e6
    return inp * k, out * k, read * k, inp * 1.25 * k, inp * 2 * k


def cost(r, price):
    inp, out, read, w5, w1 = rates(r, price)
    return r["in"] * inp + r["out"] * out + r["read"] * read + (r["cw"] - r["cw1h"]) * w5 + r["cw1h"] * w1


# ---------------------------------------------------------------- transcripts

def usage_of(u, model, at, fast=None):
    creation = u.get("cache_creation") or {}
    cw = int(u.get("cache_creation_input_tokens") or 0)
    return {"t": at, "model": model, "in": int(u.get("input_tokens") or 0), "out": int(u.get("output_tokens") or 0),
            "read": int(u.get("cache_read_input_tokens") or 0), "cw": cw,
            "cw1h": min(cw, int(creation.get("ephemeral_1h_input_tokens") or 0)),
            "cw5m": min(cw, int(creation.get("ephemeral_5m_input_tokens") or 0)),
            "fast": (u.get("speed") if fast is None else fast) == "fast"}


def load(path, seen, since, until):
    """One transcript: its names, and its cache lines' responses in order. Only the keys the
    module's note lists are looked at; a line's other values are dropped with the line."""
    names, lines_, requests = set(), collections.defaultdict(list), {}
    errors, compactions, origin, last_any = [], [], {}, None
    with open(path, errors="replace") as fh:
        for raw in fh:
            if '"usage"' not in raw and '"timestamp"' not in raw and '"customTitle"' not in raw and '"agentName"' not in raw:
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            kind = o.get("type")
            for key in ("customTitle", "agentName"):
                if isinstance(o.get(key), str):
                    names.add(o[key])
            stamp = o.get("timestamp")
            if not isinstance(stamp, str):
                continue
            try:
                at = ts(stamp)
            except ValueError:
                continue
            agent = o.get("agentId") if o.get("isSidechain") else None
            line = agent or ""
            if kind == "api-request":
                if isinstance(o.get("id"), str):
                    requests[o["id"]] = at
            elif kind == "user":
                if isinstance(o.get("turnOrigin"), str):
                    origin[line] = o["turnOrigin"]   # a new turn, and who started it
            elif kind == "system" and o.get("subtype") == "compact_boundary":
                meta = o.get("compactMetadata") or {}
                compactions.append({"t": at, "trigger": str(meta.get("trigger"))[:20], "pre": int(meta.get("preTokens") or 0),
                                    "post": int(meta.get("postTokens") or 0), "idle": at - last_any if last_any else None})
            elif kind == "assistant":
                msg = o.get("message") if isinstance(o.get("message"), dict) else {}
                if isinstance(o.get("error"), str):
                    errors.append((at, o["error"]))
                u = msg.get("usage")
                if not isinstance(u, dict):
                    continue
                mid = msg.get("id") or o.get("requestId") or o.get("uuid")
                sent = requests.get(o.get("requestRef"), at)
                if not mid or mid in seen or at > until:
                    continue
                r = usage_of(u, str(msg.get("model") or "unknown"), sent)
                if r["in"] + r["out"] + r["read"] + r["cw"] <= 0:
                    continue
                seen.add(mid)
                last_any = at
                if at < since:
                    r["before"] = True      # sets the gap of the next one; not counted itself
                r["origin"] = origin.pop(line, None)   # None: no new turn since the last response
                lines_[line].append(r)
                for step in u.get("iterations") or []:
                    if isinstance(step, dict) and step.get("type") == "advisor_message":
                        a = usage_of(step, str(step.get("model") or "advisor"), sent, fast=u.get("speed"))
                        a["origin"] = None
                        if at < since:
                            a["before"] = True
                        lines_[line + "|advisor"].append(a)
    return names, lines_, errors, compactions


def role_of(names):
    """(role, task slug) by the name VibeSwitcher starts a session with; None for any other."""
    for name in sorted(names):
        if name.startswith("lead-"):
            return "lead", None
        if name.startswith("worker-"):
            return "worker", name[len("worker-"):].split("--")[0]
        if name.startswith("verify-"):
            return "verifier", name[len("verify-"):]
        m = re.match(r"finder\d+-(.+)$", name)
        if m:
            return "verifier", m.group(1)
    return None


# ---------------------------------------------------------------- outside the transcripts

def sleeps():
    """The Mac's sleeps as (from, to), from the power log; None when it can't be read."""
    try:
        out = subprocess.run(["pmset", "-g", "log"], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    spans, asleep = [], None
    for m in re.finditer(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ([+-]\d{4}) (Sleep|Wake|DarkWake) *\t", out, re.M):
        at = datetime.datetime.strptime(m.group(1) + " " + m.group(2), "%Y-%m-%d %H:%M:%S %z").timestamp()
        if m.group(3) == "Sleep":
            asleep = asleep if asleep is not None else at
        elif asleep is not None:
            spans.append((asleep, at))
            asleep = None
    return spans


def overlap(a, b, spans):
    return sum(max(0.0, min(b, y) - max(a, x)) for x, y in spans)


def board(root):
    """Times by task slug, the questions' spans, and the events that reach the lead."""
    tasks, questions, events = {}, [], []
    folder = os.path.join(root, ".vibeswitcher")

    def task(t):
        slug = t.get("slug")
        if not isinstance(slug, str):
            return
        receipt, waits = t.get("receipt") or {}, t.get("waits") or (t.get("receipt") or {}).get("waits") or {}
        merged = (t.get("merged") or {}).get("at")
        ready = receipt.get("mergeReady") or merged
        run = sum(float(waits.get(k) or 0) for k in ("mergeLoadWait", "mergeSlotWait", "mergeTesting"))
        entry = {"started": t.get("startedAt"), "done": (t.get("evidence") or {}).get("at"), "merged": merged,
                 "ended": receipt.get("endedAt") or merged, "merge": (ready - run, merged or ready) if ready else None}
        tasks[slug] = entry
        for at, kind in ((entry["done"], "a worker's report"), ((t.get("setback") or {}).get("at"), "a worker's report"),
                         (merged, "a merge's result"), ((t.get("dryRun") or {}).get("at"), "a merge's result")):
            if at:
                events.append((float(at), kind))
        q = t.get("question")
        if isinstance(q, dict) and q.get("askedAt"):
            question(q, slug)

    def question(q, slug=None):
        end = q.get("answeredAt") or q.get("autoDecidedAt") or q.get("withdrawnAt") or float("inf")
        questions.append((float(q["askedAt"]), float(end), q.get("task") or slug))
        if q.get("answeredAt"):
            events.append((float(q["answeredAt"]), "the user's answer to a question"))

    try:
        with open(os.path.join(folder, "board.json")) as fh:
            b = json.load(fh)
    except (OSError, ValueError):
        return tasks, questions, events, False
    try:
        with open(os.path.join(folder, "board-archive.jsonl")) as fh:
            for line in fh:
                try:
                    entry = json.loads(line)
                    if isinstance(entry, dict) and "slug" not in entry and isinstance(entry.get("question"), dict):
                        if entry["question"].get("askedAt"):
                            question(entry["question"])     # a closed question, archived by itself
                    elif isinstance(entry, dict):
                        task(entry)
                except (ValueError, TypeError):
                    pass
    except OSError:
        pass
    for t in (b.get("archivedBatch") or []) + (b.get("tasks") or []):
        task(t)
    for q in b.get("questions") or []:
        if q.get("askedAt"):
            question(q)
    for r in b.get("reports") or []:
        if r.get("at"):
            events.append((float(r["at"]), "a worker's report"))
    return tasks, questions, sorted(events), True


# ---------------------------------------------------------------- causes

CAUSES = ["Mac sleep", "usage-limit stop", "waiting on an audit", "waiting on a merge", "waiting on the user",
          "woken by a worker's report", "woken by an audit's verdict", "woken by a merge's result",
          "woken by the user's answer to a question", "its own long job (a tool call or background run past the TTL)",
          "its own timer", "a message from another session", "typed in after an idle (the user, or a notice of the app's own)",
          "waiting on the lead (no audit, merge or question in the gap)", "after its task ended", "other"]


def team_event(b, events, ends):
    """What reached the lead in the EVENT_WINDOW_S before `b`: the board's event, else a turn's end."""
    near = [kind for at, kind in events if b - EVENT_WINDOW_S <= at <= b + 5]
    if near:
        return near[-1]
    for who, what in (("verifier", "an audit's verdict"), ("worker", "a worker's report")):
        i = bisect.bisect_left(ends[who], b - EVENT_WINDOW_S)
        if i < len(ends[who]) and ends[who][i] <= b + 5:
            return what
    return None


def cause(role, slug, sub, a, b, ttl, origin, errors, ctx):
    spans, tasks, questions, events, audits, ends = ctx
    if any(kind == "rate_limit" and a - 120 <= at <= b for at, kind in errors):
        return "usage-limit stop"
    if spans is not None and (b - a) - overlap(a, b, spans) <= ttl:
        return "Mac sleep"
    if sub or origin in (None, "task_notification"):
        # No new turn since the last response, or its own background job's end started one.
        if sub or role != "lead" or origin is None:
            return "its own long job (a tool call or background run past the TTL)"
    if origin == "scheduled":
        return "its own timer"
    if role == "lead":
        woke = team_event(b, events, ends)
        if woke:
            return "woken by " + woke
        if origin == "task_notification":
            return "its own long job (a tool call or background run past the TTL)"
        if origin == "peer":
            return "a message from another session"
        return "typed in after an idle (the user, or a notice of the app's own)"
    task = tasks.get(slug) or {}
    asked = overlap(a, b, [(x, y) for x, y, about in questions if about == slug])
    if asked >= (b - a) / 2:
        return "waiting on the user"
    if role == "worker":
        audit = overlap(a, b, audits.get(slug, []))
        merge = overlap(a, b, [task["merge"]]) if task.get("merge") else 0
        if audit > 0 or merge > 0:
            return "waiting on an audit" if audit >= merge else "waiting on a merge"
        if task.get("ended") and a >= task["ended"]:
            return "after its task ended"
        if origin == "peer":
            return "a message from another session"
        return "waiting on the lead (no audit, merge or question in the gap)"
    return "other"


# ---------------------------------------------------------------- main

def count(n):
    n = float(n)
    if abs(n) >= 1e9:
        return f"{n / 1e9:.2f}B"
    if abs(n) >= 1e6:
        return f"{n / 1e6:.1f}M"
    if abs(n) >= 1e3:
        return f"{n / 1e3:.0f}k"
    return f"{n:.0f}"


def pct(part, whole):
    return f"{100 * part / whole:.1f}%" if whole else "–"


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--until", metavar="'YYYY-MM-DD HH:MM'", help="the window's end, local time (default: now)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--events", action="store_true", help="also list each cold re-send: when, whose, its gap and context")
    ap.add_argument("--price-as", action="append", default=[], metavar="MODEL=PRICED",
                    help="take MODEL's rates from PRICED (a model the Receipts table has), for a model it has no price for")
    args = ap.parse_args()
    price_as = dict(x.split("=", 1) for x in args.price_as)
    here = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    table, as_of = prices(here)
    root = repo_root()
    now = time.mktime(time.strptime(args.until, "%Y-%m-%d %H:%M")) if args.until else time.time()
    since = now - args.days * 86400
    base = os.path.expanduser("~/.claude/projects")
    own, trees = claude_name(root), claude_name(os.path.join(root, ".vibeswitcher", "worktrees")) + "-"
    folders = [d for d in glob.glob(os.path.join(base, "*")) if os.path.basename(d) == own or os.path.basename(d).startswith(trees)]

    seen, sessions = set(), []
    for d in sorted(folders):
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
            if os.path.getmtime(f) < since:
                continue
            names, lines_, errors, compactions = load(f, seen, since, now)
            who = role_of(names)
            if who is None:
                continue        # the user's own session in that folder: not read past its name
            role, slug = who
            sessions.append({"role": role, "slug": slug, "sub": False, "lines": lines_, "errors": errors, "compactions": compactions})
            for g in sorted(glob.glob(os.path.join(f[:-len(".jsonl")], "subagents", "*.jsonl"))):
                if os.path.getmtime(g) < since:
                    continue
                _n, sublines, suberrors, _c = load(g, seen, since, now)
                sessions.append({"role": role, "slug": slug, "sub": True, "lines": sublines, "errors": suberrors, "compactions": []})

    # An audit's span: its verifier's (or a finder's) first request to its last, by task.
    audits = collections.defaultdict(list)
    for s in sessions:
        if s["role"] == "verifier" and not s["sub"]:
            times = [r["t"] for rs in s["lines"].values() for r in rs]
            if times:
                audits[s["slug"]].append((min(times), max(times)))
    spans = sleeps()
    tasks, questions, events, has_board = board(root)
    # A turn's end: a main session's request that no other follows within TURN_END_S.
    ends = {"worker": [], "verifier": []}
    for s in sessions:
        if s["role"] in ends and not s["sub"]:
            times = sorted(r["t"] for line, rs in s["lines"].items() if not line.endswith("|advisor") for r in rs)
            ends[s["role"]] += [t for t, nxt in zip(times, times[1:] + [float("inf")]) if nxt - t > TURN_END_S]
    for who in ends:
        ends[who].sort()
    ctx = (spans, tasks, questions, events, audits, ends)

    def group(s, line):
        if line.endswith("|advisor"):
            return s["role"] + "'s advisor"
        return s["role"] + (" subagents" if s["sub"] else "")

    order = ["lead", "lead's advisor", "lead subagents", "worker", "worker's advisor", "worker subagents",
             "verifier", "verifier's advisor", "verifier subagents"]
    zero = lambda: collections.defaultdict(float)
    tot = collections.defaultdict(zero)
    by_cause = collections.defaultdict(lambda: collections.defaultdict(zero))
    hist = collections.defaultdict(lambda: [0, 0, 0.0, 0.0])   # (ttl, gap bucket) -> responses, missed, read, previous prompt
    models = collections.defaultdict(float)
    unpriced = collections.defaultdict(float)
    cold_events = []
    warm = collections.defaultdict(zero)   # keep-warm policy by cap
    rotate_at = [100_000, 150_000, 200_000]
    rotate = {n: zero() for n in rotate_at}
    caps = [1, 2, 4, 8, 24]
    buckets = [(0, 300, "≤ 5 min"), (300, 1800, "5–30 min"), (1800, 3300, "30–55 min"), (3300, 3600, "55–60 min"),
               (3600, 4200, "60–70 min"), (4200, 7200, "70–120 min"), (7200, 1e12, "> 2 h")]

    for s in sessions:
        for line, rs in s["lines"].items():
            g = group(s, line)
            sub = s["sub"] or line.endswith("|advisor")
            if any(not r.get("before") for r in rs):
                tot[g]["sessions"] += 1
            prev, ttl = None, None
            offsets = {n: 0.0 for n in rotate_at}
            for r in rs:
                prompt = r["in"] + r["read"] + r["cw"]
                price = price_of(r["model"], table, price_as)
                counted = not r.get("before")
                if counted and g == "lead" and r["origin"] == "human":
                    tot[g]["turns"] += 1
                    tot[g]["turns_team"] += 1 if team_event(r["t"], events, ends) else 0
                if counted and g == "lead" and prev is not None:
                    # Had the lead handed over to a fresh one at an idle of ROTATE_IDLE_S with its context over n.
                    # Tokens are counted whatever the model; dollars only for a priced one.
                    before_, gap_ = prev["in"] + prev["read"] + prev["cw"], r["t"] - prev["t"]
                    _i, out_, read_, _w5, w1_ = rates(r, price) if price else (0.0,) * 5
                    shrank = prompt < before_ * 0.7     # a compaction or a new start already dropped the old context
                    for n in rotate_at:
                        ro = rotate[n]
                        if shrank:
                            offsets[n] = 0.0            # nothing left for a handover to save here
                        carried = before_ - offsets[n]
                        if not shrank and gap_ > ROTATE_IDLE_S and carried >= n:
                            ro["rotations"] += 1
                            awake = spans is None or overlap(prev["t"], prev["t"] + ROTATE_IDLE_S, spans) < 60
                            if awake:
                                ro["warm_notes"] += 1
                                ro["spent"] += carried * read_ + 1000 * out_      # the note's turn, on a warm cache
                                ro["spent_tokens"] += carried
                            was = min(r["cw"], max(0, before_ - r["read"])) if ttl is not None and gap_ > ttl else 0
                            was = max(0, was - offsets[n])
                            ro["write_saved"] += was - FRESH_LEAD                # the fresh lead writes its own start
                            ro["saved"] += (was - FRESH_LEAD) * w1_
                            if not was:
                                ro["saved"] += carried * read_                   # ...and doesn't read the old context
                            offsets[n] = before_ - FRESH_LEAD
                        # Never less than a fresh lead carries.
                        kept = min(offsets[n], r["read"], max(0, prompt - FRESH_LEAD))
                        ro["read_saved"] += kept
                        ro["saved"] += kept * read_
                if counted:
                    t = tot[g]
                    for k in ("in", "out", "read", "cw", "cw1h", "cw5m"):
                        t[k] += r[k]
                    t["responses"] += 1
                    models[r["model"]] += prompt + r["out"]
                    if price:
                        t["cost"] += cost(r, price)
                    else:
                        unpriced[r["model"]] += prompt + r["out"]
                        t["unpriced"] += prompt + r["out"]
                if prev is None:
                    if counted:
                        tot[g]["first_cw"] += r["cw"]
                        tot[g]["first_prompts"] += 1
                        tot[g]["first_prompt_tokens"] += prompt
                elif counted:
                    gap = r["t"] - prev["t"]
                    before = prev["in"] + prev["read"] + prev["cw"]
                    resent = min(r["cw"], max(0, before - r["read"]))
                    missed = before >= MIN_CONTEXT and r["read"] < before / 2
                    if ttl is not None:
                        for lo, hi, label in buckets:
                            if lo < gap <= hi or (lo == 0 and gap <= hi):
                                h = hist[(ttl, label)]
                                h[0] += 1
                                h[1] += 1 if missed else 0
                                h[2] += r["read"]
                                h[3] += before
                                break
                    if ttl is not None and gap > ttl:
                        why = cause(s["role"], s["slug"], sub, prev["t"], r["t"], ttl, r["origin"], s["errors"], ctx)
                        extra = 0.0
                        if price:
                            _i, _o, read, w5, w1 = rates(r, price)
                            extra = resent * ((w1 if r["cw1h"] >= r["cw5m"] else w5) - read)
                        t = tot[g]
                        t["cold"] += 1
                        t["cold_cw"] += r["cw"]
                        t["cold_resent"] += resent
                        t["cold_extra"] += extra
                        t["cold_slept"] += overlap(prev["t"], r["t"], spans) if spans else 0
                        t["cold_gap"] += gap
                        c = by_cause[g][why]
                        c["n"] += 1
                        c["cw"] += r["cw"]
                        c["resent"] += resent
                        c["extra"] += extra
                        cold_events.append({"group": g, "cause": why, "gap": gap, "context": before, "resent": resent, "extra": extra,
                                            "ttl": ttl, "model": r["model"], "at": r["t"], "task": s["slug"] or "",
                                            "slept": overlap(prev["t"], r["t"], spans) if spans else 0})
                        # Keep-warm: a request every PING_EVERY_S while idle, at most `cap` of them.
                        if ttl >= 3600 and why not in ("Mac sleep", "usage-limit stop"):
                            # Tokens whatever the model; dollars only for a priced one.
                            _i, out, read, _w5, _w1 = rates(prev, price) if price else (0.0,) * 5
                            need = int(gap // PING_EVERY_S)
                            for cap in caps:
                                w = warm[(g, cap)]
                                w["pings"] += min(need, cap)
                                w["ping_tokens"] += min(need, cap) * before
                                w["spent"] += min(need, cap) * (before * read + 150 * out)
                                if need <= cap:
                                    w["saved"] += extra
                                    w["kept"] += 1
                                    w["saved_tokens"] += resent
                    elif missed:
                        shrank = prompt < before * 0.7
                        t = tot[g]
                        t["warm_miss"] += 1
                        t["warm_miss_cw"] += r["cw"]
                        t["compact_cw" if shrank else "other_miss_cw"] += r["cw"]
                        t["compact_n" if shrank else "other_miss_n"] += 1
                if r["cw1h"] > 0 or r["cw5m"] > 0:
                    ttl = 3600 if r["cw1h"] >= r["cw5m"] else 300
                prev = r
        for c in s["compactions"]:
            if since <= c["t"] <= now and not s["sub"]:
                t = tot[s["role"]]
                t["compactions"] += 1
                t["compact_pre"] += c["pre"]
                t["compact_post"] += c["post"]
                t["compact_" + c["trigger"]] += 1
                if c["idle"] is not None and 3000 <= c["idle"] <= 3600:
                    t["compactions_idle"] += 1

    groups = [g for g in order if g in tot]
    total = zero()
    for g in groups:
        for k, v in tot[g].items():
            total[k] += v
    tokens = lambda t: t["in"] + t["out"] + t["read"] + t["cw"]

    out = {"days": args.days, "prices_as_of": as_of, "price_as": price_as, "board": has_board, "sleep_log": spans is not None,
           "slept_h": round(overlap(since, now, spans) / 3600, 1) if spans else None,
           "groups": {g: dict(tot[g]) for g in groups}, "total": dict(total),
           "causes": {g: {c: dict(v) for c, v in by_cause[g].items()} for g in groups},
           "models": dict(models), "unpriced": dict(unpriced),
           "keep_warm": {f"{g}|{cap}": dict(v) for (g, cap), v in warm.items()},
           "histogram": {f"{ttl}|{label}": v for (ttl, label), v in hist.items()}}
    if args.json:
        json.dump(out, sys.stdout, indent=1)
        print()
        return

    day = lambda t: time.strftime("%Y-%m-%d %H:%M", time.localtime(t))
    print(f"Window: {day(since)} to {day(now)} ({args.days:g} days). Sessions read: "
          + ", ".join(f"{int(tot[g]['sessions'])} {g}" for g in groups) + ".")
    print(f"Prices: LeadPrices.table as of {as_of}" + (f"; --price-as {price_as}" if price_as else "")
          + ("; no price for: " + ", ".join(f"{m} ({count(v)} tokens)" for m, v in sorted(unpriced.items())) if unpriced else "") + ".")
    print("Mac asleep in the window: " + (f"{out['slept_h']} h (pmset -g log)." if spans is not None else "unknown (no power log).")
          + ("" if has_board else " No board found: causes that need it fall under the others."))
    print()
    print("### Tokens and TTL by role")
    print("| role | responses | tokens | input | output | cache read | cache write | in the 1 h bucket | in the 5 min bucket | TTL it gets | est. cost |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |")
    for g in groups + ["all"]:
        t = total if g == "all" else tot[g]
        ttl = "1 h" if t["cw1h"] > 0.95 * t["cw"] else "5 min" if t["cw5m"] > 0.95 * t["cw"] else "mixed"
        print(f"| {g} | {int(t['responses'])} | {count(tokens(t))} | {count(t['in'])} | {count(t['out'])} | {count(t['read'])} | {count(t['cw'])} | "
              f"{pct(t['cw1h'], t['cw'])} | {pct(t['cw5m'], t['cw'])} | {ttl} | ${t['cost']:,.0f}{' + unpriced' if t['unpriced'] else ''} |")
    print()
    print("### Cache writes by why they were written")
    print("| role | cache write | written cold (gap > TTL) | share | of it re-sent context | cold re-sends | median context at one | a session's first write | after a compaction | other miss inside the TTL | extra cost of the re-sent |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for g in groups + ["all"]:
        t = total if g == "all" else tot[g]
        ctxs = [e["context"] for e in cold_events if g == "all" or e["group"] == g]
        print(f"| {g} | {count(t['cw'])} | {count(t['cold_cw'])} | {pct(t['cold_cw'], t['cw'])} | {count(t['cold_resent'])} | {int(t['cold'])} | "
              f"{count(median(ctxs))} | {count(t['first_cw'])} | {count(t['compact_cw'])} | {count(t['other_miss_cw'])} | ${t['cold_extra']:,.0f} |")
    print()
    print("### Causes of the cold re-sends")
    print("| role | cause | cold re-sends | written cold | re-sent context | share of the role's cold writes | extra cost |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for g in groups:
        for why, c in sorted(by_cause[g].items(), key=lambda x: -x[1]["cw"]):
            print(f"| {g} | {why} | {int(c['n'])} | {count(c['cw'])} | {count(c['resent'])} | {pct(c['cw'], tot[g]['cold_cw'])} | ${c['extra']:,.0f} |")
    print()
    print("### The week's bill and the cold share of it")
    all_tokens = tokens(total)
    print(f"- All roles: {count(all_tokens)} tokens, est. ${total['cost']:,.0f}"
          + (f" for the priced models ({count(total['unpriced'])} tokens have no price)" if total["unpriced"] else "") + ".")
    print(f"- Written cold: {count(total['cold_cw'])} tokens in {int(total['cold'])} re-sends = {pct(total['cold_cw'], all_tokens)} of the tokens, "
          f"{pct(total['cold_cw'], total['cw'])} of the cache writes.")
    print(f"- Of it re-sent context (in the cache before the gap): {count(total['cold_resent'])} tokens; writing it again instead of reading it "
          f"cost est. ${total['cold_extra']:,.0f} = {pct(total['cold_extra'], total['cost'])} of the bill.")
    for g in groups:
        t = tot[g]
        if t["compactions"]:
            triggers = ", ".join(f"{int(v)} {k[len('compact_'):]}" for k, v in sorted(t.items())
                                 if k.startswith("compact_") and k not in ("compact_pre", "compact_post", "compact_cw", "compact_n"))
            print(f"- Compactions, {g}: {int(t['compactions'])} (by trigger: {triggers}), {int(t['compactions_idle'])} of them 50–60 min after "
                  f"the session's last response; {count(t['compact_pre'])} tokens before, {count(t['compact_post'])} after.")
    print()
    print("### Does the measured TTL hold? Cache misses by gap")
    print("| TTL in force | gap since the last request | responses | missed (read under half the last prompt, of 20k+) | cache read / last prompt |")
    print("| --- | --- | ---: | ---: | ---: |")
    for ttl in (3600, 300):
        for _lo, _hi, label in buckets:
            h = hist.get((ttl, label))
            if h:
                print(f"| {'1 h' if ttl == 3600 else '5 min'} | {label} | {h[0]} | {h[1]} | {pct(h[2], h[3])} |")
    print()
    print(f"### A keep-warm request every {PING_EVERY_S // 60} min while idle (1 h lines; not through sleep or a usage limit)")
    print("| role | at most | cold re-sends avoided | re-sent tokens avoided | requests sent | cache-read tokens they cost | est. saved | est. spent | net |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for g in groups:
        for cap in caps:
            w = warm.get((g, cap))
            if w:
                print(f"| {g} | {cap} | {int(w['kept'])} | {count(w['saved_tokens'])} | {int(w['pings'])} | {count(w['ping_tokens'])} | "
                      f"${w['saved']:,.0f} | ${w['spent']:,.0f} | ${w['saved'] - w['spent']:,.0f} |")
    print()
    print("### Cold re-sends by size (what a fresh session would not carry)")
    print("| role | context at the re-send | cold re-sends | re-sent context | extra cost |")
    print("| --- | --- | ---: | ---: | ---: |")
    sizes = [(0, 50_000, "< 50k"), (50_000, 100_000, "50–100k"), (100_000, 200_000, "100–200k"), (200_000, 10**9, "≥ 200k")]
    for g in groups:
        for lo, hi, label in sizes:
            es = [e for e in cold_events if e["group"] == g and lo <= e["context"] < hi]
            if es:
                print(f"| {g} | {label} | {len(es)} | {count(sum(e['resent'] for e in es))} | ${sum(e['extra'] for e in es):,.0f} |")
    firsts = {g: tot[g]["first_prompt_tokens"] / tot[g]["first_prompts"] for g in groups if tot[g]["first_prompts"]}
    print()
    print("A session's first prompt (mean tokens): " + ", ".join(f"{g} {count(v)}" for g, v in firsts.items()) + ".")
    print()
    print(f"### Handing the lead over at an idle of {ROTATE_IDLE_S // 60} min (a fresh lead carries {count(FRESH_LEAD)})")
    print("| when its context is over | handovers | of them with the Mac awake for the note | cache-read tokens not carried after | cache-write tokens saved (net of the fresh starts) | est. saved | est. spent on the notes | net |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for n in rotate_at:
        ro = rotate[n]
        print(f"| {count(n)} | {int(ro['rotations'])} | {int(ro['warm_notes'])} | {count(ro['read_saved'])} | {count(ro['write_saved'])} | "
              f"${ro['saved']:,.0f} | ${ro['spent']:,.0f} | ${ro['saved'] - ro['spent']:,.0f} |")
    print()
    if tot["lead"]["turns"]:
        print(f"The lead's turns started by a typed prompt: {int(tot['lead']['turns'])}, {int(tot['lead']['turns_team'])} of them within "
              f"{EVENT_WINDOW_S} s after a team event (a report, a verdict, a merge, an answer).")
    starts = collections.defaultdict(list)
    for s in sessions:
        if s["role"] == "worker" and not s["sub"]:
            rs = sorted((r for line, x in s["lines"].items() if not line.endswith("|advisor") for r in x), key=lambda r: r["t"])
            if rs:
                starts[s["slug"]].append((rs[0]["t"], rs[-1]["t"], rs[0]["in"] + rs[0]["read"] + rs[0]["cw"], rs[0]["cw"],
                                          rs[-1]["in"] + rs[-1]["read"] + rs[-1]["cw"], len(rs)))
    replaced = []
    for slug, runs in starts.items():
        runs.sort()
        for (_a, last, _p, _c, carried, _n), (first, _l, prompt, cw, _x, requests) in zip(runs, runs[1:]):
            if first >= since and any(0 <= first - e <= REPLACED_S for _s, e in audits.get(slug, [])):
                replaced.append((first - last, prompt, cw, carried, requests))
    if replaced:
        within = [x for x in replaced if x[0] <= PING_EVERY_S]
        print(f"Workers started within {REPLACED_S // 60} min after their task's audit ended, after an earlier worker (a released one's replacement): "
              f"{len(replaced)}; {len(within)} of them within {PING_EVERY_S // 60} min of the earlier one's last request (its cache still warm). "
              f"Their first prompts: {count(sum(x[1] for x in replaced))} tokens, {count(sum(x[2] for x in replaced))} of them cache writes; "
              f"the earlier workers' contexts: median {count(median([x[3] for x in replaced]))}; "
              f"the replacements' requests: median {median([x[4] for x in replaced])}.")
    spans_ = [e - s for ends in audits.values() for s, e in ends]
    if spans_:
        print(f"Audits (a verifier's first request to its last): {len(spans_)}, median {median(spans_) / 60:.0f} min, "
              f"{pct(sum(1 for x in spans_ if x <= PING_EVERY_S), len(spans_))} within {PING_EVERY_S // 60} min.")
    if args.events:
        print()
        print("### Each cold re-send")
        print("| when | role | task | cause | gap | of it asleep | context before | re-sent | model |")
        print("| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |")
        for e in sorted(cold_events, key=lambda e: e["at"]):
            print(f"| {day(e['at'])} | {e['group']} | {e['task']} | {e['cause']} | {e['gap'] / 3600:.1f} h | {pct(e['slept'], e['gap'])} | "
                  f"{count(e['context'])} | {count(e['resent'])} | {e['model']} |")
        print()
    print("Models by tokens: " + ", ".join(f"{m} {count(v)}" for m, v in sorted(models.items(), key=lambda x: -x[1])) + ".")


if __name__ == "__main__":
    main()
