#!/usr/bin/env python3 -I
"""Replay the load recorder's samples against candidate rules for the Mac's load gate.

Read-only: it opens the recorder's files for reading and writes nothing. Standard library only.

    python3 -I scripts/load-gate-backtest.py                 # every day in ~/.vibeswitcher/stats
    python3 -I scripts/load-gate-backtest.py --stats DIR     # another folder of load-*.jsonl / merges-*.jsonl
    python3 -I scripts/load-gate-backtest.py --top           # also the top process groups' evidence
    python3 -I scripts/load-gate-backtest.py --until 2026-11-27T11:28   # the data as the review saw it
    python3 -I scripts/load-gate-backtest.py --selftest      # the hand-checked fixture, scripts/fixtures/load-gate

Inputs (LoadRecorder.swift): load-YYYY-MM-DD.jsonl, one LoadSample about every minute (`load` [1, 5, 15],
`cores`, `boost`, `heavy` {slots, held}, `sessions` by project and role, `memory`, above load 48 `top`), and
merges-YYYY-MM-DD.jsonl beside them, one MergeSample per merge. No project or task name is ever printed.

How it counts (each choice is also the report's, docs/process/reviews/load-gate-2026-11.md):
- Time: each sample stands for the gap to the next one, capped at CAP_MIN minutes, and for 1 minute before a gap
  longer than BREAK_MIN (the Mac asleep or off isn't time anyone waited). A stretch breaks at such a gap.
- Threshold in force: --boost-threshold (36) when the sample says boost, else --threshold (default 2 x cores).
  mac-limits.json isn't read (it's outside stats/): a load_threshold set there isn't seen.
- Refused: the rule says no room. Nobody's refusals are recorded, so this is the time a start would have been
  refused, an upper bound on time actually lost.
- Idle: no worker or verifier session in any project (leads don't count) and no heavy slot held.
- Free: no heavy slot held and the 1-minute load at or under the threshold.
- Overload: the 1-minute load over 2 x the threshold in force: the same line for every row.
- False room (load): the rule says room at a moment and within the next LOOKAHEAD_MIN minutes an overload is
  sampled. A window that crosses a gap over BREAK_MIN is unknown and left out of both counts.
- False room (merge): the rule says room and a merge's tests (ones that ran) start within the next LOOKAHEAD_MIN
  minutes and fail their first run or rerun.
- "new" false room: the moments the baseline refused but the candidate said room: the only moments where a
  candidate takes a risk the baseline didn't. (The replay can't see the load a start it allows would have added.)
- Boot: the first sample after a gap over BREAK_MIN whose swap total is 0 MB while the one before had swap (macOS
  drops its swap files at a restart, not at a sleep); minutes since boot count from that sample.
"""
import argparse
import datetime as dt
import glob
import json
import math
import os
import sys

CAP_MIN = 2.0
BREAK_MIN = 3.0
LOOKAHEAD_MIN = 5.0


# ---------------------------------------------------------------------------------------------------- reading


def read_jsonl(paths):
    rows = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return rows


class Sample:
    __slots__ = ("t", "one", "five", "fifteen", "cores", "boost", "team", "held", "slots", "swap_total",
                 "top", "threshold", "weight", "gap_before", "gap_after", "boot_at", "known")

    def __init__(self, raw, threshold, boost_threshold):
        self.t = dt.datetime.fromisoformat(raw["t"])
        load = raw.get("load") or []
        self.known = len(load) >= 2
        self.one = float(load[0]) if self.known else None
        self.five = float(load[1]) if self.known else None
        self.fifteen = float(load[2]) if len(load) > 2 else None
        self.cores = int(raw.get("cores") or 0)
        self.boost = bool(raw.get("boost"))
        self.team = sum(int(s.get("n") or 0) for s in raw.get("sessions") or [] if s.get("role") != "lead")
        heavy = raw.get("heavy") or {}
        self.held = len(heavy.get("held") or [])
        self.slots = int(heavy.get("slots") or 0)
        self.swap_total = (raw.get("memory") or {}).get("swap_total_mb")
        self.top = raw.get("top") or []
        normal = threshold if threshold is not None else 2.0 * self.cores
        self.threshold = boost_threshold if self.boost else normal
        self.weight = 1.0
        self.gap_before = None
        self.gap_after = None
        self.boot_at = None

    @property
    def idle(self):
        return self.team == 0 and self.held == 0

    @property
    def overload(self):
        return self.known and self.one > 2.0 * self.threshold


