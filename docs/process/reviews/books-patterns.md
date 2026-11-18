# Patterns from the software-engineering canon: what VibeSwitcher should adopt

Written by a worker (task patterns-from-the-top) on 2026-11-18, at the user's request of the same day: take about
50 of the most influential software-engineering books, pull out the patterns they propose, and check each against
VibeSwitcher's architecture (the app, the session host, the MCP tool server, VibeCore) and its processes (lead,
workers, verifiers, contracts, audits, merges, flakes, incidents, retrospectives). No code or setting was changed.

**How to read the tables.** Each book gets the one to three patterns that matter most to a system like this one,
one line each, and a status:

- **done**: something enforces or carries it, cited (a file, a test, a decision by its timestamp in
  `docs/lead/decisions.md`, or a script);
- **partly**: some of it exists, and the row says what's missing;
- **not done**: checked against the code, `docs/process/product-inventory.md`, `docs/lead/decisions.md`,
  `decisions-archive.md`, `docs/process/backlog.md` and `docs/process/reviews/`, and not found;
- **decided against** or **parked**: tried or weighed and dropped, with the decision's date (these aren't proposed
  again);
- **doesn't fit**: with the reason.

Decision references are `decision YYYY-MM-DD HH:MM` and point at `docs/lead/decisions.md` unless they say
"archive". Backlog ids (A1, B3…) are `docs/process/backlog.md`'s; its Status column is behind the code (A1, A2, A3, A5,
A6 and B3 landed on 2026-11-08), so the tables cite the code instead.

## The numbers used

| Figure | Value | Source and filter |
| --- | --- | --- |
| Merge runs, this week | 96 runs for 73 tasks; median 17.0 min, p90 55.2 min; first run failed 25 of the 89 that record it; 16 passed only on the rerun; 18 reran the whole command; 7 conflicts, 8 failed | `~/.vibeswitcher/stats/merges-2026-11-12..18.jsonl`, rows with `project` = vibeswitcher only (the files are Mac-wide); 11-18 is a partial day. Durations include failed and conflicting runs |
| Merge runs, the week before | 139 runs for 113 tasks; median 14.4 min, p90 36.3; first run failed 35 of 129; 18 passed only on the rerun; 27 whole reruns; 7 hung | same files, 2026-11-05..11 |
| The Mac, this week | 106.9 h sampled; 1-minute load median 5.2, p90 18.2, max 236 on 12 cores; memory pressure "warn" 431 min; 2 app freezes, both at load 100–150; 0 freezes during merge runs | `scripts/load-report.sh 2026-11-12 2026-11-18` (Mac-wide, every project) |
| Hot files | `Sources/VibeCore/LeadToolset.swift`: 7,618 lines, 321 functions, in 211 commits since 2026-10-18 (82 since 11-04). `Sources/VibeSwitcher/Sandbox.swift`: 4,608 lines, 126 commits (65) | `wc -l`, `git log --name-only` (commits, not tasks) |
| Audits forced only by Sandbox.swift | 36 audit starts whose only stated reason was "It touches sensitive_paths (Sources/VibeSwitcher/Sandbox.swift)", 5 of them since 11-11 | `docs/lead/progress.md` + `progress-archive.md` |
| Tasks planned | 630 in all; 36 about flaky tests; 9 about the app's memory growing again | "Planned" lines in both progress files |
| Flakes | 202 flakes over 166 tests in 22 days | `Tests/VibeSwitcherTests/ElapsedTimeLintTests.swift`'s header |
| Quality | first-audit pass rate 68%, 1.4 audit rounds to pass, 0 reverts | the status scorecard, as the task's contract gives it |

## In short

VibeSwitcher already does most of what these books ask for, and often more strictly: guard rails are code rather than
prose, incidents become checks, and decisions are recorded with their reasons. The books' best remaining lever is the
merge gate, treated as a production service with an objective and an error budget. The ranked proposals:

