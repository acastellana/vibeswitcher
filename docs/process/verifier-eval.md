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
scripts/verifier-eval.sh --all --total-usd 80   # the same, stopped at about $80 (a case can run a little past its cap)
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
A run measuring a change to REVIEW.md itself has to pass that branch's blob (`--guide $(git rev-parse HEAD:REVIEW.md)`), or
it scores main's.

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

### 2026-11-09, --all (verifier-eval-failed): 12 of 12 cases, checklist auto, model fable. The first baseline with REVIEW.md

The first full run with today's REVIEW.md in every case's clone, read the way a real audit reads it, and the first
that says which Claude Code ran and how many permissions were denied. Its summary, as the script printed it:

```
verifier eval, --all, checklist auto, Claude Code 2.1.319, REVIEW.md 5ba8d39b
bugs found: 7 of 14 (4 as Important) in 9 bug cases
false alarms: 0 Important finding(s) on 3 clean cases
tokens: 33007719; cost: $53.34; 161 min
per case:
  a-fix-s-regression: 2 of 3 found (1 as Important), $3.58, 5 permission denial(s)
  a-slash-command-that: 0 of 1 found (0 as Important), $3.81, 1 permission denial(s)
  the-briefing-uses: 1 of 1 found (0 as Important), $3.40, 0 permission denial(s)
  ending-a-session-ends: 1 of 3 found (0 as Important), $5.58, 3 permission denial(s)
  memory-the-host-parser: 1 of 1 found (1 as Important), $6.50, 4 permission denial(s)
  lead-record-commits: 0 of 1 found (0 as Important), $3.44, 1 permission denial(s)
  a-base-branch-the: 1 of 2 found (1 as Important), $4.73, 4 permission denial(s)
  finished-work-lands: 0 of 1 found (0 as Important), $5.61, 1 permission denial(s)
  steadier-merge-gate: 1 of 1 found (1 as Important), $4.50, 1 permission denial(s)
  the-lead-s-rules: clean, 0 Important finding(s), $4.14, 8 permission denial(s)
  the-phone-shows-needs: clean, 0 Important finding(s), $2.36, 1 permission denial(s)
  every-task-gets-a: clean, 0 Important finding(s), $5.68, 0 permission denial(s)
```

No case errored or was left unscored. An earlier attempt the same day stopped at 3 of 12 when its session went away,
and none of it is counted here. The denial figures are from re-scoring this run's kept streams offline (`--score`, then
`--summary`), after the script was fixed to add up every result event's denials instead of reading only the last
event's. Bugs found, Important findings, false alarms, tokens, cost and minutes came out the same.

| Case | Time | By place, 2026-11-01 → now | What the findings say |
|---|---|---|---|
| a-fix-s-regression | 9.7 min | 3 → 2, Important 1 → 1 | F1 (`--remote`/`--exec`) found in substance, as Important at :69, run in a scratch folder. F3 (the symlink) by a Nit at :69, its probe denied. F2 (`--add-file`) not reported. The places are crossed: :80 matched a Nit on abbreviated `--out=`. |
| a-slash-command-that | 7.5 min | 0 → 0 | Missed. A Nit at ChatSync.swift:194 is about another value (`unreadFooter`), though REVIEW.md has the rule on state shared by sessions. |
| the-briefing-uses | 9.3 min | 1 → 1, Important 0 → 0 | By place only: the Nit at :540 says each return to the General tab reads the key again; the bug is that reopening Settings never does. Missed in substance. |
| ending-a-session-ends | 25.5 min | 2 → 1, Important 1 → 0 | By place only: the Nit at :64 is about a fixed sleep, not F2's `terminationReason`. F1 and F3 missed. Its two Important findings are elsewhere (the temporary-folder lint failing, `realpath` in SessionStrays.swift). |
| memory-the-host-parser | 18.9 min | 1 → 1, Important 1 → 1 | Found as Important at HostedSession.swift:634, in substance. |
| lead-record-commits | 10.3 min | 0 → 0 | Scored missed, found in substance: a Nit at Worktrees.swift:822 says a records change that merges cleanly is kept, and calls it not blocking. That's 33 lines from :789, outside the 3 the score allows. |
| a-base-branch-the | 13.9 min | 1 → 1, Important 1 → 1 | F1 as Important at LeadBaseMoves.swift:353, from PrivateWriteLint. F2 missed, as before. |
| finished-work-lands | 15.9 min | 0 → 0 | Scored missed, found in substance as Important: at LeadAdvance.swift:272 it says auto_advance and the hold are read once before the loop at :307, and quotes REVIEW.md's rule. That's 35 lines from :307. |
| steadier-merge-gate | 11.4 min | 0 → 1, Important 0 → 1 | By place only: the Important at MergeRerun.swift:34 is about parameterized test names; nothing on a crashed or stopped run rerunning with --filter. Missed in substance, as before. |
| the-lead-s-rules | 13.7 min | clean → clean | No false alarm: 5 findings, none Important. |
| the-phone-shows-needs | 12.8 min | clean → clean | No false alarm: 3 findings, none Important. |
| every-task-gets-a | 12.4 min | clean → clean | No false alarm: 6 Nits and 1 Pre-existing. |

