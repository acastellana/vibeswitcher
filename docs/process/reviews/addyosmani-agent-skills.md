# Ideas review: addyosmani/agent-skills

- **Repository:** https://github.com/addyosmani/agent-skills
- **Commit read:** `301b02b12bff98e4688e6984af6556802322bbde` (2026-11-01, shallow clone; read as documents, nothing run or installed)
- **Licence:** MIT, copyright 2025 Addy Osmani. Reuse needs the notice kept. This report quotes only short phrases; the fixtures and the floor-guard script should be rewritten for Swift rather than copied, or copied with the notice.

**What it really is.** A pack of 25 Markdown skills for coding agents, covering spec to ship, with 9 slash commands, 4 personas and some checklists, installable as a plugin in Claude Code and other tools. It has no runtime and no orchestrator: its own rule is that "the user (or a slash command) is the orchestrator" (`references/orchestration-patterns.md:5`). Most of its advice is good general practice that VibeSwitcher's briefs already enforce more strictly, so the part worth taking is `evals/` and a few precise review rules.

## Ideas, ranked

Ranking is expected effect on the goal divided by cost. Numbers quoted from the repository are its own, from 3 to 9 runs per prompt, and I didn't rerun them.

### 1. A run that didn't finish gets no score

- **Source:** `evals/README.md:45`: only runs with an explicit successful end reach the grader; failed ones "produce no score".
- **VibeSwitcher today:** `scripts/verifier-eval.sh:383` writes `"error"` into `score.json`, but nothing reads it. The summary adds every score (`:150`, totals to `:168`), and the case exits 0 on a clean case with no Important finding (`:386`). A verifier stopped by `--max-budget-usd` (`:286`), or any run that ends with an error result, therefore counts as "no false alarm" on a clean case and as a miss on a bug case. (A process that dies with no result at all is already reported as "couldn't run", `:319-321`.) No summary so far in `docs/process/verifier-eval.md` mentions an errored run, so I found no past result this changed.
- **Change:** the summary lists an errored case as "not scored", leaves it out of the totals, and exits 2, as it does for "couldn't run". It also prints the count of permission denials per case. Don't reject on denials as the repository does, since a read-only verifier is denied edits by design.
- **Serves:** fewer issues. This eval decides whether verifier prompt changes merge (`Sources/VibeCore/LeadWorkflow.swift:1086`).
- **Size:** S.
- **Risk:** low. The script is a sensitive path, so it gets an audit (decision 2026-11-07 20:06).
- **Measure:** a dry test with a made-up `score.json` holding `error: true` shows "not scored" and exit 2 (fails today); then the count of errored cases per full run.
- **Verdict:** adopt.

### 2. The risk check also sees tests made easier

- **Source:** `skills/constraint-driven-development/references/floor-guard.md:100-105` (an assertion removed from a test that stayed) and `SKILL.md:216`.
- **VibeSwitcher today:** the test census catches tests removed by name and an added `@Test(.disabled…)` (`Sources/VibeCore/LeadRisk.swift:204`, `:251`). The risk patterns don't read test files (`LeadRisk.swift:26`, `:170`). A review none branch can drop every `#expect` from a test that keeps its name and nothing raises it. The ban is prose only (`LeadWorkflow.swift:1194`), and on review none a verifier reads the diff only in the 10% random sample (`audit_sample_percent`, `:626`).
- **Change:** a sibling of `testCensus` raises to audit when a test file's net count of `#expect`, `#require` and `XCTAssert*` falls, or when the branch adds `XCTSkip`, `withKnownIssue`, `.enabled(if: false)` or `@Suite(.disabled`. Use the net count per file, not the repository's per-removed-line rule, so a rewritten assertion doesn't trigger it.
- **Serves:** safer, fewer issues.
- **Size:** S.
- **Risk:** extra audits on test refactors. It only raises, as the rest of the check does.
- **Measure:** first backtest on the last 100 merged diffs (free): how many would have raised, and how many of those were real. Afterwards, raises per 30 merges and the share whose audit found something.
- **Verdict:** adapt. Decision 2026-11-06 22:35 prefers an incident before a new check, so take it only if the backtest raises few merges. The census itself was built from a red-team finding without an incident.

### 3. Before an Important finding, read what reaches that line

