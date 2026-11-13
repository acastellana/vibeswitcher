# Worker rediscovery, 2026-11: would a shared notes board between workers save time?

Written by a worker (task measure-how-often) on 2026-11-13, before deciding whether to build a board where workers leave
each other tips. No product code or setting was changed.

## In short

**Don't build the notes board yet. Fix AGENTS.md and the worker brief instead.** Over the last 7 days, repeats that a
tip from another worker would have prevented cost **2.2%** of worker time. Repeats from concurrent tasks changing the
same file cost **0.8%**. Together that is **3.0%**, under the proposed 5% bar. All of the tip-preventable share (158
minutes) came from one incident: a lint was red on main for about four hours on 2026-11-12, and 9 workers
each tracked it down separately. That incident has a cheaper fix than a board (see the verdict). The most common repeats
are stable facts and traps that every worker meets. A line in AGENTS.md or the brief would prevent those for every
future worker, which a board kept by past workers can't do as well.

## Sample

- **All** worker sessions of this project in the 7 days to 2026-11-13 18:30, no sampling. In that window, this
  repository's worktrees have 324 Claude Code sessions: **151 worker sessions**, 170 verifier sessions and 3 others
  (one-off command runs). The worker sessions are the ones whose first prompt starts the task.
- **150 worker sessions were read**, covering **119 tasks** (some tasks had a second worker, for rework, after a
  restart, or a Codex worker besides the Claude one). The one left out is this task's own session, which reads the
  others' output and would count it twice.
- **Left out: Codex workers.** The lead sent 14 tasks' workers to Codex in the window (progress.md). Codex keeps no
  Claude Code transcript, so 12 of those tasks have no worker session here at all: about 9% of the window's 131 worker
  tasks. The figures below cover the 119 Claude-run tasks only. Nothing suggests Codex workers hit the traps more or
  less often.
- Worker time in the sample: **7,167 worker-minutes (119.5 hours)**. That is each session's time between its events,
  with any gap over 10 minutes counted as 10 minutes, so waiting on the lead, the user or a busy Mac isn't counted as
  work.
- Only this repository's sessions were read: the session folders of worktrees under this repository's
  `.vibeswitcher/worktrees`. `docs/lead/progress.md` was read by hand for the Codex count and for when main was red.
  No other project's sessions were opened.

## Method

`scripts/worker-rediscovery.py` (read-only) does the whole count. It reads each worker session's tool calls, results
and timestamps. Then it matches each call against a fixed list of categories: refused or blocked commands, failed lint
runs, greps for the same test helper, and `git merge` runs that hit a conflict. The categories came from a first pass
over every failed tool call and every grep repeated in 3 or more tasks. Rerun it with:

```sh
python3 -I scripts/worker-rediscovery.py            # the table and totals below
python3 -I scripts/worker-rediscovery.py --json     # the same, as JSON
python3 -I scripts/worker-rediscovery.py --days 14  # another window
```

- **A hit** is one burst of a category in a session. Calls of the same category less than 5 minutes apart are one hit.
- **Minutes lost per hit** come from transcript timestamps. Each hit is timed from the gap before the call that hit
  (writing it) to the first call of another kind after the burst (the recovery). For a failed lint, the time runs to
  the next lint run that doesn't fail the same way, or to the next report or ask_lead, whichever comes first. For a
  merge conflict, it runs from the conflicted `git merge` to the commit that resolves it. Every gap is capped at 10
  minutes and every hit at 30 minutes (60 for a merge conflict; the longest seen was 24). A conflicted merge that was
  aborted rather than committed (2 cases) isn't timed.
- **The window** always ends when the script runs, so a rerun later counts a later week.
- **A repeat** is a hit in any task except the first task to hit that category. The first hit is the discovery a tip
  would have come from, so it isn't counted as avoidable.
- **"Said today"** checks whether today's AGENTS.md or the worker brief (`Sources/VibeCore/LeadWorkflow.swift`) already
  covers the category. It is a regular expression per category over those two texts, checked by hand.

Limits. The timings are lower bounds. A refused command often costs a few seconds of tool time plus the model's
rethink, and only the gaps between events are counted. The re-test after a merge conflict isn't counted, and neither
is the lead's side of a conflict (a failed merge attempt, an audit that had to wait). Bucket (c) counts conflicts
only: duplicated work between concurrent tasks without a conflict wasn't measured. Categories that no regular
expression catches, such as a worker reading the same long file other workers read to learn the same thing, aren't
counted. Even if every per-hit time were twice as long, (a) + (c) would be 6.0%. That case is covered in the verdict.

## Repeated discoveries

Bucket: **a** = a tip from an earlier or concurrent worker would have prevented it. **b** = a line in AGENTS.md or
the brief, or a fix to the tool that misleads, would prevent it better. **c** = two concurrent tasks changed the same
file.

