# Backtest: would a fresh reader of contracts catch what later went wrong?

Backtest for idea 1 in [the elephant-goldfish review](google-elephant-goldfish-model.md): a cheap headless model reads only a contract, before its worker starts, and says what's being asked, which design choices the worker would have to guess, and whether each acceptance check can be done inside the boundaries.

## Verdict: don't build

The reader doesn't tell contracts that later went wrong from contracts that didn't. It flags 97% of both groups. A contract that later needed changing gets a mean of 4.5 flags, and a clean one gets 4.1 (AUC 0.57, 95% interval 0.48 to 0.66, where 0.5 is a coin toss).

When a contract did go wrong, the reader named the actual problem about one time in five (15 of 70, checked by hand). That is a real signal, but it arrives inside 4 to 5 flags on every contract, so the lead would have to read all of them, on the clean contracts too. Only about 7% of the flags it raised on the changed contracts named what later changed. Money isn't the obstacle: the whole backtest cost $0.52, about $0.0015 a reader call. The cost is the lead's attention, and a gate that fires on 97% of contracts doesn't direct it anywhere.

## Method

**First versions.** The board keeps only each contract's latest text, so the first versions come from the lead's own `add_task` calls in its session transcripts. As a check, 273 of the 286 matched tasks with no later amendment had exactly the board's text. Of the other 13, 11 are tasks created from a finding, whose call carries no text, and 2 differ from the board in some field. All 13 were excluded. No contract text appears in this report; cases are numbered only in the working files.

**Group A, went wrong later (70).** Finished tasks whose contract was later amended, re-rolled, or audited "suspect" or "violation": 66 amended, 13 audited suspect or violation, 1 re-rolled (they overlap). All 14 suspect, violation or re-rolled tasks are in; the rest are a seeded random draw from the 119 eligible. The board keeps only a task's last setback, so earlier "suspect" verdicts that a later setback replaced aren't counted.

**Group B, passed clean (70).** Tasks with no amendment and no context note, whose first audit passed (one round, complete and clean, no Important finding). Each is the unused task nearest in time to its group A case, so the two groups cover nearly the same weeks (2026-10-17 to 2026-11-08 for A, 2026-10-20 to 2026-11-08 for B). Median contract size is 2.2 KB for A and 2.1 KB for B, and contract size doesn't predict flag count (correlation 0.04).

**The reader.** Claude Haiku 5.5 through headless `claude -p`, with no tools and no session saved, given only the contract's first version, twice per contract. It answers the three questions as JSON and marks each guess "material" or "minor". A **flag** is a material guess, or an acceptance check it answers "no" or "unclear".

**Matching.** A second Haiku call compared the reader's flags with what later happened on each group A case: "yes" is the same problem, "partial" the same area only. A third labelled each case's later change by kind. I then read all 25 "yes" verdicts by hand against the record and kept 15; a sample of 12 "partial" verdicts held none that should have been "yes". A control ran the scorer on each case's later change against a different contract's flags, to check it wasn't passing anything.

**Rule fixed first.** Before any full-run result was read (only a 34-case pilot of group A had been seen), the rule was: build only if the AUC is at least 0.65 with its interval's lower end above 0.5, and some threshold has A's flag rate at least 20 points above B's with B's at most 40%, and the reader names the problem in at least 40% of contract gaps, at least twice the control.

## Results

### How often the reader flags something

| Flag count at least | Group A (later went wrong) | Group B (passed clean) | Difference | Fisher p |
|---|---|---|---|---|
| 1 (any flag) | 68/70 (97%) | 68/70 (97%) | 0 | 1.00 |
| 2 | 67/70 (96%) | 64/70 (91%) | +4 points | 0.49 |
| 3 | 59/70 (84%) | 53/70 (76%) | +9 | 0.29 |
| 4 | 50/70 (71%) | 41/70 (59%) | +13 | 0.16 |
| 5 | 34/70 (49%) | 23/70 (33%) | +16 | 0.09 |
| 6 | 21/70 (30%) | 21/70 (30%) | 0 | 1.00 |

- **Overall verdict "needs fixing":** 66/70 (94%) against 65/70 (93%).
- **Flag count separation:** AUC 0.57 (0.48 to 0.66). The second run of the reader gave 0.54.
- **Acceptance-check flags alone:** AUC 0.55 (0.46 to 0.63), with 63/70 flagged against 58/70. Checks answered a flat "no" were too rare to use (2/70 against 0/70).
- **Suspect or violation tasks against B:** AUC 0.50.
- **Repeatability:** two runs on the same contract gave the same overall verdict on 125 of 140 and differed by a median of one flag.

### How often the flag matches what changed later

| Later change (group A) | Cases | Scorer "yes" | Hand-checked "yes" |
|---|---|---|---|
| All | 70 | 25 (36%) | 15 (21%, interval 13 to 32) |
| Labelled a contract gap | 22 | 12 (55%) | 8 (36%, 20 to 57) |
| Boundary omitted something the work needed | 19 | 9 | 7 (37%) |
| Requirement or design left open | 24 | 10 | 6 (25%) |
| Missing environment fact | 3 | 2 | 1 |
| Audit findings relayed, contract not at fault | 9 | 2 | 0 |
| Scheduling or a later change of mind | 15 | 2 | 1 |

A further 36 of the 70 scored "partial": the same area but a different problem. The shuffled control scored "yes" on 1 of 70 (1%), so the scorer does separate matching from non-matching flags. Among group A's 317 flags, about 22 (7%) named what later changed.

The two gap rows don't add up to the kind rows because the "contract gap" label is a separate judgement, and a noisy one: several boundary cases I'd count as gaps were labelled otherwise.

### Against the rule

| Condition | Needed | Got | Result |
|---|---|---|---|
| Separation | AUC at least 0.65, interval above 0.5 | 0.57 (0.48 to 0.66) | **Fails** |
| Usable threshold | At least +20 points, with B at most 40% | Best is +16 at 5 flags, B at 33% | **Fails** |
| Right problem | At least 40% of gaps, twice the control | Scorer: 55%, control 5%. By hand: 36% | Passes on the scorer, fails by hand |

The first two fail on any reading, so the verdict doesn't depend on the third.

## What this does and doesn't show

- It shows that this reader, on this model, is not a useful filter for contracts. It doesn't show that the contract gaps aren't real: 15 cases have a flag that named a real later change, and the boundary gaps come closest to what idea 1 wanted.
- Narrowing to the acceptance-check question doesn't fix it (AUC 0.55). This was looked at after the rule was fixed, so treat it only as a reason not to expect an easy rescue.
- Group B isn't proof of a perfect contract. A clean first audit means the work passed, and a worker may have guessed right on something the reader flagged, so some of B's flags may be fair. That makes the flags less costly than "wrong", but they still don't point the lead at the contracts that need attention.
- An amendment isn't always a defect in the contract: a third of group A's changes were relayed audit findings or scheduling, which no reader could foresee. The hand-checked rates by kind allow for that.
- The reader had only the contract, as idea 1 specifies. With the repository's file list it might check boundaries better; that's a different proposal and is untested here.

## Spend

About 520 Haiku calls cost $0.52 at list price, from `total_cost_usd` on each call, including the pilot and both reader runs. The prompts, the case lists and the per-call output are in the worker's scratch folder, not the repository.
