# VibeSwitcher runtime evaluation

## Summary

| Metric | Measured | Target for an AAA menu bar app | Verdict |
|---|---|---|---|
| Main-thread hangs during this evaluation | **1 live hang of ~13 min that never recovered**: the app process was gone between 16:39:12 and 16:39:27, quit from outside (from 16:26:14, 2 s after opening a 62-entry chat). The main thread spins at 55–105 % CPU in a SwiftUI layout transaction | 0 hangs > 250 ms | **FAIL** |
| App CPU with the window open on a live session (12.2 min before the hang, 10 s intervals) | mean **14.1 %**, p50 13.3 %, p95 24.1 %, min 8.4 %, max 28.8 % | ≤ 1 % idle, ≤ 5 % while showing a live terminal | **FAIL** |
| App CPU over the whole 12.9 min window (includes the start of the hang) | mean 18.4 %, max 106.5 % | as above | **FAIL** |
| Main thread busy outside the hang (`sample`, 10 s) | 12.2 % (1,029 of 8,439 ms): SwiftUI graph updates 434 ms, CA commit and drawing 325 ms (terminal draw 98 ms) | < 2 % | **FAIL** |
| App memory | RSS p50 153 MB, max 199 MB before the hang. Physical footprint 296 MB (peak 351 MB). **During the hang RSS swings between 324 and 731 MB** | footprint < 100 MB, stable | **FAIL** |
| Session host CPU | mean 0.3 %, max 0.6 % (11 sessions, 3 of them busy) | < 1 % | PASS |
| Session host memory | RSS 13–17 MB, footprint 42.5 MB (peak 54.8 MB) | < 50 MB | PASS |
| Threads | app 7–15, host 4 | bounded, < 30 | PASS |
| Open file descriptors | app 82–96 (no growth over 13 min), host 28 (constant) | stable | PASS |
| Sessions the app misses (`app-status.json` vs `--dump`, 12 snapshots over 6 min) | **1 of 11 missing the whole time** (ttys006). Root cause found: a poisoned argv cache | 0 | **FAIL** |
| Sessions misclassified | 1 (ttys000 "done" for 4 h 45 min although it never ran a turn) | 0 | **FAIL** |
| Hook latency, realistic payloads (n = 400) | p50 16.4 ms, p95 24.0 ms, p99 37.5 ms, max 44.3 ms (spawning `/usr/bin/true` costs 3.2 ms) | p50 < 10 ms, p95 < 25 ms | WARN |
| Hook latency, large prompt or last message | 100 KB: 85 ms. 1 MB: 0.8 s. 2 MB: 1.5–3.2 s. **5 MB: 9.7 s** | < 50 ms at any size | **FAIL** |
| Hook on empty or malformed input (14 cases) | always exit 0, no stdout, no crash; ~5 ms | exit 0, silent | PASS |
| `--chat-bench`, 3 largest transcripts (82–129 MB) × plain / LIVE / STACK | worst stall 0.10–0.26 s, first layout 0.10–0.15 s, RSS 104–121 MB | worst stall < 0.1 s | WARN |
| Hang watchdog (`VIBESWITCHER_BENCH_STALL=1`) | detects at 2.08 s, writes `hang-*.txt` + `.log`, logs "answered again after 4.0 s" | works | PASS |
| `osascript` processes spawned by the app | about 15/min for Terminal tabs and up to 10/min for screen text (4 s and 6 s cadence; every 1.5 s while Terminal is frontmost) | event-driven, ~0 when nothing changes | **FAIL** |

Measured on 2026-10-17, 16:13–16:40 CEST, against the installed app (`/Applications/VibeSwitcher.app`, app build
1792239825 = 14:23 today, which includes e992e0a; session host build 1792178869 = 2026-10-16 21:27). Machine: Mac15,7
(12 cores, 36 GB), macOS 15.7.3. The app (pid 33127) had been running for 1 h 50 min with its window open on a live
session and the sidebar enabled. 11 Claude sessions ran in `vibeswitcher-host` (pid 4086), three of them evaluation
workers that were busy the whole time. Nothing was reinstalled, relaunched, killed or reconfigured. No input went to
any session. Raw data, scripts and trimmed stacks are in [`runtime-data/`](runtime-data/).

