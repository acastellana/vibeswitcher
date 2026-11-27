# Why a heavy slot loads the Mac beyond its share of cores, 2026-11

**Top fix 1: test.sh's vs-heavy counts the Mac's 3 slots.** It moves VIBESWITCHER_HOME to a scratch home first, so vs-heavy
counts 2 slots: a worker's run gets 6 cores, not 4, and only slots 1–2. Workers' and v2 runs hold 48% of all slot-minutes,
69% of this project's. **You get:** worker runs at 4 (live: 6 + 6 + 4 = 16 cores on 12), none waiting with slot 3 free.
**Top fix 2: record the load's make-up** (CPU idle, the slots' runnable threads). **You get:** a measured split; today it
is two 3-minute looks at load 27: slots' trees 23–27%, short-lived unattributed 9–11%, outside 64–65% (77% at most).
**What the user was told, checked:** "most of the load is outside any slot" stands weakened: true of the slots' process
trees at load 27, unmeasured in the storms over 48 (70% of the over-share), partly the slots' doing (spawn checks).
"Our jobs mostly stay inside their width" stands weakened: long-lived processes do; a cold build could reach 7.2 on 4.

Written by a worker (task why-a-heavy-slot) on 2026-11-27. Reproduce the numbers with
`python3 -I scripts/heavy-slot-load.py --until 2026-11-27T11:28`, the data the load review saw
([the script](../../../scripts/heavy-slot-load.py), a sibling of
[the load gate backtest](../../../scripts/load-gate-backtest.py), whose reading and minutes it reuses). Its arithmetic
is checked on a hand-made fixture ([scripts/fixtures/heavy-slot](../../../scripts/fixtures/heavy-slot)) by
`python3 -I scripts/heavy-slot-load.py --selftest`. The review it follows: [the load gate](load-gate-2026-11.md).

## The answer in one paragraph

Whether a slot's own processes stay inside its width is not established. Measured with `ps`, the long-lived processes
of a cold build at VS_HEAVY_CORES 4 ran 2.8 runnable threads on average (at most 5), and those of a full suite's test
phase 1.2 (at most 12), because the tests wait on their subprocesses. But that sampler left processes born between its
two `ps` calls unattributed, 3.2–4.4 runnable threads at the Mac's level, and some of them are the runs' own children:
counted to the run, the build could reach 7.2 on width 4 and the test phase 5.6. Run 3's sampler counts them, but its
build was warm (0.2 min) and its tests a 1-minute filter run (1.0 runnable at width 6). Three things push the Mac past
the slots' shares. (1) **Load outside the slots' process trees:** in two live looks with all three slots held, the
holders' trees held 7.2 of 26.6 and 7.8 of 33.2 runnable threads (23–27%), short-lived processes no tree could claim
2.4 and 3.7 (9–11%), and the rest, 64–65%, ran outside the trees: 64–77% if none or all of the short-lived are outside.
Part of that rest follows the slots' work (the system checking their spawns), and both looks were at load 27, not in
the storms over 48. (2) **Slots wider than their share:** a worker's run gets 6 cores because of the scratch home
(fix 2a), and vs-heavy widens the first run to every free core. Neither leaves room for the Mac's own load (4.6 with no
slot held). Live: 6 + 6 + 4 = 16 cores given on 12. (3) **Saturation:** once demand passes 12 cores the CPU is 0–8% idle,
threads queue, and the 1-minute load grows faster than the work. The samples show it: 9.7 with one slot held, 19.9 with
two, 44.6 with three. At the loads looked at it is real contention, not a count of idle waiters: `ps`'s runnable threads
were close to the load in two of the three busy looks (26.6 against 27.1; 31.6 against 31.9) and above it in the third
(33.2 against 27.8). By kind of holder, **workers' runs account for the largest share of the over-share load**: 37–42%, then merges
at 26–32%, then the v2 clones' runs at 20–22%. Per minute held, load runs are the heaviest, at 7 × their share.

## What was measured

- **Samples:** ~/.vibeswitcher/stats/load-2026-11-14 to 11-27 (to 11:28), 14,364 samples, 239.9 hours, 10.0 days of
  samples. merges-*.jsonl beside them. The anchor reproduces the load review's table exactly: the 1-minute averages 4.5
  with no slot held, 9.7 with one, 19.9 with two and 44.6 with three (p90 101.2). The gate's baseline rule refused 1,158
  minutes. B, the mean 1-minute with no slot held, is 4.6.
- **What a holder is.** A sample records a slot's project, task and minutes held, never its command (LoadRecorder.swift:
  "never its command"), so its kind is inferred. Each rule, and how sure it is:
  - **merge:** no task, and one of our merge lines spans the sample (its `t` is when the slot was taken; ±1 minute).
    Merges, audits and reverts all write the repository as their place (`Worktrees.runChecks`, `place: root`). Our 114
    merge runs sum to 2,885 minutes (a one-off query, not printed by the script) and the holds classed as merge to 2,287. The gap is sleep and sample gaps inside
    runs, so audits aren't hiding there.
  - **lead-other:** no task and no merge spans it: an audit's run, a revert's, or a run in the main checkout. 151 minutes.
  - **worker:** a task's worktree. This covers a worker's own runs (scripts/test.sh focused or full, build-app.sh), a
    verifier's runs in that worktree, and the pre-done check (`place: worktree`). The holder alone can't tell them apart.
  - **worker-v2:** a task whose slug starts "v2-". Its runs build a nested v2 clone inside the task's worktree
    (worktrees/<task>/.vibeswitcher/<clone>, as the lead defined it). The holder names the task, not the clone.
  - **load-run:** a worker hold whose top groups show scripts/test-under-load.sh's signature: test bundles led by bash,
    or a bash group of 4 or more using 200% or more. Top groups exist only above load 48, so this is a lower bound.
  - **other-project:** another project's holder; its name is never printed. The recorded names `checkout`, `clone` and
    `repo` can't be mapped to a folder from the samples, so their slot time (part of other-project and no-project) is
    unattributable.
