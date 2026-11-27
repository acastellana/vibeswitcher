#!/usr/bin/env python3 -I
"""Where the Mac's load comes from while heavy slots are held: the load recorder's samples by what holds the slots.

Read-only: it opens the recorder's files for reading and writes nothing. Standard library only. A sibling of
scripts/load-gate-backtest.py, whose reading and time weighting it reuses (the same minutes, the same anchor table).

    python3 -I scripts/heavy-slot-load.py                            # every day in ~/.vibeswitcher/stats
    python3 -I scripts/heavy-slot-load.py --until 2026-11-27T11:28   # the data as the load review saw it
    python3 -I scripts/heavy-slot-load.py --stats DIR                # another folder of load-*/merges-*.jsonl
    python3 -I scripts/heavy-slot-load.py --selftest                 # the hand-checked fixture, scripts/fixtures/heavy-slot

The report it feeds: docs/process/reviews/heavy-slot-load-2026-11.md. Another project's name, and any task slug or
folder name, is never printed: other projects are "other-1", "other-2", … by their slot-minutes.

What a holder is (a sample's heavy.held records only a slot's project, task and minutes held, never its command, so
its kind is inferred, and each rule says how):
- merge: no task, and a merge line of the same project (merges-*.jsonl: t is when its slot was taken) spans the
  sample: t - 1 min <= sample <= t + duration_s + 1 min. Merges, audits and reverts all write the repository as their
  place (Worktrees.runChecks, place: root), so no task means one of them, or a run in the main checkout.
- lead-other: no task and no merge spans it: an audit's build and test run, a revert's test, or a run started in the
  main checkout (the lead's, the user's). Above load 48 a top group in an audit-* folder confirms an audit.
- worker: a task: a run in that task's worktree (scripts/test.sh, a load run, build-app.sh, the pre-done check).
  A task slug starting "v2-" is a v2 line's task, whose runs build a nested v2 clone in its worktree (worker-v2).
- load-run (a part of worker or worker-v2): a holder episode (the same slot, project and task, its minutes not going
  back) during which some sample's top groups show test-under-load.sh's signature in that project: test bundles run by
  bash (swiftpm-testing whose group leader is bash: the script starts the bundles itself), or a bash group of 4 or more
  processes using 200 % or more (its busy loops). Only samples over load 48 name top groups, so this is a lower bound.
- other-project: the holder names another project. no-project: the holder names none (an older note).

Over-share load, per sample with n >= 1 slots held: max(0, 1-minute - B - n x share), where B is the mean 1-minute
with no slot held (the Mac's own load, everything else) and share is vs-heavy's floor, ceil(cores / slots), at least
2 (4 on 12 cores with 3 slots). It is split equally among the n holders. A slot's load "beyond its share" is what
this counts: sized jobs alone would keep it at 0.

Phases: the 1-minute load by minutes into the hold (single-holder samples), and above load 48 the top groups' CPU by
command: build (swift-frontend, swift-build, swift-package, swiftc, swift-driver, clang, ld), test (swiftpm-testing,
the host, parsers and MCP server the tests start, git, node, xctest), other of ours (any other group in a project
folder), sessions (Claude Code and the MCP server it runs, whose command or group leader is a version such as
"2.1.327") and not ours (no project folder: the browser, the VM, system daemons).
"""
import argparse
import datetime as dt
import importlib.util
import json
import math
import os
import sys

# The backtest is imported from its file: no __pycache__ beside it.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("load_gate_backtest", os.path.join(HERE, "load-gate-backtest.py"))
backtest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(backtest)

OWN = "vibeswitcher"
KINDS = ("merge", "lead-other", "worker", "worker-v2", "other-project", "no-project")
BUILD = ("swift-frontend", "swift-build", "swift-package", "swiftc", "swift-driver", "clang", "ld", "ld64",
         "swift-autolink-e", "swift-plugin-se")
TEST = ("swiftpm-testing", "xctest", "vibeswitcher-ho", "vibeswitcher-mc", "vibeswitcher-la", "launcher", "git",
        "node", "fake-claude", "xcrun")
