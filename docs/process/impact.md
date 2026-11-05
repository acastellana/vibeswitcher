# Feature impact ledger

Did a change help? This ledger answers that question for each feature or process change, by hand for now. Each
change gets one entry: what it should improve, the number that shows it, that number before the change, when to look
again, and then the result, the verdict and the reason. The lead fills in results at each retrospective with
[scripts/impact-metrics.sh](../../scripts/impact-metrics.sh). Once this routine has proved useful, it can become a lead
tool, and not before.

> "We need to be able to track which features help or not and why, to recursively self-improve in the future,
> starting manually." (the user, 2026-11-01)

## The routine

1. **When a change merges** (or is planned, if it's part of a release), add an entry with status `measuring`. Write
   its hypothesis and metric, and take the baseline: run the script over a window before the change and paste the
   numbers.
2. **At the check date**, run the script over the check window. Put the numbers next to the baseline in Result.
3. **Decide the verdict** (see [Verdicts become tasks](#verdicts-become-tasks)) and write why in one or two sentences.
   Set status to `done`, or to `measuring` again with a new check date if the window was extended.
4. Turn a `tune` or `revert` verdict into a task the same day.

Freeze numbers don't keep. The app deletes hang reports after a week, and sooner once they pass 500 MB (about
0.75 MB each, so a 10-an-hour night fills that in under three days). Read freezes/h within days of the window and paste
the numbers into the entry. The script counts only the hours whose reports are still there, and says `partial` (or
`n/a`) when some were deleted.

```sh
scripts/impact-metrics.sh 2026-10-25..2026-10-31                    # whole local days, TO included
scripts/impact-metrics.sh 2026-11-01T02:49..2026-11-08T02:49         # from a merge's minute
scripts/impact-metrics.sh 2026-11-01..2026-11-07 --project ~/dev/x   # another project (repeatable)
```

The script only reads. Per project, it reads the board (`.vibeswitcher/board.json` and `board-archive.jsonl`, with
the flake ledger) and the lead's [progress.md](../lead/progress.md) and [incidents.md](../lead/incidents.md). It reads
these from the main checkout, even when run from a worktree. Mac-wide, it reads the hang reports
(`~/.vibeswitcher/debug/hang-*`) and, once they exist, the load recorder's `~/.vibeswitcher/stats/load-<day>.jsonl`
and `merges-<day>.jsonl`. It never reads `~/.vibeswitcher/lead`. When a metric's source is missing, the script prints
`n/a` with the reason. It never estimates a missing number.

## Entry format

Copy this block under [Entries](#entries), newest first:

```markdown
### IM-N: Short name (task slug, commit)

- **Change:** what changed, merged when (or planned).
- **Hypothesis:** if <change>, then <metric> moves from <baseline> to <threshold> within <window>, because <mechanism>;
  <guard metric> doesn't get worse than <limit>.
- **Metric:** the primary metric (from the standard list where possible); guard: what must not get worse.
- **Baseline:** the numbers, the window they cover, the command.
- **Check:** the date, and the window to measure.
- **Status:** measuring | done
- **Result:** the check window's numbers next to the baseline's.
- **Verdict:** keep | tune | revert | inconclusive
- **Why:** one or two sentences: the reason for the verdict, and any confounder that could explain the result instead.
```

### The standard metrics

| Metric | Definition | Source |
|---|---|---|
| merges/h | merges in the range ÷ its elapsed hours; also per active hour (an hour with any progress.md line) | board, progress.md |
| median start-to-merge | first worker start → merge, over the range's merges | board (receipt or task) |
| median audit-to-merge | first `Started the audit of` line → merge, over audited merges | progress.md, board |
| audit rounds per audited task | audits recorded ÷ merges with at least one audit | board scores |
| Important findings per task | Important findings raised ÷ merges (and ÷ audited merges) | board scores |
| reverts | merges reverted in the range (by revert time) | board |
| incidents | incidents.md entries dated in the range | incidents.md |
| flaky-merge rate | merges that passed only on the merge's rerun ÷ merges with a receipt; plus the flake ledger's counts | board receipts, flake ledger |
| median full-suite duration | median `duration_s` of the project's merge test runs that ran | load recorder merges files |
| freezes/h (by load bucket) | hang reports ÷ the hours whose reports the app still keeps; with load samples, per 1-minute-load bucket (0-12, 12-24, 24-36, …) | hang reports, load recorder |
| worker hours, estimated cost per task | receipts of tasks ended in the range: worked hours; mean worker + verifier cost (only receipts whose cost is known) | board receipts |
| usage-limit stops | no source records them yet: `n/a` until the usage watch writes one | (none yet) |

## Writing a falsifiable hypothesis

A hypothesis is useful only if a number could prove it wrong. Before writing one, check:

- **One metric, one direction, one threshold.** "Median audit-to-merge drops from 31 min to under 25 min" can be
  checked. "Audits get faster" can't. Pick the threshold before you look at the result.
- **A mechanism.** Say why the number should move ("the verifier no longer runs a 4-minute suite"). If the number
  moves but the mechanism didn't happen, the verdict is `inconclusive`, not `keep`.
- **A guard.** Say what the change could break and how much damage is acceptable. Examples: reverts stay at 0,
  Important findings per audited task stay under 0.4, freezes/h don't rise.
- **A window big enough to tell.** Ask for at least 10 merges (or 24 h of samples for Mac metrics) in the check
  window, as long as the baseline window. With fewer, the verdict is `inconclusive` and the window is extended once.
- **Confounders, named.** Mac load, the batch's mix (a run of docs tasks merges fast), and other changes landing in
  the same window. IM-1 to IM-5 below landed within the same 13 hours, so their shared metrics count together.
  Say so in Why rather than credit one change. Once the load recorder exists, compare within the same load bucket.
- **Write it before the result.** An entry whose hypothesis was edited after the check is a story, not a test.

Weak: "Boost mode improves throughput." Falsifiable: "With Boost on while the user is away, merges/h rises from 0.77
to at least 1.0 over a week, because more workers and audits run at once. Guard: freezes/h in the 36–48 load bucket
stays under 2× its value at 24–36."

## Verdicts become tasks

| Verdict | When | What the lead does |
|---|---|---|
| **keep** | The metric crossed the threshold and the guard held | Nothing more. The entry is done. Mention it in the retrospective. |
| **tune** | It helped, but by less than the threshold, or the guard slipped a little | `add_task` to change the one setting or behaviour the result points at (e.g. "boost load_threshold 36 → 32"), citing the entry (IM-N) and its numbers in the context. Then open a new entry for the tuned change. |
| **revert** | The metric got worse, or the guard broke (a revert, an incident, more freezes) | The lead's `revert` of the merge, or a task to take the change out (review audit), citing the entry. Write down what we learned in Why. |
| **inconclusive** | Too little data, or a confounder explains the result as well | Extend the window once with a new check date. If it is still unclear, close the entry as inconclusive with no task. An inconclusive verdict never turns into a revert. |

A verdict is the lead's, made at a retrospective. The user hears about `revert` verdicts before they become tasks.

## Baselines used below

Unless an entry says otherwise, baselines come from vibeswitcher's week **2026-10-25..2026-10-31**
(`scripts/impact-metrics.sh 2026-10-25..2026-10-31`). Over 169 h:

- 130 merges: 0.77/h, or 1.31 per active hour (99 h with lead activity)
- median start-to-merge 63 min; median audit-to-merge 31 min (82 of 94 audited merges)
- 1.29 audit rounds per audited task; 0.19 Important findings per task (0.27 per audited task)
- 0 reverts; 8 incidents
- flaky-merge rate 27% (26 of 98 merges with a receipt)
- 46.3 worker hours over 112 tasks ended; estimated cost per task $11.63
- freezes 2.92/h over 2026-10-28T12:10..2026-10-31 (245 hang reports in 83.8 h). That is the part of the week whose
  reports the app still keeps: older ones were deleted, and before 2026-10-28 12:10 it kept only the 10 newest. Over
  2026-10-29..2026-10-31 it was 2.40/h.

The script reads no source yet for some metrics. For these, the baselines come from the load study (2026-11-01): Mac
load bends at 24, and throughput peaks around 36–48. About 20% of merges flake on the first run. The full suite takes
~192 s when the Mac is calm and ~240 s above load 24. Usage-limit stops: 1 incident (2026-10-31 16:48), no count. For
cost, the receipts of the 2026-10-31 batch give 8 tasks, 2.9 h and ~$86.

## Entries

### IM-15: Marked wallet requests never go to the browser wallet (wallet-requests-marked, planned)

- **Change:** a wallet request whose `reason` has the first line `LOCAL FORK ONLY` (or nearly: spaces, tabs and
  carriage returns at its ends dropped, case ignored) is never offered Sign in browser wallet, whatever its `from`:
  `WalletBrowser.canSign` is false for it, so the card has no browser button, no signing page is made, and
  `vs-wallet request` says it waits for the Wallet Manager. It is filed, shown and sent to the Wallet Manager like any
  other. The spec records the marker ([wallet-request.md](../protocol/wallet-request.md), History, 2026-11-05).
- **Hypothesis:** no marked request is ever offered the browser wallet, because the card, the desk's signing page and
  vs-wallet's output all ask the one rule. Unmarked requests from an 0x address are offered it as before.
- **Metric:** the tests that hold the rule stay green in every merge's full suite:
  `aRequestMarkedLocalForkOnlyCantBeSignedInTheBrowser`, `aNearlyRightMarkerIsRefusedTheBrowserToo`,
  `aMarkedRequestsCardNeverHasTheBrowserAction`, `aMarkedRequestIsNeverOpenedInTheBrowserWallet` and
  `aMarkedRequestWithoutAWalletManagerWaitsForItNeverTheBrowserWallet`. Guards: incidents of a marked request opened
  in the browser wallet stay at 0; `aReasonWithoutTheMarkerAsItsFirstLineStaysSignable` stays green (an unmarked
  request keeps the browser wallet).
- **Baseline:** before the change, a marked request from an 0x address was offered the browser wallet: the five tests
  fail on the commit before it (139 issues in the app's two suites, 46 in the core's two). 0 incidents, since no
  project puts the marker on a request yet.
- **Check:** 2026-11-12, window from this change's merge to 2026-11-12.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-14: No audit waits on an evidence read (turn-this-incident-into-3, planned)

- **Change:** a verifier's settings let it read the image files in its own task's evidence folder
  (`<repo>/.vibeswitcher/evidence/<task>/<report>/`) without a prompt, and nothing else outside its worktree. The
  witness also declines a verifier's Read prompt that no one answers, as it declines a command's.
- **Hypothesis:** no audit waits on an evidence read: witness reports of a verifier waiting on a Read prompt drop
  from 3 in one day to 0 over the week after the merge, because the verifier is no longer asked about the screenshots
  its brief names, and a Read prompt that still shows is declined after 2 minutes (not the one auto mode shows for
  its first read outside the working directories, nor a Glob's or Grep's: nothing is typed there and the lead is told
  it waits; count those apart). Guard: no verifier reads a file
  outside its worktree other than its task's evidence images without a prompt (0 incidents about it).
- **Metric:** witness reports of a verifier waiting on a Read prompt, across projects where the lead reports them
  (the lead's reports and incidents.md titles in the range). Guard: incidents about a verifier reading what it
  shouldn't.
- **Baseline:** 3 on 2026-11-05 (one here, two in another project on one task's audit, the first sitting 155 minutes
  until the audit was restarted).
- **Check:** 2026-11-12, window one week from the merge.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-13: Usage-aware worker routing (usage-aware-worker, planned)

- **Change:** a task with `agent: auto` (or `agent_default: auto`) starts on Codex when Claude's usage is tight (a
  limit at 70%+, or a weekly one more than 10 points ahead of pace) and Codex has room (under 85%, or under 100% with
  credits), else on Claude. It no longer waits at Claude's 80% hold while Codex has room.
- **Hypothesis:** with auto tasks, Claude's weekly % used per merged task drops, because bounded work moves to Codex
  once Claude runs ahead of pace. The share of worker tokens on Codex rises from 0. Quality holds: Important findings
  per Codex-routed task ≤ 0.4.
- **Metric:** share of worker tokens on Codex vs Claude per merged task, from receipts (split by hand by
  `codexWorked` until receipts count Codex tokens); Claude's weekly % used per merged task, from
  `~/.vibeswitcher/account-usage.json` at the window's end over its merges. Guards: Important findings per Codex-routed
  task; reverts of routed merges stay at 0.
- **Baseline:** last 7 days (`scripts/impact-metrics.sh 2026-10-26..2026-11-01`): 148 merges, 0 of them Codex-worked, so
  the Codex share of worker tokens is 0%. Claude's current weekly window (2026-10-28T18:00..2026-11-02T08:43): 55% used
  over 87 merges, about 0.63% per merged task. Important findings 0.35 per audited task.
- **Check:** 2026-11-16, window from this change's merge to 2026-11-16.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-12: Codex workers for bounded tasks (boost-release-3b-codex, planned)

- **Change:** a task can run its worker on the Codex CLI. Codex tasks are always audited by Claude.
- **Hypothesis:** Codex workers on mechanical tasks spread usage across accounts, so usage-limit stops drop to 0 in
  weeks with Codex use. Their quality holds: Important findings per Codex task ≤ 0.4, against 0.27 per audited task
  now.
- **Metric:** usage-limit stops; Important findings per audited task (split Codex and Claude by hand from the board).
  Guard: reverts of Codex merges stay at 0.
- **Baseline:** 0.27 Important findings per audited task; usage-limit stops n/a (1 incident, 2026-10-31).
- **Check:** 2026-11-16, provisional: 14 days after the first Codex task merges (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-11: Boost mode (boost-release-6-7, planned)

- **Change:** higher Mac-wide limits on demand, or automatically when the user is away and the Mac is on AC power
  (load_threshold 36, mac_max_sessions 18, max_workers 7).
- **Hypothesis:** in boosted stretches, merges/h rises from 0.77 to at least 1.0 (per active hour, from 1.31 to at
  least 1.6), because more workers and audits run at once below the 36–48 throughput peak.
- **Metric:** merges/h in boosted stretches against normal ones. Guards: freezes/h in the 36–48 bucket under 2× the
  24–36 bucket; flaky-merge rate under 35%; median full-suite duration under 300 s.
- **Baseline:** 0.77 merges/h, 1.31 per active hour; flaky-merge rate 27%; suite ~240 s above load 24 (load study).
- **Check:** 2026-11-09, provisional: 7 days after it merges (move it if that's later), comparing boosted and normal
  stretches with the load recorder's files.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-10: Batched merges (boost-release-5-7, planned)

- **Change:** review-passed tasks are tested together with one full-suite run, and the batch is split on failure.
- **Hypothesis:** with batching on, test runs per merge drop from 1 to at most 0.6, and merges/h rises by at least
  20%, because one suite run carries several merges.
- **Metric:** recorded merge test runs ÷ merges (from the merges files and the board); merges/h. Guards: reverts stay
  at 0; flaky-merge rate under 35%.
- **Baseline:** 1 test run per merge (plus a rerun on 27% of merges); 0.77 merges/h.
- **Check:** 2026-11-09, provisional: 7 days after merge_batching is first on in a project (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-9: Idle workers released during audits (boost-release-4-7, planned)

- **Change:** a task's idle worker is ended when its audit starts, and restarted only if findings come back.
- **Hypothesis:** releasing idle workers frees a session slot (~450 MB) during each audit. That lowers worker hours
  per task by at least 10% at the same throughput, because idle sessions stop counting as working time.
- **Metric:** worker hours ÷ tasks ended. Guards: median start-to-merge doesn't rise by more than 10 min; audit rounds
  per audited task stay under 1.4.
- **Baseline:** 46.3 h ÷ 112 tasks = 0.41 h per task; start-to-merge 63 min; 1.29 rounds.
- **Check:** 2026-11-09, provisional: 7 days after it merges (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-8: Usage watch (boost-release-3-7, planned)

- **Change:** VibeSwitcher reads how close the account is to its usage limits. Near a limit, it holds new starts and
  audits.
- **Hypothesis:** no session stops mid-task on a usage limit (0 stops) in the 14 days after it merges, because starts
  are held at 80% of a limit.
- **Metric:** usage-limit stops (the script prints `n/a` until the watch records them: add its source to the script
  when it lands); incidents about usage limits. Guard: merges/h doesn't drop by more than 10% in weeks with no hold.
- **Baseline:** 1 usage-limit incident in the week before (2026-10-31 16:48); no count of stops exists.
- **Check:** 2026-11-16, provisional: 14 days after it merges (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-7: Heavy-job reports (boost-release-2-7, planned)

- **Change:** many-core jobs that run outside vs-heavy for more than ~5 minutes are noticed, and their lead is told.
- **Hypothesis:** freezes/h fall by at least a quarter, and minutes above load 48 drop by at least half, because the
  jobs that cause them move under vs-heavy and take turns.
- **Metric:** freezes/h; once the recorder runs, its minutes above load 48 and freezes/h in those buckets. Guard: no
  report about vs-heavy jobs or VibeSwitcher's own merges and audits (false alarms: 0).
- **Baseline:** freezes 2.92/h over 2026-10-28T12:10..2026-10-31, 2.40/h over 2026-10-29..2026-10-31. Load study: the load bends at 24,
  and throughput peaks around 36–48. Minutes above 48: none recorded yet, so use the recorder's days before this
  merges.
- **Check:** 2026-11-09, provisional: 7 days after it merges (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-6: Load recorder (boost-release-1-7, planned)

- **Change:** VibeSwitcher records a line every minute: load, memory, sessions and heavy slots. It also records every
  merge's test run.
- **Hypothesis:** the recorder costs under 50 ms of CPU a minute, and covers at least 95% of the minutes the app runs.
  With it, the script gives freezes/h by load bucket and the median full-suite duration, which are `n/a` today.
- **Metric:** sampled minutes ÷ elapsed minutes while the app runs; the script's two `n/a` metrics get numbers.
  Guard: freezes/h doesn't rise (the sampler runs off the main thread).
- **Baseline:** freezes/h by load bucket and median full-suite duration are `n/a`; freezes 2.92/h.
- **Check:** 2026-11-09, provisional: 7 days after it merges (move it if that's later).
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-5: Git reads of files outside the repository refused (workers-and-verifiers-2, 85f3e417)

- **Change:** `git diff --no-index` and other git reads of files outside the repository are refused to every role, so
  no worker or verifier can read the lead's private files. Merged 2026-11-01 08:25.
- **Hypothesis:** the lockdown closes the hole without slowing work: no audit finds a lead-file read, and median
  start-to-merge stays within 10 min of 63 min, because workers didn't need those reads.
- **Metric:** median start-to-merge; workers blocked on a refused git read (count from progress.md and reports by
  hand). Guards: audit rounds per audited task under 1.4; 0 incidents about refused reads.
- **Baseline:** start-to-merge 63 min; 1.29 rounds per audited task.
- **Check:** 2026-11-08, window 2026-11-01T08:25..2026-11-08T08:25.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-4: Verifiers no longer wait on a prompt nobody sees (turn-this-incident-into-8, d886431f)

- **Change:** verifiers and finders may run read-only git and search commands. The witness declines a finder that
  waits on a permission prompt instead of leaving it hanging. Merged 2026-11-01 04:14.
- **Hypothesis:** audits no longer hang on a permission prompt (0 such restarts or incidents in 14 days, against 2 in
  the 2 days before), and median audit-to-merge drops below 31 min, because no audit waits for the lead to notice.
- **Metric:** incidents about verifier prompt hangs (read incidents.md titles in the range), across projects where
  the lead reports them; median audit-to-merge. Guard: Important findings per audited task don't drop below 0.2,
  because finders that are declined must not mean lost findings.
- **Baseline:** 2 prompt hangs (2026-10-31 ~16:2x and 2026-11-01 00:31, the incident of 00:32); audit-to-merge
  31 min; 0.27 Important findings per audited task.
- **Check:** 2026-11-15, window 2026-11-01T04:14..2026-11-15T04:14.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-3: Strict paths hold unconfirmed Important findings (strict-paths-an, b6dc4949)

- **Change:** on a branch that touches strict_paths, an Important finding holds merge and auto_advance even when the
  finders' vote left it unconfirmed, until the lead rules. Merged 2026-11-01 03:32.
- **Hypothesis:** no merge that touches strict_paths is reverted or followed by an incident in its area within
  14 days. The hold costs little: median audit-to-merge rises by at most 10 min over 31 min.
- **Metric:** reverts of strict-path merges, and incidents in their area; median audit-to-merge. Guard: holds the
  lead dismisses as false stay under half of all holds (count `Held:` lines in progress.md by hand).
- **Baseline:** 0 reverts in the week; audit-to-merge 31 min.
- **Check:** 2026-11-15, window 2026-11-01T03:32..2026-11-15T03:32.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-2: One full suite per audited task (verifiers-don-t-run, 03bd1d6a)

- **Change:** verifiers no longer run a full suite of their own. The merge's test run is the one full suite. Merged
  2026-11-01 02:49.
- **Hypothesis:** median audit-to-merge drops from 31 min to under 25 min, and the Mac runs one suite fewer per
  audited task (~4 min of many-core CPU), because the verifier's suite run was the longest step of an audit. Safety
  holds: reverts stay at 0, and the flaky-merge rate doesn't rise above 30%.
- **Metric:** median audit-to-merge. Guards: reverts; flaky-merge rate; Important findings per audited task stay at
  least 0.2, because the verifier must still find what a suite would show.
- **Baseline:** audit-to-merge 31 min (82 of 94 audited merges); flaky-merge rate 27%; 0 reverts; 0.27 Important
  findings per audited task. An early read, 2026-11-01T02:49..09:30, gave 59 min over 9 audited merges, a heavily
  loaded morning, with too few merges to decide.
- **Check:** 2026-11-08, window 2026-11-01T02:49..2026-11-08T02:49.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)

### IM-1: The app never writes to the session host on the main thread (the-main-thread-blocks, 6a7433c4)

- **Change:** HostConnection writes on a queue of its own, never its caller's, so SessionStore.refresh no longer
  blocks the main thread on the host's socket. Merged 2026-10-31 19:52.
- **Hypothesis:** freezes/h drop by at least a third from the 2.31/h before the fix, because the main thread no longer
  waits on a busy host's socket. With the load recorder, the drop must hold within the same load bucket.
- **Metric:** freezes/h (by load bucket once the recorder runs). Guard: no new incident of lost or reordered input
  to sessions, since writes are now asynchronous.
- **Baseline:** 2.31 freezes/h over 2026-10-28T12:10..2026-10-31T19:50 (184 hang reports in 79.7 h, all still
  kept). An early read over 2026-10-31T19:52..2026-11-01T09:00 gave 11.04/h (145 in 13.1 h). That is five times higher, during a heavily
  loaded night. Without load buckets, the load can't be told apart from the change. If the rise holds within load
  buckets, open a task to find what the freezes are.
- **Check:** 2026-11-07, window 2026-10-31T19:52..2026-11-07T19:52, by load bucket if the recorder has merged by
  then. The night's reports start being deleted on 2026-11-07, and sooner if they pass 500 MB. While freezes run
  above 5/h, read the script every two days and paste each read here; the check combines them.
- **Status:** measuring
- **Result:** (pending)
- **Verdict:** (pending)
- **Why:** (pending)
