# Ideas review: google/elephant-goldfish-model

- **Repository:** https://github.com/google/elephant-goldfish-model
- **Commit read:** `5382b17619be07811a14b2146c7672620b34a791` (main, 2026-11-08), a depth-1 clone read as documents. Nothing in it was run or installed.
- **Licence:** Apache-2.0, with no NOTICE file. The ideas are free to use. Copying its persona or skill text would need the licence kept and changes marked, so everything below is a re-description.

**What it really is.** A plugin of Markdown prompts for Claude Code, Codex, Antigravity and others: seven skills (brainstorm, draft, review, review loop, resolve, bootstrap, drift report), nine reviewer personas and five document standards, with Python tests that check packaging, links and transcripts. The idea is that one agent with the conversation's context (the "elephant") drafts a design document, and reviewers with no conversation history (the "goldfish") critique it, while the user approves each step. It reviews design documents before code exists; VibeSwitcher reviews code after a worker wrote it, so the overlap is the review mechanics, not the workflow.

**How far its claims go.** It publishes no effectiveness numbers, and its FAQ says completing the workflow "does not demonstrate a productivity improvement" (`docs/faq.md:45`). Its `test_scenarios.yaml` files are called a benchmark in `docs/designs/review.md:185`, but the only code in `tests/`, `scripts/` or `.github/` that reads them checks their schema (`tests/unit/test_scenario_coverage.py`). The ideas below are therefore untested hypotheses, and each says how it would be measured here.

## Ideas, ranked

Ranking is expected effect on the goal divided by cost. Line numbers are at the commits named above and on this branch's base.

### 1. A fresh reader checks a contract before its worker starts

- **Source:** `agents/comprehension.md:37` (paraphrase first: a wrong paraphrase is a finding, and it catches parts that don't connect, which a list of undefined terms doesn't), `agents/implementation_readiness.md:38` (flag every design choice left to the implementer).
- **VibeSwitcher today:** a contract is written by the lead and rendered unchanged to the worker (`Sources/VibeCore/LeadWorkflow.swift:961`, `WorkerBrief.render` at `:1727`). The first fresh eyes come after the code exists: the blind check (`:791`) and the verifier (`:1487`). Contract gaps found late are on record: five tasks needed Sandbox files their boundaries omitted (decision 2026-10-30 15:08), audits came back "suspect" for the same reason (2026-11-07 19:48), three follow-ups came from unchecked environment facts (2026-10-31 23:30), and a contract missed paths to the protected property at a cost of 3 tasks (2026-11-05 00:30:32). Backlog B1 is a user glance at UI work, A6 versions contracts and C10 predicts tests; none has a reader test the contract.
- **Change:** when a task is audited or has a budget over 60 minutes, a cheap headless model (the way `LeadRisk` asks for a raise) gets only the contract and answers three things: what it thinks is being asked, in its own words; which design choices the worker would have to guess; and whether each acceptance check can be done inside the boundaries. The answer goes to the lead on `add_task`, and auto_advance's start waits for it, with a timeout. It never refuses. The lead applies a gap only if a real worker would hit it, which is the repository's own guard against writing for a zero-context reader (`skills/egm-resolve/SKILL.md:74`).
- **Serves:** fewer issues, fewer questions, and getting exactly what was asked.
- **Size:** M. **Risk:** low. It adds one small model call per qualifying contract and can bloat contracts if the lead obeys every gap.
- **Measure:** backtest first, for about the price of a few cheap calls. Run it on the v1 text of tasks later amended, re-rolled or marked "suspect", and on as many tasks that passed their first audit clean, then compare how often it flags what the amendment later changed with how often it flags clean contracts. Build it only if it separates them. After that: first-audit pass rate (68% today), amendments per task and contract questions per task.
- **Verdict:** adapt.

### 2. A fixed finding isn't a settled finding

- **Source:** `skills/egm-review-loop/SKILL.md:162` and `:166`: accepted or contested findings stay closed, but one that was fixed can reopen, because a later edit may have undone the fix.
- **VibeSwitcher today:** the re-audit's closed list holds every non-open finding, fixed and dismissed alike (`Sources/VibeCore/LeadToolset.swift:2699`), and the verifier is told a closed finding is "never raised again, under its id or another" (`Sources/VibeCore/LeadWorkflow.swift:1694`, list at `:1717`). If round 3's fix for F2 undoes round 2's fix for F1, the verifier is told not to say so.
- **Change:** split the list in two. Dismissed and pre-existing findings are never raised again. Fixed ones aren't re-reviewed, but if this round's diff touches the fix's lines and undoes it, the finding reopens under its id. The ledger has to accept open on a fixed id.
- **Serves:** fewer issues.
- **Size:** S. **Risk:** low: a few more re-raised findings. It is probably rare, since a fix's regression test usually catches this, and it's listed because the prompt forbids the right answer and the change is small.
- **Measure:** add one `verifier-eval` case whose second commit undoes a fixed finding, and score it before and after. In production, count reopened findings and whether each was real.
- **Verdict:** adopt.