The session host is lean and stable. The app is not: it hangs, misses sessions, and burns roughly a seventh of a
core while doing nothing the user can see.

## Findings

Severity: P0 = crash, data loss or security. P1 = broken behaviour. P2 = slow or wasteful. P3 = polish.

### R1 (P1). Opening a chat hung the main thread for ~13 minutes until the app was quit; CPU 55–105 %, RSS up to 731 MB

**Evidence.** `~/.vibeswitcher/debug/app.log`:

```
16:26:12.594 chat: show 6d824633-….jsonl
16:26:12.686 chat: loaded 62 entries, 30 items from 6d824633-….jsonl
16:26:16.423 main thread stuck since 2026-10-17 14:26:14 +0000; sampling into hang-20261017-162614.txt
```

It never logged "answered again": the process was gone between 16:39:12 and 16:39:27. It was quit from outside, not by this evaluation, after about 13 minutes stuck; the per-15 s trace is in
[`runtime-data/hang-watch.txt`](runtime-data/hang-watch.txt). The watchdog's state dump
([`hang-20261017-162614.log`](runtime-data/hang-20261017-162614.log)) shows: window key and visible at 1728×1014,
`showsChat=true terminalHidden=true`, chat `state=ready entries=62 items=30 shownLimit=120 atBottom=false`.
**This is a recurrence.** The earlier investigation of today's hang records found exactly one real freeze, at
10:21 on an older build, and called its cause a "chat layout storm" that is still unexplained. It concluded that
"since 10:48 the main thread hasn't been stuck for over 2 seconds". That held until 16:26 on the current build
(1792239825, which includes the e992e0a watchdog fix), so the storm survived the hang fixes. The 10:21 record
predates the oldest line in today's `app.log` (10:47:58) and was not seen directly by this evaluation.
CPU went from 13 % to 106 % in the 16:26:30 sample. RSS moved 146 → 275 → 308 MB, then swung between 324 and
731 MB: something is allocating and freeing furiously in a loop.

My own `sample` taken 70 s into the hang ([`runtime-data/sample-hang-main.txt`](runtime-data/sample-hang-main.txt))
shows all 4,243 of 4,243 main-thread samples inside one SwiftUI transaction:

```
CFRunLoopRunSpecific → __CFRunLoopDoObservers → NSRunLoop.addObserver closure (SwiftUICore)
 → GraphDelegate.beginTransaction → ViewGraphDelegate.updateGraph → GraphHost.runTransaction   3941
   → AG::Subgraph::update → AG::Graph::UpdateStack::update                                       3460
     → LazySubviewPlacements.updateValue → LazyStack.place → StackPlacement.place                 969
         → ForEachList.applyNodes → … ModifiedViewList.applyNodes (×4) …
     → RootGeometry.value → StackLayout.sizeThatFits → prioritize → insertionSort
         → ScrollViewLayoutComputer.Engine.sizeThatFits → _FlexFrameLayout.sizeThatFits (nested)  715
```

The main thread never returns to the run loop, so it is a layout/graph-update feedback loop, not a single slow
call. Sessions in the window kept running because they live in `vibeswitcher-host`. Everything else froze: the
menu bar, the sidebar, notifications, and `app-status.json`, which last changed at 14:26:01Z (16:26:01 local).

**Not reproduced offscreen.** `--chat-bench` on the same transcript (plain / STACK / LIVE) ran clean: worst stall
0.11 s, 29 items. The bench differs from the real window: its width is fixed at 900/640/1100, it has no restored
reading anchor, no inspector or sidebar, and no live session row. One bench signal does point at layout
instability: for the same 19 items the bench reported a content height anywhere from **409 to 7,765 px** between
ticks (t1-plain), and 470 to 12,104 px with LIVE. A `LazyVStack` whose height estimate swings like that is a
classic ingredient of a scroll/placement feedback loop.

**Direction.**
1. Reproduce with the bench at the real geometry: 1728 px wide, chat opened scrolled up, so the
   `restoreAnchor`/`scrollTo(anchor, .top)` path in `ChatView` runs (`atBottom=false`). Add a bench switch for
   "open at a restored anchor".
