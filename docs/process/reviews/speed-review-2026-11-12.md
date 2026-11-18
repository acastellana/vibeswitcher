# Speed review, 2026-11-12: where development through VibeSwitcher loses time

Written by an Opus worker (task where-development) on 2026-11-12, because Fable is held back on this account until
Nov 17. The lead may have Fable check the ranking, so the ranking comes first. No code or setting was changed.

## Ranking

The two units differ. **Task-hours a day** is lead time removed: the sum, over the tasks merged in a day, of the time
each spends between being created and landing on main. Over the last 7 days that sum was **107 task-hours a day**
(751 h over the 111 merged tasks that have a receipt). **Merges a day** is throughput: 130 distinct tasks merged in
the same 7 days by progress.md, **18.6 a day**. A change that saves task-hours makes each idea land sooner. A change
that adds merges lands more ideas.

**Coverage.** 18 of those 130 merges have no row on the board or in its archive (7 on 2026-11-06, 5 on 11-07, 3 on
11-05, 3 on 11-10), so they have no receipt. Every receipt-based figure below covers the other 112 (85%). The merge
counts per day come from progress.md.

| # | Change | Kind | Expected gain a day | How sure | Cost, risk | Contract |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Keep work that's in flight awake: the team runs where it can stay on power with the lid open, and VibeSwitcher shows what each sleep cost | Workflow setting (the user's habit, or which Mac runs the team), plus a small VibeSwitcher change | **5–10 task-hours** (and about 1 more merge) | The loss is measured: 16.3 task-hours a day of in-flight time fell in sleep. How much can be won back is a guess. | Low. The risk is a hot laptop running at night. | [Yes](#contract-1-sleep-shows-its-cost) |
| 2 | Keep the pipeline fed: when the board runs low, start the next item from a queue the user already approved | Lead-policy change, plus a small VibeSwitcher change | **+3 to +7 merges** on average, from the lean days | The idle capacity is measured. The gain is a guess, capped by the weekly usage limits and by what the user wants built. | Medium. Risks: work the user then shrugs off (7 tasks were dropped after a "meh" in 14 days) and spending usage faster. | [Yes](#contract-2-an-idle-board-pulls-the-next-approved-item) |
| 3 | Start a chained task on its predecessor's audited branch, not on its merge | VibeSwitcher change (merge and start code, all sensitive paths) | **2–3 task-hours** | Estimate | High. Needs a restack when the predecessor's rework moves its branch, and conflicts become possible. | No |
| 4 | Make merge test runs survive a crash: run the suite in shards, rerun only the shard that crashed, and fix the top crashers | VibeSwitcher change (test scripts, MergeRerun) | **~2 task-hours**, plus ~0.5 slot-hours | Estimate. The crash share of merge failures is inferred. | Medium. MergeRerun is a sensitive path, so it's audited. | [Yes](#contract-4-a-crash-costs-one-shard-not-the-merge) |
| 5 | Let merge runs use the cores the Mac has free. A calm-Mac merge went from 7–9 min to 15 min on 2026-11-08, when the slot-width caps landed. | VibeSwitcher change (scripts/lib/swift-jobs.sh, scripts/test.sh, vs-heavy) | **~1.7 task-hours**, plus ~1.4 heavy-slot hours | High on the cause (a step change on one date). The size is an estimate. | Low cost. The risk is more app freezes under load, which is why the caps exist. | [Yes](#contract-5-a-calm-mac-merge-gets-the-free-cores) |
| 6 | Risk-tiered audits: tasks under 30 min of work, touching no sensitive path, merge with review none plus the existing 10% sample | Lead-policy change, within the user's floor | **~1 task-hour**, plus roughly a fifth fewer verifier tokens | Estimate | Low cost, real quality risk: 4 of the 67 such tasks in 14 days had an Important finding | No |
| 7 | Rework resumes the released worker's own session instead of a fresh worker | VibeSwitcher change (LeadAdvance.sendBack, sensitive) | **~1 task-hour** | Guess (startup cost not measured) | Low to medium | No |
| 8 | A config-seal hold stops only what the change can reach, and its card reaches the user at once (notification, phone) | VibeSwitcher change | **~0.5 task-hours** | Estimate | Medium. It touches the seal, which guards the agents' config. | No |
| 9 | A rejected push card fetches, runs merge_remote and asks again in one step | VibeSwitcher change | **< 0.3 task-hours**, plus fewer clicks | Estimate | Low | No |

Suggested order, by gain for the cost: **5** (cheap, sure), **1** (cheap; mostly a habit), **4**, **2**, then **6**,
**7**, **3**, **8**, **9**. #1 and #2 work together. Without #2, a Mac kept awake has nothing to run. Without #1, a
fed board stalls every night.

Already planned, so not proposed again here; their expected gains are in
[Gains of the work already planned](#gains-of-the-work-already-planned): model routing (each-role-gets-the), the Fable
fallback (when-fable-s-limit), the pre-done check (a-worker-can-t-2), prompt trimming (prompts-and-agents-md), and
bigger tasks with verification points (a lead decision).

## In short

- **Throughput follows planning, not capacity.** Merges per day track tasks planned per day almost one for one
  (31/38/28 planned on 2026-11-07..09, then 37/42/24 merged; 8/4/4 planned on 2026-11-10..12, then 8/4/1 merged).
  Over 108 sampled hours, VibeSwitcher ran 1.64 workers on average against a cap of 5 to 7, and had no worker or
  verifier at all for 24% of them. It reached 5 workers mainly on the three burst days (13–24% of samples, against
  0–6% on the other days).
- **A third of in-flight time is spent asleep.** Of 343 task-hours between a task's start and its merge, 114 (33%)
  fell where the load recorder has no samples: the Mac asleep, or the app not running. 44 of the 71 gap hours were
  between midnight and 08:00, and 69 gaps of 10–60 minutes fell in the day. "Held: on battery under your 10 % limit"
  appears 20 times in 7.4 days.
- **Merges are slower than they were, and the reason is in our own settings.** Clean merge runs took a median 8.2–8.7
  min before 2026-11-08 05:16 and 15.0–15.8 min after it, on calm Macs too (7.2 → 15.0 min at a 1-minute load ≤ 6).
  The suite grew only 15% in that time (3,424 → 3,946 tests). Two changes landed then: turn-this-incident-into-13
  sized the merge's build to its slot, and swift-testing-s-parallel capped the tests to the slot's share, 4 cores of
  12 with 3 slots. The 2026-11-08 05:42 decision named a trigger, merges above about 600 s on a calm Mac. Merges have
  been at about 900 s since, and that check was closed on worker full-suite times, not on merge times.
- **Merge failures are mostly crashes, not single flaky tests.** All 19 reruns in the 91 distinct merge runs this
  week reran the whole command: a crash, or a failure that named no test. 11 passed on the rerun and 8 failed it. 23
  tasks had a merge fail before they landed, a median 54 minutes later (26 task-hours in all).
- **Audits catch little on small tasks and a lot on large ones.** Over 14 days, 5–7% of audited tasks under 30 min of
  work had an Important finding, against 64% of those over an hour. A failed verdict cost a median 46 minutes to the
  next audit.
- **The user is rarely the wait.** Questions cost 0.8 task-hours in 7 days. Push clicks came in a median of about 2
  minutes. The user-shaped waits are the config seal's holds (about 3.5 h of whole-pipeline holds this week) and the
  Mac's sleep.

## Where the time goes

Windows: task receipts for tasks that ended 2026-11-05 09:32 → 2026-11-12 09:32 (111 merged, 7 abandoned, 2 folded);
event trails from `docs/lead/progress.md` lines dated 2026-11-05 → 2026-11-12 09:30; merge runs and load samples from
`~/.vibeswitcher/stats/` for the same days. 14-day figures, where given, cover 2026-10-29 → 2026-11-12.

### From created to merged

| Measure (7 days) | Value | Source |
| --- | --- | --- |
| Tasks merged | 130 (18.6 a day), by progress.md's "Merged X" lines; 111 of them have a receipt in the window used below | progress.md; board-archive.jsonl + board.json, `receipt.ending` |
| Tasks merged, 14 days (receipts only) | 211 (15.1 a day), an undercount like the 7-day one | receipts |
| Created → merged, all | median 156 min, p75 325, p90 642, mean 406; 14 days: median 123 | `receipt.endedAt − createdAt` |
| … tasks with no `after` (77) | median 117 min, p90 415, mean 207 | same, `after` empty |
| … chained tasks (34) | median 338 min, p90 762, mean 856 | same, `after` set |

### Split by phase

Each merged task's trail is cut where its first audit started, where its last passing verdict came, and where it
merged (114 tasks with a full trail: 78 audited, 36 not). The receipts' own counters are shown beside the phase they
fall in. "Asleep" is the part of each phase that fell in a gap of more than 150 s between load samples.

| Phase | Tasks | Median | Mean | Sum | Asleep | What's inside it (receipts) | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Waiting to start, chained | 33 | 123 min | 629 min | 346 h | 34% | The predecessor's whole life. A chained task starts a median 0.2 min after its last predecessor merges (p90 6.8 min). | receipts; `after`; progress "Started a worker" |
| Waiting to start, not chained | 77 | 0 min | 48 min | 61 h | 39% | Room on the Mac, max_workers, usage holds, battery holds | receipts |
| Worker, start → first audit (audited tasks) | 78 | 50 min | 72 min | 93 h | 17% | Counted work: median 29 min (`receipt.worked`, sleep and waits excluded). The rest is worktree init, startup, waits on the test lock, the lead or a prompt, and sleep. | progress trail + receipts |
| Audit and rework, first audit → last pass | 78 | 15 min | 81 min | 106 h | 42% | Audit wait (median 1 min, sum 31 h), auditing (median 14 min, sum 71 h, 37 h of it from one task, tests-long-synchronous). 30 of 80 audited tasks needed a second round or more, and 1 was re-rolled. A failed verdict took a median 46 min to the next audit (n = 13 with both events, 14 h). | receipts `waits`; progress "Audit of …" |
| Passing verdict → merged | 78 | 23 min | 37 min | 48 h | 22% | Merge test runs: median 15 min, sum 45 h. Load and slot waits: 1.6 h in all. The rest is batching, queueing and failed attempts. | progress trail; receipts `waits.merge*` |
| Not audited, start → merged | 36 | 71 min | 158 min | 95 h | 46% | Counted work: median 27 min | progress trail + receipts |
| Merge failure → merged (overlaps the two rows above) | 23 | 54 min | — | 26 h | — | 15 "tests fail", 5 hung, 4 "batch tests fail", 3 conflicts and 3 other refusals, over 2026-11-05..12 (30 refusals for 23 tasks) | progress "Merge of … failed", "Didn't merge" |
| Waiting on the user (questions) | 4 questions | — | — | 0.8 h | — | 14 days: 7 questions, 3.3 h | `receipt.waitingOnUser` |

What the contract asked for, mapped to the table:

- **Waiting to start:** 408 task-hours in 7 days, 85% of it in chains. That is a planning choice, not a delay.
- **Worker time:** about 77 counted hours, median 29 min a task, against a median of 50 min on the wall (audited
  tasks).
- **Waiting on audit:** median 1 min, but 31 h in sum: a few long waits, mostly for Mac room or the Fable limit.
- **Audit:** 71 h, median 14 min. Per audited task (80), without the one 37-hour outlier, it averages about 21 min.
- **Rework rounds:** 30 of 80 audited tasks; 29 failing verdicts in the progress log; fail → next audit median 46 min.
- **Merge queue and test run:** passing verdict → merged, median 23 min. The test run alone has a median of 14.3 min
  over 91 distinct runs.
- **Reruns:** 19 of 91 runs reran (all as whole-command reruns); 11 passed and 8 failed.
- **Waiting on the user or the lead:** 0.8 h of questions. The lead's own latency isn't measurable here (see the end).

### Merge runs

From `~/.vibeswitcher/stats/merges-*.jsonl`, this project, 2026-11-05 09:32 → 2026-11-12. One row per task; a batch's
rows share one run, so the runs below are counted once per batch.

| Measure | Value |
| --- | --- |
| Distinct runs | 91 (128 rows; 27 batched runs carried 64 tasks) |
| Outcome | 69 passed, 11 passed on the rerun, 8 failed, 2 hung, 1 conflict |
| First run failed | 22 of 91 (24%). It didn't follow the load (2026-11-05..12 rows: 22% at load > 12, 26% at 6–12, 27% at ≤ 6) |
| Reruns | 19, every one of the whole command (crash, or no test named). `flakes/ledger.jsonl` in the last 7 days: 29 flakes, 7 rerun records, 3 fixes. The flake list's top entry is "(the test command, naming no test)", 11 times since 2026-11-05. |
| Duration | median 14.3 min, p75 16.4, p90 24.6; 25.9 h in all, 4.1 h of it in runs that failed, hung or conflicted |
| Clean-pass duration over time | 2026-10-28..11-04: 8.2 min; 11-04..11-08 05:42: 8.7 min (calm: 7.2); 11-08 05:42..11-10: 15.0 min (calm: 15.0); 11-10..11-12: 15.8 min (calm: 15.8) |

The last 7 days' load buckets show the same median duration (13.9 min above load 12, 14.7 at 6–12, 15.0 at or below
6). The "30+ min under load" in the brief came from boosted stretches in boost-release-check.md. Load hasn't been what
makes merges long since 2026-11-08: the width is.

### Capacity

From `~/.vibeswitcher/stats/load-2026-11-05..12.jsonl`: 6,494 one-minute samples (108 h of the 192 h).

| Measure | Value |
| --- | --- |
| This project's workers | mean 1.64; none in 27% of samples; mean 2.5–3.0 on 2026-11-07..09, 0.2–1.4 on the other days |
| At or over 5 workers | 13–24% of samples on 2026-11-07..09, 0–6% on the other days |
| Verifiers | mean 0.44 |
| No worker and no verifier | 26.5 h (24% of sampled time) |
| Heavy slots held | mean 0.92 of 2–3 |
| Planned, merged per day (both from progress.md) | 11-05 8/7 · 11-06 14/7 · 11-07 31/37 · 11-08 38/42 · 11-09 28/24 · 11-10 8/8 · 11-11 4/4 · 11-12 4/1 |

The Fable limit was reached 4 times in the window: 2026-11-06 11:27, 11-07 20:36, 11-09 19:55 and 11-12 09:17. Each
time the lead moved audits by hand: verifier_model = opus 16 minutes later on 11-06, and on 11-09 audits were held
from 20:24 to 21:46 before moving to Opus.

### Sleep and power

| Measure | Value | Source |
| --- | --- | --- |
| Gaps over 150 s between samples, 2026-11-05..12 | 144 gaps, 70.9 h; 44.1 h of it between 00:00 and 08:00; 69 gaps of 10–60 min, 60 under 10 min, 12 of 1–4 h, 3 over 4 h | load samples |
| In-flight task time inside gaps | 114.3 h of 342.6 h (33%); 25 of 111 tasks lost more than 30 min to it | receipts × load samples |
| Created → started time inside gaps | 143 h | same |
| Battery holds | 20 "Held: on battery under your 10 % limit" lines in 7.4 days | progress.md |
| Earlier evidence | 2026-11-08: 41 sleeps between 15:00 and 20:00 on battery; a merge run's 51.8 wall minutes held 4.9 awake | decisions.md 2026-11-08 20:36 |

VibeSwitcher's Keep Awake takes a `PreventUserIdleSystemSleep` assertion (Sources/VibeSwitcher/KeepAwake.swift:42).
That stops idle sleep, but not a closed lid or a battery running out.

### The user, the lead, and the other Mac

| Measure | Value | Source |
| --- | --- | --- |
| Config-seal and install-gate holds | 6 holds, after which nothing started, audited or merged for 13–83 min: 2026-11-08 09:16 (54 min, three tasks stopped), 09:56 (14), 13:35 (13); 11-09 08:26 (16), 21:45 (83); 11-10 17:08 install gate (28 min to the next start; that task merged 54 min later). About 3.5 h in all. | progress "changed while the team's sessions ran", "isn't installed yet" |
| Push cards | 16 asked; 14 pushed (median about 2 min to the click; the longest waits were 64 and 47 min); 2 rejected because the other Mac had pushed first (2026-11-10 18:04, 2026-11-12 00:14) | progress |
| Cross-Mac merges | 4 tasks (merge-github-s-main, redo-the-github-merge, github-merge-third-try, merge-github-s-main-2) and 2 incidents in 2026-11-07..10. Since 2026-11-11, merge_remote has merged origin/main by itself 8 times. | progress, incidents.md |
| Installs | 13 builds were seen on merges between 2026-11-08 01:23 and 2026-11-11 23:54, about 3.4 a day. A merge waited a median of at most 4.5 h for the next build. | build labels on progress "Merged" lines |
| Lead wakes | 2,269 "woke the lead" lines in app.log over 2026-10-28..11-12, all projects together; 1,982 of them for a single report | ~/.vibeswitcher/debug/app.log |

## The improvements

### 1. Keep work that's in flight awake

**Evidence.** In 7 days, 114 of 343 in-flight task-hours (33%) fell in recorder gaps, and so did 143 h of time
spent waiting to start. Unaudited tasks spent 46% of their start → merge time in gaps, and the audit-and-rework phase
42%. The battery hold fired 20 times. On 2026-11-08 the Mac slept 41 times in five afternoon hours on battery.
Incidents and tasks this week were spent on making sleep less harmful: resume-work-cut-off,
test-waits-count-awake, turn-this-incident-into-16, the-other-time-limits, a-task-s-time. Those stop sleep from
breaking things, but the time is still lost.

**Gain, and how it was estimated.** The exposure is 16.3 task-hours a day. If half of it is won back, for instance on
nights the Mac stays plugged in with the lid open, that is about 8 task-hours a day. The range given is 5–10. Merges
gain about +1 a day, from tasks finishing overnight instead of the next morning. The rest of the gain needs #2.
The 50% is a guess. The recorder can't tell sleep from the app being quit, though the night-time pattern and the
2026-11-08 `pmset` reading point to sleep.

**Cost and risk.** For the user: plug in and keep the lid open (or use an external display) when leaving work
running, or move the team to a Mac that's always on. VibeSwitcher's part is to make the cost visible (contract 1).
`PreventSystemSleep` on AC wouldn't help much, because a closed lid still sleeps. The risk is heat or wear from a
laptop working overnight.

**Kind.** Workflow setting (the user's habit, or which Mac runs the team), plus a small VibeSwitcher change.

### 2. Keep the pipeline fed from an approved queue

**Evidence.** Merged per day tracks planned per day (table above). The capacity sat idle: 24% of sampled time with
no worker and no verifier; 0.2 workers on average on 2026-11-11. auto_advance already starts planned tasks the moment
there is room (no-`after` tasks start a median of 0 min after they're planned). What runs out is planned work. Ideas
also wait in docs/process/backlog.md: 17 tier-A and tier-B ideas from 2026-11-07, several still "idea". The lead
plans in bursts, after the user gives direction.

**Gain, and how it was estimated.** Over 2026-11-05..12, five lean days produced 27 merges between them. The three
burst days produced 103. If each lean day ran at half a burst day's pace (about 17), the lean days would add about 58
merges, roughly 8 a day over the 7.4 days. That is reduced to **+3 to +7 a day** because of the weekly usage limit
(every-model usage at 80–87% on 2026-11-07, with 4 days to the reset), the Fable limit, and what the user will
actually want. The range is a guess. Usage, not the Mac, would be the next ceiling.

**Cost and risk.** The VibeSwitcher side is small: a wake for the lead when the board runs low, and a status line
for the queue (contract 2). The lead-policy side: the user approves a ranked batch ahead of time, and the lead keeps
N of them planned. Risks: building what the user later shrugs at (7 "meh" abandonments in 14 days, all of them
visible features: chat ideas, icons, 3D views). So the queue should hold mostly fixes, debt and measured
improvements, and features only once the user has seen a mockup (backlog B1). It also spends usage faster, which
agent: auto (Codex when Claude is tight) and the 80% hold already guard.

**Kind.** Lead-policy change, plus a small VibeSwitcher change.

### 3. Start a chained task on its predecessor's audited branch

**Evidence.** 34 of 111 tasks waited on `after`. They started a median 0.2 min after their predecessor merged, so
nothing in VibeSwitcher is slow there: the chain itself is the cost. Each link pays its predecessor's audit (median
about 15 min with the wait) and its predecessor's passing verdict → merged (median 23 min). Chains come from the
2026-11-08 rule that tasks touching the same function run in sequence.

**Gain.** Overlapping the successor's work with its predecessor's audit and merge saves about 30–38 min a link.
34 links over 7 days is about 4.9 a day, so about 2.4 task-hours a day. Estimate.

**Cost and risk.** High. It changes start and merge code in LeadAdvance, Worktrees and LeadToolset, all sensitive.
The successor must be restacked when the predecessor's rework or its merge's rebase moves it. A predecessor that fails
its audit can strand the successor's work. Bigger tasks (already a lead decision) remove some links more cheaply. Do
this one only if chains stay common after that.

**Kind.** VibeSwitcher change.

### 4. Make merge test runs survive a crash

**Evidence.** Every rerun this week was a whole-command rerun (19 of 19): the test process died, or the failure named
no test. 11 passed on the rerun, so the crash was intermittent. The flake list's most common entry is "(the test
command, naming no test)" (11 since 2026-11-05). Incident 2026-11-09 18:26 records "619 tests printed their start and
never finished". The rows of whole reruns list 360–525 unfinished tests each: one crash takes the whole suite with it.
A rerun costs the whole suite again, and a crash that doesn't recur on the rerun still fails the merge. Then the task
goes back to a worker, then to another merge, a median 54 minutes later. 23 tasks went through that this week.

**Gain.** Failure → merged was 26 task-hours in 7 days, 3.7 a day. If half of those failures were crashes that
sharding plus crasher fixes would avoid, that's about 1.9 task-hours a day. Add about 0.5 slot-hours a day from not
rerunning the whole suite. The half is an estimate. The rerun records can't tell a genuine failure from a crash.

**Cost and risk.** Medium. Sharding the Swift tests into a few processes within the slot's width; MergeRerun reruns
only the failed shard (sensitive, audited); and the top crashers, found in their crash reports and fixed with tests
that fail without the fix. Risks: a test that depends on running in the same process as another, and lost tests
(the contract checks the count).

**Kind.** VibeSwitcher change (test infrastructure).

### 5. Let merge runs use the cores the Mac has free

**Evidence.** Clean merge runs took a median 8.2–8.7 min until 2026-11-08 05:16 and 15.0–15.8 min since, on a calm Mac
too (7.2 → 15.0 min at load ≤ 6). The test count rose 15% over the same days. Around 05:16 and 06:11 on 2026-11-08,
two caps landed: the merge build sized to its slot (turn-this-incident-into-13) and Swift Testing's width capped to
`VS_HEAVY_CORES` (swift-testing-s-parallel). With 3 slots on 12 cores that is 4 cores, whatever the load
(scripts/lib/swift-jobs.sh, scripts/test.sh `slot_width`, Resources/bin/vs-heavy). The caps exist for a reason: a
2026-11-01 merge build ran 9 compilers at about 900% CPU at load 62–84, and runs at load 100–225 froze the app about 40
times. The 2026-11-08 05:42 decision set the check, merges above about 600 s on a calm Mac. The 23:16 retrospective
closed it on full-suite times of 423–660 s. Merge commands have run at about 900 s since.

**Gain.** About 6.5 min a run if a calm-Mac run gets back to about 9 min. At 13 distinct runs a day that is about 1.4
heavy-slot hours a day. At 16 tasks a day it is about 1.7 task-hours of lead time. It also narrows the window in
which a crash or a sleep can hit a run. The step change is measured. That the caps are the whole cause is likely but
not proven: the merge log's build/test split couldn't be read here.

**Cost and risk.** Low: shell scripts and their tests. The risk is more freezes when a wide run meets new load. Giving
a run more width only when the Mac is calm and few slots are held, and checking freezes per hour against the
recorder, keeps that in view.

**Kind.** VibeSwitcher change.

### 6. Risk-tiered audits for small tasks

**Evidence.** Over 14 days, audited tasks by worked time: under 15 min, 27 tasks, 2 with an Important finding (7%),
audit wait plus audit median 10 min; 15–30 min, 40 tasks, 2 (5%), 16 min; 30–60 min, 45 tasks, 9 (20%), 24 min; over
60 min, 25 tasks, 16 (64%), 42 min. Verifiers cost $526 against the workers' $682 this week (priced tokens only; Fable
worker tokens are unpriced), and audits were what the Fable limit stopped.

**Gain.** About 4.8 small audited tasks a day × about 13 min = about 1 task-hour a day, and about a fifth of the
verifier spend. The fifth is an estimate from task counts, not tokens.

**Cost and risk.** Low cost. The user owns the floor (decision 2026-11-07 20:08), so this is the user's call. The
risk: about 1 in 17 small tasks had an Important finding, and the 10% random sample (review-sampling-audit-10) would
catch only some of those. Keep: Codex workers always audited, sensitive paths, and the risk check's raise to audit.

**Kind.** Lead-policy change, within the user's floor.

### 7. Rework resumes the worker's own session

**Evidence.** Idle workers are released while their audit runs (IM-9). When the audit leaves Important findings, or
the merge fails, `LeadAdvance.sendBack` and `sendToWorker` start a new worker that "knows only its contract" and
rebuilds its picture from `git log`, the diff and the done report (Sources/VibeCore/LeadAdvance.swift:898–940). This
week had 29 failing verdicts and 30 merge refusals. A failed verdict took a median 46 min to the next audit.

**Gain.** If resuming the released session (its transcript, with the findings as the next prompt) saves 10 min a
pass, about 7 passes a day give about 1.2 task-hours. The 10 min is a guess: worker startup isn't recorded.

**Cost and risk.** Low to medium. The resumed context costs a cache write. A worker that went wrong may carry its
mistake into the fix, where a fresh one might not. Re-rolls stay fresh.

**Kind.** VibeSwitcher change.

### 8. A config-seal hold stops only what it must, and its card reaches the user at once

**Evidence.** 6 holds this week stopped every start, audit and merge for 13–83 min, about 3.5 h in all; two of them
became incidents (2026-11-08 09:58 and 13:37). The user chose to keep Accept for skill updates (decision 2026-11-09
17:30), so the hold itself stays. What can shrink is its reach and the time until the user sees it. A change to
something that only instructs could hold starts but not merges of branches already audited. The card can go out as a
notification and to the phone.

**Gain.** About 0.5 task-hours a day. Estimate.

**Cost and risk.** Medium. The seal guards what every agent session loads. Narrowing it needs an audit and a clear
rule for which items hold what.

**Kind.** VibeSwitcher change.

### 9. A rejected push fetches, merges and asks again in one step

**Evidence.** 2 of 16 push requests this week were rejected because the other Mac pushed while the card waited.
Each rejection costs a fetch, a merge_remote, a test run and a new card. The 2026-11-07..10 cluster of cross-Mac merges
(4 tasks, 2 incidents) has since been replaced by merge_remote's automatic path (8 automatic merges since 2026-11-11).

**Gain.** Less than 0.3 task-hours a day, plus one click per rejection. Small. It matters more if the other Mac
pushes more often.

**Kind.** VibeSwitcher change.

## Gains of the work already planned

Counted here, not re-proposed.

| Planned work | Evidence this week | Expected gain a day | How sure |
| --- | --- | --- | --- |
| Fable fallback (when-fable-s-limit) and model routing (each-role-gets-the) | The Fable limit was reached 4 times (2026-11-06 11:27, 11-07 20:36, 11-09 19:55, 11-12 09:17), each handled by hand: audits moved to Opus 16 min later on 11-06, and were held 82 min on 11-09. 66 of ~100 audits this week ran on Fable. | Holds and hand-switches avoided: **~0.5–1 task-hour**; merges about the same, since the lead switched quickly | Estimate |
| Pre-done check that sends a worker back (a-worker-can-t-2) | 29 failing verdicts; fail → next audit median 46 min | **~1.5 task-hours**, if it halves failing verdicts | Guess on the share it catches |
| Bigger tasks with verification points (lead decision) | Non-work time per task: median 117 min created → merged against 29 min worked, for tasks with no chain. 34 chained tasks. But tasks over an hour drew Important findings 64% of the time. | **1–3 task-hours**, from fewer audits, merges and chain links | Guess; the verification points are what keep larger tasks from losing it in rework |
| Prompt trimming (prompts-and-agents-md) | Worker tokens 1,666 M (nearly all cache reads) for 111 merges | Tokens, so throughput when usage binds. Time not measurable. | Not estimated |

## Weighed and not recommended

The lead asked for these to be weighed against the evidence (contract v3).

- **Claude Code's OS-level sandbox for worker shell commands.** No time to win. No worker waited on a permission
  prompt this week. The verifier prompt waits (incidents 2026-11-01, 2026-11-05) are fixed. And it would cost time:
  macOS refuses a sandbox inside a sandbox. SwiftPM's manifest step already needs `--disable-sandbox` under Codex's
  seatbelt (scripts/lib/swift-jobs.sh). The sandbox app can't start inside Codex's sandbox: the-sandbox-app-builds
  was abandoned for that, and UI tasks are pinned to Claude by the 2026-11-11 decision. The tests start session hosts
  and fake ttys, and vs-heavy keeps its lock under `~/.vibeswitcher`. A sandboxed Claude worker would hit the same
  walls. The security benefit is real, but that is a security decision, not a speed one. If it's wanted, pilot it on
  verifiers first: they're read-only, and their allow lists are where prompts have hung.
- **Deny rules committed in the repository's `.claude/settings.json`.** VibeSwitcher already writes each role's allow
  and deny rules at launch (LeadLaunch.prepare), and `.claude/` is a sensitive path under the config seal. Committing
  them would mostly reach the user's own sessions in this repository. No effect on speed.
- **CI with autofix and merge-when-ready.** The merge gate already is a local merge queue. merge_policy auto merges
  when ready. A failed merge is sent back to its worker by itself: "Sent its worker the output; it's back at work",
  15 tasks auto-sent back this week. Batching and one flake rerun are already there. A hosted runner would need macOS
  27 with a GUI session, Terminal ttys, the Metal toolchain and node. It would have fewer cores than this Mac, whose
  4-core merges already take 15 min. And every run would need a push, which is the user's click. Its one real
  advantage, running while the laptop sleeps, #1 gets more cheaply.
- **Cloud sessions.** Claude Code's cloud sessions run in Linux environments, as far as this review knows (not
  checked here). They can't build or test a macOS AppKit app, start the sandbox app, or reach the local board, the
  lead's tool server, vs-heavy or the vault. Only research and doc tasks could run there, about 8 of 111 this week
  (ideas reviews, backtests, this review), and even those read local records under `~/.vibeswitcher`.