1. **An error budget for the merge gate** (SRE, Implementing SLOs, Deming): 28% of merge runs fail their first try.
2. **Tidy first, as its own small task** (Tidy First?, Refactoring): large tasks need a second audit round 59% of the time.
3. **Split Sandbox.swift by what's sensitive** (A Philosophy of Software Design, Your Code as a Crime Scene): 36 audits were started only because a UI task touched it.
4. **A crash costs one test shard, not the merge** (Release It!, Software Engineering at Google): 18 whole-suite reruns this week.
5. **The git guard fails closed on git it can't see** (Building Secure and Reliable Systems, Secure by Design): three guard tasks so far, and `RefusedGit.swift` itself lists the open spellings.
6. **The memory benches run by themselves on a calm Mac** (Building Evolutionary Architectures, Release It!): the app's memory growth has needed 9 tasks since October.
7. **Stability metrics in the weekly scorecard** (Accelerate): change failure rate and time to restore are counted by hand today.
8. **Lead messages measured by whether they needed the user** (SRE, Making Work Visible): the noise rule was written twice, on 10-25 and 11-17.
9. **Each retrospective checks whether an incident came back after its check merged** (The Site Reliability Workbook, Dekker).
10. **One transition table for a task's states** (Domain Modeling Made Functional): low on the list, since only one incident backs it.

Details, costs and the week-one checks are in [the shortlist](#the-shortlist).

## What VibeSwitcher already does well

By these books' standards, the strongest parts are these.

- **Poka-yoke over discipline.** Rules that matter are enforced by the tools, not left in briefs. `docs/process/lead-rules.md`
  counts 33 enforced rules against 19 left as guidance, each with the reason it has no check. *The Toyota Way*'s
  mistake-proofing, Brooks's conceptual integrity and *Building Secure and Reliable Systems*' "design for least
  privilege" all show up here: `LeadLaunch` deny rules, the vault's verdicts, `LeadReviewFloor`, `ConfigSeal`.
- **Stop the line.** A red base stops merges and names its cause (`LeadPipeline.swift`). A merge tests the exact
  commit it lands (`LeadLandingCheck.swift`), and one merge runs at a time under `TestLock`. That is *Continuous
  Delivery*'s "never commit on a broken build" and the Toyota andon, built in.
- **Incidents become checks, blamelessly.** `record_incident` plans a check task, and `docs/lead/incidents.md` holds
  evidence rather than blame. A fix's regression test must fail without the fix (decision 2026-10-25 09:46). This is the
  SRE postmortem loop, and *Software Engineering at Google*'s Beyoncé rule.
- **Bulkheads and timeouts at the process level.** Each session has its own parser process (decision 2026-10-18 17:55),
  so a parser trap stays in its session. Stalled runs are stopped in minutes (`StallWatch.swift`), and heavy work
  shares Mac-wide slots (`TestLock.swift`, `vs-heavy`, `HeavyJobs.swift`). Starts back off on load and memory
  (`MacMemory.swift`). *Release It!* would recognise every one of these.
- **Clocks treated as unreliable.** Limits count awake time, not wall-clock (`MacTime.swift`, decision 2026-11-08
  20:36), and tests wait on events, not sleeps (`ElapsedTimeLint`, the `eventually`/`until` helpers). That is *DDIA*'s
  chapter on unreliable clocks, applied to a laptop that sleeps.
- **Decisions with their reasons, and evidence before building.** `decisions.md` works as an architecture decision log.
  Ideas get backtested before they're built (`backtest-contract-reader.md`, `backtest-test-weakening.md`,
  `worker-rediscovery-2026-11.md`), and a pre-registered bar dropped the team experiment (decision 2026-11-16 07:21).
  That is *Accelerate*'s and Deming's demand to measure before believing, which few teams meet.
- **Small batches and risk-scaled review.** Tasks are kept under about 30 minutes (decision 2026-11-12 10:33). Small,
  non-sensitive tasks merge on their tests (`LeadSmallTask.swift`), and sensitive paths are always audited
  (`LeadRisk.swift`). That is *Lean Software Development* and *Accelerate*'s small-batch finding, with the audit
  spend placed where the findings are (5–7% Important on small tasks, against 64% on large ones).