### 3. Dismissing an Important finding names evidence someone can check

- **Source:** `skills/egm-resolve/SKILL.md:58-71`: a contest cites something the reviewer could read, and "this was intentional" isn't evidence. A rebuttal resting on something no reviewer can read goes to the user instead.
- **VibeSwitcher today:** a worker's disagreement is judged by the re-audit (`Sources/VibeCore/LeadWorkflow.swift:832`, `:1700`), but the lead's `dismiss_finding` needs only a non-empty reason (`Sources/VibeCore/LeadToolset.swift:1194`), and that lifts the merge hold. The lead both drives the work and clears what blocks it, the governance concern behind the user's floor (decision 2026-11-07 20:08).
- **Change:** for an Important finding, `reason` must name a file and line, a decision's timestamp or a user answer's id; anything else is refused. If the evidence is only what the lead remembers, it records a decision first or asks the user. Nits are unaffected.
- **Serves:** safer.
- **Size:** S. **Risk:** low. It's a format check, not a truth check, so a wrong citation still passes, though it can be audited afterwards.
- **Measure:** share of Important dismissals carrying a citation (baseline from the audit ledgers), and escapes traced to a dismissed finding.
- **Verdict:** adapt.

### 4. Check the blind check from the transcript, not the claim

- **Source:** `TESTING.md:160-169`: evidence that a reviewer ran is the tool record; "child-written receipts and parent summaries" can't stand in for it. `tests/unit/test_claude_traces.py` applies this to transcripts.
- **VibeSwitcher today:** `report` requires `blind_check` to be non-empty text (`Sources/VibeCore/LeadToolset.swift:5195`). Lead-rules G13 already notes that a self-reported line proves little, and E5 has shown that a proof record can replace a claim (`Sources/VibeCore/LeadToolset.swift:5215`). VibeSwitcher reads transcripts already (`Sources/VibeCore/TranscriptReader.swift`).
- **Change, in two steps:** first, a zero-token script scans past Claude workers' transcripts: before each done report, was there a subagent call after the last code commit, and did its prompt hold the contract's goal and a diff? Only if the scan shows real skipping (say over 5%) does `report` start refusing a done without that call, with a lead override. This follows the "incident first, then the check" policy (decision 2026-11-06 22:35). Codex workers are out of scope; they're always audited.
- **Serves:** fewer issues.
- **Size:** S for the scan, M for the gate. **Risk:** the transcript format can change, and matching the prompt's content is a heuristic, so false refusals are possible.
- **Measure:** the share of done reports backed by a matching call, and first-audit pass rate with and without one.
- **Verdict:** adapt, scan first.

### 5. A planted-marker probe of what a verifier really sees

- **Source:** `tests/integration/test_claude.py:96-172`: a live run plants random markers the child must not see and fails if they come back. `TESTING.md:134` and `:137` record why it matters: instruction files were reported reaching children on some CLI releases, so isolation can change with a harness update.
- **VibeSwitcher today:** `VerifierIsolationTests` assert the launch configuration (`Tests/VibeCoreTests/VerifierIsolationTests.swift`; the memory switch is at `Sources/VibeCore/LeadLaunch.swift:233-240`). Nothing checks what a real verifier ends up reading. Backlog C8 proposes a scratch worktree to close the channel fully; this is the measurement that says whether C8 is needed.
- **Change:** a case beside `scripts/verifier-eval.sh`, run when the Claude Code version changes: plant random markers in a worker's auto-memory folder and in its chat, start a real verifier on a cheap model in a scratch clone, and fail if it can name one. Do the same for a blind-check subagent, with a marker in the worker's conversation.
- **Serves:** safer.
- **Size:** S. **Risk:** false comfort. It covers what's loaded into context, not files a worker's shell leaves for the verifier to read (the repository says the same of its own isolation, `docs/claude.md:164`).
- **Measure:** pass or fail per CLI version. Several passes argue against building C8; a failure gives C8 its evidence.
- **Verdict:** adapt.

### 6. A size ceiling on each role's prompt