2. Look for size feedback inside the `ScrollView`/`LazyVStack`. Suspects: rows using
   `.fixedSize(horizontal: false, vertical: true)` inside flexible frames (`.frame(maxWidth: 900)` then
   `.frame(maxWidth: .infinity)`), and the "bottom" sentinel whose `onAppear`/`onDisappear` flips `@State atBottom`.
3. As a safety net, the watchdog could record a "stuck > 60 s" breadcrumb and offer a
   relaunch-and-reopen-without-chat recovery on the next launch.

### R2 (P1). The app misses sessions whose argv it read before `exec`: ttys006 was missing for ≥ 13 minutes

**Evidence.** In 12 snapshots, 30 s apart from 16:20:06 to 16:25:39
([`runtime-data/statuscmp.txt`](runtime-data/statuscmp.txt)), `--dump` listed 11 sessions and
`app-status.json` listed 10. **ttys006 (claude pid 46336, the UX evaluation worker, started 16:13:05) was always
missing**, even though `app-status.json` was rewritten six times in that span. The watchdog's state dump at 16:26
agrees: `host … sessions=16 live=11`, `scanned sessions=10`. The session was healthy the whole time; its hook
state file `state/ttys006.json` was updated at 16:17.

**Root cause, from reading the code.** On a Claude process the kernel `p_comm` is the version (`ps -o ucomm`
prints `2.1.302` for all four workers). `ProcessTable.makeInfo` therefore identifies the agent from argv[0] via
`ProcessTable.arguments(pid:start:)`, which caches **per (pid, start-second)**. The host starts every session as
`vibeswitcher-host --pty-exec PROGRAM …`, which then `execv`s Claude. `exec` keeps the pid and the start time
(see `PTYSpawn.swift`: "execs the program, which keeps its process id"). If the 2 s scan runs in the short window
after the launcher has its TTY and before it execs, it caches argv `[vibeswitcher-host, --pty-exec, …]` for that
(pid, start). That key never changes, so the process is classified "not an agent" for the rest of its life. A
fresh process (`--dump`) has an empty cache, which is why it sees the session. The window is narrow, so this
would strike more often when sessions start in bursts (a lead launching workers), exactly as it did here.

**Direction.** Don't cache a negative or launcher result: skip caching when argv[0] is the host launcher or
`--pty-exec` is present. Or key the cache on something that changes at exec, for example `p_comm` together with
pid and start. `cwdCache`/`projectCache` in `SessionScanner` are keyed on pid alone and have the same pre-exec
exposure (the cwd is read once). Add a test that feeds a launcher argv and then a claude argv for the same
(pid, start).

### R3 (P2). About 14 % CPU and ~12 % main-thread time spent "doing nothing" with the window open

**Evidence.** In 74 samples from 16:13:50 to 16:26:10 ([`runtime-data/samples.csv`](runtime-data/samples.csv),
[`runtime-data/app-series.txt`](runtime-data/app-series.txt)), CPU never went below 8.4 % and averaged 14.1 %.
`top` 1 s readings p50 was 7.3 %. The 10 s `sample`
([`runtime-data/sample-prehang-main.txt`](runtime-data/sample-prehang-main.txt)) puts the main thread at 87.8 %
idle. Its busy time was:

- SwiftUI graph updates from the run-loop observer: 434 ms per 10 s. Something publishes state every tick. Likely sources:
  the 2 s `SessionStore.refresh`, which assigns `sessions` whenever any field differs, ageing detail strings
  included; the 1 s chat timer; and the 1 s watchdog snapshot.
- Core Animation commit and display: 325 ms, of which `TerminalView.draw` was 98 ms and Auto Layout
  (`layoutSubtreeIfNeeded`, deep recursion) 76 ms.
- `_doUpdateTilingConstraintsImmediately` / `minFullScreenContentSize`: 18 ms. This is window constraint work on
  every pass.

