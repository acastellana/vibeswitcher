Every task gets a receipt: time, tokens, cost, rounds, rollback

Each task that ends (merged, folded or abandoned) has a compact receipt on the board. It holds: the worker's working time and wall time from start to end; tokens (input, output, cache read/write) per role (worker, verifier) read from their session transcripts, and an estimated cost; audit rounds, re-rolls and merge reruns; the merge's test count; the user's questions and minutes waited; and the commits it brought (the rollback point). board(task) shows it. status's scorecard and the all-done card show the batch's totals and the most expensive task. This lets the lead compare models and see which kinds of task cost the most.

Acceptance checks:
- Focused tests: a receipt is built from a fixture board task plus fixture transcripts (JSONL with usage fields like Claude Code writes). Tokens are summed per role, and a session resumed or compacted mid-task is counted once, not twice. The receipt is stored on the task when it ends and shows in board(task).
- Cost is labelled as an estimate. It comes from a per-model price table in one place, with the date the prices were taken. An unknown model shows tokens with 'cost unknown', not a wrong number.
- status's scorecard line and the all-done card show the batch's totals (tasks, worker hours, tokens, estimated cost) and the most expensive task by name. Sandbox screenshot of the all-done card with it.
- A task merged before this change has no receipt and shows nothing, not zeros.
- Done report: a receipt for one real finished task in this repo, computed read-only from its kept transcripts if they're still there. Say which if not.

Boundaries:
- LeadBoard.swift (the task record), LeadToolset.swift (board/status text), a new LeadReceipt.swift, the scorecard and all-done card views, and tests. Merge project-lead in before reporting done: a-verifier-that-ends may touch LeadToolset at the same time.
- Read transcripts only from the task's own worker and verifier sessions, never the user's or other leads' messages. Store numbers only, no transcript text.
- Don't touch Sources/vibeswitcher-mcp/ or MCPServer.swift (task open-sessions-pick-up).

Context:
The board already keeps a per-task score (rounds, questions, waitingOnUser, mergedUnaudited) and the merge commit. each-task-has-a (merged at 8ddafec) added the worker's counted working time (worked, in LeadBudget.swift). read_session already finds a task's worker and verifier sessions and their transcripts. For current model prices use the claude-api skill or Anthropic's pricing page. Workers run on opus, verifiers on fable 5.1. The idea: a "change receipt" per run, so that model changes are comparable and costs are attributable.
