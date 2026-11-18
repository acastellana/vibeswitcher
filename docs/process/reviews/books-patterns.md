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

The product inventory was searched for Statistics, the scorecard, notifications, memory and the benches; nothing in it
covers a "not done" row. Decision references are `decision YYYY-MM-DD HH:MM` and point at `docs/lead/decisions.md` unless they say
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
merge gate, treated as a production service with an objective and an error budget. The nine ranked proposals:

1. **An error budget for the merge gate** (SRE, Implementing SLOs, Deming): 18% of merge runs this week passed only on a whole rerun.
2. **Tidy first, as its own small task** (Tidy First?, Refactoring): large tasks need a second audit round 59% of the time.
3. **The git guard fails closed on git it can't see** (Building Secure and Reliable Systems, Secure by Design): two spelling tasks in one evening, and `RefusedGit.swift` itself lists the open spellings.
4. **Split Sandbox.swift by what's sensitive** (A Philosophy of Software Design, Your Code as a Crime Scene): 36 audits were started only because a UI task touched it.
5. **The memory benches run by themselves on a calm Mac** (Building Evolutionary Architectures, Release It!): the app's memory growth has needed 9 tasks since October.
6. **Time to restore, and escapes, in the weekly scorecard** (Accelerate): pipeline blocks aren't counted at all, and escapes sit apart in Statistics.
7. **Lead messages measured by whether they needed the user** (SRE, Making Work Visible): the noise rule was written twice, on 10-25 and 11-17.
8. **Each retrospective checks whether an incident came back after its check merged** (The Site Reliability Workbook, Dekker).
9. **One transition table for a task's states** (Domain Modeling Made Functional): low on the list, since only one incident backs it.

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
  spend placed where the findings are (5–10% of small tasks had an Important finding, against 64% of large ones).
- **Contracts as the unit of work.** Each task carries a goal, acceptance checks and boundaries, has one owner through
  completion, and is checked by an independent verifier on another model. That is *The Pragmatic Programmer*'s design
  by contract and *Turn the Ship Around!*'s intent-based delegation, with the working policy in every prompt
  (`WorkingPolicy.swift`).

The weak spots these standards expose are few and specific: the merge gate's reliability is measured but has no target;
memory is checked by benches that only run on request; a security guard keeps meeting new spellings of the same
command; and two large files keep pulling unrelated work together.

## The book list