- **Contracts as the unit of work.** Each task carries a goal, acceptance checks and boundaries, has one owner through
  completion, and is checked by an independent verifier on another model. That is *The Pragmatic Programmer*'s design
  by contract and *Turn the Ship Around!*'s intent-based delegation, with the working policy in every prompt
  (`WorkingPolicy.swift`).

The weak spots these standards expose are few and specific: the merge gate's reliability is measured but has no target;
memory is checked by benches that only run on request; a security guard keeps meeting new spellings of the same
command; and two large files keep pulling unrelated work together.

## The book list

50 books in four groups, by first-edition year. They include every title the task named, plus these swaps and
additions, each chosen because it speaks to a problem this repository's records show:

- **Your Code as a Crime Scene** (Tornhill): its hotspot measure (churn × size) is the hot-file problem, with numbers.
- **Building Secure and Reliable Systems** (Google) and **Secure by Design**: the guard rails are a security boundary,
  and *Release It!* alone doesn't cover least privilege or parsing untrusted input.
- **Domain Modeling Made Functional**: the board's task states are where an incident on 2026-10-30 came from.
- **Building Evolutionary Architectures**: fitness functions are the missing piece for memory.
- **The Field Guide to Understanding Human Error** (Dekker): the incident process works best with its framing.
- **Implementing Service Level Objectives**, **Out of the Crisis** (Deming) and **The Toyota Way**: the merge gate is a
  production line, with common-cause variation (flakes) and a stop-the-line rule.
- **Shape Up**: its appetite is what a task's time budget already is.
- **Thinking in Systems** and **Turn the Ship Around!**: the self-improvement loop and the lead-worker delegation.

Left out on purpose: *The Phoenix Project* (a novel that restates *The DevOps Handbook*), *Head First Design Patterns*
(it repeats *Design Patterns*), language-specific books (*Effective Java*), and algorithm texts (*Introduction to
Algorithms*, *SICP*). None of those propose engineering-process patterns that the others don't.

### Design and architecture

