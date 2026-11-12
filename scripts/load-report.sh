#!/bin/bash
# The Mac's load profile and VibeSwitcher's freezes per load bucket, from the load recorder's files
# (~/.vibeswitcher/stats/load-<day>.jsonl, one line a minute; merges-<day>.jsonl, one line a merge: see LoadRecorder.swift)
# joined with the app's hang logs (~/.vibeswitcher/debug/hang-<yyyyMMdd-HHmmss>.txt/.log), for a range of days.
# Read-only: it never writes or removes anything.
#
# scripts/load-report.sh [FROM [TO]]     days as yyyy-MM-dd; TO defaults to today, FROM to 6 days before TO
#   --home DIR     VibeSwitcher's folder instead of $VIBESWITCHER_HOME, else ~/.vibeswitcher
#
# A freeze counts in the bucket of the minute's sample nearest it (within 2 minutes), else as "unsampled". Then the
# freezes during merge runs per hour, all and by the width each run got (merges' `cores`).
set -euo pipefail

home="${VIBESWITCHER_HOME:-$HOME/.vibeswitcher}"
days=()
while (($#)); do
    case "$1" in
        --home) home="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) days+=("$1"); shift ;;
    esac
done
for day in "${days[@]+"${days[@]}"}"; do
    [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "load-report: '$day' isn't a day (yyyy-MM-dd)" >&2; exit 2; }
done

exec /usr/bin/python3 -I - "$home" "${days[@]+"${days[@]}"}" <<'PY'
import datetime as dt, json, os, re, statistics, sys

home = sys.argv[1]
days = sys.argv[2:]
to = dt.date.fromisoformat(days[1]) if len(days) > 1 else dt.date.today()
start = dt.date.fromisoformat(days[0]) if days else to - dt.timedelta(days=6)
if start > to:
    start, to = to, start
stats, debug = os.path.join(home, "stats"), os.path.join(home, "debug")

def local(stamp):
    """A recorded stamp ("2026-11-01T14:02:00+01:00") as local wall time, no zone."""
    return dt.datetime.fromisoformat(stamp).astimezone().replace(tzinfo=None)

def lines(kind):
    found = []
    day = start
    while day <= to:
        path = os.path.join(stats, f"{kind}-{day.isoformat()}.jsonl")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                for line in f:
                    try:
                        found.append(json.loads(line))
                    except ValueError:
                        pass
        day += dt.timedelta(days=1)
    return found

samples = [s for s in lines("load") if s.get("load")]
for s in samples:
    s["at"] = local(s["t"])
samples.sort(key=lambda s: s["at"])
merges = lines("merges")

hangs = set()
if os.path.isdir(debug):
    for name in os.listdir(debug):
        m = re.fullmatch(r"hang-(\d{8}-\d{6})\.(txt|log)", name)
        if m:
            at = dt.datetime.strptime(m.group(1), "%Y%m%d-%H%M%S")
            if start <= at.date() <= to:
                hangs.add(at)

EDGES = [0, 12, 24, 36, 48, 72, 100, 150]
def bucket(load):
    for low, high in zip(EDGES, EDGES[1:]):
        if load < high:
            return f"{low}-{high}"
    return f"{EDGES[-1]}+"
NAMES = [f"{l}-{h}" for l, h in zip(EDGES, EDGES[1:])] + [f"{EDGES[-1]}+"]

def nearest(at):
    """The sample nearest `at` within 2 minutes, or None (a binary search over the sorted samples)."""
    lo, hi = 0, len(samples)
    while lo < hi:
        mid = (lo + hi) // 2
        if samples[mid]["at"] < at:
            lo = mid + 1
        else:
            hi = mid
    best = None
    for i in (lo - 1, lo):
        if 0 <= i < len(samples):
            gap = abs((samples[i]["at"] - at).total_seconds())
            if gap <= 120 and (best is None or gap < best[0]):
                best = (gap, samples[i])
    return best[1] if best else None

rows = {name: {"minutes": 0, "freezes": 0, "merges": [], "fails": 0} for name in NAMES}
for s in samples:
    rows[bucket(s["load"][0])]["minutes"] += 1
unsampled = 0
for at in hangs:
    s = nearest(at)
    if s is None:
        unsampled += 1
    else:
        rows[bucket(s["load"][0])]["freezes"] += 1
for m in merges:
    if not m.get("load"):
        continue
    row = rows[bucket(m["load"][0])]
    if m.get("first_run"):
        row["merges"].append(m.get("duration_s", 0))
        row["fails"] += m["first_run"] == "failed"

def mins(seconds):
    return f"{seconds / 60:.1f} min"

print(f"Load report {start} .. {to} ({home})")
total = len(samples)
if total == 0:
    print("No load samples in this range.")
else:
    loads = sorted(s["load"][0] for s in samples)
    p90 = loads[min(len(loads) - 1, int(0.9 * len(loads)))]
    cores = samples[-1].get("cores")
    print(f"Samples: {total} minutes ({total / 60:.1f} h); 1-min load median {statistics.median(loads):.1f}, "
          f"p90 {p90:.1f}, max {loads[-1]:.1f}" + (f"; {cores} cores" if cores else ""))
    pressure = {}
    for s in samples:
        level = (s.get("memory") or {}).get("pressure")
        if level:
            pressure[level] = pressure.get(level, 0) + 1
    swap = max(((s.get("memory") or {}).get("swap_used_mb") or 0) for s in samples)
    print("Memory pressure: " + (", ".join(f"{k} {v} min" for k, v in sorted(pressure.items())) or "not recorded")
          + f"; swap used at most {swap} MB")
    sessions = [sum(x.get("n", 0) for x in s.get("sessions", []) if x.get("role") != "lead") for s in samples]
    held = [len(s.get("heavy", {}).get("held", [])) for s in samples]
    print(f"Team sessions (workers and verifiers): median {statistics.median(sessions):g}, max {max(sessions)}; "
          f"heavy slots held: median {statistics.median(held):g}, max {max(held)}")
print()
print(f"{'load':<9}{'minutes':>9}{'share':>8}{'freezes':>9}{'per hour':>10}{'merges':>8}{'suite median':>14}{'1st-run fails':>15}")
for name in NAMES:
    row = rows[name]
    if not row["minutes"] and not row["freezes"] and not row["merges"]:
        continue
    share = f"{100 * row['minutes'] / total:.0f}%" if total else "-"
    rate = f"{row['freezes'] / (row['minutes'] / 60):.2f}" if row["minutes"] else "-"
    suite = mins(statistics.median(row["merges"])) if row["merges"] else "-"
    fails = f"{row['fails']}/{len(row['merges'])}" if row["merges"] else "-"
    print(f"{name:<9}{row['minutes']:>9}{share:>8}{row['freezes']:>9}{rate:>10}{len(row['merges']):>8}{suite:>14}{fails:>15}")
if unsampled:
    print(f"{'unsampled':<9}{'':>9}{'':>8}{unsampled:>9}   (freezes with no load sample within 2 minutes)")

# Freezes while merge runs ran (each run once: a batch's lines share theirs), by the width its run got (`cores`, from
# vs-heavy's line; "-" on lines without it): the check that a wider run on a calm Mac didn't bring more freezes.
runs = {}
for m in merges:
    if not m.get("t") or m.get("duration_s") is None:
        continue
    key = m.get("batch") or (m["t"], m.get("project"), m.get("task"))
    at = local(m["t"])
    runs[key] = (at, at + dt.timedelta(seconds=m["duration_s"]), m.get("cores"))

def during(windows):
    """Minutes the windows cover (overlaps once) and the freezes inside them."""
    covered, end = 0.0, None
    for a, b in sorted((a, b) for a, b, _ in windows):
        if end is not None and a < end:
            a = end
        if b > a:
            covered += (b - a).total_seconds()
            end = b if end is None or b > end else end
    frozen = sum(1 for h in hangs if any(a <= h <= b for a, b, _ in windows))
    return covered / 60, frozen

if runs:
    print()
    def line(name, windows):
        minutes, frozen = during(windows)
        rate = f"{frozen / (minutes / 60):.2f}" if minutes else "-"
        return f"{name}: {len(windows)} runs, {minutes:.0f} min, {frozen} freezes, {rate} per hour"
    print(line("During merge runs", list(runs.values())))
    widths = sorted({w for _, _, w in runs.values()}, key=lambda w: (w is None, w or 0))
    for width in widths:
        print("  " + line(f"width {width if width is not None else '-'}", [r for r in runs.values() if r[2] == width]))

if samples:
    print()
    print("Load by hour of day (1-min load: mean / max, minutes sampled)")
    hours = {}
    for s in samples:
        hours.setdefault(s["at"].hour, []).append(s["load"][0])
    for hour in sorted(hours):
        values = hours[hour]
        print(f"  {hour:02d}:00  {statistics.mean(values):6.1f} / {max(values):6.1f}  ({len(values)})")
    busy = {}
    for s in samples:
        for group in s.get("top") or []:
            key = (group.get("command", "?"), group.get("project") or "-")
            busy[key] = busy.get(key, 0) + 1
    if busy:
        print()
        print(f"Busiest process groups in minutes over load 48 (command, project: minutes named)")
        for (command, project), count in sorted(busy.items(), key=lambda kv: -kv[1])[:10]:
            print(f"  {command:<20} {project:<24} {count}")
PY
