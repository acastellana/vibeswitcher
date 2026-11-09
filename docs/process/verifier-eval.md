# The verifier's eval set

"Our incidents are the eval": every real miss becomes a case, and a change to the verifier's prompt or model is
scored against all of them instead of guessed. `scripts/verifier-eval.sh` replays each case to one verifier, started
as an audit starts it (its prompt, permission rules, model, today's REVIEW.md and the security checklist where an
audit would put it), in a scratch clone with a scratch HOME, and scores its findings.

**When to run it.** Before merging a change to the verifier's prompt (`LeadPrompts.verifier`, the checklist, REVIEW.md
handling) or its model (`verifier_model`): `scripts/verifier-eval.sh --all`, then compare its summary with the last
one below and add the new one. The lead's brief says so where a project has the script.

```sh
scripts/verifier-eval.sh --all --dry-run        # free: every case builds its clone and prompt, no model call
scripts/verifier-eval.sh --all                  # every case, one summary (about $45–60, two hours)
scripts/verifier-eval.sh --all --total-usd 80   # the same, stopped before it can pass $80
scripts/verifier-eval.sh steadier-merge-gate    # one case
scripts/verifier-eval.sh --summary RUN_FOLDER   # an --all run's summary again, from its kept score.json files
scripts/verifier-eval.sh --patch NAME HEAD      # store a new case's audited commit as a patch (below)
```

**Cost.** A case costs what an audit does: $2.87 to $5.02 in the runs below, about 10 minutes each (1.6–2.7 M
tokens, nearly all cache reads). The set has 12 cases, so a full run is about $45–60 and, one case after another,
about two hours. Each case's `--max-usd` (20 by default) caps a runaway; `--total-usd N` caps a whole `--all` run.