- **Codex workers' missing screenshots.** UI tasks with layout changes already go to Claude (decision 2026-11-11
  23:36). It costs time only when Claude's usage is tight, which agent: auto then shifts the other way. Not worth a
  task now.
- **False stall alarms and the lead's turn latency.** The stall reports were reworked this week (a-stalled-or-hung,
  a-task-s-time, turn-this-incident-into-16). Routine steps don't wait on the lead: the audit wait has a median of
  1 min, and chained starts come 0.2 min after a merge. The lead's own latency on judgment calls couldn't be measured
  (below).
- **Merge runs of 30+ min under load.** That was true in the boosted stretches of boost-release-check.md. This week
  the load buckets show the same median (14–15 min), so load is no longer the reason. The width is (#5).

## What this review couldn't measure, and which claims are estimates

Not measured:

- **The lead's turn latency** (time from a report or a question to the lead's action). Lead transcripts are outside
  this task's boundaries, and reading `.vibeswitcher/lead-tokens.json` was refused. Only the automated steps' waits
  are known.
- **Sleep against the app being quit.** A recorder gap is either. The night-time pattern and the 2026-11-08 `pmset`
  reading point to sleep, but the 114 h aren't split.
- **How long battery holds lasted.** power.json keeps only the current state, and progress.md logs the hold's start,
  not its end.
