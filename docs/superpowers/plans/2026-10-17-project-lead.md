# Project Lead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-project lead (a Claude session that plans and never codes) that runs workers in their own
worktrees, has a read-only verifier check each, merges what passes, asks the user only what it must, and keeps a
board in the repo (git-ignored) — with VibeSwitcher as its runtime and witness.

**Architecture:** Pure parts in VibeCore (board, workflow + prompts, launch command lines, worktree git plans,
MCP JSON-RPC dispatch, session digest, a one-shot host client). A new executable, `vibeswitcher-mcp` (stdio MCP
server), implements the lead's tools on top of them, talking to the session host and git directly. The app adds
"New Project Lead", nests workers under their lead, a Board inspector tab, question cards that answer the lead,
and the witness (worker events steered into the lead).

**Spec:** docs/superpowers/specs/2026-10-17-project-lead-design.md (Steer: done).

## Global Constraints

- Everything the lead keeps lives in `<repo>/.vibeswitcher/` (excluded through `.git/info/exclude`).
- Workers: `agent/<slug>` branches in `<repo>/.vibeswitcher/worktrees/<slug>`; never on main; deny rules for
  force push, hard reset, branch deletion, switching to main.
- The lead denies itself Edit/Write/NotebookEdit and `git commit` (it never codes).
- Merge only fast-forward, only after the verifier's verdict is complete+clean and the test command passes on the
  rebased branch.
- At most `max_workers` (default 3) workers at once.
- End-to-end checks only on a scratch repository and scratch sessions.

## Review Focus

1. A merge when the user's main checkout has uncommitted changes or is on another branch: refuse, never clobber.
2. Two tool calls racing on the board (lead + verifier): writes are locked and atomic.
3. Slugs from arbitrary task titles: safe as branch and folder names, unique.
4. A worker's session ending or the app quitting mid-task: the board still says where things are.
5. The verifier changing files: its integrity verdict says so and nothing merges.

---

### Task 1: Board (VibeCore `LeadBoard.swift`)
`LeadBoard` (tasks, questions, updates, lead info) with `LeadTask` (id, slug, title, contract {goal, acceptance,
boundaries, context}, status planned|running|review|done|failed|blocked, worker host id, branch, worktree,
evidence {completion complete|incomplete|blocked, integrity clean|suspect|violation, summary, at}), `LeadQuestion`
(id, text, options, answer?), `LeadUpdate`. `BoardStore(root:)`: load / update(closure) under a lock with atomic
write; `appendProgress`, `appendDecision`; `ensureExcluded()` adds `.vibeswitcher/` to `.git/info/exclude`.
`Slug.make(title, taken:)`. Tests: round trip, locked concurrent updates, slugs, exclude idempotent.

### Task 2: Workflow and prompts (`LeadWorkflow.swift`)
`workflow.md` front matter (max_workers, test_command, init_command, worker_agent, verifier_model) with defaults
and a template; `LeadPrompts.lead/worker/verifier(…)` and `WorkerBrief.render(task)`. Tests: parsing, defaults,
rendering includes contract, rules and tool names.

### Task 3: Launch command lines (`LeadLaunch.swift`)
Files under `.vibeswitcher/run/`: MCP config (the `vibeswitcher-mcp` binary with role, root, task), settings
(permissions deny lists per role), prompts. `LeadLaunch.command(role:…)` → `claude --append-system-prompt … 
--mcp-config … --settings … [initial prompt]`, shell-quoted. Tests.

### Task 4: Worktrees (`Worktrees.swift`)
`Worktrees.create(root, slug)`, `rebaseAndTest(…)`, `merge(…)` (ff-only; refuses a dirty main checkout or main
checked out elsewhere mismatch), `remove(…)`; runs `git` via Process. Tests on a temp repo.

### Task 5: MCP dispatch (`MCPServer.swift`)
JSON-RPC 2.0 over newline-delimited stdio: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`,
`ping`; tool definitions with JSON schemas; errors as tool results with `isError`. Tests with a fake toolset.

### Task 6: Session digest and host calls (`SessionDigest.swift`, `HostCall.swift`)
`SessionDigest.text(ChatLog, limit:)` — prompts, replies, tool summaries, failures, newest last, bounded.
`HostCall.request(_:)` one-shot (hello → request → reply by seq, timeout). Tests for digest.

### Task 7: `vibeswitcher-mcp` executable
Tools: `status`, `sessions`, `read_session`, `start_worker`, `message`, `audit`, `submit_audit` (verifier),
`ask_user`, `post_update`, `board`, `update_task`, `record_decision`, `merge`, `cleanup`. Bundled in the app.

### Task 8: App
"New Project Lead…" (project header menu, palette, start page); lead row marked and pinned; workers nested under
it (worktree paths map to the project); inspector **Board** tab (tasks, questions with answer → steer to the lead,
updates); witness: worker done / needs input / stalled → steered into the lead; lead's questions as cards in its
chat.

### Task 9: End to end, README, review
Scratch repo; lead plans two small tasks, workers implement, verifier audits, merge; README; fresh review; fixes.