def load_samples(stats, threshold, boost_threshold, until=None):
    raws = read_jsonl(sorted(glob.glob(os.path.join(stats, "load-*.jsonl"))))
    samples = [Sample(r, threshold, boost_threshold) for r in raws if r.get("t")]
    if until is not None:
        samples = [s for s in samples if s.t <= until]
    samples.sort(key=lambda s: s.t)
    boot = None
    for i, s in enumerate(samples):
        if i:
            s.gap_before = (s.t - samples[i - 1].t).total_seconds() / 60
            samples[i - 1].gap_after = s.gap_before
            if s.gap_before > BREAK_MIN and s.swap_total == 0 and (samples[i - 1].swap_total or 0) > 0:
                # The restart happened somewhere in the gap; the app's first sample after it is the nearest bound
                # (2026-11-27: the Mac restarted at 11:01, the first sample is 11:04).
                boot = s.t
        s.boot_at = boot
    for s in samples:
        s.weight = 1.0 if s.gap_after is None or s.gap_after > BREAK_MIN else min(s.gap_after, CAP_MIN)
    return samples


def load_merges(stats, until=None):
    """One entry per test run: a batched merge's tasks each have a line sharing the batch's run, kept once (its
    first line; any line's failure counts for the run)."""
    merges = []
    batches = {}
    for raw in read_jsonl(sorted(glob.glob(os.path.join(stats, "merges-*.jsonl")))):
        if not raw.get("t"):
            continue
        raw["_t"] = dt.datetime.fromisoformat(raw["t"])
        if until is not None and raw["_t"] > until:
            continue
        ran = raw.get("first_run") is not None
        raw["_ran"] = ran
        raw["_bad"] = ran and (raw.get("first_run") == "failed" or raw.get("reran") is not None
                               or raw.get("result") in ("failed", "hung"))
        batch = raw.get("batch")
        if batch:
            if batch in batches:
                batches[batch]["_bad"] = batches[batch]["_bad"] or raw["_bad"]
                batches[batch]["_ran"] = batches[batch]["_ran"] or ran
                continue
            batches[batch] = raw
        merges.append(raw)
    merges.sort(key=lambda m: m["_t"])
    return merges


# ---------------------------------------------------------------------------------------------------- rules
# Each rule: (samples, i) -> True (room) or False (refuse). An unreadable load is always a refusal.


def since_boot(s):
    return (s.t - s.boot_at).total_seconds() / 60 if s.boot_at else None


def steady(s):
    return max(s.one, s.five)


def rule_baseline(samples, i):
    s = samples[i]
    return s.known and steady(s) <= s.threshold


def rule_one(samples, i):
    s = samples[i]
    return s.known and s.one <= s.threshold


def recent_ones(samples, i, minutes):
    """The 1-minute loads sampled in the last `minutes` (this one included); None when a gap breaks the window."""
    s = samples[i]
    out = [s.one]
    j = i
    while j > 0:
        prev = samples[j - 1]
        if samples[j].gap_before > BREAK_MIN:
            return None
        if (s.t - prev.t).total_seconds() / 60 > minutes:
            break
        out.append(prev.one)
        j -= 1
    else:
        return None
    return out


def rule_c(boot_minutes):
    def rule(samples, i):
        s = samples[i]
        if not s.known:
            return False
        booted = since_boot(s)
        ignore_five = s.idle or (booted is not None and booted <= boot_minutes)
        return s.one <= s.threshold if ignore_five else steady(s) <= s.threshold
    return rule


def rule_c_guarded(boot_minutes):
    """(cG) As (c), but the boot clause only while no heavy slot is held: our own build can't pause into room."""
    def rule(samples, i):
        s = samples[i]
        if not s.known:
            return False
        booted = since_boot(s)
        ignore_five = s.idle or (s.held == 0 and booted is not None and booted <= boot_minutes)
        return s.one <= s.threshold if ignore_five else steady(s) <= s.threshold
    return rule


