# Why a heavy slot loads the Mac beyond its share of cores, 2026-11

**Top fix 1: a worker's test run gets the share of 2 slots, not 3.** scripts/test.sh moves VIBESWITCHER_HOME to its scratch
home before it calls vs-heavy, so vs-heavy reads neither Settings nor Boost: it counts 2 slots, gives the run 6 cores
instead of 4, and lets it take only slots 1 and 2. Workers' runs hold 77% of the slot-minutes. **You get:** three slots
that add up to 12 cores of work, not the 16 seen today (6 + 6 + 4), and no worker run waiting in line while slot 3 is free.
**Top fix 2: record what the load is made of.** Each minute's sample adds the CPU's idle share and the runnable threads
inside the slots' processes. **You get:** a number for the load outside any slot. In two live looks it was 64–70% of
the runnable threads: another project's runtime, Spotlight, short-lived processes. The 10 days of samples can't
see it at all. With it, the gate can judge contention instead of a count, and "a start waits only for a slot" can be judged.

Written by a worker (task why-a-heavy-slot) on 2026-11-27. Reproduce the numbers with
`python3 -I scripts/heavy-slot-load.py --until 2026-11-27T11:28`, the data the load review saw
([the script](../../../scripts/heavy-slot-load.py), a sibling of
[the load gate backtest](../../../scripts/load-gate-backtest.py), whose reading and minutes it reuses). Its arithmetic
is checked on a hand-made fixture ([scripts/fixtures/heavy-slot](../../../scripts/fixtures/heavy-slot)) by
`python3 -I scripts/heavy-slot-load.py --selftest`. The review it follows: [the load gate](load-gate-2026-11.md).

## The answer in one paragraph

A slot's own processes mostly stay inside its width. Measured with `ps`, a build at VS_HEAVY_CORES 4 ran 2.8 runnable
threads on average (at most 5). A full suite's test phase ran 1.2 (at most 12), because the tests wait on their
subprocesses. Three things push the Mac past the slots' shares. (1) **Load outside any slot:** in two live looks with
all three slots held, the holders' process trees held 7.2 of 26.6 and 7.8 of 33.2 runnable threads; the rest ran outside
any slot.
(2) **Slots wider than their share:** a worker's run gets 6 cores because of the scratch home (fix 1), and vs-heavy
widens the first run to every free core. Neither leaves room for the Mac's own load (4.6 with no slot held). Live: 6 + 6
+ 4 = 16 cores given on 12. (3) **Saturation:** once demand passes 12 cores the CPU is 0–8% idle, threads queue, and the
1-minute load grows faster than the work. The samples show it: 9.7 with one slot held, 19.9 with two, 44.6 with three.
That is real contention, not a count of idle waiters: at those moments `ps`'s runnable threads matched the load (26.6
against 27.1; 31.6 against 31.9). By kind of holder, **workers' runs account for most of the over-share load**: 37–42%,
then merges at 26–32%, then the v2 clones' runs at 20–22%. Per minute held, load runs are the heaviest, at 7 × their
share.

## What was measured

- **Samples:** ~/.vibeswitcher/stats/load-2026-11-14 to 11-27 (to 11:28), 14,364 samples, 239.9 hours, 10.0 days of
  samples. merges-*.jsonl beside them. The anchor reproduces the load review's table exactly: the 1-minute averages 4.5
  with no slot held, 9.7 with one, 19.9 with two and 44.6 with three (p90 101.2). The gate's baseline rule refused 1,158
  minutes. B, the mean 1-minute with no slot held, is 4.6.
- **What a holder is.** A sample records a slot's project, task and minutes held, never its command (LoadRecorder.swift:
  "never its command"), so its kind is inferred. Each rule, and how sure it is:
  - **merge:** no task, and one of our merge lines spans the sample (its `t` is when the slot was taken; ±1 minute).
    Merges, audits and reverts all write the repository as their place (`Worktrees.runChecks`, `place: root`). Our 114
    merge runs sum to 2,885 minutes and the holds classed as merge to 2,287. The gap is sleep and sample gaps inside
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
  tool looked at any process. **The Mac wasn't calm for any of them:** two other slots were held throughout, and the CPU
  was 0–25% idle. The run's own counts don't depend on that; the Mac's counts do.