- **Source:** `tests/unit/test_skill_load_limits.py`: a plain test fails when a skill body passes a byte limit.
- **VibeSwitcher today:** no test limits `LeadPrompts.lead`, `worker` or `verifier` (`Sources/VibeCore/LeadWorkflow.swift:938`, `:1150`, `:1481`). Each new rule adds text to every session; the source lines that compose a worker's brief come to roughly 24 KB (a rough count, not a rendered size). The cost of context files is why AGENTS.md was cut down (decision 2026-10-26 11:01 (a)). Backlog B4 covers skills, not these prompts.
- **Change:** one test renders each role's prompt from a fixture workflow and fails above today's size plus 10%. Raising the ceiling is a one-line change that the audit of `LeadWorkflow` sees.
- **Serves:** cheaper.
- **Size:** S. **Risk:** pressure to trim a safety rule to pass. It stops growth and doesn't save anything by itself.
- **Measure:** rendered characters per role over time, against cost per accepted delivery (backlog A1).
- **Verdict:** adopt.

### 7. The repository's main workflow: design documents, staged reviewers, a user gate at each step

- **Source:** `skills/egm-review/SKILL.md`, `skills/egm-draft/SKILL.md`, `resources/execution_instructions.md:20` and `:24` (explicit agreement at each step, one question at a time).
- **VibeSwitcher today:** the lead plans and contracts autonomously, and the user is asked only about direction, taste and irreversible steps (decision 2026-10-18 18:50; lead-rules G1).
- **Change:** none. Idea 1 takes the useful part at a fraction of the cost: a logged full run used 15 reviewers (`TESTING.md:137`), plus user gates.
- **Serves:** none of the goals; it costs more and asks more.
- **Size:** L. **Risk:** high, in time and in questions to the user.
- **Measure:** if it's ever revisited, rework on tasks of an hour or more against the extra cost and questions.
- **Verdict:** skip.

## Looked good, but VibeSwitcher already has it or rejected it

| Idea in the repository | Where VibeSwitcher records it |
|---|---|
| Review in a fresh context with no conversation (`skills/egm-review/SKILL.md:28`) | Worker's blind check `LeadWorkflow.swift:791`; independent verifier `:1487` |
| A review that can't be fresh isn't a review | Codex workers can't lower their audit: `LeadToolset.swift:1059-1062`, `LeadWorkflow.swift:1215` |
| A reviewer that failed is "not run", never zero findings (`agents/synthesizer.md:41`) | The verdict waits for every finder (`LeadWorkflow.swift:1007`); an ended verifier is restarted once (`LeadAdvance.swift:16`) and reported (`LeadWitness.swift:281`) |
| Several independent reviewers merged into one report | `audit_finders` and the vote (`LeadWorkflow.swift:1296`, `:1392`); a second security finder was rejected (decision 2026-10-26 11:01 (b)) |
| Findings with severity and evidence; Nits don't block | lead-rules #10 and E4 |
| Cap on review rounds (`skills/egm-review-loop/SKILL.md:175`) | lead-rules #11, the round cap then re-roll |
| Two clean rounds before converging (`:173`) | Rejected: lead-rules E3, and the working policy's no audit loop without a concrete concern |
| A fresh reader paraphrases, applied to the code review | Backlog B7 (verdict before reading the worker's claims) |
| Playing the intent back to the user first | Backlog B1 |
| Drift reports comparing docs with code (`skills/egm-drift-report/SKILL.md`) | A scheduled gardener was rejected (decision 2026-10-26 11:01 (c)); backlog C7 and A5 cover the useful part (see below) |
| Tests of prompts' behaviour | `docs/process/verifier-eval.md`, backlog C3 and C4 |
| Heavier process for large diffs (`AGENTS.md`, `tests/scope_advisory.cjs`) | `risk_lines` and sensitive paths: `LeadRisk.swift:23`, lead-rules #16 |
| Check for existing code before building | `LeadPrompts.productCheck` (`LeadWorkflow.swift:638`), backlog A5 |
| One blocking question at a time | Doesn't fit: `ask_user` doesn't block work (`LeadWorkflow.swift:953`); backlog A4 goes toward a digest |

**One piece of evidence for backlog C7.** `docs/process/lead-rules.md` cites brief lines by number, and they've gone stale: rule 1 cites `LeadWorkflow.swift:776` for "the lead never writes code", but that line is now in `lintTests` and the rule is at `:942`; E2 cites `:921` for `onBattery`, now at `:1112`. C7's "regenerate lead-rules" would fix this, and citing symbols instead of line numbers would keep it fixed.