- **A merge run's split into init, build, Swift tests and web tests.** merge-test.log lives under
  `~/.vibeswitcher/lead/scratch`, which this session couldn't read. So in #5 the build/test share of the 6.5 min is
  inferred from the step change.
- **Which merge failures were genuine, and which were crashes or flakes.** Only the rerun outcome is recorded. Crash
  reports (DiagnosticReports) were outside the boundaries.
- **What the usage limits count.** Tokens per task are known; how they count against the weekly and Fable limits is
  not.
- **Idea → task latency.** How long an idea waits in chat or the backlog before the lead plans it isn't recorded.
- **Escapes.** Defects found after merge, and the follow-up tasks they caused, weren't counted.
- **Worker startup cost** (a fresh worker reading its way in), which #7's gain rests on.

Estimates and guesses, labelled:

- Measured: every number in "Where the time goes", the per-size audit yields, the merge duration step on 2026-11-08,
  and the hold and push counts.
- Estimates (a measured base times a stated assumption): the gains of #3, #4, #5, #6 and #8, and the Fable
  fallback's 0.5–1 task-hour.
- Guesses (the assumption itself isn't measured): #1's 50% recoverable, #2's "+3 to +7", #7's 10 min a pass, the
  pre-done check halving failing verdicts, and bigger tasks' 1–3 task-hours.
- Inferences: that the slot-width caps are the whole cause of the merge slowdown; that the recorder gaps are mostly
  sleep.
- **A gap in the records:** 18 of the week's 130 merges (14%) have no board row and so no receipt. Why they're missing
  wasn't looked into. The receipt-based splits assume the missing 18 look like the rest.

## Ready-to-file contracts

### Contract 1: Sleep shows its cost

**Goal.** The user sees, every day and on each wake, how much in-flight work the Mac's sleep and battery holds paused,
so they can choose to keep the Mac awake and on power when work is running.

**Acceptance checks.**

1. The day's app-health digest, and status, state per project the hours of in-flight task time (running or in
   review) that fell in sleep, from the witness's sleep log (the awake clock). A test with an injected sleep log
   checks the figure.
