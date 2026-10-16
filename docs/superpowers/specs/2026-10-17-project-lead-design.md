# Project lead

The user: "per project, a single agent that knows all the context of the project and all the sessions … to
orchestrate much longer-horizon tasks; only asking the direct questions, showing results often but hiding
the grunt work … it makes most decisions, consulting subagents so others execute them … giving me the
opportunity to give feedback without stopping the process … and managing the repository so it's not a mess."

Decisions (2026-10-17): the lead merges reviewed work to main itself; workers are Claude, Codex when useful
(a different model verifies); the project's board lives in the repo, git-ignored (`.vibeswitcher/`); build
order: Steer → MCP server → lead and its UI → repository hygiene.

## Background

- Claude Code agent teams (experimental): lead + teammates + task list + mailbox + `TaskCompleted` /
  `TeammateIdle` hooks; teammates don't survive resume, die with the lead, one team per session, no nesting.
  Good for a burst, not for a lead that lasts weeks.
- Cross-session messaging (built in): `ListAgents` / `SendMessage` between your sessions on this machine,
  delivered between tool calls without interrupting; `notify_when_idle` for a one-time "done" notice.
- Hooks: `PostToolUse` / `Stop` can add context mid-turn (`hookSpecificOutput.additionalContext`), and `Stop`
  can keep the turn going (`decision: "block"`).
- Practice: one worktree, one branch, one owner per task; coordinator + specialists + verifier (≈1 per 3–4
  builders); plan before code; hooks block "done" until checks pass; specs with acceptance criteria.

## Lessons from the reading (and what they change)

- **Anthropic, effective harnesses for long-running agents**: memory lives in files, not in a context: a feature
  list in JSON where agents may only flip `passes`, a progress log, `init.sh`, a commit per step; every session
  starts with the same ritual (where am I, log, list, run init + a smoke test) and ends clean. → The board is a
  task list in JSON with acceptance checks; workers follow a start/end ritual; `init.sh` per project.
- **LongHorizon-Harness (Manage–Execute–Audit)**: the manager keeps the state outside execution and changes it
  only from facts an auditor verified; executors run a bounded contract (goal, acceptance criteria, boundaries,
  prior evidence) in a fresh context; a read-only auditor in another fresh context checks the environment, not
  the executor's report. → A worker's "done" is a claim; the board changes only on a verifier's evidence; the
  lead reads contracts and audits, not raw worker transcripts.
- **Gas Town (Maggie Appleton; paddo.dev)**: the Mayor never codes; workers are disposable, identities and work
  persist (in git); a Witness watches health, a Refinery owns the merge queue; operational roles beat persona
  pipelines. Failures seen: big token burn, failing tests auto-merged, force pushes, deleted code; design and
  human attention are the bottleneck; start simple. → The lead never codes; VibeSwitcher is the Witness (stalls,
  loops, waiting sessions are reported to the lead); merging is a queue that tests the rebased branch and never
  merges red; force pushes and history rewrites are blocked.
- **OpenAI Symphony**: the board is the control plane; one workspace per task; a WORKFLOW.md in the repo holds
  config and the prompt template; reconciliation every tick, stall detection and restart, retries with backoff;
  work ends at a human-review state; people manage 3–5 sessions comfortably. → `.vibeswitcher/workflow.md`
  holds the lead's playbook and limits, editable per repo; at most 3 workers at once by default; stalled
  workers are restarted from their contract.
- **OpenAI, harness engineering**: engineers design the environment (docs as the system of record, plans in the
  repo, mechanical checks), human attention is the scarce resource. → The lead keeps docs and plans current and
  turns repeated mistakes into checks (tests, lint, guard rules), not prose.
- **AgentRadio**: messages that surface at the next step without the agent stopping to listen beat blocking
  receives (51.6% → 62.1%), at much higher token cost. → The lead never blocks waiting on workers: events and
  your feedback arrive as steered messages at its next tool call.
- **Eleven harnesses (source study)**: stay single-agent until parallel work clearly beats serial (multi-agent
  ≈15× the tokens); skills for capability templates, MCP for external systems; safety rules as data; cheap
  caps for stuck agents. → Parallel workers only for independent tasks; worker roles as skills; guard rules in
  a data file; per-worker time and retry caps; token use shown per team.
- **Codex subagents**: custom agents in TOML, concurrency capped, permissions inherited; parallelize reads,
  be careful with parallel writes. → Codex workers get the same contract; writes only ever in their own worktree.