50 books in four groups, each with its first edition's year. They include every title the task named, plus these swaps and
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
| Patterns of Enterprise Application Architecture, Fowler, 2002 | Optimistic offline lock: detect a stale write by version, don't lock | done: contracts carry versions, and a clean verdict on an older contract version is audited again (`LeadBoard.swift`, `LeadToolset.swift`; backlog A6); merge refuses a verdict on a moved head (`LeadGuardRailsTests`) |
| | Unit of work: commit related changes together or not at all | done: the lead's records are committed by the tool server alone (`LeadRecords.swift`, decision 2026-10-17 17:45); batched merges land together or are split (`LeadMergeBatch.swift`) |
| Domain-Driven Design, Evans, 2003 | Ubiquitous language: one word, one meaning, shared by code and people | done: "vault" vs "wallet" renamed while the format was new (decision 2026-10-31 17:16); "board" vs "wall" kept apart (`team-on-one-task-design.md`) |
| | Bounded context with a published language and an anticorruption layer | done: wallet requests cross to another app only in a versioned format with test vectors (`docs/protocol/wallet-request.md`, `docs/protocol/vectors/`; decision 2026-10-31 15:15) |
| | Aggregate guarding its invariants | partly: `LeadBoard.swift` holds a task's states, but 14 direct `status =` writes in 4 files set them; see shortlist 9 |
| Enterprise Integration Patterns, Hohpe & Woolf, 2003 | Guaranteed delivery and dead-letter channel: a message that can't be delivered is noticed, not lost | partly: the witness reports a message waiting undelivered (incident 2026-11-03 09:26, Codex steer inbox, now fixed); delivery has no dead-letter record a lead can list |
| | Idempotent receiver: a resent message has its effect once | done: phone replies are sent once, with honest ✓/✗ (task phone-replies-sent-once); wallet sends go one card at a time with their own outcome (decision 2026-11-10 18:41) |
| Release It!, Nygard, 2007 | Bulkheads: one failure can't sink the rest | done for sessions (one parser process each, decision 2026-10-18 17:55) and for projects (Mac-wide slots, `TestLock.swift`); inside a test run, sharding was weighed and dropped on 2026-11-12 (the speed review's re-check): reruns take only the failing tests instead (`MergeRerun.swift`) |
| | Timeouts and circuit breakers | done: `StallWatch.swift` stops a silent run in minutes; the audit round cap stops after two failed rounds (`LeadAdvanceTests.pastTheRoundCapTheTaskIsLeftToTheLead`); usage and battery holds stop starts (`AccountUsage.swift`, `PowerSource.swift`) |
| | Steady state: a long-running process must not accumulate | partly: `FootprintRelief.swift`, the app-health line's growth trend (`AppHealth.swift`), and the benches `FootprintBenchTests`, `SandboxSoakBenchTests`; the benches run only with `--perf`, by hand: shortlist 5 |
| A Philosophy of Software Design, Ousterhout, 2018 | Deep modules: a small interface over a lot of behaviour | partly: `RefusedGit`, `MacTime`, `TestLock` are deep; `LeadToolset` is one 7,618-line class with 321 functions, in which every tool family shares one type |
| | Information hiding: a decision lives in one place | partly: the refused git options are kept once (`RefusedGit.swift` header); what the sandbox may do and its fixtures share one sensitive file (`Sandbox.swift`): shortlist 4 |
| Clean Architecture, Martin, 2017 | The dependency rule: policy doesn't depend on UI or frameworks | done: no file in `Sources/VibeCore` imports AppKit or SwiftUI; the app (`Sources/VibeSwitcher`) and the host (`Sources/VibeHost`) depend on it |
| | Humble object: keep logic out of what's hard to test | done: the app's logic is in VibeCore and tested headless; UI is checked in the sandbox (`scripts/sandbox-app.sh`) |
| Designing Data-Intensive Applications, Kleppmann, 2017 | Unreliable clocks: never order or time out by wall-clock | done: limits count awake time (`MacTime.swift`, decision 2026-11-08 20:36); decisions are stamped by the Mac's clock in one place (`LeadBoard.appendDecision`) |
| | An append-only log with derived views | done: progress.md is append-only; `product-inventory.md` is generated from the code (`scripts/product-inventory.sh`); finished tasks move to `board-archive.jsonl` |
| Domain Modeling Made Functional, Wlaschin, 2018 | Make illegal states unrepresentable: legal transitions written once | not done: no transition table; a kept task was merged by auto_advance (incident 2026-10-30 21:42), fixed case by case (`aTaskSetKeptDuringItsMergesTestRunStaysKept`): shortlist 9 |
| | Validate at the trust boundary into types that can't hold bad data | done: wallet requests are parsed strictly into a typed value (`WalletRequestFormat.swift`, vectors in `docs/protocol/vectors/`); `LeadWorkflow` reads workflow.md's known keys only |
| Building Evolutionary Architectures, Ford, Parsons & Kua, 2017 | Fitness functions: an architectural property checked automatically and continuously | partly: lints are fitness functions that run in every merge (`PrivateNamesLint`, `ElapsedTimeLint`, `TemporaryFolderLint`); performance and memory ones are benches outside the merge (decision 2026-10-21 22:52 (3)) and run by nobody on a schedule: shortlist 5 |
| Secure by Design, Johnsson, Deogun & Sawano, 2019 | Reject what you can't understand; allowlist over denylist | partly: the verifier's commands are an allowlist (`ReadOnlyCommand.swift`); the workers' git guard is a denylist over shell spellings and lists its own open cases (`RefusedGit.swift`): shortlist 3 |
| | Domain primitives for anything that crosses a trust boundary | done: secret-shaped text is refused in lead mail (decision 2026-11-04 22:18), `SecretShapes.swift`, `SecretShapeLint` |
| Building Secure and Reliable Systems, Adkins et al., 2020 | Least privilege: each role gets only what its job needs | done: per-role deny rules (`LeadLaunch.swift`), the lead writes no code, nobody pushes except through the user's click (decision 2026-11-04 22:42) |
| | Design for recovery: assume a guard fails and detect at the resource | partly: the base's head is checked by the vault (`LeadBaseMoves.swift`) and the agents' config is sealed (`ConfigSeal.swift`); a guard bypass in a worker is found only if it moves one of those |
| Fundamentals of Software Architecture, Richards & Ford, 2020 | Architecture decision records: context, decision, consequences | done: `docs/lead/decisions.md`, each entry with its reason, plus `decisions-archive.md` and `docs/process/lead-rules.md` mapping each rule to what enforces it |
| | Name the architecture characteristics and trade them explicitly | done: crash isolation's memory cost was accepted in numbers (decision 2026-10-18 17:55); three attached terminal views over a 30 s release (decision 2026-10-23 15:13) |

### Code and testing