The app keeps at least these wake-ups running permanently: watchdog beat at 4 Hz, watchdog state snapshot and
breadcrumb flush at 1 Hz (`describeState()` runs on the main thread every second), session scan at 0.5 Hz, menu-bar
visibility check at 0.5 Hz, lead board at 0.33 Hz, chat poll at 1 Hz while a chat is shown, and the sidebar poll at
5 Hz (R7). Together these prevent App Nap and idle.

**Direction.** Profile one minute in Instruments (SwiftUI + Time Profiler) to see which `@Published` writes
invalidate the sidebar, inspector and window. Assign `sessions` only when something the UI shows changes, and
keep ticking timers in a leaf view. Coalesce the timers: one 1 Hz tick when a window is visible, slower or none
when not. Let the watchdog beat on a `DispatchSourceTimer` with leeway, and skip `describeState()` when nothing
changed. Measure the menu-bar-only state, with the window closed, separately; the evaluation could not close
the window without touching the user's app.

### R4 (P2). The hook redacts the whole prompt or last message before clipping it, so a large paste blocks the agent for seconds

**Evidence.** [`runtime-data/hookscale.txt`](runtime-data/hookscale.txt), HOME and `CFFIXED_USER_HOME` pointed at
a temp dir:

| payload size | UserPromptSubmit `prompt` | Stop `last_assistant_message` | PostToolUse `tool_response` | PreToolUse Write `content` |
|---|---|---|---|---|
| 10 KB | 20.6 ms | 16.2 ms | 7.1 ms | 8.7 ms |
| 100 KB | 85.4 ms | 86.0 ms | 7.5 ms | 8.9 ms |
| 1 MB | 784 ms | 820 ms | 15.5 ms | 16.5 ms |
| 2 MB | 1,544 ms | 3,234 ms | 44.9 ms | 40.6 ms |
| 5 MB | **9,726 ms** | | | |

`HookState.clip` runs `Redaction.secrets(in:)`, which applies 13 regexes, over the entire text and only then cuts
it to 280 characters. This happens while the hook holds the state file's `flock`, and Claude Code waits for
`UserPromptSubmit` and `Stop` hooks. A pasted log of a few hundred KB already adds a visible delay to every
submit, and parallel hooks on the same TTY queue behind the lock.

**Direction.** Clip first, to the first ~4 × limit characters, before flattening and redacting, then clip again
to the limit. Keep a small overlap so a secret straddling the cut is still masked. Also check
`SessionNaming.isSystemPrompt` for full-text scans. Add a test that a 5 MB prompt reduces in < 20 ms.

### R5 (P2). ttys000 has been "done" for 4 h 45 min, but it never ran a turn

**Evidence.** In every snapshot, `app-status.json` shows `ttys000 claude done hooks=false`, and `--dump` shows
`no hooks`. This Claude (pid 85757) was started by the host at 11:48:38 (`host: spawn Claude in
genlayer-website`) and its project folder `~/.claude/projects/-Users-albert-dev-genlayer-site-genlayer-website/`
has **no transcript at all**. It has never fired a hook, so it is most likely sitting at the folder-trust prompt
or an empty input. "Done" means "a finished turn you haven't seen", which is wrong here. If it is the trust
prompt, it should be "needs input".

**Direction.** Without hooks, a title-only status of "done" should require an observed busy→idle transition. A
session that has never been seen busy is "idle". If `TrustPrompt` detection applies to hosted sessions, run it
here and surface "needs input".

### R6 (P2). Terminal is polled through `osascript` processes every 1.5–6 s

**Evidence.** `SessionStore.refresh` calls `TerminalBridge.tabs()` every 4 s, or every 1.5 s while Terminal is
frontmost. It calls `TerminalBridge.screens(for:)` every 6 s while any Claude session is quiet. Each call
spawns `/usr/bin/osascript` (`TerminalBridge.runAppleScript`). In the 10 s `sample`, the `vibeswitcher.scan`
queue spent 318 ms blocked reading `osascript` output or waiting for it to exit. That cost is in the
child process and in Terminal, not counted in the app's CPU above. A bare `osascript -e 'return 1'` alone costs
about 20 ms of CPU; the real scripts do more and make Terminal answer Apple Events. All 11 current sessions are
hosted, so in this configuration the polling buys nothing.