def rule_boot_only(boot_minutes):
    def rule(samples, i):
        s = samples[i]
        if not s.known:
            return False
        booted = since_boot(s)
        if booted is not None and booted <= boot_minutes:
            return s.one <= s.threshold
        return steady(s) <= s.threshold
    return rule


def rule_committed(samples, i):
    """(d) The 5-minute counts only while a heavy slot is held: builds and test runs hold one, and they are what
    pauses between phases; workers and audits waiting on the model don't load the Mac."""
    s = samples[i]
    if not s.known:
        return False
    return steady(s) <= s.threshold if s.held else s.one <= s.threshold


def rule_committed_full(samples, i):
    """(d') As (d), and no room while every heavy slot is held (the next build would queue anyway)."""
    s = samples[i]
    return rule_committed(samples, i) and not (s.slots and s.held >= s.slots)


def rule_sustained(minutes, base=None):
    """The 1-minute at or under the threshold at every sample of the last `minutes` (the window unbroken)."""
    def rule(samples, i):
        s = samples[i]
        if not s.known:
            return False
        if base is not None and not base(samples, i):
            return False
        ones = recent_ones(samples, i, minutes)
        return ones is not None and all(o is not None and o <= s.threshold for o in ones)
    return rule


def rule_idle_only(samples, i):
    """(cI) As (c) without the boot clause: the 5-minute ignored only while nothing of ours runs."""
    s = samples[i]
    if not s.known:
        return False
    return s.one <= s.threshold if s.idle else steady(s) <= s.threshold


def rule_calm(held_matters):
    """(g) The 5-minute ignored once the 1-minute has stayed at or under half the threshold for the last 3 minutes:
    a spike that's over, whatever caused it. (h) The same, and only while no heavy slot is held."""
    def rule(samples, i):
        s = samples[i]
        if not s.known:
            return False
        ones = recent_ones(samples, i, 3)
        calm = ones is not None and all(o is not None and o <= s.threshold / 2 for o in ones)
        if held_matters and s.held:
            calm = False
        return s.one <= s.threshold if calm else steady(s) <= s.threshold
    return rule


def fixed_threshold(value):
    def rule(samples, i):
        s = samples[i]
        return s.known and steady(s) <= value
    return rule


RULES = [
    ("a", "max(1,5) <= T  [baseline, today]", rule_baseline),
    ("b", "1-minute only", rule_one),
    ("c15", "(a), 5-min ignored while idle or <=15 min after boot", rule_c(15)),
    ("c30", "(a), 5-min ignored while idle or <=30 min after boot", rule_c(30)),
    ("cG", "(c30), the boot clause only while no slot is held", rule_c_guarded(30)),
    ("cB", "(a), 5-min ignored <=30 min after boot only", rule_boot_only(30)),
    ("d", "(a) while a heavy slot is held, else 1-minute", rule_committed),
    ("d'", "(d), and no room while every slot is held", rule_committed_full),
    ("k3", "1-minute <= T over the last 3 min", rule_sustained(3)),
    ("k5", "1-minute <= T over the last 5 min", rule_sustained(5)),
    ("cI", "(a), 5-min ignored while idle only", rule_idle_only),
    ("g", "(a), 5-min ignored once 1-min <= T/2 for 3 min", rule_calm(False)),
    ("h", "(g), and only while no heavy slot is held", rule_calm(True)),
    ("f24", "max(1,5) <= 24 always (2 x cores)", fixed_threshold(24.0)),
    ("f36", "max(1,5) <= 36 always (3 x cores)", fixed_threshold(36.0)),
]


# ---------------------------------------------------------------------------------------------------- replay