| Book | Pattern | Status here |
| --- | --- | --- |
| Design Patterns, Gamma, Helm, Johnson & Vlissides, 1994 | Command: requests as objects that can be queued, logged and replayed | done: MCP tool calls are typed requests that `LeadToolset` dispatches and records in progress.md; `ComposerOutbox.swift` queues sends |
| | Strategy: pick an algorithm at run time behind one interface | done: `agent: auto` routes a task to Claude or Codex (decision 2026-11-02 08:18); `LeadDelivery.way` picks steer or type |
| Patterns of Enterprise Application Architecture, Fowler, 2002 | Optimistic offline lock: detect a stale write by version, don't lock | done: contracts carry versions, and a clean verdict on an older contract version is audited again (`LeadAdvance.swift`; backlog A6); merge refuses a verdict on a moved head (`LeadGuardRailsTests`) |
| | Unit of work: commit related changes together or not at all | done: the lead's records are committed by the tool server alone (`LeadRecords.swift`, decision 2026-10-17 17:45); batched merges land together or are split (`LeadMergeBatch.swift`) |
| Domain-Driven Design, Evans, 2003 | Ubiquitous language: one word, one meaning, shared by code and people | done: "vault" vs "wallet" renamed while the format was new (decision 2026-10-31 17:16); "board" vs "wall" kept apart (`team-on-one-task-design.md`) |
| | Bounded context with a published language and an anticorruption layer | done: wallet requests cross to another app only in a versioned format with test vectors (`docs/protocol/wallet-request.md`, `docs/protocol/vectors/`; decision 2026-10-31 15:15) |
| | Aggregate guarding its invariants | partly: `LeadBoard.swift` holds a task's states, but 14 direct `status =` writes in 4 files set them; see shortlist 10 |
| Enterprise Integration Patterns, Hohpe & Woolf, 2003 | Guaranteed delivery and dead-letter channel: a message that can't be delivered is noticed, not lost | partly: the witness reports a message waiting undelivered (incident 2026-11-03 09:26, Codex steer inbox, now fixed); delivery has no dead-letter record a lead can list |
| | Idempotent receiver: a resent message has its effect once | done: phone replies are sent once, with honest ✓/✗ (task phone-replies-sent-once); wallet sends go one card at a time with their own outcome (decision 2026-11-10 18:41) |
| Release It!, Nygard, 2007 | Bulkheads: one failure can't sink the rest | done for sessions (one parser process each, decision 2026-10-18 17:55) and for projects (Mac-wide slots, `TestLock.swift`); not done inside a test run, where one crash fails the whole suite: shortlist 4 |
| | Timeouts and circuit breakers | done: `StallWatch.swift` stops a silent run in minutes; the audit round cap stops after two failed rounds (`LeadAdvanceTests.pastTheRoundCapTheTaskIsLeftToTheLead`); usage and battery holds stop starts (`AccountUsage.swift`, `PowerSource.swift`) |
| | Steady state: a long-running process must not accumulate | partly: `FootprintRelief.swift`, the app-health line's growth trend (`AppHealth.swift`), and the benches `FootprintBenchTests`, `SandboxSoakBenchTests`; the benches run only with `--perf`, by hand: shortlist 6 |
| A Philosophy of Software Design, Ousterhout, 2018 | Deep modules: a small interface over a lot of behaviour | partly: `RefusedGit`, `MacTime`, `TestLock` are deep; `LeadToolset` is one 7,618-line class with 321 functions, in which every tool family shares one type |
| | Information hiding: a decision lives in one place | partly: the refused git options are kept once (`RefusedGit.swift` header); what the sandbox may do and its fixtures share one sensitive file (`Sandbox.swift`): shortlist 3 |
| Clean Architecture, Martin, 2017 | The dependency rule: policy doesn't depend on UI or frameworks | done: no file in `Sources/VibeCore` imports AppKit or SwiftUI; the app (`Sources/VibeSwitcher`) and the host (`Sources/VibeHost`) depend on it |
| | Humble object: keep logic out of what's hard to test | done: the app's logic is in VibeCore and tested headless; UI is checked in the sandbox (`scripts/sandbox-app.sh`) |
| Designing Data-Intensive Applications, Kleppmann, 2017 | Unreliable clocks: never order or time out by wall-clock | done: limits count awake time (`MacTime.swift`, decision 2026-11-08 20:36); decisions are stamped by the Mac's clock in one place (`LeadRecords.swift`) |
| | An append-only log with derived views | done: progress.md is append-only; `product-inventory.md` is generated from the code (`scripts/product-inventory.sh`); finished tasks move to `board-archive.jsonl` |
| Domain Modeling Made Functional, Wlaschin, 2018 | Make illegal states unrepresentable: legal transitions written once | not done: no transition table; a kept task was merged by auto_advance (incident 2026-10-30 21:42), fixed case by case (`aTaskSetKeptDuringItsMergesTestRunStaysKept`): shortlist 10 |
| | Parse, don't validate, at the edges | done: wallet requests are parsed strictly into a typed value (`WalletRequestFormat.swift`, vectors in `docs/protocol/vectors/`); `LeadWorkflow` reads workflow.md's known keys only |
| Building Evolutionary Architectures, Ford, Parsons & Kua, 2017 | Fitness functions: an architectural property checked automatically and continuously | partly: lints are fitness functions that run in every merge (`PrivateNamesLint`, `ElapsedTimeLint`, `TemporaryFolderLint`); performance and memory ones are benches outside the merge (decision 2026-10-21 22:52 (3)) and run by nobody on a schedule: shortlist 6 |
| Secure by Design, Johnsson, Deogun & Sawano, 2019 | Reject what you can't understand; allowlist over denylist | partly: the verifier's commands are an allowlist (`ReadOnlyCommand.swift`); the workers' git guard is a denylist over shell spellings and lists its own open cases (`RefusedGit.swift`): shortlist 5 |
| | Domain primitives for anything that crosses a trust boundary | done: secret-shaped text is refused in lead mail (decision 2026-11-04 22:18), `SecretShapes.swift`, `SecretShapeLint` |
| Building Secure and Reliable Systems, Adkins et al., 2020 | Least privilege: each role gets only what its job needs | done: per-role deny rules (`LeadLaunch.swift`), the lead writes no code, nobody pushes except through the user's click (decision 2026-11-04 22:42) |
| | Design for recovery: assume a guard fails and detect at the resource | partly: the base's head is checked by the vault (`LeadBaseMoves.swift`) and the agents' config is sealed (`ConfigSeal.swift`); a guard bypass in a worker is found only if it moves one of those |
| Fundamentals of Software Architecture, Richards & Ford, 2020 | Architecture decision records: context, decision, consequences | done: `docs/lead/decisions.md`, each entry with its reason, plus `decisions-archive.md` and `docs/process/lead-rules.md` mapping each rule to what enforces it |
| | Name the architecture characteristics and trade them explicitly | done: crash isolation's memory cost was accepted in numbers (decision 2026-10-18 17:55); three attached terminal views over a 30 s release (decision 2026-10-23 15:13) |