- **Over-share load**, per sample with n slots held: max(0, 1-minute − B − n × share). Share is vs-heavy's floor,
  ceil(cores ÷ slots), at least 2 (4 on 12 cores with 3 slots). It is split equally among the holders, and again in
  proportion to what each kind adds over B when it holds the only slot ("by alone"). Sized jobs alone would keep it at 0.
- **Observed runs:** two under vs-heavy on main's code in this worktree, and one bare `bash scripts/test.sh`, the way a
  worker runs it. A first launch failed at once with exit 127 (vs-heavy wasn't on this shell's PATH) and ran nothing,
  so it isn't counted. A separate shell sampled `ps` every 3 seconds: thread states from `ps -AM`, the run's process
  tree, the other holders' trees by their .holder notes, new processes, and `iostat`'s CPU idle beside it. No other
  tool looked at any process. **The contract's calm Mac wasn't met for runs 1 and 2:** two other slots were held
  throughout, and the CPU was 0–25% idle; all three runs allowed are spent. Runs 1 and 2's sampler read the run's tree
  and the thread states in two `ps` calls, so their counts (2.8, 1.2) leave out the run's children born between the two
  calls: they are lower bounds on the run's runnable threads, not upper ones, and with every unattributed thread counted
  to the run they reach 7.2 and 5.6 (see "the observed runs"). Their durations (384 s, 914 s) are a busy Mac's. Run 3's
  build and tests ran on a calmer Mac (load 4–6, CPU 33–64% idle) with a sampler that counts short-lived children, but
  it covers neither a cold build nor a full suite. **What rests on the busy-Mac runs:** the builds' and full suite's
  runnable counts, the durations, and cause 4's 5.5 minutes per cold build. A calm-Mac cold build and full suite with
  run 3's sampler would settle the width question and give the true durations, and so the minutes fixes 4 and 5 save.
  The lead waived it (2026-11-27): it would itself be 15 minutes of the load under study.
- **Passive looks:** two looks of 3 minutes each, with no run of mine. They sampled the three live holders' trees the
  same way: test.sh at 6 cores, a v2 clone's test.sh at 6, and a load run at 4.

## Where the load comes from, by what holds the slots

Over the 10 days, 7,391 minutes had a slot held and 68,617 load-minutes were over the shares. 817 minutes had a slot
held and the 1-minute over the threshold in force. Slot-minutes count once per holder (a minute with two slots held is
two slot-minutes), so the Slot-min column sums to 11,751, of which 8,186 are this project's (merge, lead-other, worker,
worker-v2, load-run); the script prints both.

| Holder | Slot-min | /day | Over-share, equal split | By alone | Minutes over T while held |
| --- | ---: | ---: | ---: | ---: | ---: |
| worker | 4,206 | 421 | 28,683 (42%) | 25,143 (37%) | 599 |
| merge | 2,292 | 229 | 18,107 (26%) | 22,050 (32%) | 438 |
| worker-v2 | 1,463 | 146 | 13,460 (20%) | 14,789 (22%) | 206 |
| other-project | 3,199 | 320 | 5,729 (8%) | 3,543 (5%) | 119 |
| load-run (lower bound) | 73 | 7 | 2,074 (3%) | 2,847 (4%) | 45 |
| no-project | 366 | 37 | 385 (1%) | 69 (0%) | 10 |
| lead-other | 151 | 15 | 179 (0%) | 175 (0%) | 3 |

**One slot held**, the cleanest view: what the Mac's 1-minute adds over B with that holder alone.

| Holder alone | Minutes | Mean | p90 | Adds over B | × its share |
| --- | ---: | ---: | ---: | ---: | ---: |
| load-run | 28 | 33.6 | 57.4 | 29.0 | 7.0 |
| merge | 786 | 15.6 | 19.3 | 11.0 | 2.5 |
| worker-v2 | 352 | 14.3 | 21.0 | 9.7 | 2.3 |
| worker | 853 | 10.1 | 18.5 | 5.6 | 1.3 |
| lead-other | 89 | 8.2 | 11.8 | 3.6 | 0.9 |
| other-project | 1,819 | 6.3 | 9.7 | 1.7 | 0.4 |

**Two and three held add up to more than their parts.** A merge alone adds 11.0 and a worker alone 5.6. Together they
average 21.3, close to the sum: 4.6 + 11.0 + 5.6. A merge with two workers averages **47.0** (p90 101.5, 305 minutes)
against a sum of 26.8. Three workers average 42.5, and a worker with two v2 runs 52.5. The typical minute shows the same
shape: the median 1-minute is 3.5 with no slot held, 6.0 with one, 11.7 with two and 27.6 with three. **But the excess
is concentrated:** 70% of the 68,617 over-share load-minutes come from the 562 samples over load 48 (4% of the samples),
43% from those over 100, and two days carry 53% (11-26: 18,803; 11-18: 17,716). So the holder ranking above says who
held slots during those storms more than who loads a typical minute. That the third slot tips the Mac into saturation
is a hypothesis the medians support; it is measured only at loads up to 33 (the live looks below).