MERGE_SLACK_MIN = 1.0


def share_of(cores, slots):
    slots = max(1, slots or 1)
    return max(2, math.ceil((cores or 12) / slots))


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[int(q * (len(values) - 1))]


def wmean(pairs):
    total = sum(w for _, w in pairs)
    return sum(v * w for v, w in pairs) / total if total else float("nan")


def folder_type(project):
    """A top group's project folder as a type: a merge's or an audit's scratch worktree, a batch's, ours, another."""
    if project is None:
        return "none"
    if project == "merge-batch" or project.startswith("merge-batch"):
        return "merge-batch"
    if project.startswith("merge-"):
        return "merge-*"
    if project.startswith("audit-"):
        return "audit-*"
    if project == OWN:
        return "ours (worktree or main checkout)"
    return "other folder"


def is_session(name):
    """A Claude Code process: its command name is its version ("2.1.327")."""
    parts = (name or "").split(".")
    return len(parts) == 3 and all(x.isdigit() for x in parts)


def phase_of(group):
    command = group.get("command") or ""
    # A session's own processes (Claude Code, and the MCP server it runs) aren't a build or a test.
    if is_session(command) or is_session(group.get("leader")):
        return "sessions"
    if command in BUILD:
        return "build"
    if command in TEST or command.startswith("vibeswitcher-") or command.startswith("launcher"):
        return "test"
    if group.get("project"):
        return "other of ours"
    return "not ours"


def is_load_run_signature(group):
    command, leader = group.get("command"), group.get("leader")
    if command == "swiftpm-testing" and leader == "bash":
        return True
    return command == "bash" and (group.get("processes") or 0) >= 4 and (group.get("cpu") or 0) >= 200