- **Source:** `skills/code-review-and-quality/SKILL.md:181` (check each finding against the callers, guards and tests that reach it, and drop it if they rule it out; "Zero findings is a valid result"). Tested by `evals/cases/code-review-and-quality.json` cases 2 to 4.
- **VibeSwitcher today:** the evidence rule asks for file, line and what shows it (`LeadWorkflow.swift:1519`). Only the finders' bug focus mentions callers (`:1307`), and the default is one verifier with no focus (`audit_finders: 1`, `:587`; its check text is `:1495`). Three tasks were left out of the eval because their Important findings were dismissed (`docs/process/verifier-eval.md:68`).
- **Change:** one sentence in the single verifier's check: before raising an Important finding, read the callers, guards and tests that reach that line, and name what you read in the evidence.
- **Serves:** fewer false holds, cheaper (fewer audit rounds).
- **Size:** S, plus the required eval run (about $45–60).
- **Risk:** the verifier talks itself out of a real bug. Recall is already imperfect (`steadier-merge-gate` was missed, 2026-10-26), so the eval has to show no drop.
- **Measure:** `scripts/verifier-eval.sh --all` before and after (bugs found, false alarms); then the share of Important findings dismissed or closed on a worker's disagreement, over at least 30 audits.
- **Verdict:** adopt, if the eval holds.

### 4. Record the Claude Code version with each result

- **Source:** `evals/README.md:65` (pin the model and record the CLI version, "because the CLI updates itself") and `:71`: the same skill text fired 6 of 6 on 2.1.283 and 1 of 6 on 2.1.312.
- **VibeSwitcher today:** the merge trailers carry the task, review, models, build and contract hash, but not the CLI (`Sources/VibeCore/LeadProvenance.swift:13-18`). `scripts/verifier-eval.sh:285` pins the model and doesn't say which CLI ran. Claude Code's updates do reach VibeSwitcher: the sandbox has a command just for the session titles 2.1.311 uses (`docs/process/product-inventory.md:350`).
- **Change:** a `VS-CLI` trailer alongside backlog A2's, and the version on the first line of each eval summary. It adds a field to A2 and takes the same value as the models.
- **Serves:** fewer issues (a change in behaviour can be tied to its cause), and B8's noise floor.
- **Size:** S.
- **Risk:** low. Keep to `LeadProvenance.allowed`, and write "unknown" when it can't be read.
- **Measure:** count how many impact ledger windows (`docs/process/impact.md`) straddle a CLI update. If many do, verdicts in those windows are confounded.
- **Verdict:** adopt.

### 5. Workers list the behaviour the contract left open

- **Source:** `skills/using-agent-skills/SKILL.md:49-61` (surface assumptions) and `skills/incremental-implementation/SKILL.md:129` (noticed but not touching).
- **VibeSwitcher today:** a worker makes routine calls itself (a small file outside the boundaries, naming, layout), lists each in its report, and asks the lead about direction, scope changes or anything risky (`LeadWorkflow.swift:785-787`). Its report also says "anything left or doubtful" (`:1188`). The verifier reads the report only for routine calls (`:1476`). Between those two sits behaviour the contract didn't settle but that isn't direction: a default value, what an edge case shows, the wording of a message. Nothing asks for that to be listed, so it's seen only if someone reads the diff.
- **Change:** extend the existing "list each in your report" to those behaviour choices, one line each with what was picked. The line between asking and deciding doesn't move: direction, scope and risk still go to the lead. The repository says stop and ask on any ambiguity; VibeSwitcher should not, because the user wants only necessary questions.
- **Serves:** exactly what the user wants, fewer questions.
- **Size:** S.
- **Risk:** padding, and a longer brief. Lists of nothing cost little.
- **Measure:** on 10 tasks, whether corrections after delivery (A1) were on a listed choice, and how many lines per report are real choices.
- **Verdict:** adapt.

### 6. Say when a setback came from the contract

- **Source:** `skills/doubt-driven-development/SKILL.md:176` (the first class of a finding is "Contract misread": fix the contract first).
- **VibeSwitcher today:** a setback records its stage, a free-text reason and the verdict (`Sources/VibeCore/LeadBoard.swift:159`). Audit rounds caused by the contract recur, mostly as "suspect" verdicts with no Important finding (decisions 2026-10-30 15:08 and 2026-11-07 19:48, A6) and sometimes as an Important finding that was "a contract reading rather than a bug" (`workers-don-t-stall` F1, `docs/process/verifier-eval.md:67`). Neither can be counted.
- **Change:** an optional `cause: contract` on the setback, set by the lead when it sends a task back or re-audits it, and counted in the scorecard. It's on the setback, not the finding, so "suspect" verdicts count too. It's a label only and changes no verdict.
- **Serves:** cheaper (fewer rounds), better contracts.
- **Size:** S to M; `LeadBoard` is a sensitive path.
- **Risk:** the lead is labelling its own contracts, so it may under-report. Check a sample against the verdicts' text.
- **Measure:** share of review setbacks labelled over 30 audits, and whether it falls after a change to the lead's contract rules.
- **Verdict:** adapt, once A1's scorecard has room for it.