**No phase of a merge's own run is the culprit.** Over all merge-alone samples, minutes 0–10 of a hold average 8.5–10.8
and minutes 11–40 average 22–43. But that mixes holds: the merges still running at minute 11 are the slow ones, on a
busy Mac. Compared with itself, each of the 12 merge holds held alone for 15 minutes or more has a median of 8.9 at
minutes 0–5 and 7.1 at minutes 11–20 (the script prints both). Two holds carry the averages (213 and 45 at minutes
11–20, a one-off query). The test phase
doesn't load the Mac; the run's neighbours do.

**The process groups on top at the high-load samples** (over load 48, by command, core-samples summed, then how many
samples name it): swift-frontend 599 (360), swiftpm-testing 482 (481), Chrome ("Google") 204 (372), Python 114 (113),
swift-package 92 (174), Docker's VM 72 (236), sessions' MCP servers 59 (196), CleanMyMac 74 (147), another IDE 45 (64),
games 48 (36). By phase: build 35%, test 26%, not ours 27%, other of ours 8%, sessions 4%. By folder: our worktrees and
main checkout build 569 and test 373; merge worktrees test 91 and build 54; audit worktrees 8.

**Above load 48 the recorder sees only a fraction.** At the 562 samples that name top groups, those groups use a median
of 2.7–3.4 cores, while the load is 48–248. With 3 slots held, the named CPU is 2.5 cores of build and test work inside
slots, 0.1 in a folder whose project held no slot, 0.1 sessions, 0.2 other of ours and 0.8 not ours, against a mean load of 99.9. The rest of
the load is in processes the recorder can't name:
- other users' (root) processes: `LoadRecorder.processes` skips a pid whose `proc_pidinfo(PROC_PIDTASKALLINFO)` fails,
  and Spotlight's mds_stores, logd and syspolicyd are root's;
- processes that start and exit between two looks: the tests' git and sh;
- groups past the top 5.

So the samples can rank holders by the load that comes *with* them. They can't say how much of that load their own
processes make. The live looks below can.

## The live looks: load is runnable threads, and most of them ran outside the slots' process trees

| Look | Load 1-min | Mac runnable (ps) | CPU idle | Holders' trees runnable (width) | Unattributed: short-lived | Outside the holders' trees (the Mac's less the trees and the short-lived), and its biggest named parts |
| --- | ---: | ---: | ---: | --- | ---: | --- |
| passive, 3 holders, 3 min | 27.1 | 26.6 (p90 74) | 25% | test.sh 2.3 (6), v2 test.sh 3.4 (6), load run 1.5 (4): 7.2 (27%) | 2.4 (9%) | 17.0 (64%; 73% with the short-lived): beam.smp 9.0, Spotlight (mds_stores + mds) 2.7, claude 0.7, logd 0.6 |
| passive, 3 holders, 2.9 min | 27.8 | 33.2 (p90 61) | 1% | v2 test.sh 4.0 (6), run 2 0.9 (4), test.sh 2.9 (6): 7.8 (23%) | 3.7 (11%) | 21.7 (65%; 77% with the short-lived): beam.smp 7.6, Spotlight 4.4, another project's esbuild 1.1, logd 0.9 |
| run 2's test phase, 14.7 min | 31.9 | 31.6 (max 114) | 8% | run 2 1.2 (4); the other holders not split | 3.6 | the rest, other slots included: beam.smp 7.6, swift-frontend 2.8, Spotlight 3.5 |

- **How to read the split.** The short-lived column is processes no tree could claim (see the last bullet): some are
  the slots' own children, some not. So the holders' trees held 23–27% of the runnable threads for certain, and
  outside them ran 64–65% for certain, 73–77% if every short-lived one was outside. "Outside the trees" isn't "not
  caused by the slots": the system checking the tests' new processes (syspolicyd, XProtect, tccd: 0.2–0.9 runnable each
  in run 3's looks) runs outside them, and Spotlight may be indexing the builds' output (below). What ran outside and
  plainly owes nothing to the slots is another project's VM, beam.smp: 7.6–9.0 runnable, 23–34%. Both looks were at
  load 27, all three slots held; none caught the storms over load 48, which carry 70% of the over-share.
- **The load average is the runnable threads, and at these loads (up to 33) it is real contention.** Above 48 it is
  unmeasured: no live look caught one. `ps`'s count of runnable threads was close to the 1-minute load in the first
  passive look (26.6 against 27.1) and run 2's test phase (31.6 against 31.9), above it in the second (33.2 against
  27.8: `ps` counts the moment, the load averages a minute), and below it in run 3 (4.1 against 6.2, a calm Mac); the
  CPU was 0–25% idle in the three busy looks. A thread in an uninterruptible wait (ps
  state U) averaged 0.0–0.3. So at these loads the number isn't inflated by threads sleeping on disk. The load review's
  restart, where the load was high on idle cores, is the exception: there the count overstates.
- **beam.smp** is another project's Erlang VM, and it held no slot. It is today's largest single source. In the 10 days
  of samples it is named only 3 times, so it ranks as an instance of "outside any slot", not as a cause of its own.
- **Spotlight** (mds_stores, mds, corespotlightd) had 2.7–4.4 runnable threads in every look, while builds wrote their
  .build folders. That it indexes our build output is plausible and unverified: no tool may look at what it reads.
- **"Short-lived"** is processes born between two `ps` calls (the first sampler took membership and states in separate
  calls), so no tree could claim them: the tests' children and anyone else's alike. The one-snapshot sampler of run 3
  counts them into their trees: see run 3.