**Against 2026-11-01, by the script's score.** Bugs found 8 → 7 of 14, as Important 4 → 4, false alarms 0 → 0 on 3
clean cases. Tokens 28.9 M → 33.0 M, cost $49.81 → $53.34, 144 → 161 min. Three cases moved by one bug each, two down
and one up, and the up is the place-only match above. That's one sample of each case: it shows no gain from REVIEW.md
and no regression. Claude Code's version wasn't recorded on 2026-11-01, so it may differ as well as REVIEW.md.

**By substance.** Read finding by finding, this run found 6 of 14 known bugs, 4 of them as Important: a-fix-s-regression
F1 and F3 (F3 a Nit), memory-the-host-parser, lead-record-commits (a Nit), a-base-branch-the F1, finished-work-lands.
The count by place is 7, from three matches that aren't the bug (the-briefing-uses, ending-a-session-ends,
steadier-merge-gate) and two real finds too far from their place to score (lead-record-commits, finished-work-lands).
This is one reader's judgment and covers this run only: the 2026-11-01 findings weren't reread, so compare the two runs
by place. When a prompt change is measured against this baseline, read the findings too.

**What to keep in mind when using it.**
- REVIEW.md has hindsight on some cases. Its rules came from real misses on the board, and some match these cases: the
  allow-rule options (`--remote`, `--exec`, `--add-file`, a symlinked folder) are a-fix-s-regression's bugs, "read once,
  then acted on" is finished-work-lands', and "one session's state kept in a value all sessions share" is
  a-slash-command-that's. A score on those says less about a new bug of the same kind.
- 29 permission denials in 10 cases, all of them Bash commands the verifier was refused. Only counted, but two of
  a-fix-s-regression's Nits say "not run: my sandbox denied the probe", so a denial can weaken a finding's evidence.
- 10 of 12 cases report the same Pre-existing finding: `scripts/test-under-load.sh` at the case's old commit looks for
  one test bundle, and today's toolchain builds one per target. It comes from replaying old commits on a new toolchain,
  and those verifiers couldn't do the under-load check.

### 2026-11-09 and 2026-11-12, --all (audits-settle-their): 12 of 12 cases, checklist auto, model fable

