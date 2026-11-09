# Ideas review: mattpocock/skills

- **Repository:** https://github.com/mattpocock/skills
- **Commit read:** `4ae2317ddb22b046e26455e4f9c9b3aaaf62212d` (2026-10-31), a depth-1 clone read as documents; nothing in it was run or installed.
- **Licence:** MIT. Short adaptations are fine; copying a skill whole needs the copyright notice. `skills/engineering/pr/SKILL.md` credits another author's skill (`skills/engineering/pr/CREDITS.md`), so check that source before reusing its text.

What it really is: 39 short Markdown skills, plus a few helper scripts, packaged as a Claude Code and Codex plugin: one developer's working habits written as instructions to an agent. It has no orchestrator, gate or evals, so its claims are argued from experience, not measured; its popularity says nothing about whether they hold. VibeSwitcher's harness already does most of what it describes, so what's worth taking is a few precise rules.

Line numbers below are as of VibeSwitcher commit `72533c6e`. "Measure" says how we'd know it helped; each change that's taken gets an entry in `docs/process/impact.md`.

## Ideas, ranked

### 1. Bug tasks start from a command that goes red on the reported symptom

- **Source:** `skills/engineering/diagnosing-bugs/SKILL.md` (Phase 1, Phase 2, the seam rule in Phase 5).
- **Today:** the worker shows its test failing without the fix when it reports (`Sources/VibeCore/LeadWorkflow.swift:814`), and an incident task's check must reproduce the incident (`Sources/VibeCore/LeadToolset.swift:4408`). Both come at the end. Nothing says to get the red run before theorising, or that it must show the symptom the user reported. Misread symptoms cost real work: `docs/lead/decisions.md:113`, `:158` and `:289` (three freeze or hang misdiagnoses), `docs/lead/progress.md:154`. And 25% of flaky fixes flaked again (`docs/process/backlog.md:5`).
- **Change:** one sentence in the worker brief, next to `regressionTest`, and one in the lead's contract step. For a bug: quote the symptom in the contract; before changing code, run one command that goes red on that symptom; for a flake, record its failure rate over N runs under load, and show that rate after the fix; with no such command, report blocked with what was tried; if no test can reach the real bug path, say so instead of adding a shallow test.
- **Leave out:** its preference for a debugger (forbidden here by `AGENTS.md`) and showing hypotheses to the user (a needless question).
- **Goal:** fewer issues, cheaper. **Size:** S.
- **Risk:** UI and hang bugs that the sandbox can't reproduce end up blocked more often; the blocked path is the intended outcome, but the lead has to expect it. Loops under load use heavy slots.
- **Measure:** share of flaky fixes that flake again (baseline 25%); bug tasks abandoned as misdiagnosed after a worker started.
- **Verdict:** adapt.

### 2. Audits ask what the diff added that nobody asked for

