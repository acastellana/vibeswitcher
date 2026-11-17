# Design: a team of workers on one task, with a shared post wall

Written by a worker (task design-a-team-of) on 2026-11-13, for the lead and the user to decide from. No product code
was changed. "Board" already means the lead's task board in VibeSwitcher (`.vibeswitcher/board.json`, the lead's
`board` tool, the board a verifier judges against). So this document calls the shared message board a team's
**wall**, and its messages **posts**.

## In short

Run 2 to 4 workers on **one** task. Each worker has its own worktree on its own sub-branch. One of them, the
**integrator**, owns the task's branch and takes the others' parts into it. Teammates write short posts to the team's
wall, and VibeSwitcher delivers each post once to the members it names, by the same path the main-red notice uses.
The task keeps one contract, one audit and one merge. Verifiers never see the wall. The design reuses the per-task
worktree, the delivery path, the lead-mail marking and limits, and the record lints. What's new is the team task's
members, two worker tools (`post`, `wall`), one integrator tool (`take_part`) and a peer-wait timer. The first
experiment builds the same backlog item (B2, sandbox UI journeys) both ways. The team way is adopted only if it gets
to merge-ready at least 25% sooner, on no more than 1.5× the tokens and with no more Important audit findings, on 2 of
2 runs.

This is a different question from the one decided on 2026-11-13 ("No shared notes board between workers for now",
[decisions](../../lead/decisions.md)). That measurement ([worker rediscovery](worker-rediscovery-2026-11.md)) covered
tips between workers on **independent** tasks and put them at 3.0% of worker time. A team's posts carry something
else: an interface found mid-task, a "don't touch X, I'm changing it", a half-done part another member waits on. The
30-minute rule (decision 2026-11-12 10:33) stays for independent work. A team task is the exception the lead uses when
a change is too big for 30 minutes and its parts share files or an interface.

## 1. What others do

No third-party sources were used. Every claim below comes from the vendor's own docs.