- **Passive looks:** two looks of 3 minutes each, with no run of mine. They sampled the three live holders' trees the
  same way: test.sh at 6 cores, a v2 clone's test.sh at 6, and a load run at 4.

## Where the load comes from, by what holds the slots

Over the 10 days, 7,391 minutes had a slot held and 68,617 load-minutes were over the shares. 817 minutes had a slot
held and the 1-minute over the threshold in force.

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
against a sum of 26.8. Three workers average 42.5, and a worker with two v2 runs 52.5. The third slot tips the Mac into
saturation, and from there the load grows faster than the work.

**No phase of a merge's own run is the culprit.** Over all merge-alone samples, minutes 0–10 of a hold average 8.5–10.8
and minutes 11–40 average 22–43. But that mixes holds: the merges still running at minute 11 are the slow ones, on a
busy Mac. Compared with itself, each of the 12 merge holds held alone for 15 minutes or more has a median of 8.9 at
minutes 0–5 and 7.1 at minutes 11–20. Two holds carry the averages (213 and 45 at minutes 11–20). The test phase
doesn't load the Mac; the run's neighbours do.

**Above load 48 the recorder sees only a fraction.** At the 562 samples that name top groups, those groups use a median
of 2.7–3.4 cores, while the load is 48–248. With 3 slots held, the named CPU is 2.5 cores of build and test work inside
slots, 0.1 ours outside, 0.1 sessions, 0.2 other of ours and 0.8 not ours, against a mean load of 99.9. The rest of
the load is in processes the recorder can't name:
- other users' (root) processes: `LoadRecorder.processes` skips a pid whose `proc_pidinfo(PROC_PIDTASKALLINFO)` fails,
  and Spotlight's mds_stores, logd and syspolicyd are root's;
- processes that start and exit between two looks: the tests' git and sh;
- groups past the top 5.

So the samples can rank holders by the load that comes *with* them. They can't say how much of that load their own
processes make. The live looks below can.

## The live looks: load is runnable threads, and most of them run outside the slots

| Look | Load 1-min | Mac runnable (ps) | CPU idle | Holders' trees runnable (width) | Outside any slot |
| --- | ---: | ---: | ---: | --- | --- |
| passive, 3 holders, 3 min | 27.1 | 26.6 (p90 74) | 25% | test.sh 2.3 (6), v2 test.sh 3.4 (6), load run 1.5 (4) | 18.5: beam.smp 9.0, short-lived 2.4, Spotlight (mds_stores + mds) 2.7, claude 0.7, logd 0.6 |
| passive, 3 holders, 2.9 min | 27.8 | 33.2 (p90 61) | 1% | v2 test.sh 4.0 (6), run 2 0.9 (4), test.sh 2.9 (6) | 21.2: beam.smp 7.6, short-lived 3.7, Spotlight 4.4, another project's esbuild 1.1, logd 0.9 |
| run 2's test phase, 14.7 min | 31.9 | 31.6 (max 114) | 8% | run 2 1.2 (4); the other holders not split | the rest, other slots included: beam.smp 7.6, short-lived 3.6, swift-frontend 2.8, Spotlight 3.5 |

- **The load average is the runnable threads, and here it is real contention.** At every look, `ps`'s count of
  runnable threads tracked the 1-minute load, and the CPU was 0–25% idle. A thread in an uninterruptible wait (ps
  state U) averaged 0.0–0.3. So at these loads the number isn't inflated by threads sleeping on disk. The load review's
  restart, where the load was high on idle cores, is the exception: there the count overstates.
- **beam.smp** is another project's Erlang VM, and it held no slot. It is today's largest single source. In the 10 days
  of samples it is named only 3 times, so it ranks as an instance of "outside any slot", not as a cause of its own.