class Data:
    """The samples (the backtest's, with their weights) and each one's raw holders, classified."""

    def __init__(self, stats, until=None):
        self.samples = backtest.load_samples(stats, None, 36.0, until=until)
        self.merges = backtest.load_merges(stats, until=until)
        raws = {}
        for raw in backtest.read_jsonl(sorted(__import__("glob").glob(os.path.join(stats, "load-*.jsonl")))):
            if raw.get("t"):
                raws[dt.datetime.fromisoformat(raw["t"])] = raw
        self.holders = []  # per sample: [(kind, holder dict)]
        merges_by_project = {}
        for m in self.merges_all(stats, until):
            merges_by_project.setdefault(m.get("project"), []).append(m)
        for s in self.samples:
            raw = raws.get(s.t, {})
            held = ((raw.get("heavy") or {}).get("held")) or []
            kinds = []
            for h in held:
                kinds.append((self.kind(h, s.t, merges_by_project), h))
            self.holders.append(kinds)
        self.mark_load_runs()
        # Other projects' names, by their slot-minutes, as other-1, other-2, …
        minutes = {}
        for s, kinds in zip(self.samples, self.holders):
            for _, h in kinds:
                p = h.get("project")
                if p and p != OWN:
                    minutes[p] = minutes.get(p, 0) + s.weight
        self.alias = {p: f"other-{i + 1}" for i, p in enumerate(sorted(minutes, key=lambda p: -minutes[p]))}
        zero = [(s.one, s.weight) for s in self.samples if s.known and s.held == 0]
        self.baseline = wmean(zero)

    @staticmethod
    def merges_all(stats, until):
        """Every merge line (a batch's tasks too: each holds no slot of its own, but the batch's run is the same)."""
        out = []
        for raw in backtest.read_jsonl(sorted(__import__("glob").glob(os.path.join(stats, "merges-*.jsonl")))):
            if not raw.get("t"):
                continue
            raw["_t"] = dt.datetime.fromisoformat(raw["t"])
            if until is not None and raw["_t"] > until:
                continue
            out.append(raw)
        return out

    @staticmethod
    def kind(h, t, merges_by_project):
        project, task = h.get("project"), h.get("task")
        if not project:
            return "no-project"
        if project != OWN:
            return "other-project"
        if task:
            return "worker-v2" if task.startswith("v2-") else "worker"
        for m in merges_by_project.get(project, []):
            start = m["_t"] - dt.timedelta(minutes=MERGE_SLACK_MIN)
            end = m["_t"] + dt.timedelta(seconds=int(m.get("duration_s") or 0), minutes=MERGE_SLACK_MIN)
            if start <= t <= end:
                return "merge"
        return "lead-other"

    def episodes(self):
        """(slot, project, task) runs of consecutive samples whose minutes don't go back: one hold each."""
        open_ = {}
        out = []
        for i, kinds in enumerate(self.holders):
            seen = set()
            for kind, h in kinds:
                key = (h.get("slot"), h.get("project"), h.get("task"))
                seen.add(key)
                ep = open_.get(key)
                minutes = h.get("minutes")
                if ep is None or (minutes is not None and ep["last_minutes"] is not None and minutes < ep["last_minutes"]):
                    ep = {"key": key, "kind": kind, "samples": [], "last_minutes": None}
                    out.append(ep)
                    open_[key] = ep
                ep["samples"].append(i)
                ep["last_minutes"] = minutes
            for key in list(open_):
                if key not in seen:
                    del open_[key]
        return out

    def mark_load_runs(self):
        self.load_run = set()  # (sample index, slot) held by a load run
        self.load_run_episodes = []
        for ep in self.episodes():
            if ep["kind"] not in ("worker", "worker-v2"):
                continue
            project = ep["key"][1]
            hit = False
            for i in ep["samples"]:
                workers = [h for k, h in self.holders[i] if k in ("worker", "worker-v2") and h.get("project") == project]
                if len(workers) == 1 and any(is_load_run_signature(g) and g.get("project") == project
                                              for g in self.samples[i].top):
                    hit = True
                    break
            if hit:
                self.load_run_episodes.append(ep)
                for i in ep["samples"]:
                    self.load_run.add((i, ep["key"][0]))

    def kinds_at(self, i, split_load_run=True):
        out = []
        for kind, h in self.holders[i]:
            if split_load_run and (i, h.get("slot")) in self.load_run:
                out.append("load-run")
            else:
                out.append(kind)
        return out

    def over_share(self, i):
        s = self.samples[i]
        n = len(self.holders[i])
        if not s.known or n == 0:
            return 0.0
        return max(0.0, s.one - self.baseline - n * share_of(s.cores, s.slots))


ALL_KINDS = ("merge", "lead-other", "worker", "worker-v2", "load-run", "other-project", "no-project")