2. On wake after a sleep of 10 min or more with tasks in flight, one notification says how long the Mac slept and
   which tasks paused. A short sleep says nothing. Tests use an injected clock and sleep log.
3. The battery hold's card and progress line say how many tasks are paused and since when, and the hold's end is
   logged too ("Released: on AC power, after N min").
4. Settings › Project lead's Keep Awake help says what keeps work running overnight: AC power, the lid open or an
   external display. It also says that a closed lid sleeps whatever the setting.
5. Sandbox shots of the notification and the Settings help.

**Boundaries.** Sources/VibeSwitcher/KeepAwake.swift, Sources/VibeCore/AppHealth.swift and the witness's sleep-log
reader, the digest and status text, Settings help text, tests. No change to what holds or starts work. Review: audit
if it touches LeadWitness.swift or LeadAdvance.swift (sensitive), else none.

### Contract 2: An idle board pulls the next approved item

**Goal.** When this project's board has fewer planned or running tasks than `keep_fed` (workflow.md, default 0 = off),
the Mac is on AC and awake, and usage isn't held, the lead is woken once with the next items from a queue the user
approved. So the pipeline keeps working between the user's sessions, on work the user already said yes to.

**Acceptance checks.**

1. docs/process/backlog.md gains an "approved" status with the date and the user's words. Only the user's answer
   sets it, never a timer. The lead's prompt says so.
