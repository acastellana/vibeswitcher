# The chat bench settle matrix on a quiet Mac, 2026-10-20

`scripts/chat-bench-settle.sh -n 12` on `Tests/VibeSwitcherTests/Fixtures/chat-bench.jsonl` (both A and B): 4 scenarios
× 4 widths × 4 variants = 64 cases, 12 runs each, 768 runs. Each case was started only while the Mac was quiet (see the
gate below), and its load was recorded. This is the evidence for setting workflow.md's `regression_command`.

**Result: 64/64 cases at 12/12.** No run failed. Five cases were rerun because the load went over 12 while they ran;
their first attempts also passed 12/12. 37 runs were starved on their first attempt and the script ran them again;
11 of those were starved a second time, so they were only recorded. The script counts all of these as passing (see
[Starved runs](#starved-runs)). The most CPU the main thread spent in any one tick, over all 768 counted runs, was
0.13 s. The rule's limit is 0.25 s.

- Mac: Apple M3 Pro, 12 cores (6 performance + 6 efficiency), 36 GB. Binary: `.build/debug/VibeSwitcher` built from
  9d612c9 (the branch's head; `scripts/test.sh` had just built it and passed 1574 tests).
- Stall rule as the bench printed it: `load_threshold 24 (twice the 12 cores)`, from the lead's workflow.md (which sets
  no load_threshold). Every counted run started under 12, so every run was judged by the strict rule: any tick over
  0.25 s fails, on the wall clock or on the CPU.
- Defaults: `-j 6`, `-e 2` (Show earlier twice), the busy model and the window's timer, widths `700 900 1200 1728`,
  scenarios `switch top middle bottom`, variants `plain LIVE STACK WINDOW`.

## The gate

A wrapper (not committed; it calls the script unchanged with `-s S -w W -v V -n 12`, one case at a time) ran the
matrix under the lead's rule:

1. **Before the matrix:** 5 minutes in a row with a 1-minute load under 8 and no `swift-frontend`, `swift-build`,
   `swift-package`, `swift-driver`, `swiftpm-testing-helper`, `xctest`, `clang` or `ld` process alive in any worktree.
   That took 58.6 min to reach, because another worker's `build-app.sh` builds ran until about 23:18. The matrix
   started at 23:23:32 at load 2.62.
2. **Before each case:** a 1-minute load under 12 and none of those processes. The load was then sampled every 5 s
   while the case ran.
3. **Rerun, not counted:** a case during which one of those processes appeared, or whose load reached 12 at any
   sample, was run again once the window was quiet. No compiler appeared during the matrix. Five cases went over 12
   (below), and their reruns stayed under it.

Earlier attempts, before the lead's rule (22:17–22:22), are not in the counts. One attempt at switch/700/plain ended
in a bug in the wrapper (12/12, start load 9.94). Three more overlapped another worker's `swift build -c release`, and
the wrapper threw them out. They passed 12/12 anyway, with
a longest tick of 1.53 s at load 21.6, starved.

| Case rerun | First attempt: start → max load | What the first attempt saw | Rerun: start → max load | Rerun |
|---|---|---|---|---|
| switch/900/plain | 6.30 → 13.77 | 12/12, 6 runs starved twice | 4.74 → 5.85 | 12/12, nothing starved |
| top/900/WINDOW | 6.00 → **30.27** | 12/12, every run started at load 22–30 and was judged by the loaded rule | 6.19 → 10.56 | 12/12, nothing starved |
| top/1728/WINDOW | 4.67 → 12.80 | 12/12, 6 runs starved twice (page 2, 0.53–0.62 s, 0.13–0.16 s CPU) | 9.52 → 9.52 | 12/12, nothing starved |
| bottom/1200/STACK | 6.95 → 17.06 | 12/12, 6 runs starved twice | 7.90 → 8.89 | 12/12, nothing starved |
| bottom/1728/LIVE | 9.38 → 15.88 | 12/12, 6 runs starved twice | 8.89 → 9.05 | 12/12, nothing starved |

The load jumps in those five came from outside the bench. In top/900/WINDOW the load went from 6.0 to 22.6 within
10 s of the case starting, and the bench's own six processes add 1–2 to the load in the other cases. No compiler was
running. Other projects' sessions were seen running during the matrix: a Python pipeline and a pytest run at 100 % CPU,
Chrome, Telegram at 116 %.

## Loads and time

- **Case start load** (counted attempts): min 2.62, median 6.47, max 11.86.
- **Max load during a case:** min 3.17, median 7.20, max 11.86.
- **Load at each run's start** (from the bench's own `stall rule:` line, 768 runs): min 2.6, median 6.6, max 11.9.
- **Time:** the 64-case pass took 2244 s (37 min 24 s), 23:23:32–00:00:56. The five reruns took 150 s, starting at
  00:08:43 after their own 5-minute quiet window. A case takes 28–31 s at `-j 6`. When the script has to run starved
  first attempts again, a case takes 46–47 s.

## Ticks, per phase

These cover the counted run of each of the 768 runs, which is the second attempt for a starved one. The
**longest tick** is on the wall clock. **Most CPU** is the most the main thread spent on the CPU in one tick. The
phases are the bench's: the first open (until it settles, or until the first page is pressed), then page 1 and page 2
of Show earlier. All values are in seconds.

| Phase | Runs | Longest tick: median | p90 | max | Most CPU: median | p90 | max |
|---|---|---|---|---|---|---|---|
| first open | 768 | 0.08 | 0.12 | 0.46 | 0.07 | 0.09 | 0.13 |
| page 1 | 768 | 0.06 | 0.09 | 0.24 | 0.06 | 0.07 | 0.12 |
| page 2 | 768 | 0.07 | 0.10 | 0.24 | 0.07 | 0.09 | 0.13 |

The 0.46 s first-open maximum is a run that was starved twice (switch/1728/STACK #11: 0.46 s with 0.10 s on the
CPU). Not counting starved runs, every longest tick was 0.25 s or less.

### Per case

These are the counted attempt's maxima over its 12 runs, as longest tick / most CPU, in seconds. For the five rerun
cases, the counted attempt is the rerun.

| Case | Passed | Start load | Max load | First open: longest / most CPU | Page 1 | Page 2 |
|---|---|---|---|---|---|---|
| switch-700-plain | 12/12 | 2.62 | 3.17 | 0.10 / 0.09 | 0.10 / 0.08 | 0.09 / 0.08 |
| switch-700-LIVE | 12/12 | 3.19 | 4.10 | 0.10 / 0.09 | 0.08 / 0.07 | 0.07 / 0.07 |
| switch-700-STACK | 12/12 | 4.49 | 4.49 | 0.10 / 0.09 | 0.08 / 0.07 | 0.07 / 0.06 |
| switch-700-WINDOW | 12/12 | 4.36 | 6.32 | 0.09 / 0.08 | 0.08 / 0.06 | 0.09 / 0.08 |
| switch-900-plain | 12/12 | 4.74 | 5.85 | 0.14 / 0.10 | 0.06 / 0.06 | 0.08 / 0.08 |
| switch-900-LIVE | 12/12 | 9.74 | 9.74 | 0.13 / 0.09 | 0.08 / 0.07 | 0.07 / 0.06 |
| switch-900-STACK | 12/12 | 8.21 | 8.21 | 0.13 / 0.11 | 0.07 / 0.07 | 0.07 / 0.07 |
| switch-900-WINDOW | 12/12 | 6.21 | 6.41 | 0.10 / 0.08 | 0.07 / 0.07 | 0.08 / 0.08 |
| switch-1200-plain | 12/12 | 5.60 | 6.13 | 0.13 / 0.09 | 0.07 / 0.06 | 0.09 / 0.09 |
| switch-1200-LIVE | 12/12 | 6.05 | 7.53 | 0.09 / 0.08 | 0.15 / 0.08 | 0.10 / 0.09 |
| switch-1200-STACK | 12/12 | 7.49 | 7.49 | 0.22 / 0.08 | 0.09 / 0.08 | 0.11 / 0.10 |
| switch-1200-WINDOW | 12/12 | 6.59 | 6.59 | 0.09 / 0.08 | 0.15 / 0.09 | 0.21 / 0.13 |
| switch-1728-plain | 12/12 | 10.23 | 10.23 | 0.25 / 0.10 | 0.07 / 0.07 | 0.09 / 0.08 |
| switch-1728-LIVE | 12/12 | 6.63 | 7.70 | 0.12 / 0.09 | 0.08 / 0.08 | 0.10 / 0.09 |
| switch-1728-STACK | 12/12 | 6.36 | 10.70 | 0.46 / 0.13 | 0.24 / 0.09 | 0.08 / 0.07 |
| switch-1728-WINDOW | 12/12 | 9.75 | 9.75 | 0.09 / 0.08 | 0.07 / 0.07 | 0.09 / 0.08 |
| top-700-plain | 12/12 | 9.01 | 9.01 | 0.13 / 0.08 | 0.10 / 0.08 | 0.09 / 0.09 |
| top-700-LIVE | 12/12 | 7.82 | 8.18 | 0.13 / 0.10 | 0.10 / 0.06 | 0.13 / 0.12 |
| top-700-STACK | 12/12 | 7.52 | 7.56 | 0.09 / 0.07 | 0.07 / 0.07 | 0.08 / 0.07 |
| top-700-WINDOW | 12/12 | 6.45 | 6.56 | 0.08 / 0.07 | 0.08 / 0.07 | 0.08 / 0.08 |
| top-900-plain | 12/12 | 6.06 | 6.06 | 0.08 / 0.06 | 0.07 / 0.07 | 0.07 / 0.07 |
| top-900-LIVE | 12/12 | 5.46 | 6.20 | 0.10 / 0.06 | 0.08 / 0.07 | 0.10 / 0.09 |
| top-900-STACK | 12/12 | 5.97 | 6.00 | 0.09 / 0.07 | 0.08 / 0.07 | 0.09 / 0.08 |
| top-900-WINDOW | 12/12 | 6.19 | 10.56 | 0.11 / 0.09 | 0.08 / 0.07 | 0.08 / 0.08 |
| top-1200-plain | 12/12 | 11.86 | 11.86 | 0.11 / 0.10 | 0.07 / 0.07 | 0.10 / 0.09 |
| top-1200-LIVE | 12/12 | 10.15 | 10.15 | 0.18 / 0.12 | 0.07 / 0.07 | 0.09 / 0.09 |
| top-1200-STACK | 12/12 | 8.87 | 8.87 | 0.09 / 0.07 | 0.06 / 0.06 | 0.08 / 0.08 |
| top-1200-WINDOW | 12/12 | 6.42 | 6.42 | 0.11 / 0.07 | 0.17 / 0.10 | 0.10 / 0.09 |
| top-1728-plain | 12/12 | 5.46 | 5.46 | 0.08 / 0.07 | 0.07 / 0.06 | 0.07 / 0.06 |
| top-1728-LIVE | 12/12 | 4.51 | 5.25 | 0.10 / 0.09 | 0.08 / 0.07 | 0.14 / 0.10 |
| top-1728-STACK | 12/12 | 4.91 | 5.47 | 0.09 / 0.07 | 0.08 / 0.06 | 0.10 / 0.09 |
| top-1728-WINDOW | 12/12 | 9.52 | 9.52 | 0.08 / 0.07 | 0.08 / 0.07 | 0.13 / 0.12 |
| middle-700-plain | 12/12 | 11.62 | 11.62 | 0.20 / 0.07 | 0.10 / 0.06 | 0.21 / 0.11 |
| middle-700-LIVE | 12/12 | 8.47 | 8.47 | 0.10 / 0.08 | 0.07 / 0.07 | 0.09 / 0.08 |
| middle-700-STACK | 12/12 | 7.68 | 7.68 | 0.09 / 0.07 | 0.06 / 0.06 | 0.07 / 0.07 |
| middle-700-WINDOW | 12/12 | 7.13 | 7.31 | 0.15 / 0.07 | 0.07 / 0.06 | 0.17 / 0.11 |
| middle-900-plain | 12/12 | 6.96 | 6.96 | 0.08 / 0.07 | 0.07 / 0.07 | 0.08 / 0.07 |
| middle-900-LIVE | 12/12 | 6.26 | 7.10 | 0.09 / 0.07 | 0.08 / 0.07 | 0.09 / 0.08 |
| middle-900-STACK | 12/12 | 7.10 | 7.10 | 0.09 / 0.07 | 0.07 / 0.06 | 0.07 / 0.07 |
| middle-900-WINDOW | 12/12 | 5.84 | 11.11 | 0.26 / 0.11 | 0.10 / 0.08 | 0.23 / 0.11 |
| middle-1200-plain | 12/12 | 10.61 | 10.61 | 0.09 / 0.08 | 0.05 / 0.05 | 0.08 / 0.07 |
| middle-1200-LIVE | 12/12 | 7.30 | 7.30 | 0.09 / 0.07 | 0.21 / 0.08 | 0.10 / 0.09 |
| middle-1200-STACK | 12/12 | 6.21 | 6.21 | 0.10 / 0.08 | 0.06 / 0.06 | 0.11 / 0.10 |
| middle-1200-WINDOW | 12/12 | 6.18 | 6.75 | 0.08 / 0.06 | 0.14 / 0.11 | 0.08 / 0.07 |
| middle-1728-plain | 12/12 | 6.75 | 6.75 | 0.10 / 0.08 | 0.06 / 0.06 | 0.08 / 0.08 |
| middle-1728-LIVE | 12/12 | 5.31 | 5.41 | 0.11 / 0.07 | 0.11 / 0.08 | 0.08 / 0.08 |
| middle-1728-STACK | 12/12 | 5.41 | 5.78 | 0.09 / 0.07 | 0.06 / 0.05 | 0.07 / 0.06 |
| middle-1728-WINDOW | 12/12 | 4.52 | 7.52 | 0.20 / 0.11 | 0.08 / 0.05 | 0.08 / 0.08 |
| bottom-700-plain | 12/12 | 7.52 | 7.52 | 0.08 / 0.06 | 0.06 / 0.06 | 0.07 / 0.07 |
| bottom-700-LIVE | 12/12 | 6.50 | 6.50 | 0.08 / 0.07 | 0.06 / 0.06 | 0.10 / 0.09 |
| bottom-700-STACK | 12/12 | 5.79 | 5.79 | 0.09 / 0.07 | 0.07 / 0.06 | 0.09 / 0.07 |
| bottom-700-WINDOW | 12/12 | 5.32 | 5.32 | 0.07 / 0.06 | 0.07 / 0.06 | 0.08 / 0.08 |
| bottom-900-plain | 12/12 | 5.05 | 5.05 | 0.11 / 0.06 | 0.08 / 0.07 | 0.10 / 0.10 |
| bottom-900-LIVE | 12/12 | 5.01 | 5.65 | 0.09 / 0.07 | 0.07 / 0.06 | 0.07 / 0.07 |
| bottom-900-STACK | 12/12 | 5.00 | 5.28 | 0.08 / 0.07 | 0.06 / 0.06 | 0.08 / 0.07 |
| bottom-900-WINDOW | 12/12 | 5.28 | 5.48 | 0.11 / 0.07 | 0.07 / 0.06 | 0.12 / 0.07 |
| bottom-1200-plain | 12/12 | 5.25 | 5.55 | 0.09 / 0.08 | 0.07 / 0.07 | 0.10 / 0.09 |
| bottom-1200-LIVE | 12/12 | 7.99 | 7.99 | 0.11 / 0.10 | 0.09 / 0.08 | 0.08 / 0.08 |
| bottom-1200-STACK | 12/12 | 7.90 | 8.89 | 0.10 / 0.07 | 0.17 / 0.12 | 0.10 / 0.09 |
| bottom-1200-WINDOW | 12/12 | 11.19 | 11.19 | 0.08 / 0.07 | 0.09 / 0.09 | 0.10 / 0.10 |
| bottom-1728-plain | 12/12 | 10.32 | 10.32 | 0.11 / 0.09 | 0.09 / 0.07 | 0.12 / 0.10 |
| bottom-1728-LIVE | 12/12 | 8.89 | 9.05 | 0.11 / 0.09 | 0.07 / 0.07 | 0.08 / 0.08 |
| bottom-1728-STACK | 12/12 | 11.69 | 11.69 | 0.11 / 0.09 | 0.09 / 0.08 | 0.13 / 0.11 |
| bottom-1728-WINDOW | 12/12 | 10.50 | 10.50 | 0.43 / 0.12 | 0.12 / 0.10 | 0.24 / 0.12 |

## Starved runs

The script runs a run again when it failed only on a tick that its main thread spent mostly waiting (under half of
the tick on the CPU). If the second run is starved too, the script records `status=starved` and the run passes.
Neither attempt of any starved run worked over 0.25 s on the CPU. The counted attempts had:

| Starved | Runs | Tick (wall) | On the CPU, at most | Load at the run's start |
|---|---|---|---|---|
| first attempt, opening | 15 | 0.25–0.52 s | 0.12 s | 6.5–10.2 |
| first attempt, page 1 | 2 | 0.38–0.47 s | 0.01 s | 6.6 |
| first attempt, page 2 | 20 | 0.26–0.51 s | 0.15 s | 4.5–11.6 |
| second attempt too (recorded, `status=starved`), all at the opening | 11 | 0.26–0.46 s | 0.12 s | 9.6–10.5 |

By case, as first attempts starved / runs recorded starved:

| Case | First attempts starved | Recorded starved |
|---|---|---|
| switch/1200/STACK | 5 | 0 |
| switch/1728/plain | 2 | 0 |
| switch/1728/STACK | 6 | 6 |
| middle/700/plain | 1 | 0 |
| middle/900/WINDOW | 5 | 1 |
| middle/1728/WINDOW | 6 | 0 |
| bottom/700/LIVE | 6 | 0 |
| bottom/1728/WINDOW | 6 | 4 |

The 11 recorded-starved runs, with the first attempt's tick and the second's:

- switch/1728/STACK, case start 6.36, max 10.70. Runs #7, #9, #10, #11 starved on page 2 at t=11 s: 0.49, 0.51,
  0.50, 0.49 s with 0.11–0.15 s CPU, at load 6.6. Runs #8 and #12 starved on page 1 at t=7 s: 0.47 and 0.38 s with
  0.01 s CPU. All six second attempts starved at the opening at t=1 s: 0.30–0.46 s with 0.07–0.12 s CPU, at load
  10.1.
- bottom/1728/WINDOW, case start 10.50. Runs #2, #4, #5, #6 starved on page 2 at t=15 s: 0.27–0.30 s with 0.01–0.03 s
  CPU. Their second attempts starved at the opening: 0.34–0.43 s with 0.10–0.12 s CPU, at load 9.6.
- middle/900/WINDOW, case start 5.84, max 11.11. Run #3 starved on page 2 at t=13 s: 0.31 s with 0.02 s CPU. Its
  second attempt starved at the opening: 0.26 s with 0.08 s CPU, at load 10.5.

**What they are: scheduling under the starved rule, made more likely by how the script runs its jobs. They are not a
layout cost.**

- **The CPU stays flat.** On the CPU, a starved tick is the same size as an ordinary one: 0.01–0.16 s, against a
  median of 0.06–0.07 s. What grows is the time off the CPU.
- **They come six at a time.** Starved runs arrive in whole `-j 6` batches: runs 1–6 or 7–12 of a case, all at the
  same moment. That moment is one where all six processes do the same thing: page 2 at t=11–15 s, or the launch and
  first open at t=1 s of the reruns, which also start together.
- **They need load.** On this Mac, six bench main threads, plus their render threads, plus the 5–10 load already on
  the Mac fill the 6 performance cores.
- **They followed the external load.** 24 of the first matrix's 35 runs that were recorded starved were in four cases
  where something outside pushed the load past 12. Rerun with the load under 12, those cases had no starved run
  (60 runs). The 11 that remain came at loads of 9.6–10.5.

This measurement can't tell a thread waiting for a core from one blocked on something else (WindowServer, a lock):
the rule counts both as the Mac's. It doesn't hide a layout regression, because a tick the layout works through over
0.25 s on the CPU fails whether or not it's starved.

**Proposed follow-ups** (none made in this task):

1. Stagger the job starts in `chat-bench-settle.sh` (a short offset per job slot), so six runs don't reach page 2 or
   the first open in the same instant. That should remove most starved first attempts without loosening the rule.
2. Have the bench record why the main thread was off the CPU in its longest tick (involuntary context switches from
   `getrusage`/`thread_info` against the tick), so a starved run is told apart from a blocked one.

## The regression command

```
bash scripts/chat-bench-settle.sh -n 12 -o "${TMPDIR:-/tmp}/chat-bench-settle" Tests/VibeSwitcherTests/Fixtures/chat-bench.jsonl Tests/VibeSwitcherTests/Fixtures/chat-bench.jsonl
```

- **Where it runs:** merge runs `regression_command` after `test_command` (`bash scripts/test.sh`), in the same
  rebased checkout, with HOME and TMPDIR in the merge's scratch home. The command relies on `.build/debug/VibeSwitcher`,
  which test.sh's `swift build` has just built in that checkout.
- **Where its output goes:** `-o` sends it to `$TMPDIR/chat-bench-settle`, which is in the merge's scratch home and
  never in the checkout. That folder is replaced on each run. `results.txt` has one line per run, and `out/` has each
  run's full output (`<scenario>-<width>-<variant>-<run>.txt`, plus `.starved` for a first attempt that was run
  again). The per-case summary (passed/12, heights, longest tick, most CPU) goes to stdout, so it lands in merge's
  output after the `--- regression_command (workflow.md) ---` marker.
- **Exit status:** 1 when any case passed fewer than 12 of 12 runs, otherwise 0.
- **Time:** about 37 min on a quiet Mac, plus test.sh (its suite alone took 174 s). Merge's single
  `test_timeout_min` (45 min by default, unset in workflow.md) covers both commands together, so it would need raising
  first (75 would leave room for starved reruns and a cold build).
- **Load:** merge waits only for the load to drop under load_threshold (24), not 12. Between 12 and 24 the bench still
  judges every tick by the strict rule, and starved runs get more frequent, as in the five over-gate attempts above.
  Those still passed 12/12, but this matrix measured nothing at a sustained load over 12.