- **Spotlight** (mds_stores, mds, corespotlightd) had 2.7–4.4 runnable threads in every look, while builds wrote their
  .build folders. That it indexes our build output is plausible and unverified: no tool may look at what it reads.
- **"Short-lived"** is processes born between two `ps` calls (the first sampler took membership and states in separate
  calls). The one-snapshot sampler of run 3 counts them into their trees: see run 3.

## Following VS_HEAVY_CORES: configured width, what runs, whether it honours the share

| Step | Where | Configured width | What actually runs (measured) | Honours the share? |
| --- | --- | --- | --- | --- |
| vs-heavy's width | Resources/bin/vs-heavy `give_width` | the cores free at start (12 − 1-minute − other slots' widths), at least the share (ceil(12 / slots) = 4) | merges: 70 of 114 lines at 4; 44 at 5–10. Live: 6, 6, 4 | **No, in two ways.** (a) It widens to every free core when it starts, and later runs get only the floor: the sum isn't held to 12. (b) No room is kept for the Mac's own load (B 4.6) |
| scripts/test.sh's own vs-heavy | scripts/test.sh:298 exports VIBESWITCHER_HOME to the scratch home, then :323 calls Resources/bin/vs-heavy | vs-heavy reads mac-limits.json and boost.json from VIBESWITCHER_HOME: neither is there, so slots = cores ÷ 6 = 2, share 6, and it takes only slots 1–2 | probe (a scratch lock folder, a fake load): scratch home "VS_HEAVY_CORES 6 … 0 of the other 1 slot held", real home 4. Run 3, bare: "waiting … (all 2 slots held)" while slot 3 was free | **No:** 6 instead of 4 for every worker, verifier and v2 run, and a queue that ignores slot 3. Merges (TestLock in the app, 3 slots) and `vs-heavy bash scripts/test.sh` wrapped on the real home get 4 |
| swift build / swift test | scripts/lib/swift-jobs.sh `heavy_swift` | `-j 2 -Xswiftc -j$(( (W + 1) / 2 ))`: 2 modules × W/2 frontends ≈ W | run 1, cold build at W 4: runnable 2.8 on average, at most 5; processes 12, at most 14 | Yes |
| Swift Testing's width | scripts/test.sh `slot_width`; `tests_per_core` 1 (the 2026-11-18 18:53 decision kept 1; the 09:57 one allowed 2 × W) | W × 1 tests at once | run 2, full suite at W 4: runnable 1.2 on average (at most 12); processes 15 (at most 140); 111 new processes a minute; the run's %CPU 78 | Yes: the tests use far less than W. They wait on hosts, git and sockets. The 2026-11-18 numbers (1009 s at 4, 680 s at 6) are wait, not CPU |
| The tests' subprocesses | hosts, parsers, git, fake Claude, zsh, xcrun | not sized: each test starts its own | run 2: 111 new processes a minute, up to 140 alive at once. Run 3: see below | Counted in the run's runnable threads above, which stay under W on average |
| Web and security tests | scripts/test.sh `run_web_tests`, after the slot is let go | one node at a time | run 2: 0.5 runnable | Outside the slot, but tiny |
| scripts/test-under-load.sh | :64 sets each run's Swift Testing width to the cores (12) for 3 runs; its busy loops fill the load to --load (2 × cores = 24) | its build uses VS_HEAVY_CORES; its tests use 3 × 12 = 36 wide; its loops make up to 24 runnable by design | live: the load run's tree 1.5 runnable while the Mac was over 24 (its loops stood down, as designed) | **No, by design:** it adds load up to 24 whatever its share. Its tests ignore VS_HEAVY_CORES |
| worktree-init.sh | scripts/worktree-init.sh | builds nothing: it writes .sourcekit-lsp/config.json and exits | — | Not a load |
| Outside slots: SourceKit-LSP and bare builds | sessions | — | top groups: swift-frontend groups leading themselves in no project folder, 24.8 core-samples in 10 days; swift-frontend in ours with no slot held, 5.5; swift-package led by zsh (a session's bare command), 0.9 | Small: 54 of the 562 named samples show build or test work of ours outside any slot |

## The causes, ranked by the load they account for, and the fixes

Each fix is written to become a task. "Expected load" says what should change. None of it was tried: this task changes
no code. Cause 1 accounts for the most load, but the samples can't size any of its fixes, so its first fix is to record
it (top fix 2). Fix 2a removes the most load that is certain, at the least cost (top fix 1).

### 1. Load outside any slot (the largest share: 64–70% of the runnable threads in the live looks)

- **Evidence:** the two passive looks above. The slot holders' trees held 7.2 of 26.6 and 7.8 of 33.2 runnable
  threads. Outside them:
  another project's VM, Spotlight, short-lived processes, sessions. The 10-day samples can't split it (see "the
  recorder sees only a fraction").
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
- **Fix 1b, task "a heavy job with no slot is named".** When the recorder's top groups show a group of build or test
  commands (BUILD and TEST in the script) using 200% or more for 3 samples, in a project whose holders hold no slot,
  the Team view's load line and the lead's status say so: "another project runs a heavy job outside the slots".
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
  Workers' and v2 runs hold 5,669 of the 7,391 slot-minutes (77%). The live .cores notes read 6, 6 and 4.
  Separately, give_width widens a run to every free core: 44 of 114 merges were given 5–10 cores. A run given 10
  on a calm Mac keeps 10 when two more start beside it.
- **Fix 2a (top fix 1), task "test.sh counts the Mac's slots".** In scripts/test.sh, call Resources/bin/vs-heavy with
  the real VibeSwitcher folder: pass `VIBESWITCHER_HOME` as it was before line 298 to the vs-heavy call only, so vs-heavy
  reads mac-limits.json and boost.json; the command inside still gets the scratch home. The same check goes in
  scripts/build-app.sh. scripts/test-under-load.sh already execs vs-heavy before it moves HOME.
  - Test: TestScriptWidthTests on a scratch home whose boost.json gives 3 slots: the run gets 4 and can take slot 3.
  - Expected load after: at most 4 + 4 + 4 = 12 cores given at three slots, not 16 (6 + 6 + 4) or 18 (6 + 6 + 6).
    A build's runnable threads follow its width (2.8 on average at 4, measured), so each worker build overlapping others
    runs about a third fewer: about 1.4 on average, 2 at its peak.
  - Cost: a worker's build at 4 cores instead of 6 while other slots are held. A full suite's test phase at width 4,
    not 6: about 1009 s instead of 680 s (2026-11-18). Fix 4 gives that back.
  - Gained: no worker run waits in line while slot 3 is free (run 3 waited "all 2 slots held", 3rd in line behind two
    other bare test.sh runs). In the samples, slots 1 and 2 were held and slot 3 free for 1,564 of the 12,250 minutes
    with 3 slots in force: an upper bound on that wait. Workers did hold slot 3 for 550 minutes, through runs wrapped in
    vs-heavy on the real home and load runs.
  - What it changes besides: slot 3 fills more often, so more minutes have three slots held. They hold 4 + 4 + 4, the
    same 12 cores that two bare runs hold today (6 + 6). So the third slot no longer adds a third job on top.
- **Fix 2b, not recommended now: stop widening.** give_width can't narrow a widened run when others start beside it.
  So the only way to hold the sum to 12 is to never widen past `ncpu − share × (slots − 1)`, which is 4 at three slots:
  no widening at all.
  - Cost: a merge on a calm Mac runs at 4 cores, 18.4 min median instead of 10.6 at 8 (the merge lines).
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
  over T. **12 minutes had the load run as the only holder and the Mac over T: 1.2 minutes a day.** All 12 are under T
  once its busy loops' target above B (24 − 4.6) is taken out. Its loops fill the load to 24 whatever else runs: on a
  calm Mac they *are* the load, and on a busy one they stand down (live: 1.5 runnable in its tree at load 27). Its 3
  suites run 12 wide each (scripts/test-under-load.sh:64), not at VS_HEAVY_CORES.
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

### 4. Builds that start from nothing (backlog B9: the data supports it)

- **Evidence:** run 1, a lint filter run in a worktree with no .build, took 384 s, 330 of them building at 2.8 runnable
  threads. Builds are where a slot's CPU goes: 2.8 runnable at width 4, against the tests' 1.2.
  Every merge, audit, new worktree and new v2 clone builds cold:
  - merge and audit worktrees are scratch folders "removed afterwards" (Worktrees.swift);
  - a new v2 clone is re-cloned from the previous task's (the lead).

  In the 14 days of files: 148 worker tasks, 39 v2 tasks, 114 merge runs of ours and about 24 audit holds. At about 5.5
  minutes each at width 4, that is about 325 cold builds and **1,790 slot-minutes, about a quarter of the 7,391 held**,
  and most of the slots' CPU.
- **Fix 4a, an experiment first, then a task "worktrees start from main's build".** Clone the main checkout's .build into
  a new worktree, merge or audit scratch with `cp -cR` (an APFS clone, no disk until written), then time the first
  build. SwiftPM's build database holds absolute paths, so it may rebuild everything anyway. If it does, B9 needs
  Swift's compilation caching instead, which is a bigger task.
  - Expected: a cold build of 5.5 min becomes an incremental one, about 1 min where little changed. That saves about
    100–150 slot-minutes a day, and most of them are build minutes at full width.
  - Cost: a clone per worktree, which is free on APFS until written.
- **Fix 4b, task "one build folder per v2 line".** Each new v2 clone keeps the previous clone's .build: clone it with
  `cp -cR`, as 4a, instead of building cold. That is 39 cold builds in 14 days, about 215 slot-minutes, and about 3 GB
  of disk per clone (the lead's figure).

### 5. Tests hold a slot's width while they wait (shorter holds, not less load)

- **Evidence:** run 2's test phase averaged 1.2 runnable threads at width 4 (78% of a core). The tests wait on their
  subprocesses. 2026-11-18: 1009 s at width 4, 388–420 s at 2 a core.
- **Fix 5, the task already decided:** `tests_per_core` 2 (scripts/test.sh), once sigpipe-probe-always-on names the
  pipe writer (decision 2026-11-18 18:53).
  - Expected load after: about the same CPU (tests at 2 a core still use under one core on average). The test phase of
    a slot's hold is a third to a half shorter, so fewer minutes with three slots held.
  - Cost: the SIGPIPE flake (3 of 10 full runs at 2 a core) until that task lands.

## The lead's four candidates

1. **Gate less.** Of the 1,158 minutes the gate refused:
   - 49 had no slot held;
   - 1,108 had a slot held. At 817 of them the 1-minute itself was over T.
   - 549 of the 1,108 had top groups named. At 497 of those 549 (91%), every build or test of ours that the recorder
     could see was inside a slot. The other 559 minutes can't be told, because nothing is named under load 48.
   - What runs outside slots: worktree-init.sh builds nothing. Over 10 days the named samples show 30 core-samples of
     swift-frontend outside a project or slot (SourceKit-LSP or a bare build) and 0.9 of a session's bare
     `swift package`.

   **So "a start waits only for a free session and memory, its heavy work waits for a slot" would have been safe for
   our own work.** What breaks it is load outside the slots that isn't ours (cause 1). Starting workers on a Mac whose
   load is someone else's adds sessions, not compile threads. **But it is safe only once fix 2a holds the slots to their
   share, and fix 1a can see the outside load.** Until then, a start on a saturated Mac queues heavy work behind three
   slots that already over-give. Recommended order: 2a, 1a, then the gate rule.
2. **The load runs:** 1.2 minutes a day alone over the limit, and its loops decide all of them. 73 minutes held in 10 days
   by signature, a lower bound. Leaving its loops out of the gate isn't a fix (they are real contention). Running it
   exclusively helps only the 45 shared over-T minutes, which fix 1a can attribute first. Fix 3 sizes its tests.
3. **Builds avoided:**
   - about a quarter of the slot-minutes (about 1,790 of 7,391) are cold builds, and they are most of the slots' CPU;
   - per worktree: 148 tasks with a hold, one cold build each, about 5.5 min at width 4;
   - per v2 clone: 39 in 14 days, about 215 slot-minutes and about 3 GB each.

   B9 is supported. Fix 4a is the experiment that decides whether a clone of .build is enough.
4. **An honest signal:** yes, add `cpu_idle` now, with `slot_runnable` (fix 1a). At the loads measured here the load
   average is honest: runnable threads matched it, and the CPU was 0–25% idle. Where it overstates (the restart, load
   with idle cores), `cpu_idle` says so. A rule using both can tell "the Mac is busy with our slots" from "the Mac is
   busy with something else" and from "the number is high but the cores are idle".

## The observed runs

| Run | Command (all in this worktree, main's code) | Width given | Took | Phase | The run's runnable threads | Its processes | New processes a minute | Mac's load / runnable / CPU idle |
| --- | --- | --- | ---: | --- | --- | --- | ---: | --- |
| 1 | `Resources/bin/vs-heavy bash scripts/test.sh --filter '<the 15 lint suites>'`, no .build (a cold build) | 4 (load 16.0, 2 other slots held) | 384 s | build, 5.5 min | 2.8 (max 5) | 12 (max 14) | 16 | 21.7 / 21.3 / 14% |
| 2 | `Resources/bin/vs-heavy bash scripts/test.sh` (full suite, the build warm) | 4 (load 16.3, 2 other slots held) | 914 s | test, 14.7 min | 1.2 (max 12) | 15 (max 140) | 111 | 31.9 / 31.6 / 8% |
| 3 | `bash scripts/test.sh --filter VibeHostTests` (bare, as a worker runs it) | RUN3_WIDTH | RUN3_TOOK | RUN3_PHASE | RUN3_R | RUN3_PROCS | RUN3_NEW | RUN3_MAC |

- Run 1 passed its 52 lint tests. Run 2 ran 4,787 tests in 653 suites and passed in 897.6 s (4 known issues), with
  the web tests 7 of 7 and 2 of 2. Run 3: RUN3_RESULT.
- Runs 1 and 2's sampler took membership and thread states in two `ps` calls, so a process born between them went
  unattributed: 3.2–4.4 runnable threads at the Mac's level. Read those runs' numbers as "1.2, plus a share of an
  unattributed 3.2–4.4". Run 3's sampler takes both from one `ps -AMww` snapshot and adds processes outside the tree that
  name the run's scratch folder (the leftover check's mark).

## What was not measurable

- **Who makes the load above 48 over the 10 days.** The recorder names under a third of the cores in use there. It
  doesn't see root's processes (Spotlight, logd, syspolicyd) or short-lived ones. Fix 1a records the split from now on.
- **The holder's command.** The samples never record it. Load runs are found only by a signature above load 48, and a
  worker's focused run, full run, build-app.sh, verifier run and pre-done check can't be told apart. Fix 1a can add the
  holder's first word (scripts/test.sh, test-under-load, build-app) and its width to `LoadSample.Holder`: the .holder
  note has both.
- **What `checkout`, `clone` and `repo` are.** They are other folders' holders with no task. Their slot time, part of
  the 3,199 other-project and 366 no-project minutes, is unattributable.
- **Spotlight's cause** (fix 1c's experiment) and **whether a cloned .build builds incrementally** (fix 4a's).
- **A calm-Mac run.** All three observed runs had two other slots held. The runs' own thread counts stand; their
  durations are those of a busy Mac.
- **Uninterruptible waits.** ps state U averaged 0.0–2.6 threads across the looks. Whether the load average counts
  them on this kernel wasn't verified: they were too few to matter here.