**Direction.** Skip both queries when no session lives in Terminal.app (the process table already says where
each TTY's parent is). Otherwise run the scripts in-process with a cached compiled `NSAppleScript`/`OSAKit`
(no fork/exec), and query only when the process table or hook state changed, instead of on a clock.

### R7 (P2). Sidebar mode polls the mouse at 5 Hz forever and listens to every mouse move system-wide

**Evidence.** `sidebar-debug.json`: `polls: 3000, totalPolls: 32117, gapMedian 0.200 s`. In `Sidebar.swift`,
enabling the sidebar adds a global `.mouseMoved`/`.leftMouseDragged` monitor **and** a 0.2 s repeating timer.
That wakes the app at least 5 times a second, plus once per mouse event anywhere on screen.

**Direction.** Use a tracking area or a thin always-on-top edge panel, which gives an `NSTrackingArea` enter
event, instead of polling. If a global monitor is needed, drop the timer, or run it only while the pointer is
within some distance of the edge.

### R8 (P2). Memory footprint is 3× what a menu bar app should use

**Evidence.** `vmmap --summary` at 16:14 ([`runtime-data/vmmap-app.txt`](runtime-data/vmmap-app.txt)): physical
footprint 295.8 MB, peak 350.8 MB. The largest contributors are "owned unmapped memory" (106.5 MB dirty, typically
GPU/IOSurface backing for the window and terminal views), MALLOC_SMALL 18.3 MB, MALLOC_NANO 18.2 M, and
MALLOC_LARGE (empty) 26.8 MB swapped. For comparison, the session host is at 42.5 MB with 11 sessions, and a
`--chat-bench` process is at 53–70 MB.

**Direction.** Release terminal views (and their layers) for sessions that aren't attached; the hang log shows
`attached terminals=3`. Check whether hidden terminals (`pane.view.isHidden`) still hold full-size backing
surfaces. Re-measure with the window closed.

### R9 (P3). Hang records were deleted by hand, so only the app.log lines remain

**Evidence.** `app.log` names seven hang reports before this session:

| when (local) | length | notes |
|---|---|---|
| 10:48:45 | 4.0 s | induced by `--chat-bench` with `VIBESWITCHER_BENCH_STALL=1` (logged "bench: blocking the main thread for 4 s") |
| 12:23:20 | 898.6 s | false: process suspended (sleep or App Nap), fixed by e992e0a |
| 12:39:06 | 898.3 s | false, as above |
| 12:54:50 | 898.6 s | false, as above |
| 13:10:35 | 553.0 s | false, as above (the ~15 min pattern) |
| 13:24:03 | 5.8 s | ambiguous: the main thread was already idle when sampled, so it can't be told apart from a short nap |
| 13:59:40 | 899.1 s | false, as above |

According to the investigation behind e992e0a, all six non-bench records were false or unprovable. The five
~15-min ones were only noticed at their end: the 4 Hz checker had been frozen too, so the whole process had been
suspended. The 13:24 one had an idle main thread by the time it was sampled. All six showed the same state: window
open but not key, a vibeswitcher terminal selected, chat off, so nothing was being drawn. The six files were then
deleted on purpose so they wouldn't mislead; only their `app.log` lines remain, and this evaluation could not
re-check them. Since the fixed build launched at 14:23:46 there were no false reports. The next record, 16:26
(R1), is real. Other details:

- **The watchdog cannot tell a short nap from a short real stall.** The 13:24 record shows that a 2–6 s stall with
  an idle main thread at sampling time stays ambiguous, and the e992e0a fix only handles the case where the checker
  itself was frozen.

- The `.txt`/`.log` hang files are created 0644, while `app.log` is 0600 and the folder is 0700.
- The "stuck since" time is written in UTC (`14:26:14 +0000`) next to local-time breadcrumbs (`16:26:16.423`).

**Direction.** Put a one-line summary of the hung main-thread stack (the top app frame and the deepest
recognisable system frame) into `app.log` itself, so the evidence survives cleanup. Write hang files 0600. Print
the "since" time in local `HH:mm:ss`.

### R10 (P3). The hook ignores `$HOME`, so isolated testing needs `CFFIXED_USER_HOME`

**Evidence.** `VibePaths.root` uses `NSHomeDirectory()`. A one-line Swift probe printed `/Users/albert` with
`HOME=/tmp/x` and printed the fake path only with `CFFIXED_USER_HOME` set. So running
`HOME=$tmp vibeswitcher-hook` as the README's debugging advice implies **writes to the real
`~/.vibeswitcher/state/<tty>.json` of the calling session**. This evaluation set both variables, checked that the
first call wrote into the temp dir, and only then started the benchmark.

**Direction.** Resolve the root from `ProcessInfo.environment["HOME"]` first, falling back to
`NSHomeDirectory()`, or add `VIBESWITCHER_HOME`. That also makes `--chat-bench`'s `TranscriptReader.checkedURL`
home check testable.

### R11 (P3). Small hook and state hygiene items

- An unknown `hook_event_name` (`"Bogus"`) is written as `lastEvent`, replacing the real last event. A new Claude
  event type would do the same and could confuse `StatusRules.resolve`. Ignore unknown events, or keep the
  previous `lastEvent`. ([`runtime-data/hookbench.txt`](runtime-data/hookbench.txt), "unknown event": state
  size changed 1155 → 1157.)
- `state/` holds 9 orphaned `ttysNNN.json.lock` files (oldest Oct 3) with no matching `.json`; only the `.json` files are pruned.
  Remove the lock together with its state file.
- Benign edge cases all held up: empty stdin, whitespace, truncated JSON, an array, a string, binary garbage,
  wrong types, 100k-deep nesting (6 ms, no crash), and a 5 KB `transcript_path` (ignored, as intended). All
  exited 0 with no stdout.
- The session host reports `outdated(live: 8, compatible: true)`: it is running yesterday's binary, because it
  can't restart without ending sessions. Host fixes don't reach a running setup until every session ends. Consider
  showing "host update pending" and offering a handover at a quiet moment.

### R12 (P3). `--chat-bench` doesn't exercise the paths that hang or cost the most

**Evidence.** The 3 largest transcripts (129 MB / 11,958 lines, 108 MB / 8,506 lines, 82 MB / 10,950 lines)
load only their newest tail: **19, 89 and 184 items**. Worst stalls were 0.10–0.26 s
([`runtime-data/chatbench/`](runtime-data/chatbench/)):

| transcript | mode | items | first tick stall | worst stall | max resize | max scroll | CPU over 15 s | max RSS / footprint |
|---|---|---|---|---|---|---|---|---|
| 1 (129 MB) | plain | 19 | 0.15 s | 0.15 s | 0.04 s | 0.02 s | 0.7 s | 110 / 56 MB |
| 1 | LIVE | 19 | 0.12 s | 0.12 s | 0.01 s | 0.04 s | 0.7 s | 117 / 61 MB |
| 1 | STACK | 19 | 0.12 s | 0.12 s | 0.04 s | 0.02 s | 0.7 s | 114 / 60 MB |
| 2 (108 MB) | plain | 89 | 0.12 s | **0.26 s** | 0.14 s | 0.10 s | 1.2 s | 115 / 65 MB |
| 2 | LIVE | 89 | 0.13 s | 0.13 s | 0.02 s | 0.05 s | 1.1 s | 121 / 70 MB |
| 2 | STACK | 89 | 0.13 s | 0.13 s | 0.02 s | 0.04 s | 1.1 s | 111 / 62 MB |
| 3 (82 MB) | plain | 184 | 0.12 s | 0.12 s | 0.04 s | 0.04 s | 1.1 s | 104 / 53 MB |
| 3 | LIVE | 184 | 0.11 s | 0.11 s | 0.04 s | 0.09 s | 1.1 s | 108 / 56 MB |
| 3 | STACK | 184 | 0.10 s | 0.10 s | 0.05 s | 0.04 s | 1.1 s | 105 / 54 MB |
| R1's transcript (3 MB, live) | plain / STACK / LIVE | 29 | 0.09–0.11 s | 0.08–0.11 s | ≤ 0.01 s | ≤ 0.01 s | 0.5–0.6 s | 82–84 MB |

The tail-only loading works: file size doesn't drive layout cost. The bench never pages back ("Load earlier",
"Show N earlier"), never restores a reading anchor, and runs at fixed widths. That is why it is green while the
real window hung (R1). The 0.10–0.15 s first layout is above one 60 Hz frame, but it happens once, at open.