The prompt with a doubt settled, the invariant named and walked, callers read before an Important finding and additions
nobody asked for named, with this branch's REVIEW.md (blob a1729417, its three new lines on skipped states, passed with
`--guide`). It ran in two parts into one folder. On 2026-11-09 the account hit its Fable usage limit (HTTP 429) six
minutes into a-base-branch-the, after six cases had been scored. On 2026-11-12, with the prompt and REVIEW.md unchanged,
the six unscored cases ran again one by one into the same folder (`--out`, each capped at what was left of $80; the
first's stream says `claude-fable-5-2`), and `--summary` gave the 12-case total. The six failed attempts are kept in
the run folder's `limit-hit-20261109/`. Claude Code moved from 2.1.319 to 2.1.322 between the two parts. As the script
printed it:

```
verifier eval, --all, checklist auto, Claude Code 2.1.319, 2.1.322, REVIEW.md a1729417
bugs found: 10 of 14 (7 as Important) in 9 bug cases
false alarms: 2 Important finding(s) on 3 clean cases
tokens: 26710474; cost: $43.22; 182 min
per case:
  a-fix-s-regression: 2 of 3 found (1 as Important), $4.15, 2 permission denial(s)
  a-slash-command-that: 0 of 1 found (0 as Important), $4.41, 0 permission denial(s)
  the-briefing-uses: 1 of 1 found (0 as Important), $4.09, 1 permission denial(s)
  ending-a-session-ends: 1 of 3 found (1 as Important), $5.93, 2 permission denial(s)
  memory-the-host-parser: 1 of 1 found (1 as Important), $3.91, 2 permission denial(s)
  lead-record-commits: 1 of 1 found (0 as Important), $3.15, 1 permission denial(s)
  a-base-branch-the: 2 of 2 found (2 as Important), $2.25, 0 permission denial(s)
  finished-work-lands: 1 of 1 found (1 as Important), $3.99, 2 permission denial(s)
  steadier-merge-gate: 1 of 1 found (1 as Important), $2.08, 0 permission denial(s)
  the-lead-s-rules: clean, 0 Important finding(s), $4.16, 0 permission denial(s)
  the-phone-shows-needs: clean, 1 Important finding(s) (false alarm), $1.52, 0 permission denial(s)
  every-task-gets-a: clean, 1 Important finding(s) (false alarm), $3.58, 0 permission denial(s)
```

With the $2.91 the 429'd attempt spent, the whole eval cost $46.13.

| Case | By place, baseline → now | What the findings say |
|---|---|---|
| a-fix-s-regression | 2 → 2, Important 1 → 1 | F1 and F2 both found as Important at :69, each run in a scratch folder (the baseline didn't report F2; 2026-11-01 had it). F3 by a Nit at :69, `Unresolved:` partway through its evidence, its probe refused by the verifier's own rules, and played down. The Nit matched by place at :76 is something else (the `..` denies being broad). |
| a-slash-command-that | 0 → 0 | Missed. Its one Important (:191) and a Nit on `unreadFooter` are elsewhere. |
| the-briefing-uses | 1 → 1, Important 0 → 0 | By place only, as before: the Nit at :540 says each return to General reads the key again. Missed in substance. |
| ending-a-session-ends | 1 → 1, Important 0 → 1 | By place only: the Important at :65 is a fixed 6 s wait passing vacuously under load, not F2's `terminationReason`. F1 and F3 missed. |
| memory-the-host-parser | 1 → 1, Important 1 → 1 | Found as Important at :634, naming the callers that reach it. |
| lead-record-commits | 0 → 1, Important 0 → 0 | Found in substance at :788, within scoring distance now, but filed **Pre-existing** ("unchanged from main") though the branch adds that function and the verifier's own stated invariant is the one it breaks. |
| a-base-branch-the | 1 → 2, Important 1 → 2 | F1 as Important, from PrivateWriteLint, as before. **F2 found in substance as Important for the first time in four runs**: a team commit whose PostToolUse isn't recorded yet leaves `move.team` nil, so a typed `! git` within 30 s takes it as the user's. It names the guards read (`move.team`, `move.waiting`, the 30 s and used-once limits), the one test (which records the team's PostToolUse before the look) and the contract line it breaks. |
| finished-work-lands | 0 → 1, Important 0 → 1 | Found as Important in substance, as in the baseline, now at :307 itself, so it scores. It names review(), LeadAdvance.merge, LeadToolset.merge and configure's lock as read, and the test that only flips the switch between passes. A second Important (a hung merge retried on every pass) isn't a known bug. |
| steadier-merge-gate | 1 → 1, Important 1 → 1 | **Found in substance as Important for the first time in four runs** (the baseline's match was by place only): a crashed run's unfinished tests become the rerun's `--filter`, so the tests that never started never run. It names LeadToolset.merge `.passedOnRerun` and the test that asserts the crashed test goes into the filter. REVIEW.md's new line is this bug. |
| the-lead-s-rules | clean → clean | No false alarm: 5 Nits. |
| the-phone-shows-needs | clean, 0 → 1 Important | **Counted as a false alarm, and it may be a real bug.** The status row now carries `shownStatus`, so a worker waiting on its lead shows `working`, and app.js's quick-reply guard (`session.status === 'needsInput'`) no longer holds a chip back: tapping one types text and Enter into the worker's open permission prompt. Main still has both lines unchanged (PhoneAccess.swift:723, app.js:1234), and the server's input route doesn't check either. Not run, only read. A real bug, not a false alarm, if a phone user can open a worker's session and tap a chip. |
| every-task-gets-a | clean, 0 → 1 Important | **A false alarm on a fact.** It says the price table's Sonnet 5.5 cache read ($0.20) doubles the source's $0.10, quoting the claude-api skill it loaded in the run, which does say $0.10. The copy of that skill on this Mac (marketplaces/anthropic-agent-skills/skills/claude-api/SKILL.md) says $0.20, as the code does, and so did the table's source when the task ran. The doubt rule worked as written: it settled the doubt from a source and raised it. The source was wrong or out of date. |

**Three runs, by substance** (one reader's judgment; the baseline's from its own entry above, Opus's as the lead gave it
from audit-eval-on-opus, the 2026-11-12 run of main's prompt):

| | Found | As Important | False alarms on 3 clean cases |
|---|---|---|---|
| Baseline, main's prompt, Fable (2026-11-09) | 6 of 14 | 4 | 0 |
| Main's prompt, Opus (2026-11-12) | 7 of 14 | 6 | not given here |
| This prompt, Fable | 9 of 14 | 7 | 2 by the script; 1 clearly false, 1 contestable |

By the script's score: 7 → 10 of 14 found, 4 → 7 as Important, false alarms 0 → 2. The numbers in the rest of this entry are by substance.

**By class, the 14 known bugs.**

| Bug | Baseline | This run |
|---|---|---|
| a-fix F1 (`--remote`/`--exec`) | Important | Important |
| a-fix F2 (`--add-file`) | missed | Important |
| a-fix F3 (symlinked folder) | weak evidence (Nit, probe denied) | weak evidence (Nit, probe denied) |
| a-slash-command-that | missed | missed |
| the-briefing-uses | missed | missed |
| ending F1, F2, F3 | missed | missed |
| memory-the-host-parser | Important | Important |
| lead-record-commits | too little weight (Nit) | too little weight (Pre-existing) |
| a-base F1 (lint) | Important | Important |
| a-base F2 (team move in flight) | missed | Important |
| finished-work-lands | Important (out of place) | Important |
| steadier-merge-gate | missed | Important |

Baseline: 4 Important, 1 weak evidence, 1 too little weight, 8 missed. This run: 7 Important, 1 weak evidence, 1 too
little weight, 5 missed. **The class that moved is missed → found as Important, by three bugs.** Two of the three
(a-base F2, steadier-merge-gate) are the bugs this branch's REVIEW.md lines were written from. The third (a-fix F2) was
found as Important on 2026-11-01 too, so it may be one run's luck. The too-little-weight and weak-evidence classes didn't
move. Fairly non-blocking of these: a-fix F3 arguably, as it needs a branch that tracks a symlink, though the board fixed
it as Important. lead-record-commits isn't: the contract says the base's records are kept exactly.

**Against the targets.**
- The four Nit-only bugs as Important (a-fix F1 and F3, the-briefing-uses, ending F2), target 2 more than the baseline:
  1 → 1, so **+0, not met**. The doubt rule didn't lift the bugs it was aimed at. a-fix F1 was Important in both runs.
  F3 is still a played-down Nit with its probe denied. The other two are still missed, not parked.
- The three state bugs, target at least 2 found: **3 of 3 found in substance, 2 as Important, met**, with the
  hindsight below. lead-record-commits is found but filed Pre-existing, which never holds a merge.
- 0 Important on clean cases: **not met**, 2 by the script. every-task-gets-a's is false (a stale source quoted
  faithfully). the-phone-shows-needs' may be a real bug the clean label didn't know of. The lead should decide, as it
  decides whether that case stays clean.

**Whether the prompt's lines were followed.** 12 of 12 summaries name an invariant. Of the 9 Important findings in the
six cases run on 2026-11-12, 8 name the callers, guards or tests read, and the ninth is lint output. Four Nits are
`Unresolved:`, three of them in the form asked for (the deciding fact and the command or record that settles it: two
about acceptance checks only a done report shows, one in the-briefing-uses), and one has it partway through (a-fix F3).
**Unrequested additions:** there's no eval case for them, so only false alarms can be checked. every-task-gets-a has three
"edit outside the boundaries" Nits (Worktrees.swift, BatchSummary.swift, Sandbox.swift), and none was raised to
Important. The eval has no done report, so whether the rule stays quiet on routine calls a worker listed wasn't tested.
Five Nits in the bug cases quote the closest contract line, and all of them stayed Nits.

**What this can't say.** It's one run of each case. REVIEW.md's hindsight now covers six of the nine bug cases:
a-fix-s-regression, a-slash-command-that and finished-work-lands from the baseline's note, plus steadier-merge-gate,
a-base-branch-the (F2) and lead-record-commits, whose bugs are this branch's three new lines. Those six cases' scores
say less about a new bug of the same kind, and two of this run's three gains are among them. The gap the run shows: the
doubt rule closes Nit as a parking place but not Pre-existing (lead-record-commits), which never fails the task. The
Pre-existing sentence is a separate, later change. The new rule also raised a fact it settled from a stale source
(every-task-gets-a). Cost per scored case fell from $4.45 in the baseline to $3.60.