## Following VS_HEAVY_CORES: configured width, what runs, whether it honours the share

| Step | Where | Configured width | What actually runs (measured) | Honours the share? |
| --- | --- | --- | --- | --- |
| vs-heavy's width | Resources/bin/vs-heavy `give_width` | the cores free at start (12 − 1-minute − other slots' widths), at least the share (ceil(12 / slots) = 4) | merges: 70 of 114 lines at 4; 44 at 5–10. Live: 6, 6, 4 | **No, in two ways.** (a) It widens to every free core when it starts, and later runs get only the floor: the sum isn't held to 12. (b) No room is kept for the Mac's own load (B 4.6) |
| scripts/test.sh's own vs-heavy | scripts/test.sh:298 exports VIBESWITCHER_HOME to the scratch home, then :323 calls Resources/bin/vs-heavy | vs-heavy reads mac-limits.json and boost.json from VIBESWITCHER_HOME: neither is there, so slots = cores ÷ 6 = 2, share 6, and it takes only slots 1–2 | probe (a scratch lock folder, a fake load): scratch home "VS_HEAVY_CORES 6 … 0 of the other 1 slot held", real home 4. Run 3, bare: "waiting … (all 2 slots held)" while slot 3 was free | **No:** 6 instead of 4 for every worker, verifier and v2 run, and a queue that ignores slot 3. Merges (TestLock in the app, 3 slots) and `vs-heavy bash scripts/test.sh` wrapped on the real home get 4 |
| swift build / swift test | scripts/lib/swift-jobs.sh `heavy_swift` | `-j 2 -Xswiftc -j$(( (W + 1) / 2 ))`: 2 modules × W/2 frontends ≈ W | run 1, cold build at W 4: its long-lived processes 2.8 runnable on average, at most 5; processes 12, at most 14; its short-lived children not counted (with the Mac's unattributed 3.2–4.4, up to 7.2). Run 3's link at W 6: ld 2.2 runnable on average, at most 11 at one look | Likely for the compiles (2 × W/2 frontends), not established by the count. The linker isn't sized by `-j`: briefly, it takes what is free |
| Swift Testing's width | scripts/test.sh `slot_width`; `tests_per_core` 1 (the 2026-11-18 18:53 decision kept 1; the 09:57 one allowed 2 × W) | W × 1 tests at once | run 2, full suite at W 4: long-lived processes 1.2 runnable on average (at most 12), short-lived children not counted (up to 5.6 with the Mac's unattributed); processes 15 (at most 140); 111 new processes a minute; the run's %CPU 78. Run 1's 15 lint suites at W 4: 3.1 (at most 4), CPU-bound file scans. Run 3, children counted: 1.0 at W 6, a 1-minute filter run | Not established for a full suite: its long-lived part uses far less than W, its children weren't counted. CPU-bound suites such as the lints fill W. The 2026-11-18 numbers (1009 s at 4, 680 s at 6) with the test process at 1–35% CPU point to waiting |
| The tests' subprocesses | hosts, parsers, git, fake Claude, zsh, xcrun | not sized: each test starts its own | run 2: 111 new processes a minute, up to 140 alive at once. Run 3: 202 a minute, 911 at its end | **Not measured for runs 1 and 2:** those born between the sampler's two calls went unattributed. Run 3 counted them (1.0 on average at W 6, 1 minute). Their spawns' cost lands outside the tree, in syspolicyd, XProtect and tccd |
| Web and security tests | scripts/test.sh `run_web_tests`, after the slot is let go | one node at a time | run 2: 0.5 runnable | Outside the slot, but tiny |
| scripts/test-under-load.sh | :64 sets each run's Swift Testing width to the cores (12) for 3 runs; its busy loops fill the load to --load (2 × cores = 24) | its build uses VS_HEAVY_CORES; its tests use 3 × 12 = 36 wide; its loops make up to 24 runnable by design | live: the load run's tree 1.5 runnable while the Mac was over 24 (its loops stood down, as designed) | **No, by design:** it adds load up to 24 whatever its share. Its tests ignore VS_HEAVY_CORES |
| Module-cache rebuilds | the Clang module cache (SwiftPM's in .build; SourceKit-LSP keeps its own) | inherits whatever starts it: inside a slot, the build's width; from SourceKit-LSP or a bare build, none | **not measured**: no sample, look or run separates a module-cache rebuild from the compile around it, and `ps` shows only swift-frontend and clang | Not measured |
| worktree-init.sh | scripts/worktree-init.sh | builds nothing: it writes .sourcekit-lsp/config.json and exits | — | Not a load |
| Outside slots: SourceKit-LSP and bare builds | sessions | — | top groups: swift-frontend groups leading themselves in no project folder, 24.8 core-samples in 10 days; swift-frontend in ours with no slot held, 5.5; swift-package led by zsh (a session's bare command), 0.9 | Small where it can be seen: 54 of the 562 named samples show build or test work (any project's) in a folder whose project held no slot. A bare build in one of our worktrees beside a slot of ours can't be seen (it reads as our project) |

## The causes, ranked by the load they account for, and the fixes

Each fix is written to become a task. "Expected load" says what should change. None of it was tried: this task changes
no code. Cause 1 accounts for the most load in the two live looks (64–77% outside the slots' trees, part of it caused by the slots), but the samples can't size any of its fixes, so its first fix is to record
it (top fix 2). Fix 2a removes the most load that is certain, at the least cost (top fix 1).

| Fix | Load removed | Run-time cost |
| --- | --- | --- |
| 2a test.sh counts the Mac's slots (top fix 1) | a worker's floor 6 → 4: about 1.4 runnable threads less on average (2 at peak) per overlapping worker build, from the build's long-lived processes; Σ floors 16–18 → 12 | worker builds and test phases at 4, not 6 (test phase about 1009 s against 680 s) until fix 5 |
| 1a record `cpu_idle` and `slot_runnable` (top fix 2) | none directly; sizes cause 1 (64–77% outside the trees in the live looks) | two host calls a minute |
| 1b name a heavy job outside the slots | today's beam.smp 7.6–9.0 → one share (4); over 10 days not measurable | none |
| 1c Spotlight exclusion (experiment) | 2.7–4.4 runnable while builds run, if the cause is ours: not measured | Spotlight doesn't find worktree files |
| 2c leave room for the Mac's own load | estimate: three-held load toward the two-held curve; not measurable until 1a | builds at 3 cores, about a third longer |
| 4a/4b builds start from main's / the line's .build (B9) | estimate: about 100–150 slot-minutes a day, if each task, merge run and audit builds cold once (assumed, not measured) | an experiment first; free on APFS |
| 3 a load run's suites at its slot's width | small: its suites mostly wait | its suites slower |
| 5 tests at 2 a core | CPU change not established (the children weren't counted); holds a third to a half shorter | the SIGPIPE flake until its task lands |
| 2b stop widening | not recommended now: holds the sum to 12 | widened runs at 4 cores; how much longer is not measured |

### 1. Load outside the slots' process trees (the largest share in the live looks: 64–77% of the runnable threads)

- **Evidence:** the two passive looks above. The slot holders' trees held 7.2 of 26.6 and 7.8 of 33.2 runnable
  threads (23–27%); 2.4 and 3.7 were short-lived and unattributed (9–11%); 64–65% ran outside the trees: another
  project's VM (23–34%), Spotlight, sessions, logd. Part of the outside follows the slots' work: the spawn checks (run
  3), and Spotlight if it indexes the builds. Two 3-minute looks at load 27; the storms over 48 weren't looked at. The
  10-day samples can't split it (see "the recorder sees only a fraction").
- **Fix 1a, record it (top fix 2), task "record the load's make-up".** LoadRecorder.swift's `LoadSample` gets two
  fields:
  - `cpu_idle`: the host's idle share since the last sample, from `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas
    (the load review's missing field);
  - `slot_runnable`: the runnable threads in the slot holders' process trees, the holders' pids from the .holder notes.
    They are our own processes, readable with `proc_pidinfo(PROC_PIDTASKINFO)`'s `pti_numrunning`; no other process is
    inspected.

  "Outside" is then the load less `slot_runnable`, every minute. Extend scripts/heavy-slot-load.py to split by it.
  - Expected load after: none removed. It names the part to remove, and it tells a gate refusing on contention (CPU
    idle near 0) from one refusing on a count (the restart).
  - Cost: two host calls a minute, about 0.1 ms each, plus walking the holders' trees (about 20 processes).
- **Fix 1b, task "a heavy job with no slot is named".** When the recorder's top groups show a group in a project
  folder, whatever its command (a compiler, a test runner, a VM such as beam.smp), using 200% or more for 3 samples
  while that project holds no slot, the Team view's load line and the lead's status say so: "another project runs a
  heavy job outside the slots". It can't see one of our own worktrees: they all read as our project's name.
  Every project's policy already asks for vs-heavy.
  - Expected load after: what that project's jobs then take through a slot, up to one share each (today's beam.smp:
    7.6–9.0 runnable on average in the looks, 21 at one moment, down to one share, 4).
  - Cost: none in run time.
- **Fix 1c, an experiment, not a task yet: Spotlight.** Add the main checkout's .vibeswitcher folder (worktrees and
  scratch) to System Settings › Spotlight › Search Privacy. That is the user's click. Then compare mds_stores and mds's
  runnable threads during a cold build, before and after.
  - Expected: 2.7–4.4 runnable threads less while builds run, if our .build folders are what it indexes.
  - Cost: Spotlight no longer finds files in worktrees.

### 2. Slots wider than their share (16 cores of work given on 12 in the live look)

- **Evidence:** the probe and run 3. A bare scripts/test.sh counts 2 slots and gets 6 cores, and holds only slots 1–2.
  Workers' and v2 runs hold 5,669 of the 11,751 slot-minutes (48%), 69% of this project's 8,186 (70% with the load
  runs, which are workers' too). The live .cores notes read 6, 6 and 4.
  Separately, give_width widens a run to every free core: 44 of 114 merges were given 5–10 cores. A run given 10
  on a calm Mac keeps 10 when two more start beside it.
- **Fix 2a (top fix 1), task "test.sh counts the Mac's slots".** In scripts/test.sh, work out the real VibeSwitcher
  folder before line 298 moves the homes, as vs-heavy does (`${VIBESWITCHER_HOME:-$HOME/.vibeswitcher}`; in a session
  VIBESWITCHER_HOME is usually unset, so passing it as it was isn't enough), and give that to the vs-heavy call only, so
  it reads mac-limits.json and boost.json; the command inside still gets the scratch home. vs-heavy's own `give_width`
  comment already says "under a merge's or test.sh's scratch HOME, Settings' and boost's counts aren't read here (the
  cores ÷ 6)". TestScriptWidthTests pins the width with VIBESWITCHER_HEAVY_SLOTS=3 set, which sessions don't have, so
  it can't see this. scripts/build-app.sh needs no change: it calls vs-heavy (:121) on the caller's home, so vs-heavy
  reads the real settings there. scripts/test-under-load.sh already execs vs-heavy before it moves HOME.
  - Test: TestScriptWidthTests on a scratch home whose boost.json gives 3 slots: the run gets 4 and can take slot 3.
  - Expected load after: the floor at three slots is 4 + 4 + 4 = 12, not 16 (6 + 6 + 4) or 18 (6 + 6 + 6). Widening
    stays (fix 2b): a run that starts on a calm Mac still takes every free core and keeps them, so 12 is the floor's
    sum, not a cap. A build's long-lived runnable threads follow its width (2.8 on average at 4, measured without its
    short-lived children), so each worker build overlapping others runs about a third fewer: about 1.4 on average, 2 at
    its peak.
  - Cost: a worker's build at 4 cores instead of 6 while other slots are held. A full suite's test phase at width 4,
    not 6: about 1009 s instead of 680 s (2026-11-18). Fix 5 gives that back.
  - Gained: no worker run waits in line while slot 3 is free (run 3 waited "all 2 slots held", 3rd in line behind two
    other bare test.sh runs). In the samples, slots 1 and 2 were held and slot 3 free for 1,564 of the 12,250 minutes
    with 3 slots in force: an upper bound on that wait. Workers did hold slot 3 for 550 minutes, through runs wrapped in
    vs-heavy on the real home and load runs.
  - What it changes besides, a risk: slot 3 fills more often, so more minutes have three slots held, which is where
    the Mac saturates today. The floors add up to the 12 that two bare runs hold today (6 + 6), but part of the load
    follows the number of jobs, not their width: each job's spawns and the system daemons checking them (run 3). So
    a third job at 4 may cost more than the 4 it is given. Watch the three-held minutes with fix 1a's fields after it
    lands; fix 2c is the lever if they rise.
- **Fix 2b, not recommended now: stop widening.** give_width can't narrow a widened run when others start beside it.
  So the only way to hold the sum to 12 is to never widen past `ncpu − share × (slots − 1)`, which is 4 at three slots:
  no widening at all.
  - Cost: every widened run at 4 cores. How much longer is not measured: the merge lines' run times by width given
    (the script prints them) are confounded by load, since a run is given 4 because it started on a busy Mac and is
    slowed by that same load, so they don't say what 4 cores cost against 8.
  - Middle ground: a cap at 2 × share (8). That still allows 8 + 4 + 4 = 16, today's figure, so it isn't a fix.
  - Gain: widening's cost is one widened run beside two floors. Only 44 of 114 merges were widened, so fix 2a is the
    bigger and cheaper half.
- **Fix 2c, a setting, not code: leave room for the Mac's own load.** B is 4.6. With 3 slots of 4, demand reaches 16.6
  on 12 cores whenever all three build. Either keep 3 slots and make the share ceil((cores − 3) ÷ slots) = 3, or take
  the room only when the 1-minute with no slot held is over 3.
  - Expected: the three-slot load comes down toward the two-slot curve (19.9) instead of 44.6. This is an estimate:
    the samples can't separate it from cause 1 until fix 1a records `slot_runnable`.
  - Cost: builds at 3 cores, about a third longer than at 4.

### 3. The load runs (by design; small in the data)

- **Evidence:** 15 holds and 73 minutes by signature in 10 days, a lower bound. 45 of those minutes had the 1-minute
  over T. **12 minutes had the load run as the only holder and the Mac over T: 1.2 minutes a day.** Its loops can't
  have done that alone: they start only as many as the others' load leaves short of 24 (2 × cores, under the boosted T
  of 36), and stand down above it (live: 1.5 runnable in its tree at load 27). So by design **its loops alone put the
  Mac over the limit 0 minutes a day**. Over T, the load came from its 3 suites, run 12 wide each
  (scripts/test-under-load.sh:64, not at VS_HEAVY_CORES), and from outside the slot. The signature needs a sample over
  load 48, so the holds found are biased toward heavy ones, and its "7 × its share" above is an upper figure.
- **Fix 3, task "a load run's tests at its slot's width".** scripts/test-under-load.sh:64 sets
  SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH to VS_HEAVY_CORES inside the slot, not the cores.
  - Expected load after: its 3 suites at 3 × 4 tests instead of 3 × 12. Their load is mostly waiting, so the gain is
    small. Its loops stay: they are the proof's point.
  - Cost: a load run's suites take longer: they wait, so the time grows with the width cut.
- **Not a fix: not counting its synthetic load in the gate.** The loops are real CPU, 24 runnable threads on 12
  cores. Every other run beside them waits, and merges started at load 24–36 failed 18% of the time (the load
  review). Leaving them out lowers the number without lowering contention.
- **Running it exclusively:** it would stop the 45 over-T minutes it shares with other slots. But it would make it wait
  for an empty Mac, three runs per task. Not recommended until fix 1a shows how much of those 45 minutes was its own.

### 4. Builds that start from nothing (backlog B9: plausible, on an assumption)

- **Evidence:** run 1, a lint filter run in a worktree with no .build, on a busy Mac, took 384 s, 330 of them building
  at 2.8 runnable threads (its long-lived processes). Over load 48 the recorder's top groups put build at 35% of the
  named CPU and test at 26%, but they can't tell a cold build from an incremental one. How much of the slots' CPU cold
  builds take is not measured. Every merge, audit, new worktree and new v2 clone builds cold:
  - merge and audit worktrees are scratch folders "removed afterwards" (Worktrees.swift);
  - a new v2 clone is re-cloned from the previous task's (the lead).

  In the 14 days of files (one-off queries, not printed by the script): 148 worker tasks, 39 v2 tasks, 114 merge runs
  of ours and about 24 audit holds. **Assuming** one cold build each, of about 5.5 minutes at width 4 (run 1's, the
  only cold build timed, on a busy Mac), that is about 325 cold builds and **1,790 slot-minutes: 15% of the 11,751
  slot-minutes, 22% of this project's 8,186**. Neither the count of cold builds per task nor their length was
  measured: a task may build cold more than once (a cleaned .build) or not at all (a filter run that skips building).
- **Fix 4a, an experiment first, then a task "worktrees start from main's build".** Clone the main checkout's .build into
  a new worktree, merge or audit scratch with `cp -cR` (an APFS clone, no disk until written), then time the first
  build. SwiftPM's build database holds absolute paths, so it may rebuild everything anyway. If it does, B9 needs
  Swift's compilation caching instead, which is a bigger task.
  - Expected: a cold build of 5.5 min becomes an incremental one, about 1 min where little changed. On the assumption
    above that saves about 100–150 slot-minutes a day (1,790 over 14 days, less the incremental minutes left).
  - Cost: a clone per worktree, which is free on APFS until written.
- **Fix 4b, task "one build folder per v2 line".** Each new v2 clone keeps the previous clone's .build: clone it with
  `cp -cR`, as 4a, instead of building cold. On the same assumption that is 39 cold builds in 14 days, about 215
  slot-minutes, and about 3 GB of disk per clone (the lead's figure).

### 5. Tests hold a slot's width while they wait (shorter holds, not less load)

- **Evidence:** run 2's test phase averaged 1.2 runnable threads at width 4 in its long-lived processes (78% of a
  core); its short-lived children weren't counted (up to 5.6 with all the Mac's unattributed threads). The tests wait on
  their subprocesses. 2026-11-18: 1009 s at width 4, 388–420 s at 2 a core.