2. With `keep_fed: N` and fewer than N planned plus running tasks, auto_advance wakes the lead once per shortfall
   with the top approved items. It doesn't when on battery, on a usage hold, held, or at night under the 10% battery
   limit. Tests cover each, with an injected board and clock.
3. The lead plans only approved items from that wake. The prompt and a test of the wake's text check this. A "meh"
   or a rejection removes the item from the queue.
4. status shows "queue: K approved, next: <title>" and keep_fed's value.
5. After a week with `keep_fed: 3`, the batch retrospective reports merges per day and idle worker-hours against this
   review's baseline (18.6 a day by progress.md's "Merged" lines; no worker or verifier for 24% of sampled time).

**Boundaries.** Sources/VibeCore/LeadAdvance.swift and LeadWorkflow.swift (sensitive: audit), LeadPrompts (the
lead's brief), docs/guide/project-lead.md, docs/process/backlog.md's format, tests. The lead-policy side (asking the
user to approve a ranked batch at each retrospective) is a decision for the lead to record.

### Contract 4: A crash costs one shard, not the merge

**Goal.** A test process that crashes during a merge's run (or a worker's full suite) costs a rerun of its own shard
only. The failure names the shard and the test that was running. The two most frequent crashers of the last 14 days
are fixed.

**Acceptance checks.**