**Direction.** Add bench modes for "load earlier ×3", "open at restored anchor" and "real window width with
inspector". Fail the bench when a tick's stall exceeds 0.25 s or when the content height for an unchanged item
list varies by more than 2×.

### Observations that are not findings

- ttys014 has shown "background" for 4.8 h because a `python3 -` it started 14 h 46 min ago is still running, and
  ttys012 because of `npx next start -p 3000`. Both are correct by the rules: work really is running. A
  "running for > N h" hint might help the user notice a forgotten process.
- ttys004 (this evaluation) showed "background" while its sampler ran, also correct.
- The session host stayed flat (0.1–0.6 % CPU, 13–17 MB RSS, 4 threads, 28 fds) through 3 busy sessions and the
  app's hang. Separating sessions into their own process is the reason sessions survived R1.

## Top 10 to fix first

1. **R1 (P1)**: the chat layout loop that hung the app for ~13 min, until it was quit, at 55–105 % CPU and up to 731 MB. Reproduce at
   the real window geometry with a restored anchor, then break the feedback loop.
2. **R2 (P1)**: the argv cache poisoned before `exec`, which hides a whole session for its lifetime. A one-line
   cache rule plus a test.
3. **R3 (P2)**: 14 % steady CPU and 12 % main-thread time with nothing changing. Stop republishing `sessions`
   and coalesce the timers.