### Code and testing

| Book | Pattern | Status here |
| --- | --- | --- |
| Code Complete, McConnell, 1993 | Checklists for reviews and construction | done: `REVIEW.md` and the security checklist for guard-rail audits (task security-checklist-for, measured with `scripts/verifier-eval.sh`) |
| | Defensive programming: assertions at boundaries, fail closed | done as a rule: hardening contracts say "fail closed" up front (decision 2026-10-25 16:33 (a)); not applied to the git guard's unreadable lines: shortlist 5 |
| The Pragmatic Programmer, Hunt & Thomas, 1999 | Design by contract | done: every task has a goal, acceptance checks and boundaries; done reports carry evidence per check (`LeadDoneEvidenceTests`) |
| | Don't live with broken windows | partly: Nits never become tasks (`LeadRuleChecksTests.aNitIsntMadeATask`), and lints keep allow-lists of old cases "still to move" (`ElapsedTimeLintTests.allowed`), which nothing counts down |
| | DRY of knowledge, not of text | done: one list of refused git options feeds both the deny rules and the hook (`RefusedGit.swift`); the working policy is one text in every prompt (`WorkingPolicy.swift`) |
| Refactoring, Fowler, 1999 | Preparatory refactoring: make the change easy, then make the easy change | not done as a process step: structural changes ride inside behaviour tasks, and large tasks need a second audit round 59% of the time (decision 2026-11-12 10:33): shortlist 2 |
| | Extract class or move function out of a large class | not done for `LeadToolset.swift` (7,618 lines); see shortlist 2 for why it's done piecemeal rather than as one split |
| Test-Driven Development: By Example, Beck, 2002 | Red first: a test that fails before the code that passes it | done for fixes: a fix's test is shown failing without it (decision 2026-10-25 09:46; worker brief `regressionTest`); the mechanical check of it is parked (decision 2026-11-06 22:35 (2)) |
| Working Effectively with Legacy Code, Feathers, 2004 | Seams: a place to change behaviour without editing it, for tests | done: injected clocks and homes (`MacTime.swift`, `Scratch`, the scratch HOME in `scripts/test.sh`), fake ttys (`Tests/VibeSwitcherTests/FakeClaude.swift`) |
| | Characterization tests before changing code nobody fully understands | partly: guard-rail behaviour is pinned (`LeadGuardRailsTests`, `RefusedGitSpellingsTests`); the merge path is pinned by merge-simulation tests, which hung once under load (incident 2026-11-08 19:21) |
| | Sprout method or class: put new behaviour in a new, tested unit | done in practice: new behaviour lands in new files (`LeadSmallTask.swift`, `LeadOverlap.swift`, `LeadSleepRecovery.swift`); their entry points still go through `LeadToolset` |
| xUnit Test Patterns, Meszaros, 2007 | Erratic test: name the cause (shared fixture, async wait, time, resource leak) and remove it | partly: the flake ledger plans a task at 3 flakes (`FlakeLedger.swift`); 36 flaky-test tasks so far, and the backlog cites 25% of flaky fixes flaking again |
| | Fresh fixture per test | done: `Scratch` and `shortFolder` per test, never `/tmp` (`TemporaryFolderLint`) |
| Clean Code, Martin, 2008 | Small functions doing one thing; names that say what | partly: most files are small and named for behaviour; `LeadToolset.swift`'s 321 functions are mostly tool handlers of 20–200 lines |
| Growing Object-Oriented Software, Guided by Tests, Freeman & Pryce, 2009 | Listen to the tests: hard-to-test code signals a design problem | done: the 2026-10-17 engineering pass found the app untestable (hard-wired paths), which led to the scratch home (`docs/eval/engineering.md`, E-32) |
| | Testing asynchronous code: probe and poll for an event, never sleep | done: `eventually`/`until` in each target's `TestSupport.swift`; tests proven under load before done (decision 2026-10-23 14:16; `LeadRuleChecksTests.aDoneThatAddsTestsWithoutTheirRunUnderLoadIsRefused`) |
| Your Code as a Crime Scene, Tornhill, 2015 | Hotspots: churn × complexity points at where defects and coordination cost gather | partly: hot files are known and handled by planning rules (decisions 2026-11-08 07:28, 2026-11-08 17:52, 2026-11-12 16:27; `LeadOverlap.swift` warns on shared files), not by changing the files: shortlist 3 |
| | Temporal coupling: files that always change together belong together | not done: nothing reads co-change from git history; the overlap warning reads boundaries, not history |
| Unit Testing: Principles, Practices, and Patterns, Khorikov, 2020 | Test observable behaviour, not implementation | done: source-scanning lints are the exception and are named as such (decision 2026-10-31 10:33); behaviour tests drive the tool server as the lead would (`LeadTeamFixture`) |
| | Few, valuable end-to-end tests; many fast unit tests | partly: the default run holds about 4,400 tests (unit and integration), plus on-demand end-to-end scripts (`scripts/e2e/wallet-e2e.sh`, `scripts/ui-journeys.sh`); there is no size split in the merge run (see Software Engineering at Google below) |
| Tidy First?, Beck, 2023 | Separate structure changes from behaviour changes, in separate commits or reviews | not done as a rule: a task's commits mix both, and its reviewer sees one diff: shortlist 2 |
| | Coupling is what makes change expensive; tidy where you're about to change | partly: the planning rules route around coupling (decision 2026-11-12 16:27) rather than reduce it |