**Antigravity `/swarm`** ([docs/swarm](https://antigravity.google/docs/swarm), "Preview"; introduced in App v2.31.0 on
November 9, 2026, [changelog](https://antigravity.google/docs/changelog))

- **Split.** "your current conversation becomes the swarm's **coordinator**". It "divides the work into pieces that
  don't collide (for example, one worker per file or per package)", adds one named worker per piece and "doesn't do
  the technical work itself". It "usually adds a `@verifier` for every two to four workers", plus a `@monitor`. Each
  worker "starts with a clean context in its own conversation".
- **Workspace.** "Workers share your workspace by default". For overlapping edits, "the coordinator can give each one
  its own working copy of your repository". Deleting a worker deletes its copy, so "the coordinator has the worker
  land its changes first".
- **Board.** The swarm coordinates "on one shared message board", with `@name`, `@group` and `@all` mentions.
  "Workers don't message each other privately, so the whole team conversation stays in one place, in order." The
  user doesn't post on it: the coordinator "posts the instructions to the right workers on the board". A direct
  message to one worker "goes to that worker only, not to the board".
- **Idle cost.** "A worker that has nothing to do, or a coordinator waiting for reports, goes to sleep on the board
  without using tokens", "until a post mentions it". But "a swarm uses quota much faster than a single conversation".
  A member that runs out of quota pauses until a new post, a model switch or a message wakes it.
- **Limits.** No maximum number of workers and no file locks are stated: collisions are avoided by how the work is
  split. "Removing a worker is permanent." It is limited to the Google AI Pro and Ultra plans.
- **Not read.** The CLI part of the changelog, and the unread part of the changelog page. A later swarm change there
  can't be ruled out.

**Claude Code agent teams** ([agent-teams](https://code.claude.com/docs/en/agent-teams); experimental, behind
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`; the version that introduced them wasn't found in the part of the
[changelog](https://code.claude.com/docs/en/changelog) that was read)

- **Split.** "One session acts as the team lead, coordinating work, assigning tasks, and synthesizing results."
  Teammates share a task list. The lead assigns tasks, or a teammate self-claims "the next unassigned, unblocked
  task". Tasks can depend on other tasks, and "task claiming uses file locking to prevent race conditions".
- **Mailbox.** Each agent has an inbox file. "Any teammate can message any other by that name." There is no broadcast:
  "to reach everyone, send one message per recipient". Messages "are delivered automatically to recipients". A message
  from another agent is treated as another Claude session's, not the user's, and can't grant consent.
- **Cost.** "Each teammate has its own context window." "Token usage scales with the number of active teammates and
  how long each one runs", and "each active teammate continues consuming tokens until it exits"
  ([costs](https://code.claude.com/docs/en/costs#agent-team-token-costs)). In plan mode, teams use "approximately 7x
  more tokens than standard sessions" ([costs](https://code.claude.com/docs/en/costs#manage-agent-team-costs)). The
  docs don't say whether a waiting teammate costs anything. They advise "Start with 3-5 teammates" and "Shut down
  teammates when their work is done".
- **Limits.** "Two teammates editing the same file leads to overwrites. Break the work so each teammate owns a
  different set of files." Teams also can't be nested, a session holds one team, the lead is fixed, and `/resume`
  doesn't restore in-process teammates. "Teammates sometimes fail to mark tasks as completed, which blocks dependent
  tasks." Each teammate starts in the lead's permission mode.

**What carries over.** Both split the work so pieces don't collide, and both give each piece a fresh context.
Antigravity makes waiting free. Claude Code's docs don't say what a waiting teammate costs. Both treat a peer's words as not the user's. Neither runs an independent audit of the
whole: Antigravity's `@verifier` is a member that reads the board. Neither gives each worker an isolated checkout by
default. VibeSwitcher keeps both of those, the audit and the isolated checkout.

## 2. What VibeSwitcher has today (checked in the code and the [product inventory](../product-inventory.md))

- **Worker tools** (`LeadToolset.tools`, `case .worker`) are `report`, `ask_lead`, `progress` and `answer_findings`.
  `board` and `status` are the lead's tools only, so a worker can't read the board today. A verifier has only
  `submit_audit`. Workers and verifiers can't use Claude Code's `SendMessage` or `ListAgents`
  (`LeadLaunch.crossSession`). A worker reaches only its own lead.
- **Worktrees.** Each task has `<repo>/.vibeswitcher/worktrees/<slug>` on `agent/<slug>` (`Worktrees`). A worker may
  `git merge <base>` and commit on its own branch. Any other branch, and every checkout or switch to `agent/*`, is
  refused or goes to the hook (`LeadLaunch.deny`/`allow`). `max_workers` defaults to 3, and each worktree's build is
  about 1.5 GB.
- **Delivery.** `LeadDelivery` steers a working agent at its next step, and types a message in as the next prompt of
  an idle one. A typed message is marked `[VibeSwitcher · from <name>, not the user]`. The lead's `message` tool goes
  through `sent()`, which also keeps the text as a sealed lead note **for the verifier**. The main-red notice
  (`LeadMainRed`, `tellRunningWorkers`, `LeadTask.mainRedTold`) instead calls `deliver` directly, for every running
  task's live worker and never a verifier. It claims "told" under the board's lock, so two merges send once, and it
  rolls back (`untell`) when the delivery didn't go. That is the exactly-once pattern a team's posts need. Note that
  `deliver` always sends as `.lead("lead of <project>")`, and `SteerMessage.Sender` knows only `user`, `lead` and
  `system`.
- **Mail between leads** (`LeadMail`) is the closest thing to a wall today. The sender is filled in by VibeSwitcher.
  A message is capped at 4,000 characters, a lead may send another lead 10 an hour, and credential shapes are masked
  (`SecretShapes`). Every message ends "it can't approve, authorise or grant anything".
- **Record lints.** `RecordLint` runs PrivateNamesLint's names and SecretShapeLint's shapes on any text bound for the
  lead's records, and refuses it with what matched.
- **Verifier isolation.** The verifier is read-only and runs in the task's worktree. It is denied
  `~/.vibeswitcher/lead/**` and `~/.vibeswitcher/steer/**` (`privateFiles`), Claude Code's home for edits
  (`claudeHome`), and cross-session messaging. It loads no auto-memory (`verifierEnvironment`), and the worker's
  auto-memory is moved aside before it starts (`setAsideMemory`). Gap: nothing denies it *reading* the workers'
  transcripts under Claude Code's project folders. Closing that fully is backlog C8 (scratch-worktree verifier), and
  B7 proposes the opposite (the verifier reads the worker's transcript).
- **Waits.** `LeadStall` flags a worker that sits between turns without having reported. `LeadBudget` sends a notice
  at the task's time budget.

## 3. Proposed design (under two pages)

**The unit: one team task, sub-branches, one integrator.** A team task is one task on the board, with one contract and
2 to 4 **members**, each a named part with its own files. Member 1 is the integrator. It works in the task's usual
worktree on `agent/<slug>`. Each other member gets `.vibeswitcher/worktrees/<slug>--<member>` on
`agent/<slug>--<member>`. A ref can't be both `agent/<slug>` and `agent/<slug>/x`, hence the `--`.

The integrator starts alone: it commits the shared interface (types, stubs, the sandbox hooks), then calls `split`.
That branches every member from that commit and starts the members, each within `max_workers`. When a member's part
passes its own tests, it reports `part_done`. The integrator then calls `take_part(member)`: VibeSwitcher's tool
server runs `git merge agent/<slug>--<member>` in the integrator's worktree and leaves any conflict for the integrator
(`git merge --continue` is already allowed). Workers' shell rules don't change.

Why not one shared branch? Git can't check one branch out in two worktrees. Sharing one worktree would mean one
`.build` that concurrent builds clobber, one index lock, and one member's half-written file breaking the others'
tests. Per-member worktrees keep the isolation the policy requires, and Claude Code's own docs warn that two agents
editing one file overwrite each other.

**Integration, then one audit and one merge.** Only the integrator's `report(done)` counts for the task. It needs
every part taken, the task's acceptance checks run on the integrated branch, the blind check run on the whole
`git diff main...HEAD`, and the usual tests under load. The audit and the merge then run unchanged on `agent/<slug>`:
the verifier sees one branch and one contract. Main's red and green notices, and "main moved and touched your files",
go to every live member: the `tellRunningWorkers` loop iterates over members, with one `mainRedTold` per member. When
main conflicts, the integrator merges main in, and members merge the team branch in (the `catchUp` text, naming the
team branch). After the merge, cleanup removes the members' worktrees and sub-branches with the task's.

**The wall: who posts, who reads, how a post arrives.**

- **Who posts.** Members post with `post(text, to: [@member…] | @all, needs_answer?, reply_to?)`. The lead may also post. Its
  post is marked as the lead's, but it is still not a contract change: those stay `update_task` and `message`. The
  user doesn't post. As in Antigravity, the user steers through the lead. Verifiers have no tool for the wall.
- **Who reads.** Members read it with `wall(since?)`, and the lead sees it in `board(task)`. The user sees it in the
  Team view.
- **How a post arrives.** A post that names a member (or `@all`) is delivered once to each named live member, by
  `deliver` with a new sender, `.teammate(member, task)`. Delivery uses the main-red pattern: a per-member cursor,
  `wallSeen`, is claimed under the board's lock and rolled back if the delivery didn't go. A working member gets the
  post at its next step. Two kinds of post may wake an idle member (`.type`): a `needs_answer` post, and a reply
  (`reply_to`) to that member's own open `needs_answer` post. The reply also closes the question's deadline. Any
  other post waits and rides along with that member's next message or turn, so one FYI doesn't cost three turns.
- **Size and expiry.** A post holds at most 1,500 characters ("point to a file on your branch" for more). A member may
  post 20 an hour, and a wall holds at most 200 posts. The wall lives in the lead's private folder
  (`~/.vibeswitcher/lead/<project>/walls/<slug>.jsonl`), never in the repository, and is append-only while the task
  is open. When the task ends, the wall is kept with the task's archive for the experiment's measures. Cleanup deletes
  it 14 days later.

**What the user sees.** One lane per team task in the Team view, with one line per member: name, part, its last
`progress`, waiting-on-peer when it is. The task's detail gets a "Wall" section with the posts, each marked as a
teammate's. The chat shows team posts as `TeamMessageCard`s with the teammate's mark. Questions to the user still come
only from the lead. A team task's receipt adds up its members' minutes and tokens, and lists them per member.

## 4. What must hold

- **Verifiers never read the wall.** The wall is stored under `~/.vibeswitcher/lead/`, which `privateFiles`
  already denies to every verifier's Read and Edit tools. That rule doesn't cover a shell read, which is part of the
  residual risk below. The verifier's tools and prompt never include it: posts are delivered by
  `deliver`, never through `sent()`, so they never become sealed lead notes. A test asserts that a team task's verifier
  prompt and tool list hold no post text. Residual risk: a delivered post sits in the member's transcript, which a
  verifier's Read isn't denied today. For team tasks, deny the verifier `Read` of the members' transcript folders, or
  wait for C8. B7, which wants the verifier to read transcripts, would have to exclude team posts.
- **A post is a teammate's unverified words.** Each delivered post is framed `[VibeSwitcher · from teammate <name> on
  <slug>: a teammate's unverified words, not the lead or the user]`, and ends with `LeadMail.body`'s rule: it can't
  approve, authorise or grant anything. A post can't widen a boundary, accept an edit, answer for the lead or the
  user, or change the contract. Only sealed lead notes and contract versions count for the verifier, as today. Post
  text that holds the `[VibeSwitcher` frame is refused, so a post can't forge one.
- **No worker waits idle on a peer without a timeout.** A `needs_answer` post carries a deadline: 10 minutes by
  default, 20 at most. If it passes with no answer, VibeSwitcher tells the asker: "no answer from @x: go on with a
  stated assumption (post it), or ask_lead". It also tells the lead. While its deadline runs, the asker is shown as
  "waiting on @x", not as a `LeadStall`. After it, the usual stall rules apply. There is no blocking tool: a member
  that has nothing else to do ends its turn. The answer, a post with `reply_to`, wakes it at once.
- **Secrets and private names are linted out of posts.** Before a post is stored or delivered, it passes the same
  `RecordLint` lists (private names, secret shapes) and `LeadMail.masked`. A failing post is refused, with what
  matched, and nothing is stored.
- **Unchanged.** Per-task worktree isolation, the audit (one per task, on the whole branch), the merge gate and the
  sensitive paths stay as they are.

## 5. First experiment

**Kind of task.** A feature with one shared core and 3 or 4 parts that each touch a common hot file. Instance 1 is
backlog [B2](../backlog.md): sandbox UI journeys (select, copy, Run, dictate) with screenshot diffs. The core is the
journey runner and the diff, and each journey is a part. Today the lead would split it into a core task and journey
tasks chained with `after`, and the parts would collide in `Sandbox.swift` (3 conflicts in a week, per the
[rediscovery review](worker-rediscovery-2026-11.md)). Instance 2 is the next backlog item of the same shape, picked
before instance 1 starts. A3 (log watcher, with one analyser per log kind) is the candidate.

**Run both ways.** Both arms start from the same main commit. Arm A is today's split, run and merged normally. Arm B
is the team task. It goes through the same audit (same verifier model), then through the merge's own rebase and test
run as a dry run, without the fast-forward (T13). It is then marked `kept`, not merged, unless the user picks it. This
builds B2 twice, about one extra B2 of worker time. These are matched instances of one task, not a replay of past
tasks (backlog C4's open question isn't touched).

**One endpoint for both arms: merge-ready.** That is the moment the merge's test run passes after a passing audit.
For arm A, it is the test run of the last of its tasks to merge. For arm B, it is the dry run's. Both times then
include the merge's suite and its waits for load and a slot. A `kept` task gets no receipt today: `update_task` clears
it, and `LeadReceipt.Ending` is only merged, folded or abandoned. T13 gives a kept experiment arm a receipt with a
`kept` ending, so both arms' measures come from the same place.

**Measures, and where each is recorded** (arm B's receipt via T13).

- Wall-clock from the first task's start to merge-ready. Source: `LeadReceipt.startedAt`, the merge or dry run's
  test-run end, and the audit and test waits (`LeadWaits`).
- Worker-minutes, summed over members. Source: `LeadReceipt.worked`.
- Tokens: workers, verifiers and the lead. Source: `LeadReceipt.worker`/`verifier`, and the lead's day in
  `lead-tokens.json` (`LeadTokenLedger`).
- Audit findings by severity, and audit rounds. Source: the board's audits and `LeadReceipt.rounds`.
- Conflicts: merge conflicts for A, and `take_part` conflicts for B. Source: `scripts/worker-rediscovery.py`'s
  conflict category, with B's counted from the integrator's transcript.
- Also: peak worktrees held, and posts per member.

**Result.** Decided in advance, as the 5% bar was.

- **Adopt** (build the rest of the UI, and let the lead choose team tasks) if, on **both** instances, B reaches
  merge-ready at least 25% sooner than A, with tokens at most 1.5× A's and no more Important findings than A.
- **Drop** if B is not at least 10% faster on either instance, or has more Important findings on either.
- **Run 2 more instances** for anything in between.

Two pairs is a small sample (backlog B8): the bar is set high so that only a large effect counts.

## 6. Build tasks the experiment needs

Each takes under about 30 minutes. **Hot** means it touches `LeadToolset`, `LeadAdvance` or the merge path.
`LeadToolset` is a sensitive path (always audited), and tasks sharing it chain with `after`. New logic goes in new
files, `LeadTeam.swift` and `LeadWall.swift`, so the hot edits stay thin.

| # | Task | Files | Hot | After |
|---|---|---|:-:|---|
| T1 | Wall store: append-only JSONL in the lead's private folder; size, count and rate caps; `RecordLint` and masking on write; per-member `wallSeen`; unit tests | new `LeadWall.swift` | no | none |
| T2 | `.teammate` sender, its frame and refusing a forged frame | `Steer.swift`, `LeadDelivery.swift` | no | none |
| T3 | Team task model: `members` (name, part, worker, branch, worktree, `wallSeen`, `mainRedTold`) on `LeadTask`, Codable with old boards | `LeadBoard.swift` (sensitive), new `LeadTeam.swift` | no | none |
| T4 | Member worktrees on `agent/<slug>--<m>`; cleanup removes them with the task's | `Worktrees` (merge path) | **yes** | T3 |
| T5 | `split` and member start: brief per member (its part, the integrator's name, the wall rules) | `LeadToolset` start path, `LeadWorkflow` brief | **yes** | T3, T4 |
| T6 | Worker tools `post` and `wall`, delivery to named members once (the main-red pattern), wake only for `needs_answer` and for a reply to the member's own open question | `LeadToolset` tools/call, `LeadWall.swift` | **yes** | T1, T2, T5 |
| T7 | `take_part` (the integrator's tool), and `part_done`: a member's done that starts no audit | `LeadToolset`, `LeadAdvance` | **yes** | T6 |
| T8 | Main-red, green and catch-up notices to every member | `LeadToolset` (`tellRunningWorkers`) | **yes** | T7 |
| T9 | Peer-wait deadline: the notice to the asker and the lead; `LeadStall` skips a member within its deadline | `LeadWitness`/`LeadStall`, `LeadWall.swift` | no | T6 |
| T10 | Verifier exclusion: a test that a team task's verifier prompt and tools hold no post text; deny the verifier `Read` of the members' transcript folders | `LeadLaunch` (sensitive), tests | no | T3 |
| T11 | Receipt per team: members' minutes and tokens summed and listed; walls kept 14 days | `LeadReceipt.swift` | no | T3 |
| T12 | Minimal UI: member lines in the team task's lane, and a Wall section in the detail; a `team wall` sandbox command | `TeamViews.swift`, `Sandbox.swift` | no | T6 |
| T13 | Experiment arm's end: `merge(dry_run)` runs the rebase and the test command on a scratch ref without the fast-forward, and records when it passed; a `kept` task keeps a receipt with a `kept` ending instead of having it cleared | merge path, `LeadToolset` (`update_task`), `LeadReceipt.swift` | **yes** | T8 |

T1, T2 and T3 can run side by side. T4 to T8 and T13 form one chain through the hot files, about 3 hours of serial work.
T9 to T12 can run beside that chain once their inputs merge. The fuller UI (filters, a user-facing wall view) waits
for "adopt".

## Open questions for the user

- Is building B2 twice (about one extra B2 of worker time) acceptable for a clean comparison? The alternative is
  matching two different tasks of the same kind, which is cheaper but noisier.
- Verifier and transcripts: should team tasks deny the verifier `Read` of the members' transcripts (T10)? This
  conflicts with B7's idea that the verifier reads the worker's transcript.
