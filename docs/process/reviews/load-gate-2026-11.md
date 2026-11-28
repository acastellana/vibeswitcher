# The Mac's load gate, 2026-11: a backtest of better rules against the recorded samples

**Recommendation: build rule (cI).** Keep today's max(1-minute, 5-minute) unless nothing of ours runs: no worker or
verifier in any project and no build or test holding a heavy slot. Then the gate reads the 1-minute alone. **What
changes for you:** after a restart like this morning's, the first start goes through once the last minute's load is
under the limit (11:09 instead of 11:19). That is 9 minutes refused instead of 15, in two parts: 11:04–11:08, and
11:14–11:17 while a heavy slot was held. Once a worker runs, later starts wait for the 5-minute as today. On a day
without a restart about 0 minutes come back. **What risk is taken:** in the replay, none. It gave back 6 minutes and no
overload followed any of them. Leads and your own sessions aren't counted, so a build of theirs run outside a slot
could still pause and open room. **The main finding:** the formula is not what holds work back. Over 10 days of samples the gate refused 116 minutes a day. At 96% of those minutes a build or test held a heavy
slot, and at 73% the 1-minute itself was over the limit: the Mac really was busy, mostly with our own builds and tests.
The bigger lever is the third heavy slot (see [What the numbers say](#what-the-numbers-say)). That is not this rule.

Written by a worker (task the-mac-s-load) on 2026-11-27. It is a replay of recorded data: the replay generated no load,
ran no bench and changed no code in Sources/. Reproduce it with
`python3 -I scripts/load-gate-backtest.py --top --until 2026-11-27T11:28` (the data as this review saw it)
([the script](../../../scripts/load-gate-backtest.py)). Its arithmetic is checked on a hand-made fixture
([scripts/fixtures/load-gate](../../../scripts/fixtures/load-gate)) by `python3 -I scripts/load-gate-backtest.py --selftest`.

## What was replayed

- **Data:** ~/.vibeswitcher/stats/load-2026-11-14.jsonl through load-2026-11-27.jsonl (to 11:27). That is 14,364
  samples covering 239.9 hours: 10.0 days of samples across 13.5 calendar days, the rest being sleep. Of those hours,
  204 were boosted. Beside them, merges-*.jsonl holds 493 merge lines. Counting a batch's shared test run once, that is 467 runs: 450
  ran their tests and 37 of those failed their first run, reran or hung. The recorder writes a first run that hung with
  no first_run field, and the replay counts those 4 runs as run and bad. A run cancelled before any rerun has no
  verdict and isn't counted as run. The recorder keeps 14 days (`LoadStats.keepDays`), so **neither 2026-10-19 nor 2026-10-28 17:38 is in
  the files**. The 10-28 shape (a dip of the 1-minute under the threshold while a heavy slot is held and the 5-minute
  is high) is rebuilt by hand in the fixture.
- **Threshold in force (T):** 36 when the sample says boost, otherwise 2 × cores = 24. mac-limits.json lies outside
  stats/ and wasn't read. A load_threshold set there would be missed, and `--threshold` overrides the default.
- **Refused:** the minutes at which the rule says "no room". Refusals themselves are not recorded (the daily
  stats/YYYY-MM-DD.json files hold only session time). So this is the time a start *would* have been refused: an
  upper bound on the time actually lost. Each sample stands for the gap to the next one, capped at 2 minutes, and for 1
  minute before a sleep.
- **Idle:** no worker or verifier session in any project (leads aren't counted, as in `MacLoad.count`) and no heavy
  slot held. **Free:** no heavy slot held and the 1-minute at or under T.
- **Overload:** the 1-minute over 2 × T in force (72 boosted, 48 otherwise). Every row uses this same line, so row (f)
  can't grade itself leniently.
- **False room (load):** the rule says room, and an overload is sampled within the next 5 minutes. A window that
  crosses a sleep counts as unknown, not as safe: 326 of rule (a)'s moments were left out this way.
  **False room (merge):** the rule says room, and within the next 5 minutes a merge's tests start and then fail their
  first run, rerun or hang. **New:** the false-room moments at which today's rule refused. Only these are a risk the
  candidate adds. The replay can't see the load that a start the candidate allows would have added. Neither can any
  replay of these files, because starts aren't recorded.
- **Boot:** the first sample after a sleep gap whose swap total is 0 MB when the sample before it had swap (macOS drops
  its swap files at a restart, not at a sleep). Only one boot is in the files: 11-27, first sampled at 11:04.

## The table

Minutes over the 10.0 days of samples, except "/day", which is per 24 hours of samples.

| Rule | What it says | Refused | /day | Idle | No team | Free | Longest idle | Back | FR load (runs, new) | FR merge (test runs, new) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- | --- |
| a | max(1, 5) ≤ T: **today, the baseline** | 1158 | 116 | 11 | 42 | 20 | 10 m, 11-27 11:04 | 0 | 301 (94, 0) | 148 (35, 0) |
| b | the 1-minute only | 846 | 85 | 5 | 22 | 0 | 5 m, 11-27 11:04 | 312 | 382 (121, **81**) | 163 (37, **15**) |
| c | (a), but the 5-minute ignored while idle or ≤ 30 min after boot (≤ 15 min: the same) | 1147 | 115 | 5 | 32 | 14 | 5 m, 11-27 11:04 | 11 | 301 (94, 0) | 148 (35, 0) |
| cG | (c), but the boot clause only while no heavy slot is held | 1152 | 115 | 5 | 36 | 14 | 5 m, 11-27 11:04 | 6 | 301 (94, 0) | 148 (35, 0) |
| cB | (a), but the 5-minute ignored ≤ 30 min after boot only | 1147 | 115 | 5 | 32 | 14 | 5 m | 11 | 301 (94, 0) | 148 (35, 0) |
| **cI** | **(a), but the 5-minute ignored while idle only: recommended** | 1152 | 115 | 5 | 36 | 14 | 5 m, 11-27 11:04 | 6 | 301 (94, 0) | 148 (35, 0) |
| d | committed: (a) while a heavy slot is held, otherwise the 1-minute (team sessions don't count) | 1138 | 114 | 5 | 36 | 0 | 5 m | 20 | 302 (94, 1) | 149 (35, 1) |
| d′ | (d), and no room while every heavy slot is held | 1880 | 188 | 5 | 36 | 0 | 5 m | 20 | 190 (72, 1) | 129 (29, 1) |
| k3 | the 1-minute ≤ T at every sample of the last 3 minutes | 1869 | 187 | 8 | 37 | 276 | 8 m | 52 | 253 (77, 8) | 130 (28, 0) |
| k5 | the same over 5 minutes | 2301 | 230 | 10 | 45 | 390 | 10 m | 14 | 207 (59, 1) | 126 (27, 0) |
| g | (a), but the 5-minute ignored once the 1-minute has stayed ≤ T/2 for 3 minutes | 1144 | 114 | 10 | 33 | 19 | 9 m | 14 | 301 (94, 0) | 148 (35, 0) |
| h | (g), and only while no heavy slot is held | 1156 | 116 | 10 | 41 | 19 | 9 m | 1 | 301 (94, 0) | 148 (35, 0) |
| f24 | max(1, 5) ≤ 24 always: 2 × cores | 1772 | 177 | 12 | 47 | 60 | 10 m | 0 | 196 (58, 0) | 126 (29, 0) |
| f36 | max(1, 5) ≤ 36 always: 3 × cores | 1086 | 109 | 11 | 42 | 15 | 10 m | 72 | 312 (96, 11) | 152 (35, 4) |
| e | real CPU use (idle share from host_processor_info ticks) | not judgeable: no CPU field is recorded (see [the CPU signal](#e-the-cpu-signal)) | | | | | | | | |

Columns: **Idle** is refused while idle. **No team** is refused with no team session (heavy slots may be held).
**Free** is refused while free. **Longest idle** is the longest stretch refused while idle. **Back** is the minutes of
room where (a) refused. **FR** is false-room moments, then (runs of consecutive moments or distinct test runs, new versus
(a)). A batched merge's tasks share one test run and count once.

Also printed by the script:

- **Merge load waits:** in 14 days only 2 merges waited for the load, 570 s in all. Rule (b) would have let them go
  after 302 s and rule (k3) after 514 s. Every other rule changes nothing for them.
- **Merge first runs that failed, reran or hung, by max(1, 5) at their start:** 20/318 (6%) under 12; 8/80 (10%) at 12–24;
  8/45 (18%) at 24–36; 1/4 at 36–72; 0/3 over 72 (a batch's run once).
- **The 1-minute load by heavy slots held:** 0 held, mean 4.5 (p90 6.6; 6,993 samples); 1 held, 9.7 (p90 16.1); 2 held,
  19.9 (p90 38.5); 3 held, **44.6 (p90 101.2; 1,088 samples)**.
- **Overload onsets:** 128. None of them followed 5 minutes with the Mac idle.
- **A "room again in N minutes" estimate:** N = 5 ln((five − one) / (T − one)). It covers the 301 moments when (a)
  refused on the 5-minute alone. The actual wait minus the estimate had a median of +0.3 min and a 10th–90th range of
  −3.0 to +6.2. It was within 2 minutes 63% of the time.

## What the numbers say

1. **Today's rule almost never refuses an idle Mac, except after a restart.** Idle time is rare in itself: 0.2 hours
   in 10 days, because some team session is nearly always open. All 11 idle minutes refused were on the morning of
   11-27, and so is the longest stretch, 10 minutes from 11:04. The "free" minutes (20) and "no team" minutes (42)
   are also small. Day by day, the refused minutes follow the heavy slots: 378 min on 11-18 with a slot held at 376 of
   them, 264 on 11-26 with 256, and 0 on 11-21, 11-22 and 11-24.
2. **The 5-minute earns its place.** Rule (b), the 1-minute alone, gives back 312 minutes (31 a day). But 81 of the 303
   given-back moments with a known window, **27%**, were followed within 5 minutes by an overload, and 15 by a merge
   whose tests failed. Among the moments when today's rule says room, 301 of 12,888 were (**2.3%**). A moment when the
   1-minute is under T but the 5-minute isn't is about 12 times likelier to precede an overload. That is the
   2026-10-28 failure, and it is common, not a one-off: max(1, 5) stays.
3. **Rules (c), (cG) and (cI) take back the restart and nothing else.** (c) gives back 11 minutes, all on 11-27:
   11:09–11:13, then 11:14–11:17, then 11:18. No new false room. But 11:14–11:17 is inside the boot window *with a
   heavy slot held*, which is exactly the shape the gate must not trust. A build that pauses between phases within 30
   minutes of a boot would open room under (c), just as 2026-10-28 did. (cG) applies the boot clause only while no
   heavy slot is held. It gives back 6 minutes (11:09–11:13 and 11:18), again with no new false room. **(cI)**, the
   idle clause alone, gives back the same 6 minutes with the same false room. **The boot clause adds nothing measured,
   so this report drops it.** Its only case beyond (cI)'s is team sessions open, no slot held and the 5-minute high
   within 30 minutes of a boot. No sample tests that case: on 11-27 the team sessions came back at 11:20, when the
   5-minute was already under 36. It is also the shape this report rejects (d) for (11-14 01:13, below): a build run
   outside a slot looks the same. What dropping it costs is unmeasured: after a restart, (cI) gives back the first
   start only, and the later ones wait for the 5-minute as today. The boot clause also needs an uptime signal and a
   30-minute window that one boot can't fit. (cB), the boot clause alone, matches (c).
4. **(d), the committed-work rule, buys 14 more minutes than (cI) for one new false-room moment on the load and one
   on merges.** It gives back 20 minutes. The
   extra ones are moments with team sessions open, no slot held, the 1-minute low and the 5-minute high (11-15 22:35,
   11-19 15:08–15:10, 11-26 08:57, and others). One of them, 11-14 01:13 (the 1-minute 3.9, the 5-minute 26.7, 2 team
   sessions, no slot held), was followed by an overload within 5 minutes. A worker's own build started outside a slot
   looks exactly like this. The data doesn't justify trusting team sessions to be idle.
5. **The waits on the 1-minute (k3, k5) catch some spikes but cost 70–115 minutes a day.** They cut false room from 301
   to 253 and 207. The variant (g) gives back 14 minutes for no new false room (its slot-guarded form, (h), only 1). But a 3-minute pause in our
   own build would fool it, which is the case the user's history rules out. It isn't recommended.
6. **(d′), no room while every heavy slot is held, is the strongest lever on overloads, in the other direction.** It
   cuts false room on the load from 301 to 190 and failing test runs from 35 to 29. The cost is 72 more minutes refused a
   day. The load by heavy slots held says why: the Mac averages 4.5 with no slot held, 9.7 with 1, 19.9 with 2, and
   44.6 with 3 (p90 101). The third slot, boost's heavy_slots 3, is where the overloads come from.
7. **(f), 2 × cores against 3 × cores.** Going from f24 to f36 gives back 686 minutes (69 a day). In exchange it allows
   116 more false-room moments on the load (196 → 312, 17% of the moments it gives back) and 26 more on merges (126 →
   152). Merge test runs started at max(1, 5) 24–36 failed, reran or hung on their first run 18% of the time (8 of 45),
   against 10% at 12–24 and 6% under 12. Today
   boost already runs at 36 for 85% of the sampled hours, so the 116 refused minutes a day are mostly against 36. This
   report recommends no threshold change. Raising the threshold buys time with merge failures, and the next task
   should not touch it.

## What macOS's load average counts that isn't contention for our work

Background, not from the samples and not verified for this report: the load average counts threads that are runnable
(running or waiting for a core), decayed with 1-, 5- and 15-minute time constants. It is not CPU use, and it doesn't
know whose threads they are. The samples show three ways it misleads the gate:

- **The restart.** The samples after the 11-27 restart (each line: the 1/5/15-minute load, then the top groups' CPU
  in percent of a core):
  - 11:04: 599/177/67, no team session, no slot held. CleanMyMac 251%, com.apple.Virtualization 213% (Docker's VM),
    Docker 146%, homed 54%, Chrome 40%.
  - 11:06: 507/317/137. The top 5 groups together use **0.3 cores**: Chrome 8%, CleanMyMac 7%, corespotlightd 7%.
  - 11:07: 193/262/129, at 0.8 cores.
  - 11:08: 73/214/120, at 0.3 cores.
  - 11:09: the 1-minute is 29, under 36, while the 5-minute is still 176.

  The 5-minute then decays by itself: 145, 119, 99, 82, 68, 56, 47, 39, 41 (at 11:18, when the 1-minute rose to 27),
  34 at 11:19. That's 10 minutes of refusals (11:09–11:18) caused by the restart's spike decaying while the 1-minute was
  under 36. Nothing of ours ran at 11:09–11:13 and 11:18. At 11:14–11:17 a heavy slot was held, though the 1-minute
  stayed at 4–5. The figure of 693 quoted from the gate's refusals came before the first sample at 11:04 and isn't in the
  files.
- **Load with little CPU behind it.** A sample names its top groups only when the 1-minute is over 48. Of the 562 that
  do, **492 show top groups using under half the cores**. This is a lower bound in two ways: it counts the top 5 groups
  only, and processes that exit within the sampling window (short compiler jobs) are missed. So it doesn't prove the
  cores were idle. Outside the restart's samples, the highest loads per core used are 52 at 0.3 cores (11-20 13:10), 204
  at 1.1 cores (11-27 10:30, before the restart) and 248 at 1.6 cores with 3 heavy slots held (11-26 10:23).
- **Other programs and system daemons.** Of the CPU the top groups name, 73% is in a project folder or a build or test
  tool, and 27% is everything else. The most often named outside a project are Chrome (368 samples, peak 524%),
  Virtualization (236, peak 256%), CleanMyMac (147, peak 284%), suggestd (48, peak 358%), corespotlightd (42),
  mediaanalysisd (14, peak 158%) and spotlightknowledged (10). Two games are also named: Steam (peak 413%) and Factorio
  (peak 466%). **Not supported by the samples:** that these daemons run at background QoS and yield the cores
  to our work. The samples record no QoS (a top group has command, leader, project, CPU and process count), so this
  is background knowledge, unverified here. **ANECompilerService at 98% of a core at 11:18 isn't in the samples:**
  the 11:18:57 sample's 1-minute was 27, under the 48 that names top groups.
- **Threads blocked on disk: not measurable here.** The samples record no disk or I/O field. Whether XNU's load
  average counts threads in an uninterruptible disk wait (Linux's does) wasn't verified for this report. Treat that
  claim as unverified either way.

## (e) The CPU signal

The recorded data can't judge a CPU-use rule. The only CPU figures are the top groups', taken above load 48, for 5
groups at most, with short-lived processes missed. A short passive measurement on this Mac at 11:30 today (`iostat -w 5`
beside `sysctl vm.loadavg`, 60 seconds; no load generated) read the CPU **0–7% idle** while the 1-minute load went from
18 to 40 and the 5-minute from 18 to 22. All of that was under the threshold of 36, while builds were running. So,
during our work, a CPU-idle rule would say "no room" *more* often than the load rule. It could only help in moments
like the restart, where the load is high and the CPU possibly isn't, and rule (cI) covers that while nothing of
ours runs. **The one extra
field that would make (e) judgeable:** `cpuIdle` in each LoadSample, the host's idle share over the minute since the
last sample, from `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas (a host call, not a look at any process).
Recorded for a week, it would let this script add the row.

## The rule, ready for a contract

**Signal.** The 1- and 5-minute load averages (`getloadavg`, as today). The host's census of team sessions across
every project (workers and verifiers; leads don't count, as in `MacLoad.count`). The heavy slots' holders
(`TestLock.holders()`).

**Rule (cI).** `steady` = the 1-minute alone if no heavy slot is held and no worker or verifier runs in any project.
Otherwise it is max(1-minute, 5-minute), as today. Room means `steady` ≤ load_threshold (unchanged: 2 × cores, 36
while boosted). Every input that can't be read counts toward waiting: an unreadable load means no room, and an
unreadable census or set of holders means "not idle", so max(1, 5). (Today `MacLoad.isBusy` and the
`steadyLoad().map { … } ?? false` call sites treat an unreadable load as room. The load was readable in every one of
the 14,364 samples, so failing toward waiting costs nothing.)

**Said to a person in one sentence:** "The Mac has room when its load is under the threshold, counting the last 5
minutes too unless nothing of ours runs: no worker, no verifier, no build or test holding a slot."

**One function, every caller.** `MacLoad.Averages.steady` sees two numbers only, so the shared seam is what has to
change: the rule becomes one function of the averages, the census and the holders (say
`MacLoad.roomLoad(_ averages:, census:, holders:) -> (load: Double, reason: Reason)?`). `LeadRuntime.steadyLoad()`
(LeadToolset.swift) and `MacLoad.steady()` (MacLoad.swift) both go through it, and no caller judges room by
`Averages.steady` alone afterwards. Each caller and where its census and holders come from:

- **start_worker** (`startWorkerAlone`), **audit** (`audit`), **a re-audit** (`startClaudeReaudit`) and **a team's
  members** (`LeadTeam.startMembers`): they already read the sessions for `macLoad(sessions, load:)`. They add the
  holders from `TestLock.standard()?.holders()`.
- **auto_advance** (LeadAdvance's `pass`, `resumeAfterSleep` and `hasRoom`) and **the pipeline's load hold**
  (`LeadPipelineWatch.pipelineSignals`): the same, from the lead's session listing and the holders.
- **merge's load wait** (`LeadToolset.waitForLoad`): today it reads `runtime.steadyLoad()` each poll and lists the
  sessions only for its timeout message. It lists them (`listed()`) and reads the holders each poll, and its progress
  and timeout texts drop "the greater of its 1- and 5-minute averages" for the load's reason.
- **The room watch** (`LeadController.lookAtRoom` in the app): it has the census (`host.sessions`, passed to
  `MacLoad.count`) but reads its load from `LeadController.macLoad`, today `MacLoad.steady` with no census or holders.
  It must read the holders (`TestLock.standard()?.holders()`, unreadable means not idle) and pass both through the one
  function, so that `RoomWaits.hasRoom`'s `mac.isBusy` judges the same load start_worker does. Otherwise a lead told
  "VibeSwitcher sends you one message once there's room again" after a restart waits for the 5-minute while
  start_worker would already allow the start. `macLoad`, faked in tests, becomes a closure that takes the census.
- **The Team view's line** (TeamViews.swift, `MacLoad.steady()` with the hosted sessions at hand): it reads the
  holders too and shows the same load and reason as the gates, so the line never says "busy" when a start would go
  through.
- **The remote fetch skip** (`LeadRemotePoller`) is not a room gate. It skips a remote fetch while the load is over
  the limit, reading `runtime.steadyLoad()`. It follows the same function, since it changes with `steadyLoad`, and
  needs no test of its own.
- **Unchanged:** TestLock and vs-heavy read only the 1-minute load, for a job's width and its stall watch, and
  StallWatch reads `MacLoad.oneMinute()`. None of them judges room.

**What the lead is told.**
- In a refusal on the 5-minute: "the Mac's load is 70 (its 5-minute average; the last minute's is 6), over
  load_threshold 36: room again in about 4 minutes" (5 ln(64 / 30) = 3.8, rounded up). The estimate is
  N = 5 ln((five − one) / (T − one)), said only when the 1-minute is under T and rounded up to whole minutes. In the
  replay it was within 2 minutes of the actual wait 63% of the time, with a median error of +0.3 min.
- When the clause applies, the load is shown with its reason: "load 6 (the last minute's: no worker or verifier runs
  and no build or test holds a slot)".
- The Team view's spoken line says the same: "the last minute's, since nothing of ours runs", or as today "the
  greater of the last minute's and the last 5 minutes'".

**Tests for that task.**
- The 11-27 restart as a fixture (no team session throughout, a slot held 11:14–11:17): room 11:09–11:13, refused
  11:14–11:17 (the 5-minute over 36), room from 11:18.
- The room watch on that fixture: the "room again" message goes out at the 11:09 look, the same minute start_worker
  allows the start. Nothing goes out at the 11:14 look, with a slot held.
- After a restart, with one worker started at 11:09: a second start at 11:10 is refused (the 5-minute 145).
- The 10-28 shape stays refused: a slot held, the 1-minute 20, the 5-minute 45.
- Team sessions open, no slot held, the 5-minute high: refused (the 11-14 01:13 shape).
- An unreadable load: refused. An unreadable census or set of holders: max(1, 5).
- The Team line and start_worker agree on the restart fixture.
- The estimate's arithmetic.
- `python3 -I scripts/load-gate-backtest.py` again afterwards: rule (cI)'s row is the new baseline.

## What was not measurable

- **The two incidents the rule must respect:** 2026-10-19 and 2026-10-28 17:38 are older than the recorder's 14 days.
  No candidate was tested against the real events, only against the fixture's reconstruction of 10-28.
- **The counterfactual:** a start a candidate allows adds load the replay can't see. "New false room" is the honest
  bound on the added risk, not a measurement of it.
- **Demand:** refusals and the starts that waited aren't recorded. Minutes refused is an upper bound on time lost. The
  only recorded demand is the merges' load waits: 2 merges, 570 s in 14 days.
- **More than one boot:** with a single restart in the data, the 15- and 30-minute boot windows of (c) and (cG) can't
  be told apart. The case where the boot clause would differ from (cI) (team sessions back before the 5-minute decays,
  no slot held) never occurs, so neither its gain nor its risk is measured. That is why (cI) drops it.
- **The 693 reading and ANECompilerService at 11:18:** neither is in the samples.
- **CPU use (e) and disk waits:** see above. One recorded field (`cpuIdle`) makes (e) judgeable.
- **A load_threshold set in mac-limits.json:** that file wasn't read. The replay assumes the defaults (24, 36 boosted).