def lookahead(samples, i):
    """'over' if an overload is sampled in the next LOOKAHEAD_MIN minutes, 'clear' if not, None if unknown."""
    s = samples[i]
    end = s.t + dt.timedelta(minutes=LOOKAHEAD_MIN)
    j = i + 1
    while j < len(samples):
        nxt = samples[j]
        if nxt.t > end:
            # Past the window: it was watched if the last sample in it is within CAP_MIN of its end.
            tail = (end - samples[j - 1].t).total_seconds() / 60
            return "clear" if tail <= CAP_MIN else None
        if nxt.gap_before > BREAK_MIN:
            return None
        if nxt.overload:
            return "over"
        j += 1
    return None


def bad_merges_ahead(merges, t):
    end = t + dt.timedelta(minutes=LOOKAHEAD_MIN)
    return [k for k, m in enumerate(merges) if m["_bad"] and t < m["_t"] <= end]


def replay(samples, merges, rule, baseline_room):
    room = [rule(samples, i) for i in range(len(samples))]
    out = {"refused": 0.0, "refused_idle": 0.0, "refused_noteam": 0.0, "refused_free": 0.0, "longest_idle": 0.0,
           "longest_idle_at": None, "given_back": 0.0, "false_load": 0, "false_load_runs": 0, "false_load_new": 0,
           "false_merge": 0, "false_merge_distinct": 0, "false_merge_new": 0, "unknown": 0}
    stretch, stretch_start, prev_false = 0.0, None, False
    merge_hits = set()
    for i, s in enumerate(samples):
        w = s.weight
        if not room[i]:
            out["refused"] += w
            if s.team == 0:
                out["refused_noteam"] += w
            if s.idle:
                out["refused_idle"] += w
            if s.held == 0 and s.known and s.one <= s.threshold:
                out["refused_free"] += w
        elif not baseline_room[i]:
            out["given_back"] += w
        # The longest refused-while-idle stretch, broken by a long gap or a sample that isn't one.
        if not room[i] and s.idle and (stretch == 0 or s.gap_before is None or s.gap_before <= BREAK_MIN):
            if stretch == 0:
                stretch_start = s.t
            stretch += w
        elif not room[i] and s.idle:
            stretch, stretch_start = w, s.t
        else:
            stretch = 0.0
        if stretch > out["longest_idle"]:
            out["longest_idle"], out["longest_idle_at"] = stretch, stretch_start
        # False room.
        is_false = False
        if room[i]:
            ahead = lookahead(samples, i)
            if ahead is None:
                out["unknown"] += 1
            elif ahead == "over":
                is_false = True
                out["false_load"] += 1
                if not baseline_room[i]:
                    out["false_load_new"] += 1
                if not prev_false:
                    out["false_load_runs"] += 1
            hits = bad_merges_ahead(merges, s.t)
            if hits:
                out["false_merge"] += 1
                if not baseline_room[i]:
                    out["false_merge_new"] += 1
                merge_hits.update(hits)
        prev_false = is_false
    out["false_merge_distinct"] = len(merge_hits)
    out["room"] = room
    return out


def merge_waits(samples, merges, room):
    """The merges that waited for the load, and when this rule would have let each go: (waited_s, would_s)."""
    rows = []
    for m in merges:
        waited = int(m.get("waited_s") or 0)
        if waited <= 0:
            continue
        start = m["_t"] - dt.timedelta(seconds=waited + int(m.get("slot_wait_s") or 0))
        would = waited
        for i, s in enumerate(samples):
            if s.t < start:
                continue
            if (s.t - start).total_seconds() > waited:
                break
            if room[i]:
                would = max(0, int((s.t - start).total_seconds()))
                break
        rows.append((waited, would))
    return rows


def days_covered(samples):
    return sum(s.weight for s in samples) / 1440.0


def fmt_min(value):
    return f"{value:.0f}"