| Book | Pattern | Status here |
| --- | --- | --- |
| Code Complete, McConnell, 1993 | Checklists for reviews and construction | done: `REVIEW.md` and the security checklist for guard-rail audits (task security-checklist-for, measured with `scripts/verifier-eval.sh`) |
| | Defensive programming: assertions at boundaries, fail closed | done as a rule: hardening contracts say "fail closed" up front (decision 2026-10-25 16:33 (a)); not applied to the git guard's unreadable lines: shortlist 3 |
| The Pragmatic Programmer, Hunt & Thomas, 1999 | Design by contract | done: every task has a goal, acceptance checks and boundaries; done reports carry evidence per check (`LeadDoneEvidenceTests`) |
| | Don't live with broken windows | partly: Nits never become tasks (`LeadRuleChecksTests.aNitIsntMadeATask`), and lints keep allow-lists of old cases "still to move" (`ElapsedTimeLintTests.allowed`), which nothing counts down |
| | DRY of knowledge, not of text | done: one list of refused git options feeds both the deny rules and the hook (`RefusedGit.swift`); the working policy is one text in every prompt (`WorkingPolicy.swift`) |
| Refactoring, Fowler, 1999 | Preparatory refactoring: make the change easy, then make the easy change | not done as a process step: structural changes ride inside behaviour tasks, and large tasks need a second audit round 59% of the time (decision 2026-11-12 10:33): shortlist 2 |
| | Extract class or move function out of a large class | not done for `LeadToolset.swift` (7,618 lines); see shortlist 2 for why it's done piecemeal rather than as one split |
| Test-Driven Development: By Example, Beck, 2002 | Red first: a test that fails before the code that passes it | done for fixes: a fix's test is shown failing without it (decision 2026-10-25 09:46; worker brief `regressionTest`); the mechanical check of it is parked (decision 2026-11-06 22:35 (2)) |
| Working Effectively with Legacy Code, Feathers, 2004 | Seams: a place to change behaviour without editing it, for tests | done: injected clocks and homes (`MacTime.swift`, `Scratch`, the scratch HOME in `scripts/test.sh`), fake ttys (`Tests/VibeSwitcherTests/FakeClaude.swift`) |
| | Characterization tests before changing code nobody fully understands | partly: guard-rail behaviour is pinned (`LeadGuardRailsTests`, `RefusedGitSpellingsTests`); the merge path is pinned by merge-simulation tests (`aTaskSetKeptDuringItsMergesTestRunStaysKept`), whose 2026-11-08 "hang" was the Mac asleep (decision 2026-11-08 20:36) |
| | Sprout method or class: put new behaviour in a new, tested unit | done in practice: new behaviour lands in new files (`LeadSmallTask.swift`, `LeadOverlap.swift`, `LeadSleepRecovery.swift`); their entry points still go through `LeadToolset` |
| xUnit Test Patterns, Meszaros, 2007 | Erratic test: name the cause (shared fixture, async wait, time, resource leak) and remove it | partly: the flake ledger plans a task at 3 flakes (`FlakeLedger.swift`); 36 flaky-test tasks so far, and the backlog cites 25% of flaky fixes flaking again |
| | Fresh fixture per test | done: `Scratch` and `shortFolder` per test, never `/tmp` (`TemporaryFolderLint`) |
| Clean Code, Martin, 2008 | Small functions doing one thing; names that say what | partly: most files are small and named for behaviour; `LeadToolset.swift`'s 321 functions are mostly tool handlers of 20–200 lines |
| Growing Object-Oriented Software, Guided by Tests, Freeman & Pryce, 2009 | Listen to the tests: hard-to-test code signals a design problem | done: the 2026-10-17 engineering pass found the app untestable (hard-wired paths), which led to the scratch home (`docs/eval/engineering.md`, E-32) |
| | Testing asynchronous code: probe and poll for an event, never sleep | done: `eventually`/`until` in each target's `TestSupport.swift`; tests proven under load before done (decision 2026-10-23 14:16; `LeadRuleChecksTests.aDoneThatAddsTestsWithoutTheirRunUnderLoadIsRefused`) |
| Your Code as a Crime Scene, Tornhill, 2015 | Hotspots: churn × complexity points at where defects and coordination cost gather | partly: hot files are known and handled by planning rules (decisions 2026-11-08 07:28, 2026-11-08 17:52, 2026-11-12 16:27; `LeadOverlap.swift` warns on shared files), not by changing the files: shortlist 4 |
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
| | Every alert is actionable; alert on symptoms the user cares about | partly: the lead speaks only in four cases (decision 2026-11-17 19:55); report cards fold into one line (task lead-chat-noise-fold, merged 2026-11-17); nothing measures the share that needed the user: shortlist 7 |
| | Eliminate toil | done: auto_advance does the routine steps (`LeadAdvance.swift`), idle workers are released during audits, cleanup frees build output by itself |
| The DevOps Handbook, Kim, Humble, Debois & Willis, 2016 | The three ways: flow, fast feedback, continual learning | done: small tasks, the pre-done check, and retrospectives that turn into tasks or decisions (decision 2026-11-01 08:54, brief's retrospective step) |
| | Telemetry everywhere, in a shared place | done: the load recorder, merge records, receipts and waits (`LoadRecorder.swift`, `LeadReceipt.swift`, `LeadWaits.swift`), the app-health digest (`AppHealth.swift`) |
| Accelerate, Forsgren, Humble & Kim, 2018 | The four key metrics: deploy frequency, lead time, change failure rate, time to restore | partly: cost per merge and time to install are in the weekly scorecard (`SetupScorecard.swift`); merges a day and escapes (a merge later reverted or named by an incident, Accelerate's change failure) are in Statistics (`SetupStatsQuality.swift`), not the weekly scorecard; corrective follow-ups are counted by hand in retrospectives (decision 2026-11-09 14:20 (4)); time to restore isn't counted: shortlist 6 |
| | Small batches and loosely coupled work | done: tasks under about 30 min (decision 2026-11-12 10:33); parallel tasks, warned on shared files (`LeadOverlap.swift`) |
| The Site Reliability Workbook, Beyer et al. (eds), 2018 | Postmortem action items are tracked and their effect checked | partly: each incident plans a check task (`record_incident`); nothing asks later whether the incident came back after its check merged, as it did on 2026-11-07 (19:46, then 22:19): shortlist 8 |
| | Alert on burn rate, not single failures | not done; follows from shortlist 1 |
| Software Engineering at Google, Winters, Manshreck & Wright (eds), 2020 | Flaky tests are tracked and fixed as a cost, not rerun forever | partly: one rerun (`MergeRerun.swift`), the flake ledger and its 3-flake rule (`FlakeLedger.swift`); quarantine (pulling a flaky test out of the gate) doesn't fit: the policy forbids moving a test out of the merge's suite |
| | Test sizes: small, medium, large, each with its own limits and runner | decided against 2026-11-12: sharding the merge run was dropped in the speed review's re-check, because the crash evidence didn't hold; reruns of only the failing tests were built instead (`MergeRerun.swift`) |
| | The Beyoncé rule: if you liked it, you should have put a test on it | done: incidents become checks; lints scan the whole repository (`PrivateNamesLint`, `SecretShapeLint`, `DocLinksLint`) |
| Implementing Service Level Objectives, Hidalgo, 2020 | SLIs that measure what users feel, and a budget policy agreed beforehand | not done: the user feels merge latency and sent-back merges; neither has an objective: shortlist 1 |
| Modern Software Engineering, Farley, 2021 | Optimise for learning: experiments with hypotheses, measured | done, then paused: the impact ledger (`docs/process/impact.md`, decision 2026-11-01 08:54) was paused 2026-11-09 14:20 (2); pre-registered experiments still run (decision 2026-11-16 07:21) |
| | Manage complexity with modularity and separation of concerns | partly: see A Philosophy of Software Design |
| Observability Engineering, Majors, Fong-Jones & Miranda, 2022 | Structured, high-cardinality events to ask new questions after the fact | done: per-minute load samples and per-merge records as JSON lines, read by scripts (`scripts/load-report.sh`, `scripts/impact-metrics.sh`) |
| | Trace one unit of work across components | partly: a task's receipt and waits follow it from start to merge (`LeadReceipt.swift`, `LeadWaits.swift`), and merges carry provenance trailers (`LeadProvenance.swift`); a merge failure's log now reaches the worker (incident 2026-11-09 18:26) |
| Chaos Engineering, Rosenthal & Jones, 2020 | Inject failures to test the system's response | parked: a chaos corpus for the orchestrator (decision 2026-11-06 22:35 (8)), until an incident calls for it |
| The Field Guide to Understanding Human Error, Dekker, 2006 | Ask what made the action make sense at the time, not who erred | done: incident entries record context and evidence; retrospectives change tools or contracts, not blame (decisions 2026-11-08 23:16, 2026-11-09 14:20) |
| | The new view: an error is a symptom of trouble deeper in the system | done: "the incidents point to handoffs the system controls, not to too few reviewers" (decision 2026-11-09 14:20) |

### Flow, teams and management

| Book | Pattern | Status here |
| --- | --- | --- |
| The Mythical Man-Month, Brooks, 1975 | Adding people to a late task makes it later (communication grows with team size) | done, measured: the team-on-one-task arm cost 2.0× the tokens and about 8 extra lead turns, and was dropped (decision 2026-11-16 07:21) |
| | The surgical team and conceptual integrity: one mind decides the design | done: the lead plans and decides, workers build one contract each, the lead writes no code (`LeadLaunch.deny(.lead)`) |
| Out of the Crisis, Deming, 1982 | Common-cause vs special-cause variation: don't react to noise, fix the system | partly: the flake ledger waits for 3 flakes before acting (`FlakeLedger.swift`); trends are said only above a sample floor (`SetupScorecard.trendFloor`); 18% of merge runs passing only on a rerun is a system property that no one owns: shortlist 1 |
| | PDSA: plan, do, study, act | done, then paused: the impact ledger's hypotheses and verdicts (`docs/process/impact.md`), paused 2026-11-09 |
| The Goal, Goldratt, 1984 | Find the constraint, exploit it, subordinate everything else to it | partly: the speed review looked for the constraint (planned work and the Mac's sleep, not capacity), and its re-check put extra audit rounds first among costs with a lever (`speed-review-2026-11-12.md`); sleep's cost is shown (`SleepCost.swift`, task sleep-shows-its-cost); rounds are what shortlist 2 goes after |
| Peopleware, DeMarco & Lister, 1987 | Protect flow time from interruptions | done for the user: questions get a default timer, routine events no message (decisions 2026-10-17 21:27, 2026-11-17 19:55); workers own routine calls instead of asking (decision 2026-10-21 22:52 (2)) |
| | Quality is set by the builders, not imposed afterwards | done: the worker proves its own work (evidence, blind check, tests under load) before an audit |
| Lean Software Development, Poppendieck & Poppendieck, 2003 | See the waste: waiting, relearning, handoffs, task switching, partly done work | done, measured: relearning 3.0% of worker time (`worker-rediscovery-2026-11.md`); waiting by cause (`LeadWaits.swift`); sleep 33% of in-flight time, most of it in ten tasks (speed review and its re-check) |
| | Decide as late as possible; amplify learning | done: triggered ideas are parked with their trigger (decision 2026-11-06 22:35), and backtests come before building (decision 2026-11-09 11:14) |
| The Toyota Way, Liker, 2004 | Jidoka: stop the line on a defect | done: main red stops merges (`LeadPipeline.swift`); a blocked pipeline is found and acted on (task merges-never-sit-blocked) |
| | Poka-yoke: make the mistake impossible rather than warned against | done: `docs/process/lead-rules.md` lists 33 enforced rules; partly for workers' git (a denylist with known gaps, shortlist 3) |
| Thinking in Systems, Meadows, 2008 | Feedback loops with delays: a balancing loop needs a measured stock | partly: retrospectives close the loop on process (`LeadWorkflow.swift`'s retrospective step); stocks like open flakes or "still to move" lint entries have no target |
| The Principles of Product Development Flow, Reinertsen, 2009 | Queues are the hidden cost: measure queue size and its cost of delay | done: task waits by cause (`LeadWaits.swift`); the cost of an extra audit round measured (median 208 min against 89 from start to merge, the re-check in `speed-review-2026-11-12.md`) |
| | Small batches; limit work in process | done: max_workers and Mac-wide limits (`LeadWorkflow.swift`, `MacLoad.swift`); batched merges of up to 8 (decision 2026-11-12 15:28) |
| | Prioritise by cost of delay over duration (WSJF) | partly: the backlog ranks by effect ÷ cost (`docs/process/backlog.md`); the board starts tasks in planned order |
| Kanban, Anderson, 2010 | Make policies explicit; limit WIP per stage | done: `docs/process/lead-rules.md`; heavy slots and one merge at a time (`TestLock.swift`) |
| Turn the Ship Around!, Marquet, 2012 | Intent-based leadership: "I intend to…" instead of asking permission | done: workers own routine calls and list them in their report (decision 2026-10-21 22:52 (2)); the lead asks the user only about direction (decision 2026-10-18 18:50) |
| Making Work Visible, DeGrandis, 2017 | The time thieves: too much WIP, unknown dependencies, unplanned work, conflicting priorities, neglected work | partly: dependencies are visible (`after`, `LeadOverlap.swift`); unplanned work (incidents, flakes) isn't shown against planned work anywhere |
| | Visualise all work, including interruptions | done: the Team view and its fading feed (decision 2026-10-17 21:27) |
| An Elegant Puzzle, Larson, 2019 | Finish migrations: make the new way the default and drive the old one to zero | partly: lints with allow-lists (`ElapsedTimeLintTests.allowed` has entries "still to move") don't count down to zero |
| | Work on what matters; measure the system, not the people | done: the scorecard reads exact data only (`SetupScorecard.swift`) |
| Team Topologies, Skelton & Pais, 2019 | Limit cognitive load per team: give each team a bounded domain | partly: a contract bounds each worker; the files they must read don't: `LeadToolset.swift` is read by most lead-tool tasks whatever their part |
| | Conway's law in reverse: shape the system to the teams you want | doesn't fit as a team rule (workers are short-lived); it does as a file rule: split by who changes what (shortlist 4) |
| Shape Up, Singer, 2019 | Appetite: fix the time, vary the scope; a circuit breaker at the end | done: a time budget per task (`LeadBudget.swift`), and over budget the worker reports what works and proposes a cut |

## Already tried, decided against or parked

These came up from the books too, but they're settled. They aren't proposed again here.

| Idea (book) | Settled | Where |
| --- | --- | --- |
| A team of workers on one task (Brooks's surgical team, inverted) | dropped 2026-11-16 | decision 2026-11-16 07:21 |
| A shared notes board between workers (Lean: relearning waste) | not built 2026-11-13; reopens over 5% of worker time | decision 2026-11-13 19:24 |
| Bigger tasks with verification points | superseded the same day, 2026-11-12 | decision 2026-11-12 10:33 (archive 2026-11-12 09:23 for the first one) |
| A fresh reader for contracts; a "tests got weaker" check (Khorikov, Meszaros) | not built 2026-11-09 | decision 2026-11-09 11:14 and the two backtests in `docs/process/reviews/` |
| The impact ledger's routine (Deming's PDSA, Farley) | paused 2026-11-09 | decision 2026-11-09 14:20 (2) |
| A scheduled gardener agent and idle bug sweeps | not built 2026-10-26 | decision 2026-10-26 11:01 (c) |
| Replays to compare whole harness versions | the user chose estimates only, 2026-11-02 | decision 2026-11-02 23:00 |
| A chaos corpus, mechanical fail-without-fix, per-contract path globs | parked with triggers, 2026-11-06 | decision 2026-11-06 22:35 |
| A copy-of-the-build start for worktrees | abandoned 2026-10-26 | archive, decision 2026-10-26 02:06 |
| Sharding the merge's test run so a crash costs one shard (Release It!'s bulkheads, Software Engineering at Google's test sizes) | dropped 2026-11-12 | `speed-review-2026-11-12.md`, the re-check's row 4: the crash evidence didn't hold; reruns of only the failing tests were built instead |
| Claude Code's OS sandbox for worker shells | weighed and not recommended for speed, 2026-11-12 | `speed-review-2026-11-12.md`, "Weighed and not recommended" |
| Quarantining flaky tests out of the gate (Software Engineering at Google) | doesn't fit | the working contracts forbid moving a test out of the merge's suite (task faster-test-suite's acceptance); the rerun and the ledger stand in |

## The shortlist

Ranked by value against cost. Each item says where its idea comes from, what changes, the problem here with its
evidence, a rough cost, and how to tell after a week. The week checks read data that is already recorded (the impact
ledger is paused), with today's baseline.

### 1. An error budget for the merge gate

- **From:** *Site Reliability Engineering* (SLOs and error budgets), *Implementing Service Level Objectives* (a budget
  policy agreed beforehand), Deming (a stable failure rate is the system's, not any one task's).
- **Change:** two objectives for this project's merge runs, over a rolling 7 days, shown in the weekly scorecard
  (`Sources/VibeCore/SetupScorecard.swift`) next to the first-try figures Statistics already computes
  (`SetupStatsQuality.swift`). First, at most 5% of merge runs pass only on their rerun: that's the noise, while a run
  that fails twice and sends its branch back is the gate working. Second, the median calm-Mac merge (1-minute load at
  most 6) takes 10 minutes or less, the target a-calm-mac-merge set. Then one line in the lead's brief (`LeadPrompts.lead`
  in `Sources/VibeCore/LeadWorkflow.swift`), next to the retrospective step: while either objective is missed, the
  next tasks the lead plans come from the flake ledger's top entries, the failures that name no test, and the slowest
  suites, ahead of new features, until both are met again. The backlog's freeze budget (B3, landed 2026-11-08) is the
  same idea applied to the app's freezes.
- **Problem and evidence:** this week 16 of the 89 runs that record a first run (18%) passed only on their rerun, and
  every one of them reran the whole command, so the failing run named no test and paid for a second full run (14%
  the week before: 18 of 129). Another 8 failed twice and went back to their branch. The ledger counted 202 flakes
  over 166 tests in 22 days, and 36 flaky-test tasks have been planned one at a time as the 3-flake rule fires. Merges
  take a median 17.0 min this week against the 10 the project set itself. Nothing says when this work goes ahead of
  features.
- **Cost:** small. One scorecard task, and one prompt line. `LeadWorkflow.swift` is on sensitive_paths, so that part
  is audited.
- **After a week:** the scorecard shows both figures with their n. If the budget was spent, the board shows the
  ledger's top entries and at least one "names no test" diagnosis planned. The passed-only-on-rerun share in
  `merges-*.jsonl` (vibeswitcher rows, `result` = passed_on_rerun) falling under 10% would show an effect. Still over
  15% after two weeks means the policy is being skipped, or the whole-command failures need a diagnosis of their own
  first.

### 2. Tidy first, as its own small task

- **From:** *Tidy First?* (separate structure changes from behaviour changes), *Refactoring* (preparatory refactoring),
  *Working Effectively with Legacy Code* (sprout class). The same idea appeared as "prefactoring first" in
  `mattpocock-skills.md` (idea 3), which wasn't among the ideas chosen on 2026-11-09 but wasn't dropped either.
- **Change:** a planning step in the lead's brief (`LeadPrompts.lead`, where contracts are written). When a task's
  change would be easier after restructuring, such as moving a tool family out of `LeadToolset.swift` or extracting a
  function, the lead plans that restructuring as its own task first: no behaviour change, tests unchanged and green.
  The behaviour task runs `after` it. `LeadToolset.swift` then shrinks one family at a time (merge, audit, starts,
  records, remote, usage), each the first time a task needs it, never as one big split that would conflict with
  everything in flight.
- **Problem and evidence:** tasks with over an hour of work needed a second audit round 59% of the time, against 18%
  for tasks under 30 min, and had an Important finding 64% of the time, against 5–10% (decision 2026-11-12 10:33,
  `speed-review-2026-11-12.md`). The speed review's re-check found extra audit rounds to be the largest in-flight
  cost with a lever: two-round tasks took a median 208 min from start to merge, against 89 for one round. On 2026-11-12 a batch of 6 lost 2 tasks to conflicts in `LeadToolset` and the merge
  path (decision 2026-11-12 16:27). `LeadToolset.swift` is in 211 commits since 2026-10-18. It is now on sensitive_paths,
  so every task that touches any of its 321 functions is audited, whatever the change.
- **Cost:** small. One brief paragraph, then tidy tasks of under 30 min each. Tidying tasks that touch `LeadToolset.swift`
  are audited while it stays sensitive. Moving the non-guard tool families into files off the list would need the
  user's review floor (decision 2026-11-07 20:08), so that is the user's call.
- **After a week:** at least one tidy task planned ahead of a behaviour task, merged in one round, and the behaviour
  task's audit rounds compared with the 1.4 baseline. `LeadToolset.swift`'s line count goes down.

### 3. The git guard fails closed on git it can't see

- **From:** *Secure by Design* (reject input you can't fully understand; prefer allowlists), *Building Secure and
  Reliable Systems* (least privilege; design for understandability), and this project's own rule that hardening fails
  closed (decision 2026-10-25 16:33 (a)).
- **Change:** in `Sources/VibeCore/RefusedGit.swift`, `refusal(in:)` answers `.unreadable` (deny) when a line hands
  text that names git, case-folded, to another interpreter (`sh`/`bash`/`zsh -c`, `eval`, `env -S`, `source`, `.`,
  `watch`, `xargs sh`), or when a git's option or command word comes from an expansion (`git $x`, `git ${…}`). Those
  are the spellings its header lists as "not seen here, and so open". worker-git-guard-part's boundaries kept
  `sh -c` and `eval` out of scope on 2026-11-17, and no decision records why they should stay open. Everything else
  stays as it is. A decision
  records that a new spelling found later is refused the same way, not hunted case by case.
- **Problem and evidence:** two spelling tasks on 2026-11-17 (worker-git-guard-the and worker-git-guard-part), each
  sent back with Important findings (process substitution, nesting limits, `find -exec`, case folding) before passing.
  An earlier guard task (the-git-guard-treats, 2026-11-08, trailer commands) passed clean. The 2026-11-17 Code Mode trial's worker ran `git --git-dir=…`
  unasked. A denylist over a shell language keeps losing to the next spelling. A worker refused this way can run the same
  git plainly, so refusing costs a rewrite, not a capability.
- **Cost:** small to medium. One task, audited for security. The risk is refusing a worker's harmless `sh -c '… git
  status'`; the refusal says to run git plainly.
- **After a week:** no new guard-spelling task planned (the baseline is two in one evening), and no worker blocked by
  the new refusal for a harmless command, judged from their reports to the lead.

### 4. Split Sandbox.swift by what's sensitive

- **From:** *A Philosophy of Software Design* (information hiding: keep each decision in one module), *Your Code as
  a Crime Scene* (hotspots), *Clean Architecture* (separate policy from detail).
- **Change:** keep what makes the sandbox safe (its own home, defaults and session host, fake sessions only, off
  screen) in one small file that stays on sensitive_paths. Move the fixtures, the control channel's probe commands,
  the shots and the soak code into files that aren't sensitive. A lint test makes sure the moved files start no
  process, write no file outside the sandbox's home, and reach no real session, which is what decision 2026-11-07 19:48
  says probes must not do. This revisits those decisions' premise that the whole file stays sensitive.
- **Problem and evidence:** 36 audits were started only because a branch touched `Sources/VibeSwitcher/Sandbox.swift`
  (5 since 2026-11-11). Sandbox probes are a recurring setback: five tasks edited it outside their boundaries
  (decision 2026-10-30 15:08), and two came back "suspect" with no Important finding (decision 2026-11-07 19:48), each
  costing a second round. It is the file most named in overlap warnings (11 of them), with 4,608 lines and 126
  commits since 2026-10-18.
- **Cost:** medium. One audited task of about an hour. Taking the moved files off sensitive_paths lowers the review
  floor, so it is the user's click in Settings (decision 2026-11-07 20:08).
- **After a week:** progress lines starting an audit only for Sandbox.swift go from 5 in a week to 0. UI tasks that
  add a probe merge as small tasks.

### 5. The memory benches run by themselves on a calm Mac

- **From:** *Building Evolutionary Architectures* (fitness functions, run continuously), *Release It!* (steady state).
- **Change:** a deterministic job, not an agent (decision 2026-10-26 11:01 (c)), run once a day by the app, as the
  load recorder is: when the Mac is on AC, awake and calm, it runs `scripts/test.sh --perf --filter
  'FootprintBenchTests|SandboxSoakBenchTests'` under `vs-heavy` on main's latest build and appends the result to
  `~/.vibeswitcher/stats/`. The app-health line (`AppHealth.swift`) reports a failing budget with the commit range since
  the last pass.
- **Problem and evidence:** the app's memory growing has needed 9 tasks since 2026-10-17, the latest on 2026-11-18
  (262 → 713 MB overnight, after two fixes on 2026-11-17). The budgets exist (under 150 MB with the window closed, at
  most 10% growth over churn, flat over five simulated hours), but the benches run only with `--perf`, by hand. Each
  regression has been found in the field, a day later, by the app-health line or the user. The load report shows
  02:00–06:00 averaging a load of 2–3 when the Mac is awake. Whether the benches would have gone red on this week's
  build is unchecked; the first scheduled runs answer it, and if they stay green while the field grows, the bench's
  traffic needs widening before the schedule is worth keeping.
- **Cost:** small to medium. One task in the app plus a stats line. Benches leave the default run (decision
  2026-10-21 22:52 (3)), so this doesn't touch merges.
- **After a week:** results recorded on at least 4 of 7 days. Any growth shows in the stats before or with the
  app-health line, not after it.

### 6. Time to restore, and escapes, in the weekly scorecard

- **From:** *Accelerate* (change failure rate and time to restore, beside throughput).
- **Change:** `SetupScorecard.swift` adds (a) time to restore: minutes the pipeline was blocked by main red or the
  lead's records failing a check, from `LeadPipeline.swift`'s causes, which nothing counts today; and (b) the escape
  rate that Statistics already computes (`SetupStatsQuality.swift`: a merge later reverted, or one an incident names),
  moved beside the week's other figures. That is Accelerate's change failure rate. The retrospective's hand count of
  corrective follow-ups (decision 2026-11-09 14:20 (4)) stays as is, since it also catches defects that never got an
  incident or a revert. If it keeps finding many more than the escape count, the escape rule is too narrow, which is
  worth a decision of its own.
- **Problem and evidence:** on 2026-11-12 every merge was blocked for about 2 h 45 min (incident 2026-11-12 13:47), and
  main was red for about four hours the same day (`worker-rediscovery-2026-11.md`). Neither shows in any weekly
  figure. Escapes (about 4% in the backlog's header) sit on a separate Statistics page that the weekly review doesn't
  read.
- **Cost:** small to medium. One task, mostly in (a). The scorecard reads exact data only.
- **After a week:** both figures appear for this week and the last, with their n, and the next retrospective cites
  them.

### 7. Lead messages measured by whether they needed the user

- **From:** *Site Reliability Engineering* (every page actionable), *Making Work Visible* (unplanned work made
  visible).
- **Change:** the weekly scorecard counts the lead's messages to the user per day, split by the four allowed reasons
  of decision 2026-11-17 19:55 (the user must act, something asked for is finished, a real problem, the daily
  summary). It also gives the share the user acted on: answered, clicked or replied. It extends the scorecard's
  questions per delivered task (backlog A1, landed 2026-11-08) from questions to every message.
- **Problem and evidence:** the same rule had to be written twice (decisions 2026-10-25 22:48 and 2026-11-17 19:55).
  On 2026-11-17 about 14 messages went out and about 4 needed the user, and the user said they don't read 80%.
  lead-chat-noise-fold merged that evening, and its follow-up is running. A rule with no count tends to drift back.
- **Cost:** small. One scorecard task that reads the lead's tool calls by kind.
- **After a week:** at most about 4 messages a day, and at least half of them needing the user, against about 4 in 14 on
  2026-11-17.

### 8. Each retrospective checks whether an incident came back after its check merged

- **From:** *The Site Reliability Workbook* (postmortem action items verified, not just closed), Dekker (the new
  view: an error is a symptom of the system).
- **Change:** one line in the lead's retrospective step (`LeadPrompts.lead`). For each incident since the last
  retrospective whose check task merged, look for a recurrence in `incidents.md`, the flake list and the merge records.
  A recurrence becomes an incident of its own, naming the check that missed it.
- **Problem and evidence:** the merge flattening of 2026-11-07 19:46 came back at 22:19 the same day, after its fix
  had merged (incidents.md); the second time came from a stale installed gate (decision 2026-11-09 14:20 (5)), which
  no check on the fix itself could have caught. Hung test runs were recorded on 2026-11-06, 2026-11-08 03:34 and 2026-11-08 19:21, and the
  third was Mac sleep (decision 2026-11-08 20:36). The retrospectives count follow-ups (decision 2026-11-09 14:20 (4)),
  but not recurrences.
- **Cost:** tiny. A prompt line; `LeadWorkflow.swift` is sensitive, so it's audited.
- **After a week:** the next retrospective lists each recent incident with "recurred: yes or no".

### 9. One transition table for a task's states

- **From:** *Domain Modeling Made Functional* (make illegal states unrepresentable), *Domain-Driven Design*
  (aggregates guard their invariants).
- **Change:** `Sources/VibeCore/LeadBoard.swift` gets one function that says which status may follow which (for
  example, nothing leaves `kept` except the lead's own update, and nothing leaves `folded` or `abandoned`). The 14
  direct `status =` writes in 4 files go through it, and a test walks every pair.
- **Problem and evidence:** auto_advance merged a task the lead had set to kept (incident 2026-10-30 21:42), which was
  fixed case by case (`aTaskSetKeptDuringItsMergesTestRunStaysKept`). That's one incident, and the 2026-11-06 rule is
  incident first, then the check, so this item sits last. Do it when a task already has to change those writes, as a
  tidy-first step (item 2).
- **Cost:** small to medium. `LeadBoard.swift` and `LeadToolset.swift` are sensitive, so it's audited.
- **After a week:** the table's test is in, and any transition it refuses is logged. No refusal in a week means the
  table matches today's behaviour.

## The pain points, mapped

| Pain point | Covered by |
| --- | --- |
| Merges take 16–20 min | faster-test-suite (running); item 1 (the 10-minute objective keeps its gain). Sharding the run is not proposed: dropped 2026-11-12 |
| Flaky tests from Mac sleep | already handled at the source: awake-time limits (`MacTime.swift`, task test-waits-count-awake), `ElapsedTimeLint`, the flakes fixed on 2026-11-17 (decision 2026-11-17 17:02); item 1 gives the rest a budget |
| Notification noise in the lead chat | lead-chat-noise-fold (merged 2026-11-17) and its follow-up (running); item 7 measures whether it holds |
| Guard rails bypassed by shell spellings | item 3 |
| Memory growth | app-memory-grows-again (running) finds this week's cause; item 5 catches the next one before the field does |
| Hot files (LeadToolset, LeadAdvance) | items 2 (LeadToolset shrinks a family at a time) and 4 (the other hotspot, Sandbox.swift); LeadAdvance (1,288 lines) is sensitive by design and small enough to keep whole |