def analyse(data):
    """Every figure the report quotes, as a dict (the self-test checks these)."""
    out = {"baseline": data.baseline, "samples": len(data.samples)}
    days = backtest.days_covered(data.samples) if hasattr(backtest, "days_covered") else None
    out["days"] = days
    # The anchor: the load review's table, unweighted as it computed it.
    by = {}
    for s in data.samples:
        if s.known:
            by.setdefault(min(s.held, 3), []).append(s.one)
    out["anchor"] = {k: (sum(v) / len(v), pct(v, 0.9), len(v)) for k, v in sorted(by.items())}
    # Slot-minutes by kind, over-share by kind, single-holder load by kind.
    slot_min = {k: 0.0 for k in ALL_KINDS}
    over = {k: 0.0 for k in ALL_KINDS}
    single = {k: [] for k in ALL_KINDS}
    over_limit_with = {k: 0.0 for k in ALL_KINDS}
    over_limit = 0.0
    over_total = 0.0
    held_minutes = 0.0
    for i, s in enumerate(data.samples):
        kinds = data.kinds_at(i)
        if not kinds:
            continue
        held_minutes += s.weight
        o = data.over_share(i) * s.weight
        over_total += o
        for k in kinds:
            slot_min[k] += s.weight
            over[k] += o / len(kinds)
        if len(kinds) == 1 and s.known:
            single[kinds[0]].append((s.one, s.weight, s.cores, s.slots))
        if s.known and s.one > s.threshold:
            over_limit += s.weight
            for k in set(kinds):
                over_limit_with[k] += s.weight
    out["slot_minutes"] = slot_min
    out["over_share"] = over
    out["over_share_total"] = over_total
    out["held_minutes"] = held_minutes
    out["over_limit_held"] = over_limit
    out["over_limit_with"] = over_limit_with
    out["single"] = {}
    for k, rows in single.items():
        if not rows:
            continue
        ones = [r[0] for r in rows]
        mean = wmean([(r[0], r[1]) for r in rows])
        share = wmean([(share_of(r[2], r[3]), r[1]) for r in rows])
        out["single"][k] = {"minutes": sum(r[1] for r in rows), "mean": mean, "p90": pct(ones, 0.9),
                            "added": mean - data.baseline, "share": share}
    # The same over-share split by each kind's load alone (what it adds over B with no other slot held; a kind never
    # alone takes the mean of all single-holder samples): a kind that loads the Mac alone takes more of a shared excess.
    alone_all = [r for rows in single.values() for r in rows]
    fallback = max(0.1, wmean([(r[0], r[1]) for r in alone_all]) - data.baseline) if alone_all else 1.0
    weight = {k: max(0.1, out["single"][k]["added"]) if k in out["single"] else fallback for k in ALL_KINDS}
    over_w = {k: 0.0 for k in ALL_KINDS}
    for i, s in enumerate(data.samples):
        kinds = data.kinds_at(i)
        if not kinds:
            continue
        o = data.over_share(i) * s.weight
        total_w = sum(weight[k] for k in kinds)
        for k in kinds:
            over_w[k] += o * weight[k] / total_w
    out["over_share_weighted"] = over_w
    # Compositions for 2 and 3 held.
    comp = {}
    for i, s in enumerate(data.samples):
        kinds = data.kinds_at(i)
        if len(kinds) < 2 or not s.known:
            continue
        key = " + ".join(sorted(kinds))
        comp.setdefault(key, []).append((s.one, s.weight))
    out["compositions"] = {k: (wmean(v), pct([x for x, _ in v], 0.9), sum(w for _, w in v)) for k, v in comp.items()}
    # Minutes into the hold, single holder: the build-then-test profile.
    bins = ((0, 2), (3, 5), (6, 10), (11, 20), (21, 40), (41, 10 ** 6))
    prof = {}
    for i, s in enumerate(data.samples):
        if len(data.holders[i]) != 1 or not s.known:
            continue
        kind = data.kinds_at(i)[0]
        minutes = data.holders[i][0][1].get("minutes")
        if minutes is None:
            continue
        for lo, hi in bins:
            if lo <= minutes <= hi:
                prof.setdefault(kind, {}).setdefault((lo, hi), []).append((s.one, s.weight))
    out["profile"] = {k: {b: (wmean(v), sum(w for _, w in v)) for b, v in d.items()} for k, d in prof.items()}
    # Top groups at high load: CPU by phase and by folder type; cores used against the load.
    phase_cpu = {}
    folder_phase = {}
    ratios = []
    outside = {"samples": 0, "minutes": 0.0, "cpu": 0.0, "build_cpu": 0.0}
    outside_by = {}
    with_top = 0
    for i, s in enumerate(data.samples):
        if not s.top:
            continue
        with_top += 1
        total = 0.0
        holder_projects = {h.get("project") for _, h in data.holders[i]}
        merge_held = any(k == "merge" for k, _ in data.holders[i])
        audit_held = any(k == "lead-other" for k, _ in data.holders[i])
        out_cpu = 0.0
        out_build = 0.0
        for g in s.top:
            cpu = float(g.get("cpu") or 0)
            total += cpu
            ph = phase_of(g)
            phase_cpu[ph] = phase_cpu.get(ph, 0.0) + cpu
            ft = folder_type(g.get("project"))
            folder_phase.setdefault(ft, {}).setdefault(ph, 0.0)
            folder_phase[ft][ph] += cpu
            # Ours outside any slot: build or test work in a folder whose project holds no slot now.
            if ph in ("build", "test"):
                p = g.get("project")
                inside = (ft in ("merge-*", "merge-batch") and merge_held) or (ft == "audit-*" and (audit_held or merge_held)) \
                    or (p in holder_projects)
                if not inside:
                    out_cpu += cpu
                    if ph == "build":
                        out_build += cpu
                    key = (g.get("command"), g.get("leader") or "-", ft)
                    outside_by[key] = outside_by.get(key, 0.0) + cpu
        if out_cpu:
            outside["samples"] += 1
            outside["minutes"] += s.weight
            outside["cpu"] += out_cpu
            outside["build_cpu"] += out_build
        ratios.append((s.one, total / 100.0, s.held))
    out["with_top"] = with_top
    out["phase_cpu"] = phase_cpu
    out["folder_phase"] = folder_phase
    out["outside"] = outside
    out["outside_by"] = outside_by
    out["ratios"] = ratios
    # Load runs: episodes, minutes, load while one is held, and the over-limit minutes with one held.
    lr_min = sum(data.samples[i].weight for ep in data.load_run_episodes for i in ep["samples"])
    lr_over = sum(data.samples[i].weight for ep in data.load_run_episodes for i in ep["samples"]
                  if data.samples[i].known and data.samples[i].one > data.samples[i].threshold)
    # Alone: the load run the only holder and the 1-minute over T. Decided by its busy loops: over T, but under it
    # once its target's worth above B (--load 2 x cores, less what the Mac had anyway) is taken out.
    lr_alone = lr_loops = 0.0
    for ep in data.load_run_episodes:
        for i in ep["samples"]:
            s = data.samples[i]
            if not s.known or s.one <= s.threshold:
                continue
            if len(data.holders[i]) == 1:
                lr_alone += s.weight
            if s.one - max(0.0, 2 * s.cores - data.baseline) <= s.threshold:
                lr_loops += s.weight
    out["load_runs"] = {"episodes": len(data.load_run_episodes), "minutes": lr_min, "over_limit": lr_over,
                        "alone_over": lr_alone, "loops_decide": lr_loops}
    # Episodes by kind: count and median length in minutes, the time a hold takes.
    eps = {}
    for ep in data.episodes():
        kind = "load-run" if ep in data.load_run_episodes else ep["kind"]
        length = sum(data.samples[i].weight for i in ep["samples"])
        eps.setdefault(kind, []).append(length)
    out["episodes"] = {k: (len(v), pct(v, 0.5), sum(v)) for k, v in eps.items()}
    # Candidate 1: the baseline rule's refusals (max(1, 5) > T) and what held the Mac then.
    refused = {"all": 0.0, "no_slot": 0.0, "held": 0.0, "held_top": 0.0, "held_top_outside": 0.0,
               "held_one_over": 0.0, "held_over_without_slots": 0.0}
    for i, s in enumerate(data.samples):
        if not s.known or max(s.one, s.five) <= s.threshold:
            continue
        refused["all"] += s.weight
        if not data.holders[i]:
            refused["no_slot"] += s.weight
            continue
        refused["held"] += s.weight
        if s.one > s.threshold:
            refused["held_one_over"] += s.weight
            # Would the 1-minute be under T with every slot's load taken out? B is what remains with no slot.
        if s.top:
            refused["held_top"] += s.weight
            holder_projects = {h.get("project") for _, h in data.holders[i]}
            merge_held = any(k == "merge" for k, _ in data.holders[i])
            for g in s.top:
                ph = phase_of(g)
                ft = folder_type(g.get("project"))
                inside = (ft in ("merge-*", "merge-batch") and merge_held) or (ft == "audit-*") or (g.get("project") in holder_projects)
                if ph in ("build", "test") and not inside:
                    refused["held_top_outside"] += s.weight
                    break
    out["refused"] = refused
    # Merges: duration by the cores their run was given (lines that say), a batch's run once.
    by_cores = {}
    for m in data.merges:
        if m.get("cores") and m.get("_ran"):
            by_cores.setdefault(int(m["cores"]), []).append(int(m.get("duration_s") or 0))
    out["merge_cores"] = {c: (len(v), pct(v, 0.5)) for c, v in sorted(by_cores.items())}
    return out