def report(stats, threshold, boost_threshold, top, out=sys.stdout, until=None):
    samples = load_samples(stats, threshold, boost_threshold, until)
    merges = load_merges(stats, until)
    if not samples:
        print(f"load-gate-backtest: no load-*.jsonl in {stats}", file=out)
        return None
    days = days_covered(samples)
    first, last = samples[0].t, samples[-1].t
    print(f"samples {len(samples)}, {first:%Y-%m-%d %H:%M} to {last:%Y-%m-%d %H:%M}, covered {days * 24:.1f} h "
          f"({days:.2f} days of samples); merge test runs {len(merges)}, a batch once ({sum(1 for m in merges if m['_ran'])} ran tests, "
          f"{sum(1 for m in merges if m['_bad'])} failed or reran)", file=out)
    print(f"boosted {sum(s.weight for s in samples if s.boost) / 60:.1f} h; overload = 1-minute > 2 x T in force; "
          f"boots seen {len({s.boot_at for s in samples if s.boot_at})}; idle {sum(s.weight for s in samples if s.idle) / 60:.1f} h",
          file=out)
    print(file=out)
    baseline = [rule_baseline(samples, i) for i in range(len(samples))]
    header = (f"{'rule':<5} {'description':<52} {'refused':>8} {'/day':>5} {'idle':>6} {'noteam':>6} {'free':>6} "
              f"{'longest idle':>18} {'back':>6} {'FR load':>8} {'runs':>5} {'new':>4} {'FR merge':>8} {'merges':>6} {'new':>4}")
    print(header, file=out)
    results = {}
    for key, text, rule in RULES:
        r = replay(samples, merges, rule, baseline)
        results[key] = r
        longest = f"{r['longest_idle']:.0f} m" + (f" @{r['longest_idle_at']:%m-%d %H:%M}" if r["longest_idle_at"] and r["longest_idle"] else "")
        print(f"{key:<5} {text:<52} {fmt_min(r['refused']):>8} {r['refused'] / days:>5.0f} {fmt_min(r['refused_idle']):>6} "
              f"{fmt_min(r['refused_noteam']):>6} {fmt_min(r['refused_free']):>6} {longest:>18} {fmt_min(r['given_back']):>6} "
              f"{r['false_load']:>8} {r['false_load_runs']:>5} {r['false_load_new']:>4} {r['false_merge']:>8} "
              f"{r['false_merge_distinct']:>6} {r['false_merge_new']:>4}", file=out)
    print("e     real CPU idle share (host_processor_info ticks): not judgeable, no CPU field is recorded", file=out)
    print(file=out)
    print("columns: minutes refused; per 24 h of samples; refused while idle (no team session, no slot held); refused "
          "with no team session (slots maybe held); refused while free (no slot held, 1-minute <= T); the longest "
          "refused-while-idle stretch; minutes given back vs (a); false room on the load (moments, runs of them, new "
          "vs (a)); false room on merges (moments, distinct merges, new vs (a)). Lookahead windows crossing a gap: "
          f"{results['a']['unknown']} moments of (a) left out.", file=out)
    print(file=out)

    waits = {key: merge_waits(samples, merges, results[key]["room"]) for key, _, _ in RULES}
    total_waited = sum(w for w, _ in waits["a"])
    print(f"merge load waits recorded: {len(waits['a'])} merges, {total_waited} s; replayed release per rule (s): "
          + ", ".join(f"{k} {sum(x for _, x in v)}" for k, v in waits.items()), file=out)

    # Merge first-run failures by the load when its tests started (the merge's own record).
    buckets = [(0, 12), (12, 24), (24, 36), (36, 72), (72, 1e9)]
    line = []
    for lo, hi in buckets:
        ran = [m for m in merges if m["_ran"] and m.get("load") and lo <= max(m["load"][0], m["load"][1]) < hi]
        bad = sum(1 for m in ran if m["_bad"])
        label = f"{lo}-{hi:.0f}" if hi < 1e9 else f"{lo}+"
        line.append(f"{label}: {bad}/{len(ran)}" + (f" ({100 * bad / len(ran):.0f}%)" if ran else ""))
    print("merge first runs failed or rerun, by max(1,5) at their start: " + "; ".join(line), file=out)

    # Overloads that began with the Mac idle 5 minutes before: work outside the team and the slots.
    onsets, idle_onsets = 0, 0
    for i, s in enumerate(samples):
        if s.overload and (i == 0 or not samples[i - 1].overload):
            onsets += 1
            before = [p for p in samples[max(0, i - 6):i] if 0 < (s.t - p.t).total_seconds() / 60 <= LOOKAHEAD_MIN]
            if before and all(p.idle for p in before):
                idle_onsets += 1
    print(f"overload onsets: {onsets}; of them with the Mac idle (no team session, no slot) for the 5 minutes "
          f"before: {idle_onsets}", file=out)

    print_eta(samples, results["a"]["room"], out)
    print_breakdown(samples, results["a"]["room"], out)
    if top:
        print_top(samples, out)
    return {"samples": samples, "merges": merges, "results": results, "waits": waits, "onsets": (onsets, idle_onsets)}