4. **R4 (P2)**: hook latency grows with prompt size (1 MB → 0.8 s, 5 MB → 9.7 s) while holding the state lock.
   Clip before redacting.
5. **R5 (P2)**: a never-used session reported as "done" for hours. Require an observed busy→idle transition.
6. **R6 (P2)**: `osascript` fork/exec every 1.5–6 s even when no session is in Terminal.app.
7. **R7 (P2)**: the sidebar's 5 Hz poll plus a global mouse monitor. Use tracking areas.
8. **R8 (P2)**: 296 MB footprint. Release backing surfaces for detached or hidden terminals, and measure with
   the window closed.
9. **R9 + R12 (P3)**: keep a stack summary in `app.log` so records survive cleanup, and make `--chat-bench`
   cover the paths that actually hang.
10. **R10 + R11 (P3)**: make the hook honour `$HOME`, ignore unknown events, and prune lock files.

## Appendix A: method

- **CPU / RSS / threads / fds:** [`runtime-data/scripts/sample.sh`](runtime-data/scripts/sample.sh), every 10 s
  from 16:13:52 to 16:26:50 (78 samples per process). CPU% per interval comes from the difference in `ps -o time`
  (cumulative CPU) over wall time, which counts every thread. `top -l 2 -s 1` gives a 1 s instantaneous reading
  for comparison. RSS comes from `ps -o rss`, threads from `ps -M | wc -l`, and fds from `lsof -p | wc -l`.
  "Normal use": the user switched window sessions at 16:19:39 and 16:19:49 and opened a chat at 16:26:12, while
  three worker sessions ran tools continuously. Raw rows are in
  [`runtime-data/samples.csv`](runtime-data/samples.csv) and the per-interval series in
  [`runtime-data/app-series.txt`](runtime-data/app-series.txt).
- **Where the time goes:** `sample 33127 10` (16:14, before the hang), `sample 33127 5` (16:27, during the hang),
  `sample 4086 5`, and `vmmap --summary` for both. These are trimmed to the relevant threads in
  `runtime-data/sample-*.txt` and `vmmap-*.txt`. `leaks` was not run: it suspends the target, and from 16:26 the
  target was already hung.
- **Hang trace:** `ps` plus `top` on pid 33127 every 15 s until recovery or 25 min:
  [`runtime-data/hang-watch.txt`](runtime-data/hang-watch.txt).
