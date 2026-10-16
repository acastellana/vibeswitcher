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
- `wait(ids, timeout)` — returns when one of them goes idle / needs input / ends.
- `ask_user(question, options?)` — non-blocking: a card in the lead's chat (and a notification); the answer
  comes back to the lead as a steered message.
- `post_update(title, body, images?, diff?)` — a result card in the project feed.
- `board_read` / `board_update` — the board (`.vibeswitcher/board.json` + `decisions.md`).
- `merge(worker)` / `cleanup(worker)` — merge a reviewed branch into main (fast-forward or rebase, tests
  first), then remove its worktree and branch.

## 3. The lead and its UI

- "New Project Lead" per project: a window session with the lead preset (`claude` with the lead playbook as
  appended system prompt, the MCP server, its own skills); pinned at the top of the project; one per project.
- Playbook: decompose into tasks with acceptance criteria; one worker per task in its own worktree; a
  fresh-context verifier per finished task (different model when Codex wrote it); merge in order after the
  verifier passes, then post an update; ask the user only for direction, product choices and risky actions,
  via `ask_user`; keep the board and decisions current; never do worker-sized work itself.
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