1. A list of the test-process crashes in merge and full-suite runs since 2026-10-29: crash report, the test running,
   and how many runs each hit. The top two causes are fixed, each with a test shown failing without its fix (the
   AGENTS.md revert procedure).
2. scripts/test.sh runs the Swift tests as K shards (by target or suite pattern), each its own process, together
   within the slot's width. One shard crashing leaves the others' results and ends with "shard S crashed during
   <test>". A test with a stand-in test binary that crashes checks this.
3. MergeRerun reruns only the failed or crashed shards, and a whole rerun happens only when no shard can be named.
   This is tested.
4. Sharded and unsharded runs list the same tests: no test lost, checked by comparing the two lists.
5. On a calm Mac, a sharded full run is no slower than the unsharded one (3 runs each, times reported).

**Boundaries.** scripts/test.sh, scripts/lib/, Sources/VibeCore/MergeRerun.swift and MergeFailure.swift (sensitive:
audit), the crashing tests' code, their tests. Crash reports: read from ~/Library/Logs/DiagnosticReports. Never attach
a debugger.

### Contract 5: A calm-Mac merge gets the free cores

**Goal.** A merge's test run, and a worker's or verifier's full suite, uses the cores the Mac has free instead of a
fixed share of them, so a merge on a calm Mac is back to about 9 min (from 15). The app's freezes per hour must not
rise.

**Acceptance checks.**

1. vs-heavy gives a run `VS_HEAVY_CORES` from what's free when it starts (the cores less the load and less the slots
   already held, within the slot share and the whole Mac). Under load, or with every slot held, it stays at today's
   share. Tests drive it with an injected load and fake holders.
