Finished work lands without waiting for the lead

When a worker reports done, VibeSwitcher moves the task on by itself, without waiting for the lead's next turn. A review none task merges. An audit task gets its audit, and a clean audit merges. Open Important findings go straight back to the worker. Once its review passes, a merged task is cleaned up. As worker slots free up, planned tasks whose prerequisites are done start by themselves. The lead hears what happened afterwards in one report and keeps the judgement calls: holds, re-plans, questions to the user.

Acceptance checks:
- A review none task whose worker reports done on a branch head merges, with the full test command run, and is cleaned up, with no lead tool call in between. A test drives this with a fake worker and a fake test command.
- An audit task whose worker reports done gets its audit started by itself. A clean verdict merges it. A verdict with open Important findings messages the worker the open ids, and the task does not merge.
- A merge whose tests fail sends the output back to the worker, as merge does today. The task stays in progress.
- Nothing moves a task the lead holds: kept, blocked, failed, abandoned or folded. A workflow switch (auto_advance: false, set with configure) turns all of it off. The task's contract can opt it out with a per-task flag on add_task/update_task.
- add_task and update_task take `after` (task slugs). With auto_advance on, a planned task starts once every task in its `after` list is done. Tasks start in board order. They respect max_workers, the Mac-wide session limit, the load threshold and the battery hold, and start when room frees, with no polling loop.
- Each automatic step lands on the lead as a report (merged, audit started, findings sent back, started, refused and why). Reports are batched, so a run of merges reads as one message. Each step is also written to the progress log.
- Two workers that report done at the same moment both merge one after another, never at once (the merge queue/lock already serializes this; a test shows it). A tool-server restart mid-step (install) neither loses a step nor runs it twice.
- Affected tests pass while editing. The full `bash scripts/test.sh` passes once before reporting done, and the new tests pass under scripts/test-under-load.sh.

Boundaries:
- VibeCore lead machinery: LeadToolset.swift (start_worker/audit/merge/cleanup paths), LeadBoard.swift, LeadWorkflow.swift (new keys, the lead prompt's How-you-work text), LeadDelivery.swift / LeadWitness.swift (reports), vibeswitcher-mcp/main.swift, and their tests.
- Don't change what the merge gate checks (tests, vault-held done report, audit verdict, sensitive_paths approval). Automatic steps go through the same functions the tools use, never a shortcut around them.
- Don't change audit findings or rounds (task audit-v3 does), the retry or catch-up behaviour of merge (task steadier-merge-gate), the worker's done report or evidence (task evidence-packet), or the sandbox app run (task sandbox-app-run). Those run in parallel and touch neighbouring code. Merge project-lead in early and often.

Context:
Why: over 2026-10-22..25, 59% of task time was finished work waiting for the lead (often overnight), and only about 1.15 of 5 worker slots were used on average. The user approved 'Phases 1 and 2' of Lead Process v3 on 2026-10-25, merges overnight included (nothing reaches the user's app until they install). OpenAI's Symphony orchestrator and Anthropic's internal flow both move work through states without a human turn and keep the human for intent and final acceptance.

Where things are: tools are in Sources/VibeCore/LeadToolset.swift: report ~l.322, start_worker ~l.369, audit ~l.381, merge ~l.383, dispatch ~l.453. The merge gate is ~l.1446-1600. The audit ledger and the 'reconsider' cap are in LeadBoard.swift ~l.249. Workflow keys are in LeadWorkflow.swift ~l.292; the lead's prompt text is in LeadWorkflow.swift too. Reports reach the lead through LeadDelivery.swift/LeadWitness.swift. Mac limits come from MacLoad.swift plus the Settings file. The battery hold is in PowerSource.swift. The test lock is TestLock.swift. The lead's tool server (vibeswitcher-mcp) is the process that runs merges today, and an install swaps it in place.

Decide where the automatic loop lives (lead tool server, app, or host) and say why in your report. It must survive the lead session being idle and the tool server being swapped by an install.

House rules: never test input on real sessions (fake ttys and scratch only); never attach debuggers; use scratch HOME/defaults in tests (Scratch.defaults). The lead never pushes.

Sibling tasks running in parallel (slugs): steadier-merge-gate, workers-run-a-sandboxed, done-reports-carry, audit-v3-blocking.

Lead: accepted as within scope: LeadAdvance.swift (new), MCPServer.swift background()/switch gate, LeadVaultGuarded.swift (auto_advance guarded key), the one-line LeadController power nudge, RoomWaits.Wait.auto, the README paragraph and the FakeRuntime lock. Also accepted: a planned task with an empty `after` starts as soon as there's room, flake-fix tasks included; the lead holds a task with blocked. The verifier should focus on concurrency and the guard rails: no step may bypass the gate's checks; no double merge or double start across two loops or an install; holds are respected; the grant/vault rules are unchanged.