### 7. Interview the user until 95% confident

- **Source:** `skills/interview-me/SKILL.md` (one question at a time, each with a guess, until an explicit yes; "whatever you think" doesn't count).
- **VibeSwitcher today:** the lead asks only what it truly needs, and proposes an answer with a timer (`LeadWorkflow.swift:953-957`; G1, `docs/process/lead-rules.md:75`).
- **Change:** none.
- **Serves:** would aim at "exactly what they want" but works against "only necessary questions".
- **Size:** M.
- **Risk:** more questions, on every underspecified ask. The lead does still ask about direction and taste; an interview would turn that into a required loop.
- **Measure:** would be the avoidable-question rate (A1, A4).
- **Verdict:** skip. Its "out of scope" line in a restated intent is worth one line in B1 when that's built.

## Looked good, but already have or rejected

| Idea (source) | Where it's recorded |
|---|---|
| Show a new test fails without the change (`references/definition-of-done.md:24`) | Rule for fixes: `LeadWorkflow.swift:814`, G12. Gate-run version: A7 and parked in decision 2026-11-06 22:35. When its trigger fires, consider the one-condition flip in `code-review-and-quality/SKILL.md:164`: without the whole change, a test of a new function just fails to compile, which proves nothing. Today's verifier is read-only, so a worker or the gate would run it. |
| Fresh-context reviewer given only the artifact and contract (`doubt-driven-development/SKILL.md:83-108`) | The worker's blind check, `LeadWorkflow.swift:791` |
| Different model reviews the code (`code-review-and-quality/SKILL.md:209`) | Decision 2026-11-07 20:06 and the review floor (2026-11-07 20:08) |
| Severity labels, cosmetic findings never block | `LeadWorkflow.swift:1511-1518`, enforced (E4, lead-rules) |
| Bounded review loop (`doubt-driven-development/SKILL.md:183-193`) | Round cap and "reconsider", `LeadWorkflow.swift:1001` (#11, lead-rules) |
| A quality floor agents can't lower (`constraint-driven-development`) | Review floor, decision 2026-11-07 20:08 |
| Test each skill with and without it (`evals/plugin/`) | B4 |
| Skills written from practice | B5. Caution from `evals/README.md:65-71`: a skill's firing is chancy and shifts between CLI versions, so a must-follow rule belongs in the role's brief, not a skill left to fire. |
| Measure a change, keep a record of what was rejected (`evals/skill-impact.md`, a table with no rows yet) | `docs/process/impact.md`, B8 |
| Replay or behaviour benchmark of the whole harness | C4; the no-replays answer, decision 2026-11-02 23:00 |
| Growing the verifier's cases | C3 |
| Planted cases for the verifier (`evals/fixtures/review-evidence/`, cases 2 to 4 of `evals/cases/code-review-and-quality.json`) | Parked in decision 2026-11-06 22:35 ("measure verifier recall with planted bugs"), incident first. The repository's fixtures test three things that decision doesn't name, and today's 12 cases don't score (`scripts/verifier-eval.sh:166`): a defect correctly labelled Pre-existing, an accusation a caller's guard refutes, and an instruction planted in a source comment. If a false hold or a verifier obeying branch text occurs, build those three as tiny Swift fixtures on their own summary line, after idea 1. |
| Show what you'll build before building | B1 |
| Scope discipline, stop and report when stuck | Boundaries in each contract; `LeadWorkflow.swift:785`, `:1194` |

## Doesn't fit

- **The user as orchestrator, no automated pipeline** (`references/orchestration-patterns.md:92`, `:316`). VibeSwitcher's point is the opposite: a lead carries the pipeline so the user doesn't.
- **Offering a cross-model review on every cycle** (`doubt-driven-development/SKILL.md:118-126`). It's a question per decision, and VibeSwitcher already routes audits to another model without asking.
- **Mandatory hand-offs and human gates at each phase** (`spec-driven-development/SKILL.md`, the gated workflow). Decision 2026-10-18 18:50 removed per-merge asks.
- **`hooks/sdd-cache-*`, trigger-word evals and description-collision checks.** Workers rarely fetch docs, and VibeSwitcher's roles get their rules in the brief, not through skill routing.
- **Change-size targets and task-size tables** (`code-review-and-quality/SKILL.md:105`, `planning-and-task-breakdown/SKILL.md:125`). The size risk is already covered by `risk_lines` and B6, with VibeSwitcher's own numbers instead of generic ones.