2. The run's output and `merges-*.jsonl` record the width it got (`cores`).
3. Three merge-sized `vs-heavy bash scripts/test.sh` runs on a calm Mac (load < 6, one slot held): median at or
   under 10 min, reported against today's 15 min. Measured once, on a calm Mac; not a test.
4. For a week after it merges, freezes per hour during merge runs (scripts/load-report.sh) are no higher than the
   week before. This is a check for the lead's retrospective, recorded with its numbers.
5. The 2026-11-08 05:42 decision's trigger (merges over about 600 s on a calm Mac) is noted as met, with this
   review's numbers.

**Boundaries.** Resources/bin/vs-heavy, scripts/lib/swift-jobs.sh, scripts/test.sh (`slot_width`), the load recorder's
merge row, their tests (TestScriptWidthTests and vs-heavy's). Not TestLock.swift or MergeRerun.swift. Review: audit,
because it changes shared test infrastructure.

## How the numbers were made

All read-only, in a scratch folder: Python over the files named in each table.

- Receipts: `.vibeswitcher/board-archive.jsonl` (rows with an `id`) plus `.vibeswitcher/board.json`'s tasks, those whose
  `receipt.endedAt` is within 7 (or 14) days. Fields used: `createdAt`, `after`, `receipt.{startedAt, endedAt, ending,
  worked, rounds, rerolls, mergeReruns, questions, waitingOnUser, waits, worker, verifier}`, `score.{review,
  importantFindings}`, `merged.at`.
- Event trails: lines of `docs/lead/progress.md` dated 2026-11-05 → 2026-11-12, matched as "Started a worker on X",
  "Started the audit of X", "Audit of X: …", "Merged X", "Merge of X failed", "Didn't merge X", "Sent X's worker". A
  verdict counts as failing when it reads "Important open", "Important (N open)", "incomplete" or "suspect".
- Merge runs: `~/.vibeswitcher/stats/merges-*.jsonl`, this project's rows, deduplicated by `batch` id for run counts.
- Capacity and sleep: `~/.vibeswitcher/stats/load-*.jsonl` sessions per role and project; gaps of more than 150 s
  between consecutive samples count as asleep (or the app not running), clipped to each task's interval.
- Flakes: `.vibeswitcher/flakes/ledger.jsonl`. Wakes: `~/.vibeswitcher/debug/app.log`. Holds, pushes and installs:
  progress.md lines as quoted above.

## Fable's check

Written by a Fable worker (task fable-checks-the-speed) on 2026-11-12, from the same records. The measurements
weren't redone: the numbers the ranking turns on were recomputed, and the sources are named in each row. Nothing above
this section was changed.

**Verdict.** The measurements reproduce. Three readings of them don't hold, and they move the ranking: #1's size rests
on one night and one task, #4's "crashes" are mostly single flaky tests, and #2 counts merges without asking what was
merged. The largest in-flight cost with a lever, extra audit rounds, is in the review only as planned work worth 1.5
task-hours.

### The ranking as Fable would order it

| Was | Now | Change | Why it moved |
| --- | --- | --- | --- |
| 5 | 1 | Merge runs use the free cores | Stays first in the suggested order. It is the only item whose loss is a step on a known date, and it reproduces: clean runs 8.2 and 8.5 min before 2026-11-08 05:42, 14.6 and 15.8 after (calm: 7.2 → 14.2); the test-width commit af3445e3 is dated 04:50 that day. The medians differ from the review's by up to 0.8 min because runs were counted once per batch and cut at 05:42; the step is the same. |
| planned, 7 | 2 | Fewer audit rounds: the pre-done check first, then #7 (rework resumes the worker's session), and tasks kept small | Up from "planned, 1.5 task-hours". Tasks with two or more rounds took a median 208 min from start to merge against 89 for one round: about 95 task-hours of excess in 7 days (13 a day, an upper bound, see below). |
| 1 | 3 | Keep in-flight work awake | Down two. The loss is real but concentrated, and a night kept awake wins back a task's remaining work, not the hours of the gap. Still cheap, so contract 1 stands as written. |
| 4 | 4 | Reruns run only the failing tests, on the branch and on main. Sharding is dropped. | Same place, different change: the evidence for crashes doesn't hold, so the costly, sensitive half of contract 4 (shards, MergeRerun per shard) has nothing to fix. |
| new | 5 | Merged work gets installed sooner | New. The review's own table has it (a merge waited a median of up to 4.5 h for the next build), but not its ranking. |
| 6 | 6 | Risk-tiered audits | Same place, the user's call. Both sides are bigger than stated (below). |
| 2 | 7 | Keep the pipeline fed | Down five. The gain is in merges a day, and that unit doesn't tell wanted work from filler. Pilot it small, after 1–4. |
| 3, 8, 9 | 8–10 | Chained starts on the audited branch; a narrower seal hold; one-step rejected push | Unchanged, and not worth tasks now. #3's case is weaker than stated: see the first dispute. |

### Disputed claims

| Claim in the review | What the records show | Source |
| --- | --- | --- |
| "107 task-hours a day" of lead time; "waiting to start: 408 h, 85% of it in chains" | One task is a third of it. boost-release-7-7 was planned on 2026-11-01 as the last link of its chain and started on 11-11: 250 h. Without it, created → merged sums to 501 h (72 a day), and the other 33 chained tasks waited 97 h in all. | receipts, `startedAt − createdAt` |
| #1: "16.3 task-hours a day of in-flight time fell in sleep"; half of it could be won back (5–10 a day) | The 114 h reproduce, but 93 of them belong to ten tasks. tests-long-synchronous alone is 28 h. The night of 2026-11-07 (a 7.9 h gap from 02:02, six tasks in flight, started 23:11–23:59 the evening before) is about 47 h. In the 8 h gaps of the nights of 11-08 and 11-09 nothing was in flight. By the clock, gaps with a task in flight came to 24.7 h starting between 23:00 and 08:00 and 18.6 h in the day, over 7 days. 73 of the 114 task-hours fell between 00:00 and 08:00, 41 in the day. A Mac kept awake that night would have finished those six tasks (2–76 min of counted work each) by about 04:00. That is a real gain for their successors (resume-work-cut-off waited 13 h, test-under-load-s 11 h), but it is their remaining work that moves, not six times eight hours. The share a habit reaches every day is the daytime one: about 6 task-hours a day of exposure, so **2–4** won back, not 5–10. | receipts × load-sample gaps, split by hour |
| "Merge failures are mostly crashes, not single flaky tests"; whole reruns "list 360–525 unfinished tests each: one crash takes the whole suite with it" | The lists are not what a crash cut off. The same names are in all 16 long lists (thePanesRowsAreTerminalAppsRows(cols:), aToolThatGivesNoAnswerIsEnded() and others: 16 of 16), and the count grows with the suite, 363 → 525. From 2026-11-09 the rows list 1, 1 and 0 tests. Crash reports say the same: 15 swiftpm-testing-helper reports in the window, all on three occasions: 3 on 11-07 between 00:08 and 00:50 (an array index in LeadRotationTests at 00:23, and two aborts at 00:08 and 00:50 whose reports show only an idle main thread); an uncaught exception, 4 times on 11-08 between 10:35 and 15:02; an assertion, 8 times on 11-09 between 14:14 and 19:00. On 11-07, ten whole reruns ran between 10:21 and 23:51, and no crash report exists after 00:50 that day. So at least 10 of the 16 were not crashes. Each list's first name is a single test, and the most frequent ones were fixed as flaky this week (aQuestionsCardIsUpWithin1Point2S…, 3 runs; aPlainShellTakesARunOnlyAtItsPrompt(), 3 runs; heldTheTranscript…). 12 of the 18 "Merge of … failed" lines name one to four tests. | merges-*.jsonl `reran`; ~/Library/Logs/DiagnosticReports (the review didn't read these); progress.md |
| #4's gain: "if half of those failures were crashes that sharding plus crasher fixes would avoid" | No. What the records support is narrower and cheaper. Every rerun was of the whole command even when the failing test was named (`rerun_whole` true on all 19; the ledger's `filtered: false`, "a whole rerun isn't run on the base"). Two branches were sent back for tests that were red on main: a-worker-s-brief (11-06 23:11) and fetch-github-by-itself (11-07 00:21) both failed on the AccountUsage date tests. Rerunning the named tests takes seconds, not 15 min, and running them on main too tells a branch's failure from main's. The crash causes are ordinary bug tasks. | flakes/ledger.jsonl; progress.md 2026-11-07 00:23 dismissal |
| #2: "+3 to +7 merges a day" from running lean days at half a burst day's pace | Three things are missing from the estimate. First, what a merge is: by a reading of the 111 titles, about 78 changed the team's own machinery (merge gate, audits, tests and flakes, config seal, usage, sleep handling, records, ideas reviews and backtests) and about 33 the app the user touches. The review's own remedy for "meh" features is a queue of "mostly fixes, debt and measured improvements", which raises the first number. Second, usage: the lean days were not usage-bound (so "follows planning" holds), but the burst was: weekly usage ran 43–47 points ahead of pace on 11-06 and 11-07 and reached the 80% hold on 11-07 10:06, 4.3 days before the reset, and the Fable limit was reached 4 times. Work pulled on lean days is paid from the budget the next burst needs. Third, "half a burst day's pace" has no measurement behind it. The 24% idle time is idle because the user hadn't said what they wanted next. That is a fact about direction, and a queue doesn't supply it. | the hand count is a judgment from titles; progress.md usage lines |
| #6: "roughly a fifth fewer verifier tokens"; 5–7% of small tasks had an Important finding | This week, tasks under 30 min of work whose receipt carries a verifier (101 of 111 do, see addition A): 49, carrying $220 of the $526 verifier spend (42%). 5 of them had an Important finding and 9 went to a second round. So the saving is about twice what was stated, and so is the risk. That is the trade the user decides; it doesn't change the rank. | receipts, `verifier.cost`, `rounds`, `score.importantFindings` |
| Planned: "bigger tasks with verification points", 1–3 task-hours | It pulls against the same data. Tasks with an hour or more of work needed a second round 13 times in 22 (59%); tasks under 30 min, 9 in 49 (18%). The review notes the 64% Important rate and still counts a gain. Bigger tasks would save audits and merges and buy rounds, which cost more. | receipts |

