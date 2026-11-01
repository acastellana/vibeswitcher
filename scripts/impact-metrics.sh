#!/bin/bash
# The standard metrics of the feature impact ledger (docs/process/impact.md) for a date range, from data already on
# this Mac, so a ledger entry's result can be filled in minutes. Read-only: it never writes or removes anything.
#
# scripts/impact-metrics.sh FROM..TO [--project DIR]... [--home DIR]
#   FROM, TO       yyyy-MM-dd (TO counts through the end of its day) or yyyy-MM-ddTHH:MM, local time
#   --project DIR  a project's repository (repeatable); default: the repository of the current folder. A worktree
#                  counts as its main checkout, where the board and the lead's records are.
#   --home DIR     VibeSwitcher's folder instead of $VIBESWITCHER_HOME, else ~/.vibeswitcher
#
# Per project it reads <repo>/.vibeswitcher/board.json and board-archive.jsonl (tasks, receipts, scores, the flake
# ledger), <repo>/docs/lead/progress.md and incidents.md. Mac-wide it reads <home>/debug/hang-*.txt|.log (one freeze
# each) and the load recorder's <home>/stats/load-<day>.jsonl and merges-<day>.jsonl when they exist. Nothing else:
# never <home>/lead. A metric whose source is missing prints "n/a" and the reason, never a guess.
set -euo pipefail

home="${VIBESWITCHER_HOME:-$HOME/.vibeswitcher}"
range=""
projects=()
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
while (($#)); do
    case "$1" in
        --home) home="${2:?--home needs a folder}"; shift 2 ;;
        --project) projects+=("${2:?--project needs a folder}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "impact-metrics: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) [[ -z $range ]] || { echo "impact-metrics: one range only (got '$range' and '$1')" >&2; exit 2; }
           range="$1"; shift ;;
    esac