- **Claude Code agent teams / cross-session messaging**: as in Background. **Parallel-agent tools (Conductor,
  Claude Squad, Superset, Emdash)**: worktree per agent is universal; surviving restarts is a differentiator
  (VibeSwitcher's host already does).

Revised shape: **lead** (manager; never codes; disposable session, the board is its memory, so a fresh lead can
take over) → **workers** (fresh context per contract, own worktree, start/end ritual) → **verifier** (read-only,
fresh context, other model when possible; complete / incomplete / blocked + clean / suspect / violation) →
**merge queue** (rebase, test, merge only green and clean) — with **VibeSwitcher as the witness** (pushes
"done", "stuck", "needs input" into the lead) and **you** steering anyone without stopping them.

## 1. Steer (any session)

Feedback that reaches a working agent at its next tool call, without stopping it.
- Composer: while the agent works, ↩ **steers** (button shows "Steer"); ⌥↩ queues the message for after the
  turn (today's Send). Idle: ↩ sends as usual.
- Claude sessions: the message goes to `~/.vibeswitcher/steer/<tty>.jsonl` (private folder), tagged with
  the agent's pid and who it's from (`you` or `lead`). The hook takes pending messages for that agent pid on
  `PostToolUse` (returned as `additionalContext`), `UserPromptSubmit` (added to the prompt) and `Stop`
  (`decision: "block"`, so the turn continues and acts on it), and logs delivered ids to
  `<tty>.delivered`. Wording: "Message from the user, sent while you were working: …". From the lead:
  "Message from your project lead (another agent, not the user): …" — never presented as the user.
- Codex sessions: typed into the session (Codex treats input during a turn as steering).
- Chat: a steered message shows as a bubble marked "steering…" then "delivered" (or "queued").

## 2. VibeSwitcher MCP server (`vibeswitcher-mcp`, stdio)

Talks to the running app over a private socket. Tools, scoped to the lead's project:
- `sessions` — every session of the project: id, agent, status, task, branch/worktree, last activity.
- `read_session(id, since?)` — the conversation condensed (prompts, replies, tool summaries, failures).
- `start_worker(task, brief, agent?, model?)` — a window session in a new worktree on `agent/<slug>`, started
  with the brief; shows nested under the lead.
- `message(id, text, steer?)` — to a worker (steer: at its next tool call).
- No blocking wait: VibeSwitcher tells the lead (as a steered message) when a worker finishes, needs input,
  stalls or loops; `status()` answers "what's going on" on demand.
- `audit(worker)` — starts the read-only verifier on the worker's branch with its contract; its report
  (completion + integrity, evidence) is what may change the board.
- `ask_user(question, options?)` — non-blocking: a card in the lead's chat (and a notification); the answer
  comes back to the lead as a steered message.
- `post_update(title, body, images?, diff?)` — a result card in the project feed.
- `board_read` / `board_update` — the board: `.vibeswitcher/board.json` (tasks with contract, acceptance
  checks, status, owner, branch, evidence = audit report), `progress.md` (log), `decisions.md`,
  `workflow.md` (playbook and limits: max workers, caps, test command, init command).
- `merge(worker)` / `cleanup(worker)` — merge a reviewed branch into main (fast-forward or rebase, tests
  first), then remove its worktree and branch.

## 3. The lead and its UI

- "New Project Lead" per project: a window session with the lead preset (`claude` with the lead playbook as
  appended system prompt, the MCP server, its own skills); pinned at the top of the project; one per project.
- Playbook (from `workflow.md`): decompose into tasks with contracts (goal, acceptance checks, boundaries,
  prior evidence); parallel workers only for independent tasks, at most 3 at once by default; one worker per
  task in its own worktree; a fresh-context verifier per finished task (different model when Codex wrote it);
  the board changes only on verifier evidence; merge in order through the queue, then post an update; ask
  the user only for direction, product choices and risky actions, via `ask_user`; keep the board, progress
  log and decisions current; turn repeated failures into checks; never code itself.
- The lead's session is disposable: everything it needs is on the board, so a fresh lead can take over (e.g.
  when its context fills) without losing the thread.
- UI: workers nested under the lead in the sidebar; in the lead's chat, question cards (answer → steer) and
  result cards; inspector **Board** tab: tasks by state, owner session, branch, verifier result.

## 4. Repository hygiene

- Worktrees in `<repo>/.vibeswitcher/worktrees/<slug>` (git-ignored); branches `agent/<slug>`.
- Guard hook for workers (PreToolUse): deny commits on main, force pushes, `git reset --hard` outside the
  worktree, deleting branches it doesn't own.
- After merge: worktree and branch removed; scratch files stay out of the repo (`.vibeswitcher/scratch`).
- `.vibeswitcher/` is added to `.git/info/exclude` (not `.gitignore`), so nothing in the repo changes.

## Testing

Pure parts in VibeCore with unit tests (inbox take/deliver, hook replies, playbook rendering, board ops,
worktree commands as plans). End-to-end on scratch repositories and scratch sessions only.