def report(data, out=sys.stdout):
    a = analyse(data)
    p = lambda *x: print(*x, file=out)
    hours = sum(s.weight for s in data.samples) / 60
    p(f"samples: {a['samples']} covering {hours:.1f} h ({hours / 24:.1f} days of samples); "
      f"B, the mean 1-minute with no slot held: {a['baseline']:.1f}")
    p("anchor, the load review's table (unweighted): the 1-minute by heavy slots held")
    for k, (mean, p90, n) in a["anchor"].items():
        p(f"  {k}{'+' if k == 3 else ''} held: mean {mean:5.1f}, p90 {p90:5.1f}, {n} samples")
    p()
    p(f"slot-minutes by kind ({a['held_minutes']:.0f} min with a slot held; over-share load-minutes "
      f"{a['over_share_total']:.0f}; minutes with a slot held and the 1-minute over T: {a['over_limit_held']:.0f})")
    p(f"  {'kind':14} {'slot-min':>8} {'/day':>6} {'over-share':>10} {'share%':>6} {'by alone':>8} {'share%':>6} {'over-T min':>10}")
    days = hours / 24 or 1
    for k in ALL_KINDS:
        sm = a["slot_minutes"][k]
        if not sm:
            continue
        o = a["over_share"][k]
        ow = a["over_share_weighted"][k]
        p(f"  {k:14} {sm:8.0f} {sm / days:6.0f} {o:10.0f} {100 * o / (a['over_share_total'] or 1):5.0f}% "
          f"{ow:8.0f} {100 * ow / (a['over_share_total'] or 1):5.0f}% {a['over_limit_with'][k]:10.0f}")
    p("  (over-share: max(0, 1-min - B - n x share) x minutes, split equally among the n holders, then split by what")
    p("   each kind adds over B when it holds the only slot (by alone); over-T min: minutes")
    p("   with the 1-minute over the threshold in force while that kind held a slot, each kind present counted)")
    p()
    p("one slot held, by kind: the 1-minute (weighted mean, p90), what it adds over B, and the slot's share")
    for k in ALL_KINDS:
        d = a["single"].get(k)
        if d:
            p(f"  {k:14} {d['minutes']:6.0f} min  mean {d['mean']:5.1f}  p90 {d['p90']:5.1f}  adds {d['added']:5.1f}"
              f"  share {d['share']:.1f}  x{d['added'] / d['share']:.1f} its share")
    p()
    p("two or three held, by kinds (weighted mean 1-minute, p90, minutes), most minutes first")
    for key, (mean, p90, minutes) in sorted(a["compositions"].items(), key=lambda kv: -kv[1][2])[:14]:
        p(f"  {key:44} mean {mean:5.1f}  p90 {p90:5.1f}  {minutes:5.0f} min")
    p()
    p("one slot held: the 1-minute by minutes into the hold (mean, minutes) — the build comes first")
    for kind, d in sorted(a["profile"].items()):
        cells = "  ".join(f"{lo}-{hi if hi < 10 ** 5 else '…'}: {mean:4.1f} ({m:.0f})" for (lo, hi), (mean, m) in sorted(d.items()))
        p(f"  {kind:14} {cells}")
    p()
    p("episodes (one hold each): count, median minutes, total minutes")
    for k, (n, med, tot) in sorted(a["episodes"].items(), key=lambda kv: -kv[1][2]):
        p(f"  {k:14} {n:5d}  median {med:5.1f}  total {tot:6.0f}")
    lr = a["load_runs"]
    p(f"load runs by signature (lower bound: top groups exist only above load 48): {lr['episodes']} holds, "
      f"{lr['minutes']:.0f} min, {lr['over_limit']:.0f} of them with the 1-minute over T, {lr['alone_over']:.0f} of those "
      f"with no other slot held, {lr['loops_decide']:.0f} under T once its busy loops' target above B is taken out")
    p()
    p(f"top groups (samples over load 48: {a['with_top']}): CPU by phase, in cores (summed % / 100, x the samples)")
    tot = sum(a["phase_cpu"].values()) or 1
    for ph, cpu in sorted(a["phase_cpu"].items(), key=lambda kv: -kv[1]):
        p(f"  {ph:14} {cpu / 100:8.0f} core-samples  {100 * cpu / tot:3.0f}%")
    p("  by folder type and phase (core-samples):")
    for ft, d in sorted(a["folder_phase"].items(), key=lambda kv: -sum(kv[1].values())):
        p(f"    {ft:34} " + "  ".join(f"{ph} {cpu / 100:.0f}" for ph, cpu in sorted(d.items(), key=lambda kv: -kv[1])))
    rs = a["ratios"]
    for lo, hi in ((48, 72), (72, 100), (100, 10 ** 6)):
        sel = [r for r in rs if lo < r[0] <= hi]
        if sel:
            p(f"  1-minute {lo}-{hi if hi < 10 ** 5 else '…'}: {len(sel)} samples, the top groups use "
              f"median {pct([r[1] for r in sel], 0.5):.1f} cores (p90 {pct([r[1] for r in sel], 0.9):.1f}) of 12; "
              f"load per core used, median {pct([r[0] / max(r[1], 0.1) for r in sel], 0.5):.0f}")
    o = a["outside"]
    p(f"  ours outside any slot (build or test groups whose folder's project holds no slot): {o['samples']} samples, "
      f"{o['minutes']:.0f} min, {o['cpu'] / 100:.0f} core-samples ({o['build_cpu'] / 100:.0f} of them building); by command, "
      f"group leader and folder type:")
    for (command, leader, ft), cpu in sorted(a["outside_by"].items(), key=lambda kv: -kv[1])[:8]:
        p(f"    {command:16} led by {leader:10} {ft:34} {cpu / 100:5.1f} core-samples")
    p()
    r = a["refused"]
    p(f"the gate's refusals (max(1, 5) > T): {r['all']:.0f} min; no slot held {r['no_slot']:.0f}; a slot held "
      f"{r['held']:.0f} (the 1-minute itself over T at {r['held_one_over']:.0f}); with top groups named "
      f"{r['held_top']:.0f}, of which {r['held_top_outside']:.0f} show build or test work of ours outside the slots")
    p()
    p("merges whose line says their width: count and median minutes by VS_HEAVY_CORES given")
    for c, (n, med) in a["merge_cores"].items():
        p(f"  {c:2d} cores: {n:3d} runs, median {med / 60:5.1f} min")
    return a