done
stamp='[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2})?'
[[ $range =~ ^$stamp\.\.$stamp$ ]] || { echo "impact-metrics: give a range FROM..TO (yyyy-MM-dd or yyyy-MM-ddTHH:MM)" >&2; usage >&2; exit 2; }
((${#projects[@]})) || projects=(.)

# Each project's main checkout: a worktree's common git folder is the main checkout's .git. Only for a checkout's
# top folder: a folder inside a repository (a test's scratch project) is read as it is.
roots=()
for project in "${projects[@]}"; do
    [[ -d $project ]] || { echo "impact-metrics: no folder $project" >&2; exit 2; }
    folder=$(cd "$project" && pwd -P)
    top=$(cd "$folder" && git rev-parse --show-toplevel 2> /dev/null || true)
    common=""
    [[ -n $top && $(cd "$top" && pwd -P) == "$folder" ]] \
        && common=$(cd "$folder" && git rev-parse --path-format=absolute --git-common-dir 2> /dev/null || true)
    if [[ $common == */.git ]]; then
        roots+=("${common%/.git}")
    else
        roots+=("$folder")
    fi
done

exec /usr/bin/python3 -I - "$home" "$range" "${roots[@]}" <<'PY'
import datetime as dt, json, os, re, statistics, sys, time

home, spec, roots = sys.argv[1], sys.argv[2], sys.argv[3:]
first, last = spec.split("..")

def parse(text, end):
    """A range end as local wall time: a day starts at 00:00, and TO's day runs through its end."""
    if "T" in text:
        return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M")
    day = dt.datetime.strptime(text, "%Y-%m-%d")
    return day + dt.timedelta(days=1) if end else day

start, end = parse(first, False), parse(last, True)
if end <= start:
    sys.exit(f"impact-metrics: the range {spec} is empty (TO before FROM)")
t0, t1 = time.mktime(start.timetuple()), time.mktime(end.timetuple())
# Rates divide by the hours that have passed: a range running into the future doesn't dilute them.
hours = max(0.0, min(t1, time.time()) - t0) / 3600

def within(epoch):
    return epoch is not None and t0 <= epoch < t1

def local_epoch(text, fmt):
    return time.mktime(dt.datetime.strptime(text, fmt).timetuple())

def median(values):
    return statistics.median(values) if values else None

def duration(seconds):
    if seconds is None:
        return "n/a"
    minutes = seconds / 60
    return f"{minutes:.0f} min" if minutes < 120 else f"{minutes / 60:.1f} h"

def ratio(part, whole, digits=2):
    return f"{part / whole:.{digits}f}" if whole else "n/a"

def line(name, value, note=""):
    print(f"  {name}: {value}" + (f" ({note})" if note else ""))

def read_jsonl(path):
    found = []
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                try:
                    found.append(json.loads(raw))
                except ValueError:
                    pass  # a line cut short by a crash
    except OSError:
        return None
    return found

# --- Mac-wide sources: the hang logs and the load recorder's files -------------------------------------------------
debug, stats = os.path.join(home, "debug"), os.path.join(home, "stats")

def recorder(kind):
    """The load recorder's lines of `kind` ("load", "merges") for the range's days, None when it wrote no file."""
    found, any_file = [], False
    day = start.date()
    while day <= (end - dt.timedelta(seconds=1)).date():
        lines = read_jsonl(os.path.join(stats, f"{kind}-{day.isoformat()}.jsonl"))
        if lines is not None:
            any_file = True
            for item in lines:
                try:
                    item["_at"] = dt.datetime.fromisoformat(item["t"]).timestamp()
                except (KeyError, TypeError, ValueError):
                    continue
                if within(item["_at"]):
                    found.append(item)
        day += dt.timedelta(days=1)
    return found if any_file else None

samples, recorded_merges = recorder("load"), recorder("merges")
if samples is not None:
    samples = sorted((s for s in samples if s.get("load")), key=lambda s: s["_at"])

# The app prunes hang reports (HangWatchdog.prune: a week, at most 500 MB, oldest first; before 2026-10-28 12:10 only
# the 10 newest), so a stretch before the oldest report left has lost its freezes: those hours aren't counted, never
# read as freeze-free. With no report at all, the last week is covered.
hangs, covered_from = None, None
if os.path.isdir(debug):
    hangs, stamps = set(), []
    for name in os.listdir(debug):
        m = re.fullmatch(r"hang-(\d{8}-\d{6})\.(txt|log)", name)
        if m:  # a freeze writes a .txt and a .log under one stamp: count it once
            at = local_epoch(m.group(1), "%Y%m%d-%H%M%S")
            stamps.append(at)
            if within(at):
                hangs.add(at)
    covered_from = min(stamps) if stamps else time.time() - 7 * 86_400
covered_start = max(t0, covered_from) if covered_from is not None else t0
covered_hours = max(0.0, min(t1, time.time()) - covered_start) / 3600
pruned_note = ""
if covered_from is not None and covered_start > t0:
    pruned_note = (f"reports before {dt.datetime.fromtimestamp(covered_start).strftime('%Y-%m-%d %H:%M')} were pruned"
                   " by the app, which keeps a week, at most 500 MB")

EDGES = [0, 12, 24, 36, 48, 72, 100, 150]  # as scripts/load-report.sh buckets the 1-minute load
NAMES = [f"{l}-{h}" for l, h in zip(EDGES, EDGES[1:])] + [f"{EDGES[-1]}+"]

def bucket(load):
    for low, high in zip(EDGES, EDGES[1:]):
        if load < high:
            return f"{low}-{high}"
    return f"{EDGES[-1]}+"

def nearest(at):
    """The load sample within 2 minutes of `at`, the nearest one."""
    best = None
    for s in samples:
        gap = abs(s["_at"] - at)
        if gap <= 120 and (best is None or gap < best[0]):
            best = (gap, s)
    return best[1] if best else None

# --- Per project ---------------------------------------------------------------------------------------------------
PROGRESS = re.compile(r"^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) (.*)$")
AUDIT_START = re.compile(r"^Automatically \(auto_advance\): Started the audit of ([a-z0-9-]+) at ")
INCIDENT = re.compile(r"^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ")

def load_tasks(folder):
    """The board's tasks and its archive's (each task once: the board's live copy over the archive's last line), the
    flake ledger, and which of the two files were there."""
    board_path = os.path.join(folder, "board.json")
    try:
        with open(board_path, encoding="utf-8") as f:
            board = json.load(f)
    except (OSError, ValueError):
        board = None
    archived = read_jsonl(os.path.join(folder, "board-archive.jsonl"))
    tasks = {}
    for task in archived or []:
        if isinstance(task, dict) and "id" in task:
            tasks[task["id"]] = task
    for task in (board or {}).get("tasks", []):
        tasks[task["id"]] = task
    flakes = (board or {}).get("flakes") if board is not None else None
    return list(tasks.values()), flakes, board is not None, archived is not None

def receipt_cost(receipt):
    """A receipt's estimated cost, both roles; None when a role's is unknown."""
    parts = [receipt.get(role) for role in ("worker", "verifier") if receipt.get(role)]
    costs = [p.get("cost") for p in parts]
    if not parts or any(c is None for c in costs):
        return None
    return sum(costs)

def report(root):
    name = os.path.basename(root.rstrip("/"))
    print(f"Project {name} ({root})")
    tasks, flakes, has_board, has_archive = load_tasks(os.path.join(root, ".vibeswitcher"))
    progress_path, incidents_path = (os.path.join(root, "docs", "lead", n) for n in ("progress.md", "incidents.md"))
    progress = None
    if os.path.exists(progress_path):
        progress = []
        with open(progress_path, encoding="utf-8") as f:
            for raw in f:
                m = PROGRESS.match(raw.rstrip("\n"))
                if m:
                    progress.append((local_epoch(m.group(1), "%Y-%m-%d %H:%M"), m.group(2)))

    if not has_board:
        print("  board: n/a (no .vibeswitcher/board.json)")
    elif not has_archive:
        print("  board: board.json only (no board-archive.jsonl: tasks archived elsewhere aren't counted)")

    # Every merge in the range, reverted since or not.
    merged = [t for t in tasks if within((t.get("merged") or {}).get("at"))]
    merged.sort(key=lambda t: t["merged"]["at"])
    n = len(merged)

    # Throughput.
    if not has_board:
        line("merges/h", "n/a", "no board")
    else:
        active = None
        if progress is not None:
            active = len({int(at // 3600) for at, _ in progress if within(at)})
        per_active = f"{ratio(n, active)} per active hour, {active} h with lead activity" if active is not None else "active hours n/a: no progress.md"
        line("merges/h", ratio(n, hours), f"{n} merges in {hours:.1f} h; {per_active}")

    # Lead times.
    starts = []
    for t in merged:
        began = (t.get("receipt") or {}).get("startedAt") or t.get("startedAt")
        if began is not None:
            starts.append(t["merged"]["at"] - began)
    line("median start-to-merge", duration(median(starts)) if has_board else "n/a",
         f"{len(starts)} of {n} merges have a start" if has_board else "no board")

    audited = [t for t in merged if (t.get("score") or {}).get("rounds", (t.get("audits") or {}).get("rounds", 0)) > 0]
    if progress is None:
        line("median audit-to-merge", "n/a", "no progress.md")
    else:
        first_audit = {}
        for at, text in progress:
            m = AUDIT_START.match(text)
            if m:
                first_audit.setdefault(m.group(1), []).append(at)
        waits = []
        for t in audited:
            # The first audit start of this task at or before its merge (progress.md has minutes; the merge, seconds).
            begun = [at for at in first_audit.get(t["slug"], []) if at <= t["merged"]["at"]]
            if begun:
                waits.append(t["merged"]["at"] - min(begun))
        line("median audit-to-merge", duration(median(waits)),
             f"{len(waits)} of {len(audited)} audited merges have an audit start in progress.md")

    # Review.
    if has_board:
        rounds = [(t.get("score") or {}).get("rounds", (t.get("audits") or {}).get("rounds", 0)) for t in audited]
        line("audit rounds per audited task", ratio(sum(rounds), len(rounds)), f"{sum(rounds)} rounds over {len(rounds)} audited of {n} merges")
        important = [(t.get("score") or {}).get("importantFindings", 0) for t in merged]
        line("Important findings per task", ratio(sum(important), n),
             f"{sum(important)} over {n} merges; {ratio(sum(important), len(audited))} per audited task")
        reverted = [t for t in tasks if (t.get("merged") or {}).get("revertedBy") or (t.get("score") or {}).get("revertedBy")
                    or t.get("status") == "reverted"]
        in_range = [t for t in reverted if within((t.get("merged") or {}).get("revertedAt") or (t.get("merged") or {}).get("at"))]
        line("reverts", len(in_range), "merges reverted in the range, by revert time, else merge time")
    else:
        for name_ in ("audit rounds per audited task", "Important findings per task", "reverts"):
            line(name_, "n/a", "no board")

    # Incidents.
    if os.path.exists(incidents_path):
        with open(incidents_path, encoding="utf-8") as f:
            heads = [INCIDENT.match(raw) for raw in f]
        count = sum(1 for m in heads if m and within(local_epoch(m.group(1), "%Y-%m-%d %H:%M:%S")))
        line("incidents", count, "docs/lead/incidents.md entries in the range")
    else:
        line("incidents", "n/a", "no docs/lead/incidents.md")

    # Merge test runs.
    if has_board:
        with_receipt = [t for t in merged if t.get("receipt")]
        flaky = [t for t in with_receipt if (t["receipt"].get("mergeReruns") or 0) > 0]
        ledger = [f for f in (flakes or []) if within(f.get("at"))]
        note = f"{len(flaky)} of {len(with_receipt)} merges with a receipt passed only on the rerun"
        if flakes is not None:
            note += f"; flake ledger: {len(ledger)} flakes of {len({f.get('test') for f in ledger})} tests in {len({f.get('task') for f in ledger})} merges"
        line("flaky-merge rate", f"{100 * len(flaky) / len(with_receipt):.0f}%" if with_receipt else "n/a", note)
    else:
        line("flaky-merge rate", "n/a", "no board")
    mine = [m for m in (recorded_merges or []) if m.get("project") == name]
    if recorded_merges is None:
        line("median full-suite duration", "n/a", "no load recorder merges-<day>.jsonl in the range")
    else:
        runs = [m["duration_s"] for m in mine if m.get("first_run") and m.get("duration_s") is not None]
        fails = sum(1 for m in mine if m.get("first_run") == "failed")
        line("median full-suite duration", f"{median(runs):.0f} s" if runs else "n/a",
             f"{len(runs)} recorded merge test runs; {fails} failed their first run")

    # Cost: the tasks that ended (merged, folded, abandoned) in the range, by their receipts.
    if has_board:
        ended = [t for t in tasks if t.get("receipt") and within(t["receipt"].get("endedAt"))]
        worked = sum((t["receipt"].get("worked") or 0) for t in ended)
        costs = [c for c in (receipt_cost(t["receipt"]) for t in ended) if c is not None]
        line("worker hours", f"{worked / 3600:.1f} h", f"{len(ended)} tasks ended with a receipt")
        line("estimated cost per task", f"${sum(costs) / len(costs):.2f}" if costs else "n/a",
             f"${sum(costs):.2f} over {len(costs)} receipts with a known cost" if costs else "no receipt with a known cost")
    else:
        line("worker hours", "n/a", "no board")
        line("estimated cost per task", "n/a", "no board")
    line("usage-limit stops", "n/a", "nothing on this Mac records them yet")
    print()

for root in roots:
    report(root)

print(f"Mac-wide ({home})")
if hangs is None:
    line("freezes/h", "n/a", "no debug folder")
elif covered_hours <= 0:
    line("freezes/h", "n/a", pruned_note)
else:
    line("freezes/h", ratio(len(hangs), covered_hours), f"{len(hangs)} hang reports in {covered_hours:.1f} h"
         + (f"; partial: {pruned_note}" if pruned_note else ""))
covered = [s for s in samples or [] if s["_at"] >= covered_start]
if samples is None or not samples:
    line("freezes/h by load bucket", "n/a", "no load recorder load-<day>.jsonl in the range")
elif hangs is None or covered_hours <= 0 or not covered:
    line("freezes/h by load bucket", "n/a", "no debug folder" if hangs is None else pruned_note or "no load sample in the covered hours")
else:
    rows = {b: [0, 0] for b in NAMES}  # minutes sampled, freezes
    for s in covered:
        rows[bucket(s["load"][0])][0] += 1
    unsampled = 0
    for at in sorted(hangs or []):
        s = nearest(at)
        if s is None:
            unsampled += 1
        else:
            rows[bucket(s["load"][0])][1] += 1
    print("  freezes/h by load bucket (1-min load: freezes / hours sampled)" + (f", partial: {pruned_note}" if pruned_note else "") + ":")
    for b in NAMES:
        minutes, freezes = rows[b]
        if minutes or freezes:
            rate = f"{freezes / (minutes / 60):.2f}" if minutes else "n/a"
            print(f"    {b:<8} {rate:>6}  ({freezes} / {minutes / 60:.1f} h)")
    if unsampled:
        print(f"    unsampled {unsampled} (no load sample within 2 minutes)")
PY