**Reading a score.** One run of one case is one sample: a verifier that finds a bug once may miss it the next
time. Compare whole summaries, and rerun a case that changed before calling it a regression. A bug counts as found
when a finding names its file within 3 lines of one of its places (as the audit's vote matches findings), at any
severity; the summary also says how many were found by an Important finding, the only kind that stops a merge.
On a clean case, every Important finding is a false alarm.

**Not scored.** A run that ended with an error (Claude's budget cap, say) measures nothing about the verifier: the
summary lists it as "not scored", leaves it out of every total and exits 2, as for a case that couldn't run; its cost
is on its own line. A summary with a not-scored case is not a comparable baseline: rerun that case.

**What each summary pins.** Its first line says which Claude Code ran (`unknown` when the stream didn't say) and which
REVIEW.md (the blob from the base branch, the same for every case in the run). Each case prints its permission
denials: only counted, since a read-only verifier is denied edits by design.

**REVIEW.md.** A real audit reads the project's REVIEW.md from the base branch (`LeadRisk.reviewGuide`). None of the
cases' bases has one, so the script adds today's to the clone's base and under its branch, the same file on both, and
checks the case's diff didn't change. Summaries before 2026-11-09 were run without it.

## The cases

Bug cases are Important findings that were real and fixed: the audit raised them on the commit named, the worker
fixed them, and the re-audit closed them. Each one's place was checked against the file at that commit (the board
records the line the verifier gave), and each bug sits in code the branch adds or changes, so it's in the diff the
verifier reads, against a contract that says what the code must do. Clean cases passed their first audit with no
Important finding, and nothing in their code was fixed since.

Most audited commits aren't on any branch any more: a merge squashes or rebases a branch, and cleanup deletes
`agent/<slug>`. Those cases are stored as `scripts/verifier-eval/NAME.patch.gz` (the branch at the audited commit
against its merge-base with the base branch, main, gzipped so the repository's text lints don't read old code), and the
script refuses one whose tree on its base isn't the audited commit's. Each case's contract is the board task's own,
as text, in `scripts/verifier-eval/NAME.contract.md` (a-fix-s-regression's is its commit's message, as when it was
first scored).

| Case | Kind | Commit | Bug (board finding) | Why it's a fair test |
|---|---|---|---|---|
| a-fix-s-regression | bug, security | 87d9b1c (on project-lead) | F1–F3: the scratch export's allows let `git archive --remote/--exec` run a command, `--add-file` read any file, and a symlinked folder take `tar -x`/`mkdir -p` out of the TMPDIR (LeadLaunch.swift:80, :69, :74) | The allow rules are the diff; the guard rails it weakens are in the files the diff touches. First case, from security-checklist-for. |
| a-slash-command-that | bug, correctness | ff15460 (patch) | F1: `noMenuSince` is one value for every session and never reset on a switch, so a message held while A's picker is open is typed into it after visiting B (ChatSync.swift:199) | The branch adds the hold-and-release logic; the contract's point is that held input never goes into an open picker. |
| the-briefing-uses | bug, correctness | e42ccae (patch) | F1: the shell key is re-read in the Briefing section's `onAppear`, but Settings keeps one window, so reopening it never looks again (SettingsWindow.swift:540) | The contract says the key is "refreshed when Settings opens"; the branch adds the `onAppear`. |
| ending-a-session-ends | bug, test correctness | 0f2c444 (patch) | F1: the new test fails in the suite (:60); F2: it reads `terminationReason` of a process still running, which throws (:63); F3: its perl `setsid` is a bareword, not `POSIX::setsid`, so the job never leaves its group (:34) (EndingASessionTests.swift) | All three are in the branch's new test. F3 is hard: the contract itself wrote `perl -e 'setsid; …'`, so a verifier that trusts the contract misses it; one that runs the test sees F1. |
| memory-the-host-parser | bug, correctness | 196c2a6 (patch) | F1: long history reads take `ring.replay()`, which starts at the last reset, so lines before a clear or pager are lost (HostedSession.swift:634, also :688) | The branch adds the long-history path; the contract says the phone still scrolls back as far as before. |
| lead-record-commits | bug, correctness | c001aac (patch) | F1: `takeBaseRecords` takes the base's version only of unmerged files, so a record git merges cleanly lands with the branch's edits (Worktrees.swift:789; the fix also went in at :600) | The contract says the base's records are kept exactly; the branch adds `takeBaseRecords`. |
| a-base-branch-the | bug, security and correctness | d87df70 (patch) | F1: `BaseMoveNote.save` writes `.vibeswitcher/run` with raw `createDirectory`/`write` (LeadBaseMoves.swift:353, PrivateWriteLint fails); F2: a team session's git command still running never marks a move as the team's, so a user's typed `! git` takes it as theirs (LeadBaseMoves.swift:220, or the guard at BaseMoves.swift:112) | Both are in code the branch adds; the contract says the guard against unattributed team moves is unchanged. The board records F2 at BaseMoves.swift:404, a line that file doesn't have at this commit; the case uses where the fix went and the guard the finding describes. |
| finished-work-lands | bug, correctness | 5ba2037 (patch) | F1: a pass reads auto_advance and the per-task opt-out once, then merges or audits every task in review, so turning either off during a long merge doesn't stop the next (LeadAdvance.swift:307, or `review()` at :312) | The contract says the switch "turns all of it off" and the flag opts a task out; the branch adds the pass. |
| steadier-merge-gate | bug, correctness | 9b127cd (patch) | F1: a run that crashed or was stopped reruns with `--filter` on the tests it named, so the rest of the suite never runs and a partial pass merges (MergeRerun.swift:35, the fix at :41) | The contract says "don't weaken the gate" and only a full-suite-or-rerun pass merges; the branch adds MergeRerun. |
| the-lead-s-rules | clean | a2e23b0 (on project-lead) | Four of the lead's rules become checks in start_worker, audit, merge and add_task. Audit: complete, clean, 2 Nits. | Refusal logic in LeadToolset: a place a verifier could invent a problem. |
| the-phone-shows-needs | clean | 72de968 (on project-lead) | The phone shows "needs you" only for the user's sessions. Audit: complete, clean, 1 Nit. | Touches PhoneAccess.swift (a sensitive path), so the security checklist is in. |
| every-task-gets-a | clean | 4662802 (on project-lead) | Every finished task gets a receipt. Audit: complete, clean, 3 Nits. | 946 lines over 10 files, Worktrees.swift and Sandbox.swift among them: the checklist is in. |

Left out, and why:

- lead-secrets-out-of, a-worker-can-t: audited before findings had a file and line on the board (2026-10-18/19), so
  there's no recorded place to score against. planted-git-hooks-or: its audits had Nits only.
- host-orders-text-enter F1/F3: the recorded lines (InputOrder.swift:399, :200) don't match the files at the commits
  that could be its first audit's, so the case can't be pinned honestly.
- selecting-text-in-the: F1 and the dismissed F2/F3 are benchmark thresholds the verifier measured, not something
  the diff shows; F5 (a data race on a shared NSFont) is real, but the case would be its biggest (141 KB).
- workers-don-t-stall F1: a sentence of the brief against an acceptance check, a contract reading rather than a bug.
- phone-replies-sent-once, fail-fast-sessions, auto-advance-s-reports: their Important findings were dismissed.

## Adding a case

From the board: a fixed Important finding (`board(task)` shows it with its file:line and the round that raised it;
the task's `setback` evidence names the commit of the audit that failed). Then:

1. `scripts/verifier-eval.sh --patch NAME COMMIT` when the commit is on no branch that stays (check with
   `git branch -a --contains COMMIT`); a commit on main whose first parent is the right base needs nothing.
2. Check each place at that commit (`git show COMMIT:FILE | sed -n 'LINEp'`), and where the fix went: list both with `|`.
3. The board task's contract as `scripts/verifier-eval/NAME.contract.md` (title, goal, acceptance checks,
   boundaries, context).
4. Its line in `cases`, then `scripts/verifier-eval.sh --dry-run NAME`, and a row here.

A clean case: a task whose first audit was complete and clean with no Important finding, and no fix since in the
code it added; its line's places are `expect-no-Important`.

## Summaries

### 2026-10-26, partial (the-verifier-s-eval): 3 of 12 cases, checklist auto, model fable

Not a full run: the task allowed three paid runs, to check that new cases score as they should.

| Case | Score | Cost | What the findings say |
|---|---|---|---|
| steadier-merge-gate | 0 of 1 found | $3.57, 10.1 min | Missed: 3 Nits on the rerun's reporting and a Pre-existing test failure; nothing on a crashed or stopped run being rerun with --filter. A real miss (no finding mentions it). |
| a-base-branch-the | 2 of 2 by place, 1 by an Important finding | $5.02, 9.8 min | F1 found as Important (the PrivateWriteLint failure, from the full suite run). F2 matched only by place: a Nit at BaseMoves.swift:114 about which typed lines `check()` counts, not about a team command still running. In substance F2 was missed. |
| the-phone-shows-needs | clean, 0 Important | $2.87, 9.6 min | No false alarm: 3 findings, none Important. |

Bugs found: 2 of 3 by place, 1 of 3 by substance and as Important. False alarms: 0 on 1 clean case. Tokens 6.8 M
in total, cost $11.46. The other nine cases have resolved in a dry run (`--all --dry-run`: 12 of 12) but haven't
been scored. Before this branch, a-fix-s-regression scored 3 of 3 with the checklist and 0 of 3 without
(security-checklist-for).

### 2026-11-01, --all (verifiers-don-t-run): 12 of 12 cases, checklist auto, model fable

The first full run, scoring the prompt in which a single verifier no longer runs the full suite of its own (merge's
run is the one), except on a branch touching shared test or build infrastructure; it names the lint tests instead.
The eval's clones have no test_command, so the prompt said the "no test_command" form of that rule.

| Case | Score | Cost | What the findings say |
|---|---|---|---|
| a-fix-s-regression | 3 of 3 found, 1 by an Important finding | $3.78, 9.5 min | F2 (:69) as Important; F1 (:81) and F3 (:76) by Nits. |
| a-slash-command-that | 0 of 1 found | $4.17, 7.4 min | Missed: nothing at ChatSync.swift:199 (its one Important is elsewhere). |
| the-briefing-uses | 1 of 1 found | $3.82, 9.8 min | Found by a Nit at SettingsWindow.swift:540. |
| ending-a-session-ends | 2 of 3 found, 1 by an Important finding | $5.86, 38.6 min | F1 (:62) as Important, F2 (:65) by a Nit; F3 (the bareword `setsid`, :34) missed. |
| memory-the-host-parser | 1 of 1 found, as Important | $5.52, 13.2 min | Found as Important at HostedSession.swift:634. |
| lead-record-commits | 0 of 1 found | $2.90, 6.3 min | Missed: nothing at Worktrees.swift:789 or :600. |
| a-base-branch-the | 1 of 2 found, 1 by an Important finding | $4.86, 10.1 min | F1 (the PrivateWriteLint failure) as Important at LeadBaseMoves.swift:353, with no full suite run; F2 missed (in substance, as before). |
| finished-work-lands | 0 of 1 found | $5.36, 11.0 min | Missed: nothing at LeadAdvance.swift:307 or :312. |
| steadier-merge-gate | 0 of 1 found | $3.28, 9.5 min | Missed, as before. |
| the-lead-s-rules | clean, 0 Important | $3.36, 10.8 min | No false alarm. |
| the-phone-shows-needs | clean, 0 Important | $1.65, 7.3 min | No false alarm. |
| every-task-gets-a | clean, 0 Important | $5.26, 10.4 min | No false alarm: 7 Nits. |

Bugs found: 8 of 14 by place (4 as Important) in 9 bug cases. False alarms: 0 Important findings on 3 clean cases.
Tokens 28.9 M in total, cost $49.81, 144 min. Against the last summary: no case caught before is missed now.
a-base-branch-the's F1 is still found as Important, now through the lints instead of a full run; its F2, matched
only by place before and missed in substance, is missed; steadier-merge-gate 0 of 1 and the-phone-shows-needs clean,
as before; a-fix-s-regression 3 of 3, as with the checklist before.