def print_eta(samples, room, out):
    """How well "room again in about N minutes" can be told when (a) refuses on the 5-minute alone: the 5-minute
    decays toward the 1-minute with a 5-minute time constant, so N = 5 ln((five - one) / (T - one))."""
    errors = []
    for i, s in enumerate(samples):
        if room[i] or not s.known or s.one >= s.threshold or s.five <= s.threshold:
            continue
        predicted = 5 * math.log((s.five - s.one) / (s.threshold - s.one))
        for j in range(i + 1, len(samples)):
            if samples[j].gap_before > BREAK_MIN:
                break
            if room[j]:
                errors.append((samples[j].t - s.t).total_seconds() / 60 - predicted)
                break
    if not errors:
        return
    errors.sort()
    n = len(errors)
    within = sum(1 for e in errors if abs(e) <= 2)
    print(f"room-again estimate on (a)'s 5-minute-only refusals: {n} moments, actual minus estimate median "
          f"{errors[n // 2]:+.1f} min, 10th {errors[n // 10]:+.1f}, 90th {errors[9 * n // 10]:+.1f}; within 2 min "
          f"{100 * within / n:.0f}%", file=out)


def print_breakdown(samples, room, out):
    """Where the baseline's refused time goes, day by day, and the load that each committed thing comes with."""
    print(file=out)
    print("(a)'s refused minutes by day: all; with the 1-minute itself over T; with a heavy slot held; with no team "
          "session; and the day's minutes of samples", file=out)
    days = {}
    for i, s in enumerate(samples):
        d = days.setdefault(s.t.strftime("%Y-%m-%d"), [0.0, 0.0, 0.0, 0.0, 0.0])
        d[4] += s.weight
        if room[i]:
            continue
        d[0] += s.weight
        if s.known and s.one > s.threshold:
            d[1] += s.weight
        if s.held:
            d[2] += s.weight
        if s.team == 0:
            d[3] += s.weight
    for day, (refused, one_over, held, noteam, covered) in sorted(days.items()):
        print(f"  {day}  refused {refused:5.0f}  1-min over {one_over:5.0f}  slot held {held:5.0f}  no team {noteam:4.0f}"
              f"  of {covered:5.0f} min sampled", file=out)
    total = sum(v[0] for v in days.values())
    if total:
        print(f"  all days: {total:.0f} min refused, {100 * sum(v[1] for v in days.values()) / total:.0f}% with the "
              f"1-minute over T, {100 * sum(v[2] for v in days.values()) / total:.0f}% with a heavy slot held", file=out)
    print("the 1-minute load by heavy slots held (mean, 90th percentile, minutes sampled):", file=out)
    by = {}
    for s in samples:
        if s.known:
            by.setdefault(min(s.held, 3), []).append(s.one)
    for held, ones in sorted(by.items()):
        ones.sort()
        p90 = ones[int(0.9 * (len(ones) - 1))]
        print(f"  {held}{'+' if held == 3 else ''} held: mean {sum(ones) / len(ones):5.1f}, p90 {p90:5.1f}, {len(ones)} samples",
              file=out)


# ---------------------------------------------------------------------------------------------------- top groups

OURS = ("swift-frontend", "swift-build", "swift-package", "swiftpm-testing", "swift-test", "swiftc", "clang", "ld",
        "xctest", "node", "cargo", "rustc", "python3", "Python", "make", "go", "esbuild", "claude", "git")