- **Source:** `skills/engineering/code-review/SKILL.md` (the Spec sub-agent's brief).
- **Today:** the verifier looks for edits outside the boundaries and anything that only looks done (`LeadWorkflow.swift:1495`); the contract finder compares the branch with its goal (`:1305`). Boundaries list only what a task must not touch or do (`Sources/VibeCore/LeadBoard.swift:9`), so extra behaviour nobody thought to forbid isn't asked about, and the worker's blind check asks only for blockers (`:791`). The user's stated goal is "exactly what they want", and `docs/process/backlog.md:17` records "little UI noise, no extra chrome".
- **Change:** the verifier's check and the contract finder's brief ask three things, each quoting the contract line: what's missing or partial; what the diff does that the contract doesn't ask for; what looks done but is wrong. The second is a Nit unless it does harm or the user would see it, and never fires on routine calls the worker listed (`:1461`).
- **Goal:** fewer issues (fewer corrections after delivery). **Size:** S to write, but `docs/process/verifier-eval.md:8` requires a full eval run first (about $45–60).
- **Risk:** false alarms on sensible small additions, and more audit rounds. The file is a sensitive path, so the change is itself audited.
- **Measure:** add a case with planted unrequested behaviour to the eval: it's found, and false alarms on the 3 clean cases don't rise. Later, corrections per delivery (backlog A1).
- **Verdict:** adapt.

### 3. The lead splits large tasks into vertical slices

- **Source:** `skills/engineering/to-tickets/SKILL.md` (vertical slices, prefactoring first, expand–contract for wide renames).
- **Today:** the lead's brief says only "Fewer, sharper tasks beat many vague ones" (`LeadWorkflow.swift:966`); neither the code nor the process docs have a rule on how to split work. Important findings appear in 5% of tasks under 0.25 h and 63% of tasks of 1 h or more (`docs/process/backlog.md:5`). That gap is confounded: harder work is both longer and buggier. Backlog B6 attacks the same tasks with two attempts; this is cheaper and comes first.
- **Change:** in the lead's contract step: a task expected to take over about 1 h becomes slices, each working end to end and verifiable alone, with any prefactor first; a wide rename goes expand, migrate, contract.
- **Goal:** fewer issues, faster. **Size:** S.
- **Risk:** more audits and merge runs per goal, on a Mac where load is the live problem; batched merges offset part of it. It also pulls against the file-chaining rules (`docs/lead/decisions.md:265`, `:281`), since slices of one feature often share files.
- **Measure:** try it on one batch: Important findings per 100 changed lines by task length, first-audit pass (baseline 68%), heavy-slot minutes per goal.
- **Verdict:** adapt.

### 4. A record of concepts the user turned down

- **Source:** `skills/engineering/triage/OUT-OF-SCOPE.md`.
- **Today:** partly covered. The lead checks decisions before proposing (`LeadWorkflow.swift:638`), and `status` lists abandoned tasks with their reasons (`LeadToolset.swift:5605`). The gaps are narrower: a reason in `status` is clipped to 60 characters and named only until its task is archived; a turned-down idea reaches decisions.md only sometimes (`docs/lead/decisions.md:273` did, the chat ideas at `docs/lead/progress.md:1169` and `:1170` didn't); and an entry moved to the archive is no longer read (`LeadToolset.swift:758`).
- **Change:** no new file. When the user turns an idea down, the lead always calls record_decision with the concept, the user's words and what would reopen it, and archive_decisions leaves those entries in place. Take its two sharp rules: match by concept, not keyword; and never record something as rejected because it already exists.
- **Goal:** fewer questions. **Size:** S.
- **Risk:** "meh" hardens into "never"; the reopen condition is the guard. decisions.md grows slightly. Nothing in the records shows a rejected idea proposed twice yet, so this is cheap prevention, not a fix (the nearest incident is the four existing features proposed on 2026-11-07).
- **Measure:** proposals that repeat a recorded concept, from the scorecard (backlog A1).
- **Verdict:** adapt.

### 5. A new test's expected value comes from somewhere other than the code

- **Source:** `skills/engineering/tdd/SKILL.md` (the tautological anti-pattern), `skills/engineering/tdd/tests.md`.
- **Today:** whether a test would fail without the change is asked only of the tests finder (`LeadWorkflow.swift:1313`), which needs audit_finders 3 on a non-sensitive branch. The red-run rule covers fixes only (`:814`), so a new feature's tests have no such check. `REVIEW.md` has no line on it. The one recorded miss is `docs/lead/decisions.md:69`.
- **Change:** one line under Important in `REVIEW.md`: a new test whose expected value is recomputed the way the code computes it, so it can't disagree with the code. Keep VibeSwitcher's source-scanning lints and prompt-text tests: its "implementation-coupled" anti-pattern doesn't apply to them.
- **Goal:** fewer issues. **Size:** S.
- **Risk:** low; a verifier could over-apply it to table-driven tests. The evidence is thin: `docs/lead/decisions.md:227` found no failure that a mechanical check would have caught that week, so this stays a review line, not a gate.
- **Measure:** one planted tautological test in the verifier eval; found or not, with clean-case false alarms unchanged.
- **Verdict:** adapt.

### 6. A short retrospective on the worker sessions that went wrong

- **Source:** `skills/engineering/retro/SKILL.md` (its categories), `skills/in-progress/chief-of-staff/SKILL.md` (retro on a sample of subagent sessions, the bad ones first; beta).
- **Today:** the lead runs a retrospective per batch, from outcomes (`LeadWorkflow.swift:1023`). Backlog A3 mines app.log, B5 writes skills from successes, C1 proposes prompt edits weekly, and B7 has the verifier read a transcript to judge that task. The nearest precedent is a one-off review of other projects' sessions (`docs/lead/decisions.md:61`). Nothing routinely asks of a struggling worker's session what in the environment would have helped.
- **Change:** when a task runs over budget or fails its first audit, one cheap-model agent reads that worker's transcript and answers fixed questions: what took long to find, what check would have caught the mistake, what information was missing, which tool calls were expensive. At most 3 candidates go to the lead, each becoming a task or check as step 10 requires. Event-triggered only, because `docs/lead/decisions.md:85` rules out a scheduled gardener.
- **Goal:** cheaper, fewer issues. **Size:** M.
- **Risk:** transcripts are untrusted text, so candidates are data for the lead and never instructions; noise and spend, so cap the runs per day.
- **Measure:** candidates that became merged checks ÷ runs; $ per run; repeat setbacks of the same class. Stop if under about 1 in 5 is worth doing after 20 runs.
- **Verdict:** adapt.

### 7. The worker brief carries only what this task's branch needs

- **Source:** `skills/productivity/writing-for-agents/SKILL.md` (branching test, no-ops, single source of truth), `skills/engineering/retro/SKILL.md` (the reviewer has less context pressure, so it should hold the standards).
- **Today:** the worker brief is about 12 KB of source text (`wc -c` over the lines `LeadWorkflow.swift:1150` assembles, before its generated git list), and what it covers doesn't depend on what the task touches. A docs-only task like this one still gets the load-test, sandbox, regression-test and findings rules. `docs/lead/decisions.md:85` trimmed AGENTS.md for this reason, but the brief was never held to it.
- **Change:** paragraphs follow what the boundaries name: tests and load rules only for a task that touches code or tests, UI rules only for app sources. Keep the rules that `report` refuses on regardless. Add a test holding the brief under a size ceiling.
- **Goal:** cheaper, fewer issues (attention). **Size:** M.
- **Risk:** boundaries are prose, so a wrong guess drops a rule a worker needs. The brief is cached input, so the dollar saving is likely small; the case rests on attention, which is hard to show.
- **Measure:** worker input tokens on docs-only tasks; report refusals and failed merges for tasks with the shorter brief, against those with the full one.
- **Verdict:** adapt, after 1–6.

### 8. A project glossary

- **Source:** `skills/engineering/domain-modeling/GLOSSARY-FORMAT.md`, and the README's section on shared language.
- **Today:** there's no glossary. The one recorded name clash was fixed by renaming (`docs/lead/decisions.md:138`), and `docs/lead/decisions.md:87` records that context files add about 20% cost and overviews don't help. `docs/process/product-inventory.md` already maps what exists.
- **Change:** none now. Revisit, as a file reached by a pointer, if a second naming mix-up is recorded: incident first, then the check (`docs/lead/decisions.md:227`).
- **Goal:** cheaper (the README's claim, unmeasured). **Size:** S.
- **Risk:** always-loaded context that goes stale.
- **Measure:** none proposed: nothing here would show a benefit yet.
- **Verdict:** skip.

## Looked good, but already here or already rejected

- **Spec and standards reviewed separately:** finder focuses and the vote (`LeadWorkflow.swift:1287`).
- **Fresh-context review:** the blind check (`LeadWorkflow.swift:791`).
- **Standards read only at review:** `REVIEW.md` and `LeadWorkflow.swift:1595`.
- **Briefs with acceptance criteria and scope:** the task contract (`Sources/VibeCore/LeadBoard.swift:4`).
- **Red then green for fixes:** `docs/process/lead-rules.md:86` (G12); the gate doing it itself is backlog A7.
- **Mechanical rules become checks:** `docs/process/lead-rules.md:7`, and lead step 8.
- **Merge danger (one-way door, blast radius):** the risk check and update wording (`LeadWorkflow.swift:868`, `:885`), and no timer on irreversible questions (`docs/process/lead-rules.md:52`).
- **Handoff between sessions:** the lead's handover (`LeadWorkflow.swift:915`).
- **Task graph, integration branch, staying up to date:** `after`, batched merges (`docs/lead/decisions.md:162`), and `docs/process/lead-rules.md:42`.
- **Interactive helper for human-only steps:** `vs-shell run` (`docs/lead/decisions.md:285`).
- **Git guardrail hook** (`skills/misc/git-guardrails-claude-code/SKILL.md`): deny rules (`docs/process/lead-rules.md:35`, `:36`).
- **Capping loops before a human:** the audit round cap (`docs/process/lead-rules.md:45`).
- **Questions with a recommended answer, asked together:** `ask_user`'s proposal (`LeadWorkflow.swift:955`) and backlog A4's digest.
- **Loading fewer skills per role:** backlog B4; the repo's user-invoked versus model-invoked split is one way to do it.
- **Grilling the user before every change (rejected):** the user wants only necessary questions (`docs/process/lead-rules.md:75`, `docs/lead/decisions.md:17`); intent capture for visible work is backlog B1.
- **Architecture survey every few days (rejected):** no scheduled gardener (`docs/lead/decisions.md:85`).

Not taken, on this review's judgement alone, with no earlier decision behind it: its code-smell baseline, because a list of twelve smells would add Nits, and the one that matters here (speculative generality) is what idea 2 asks; and briefs without file paths, because VibeSwitcher's tasks start soon after they're written and its planning rules use the boundaries' paths.