### Delivery and operations

| Book | Pattern | Status here |
| --- | --- | --- |
| Continuous Integration, Duvall, Matyas & Glover, 2007 | Integrate often against a main line that stays green | done: tasks merge into main many times a day (18.6 a day in the speed review's week); a red main stops merges (`LeadPipeline.swift`); the full suite runs on main after the user pulls outside work (decision 2026-10-31 00:40) |
| Continuous Delivery, Humble & Farley, 2010 | The deployment pipeline: every change goes through the same automated stages | done: done check (`LeadDoneCheck.swift`), audit, merge with the full suite, landing check (`LeadLandingCheck.swift`), install card (decision 2026-11-17 11:44) |
| | A fast commit stage (about 10 min) before slower stages | partly: the merge run is the only stage, median 17.0 min this week; a calm-Mac merge was planned at about 9 min (task a-calm-mac-merge, merged 2026-11-12); task faster-test-suite is on it now |
| | Keep releases reversible | partly: `revert` exists for a merged task; install rollback is an idea (backlog B12) |
| Site Reliability Engineering, Beyer, Jones, Petoff & Murphy (eds), 2016 | Service-level objectives with an error budget that decides between features and reliability | partly: the gate's first-try rate is shown in Statistics (`SetupStatsQuality.swift`), but no target and no rule act on it: shortlist 1 |
| | Every alert is actionable; alert on symptoms the user cares about | partly: the lead speaks only in four cases (decision 2026-11-17 19:55); report cards fold into one line (task lead-chat-noise-fold, merged 2026-11-17); nothing measures the share that needed the user: shortlist 8 |
| | Eliminate toil | done: auto_advance does the routine steps (`LeadAdvance.swift`), idle workers are released during audits, cleanup frees build output by itself |
| The DevOps Handbook, Kim, Humble, Debois & Willis, 2016 | The three ways: flow, fast feedback, continual learning | done: small tasks, the pre-done check, and retrospectives that turn into tasks or decisions (decision 2026-11-01 08:54, brief's retrospective step) |
| | Telemetry everywhere, in a shared place | done: the load recorder, merge records, receipts and waits (`LoadRecorder.swift`, `LeadReceipt.swift`, `LeadWaits.swift`), the app-health digest (`AppHealth.swift`) |
| Accelerate, Forsgren, Humble & Kim, 2018 | The four key metrics: deploy frequency, lead time, change failure rate, time to restore | partly: merges a day and time to install are in the weekly scorecard (`SetupScorecard.swift`); change failure rate is counted by hand in retrospectives (decision 2026-11-09 14:20 (4)), and time to restore isn't counted: shortlist 7 |
| | Small batches and loosely coupled work | done: tasks under about 30 min (decision 2026-11-12 10:33); parallel tasks, warned on shared files (`LeadOverlap.swift`) |
| The Site Reliability Workbook, Beyer et al. (eds), 2018 | Postmortem action items are tracked and their effect checked | partly: each incident plans a check task (`record_incident`); nothing asks later whether the incident came back after its check merged, as it did on 2026-11-07 (19:46, then 22:19): shortlist 9 |
| | Alert on burn rate, not single failures | not done; follows from shortlist 1 |
| Software Engineering at Google, Winters, Manshreck & Wright (eds), 2020 | Flaky tests are tracked and fixed as a cost, not rerun forever | partly: one rerun (`MergeRerun.swift`), the flake ledger and its 3-flake rule (`FlakeLedger.swift`); quarantine (pulling a flaky test out of the gate) doesn't fit: the policy forbids moving a test out of the merge's suite |
| | Test sizes: small, medium, large, each with its own limits and runner | not done: one `swift test` process runs everything, so one crash takes 360–525 unfinished tests with it (`speed-review-2026-11-12.md`): shortlist 4 |
| | The Beyoncé rule: if you liked it, you should have put a test on it | done: incidents become checks; lints scan the whole repository (`PrivateNamesLint`, `SecretShapeLint`, `DocLinksLint`) |
| Implementing Service Level Objectives, Hidalgo, 2020 | SLIs that measure what users feel, and a budget policy agreed beforehand | not done: the user feels merge latency and sent-back merges; neither has an objective: shortlist 1 |
| Modern Software Engineering, Farley, 2021 | Optimise for learning: experiments with hypotheses, measured | done, then paused: the impact ledger (`docs/process/impact.md`, decision 2026-11-01 08:54) was paused 2026-11-09 14:20 (2); pre-registered experiments still run (decision 2026-11-16 07:21) |
| | Manage complexity with modularity and separation of concerns | partly: see A Philosophy of Software Design |
| Observability Engineering, Majors, Fong-Jones & Miranda, 2022 | Structured, high-cardinality events to ask new questions after the fact | done: per-minute load samples and per-merge records as JSON lines, read by scripts (`scripts/load-report.sh`, `scripts/impact-metrics.sh`) |
| | Trace one unit of work across components | partly: a task's receipt and waits follow it from start to merge (`LeadReceipt.swift`, `LeadWaits.swift`), and merges carry provenance trailers (`LeadProvenance.swift`); a merge failure's log now reaches the worker (incident 2026-11-09 18:26) |
| Chaos Engineering, Rosenthal & Jones, 2020 | Inject failures to test the system's response | parked: a chaos corpus for the orchestrator (decision 2026-11-06 22:35 (8)), until an incident calls for it |
| The Field Guide to Understanding Human Error, Dekker, 2006 | Ask what made the action make sense at the time, not who erred | done: incident entries record context and evidence; retrospectives change tools or contracts, not blame (decisions 2026-11-08 23:16, 2026-11-09 14:20) |
| | Look for the second story: the system's conditions behind the error | done: "the incidents point to handoffs the system controls, not to too few reviewers" (decision 2026-11-09 14:20) |