def print_top(samples, out):
    with_top = [s for s in samples if s.top]
    print(file=out)
    for boot in sorted({s.boot_at for s in samples if s.boot_at}):
        print(f"after the boot first sampled {boot:%m-%d %H:%M} (team sessions, slots held, top groups' CPU):", file=out)
        for s in samples:
            if s.boot_at == boot and (s.t - boot).total_seconds() <= 20 * 60:
                groups = ", ".join(f"{g.get('command')} {g.get('cpu', 0):.0f}%" for g in s.top) if s.top else "-"
                print(f"  {s.t:%H:%M} load {s.one:.0f}/{s.five:.0f}/{s.fifteen:.0f} team {s.team} held {s.held}  {groups}",
                      file=out)
    print(f"top groups: {len(with_top)} samples name them (1-minute > 48). Their CPU (percent of a core) summed, "
          "a lower bound on use (5 groups at most):", file=out)
    low = [s for s in with_top if sum(g.get("cpu", 0) for g in s.top) / 100 < s.cores / 2]
    print(f"  samples where the top groups use under half the cores: {len(low)} of {len(with_top)}", file=out)
    worst = sorted(with_top, key=lambda s: s.one / max(0.1, sum(g.get('cpu', 0) for g in s.top) / 100), reverse=True)[:8]
    print("  highest load per core used:", file=out)
    for s in worst:
        used = sum(g.get("cpu", 0) for g in s.top) / 100
        print(f"    {s.t:%m-%d %H:%M} 1-min {s.one:.0f} 5-min {s.five:.0f}, top groups {used:.1f} cores, "
              f"team {s.team}, held {s.held}", file=out)
    counts = {}
    for s in with_top:
        for g in s.top:
            if g.get("project"):
                continue
            name = g.get("command", "?")
            if name.startswith(OURS) or (g.get("leader") or "").startswith(OURS):
                continue
            c = counts.setdefault(name, [0, 0.0])
            c[0] += 1
            c[1] = max(c[1], g.get("cpu", 0))
    print("  groups outside any project folder and not a build or test tool, by samples named in (peak % of a core):",
          file=out)
    for name, (n, peak) in sorted(counts.items(), key=lambda kv: -kv[1][0])[:20]:
        print(f"    {name:<18} {n:>4}  peak {peak:.0f}%", file=out)
    ours_cpu = other_cpu = 0.0
    for s in with_top:
        for g in s.top:
            mine = g.get("project") or g.get("command", "").startswith(OURS) or (g.get("leader") or "").startswith(OURS)
            if mine:
                ours_cpu += g.get("cpu", 0)
            else:
                other_cpu += g.get("cpu", 0)
    total = ours_cpu + other_cpu
    if total:
        print(f"  of the named CPU: in a project folder or a build/test tool {100 * ours_cpu / total:.0f}%, "
              f"the rest {100 * other_cpu / total:.0f}%", file=out)


# ---------------------------------------------------------------------------------------------------- self-test