- **Hook:** [`runtime-data/scripts/hookbench.py`](runtime-data/scripts/hookbench.py), 400 invocations cycling
  through SessionStart, UserPromptSubmit, PreToolUse ×2, PostToolUse, PermissionRequest, Notification and Stop.
  The payloads use the shapes Claude Code sends: session_id, transcript_path, cwd, tool_input, a 4 KB
  tool_response and a 280-char message. Each call is timed as wall time around `subprocess.run`.
  `HOME` **and** `CFFIXED_USER_HOME` point at a fresh temp dir (see R10), and the script aborts unless the first
  call's state file lands there. Then come 14 empty/malformed cases, and
  [`hookscale.py`](runtime-data/scripts/hookscale.py) for 10 KB–2 MB fields. Results are in
  [`hookbench.txt`](runtime-data/hookbench.txt) and [`hookscale.txt`](runtime-data/hookscale.txt).
- **Chat bench:** [`runtime-data/scripts/chatbench.sh`](runtime-data/scripts/chatbench.sh) ran the installed
  binary's `--chat-bench` on the 3 largest `~/.claude/projects/**/*.jsonl` (read-only), each plain, with
  `VIBESWITCHER_BENCH_LIVE=1` and with `VIBESWITCHER_BENCH_STACK=1`, under `/usr/bin/time -l`. The bench must run
  with the real home, because its transcript check rejects paths outside `NSHomeDirectory()`. The
  `VIBESWITCHER_BENCH_STALL=1` run used `CFFIXED_USER_HOME` so its hang files went to a temp dir (its chat then
  shows "No conversation", which doesn't matter for the watchdog check). Outputs are in
  [`runtime-data/chatbench/`](runtime-data/chatbench/). Most runs happened while the hung app occupied about one
  core, out of 12.
- **Status cross-check:** [`runtime-data/scripts/statuscmp.py`](runtime-data/scripts/statuscmp.py), 12 rounds 30 s
  apart, parsing `--dump` (TTY, agent, pid, last hook event and age, background shells) against
  `app-status.json`. Output: [`runtime-data/statuscmp.txt`](runtime-data/statuscmp.txt).

## Appendix B: raw CPU / RSS series (VibeSwitcher, 20 s excerpt; every 10 s row is in `app-series.txt`)

```
16:14:08 cpu= 15.5% rss=151MB th=8 fds=86      16:20:28 cpu= 27.0% rss=160MB th=8 fds=86
16:14:48 cpu= 11.1% rss=153MB th=9 fds=90      16:21:08 cpu= 10.7% rss=146MB th=9 fds=86
16:15:28 cpu= 12.0% rss=154MB th=8 fds=84      16:21:49 cpu=  8.9% rss=150MB th=8 fds=92
16:16:08 cpu= 17.1% rss=149MB th=8 fds=84      16:22:29 cpu= 10.6% rss=153MB th=8 fds=86
16:16:48 cpu= 10.7% rss=147MB th=9 fds=90      16:23:09 cpu= 13.4% rss=148MB th=8 fds=86
16:17:28 cpu= 22.5% rss=148MB th=9 fds=86      16:23:50 cpu= 16.9% rss=148MB th=8 fds=92
16:18:08 cpu=  9.5% rss=155MB th=9 fds=86      16:24:30 cpu=  9.4% rss=156MB th=10 fds=84
16:18:48 cpu= 15.0% rss=156MB th=9 fds=90      16:25:10 cpu= 10.0% rss=144MB th=10 fds=86
16:19:28 cpu= 14.2% rss=147MB th=8 fds=86      16:25:50 cpu= 12.1% rss=146MB th=9 fds=90
16:20:08 cpu= 24.9% rss=157MB th=8 fds=86      16:26:10 cpu= 16.5% rss=176MB th=15 fds=86   ← chat opened 16:26:12
                                               16:26:30 cpu=106.5% rss=275MB th=7 fds=82   ← hung since 16:26:14
                                               16:26:50 cpu=105.2% rss=308MB th=7 fds=82
```

vibeswitcher-host over the same window: CPU 0.1–0.6 % (mean 0.3 %), RSS 13–17 MB, 4 threads, 28 fds in every
sample.