- **Fix 5, the task already decided:** `tests_per_core` 2 (scripts/test.sh), once sigpipe-probe-always-on names the
  pipe writer (decision 2026-11-18 18:53).
  - Expected load after: not established. The test process itself would still use under one core on average, but
    twice the tests at once start about twice the children a minute, and their spawn checks land in the system's
    daemons; neither was measured at 2 a core. The test phase of a slot's hold is a third to a half shorter, so fewer
    minutes with three slots held. Measure it with run 3's sampler when the task lands.
  - Cost: the SIGPIPE flake (3 of 10 full runs at 2 a core) until that task lands.

## The lead's four candidates

1. **Gate less.** Of the 1,158 minutes the gate refused:
   - 49 had no slot held;
   - 1,108 had a slot held. At 817 of them the 1-minute itself was over T.
   - 549 of the 1,108 had top groups named. At 497 of those 549 (91%), no build or test group sat in a folder whose
     project held no slot. That doesn't clear our own bare builds: every worktree, v2 clone and the main checkout reads
     as our project's name, so a worker's bare `swift build` beside any slot of ours looks like that slot's run. The other
     559 minutes can't be told, because nothing is named under load 48.
   - What runs outside slots: worktree-init.sh builds nothing. Over 10 days the named samples show 30 core-samples of
     swift-frontend outside a project or slot (SourceKit-LSP or a bare build) and 0.9 of a session's bare
     `swift package`.

   **Whether "a start waits only for a free session and memory, its heavy work waits for a slot" would have been safe:
   not measurable from the samples.** They can't see our own bare builds (above), nor root's or short-lived processes.
   What is known: worktree-init.sh builds nothing, and no build or test of another folder's project ran outside a slot
   at 91% of the named minutes. Fix 1a's `slot_runnable` makes it measurable: it counts the slot holders' trees, so a
   bare build in a worktree lands in "outside". Recommended order: 2a, 1a, a week of samples, then the gate rule.