def selftest():
    """The fixture, scripts/fixtures/load-gate/stats, by hand. 12 cores, no boost: T = 24, overload = 1-minute > 48.

    load-2026-01-05.jsonl, 16 samples (time, 1-min, 5-min, team sessions, heavy slots held):
      09:00 10 10 1 1 | 09:01 60 20 1 1 | 09:02 70 40 1 1 | 09:03 20 45 1 1 (the 2026-10-28 dip) | 09:04 80 50 1 1
      09:05 10 40 1 1 | 09:06 8 30 0 0 | 09:07 6 26 0 0 | 09:08 5 22 | 09:09 5 20 | 09:10 5 18 | 09:11 5 16
      -- 29-minute gap, swap 2048 -> 0 MB: a restart, first sampled 09:40 --
      09:40 300 150 0 0 | 09:41 20 100 0 1 (a merge's slot) | 09:42 10 70 0 0 | 09:43 9 20 0 0
    Every sample weighs 1 minute (09:11 and 09:43 too: one stands before a long gap, the other is the last).
    (a) max(1,5) <= 24 refuses 09:01-09:07 (7) and 09:40-09:42 (3): 10. Idle among them: 09:06, 09:07, 09:40, 09:42
        (09:41 holds a slot): 4; the longest idle stretch 09:06-09:07: 2 (09:41 breaks 09:40-09:42).
        False room on the load: 09:00 (09:01 overloads): 1. 09:08 is clear (its window's last sample, 09:11, is
        within 2 minutes of its end); 09:09-09:11 and 09:41-09:43 are unknown (a gap, the end of the file).
    merges-2026-01-05.jsonl: 09:03:30 failed its first run and reran, 09:20 passed.
        (a) has room at 09:00, 3.5 minutes before the failing one: 1 merge false room.
    (b) 1-minute <= 24 refuses 09:01, 09:02, 09:04, 09:40: 4; idle 1 (09:40). False room on the load: 09:00 and 09:03
        (09:04 overloads): 2 moments in 2 runs, 1 new (09:03, which (a) refused). On merges: 09:00 and 09:03, 1 new,
        1 distinct merge.
    (c30) the 5-minute ignored while idle (09:06-09:11, 09:40, 09:42, 09:43) or within 30 minutes of the 09:40 boot:
        refuses 09:01-09:05 (09:03 and 09:05: not idle, the 5-minute 45 and 40 > 24) and 09:40 (300): 6; gives back
        09:06, 09:07, 09:41 (in the boot window, slot or not), 09:42: 4; idle refused 1.
    (cG) the boot clause only while no slot is held: 09:41 is refused too (the 5-minute 100): 7 refused, 3 given back.
    (d) the 5-minute only while a slot is held: the same as (cG) here, 7.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    stats = os.path.join(here, "fixtures", "load-gate", "stats")
    with open(os.devnull, "w", encoding="utf-8") as sink:
        got = report(stats, None, 36.0, False, out=sink)
    a, b, c, d, g = (got["results"][k] for k in ("a", "b", "c30", "d", "cG"))
    expected = [
        ("samples", len(got["samples"]), 16),
        ("a refused", a["refused"], 10.0),
        ("a refused idle", a["refused_idle"], 4.0),
        ("a longest idle", a["longest_idle"], 2.0),
        ("a false load", a["false_load"], 1),
        ("a false merge", a["false_merge"], 1),
        ("b refused", b["refused"], 4.0),
        ("b refused idle", b["refused_idle"], 1.0),
        ("b false load", b["false_load"], 2),
        ("b false load runs", b["false_load_runs"], 2),
        ("b false load new", b["false_load_new"], 1),
        ("b false merge", b["false_merge"], 2),
        ("b false merge new", b["false_merge_new"], 1),
        ("b false merge distinct", b["false_merge_distinct"], 1),
        # (c30): idle moments use the 1-minute; 09:40 (300) still refuses. 09:05 isn't idle: 40 > 24 refuses.
        ("c30 refused", c["refused"], 6.0),
        ("c30 given back", c["given_back"], 4.0),
        ("c30 refused idle", c["refused_idle"], 1.0),
        # (d) and (cG) refuse 09:41 too: a slot is held there, so the 5-minute (100) counts.
        ("d refused", d["refused"], 7.0),
        ("cG refused", g["refused"], 7.0),
        ("cG given back", g["given_back"], 3.0),
        ("boots", len({s.boot_at for s in got["samples"] if s.boot_at}), 1),
    ]
    failed = [(name, value, want) for name, value, want in expected if value != want]
    for name, value, want in failed:
        print(f"selftest: {name}: got {value}, want {want}")
    print(f"selftest: {len(expected) - len(failed)} of {len(expected)} checks passed" + ("" if not failed else ", FAILED"))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stats", default=os.path.join(os.path.expanduser("~"), ".vibeswitcher", "stats"))
    parser.add_argument("--threshold", type=float, default=None, help="the normal load_threshold (default 2 x cores)")
    parser.add_argument("--boost-threshold", type=float, default=36.0)
    parser.add_argument("--top", action="store_true", help="also print the top process groups' evidence")
    parser.add_argument("--until", help="leave out samples and merges after this local time, 2026-11-27T11:28")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    until = dt.datetime.fromisoformat(args.until).astimezone() if args.until else None
    return 0 if report(args.stats, args.threshold, args.boost_threshold, args.top, until=until) is not None else 1


if __name__ == "__main__":
    sys.exit(main())