def selftest():
    """The fixture, scripts/fixtures/heavy-slot/stats, by hand. 12 cores, 3 slots (share 4), boost (T 36).

    load-2026-01-06.jsonl, 14 samples one a minute from 10:00, each weighing 1 minute (the 1-minute, what holds):
      10:00 4, nothing | 10:01 6, nothing | 10:11 3, nothing | 10:12 7, nothing          -> B = 20 / 4 = 5
      10:02 13 and 10:03 21: no task; the merge line (10:02:00, 120 s) spans 10:01-10:05  -> merge, over-share 4, 12
      10:04 29: the merge and a worker (fix-a)                                             -> 29 - 5 - 8 = 16, 8 each
      10:05 9: the worker                                                                  -> 0
      10:06 60, 10:07 30, 10:08 40: a worker (fix-b) whose 10:06 top shows bundles led by bash and a bash group of 6
            at 900 %: a load run, its whole hold (10:06-10:08)                             -> 51, 21, 31
      10:09 20: no task, outside the merge's window                                        -> lead-other, 11
      10:10 50: lead-other, another project's holder, a v2 task (v2-keeper)                -> 50 - 5 - 12 = 33, 11 each;
            top: swift-frontend 400 % in ours (a slot of ours is held: inside), swift-frontend 300 % in a folder whose
            project holds no slot (outside, building: 3 cores), a 100 % group in no folder (not ours)
      10:13 70 (the 5-minute 70): lead-other                                               -> 61
    Slot-minutes: merge 3, worker 2, load-run 3, lead-other 3, other-project 1, worker-v2 1. Over-share: merge
      4 + 12 + 8 = 24, worker 8, load-run 103, lead-other 11 + 11 + 61 = 83, other-project 11, worker-v2 11: 240.
    Over T with a slot held: 10:06, 10:08, 10:10, 10:13: 4, with a load run 2. The gate (max(1, 5) > 36) refuses the
      same 4, all with a slot held; of the two with top groups, 10:10 shows ours outside the slots: 1.
    One slot held: 8 samples (10:02, 10:03, 10:05-10:09, 10:13); the merge alone averages (13 + 21) / 2 = 17.
    merges-2026-01-06.jsonl: one run at 4 cores, 120 s.
    """
    stats = os.path.join(HERE, "fixtures", "heavy-slot", "stats")
    data = Data(stats)
    with open(os.devnull, "w", encoding="utf-8") as sink:
        a = report(data, out=sink)
    sm, ov = a["slot_minutes"], a["over_share"]
    expected = [
        ("samples", a["samples"], 14),
        ("baseline", a["baseline"], 5.0),
        ("merge slot-min", sm["merge"], 3.0),
        ("worker slot-min", sm["worker"], 2.0),
        ("load-run slot-min", sm["load-run"], 3.0),
        ("lead-other slot-min", sm["lead-other"], 3.0),
        ("other-project slot-min", sm["other-project"], 1.0),
        ("worker-v2 slot-min", sm["worker-v2"], 1.0),
        ("merge over-share", round(ov["merge"], 6), 24.0),
        ("worker over-share", round(ov["worker"], 6), 8.0),
        ("load-run over-share", round(ov["load-run"], 6), 103.0),
        ("lead-other over-share", round(ov["lead-other"], 6), 83.0),
        ("other-project over-share", round(ov["other-project"], 6), 11.0),
        ("worker-v2 over-share", round(ov["worker-v2"], 6), 11.0),
        ("over-share total", round(a["over_share_total"], 6), 240.0),
        ("by-alone split keeps the total", round(sum(a["over_share_weighted"].values()), 6), 240.0),
        # 10:04: merge alone adds 12, the worker 4: 16 splits 12 / 4.
        ("by-alone merge", round(a["over_share_weighted"]["merge"], 6), 4.0 + 12.0 + 12.0),
        ("over-T held", a["over_limit_held"], 4.0),
        ("over-T with load run", a["over_limit_with"]["load-run"], 2.0),
        ("load-run episodes", a["load_runs"]["episodes"], 1),
        # 10:06 (60) and 10:08 (40), alone both; 40 - (24 - 5) = 21 <= 36 is the loops' doing, 60 - 19 = 41 isn't.
        ("load-run alone over T", a["load_runs"]["alone_over"], 2.0),
        ("load-run loops decide", a["load_runs"]["loops_decide"], 1.0),
        ("single merge mean", round(a["single"]["merge"]["mean"], 6), 17.0),
        ("refused", a["refused"]["all"], 4.0),
        ("refused held", a["refused"]["held"], 4.0),
        ("refused with ours outside", a["refused"]["held_top_outside"], 1.0),
        ("outside samples", a["outside"]["samples"], 1),
        ("outside build cores", a["outside"]["build_cpu"] / 100, 3.0),
        ("anchor 1 held", a["anchor"][1][2], 8),
        ("merge widths", a["merge_cores"], {4: (1, 120)}),
        ("others aliased", sorted(data.alias.values()), ["other-1"]),
    ]
    failed = [(name, value, want) for name, value, want in expected if value != want]
    for name, value, want in failed:
        print(f"selftest: {name}: got {value}, want {want}")
    print(f"selftest: {len(expected) - len(failed)} of {len(expected)} checks passed" + ("" if not failed else ", FAILED"))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stats", default=os.path.join(os.path.expanduser("~"), ".vibeswitcher", "stats"))
    parser.add_argument("--until", help="leave out samples and merges after this local time, 2026-11-27T11:28")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    until = dt.datetime.fromisoformat(args.until).astimezone() if args.until else None
    data = Data(args.stats, until=until)
    report(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