2. **The load runs:** its loops alone put the Mac over the limit 0 minutes a day by design (they fill only up to 24).
   With the load run the only holder the Mac was over the limit 1.2 minutes a day (12 in 10 days), from its suites and
   from outside the slot. 73 minutes held in 10 days by signature, a lower bound. Leaving its loops out of the gate
   isn't a fix: below 24 they are real contention, 24 runnable threads on 12 cores. Running it exclusively helps only
   the 45 over-T minutes it shared with other slots, which fix 1a can attribute first. Fix 3 sizes its suites.
3. **Builds avoided:**
   - the split of heavy-slot time into building and testing was **not measured**: the samples don't record the
     holder's phase, and only one cold build was timed (run 1, 5.5 min on a busy Mac);
   - **assuming** one cold build of 5.5 min per task, merge run and audit: about 1,790 slot-minutes, 15% of the 11,751
     (22% of this project's 8,186);
   - per worktree: 148 tasks with a hold, one cold build each on that assumption;
   - per v2 clone: 39 in 14 days, about 215 slot-minutes on that assumption, and about 3 GB each.

   B9 is plausible, not shown: it rests on that assumption. Fix 4a's experiment, timed, measures the saving directly.
4. **An honest signal:** yes, add `cpu_idle` now, with `slot_runnable` (fix 1a). At the loads measured here the load
   average is honest: runnable threads were close to it or above it in the three busy looks, and the CPU was 0–25%
   idle. Where it overstates (the restart, load
   with idle cores), `cpu_idle` says so. A rule using both can tell "the Mac is busy with our slots" from "the Mac is
   busy with something else" and from "the number is high but the cores are idle".

## The observed runs

| Run | Command (all in this worktree, main's code) | Width given | Took | Phase | The run's runnable threads (runs 1–2: long-lived processes only) | Its processes | New processes a minute | Mac's load / runnable / CPU idle |
| --- | --- | --- | ---: | --- | --- | --- | ---: | --- |
| 1 | `Resources/bin/vs-heavy bash scripts/test.sh --filter '<the 15 lint suites>'`, no .build (a cold build) | 4 (load 16.0, 2 other slots held) | 384 s | build, 5.5 min | 2.8 (max 5) | 12 (max 14) | 16 | 21.7 / 21.3 / 14% |
| 2 | `Resources/bin/vs-heavy bash scripts/test.sh` (full suite, the build warm) | 4 (load 16.3, 2 other slots held) | 914 s | test, 14.7 min | 1.2 (max 12) | 15 (max 140) | 111 | 31.9 / 31.6 / 8% |
| 3 | `bash scripts/test.sh --filter VibeHostTests` (bare, as a worker runs it) | **6** ("load 4.0, 1 of the other 2 slots held, at least the slot's share, 6") | 643 s, 570 of them in line | test, 1.0 min (warm build 0.2 min) | 1.0 (max 10); the build's link 3.2 (max 11) | 31 (max 40); 65 (max 145) at its end | 202; 911 at its end | 6.2 / 4.1 / 55% |

- Run 1 passed its 52 lint tests. Run 2 ran 4,787 tests in 653 suites and passed in 897.6 s (4 known issues), with
  the web tests 7 of 7 and 2 of 2. Run 3 ran 275 tests in 61 suites and passed in 58.2 s (3 known issues), with the
  security socket and signing checks and the web tests passing.
- **Run 3 waited 9.5 minutes in line, "all 2 slots held".** For the first 6 of them (13:31–13:36 in the samples) slots 1
  and 2 were held and slot 3 was free. At 13:37 a load run, started on the real home, took slot 3. Then it was given 6
  cores, the share of 2 slots.
- **Run 3's test phase spawned 202 processes a minute, and 911 a minute at its end** (up to 145 alive at once): the
  hosts, MCP servers and git its tests start. Its own runnable threads stayed at 1.0 on average. Outside its tree,
  syspolicyd, XProtect and tccd were runnable at every look (0.2–0.9 each), checking the new processes. These are root
  daemons, so the recorder can't see them. This is the mechanism behind "short-lived" in the table above: the cost of a
  spawn lands in the system's daemons, not in the run's tree.
- Runs 1 and 2's sampler took membership and thread states in two `ps` calls, so a process born between them went
  unattributed: 3.2–4.4 runnable threads at the Mac's level. Read those runs' numbers as lower bounds: run 1's build
  2.8 to 7.2 on width 4, run 2's test phase 1.2 to 5.6 on width 4, depending on how much of the unattributed was
  theirs. Whether they stay inside their width is therefore not established. Run 3's sampler takes both from one `ps -AMww` snapshot and adds processes outside the tree that
  name the run's scratch folder (the leftover check's mark).

## What was not measurable

- **Our own bare builds outside a slot.** A worktree's processes read as our project, so the samples can't tell a
  bare `swift build` from a slot's run. Fix 1a's `slot_runnable` can.
- **Who makes the load above 48 over the 10 days.** The recorder names under a third of the cores in use there. It
  doesn't see root's processes (Spotlight, logd, syspolicyd) or short-lived ones. Fix 1a records the split from now on.
- **The holder's command.** The samples never record it. Load runs are found only by a signature above load 48, and a
  worker's focused run, full run, build-app.sh, verifier run and pre-done check can't be told apart. Fix 1a can add the
  holder's first word (scripts/test.sh, test-under-load, build-app) and its width to `LoadSample.Holder`: the .holder
  note has both.
- **What `checkout`, `clone` and `repo` are.** They are other folders' holders with no task. Their slot time, part of
  the 3,199 other-project and 366 no-project minutes, is unattributable.
- **Spotlight's cause** (fix 1c's experiment) and **whether a cloned .build builds incrementally** (fix 4a's).
- **A calm-Mac cold build and full suite (waived by the lead).** Runs 1 and 2 had two other slots held throughout.
  Their thread counts leave out their short-lived children (lower bounds); their durations are a busy Mac's. A later
  task takes that run, with run 3's one-snapshot sampler, if a fix needs the baseline: whether a cold build and a full
  suite stay inside their width, fix 4's minutes per cold build, fix 5's test-phase time.
- **How much heavy-slot time is building rather than testing**, per worktree and per v2 clone (candidate 3). The
  samples don't record a holder's phase; cause 4's 1,790 slot-minutes assume one 5.5-minute cold build per task, merge
  run and audit. Fix 1a's holder command, or a phase field, would measure it.
- **Module-cache rebuilds** (Clang's module cache, SwiftPM's in .build and SourceKit-LSP's own): whether they happen
  outside a slot, at what width, and what they cost. No sample, look or run separates them from the compile around
  them.
- **Fix 2b's cost.** The merge lines' run times by width given are confounded by load: a run given 4 started on a busy
  Mac and ran on it. What 4 cores cost against 8 on the same Mac wasn't measured.
- **Uninterruptible waits.** ps state U averaged 0.0–2.6 threads across the looks. Whether the load average counts
  them on this kernel wasn't verified: they were too few to matter here.