### Additions

**A. Extra audit rounds are the largest in-flight cost with a lever.** The base here is the receipts: 101 of the 111
merged tasks carry a verifier (the 75 with review audit, and 26 planned as review none or with no review recorded
that were audited all the same). The review's 80 audited tasks come from the progress trail; both
counts find 30 tasks with two rounds or more. Their start → merge median was 208 min; the 71 one-round audited
tasks' was 89, and none of the 71 is an unaudited task. The excess over that median sums to
142 h, or 95 h without the longest task: about 13 task-hours a day. It is an upper bound. The same tasks were larger
(counted work median 50 min against 25, about 12 h of the 95), and a task in rework is the one left in flight
overnight (the review's audit-and-rework phase is 42% asleep), so this overlaps #1. The review priced a failed verdict
at its 46 min to the next audit; the round also pays a second audit, a second wait and often a night. Nothing new to
build: the pre-done check (a-worker-can-t-2) is the first lever and should be judged on rounds per task, #7 is the
second once worker startup is measured, and the cheapest is the lead's own: keep tasks under about 30 min of work
where the change allows. How sure: the 95 h is measured, the share a check removes is a guess.

**B. Merged work waits for an install, and most of this week's merges only act once installed.** The review's table
has 13 builds in 4 days and a median wait of up to 4.5 h from a merge to the next build, against a created → merged
median of 156 min: for the user, the install is the longer half. It also feeds back into the pipeline, because about
78 of 111 merges changed the lead's own machinery, which runs from the installed app. On 2026-11-10 17:08 a merge
was refused because "Gate code on main isn't installed yet: 18 commits", and landed 54 min later. A flaky-test or
gate fix that sits uninstalled keeps costing merges. The install is the user's click (it relaunches the app), so the
change is small: when gate or lead commits wait and nothing is in flight, the lead says so once, with the count and
what they fix; the scorecard's time-to-install (backlog A1, merged this week) is the measure. Gain: not estimated in
task-hours. The 4.5 h was not re-measured here.

No third addition. Fable looked for one in the worker phase (50 min on the wall against 29 counted) and found no
record that splits it: measuring that gap is worth a line in the next review, not a task.

### What the lead can file from this

1. Contract 5 as written.
2. Contract 1 as written, with its gain read as 2–4 task-hours a day.
3. Contract 4 rewritten: a failed merge run reruns only the tests it names, on the branch and on main; a test that
   fails on main too doesn't send the branch back, and becomes a fix task. Checks 2, 4 and 5 (shards) go, and
   check 3 becomes that rerun of the named tests, with a whole rerun only when no test is named. Check 1 stays as
   the crash causes above.
4. Nothing for #2 yet. If the user wants it, start with `keep_fed: 1` and a queue of items the user named.