| Repeated discovery (own words) | Bucket | Tasks hit | Hits | Median min / hit | Mean min / hit | Minutes, all hits | Minutes, repeats only | AGENTS.md or brief says it today |
| --- | :-: | --: | --: | --: | --: | --: | --: | :-: |
| A git command with a pipe, redirect, `;` or `&&` around it is refused (most often: saving the branch diff to a file for the blind check, and the revert-and-restore pipe for a regression test) | b | 68 | 107 | 0.1 | 0.2 | 18.0 | 17.6 | yes |
| Putting a file back with `git checkout --` or `git restore` after a mutation or revert check is blocked by the safety hook | b | 23 | 25 | 0.1 | 0.1 | 3.1 | 2.9 | no |
| Where the lead test fixture is and what it offers (`LeadTeamFixture`) | b | 21 | 23 | 0.1 | 0.3 | 8.0 | 7.9 | no |
| Which helper gives a test its scratch home (`Scratch`) | b | 19 | 21 | 0.2 | 0.3 | 5.8 | 5.7 | no |
| Which helper a test uses to wait on an event (until / eventually / the hang guard) | b | 18 | 24 | 0.2 | 0.3 | 7.6 | 6.4 | no |
| Bringing the branch up to date with main hits a conflict | c | 18 | 21 | 0.4 | 3.0 | 63.4 | 55.8 | no |
| The done report is refused because changed tests weren't run under load yet | b | 14 | 19 | 0.5 | 0.5 | 8.7 | 8.3 | yes |
| The merge log path the lead sends after a failed merge is in a folder workers can't read | b | 11 | 17 | 0.1 | 0.2 | 2.8 | 2.3 | no |
| A lint is red on main itself (another project's name in the lead's record), not on the branch, and each worker works out that it isn't theirs | a | 9 | 13 | 13.7 | 16.4 | 213.4 | 157.5 | no |
| The done report is refused because the evidence misses an acceptance check | b | 8 | 8 | 0.4 | 0.6 | 4.4 | 3.4 | yes |
| PrivateWriteLint: a new raw file write needs the private-write helper or an allow-list entry | b | 8 | 9 | 1.4 | 1.5 | 13.6 | 12.2 | yes |
| TemporaryFolderLint: a test or script used the system temporary folder instead of a scratch folder | b | 8 | 8 | 2.0 | 2.7 | 21.6 | 20.9 | no |
| A foreground `sleep` to wait for a background job is refused | b | 6 | 6 | 0.1 | 0.1 | 0.5 | 0.4 | yes |
| Looking for the `Lead*.swift` sources in the app target (they live in VibeCore) | b | 6 | 6 | 0.1 | 0.0 | 0.3 | 0.2 | no |
| Where the sandbox's sheet list lives | b | 3 | 3 | 0.1 | 0.2 | 0.5 | 0.2 | yes |
| PrivateNamesLint rejects a name or email address the branch added | b | 3 | 4 | 2.8 | 2.8 | 11.2 | 5.1 | no |

The 21 conflicts (row c) touched 17 files. Four files conflicted in more than one task: `LeadToolset.swift` (4
tasks), `Sandbox.swift` (3), `LeadMergeBatch.swift` (3) and `Web/app.js` (2). These are the files that collect a line
for every new tool, sheet or merge rule.

What the first pass found that isn't a repeat: no worker ran a bare `swift test` and hit its refusal (15 tasks ran
`swift build` or `swift test` directly, all as compile checks that worked). Waits on the Mac-wide `vs-heavy` slots (15
tasks) are contention, not rediscovery, and aren't counted. The red-on-main lint row is one incident: the lint failed
on main from before 11:11 until the fix to the lead's record at 15:24 on 2026-11-12, and 9 tasks hit it in that window.

## Totals

| | Worker-minutes | Share of worker time (7,167 min) |
| --- | --: | --: |
| All repeats (a + b + c) | 307 | 4.3% |
| (a) a tip from a concurrent or earlier worker would have prevented it | 158 | 2.2% |
| (b) a line in AGENTS.md or the brief, or a tool fix, would prevent it better | 94 | 1.3% |
| (c) two concurrent tasks changed the same file and conflicted | 56 | 0.8% |
| **(a) + (c), the board's case** | **213** | **3.0%** |

The rows don't sum exactly because of rounding. Over 7 days and 119 tasks, all repeats together cost about 5 hours of
worker time, about 2.6 minutes per task.

## Verdict

**Neither a notes board nor nothing: fix AGENTS.md and the brief, and make a red main visible.** The threshold is the
proposed one: a board is worth it if (a) + (c) is over 5% of worker time. Measured, it is 3.0%. Even with every per-hit
time doubled, it is 6.0%, and all of the (a) share, 74% of (a) + (c), is a single incident. That incident (a lint red on main for four
hours, found again by 9 workers) is better fixed at its source than by a board. The lead's record shouldn't go
unchecked onto main. Failing that, VibeSwitcher could tell every running worker once that main fails a named test, the
way it already tells a worker its branch conflicts. The conflict share (c) wouldn't shrink with tips either. Two workers
editing `LeadToolset.swift` still conflict when they know about each other, so that's a job for backlog B10 (conflict
forecast) and the lead's scheduling. The (b) repeats are cheap to remove:

- Say in AGENTS.md where the test helpers are and what they're for: `LeadTeamFixture`, `Scratch` and the wait helpers.
  68 hits in a week were searches for them.
- Make the brief's own recipes pass the git rule. The blind check needs the branch diff in a file, and the regression
  check pipes `git diff` into `git apply -R`. Both are refused as written, and 68 tasks hit the refusal at least once.
  Give a form that is allowed, and say how to put a file back after a mutation check when `git checkout --` is blocked.
- Say in AGENTS.md what TemporaryFolderLint wants: a scratch folder, never the system temporary folder.
- Send workers a merge log they can read, not a path in the lead's private folder.

Revisit the board if a second shared-trap incident like the one on 2026-11-12 shows up within a month, or if a rerun of
this script puts (a) + (c) over 5%.
