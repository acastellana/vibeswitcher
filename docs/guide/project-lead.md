# The project lead

A project lead is one Claude Code session per git repository that you talk to about the project. It plans the work,
runs a team of coding agents to do it (Claude sessions, or Codex for bounded tasks), checks what they did and merges
what passes. You decide what to build;
it handles the rest and asks you only what's yours to decide.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/lead-dark.png">
  <img alt="A lead's chat: the team strip, notes from workers and an all-done card" src="../images/lead-light.png">
</picture>

## Starting a lead

- In the window: the start page's **Choose Folder…**, ⌘N with nothing selected, ⌘K, or the ⊕ menu's Project Lead.
  Picking a folder in a git repository starts its lead, or shows the one already running. A folder that isn't a
  repository offers to make one; a repository with no commits offers to make a first commit.
- **New Project…** makes a new repository and can start its lead with a first goal.
- From a shell: `VibeSwitcher --lead FOLDER [--goal "…"]` starts the lead of the repository holding FOLDER, or sends
  the running lead the goal.

A new lead first reads its status, the project's `workflow.md` notes, `decisions.md` and the end of `progress.md`.
With a goal, it plans tasks, starts workers and tells you its plan; without one, it greets you in a line.

The lead's branch (its base) is the one checked out when it first starts in the repository; `base_branch:` in
`workflow.md` changes it. Workers start from it and their work is merged into it. The lead has no way to push by
itself: see [The remote](#the-remote).

## How a lead plans: the task contract

The lead turns what you ask for into tasks on its board. Each task has a contract:

- **goal**: what should be true when it's done;
- **acceptance**: the checks, focused tests or things to look at that show it works;
- **boundaries**: the files and areas the worker may change;
- **context**: what the worker needs to know.

A task can also have a review level (below), an `after` list (tasks that must be done first), its own time budget
(`budget_min`), a `model` for its worker (as `claude --model` takes it: `sonnet` for a mechanical task; left out, the
worker runs on the project's Claude command's model, as before; given, it replaces a `--model` that command names) and `auto_advance: false` to keep it out of automatic
moves. The lead changes a task with
`update_task`. A task's state (`LeadBoard.swift`) is planned, running, review (reported done, being checked), done
(merged), failed, blocked, kept, folded, abandoned or reverted. A task made by
mistake that never ran can be removed.

## Workers

The lead starts each task's **worker**: a Claude session in its own git worktree,
`.vibeswitcher/worktrees/<task>`, on the branch `agent/<task>`. At most `max_workers` (3 by default) run at once in a
project. The worker gets the contract and the user's working policy, runs `init_command` (if set) first, and:

- owns the change through completion, making the routine calls itself and listing them in its report;
- asks the lead (`ask_lead`) only about direction, scope or anything risky;
- notes milestones with `progress` (shown on its task's line in the Team tab);
- runs the tests its change affects; the merge runs the full suite;
- reports `done` with evidence for each acceptance check, `blocked`, or `over_budget`.

**Time budget.** A task's budget is `task_budget_min` (120 minutes by default; 0 means none) unless it sets its own.
Only the worker's working time counts: not waiting on a prompt, the lead, you or a test slot, and not audits. When it's
reached, the worker is told to commit what works and report `over_budget` with what works, what's missing and a
proposal. Nothing is stopped; the lead extends the budget, re-plans or abandons the task.

Workers can't push, move refs, rebase other branches, or check out the lead's branch: Claude Code's permission rules
deny it. A worker brings its branch up to date by merging the base in.

### Codex workers

A task can name its worker's agent: `add_task` or `update_task` with `agent: codex` (`claude` is the default; `auto`
chooses at each start, see [Auto routing](#auto-routing-agent-auto)). It's
meant for bounded, mechanical tasks with a tight contract, to spread usage onto the Codex account when Claude's limits
run low; near a Claude limit, start_worker's refusal and auto_advance's hold suggest it, and the lead decides. Codex
only implements: the lead, verifiers and the risk check stay Claude.

A Codex worker is the project's Codex command (its Codex launch preset) started in the task's worktree with:

- the same brief as a Claude worker's (as Codex's `developer_instructions`), plus a part on its sandbox and the rules
  below;
- the VibeSwitcher tool server as its one MCP server, its tools pre-approved (under approval never Codex refuses an MCP
  call that needs approval), scoped to the repository, the task and the worker role, so
  `progress`, `report`, `ask_lead` and `answer_findings` work as for any worker, and auto_advance moves its work on the
  same way. `--no-daemon` keeps that server under the session's own process, which is how the session host tells which
  session asks;
- `--sandbox workspace-write` with network off and `--ask-for-approval never` (no one answers approvals; a refused
  command just fails). It writes only in its worktree, its TMPDIR and /tmp, and the git folders its commits need: its
  worktree's own git folder, the object store and the `agent/` branches' refs. Never `main`'s ref, tags, the git config
  or another checkout; no push or fetch;
- the worktree trusted for that session only (nothing is written to `~/.codex`). Flags in the Codex command that
  would loosen that (`--yolo`, `--dangerously-bypass-approvals-and-sandbox`, `--full-auto`, `-s`, `-a`, `-C`,
  `--add-dir`, `-p`) are dropped; a task's `model` replaces its `-m`.

Its checks run as a Claude worker's do, as the brief writes them, with no flags of their own: `bash scripts/test.sh
--filter X`, the lint filter and `scripts/test-under-load.sh`. Inside Codex's sandbox (its commands have
`CODEX_SANDBOX` set) the scripts leave SwiftPM's own sandbox out (`--disable-sandbox`: macOS refuses a sandbox-exec
inside Codex's seatbelt, and SwiftPM compiles the manifest under one); a new worktree takes the main checkout's SwiftPM
dependencies (`.build/repositories`, `checkouts`, cloned), there being no network to fetch them; and the scripts list
processes through libproc, since `/bin/ps` is setuid and macOS starts no setuid program in any sandbox, so no launch
setting could let it through (`scripts/lib/processes.sh`). On 2026-11-02 the first Codex task's `scripts/test.sh`
failed before compiling, and the lead had to hand its worker `--disable-sandbox`. Still out of a Codex worker's reach:

- tests that open a Unix socket, which its sandbox refuses with the network off: every test that starts a scratch
  session host (the VibeHostTests target, and app tests such as LeadStartsHostTests) and so the full suite. Its focused suites and the
  lints run; the audit and the merge's full run cover the rest, so a task about the session host stays Claude's;
- `scripts/sandbox-app.sh` (the UI check in the real app): a UI task stays Claude's;
- a change to the package's dependencies (`Package.resolved`): fetching them needs the network;
- vs-heavy's view of its CPU use: vs-heavy reads that with `ps`, which can't start there, so a waiter may see the
  Codex run as idle. Nothing acts on it. (Its core count falls back to `getconf` where the `sysctl` command fails.)

The on-demand `CodexRealRunTests/theProjectsChecksRunInARealCodexWorkersSandbox` runs these checks in a real Codex
worker's sandbox.

A Codex task is always audited by a Claude verifier: its review is audit and can't be lowered while its worker is
Codex, or once a Codex worker worked on it; merge refuses it without a passing audit whatever the board or the vault
says. Status and board say `worker: Codex` on it (and `worker: Claude` on the other open tasks beside it), and the
Mac-wide session limit counts it like any worker.

What Codex can't be made to refuse (it has no per-session deny rules: its `.rules` files load only from its own home,
the project's `.codex` folder or managed requirements, and its sandbox draws no line inside the worktree), and what
checks it instead:

| Claude worker's rule | Instead, for Codex |
| --- | --- |
| The refused git commands that stay on its own branch or another `agent/` one (amend, reset --hard, checkout or branch -D of another task's branch) | The sandbox holds the ones that write elsewhere (`main`, tags, config, the remote); the Claude audit's integrity check reads the branch's history |
| No edits to the records folder (`docs/lead`) | Merge takes the base's copy of the lead's records whatever the branch did to them; the audit reads the rest of the diff |
| No reads of `~/.vibeswitcher/lead` and `~/.vibeswitcher/steer` | Its brief; the session host tells callers apart by their process, never by what they've read |
| (none: Codex's own) | Your Codex rules (`~/.codex/rules`) stay in force: a command prefix you approved there runs outside the sandbox. The TUI loads them whatever a session says (only `codex exec --ignore-rules` skips them), so keep them narrow; the audit reads what the branch did |
| pkill, killall and debuggers refused by rule | Its brief; a sandboxed command signals only its own processes |

Review a Codex worker's output critically: it's the audit's job, and the start_worker reply says so.

A Codex worker starts through the session host as a Claude worker does: its TUI draws, its tools connect, it calls
progress and report, and between turns it takes a message (the lead's, a verifier's findings that auto_advance sends
back, what waited in its inbox) typed in as its next prompt. Its hooks (VibeSwitcher's Codex hooks, in your Codex home)
tell when its turn is over, and its composer is read as Claude's box is (`LeadDelivery.codexBox`). The on-demand
`CodexWorkerHostRunTests` runs a real one through all of that. Until 2026-11-01 none of it did (task
codex-s-tui-renders): every hosted session started on a 0×0 terminal, where Codex 0.160's TUI draws only blank frames;
the worktree's trust key never applied, so Codex sat on its trust prompt and started no MCP server; and its composer
wasn't recognised. Should a Codex release break it again, `VIBESWITCHER_CODEX_WORKERS=0` in the lead's tool server's
environment switches Codex workers off: start_worker refuses a codex task, auto_advance starts none (it tells the lead
once), and the usage watch doesn't suggest Codex.

### Auto routing: agent auto

`agent: auto` (on `add_task` or `update_task`, or for every new task that names no agent with `configure
agent_default: auto`) lets each start pick the agent from both accounts' usage. `start_worker` and auto_advance decide
at the start, not when the task is planned:

- **Codex** when Claude is *tight* and Codex *has room*. Claude is tight when one of its current limits on the
  worker's model (or on every model) is at 70% or more, or a weekly limit is more than 10 points ahead of pace. Pace
  is the used % against the % of the window gone, from its reset time: 64% used with 52% of the week gone is 12
  points ahead. Codex has room when each of its known limits is under 85%, or under 100% with credits available, and
  Codex doesn't say a limit is reached.
- **Claude** otherwise, and whenever either side's usage isn't known. Unknown is never room.

So where Claude's 80% hold would refuse or hold an auto task, it starts on Codex while Codex has room. A task pinned to
`claude` holds as before. A start that lands on Codex is a Codex task from then on (`codexWorked`): a Claude verifier
audits it before merge whatever its review says. Its `model` is Claude's, so a start on Codex runs Codex's own. The
start's reply and its progress line say where it went and why, e.g. `auto → Codex: Claude weekly 64%, 12 points ahead
of pace; Codex 40%`. Status shows Claude's limits and Codex's, each with its pace, and `Next auto task → codex|claude
(why)`. Board says `worker: auto (now Codex)` while it runs.

Codex's usage comes from its own session files: the newest `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`
(`~/.codex` by default), the last `rate_limits` of a `token_count` event in its last 256 KB (`CodexUsage.swift`).
That means the account's windows (`primary`, `secondary`: used %, length, reset) and its credits. Other limits in
there (one model's, `premium`) are passed over. It's read only, kept for 30 s, and read again only when the file
changes. A reading whose windows have all reset, a malformed one, or none at all is unknown. The thresholds are
constants in one place, `UsageRouting`.

Only workers are routed: the lead, planning, the risk check and verifiers stay on Claude whatever the quota. Mark
bounded, mechanical tasks auto. Pin design-heavy or security work to `claude`.

## Review levels and audits

Each task has a review level:

- **none** (the default): the merge takes the worker's done report on the branch's head, and the merge's own test run
  is the check.
- **audit**: a read-only **verifier** checks the work against the contract with real commands and tries to break it.
  Only work it passes merges. The lead picks this for security, irreversible operations or complex changes.

Some tasks are audited whatever their level says:

- a branch that touches `sensitive_paths` (by default `.claude/`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`,
  `AGENTS.md`, `.github/`, `.env`, `.env.*`, `*.entitlements`, `*.pem`);
- a review-none task the **risk check** raises: its diff (`LeadRisk.swift`) is over `risk_lines` (400) lines outside
  tests, benches and fixtures; or its code deletes or rewrites files or data, changes permissions, spawns processes or
  adds locks or threads; or it changes the test or build setup or `REVIEW.md`, or takes tests out. Then, unless
  `risk_model` is off, a small Claude model sees the diff's stat and the contract and may raise it too. Either can only
  raise, and an error leaves the result as it was;
- a random **sample** of the review-none tasks left, `audit_sample_percent` of them (10 by default), drawn once per
  task.

The Team tab shows such a task as **Needs audit**, with why. `REVIEW.md` at the repository's root is your few lines on
what matters in this code; the verifier and the risk check read it from the base branch, so a worker can't change its
own audit by editing it.

A verifier runs on a different model from the task's worker when `verifier_model` is empty (the default).

**Findings.** A verdict comes with findings, each at a file and line with its evidence, and a severity:

- **Important** blocks the merge until it's fixed or dismissed;
- **Nit** never blocks and never becomes a task by itself;
- **Pre-existing** never fails the task.

The lead resolves each Important finding: the worker fixes it and a re-audit checks only those findings; or
`dismiss_finding` closes it with a reason; or it becomes a task of its own.

**The round cap.** After 2 audit rounds that failed or left Important findings open, the task's status says
"reconsider the approach". The lead doesn't send it back for a third round. It re-plans it, asks you, or **re-rolls**
it: the worker stops, its branch is kept as `archive/<task>-<n>`, and a fresh worker starts from the base with a
summary of the findings and answers so far.

**Several finders.** With `audit_finders: 2` or `3`, an audit runs that many verifiers, each with its own focus
(contract and acceptance; bugs and regressions; security or the tests). The audit builds and tests the commit once and
hands every finder the logs. Findings most finders raised stay open; the rest show as **unconfirmed** and don't block
unless `strict_paths` holds them (below).
New Nits past `audit_nit_cap` (5) are left out and counted. Each finder counts against the Mac-wide session limit.

**Strict paths.** `strict_paths` (globs, comma-separated, e.g. `src/signing/**, src/hardware/**`; set with
`configure`; empty by default) makes every Important finding count on a branch that touches one: an unconfirmed one
holds `merge` and auto_advance as an open one does, and goes back to the worker with the open ones. It holds until the
lead dismisses it (`dismiss_finding`), makes it a task (`add_task(from_finding:)`), or a re-audit closes it, judging the
worker's answer. The merge refusal, the audit's report, `status` and `board(task)` name each held finding and say
`strict_paths` holds it. A branch that touches no strict path is as before.

**The review rules floor.** Settings › Project lead › Review rules floor sets, per project, the least strict its rules
may be: sensitive and strict paths, audit finders, merge policy, risk lines, the risk check's model pass, the audit
sample, and whether the verifier must run on a different model. It's kept in the session host's vault, written only by
the app. A lead can make a rule stricter with `configure`, never looser: for paths both lists count, for the rest the
stricter value does.

A verifier ends itself 20 seconds after it submits its verdict. The app ends every worker and verifier session of a
task that merged, was folded, abandoned or cleaned up.

## The merge gate

`merge` takes exactly the commit the verifier passed (or, for review none, the commit the worker reported done on),
then:

1. rebases it onto the lead's branch in a worktree no agent works in (squashed into one commit if the worker merged
   the base in);
2. runs `init_command`, then `test_command`, then `regression_command` if set, each within `test_timeout_min` (45
   minutes), and stops one as hung sooner when it makes no progress for `stall_min` (10 minutes: no new output, under
   1 % of a core, while the Mac's load is under `load_threshold`), naming the last test it started;
3. fast-forwards the lead's branch to exactly what was tested. Never a merge commit, never a force.

It refuses while an Important finding is open, while the task is **kept** (held back with a reason, such as "don't
merge until I've looked"), when the lead's branch was moved by something other than its own merges, when the
`workflow.md` guard rails differ from what the lead last set, or while [the agents' config is held](#the-config-seal).

If the lead's branch moved, a card in the lead's chat lists the commits, with **Accept These Commits** (merges start
from there, with the lead and its team running on) and **Keep Refused**.

Merges wait while the Mac's load is above `load_threshold`. `merge_batching: boost` (only while Boost is on) or `always` tests several passed
tasks with one run: each is stacked on the base, and a run that fails is split to find the one that breaks it. Each task's
merge is still recorded on its own, so revert undoes just that one.

A merge is run by the installed app's tool server, so a change to the gate's own code on the base doesn't apply until
it's installed. `status` says when the base has such commits the running build lacks. `merge_remote` and the merge of a
branch carrying the remote refuse then, until you install from the base (`scripts/build-app.sh --install`).

**Flaky tests.** When tests fail, the failing tests run once more (up to 20 named tests, else the whole command), at
most once per merge, and never after a build error or a `regression_command` failure. If they pass, the merge goes
ahead and each is recorded as a flake, with its evidence in a file. A test that flakes 3 times within 7 days becomes a
task to fix it, once.

**Merge policy** (`merge_policy:` in `workflow.md`), chosen once per project, within the floor above:

- `auto`: work merges once its review passes; the lead then posts what changed, how it was checked and how to revert it.
- `ask_sensitive`: a commit touching `sensitive_paths` waits for you.
- `ask_all`: every merge waits.

Until you choose, the lead asks you once and merges are handled as `ask_sensitive`. A merge that waits needs your
answer "Approve <commit>", which approves that exact commit only. A timer never counts as an approval.

Other endings: **folded** (another task carries its work), **abandoned** (dropped, with a reason), **failed** (tried and
didn't pass). Folded and abandoned tasks don't count as failed.

## The config seal

Workers, verifiers and a branch's tests run as you, so a shell in any of them could write what your next session loads.
No sandbox can hold them: macOS refuses a sandbox inside a sandbox, and many test suites start one. So the session
host's vault keeps a hash of each of these, as last sealed (`ConfigSeal.swift`):

- Claude Code's settings, hooks, skills, commands, agents, output styles and instructions in `~/.claude`, and the MCP
  servers in `~/.claude.json`;
- Codex's config, hooks, rules and instructions, your shell's startup files, your git config, and the VibeSwitcher
  hook binary;
- the main checkout's git config and hooks, its `.claude` settings, `CLAUDE.local.md` and `.mcp.json`;
- each enabled plugin's manifest, hooks and servers, and the scripts your settings name by path.

Each is hashed again before a worker or verifier starts and after a merge's tests. A change made while the team ran
holds new workers, verifiers and merges for that team, and the lead is told. Code that runs (hooks, MCP servers, shell
startup, git's commands, a plugin's update) holds whoever changed it. A change made while the team was quiet to
something that only instructs (`CLAUDE.md`, agents, output styles), or by hand to a plugin's files or a script your
settings name, is taken as yours and sealed.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/config-held-dark.png">
  <img alt="A card in the lead's chat naming the agents' config that changed while the team ran, with an Accept button" src="../images/config-held-light.png">
</picture>

A card in the lead's chat names each thing held, what changed in it and when. **I Changed Them: Accept** seals them, and
only your click in the app can. If you didn't make the change, look at the files and set them back first. The lead's
own start is never held, and running sessions keep the hooks they started with. It's a detector, not a lock: what a
shell wrote is on disk, but no worker or verifier VibeSwitcher starts loads it unseen.

## Provenance

The top commit of each merge on the base ends with git trailers (`LeadProvenance.swift`), so the history says where it
came from and it goes wherever the commit goes. A branch of several commits lands as several; only the top one has them.

| Trailer | What it says |
| --- | --- |
| `VS-Task` | The task's slug. |
| `VS-Review` | `none`, or `audit (pass at <commit>)` with any findings the lead dismissed. |
| `VS-Worker-Model`, `VS-Verifier-Model` | The models that worked on and audited it. |
| `VS-Build` | The commit of the tool server that merged it. |
| `VS-Contract` | A hash of the task's contract, as its worker got it. |

Only slugs, model names, verdict words and hashes go in: no email, path or newline. In a batch each task's commit has its
own, and a merge carrying the remote keeps them. `scripts/merge-provenance.sh [-n N] [--build PREFIX] [--model TEXT]`
lists them from `git log` alone.

## The remote

The lead's deny rules refuse `git fetch` and `git push`. It syncs through three fixed-shape tools, whose remote, URL and
branch come from `workflow.md`, never from the call:

- `fetch_remote` fetches the base branch only, into its remote-tracking ref, and says how far ahead and behind it is;
- `merge_remote` merges that into the base in a scratch worktree, runs the tests, and fast-forwards the base; a conflict
  outside the lead's records stops it, with the files named;
- `push_remote` asks you. A card lists the commits, with **Push N Commits** and **Decline**. Only your click pushes, from
  the app's own process: exactly that commit, as a fast-forward, never forced. The lead hears the outcome either way.

## auto_advance

With `auto_advance: true` (the default), finished work moves on without waiting for the lead's next turn. The lead's
tool server:

- merges a review-none task reported done (unless the risk check raises it to audit);
- starts an audit task's audit, and merges a clean verdict;
- sends the worker a verdict's open Important findings, once per verdict, never past the round cap;
- retries once a verifier that ended without a verdict;
- sends the worker a failed merge's output;
- cleans up what merged;
- starts a planned task once every task in its `after` list is done, within `max_workers`, the Mac-wide limits and the
  battery hold.

Each step goes through the lead's own tools and checks, lands in the progress log and reaches the lead in one report.
It never moves a task the lead holds: kept, blocked, failed, folded or abandoned. `configure(auto_advance: false)` turns
it off for the project; a task's own `auto_advance: false` opts it out.

## Mac-wide limits

These are set once for the Mac, not per project, in Settings › Performance, and kept in
`~/.vibeswitcher/mac-limits.json`:

- **Team sessions** (`mac_max_sessions`): the most workers and verifiers of all projects together, 10 by default.
- **Load** (`load_threshold`): the load above which leads start nothing, the greater of the 1- and 5-minute averages
  (so a dip of the 1-minute after a spike isn't room); empty means twice the cores.
- **Test and build slots** (`heavySlots` in the file): the builds and full test runs at once, below. The cores ÷ 6,
  rounded down, by default (2 on a 12-core Mac, the user's choice on 2026-11-01).

The session host counts the live workers and verifiers of every project (the **census**), so every lead sees the same
total. `start_worker` and `audit` refuse at either limit, and the lead gets one message once there's room again. A
project's `workflow.md` lines for these two are ignored.

**Heavy work.** Full test suites, release builds, merges and audits' test runs take a slot from `vs-heavy`, shared by
every project on the Mac. How many is one count, read the same way by `vs-heavy` and by the leads' merges and audits:
`VIBESWITCHER_HEAVY_SLOTS` (a project's `heavy_slots` in workflow.md gives its sessions that), else the Settings value
above (2 on a 12-core Mac); while Boost mode is on, raised to boost's (3), never lowered. A run that finds every slot
held waits, naming who holds each. A slot assumes a job of about the cores ÷
the slots, so each slot's command gets `VS_HEAVY_CORES`, its share of the cores (the cores ÷ the slots, rounded up, at
least 2), and caps its own parallelism to it: `node --test --test-concurrency=$VS_HEAVY_CORES`, `make -j $VS_HEAVY_CORES`,
and for SwiftPM `swift build -j 2 -Xswiftc -j$(( (VS_HEAVY_CORES + 1) / 2 ))` (see [Development](development.md)). The
working policy's `vs-heavy` line tells every role so. Uncapped, a `node --test` run on ~9 cores and a Swift build beside
it held the Mac at load 62 inside the lock (2026-11-01).

**Boost.** Settings › Performance › Boost is Off, On or Automatic (`Boost.swift`, `BoostWatch.swift`). While on, the
Mac-wide limits are raised to the boost values, each editable: `load_threshold` 36, `mac_max_sessions` 18,
`max_workers` 7 per project (a project's own when higher), test and build slots 3 (from Settings' 2 on a 12-core Mac,
so `VS_HEAVY_CORES` goes from 6 to 4; for `vs-heavy` and the leads' merges and audits alike); projects whose `merge_batching` is `boost` batch their merges. Automatic boosts only while the Mac is on AC power and
you're away (screen locked or no input for 5 minutes, as the notifications judge it) and drops back within one 10-second
look when either changes: new starts stop above the normal limits and running work finishes. On battery it's off
whatever the mode, unless **Also on battery** is on (off by default): then On and Automatic work on battery as on AC
until the charge drops below 30 % (`Boost.batteryFloor`; a charge not known counts as below), and `status` says so:
`boost: on (on in Settings, on battery (allowed, 86%))`, `boost: off (on in Settings, on battery at 24%: boost on
battery stops below 30%)`. The away rule and the battery hold below still apply. The usage watch keeps it off at 70 % of an every-model account limit, and says so. The app keeps its decision
in `~/.vibeswitcher/boost.json` (rewritten at least every minute; older than 150 s reads as off, so a quit app leaves
the normal limits), and each lead's `status` says it: `boost: on (automatic: away, on AC): load_threshold 36, …`. While
boosted, room freed on the Mac goes first to the project you last worked in: the witness wakes its refused starts first,
and other projects' starts are held while the room left wouldn't fit it. An orange bolt shows in the toolbar and the menu bar
while boost is on; its tooltip says why, and the toolbar's opens Settings › Performance at Boost.

## The account's usage limits

Workers and verifiers spend the Claude account's usage, and a session that reaches a limit stops mid-task until it
resets. VibeSwitcher reads what Claude Code exposes (`AccountUsage.swift`), best effort:

- **The status line's input.** For a Claude.ai subscriber, after a session's first reply, Claude Code hands the status
  line `rate_limits`: `five_hour` and `seven_day`, each with `used_percentage` (0–100) and `resets_at` (epoch seconds),
  and `spend_limit` behind a gateway. These are the whole account's. The sessions VibeSwitcher starts (lead, workers,
  verifiers) get its status line. It runs your own status line with the same input and prints its output byte for byte
  first, then keeps the windows in `~/.vibeswitcher/account-usage.json`, so the line reads as yours, and nothing of
  VibeSwitcher's that fails stops it from showing. Your status line is found as Claude Code layers its settings: the
  project's `.claude/settings.local.json`, then its `.claude/settings.json`, then `~/.claude/settings.local.json`, then
  `~/.claude/settings.json`. A verifier looks only at your user settings, since it runs with `--setting-sources user`
  and the branch's project settings were written by a worker. Your own sessions are untouched. There's no per-model
  percentage there.
- **Transcripts** say nothing about usage until a request is refused. Then the API-error line carries `apiError`
  (`usage_limit_reached`, or `model_requires_usage_credits` when only that model is out, as Fable was on 2026-11-01),
  `rateLimitType` (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_overage_included`) and
  `resetsAt`. A refusal counts as that limit at 100 % until its reset, for the session's model alone when the type
  names a model or the model needs usage credits, else for every model.
- Claude Code also reads per-window use from the API's response headers and shows `/usage` on its own screen, but
  writes neither to a file. The OAuth usage endpoint would need the account's token from the Keychain, which
  VibeSwitcher doesn't touch.

At 80 % of a limit, `start_worker` and `audit` start nothing on the models that limit holds back (every model for the
weekly and 5-hour limits) unless the lead passes `override_usage: true`, or **Ignore usage limits** is on in
Settings › Performance (then Boost isn't held off for usage either, and `agent: auto` stays on Claude). Sessions already running carry on.
auto_advance skips those starts and audits and tells the lead once per limit, with the reset time. `status` shows each
known limit, how much is used, when it resets and its pace (see [Auto routing](#auto-routing-agent-auto)). What isn't known (an API key, no status line run yet, a reading past
its reset) means no back-off, never a stop.

## The battery hold

On battery, below a set charge, lead work pauses: `start_worker`, `audit`, `merge` and `revert` refuse, and work
already running finishes. The default is 50 %; Settings › Performance sets it from 10 to 90 %, or 0 for
never. The lead is told when the hold starts and ends.

**Keeping the Mac awake.** While a worker, verifier or merge runs, the Mac doesn't go to sleep on its own (the display
still does). "Keep the Mac awake while the team works" in Settings › Performance is On power only by default; Always or
Never change it.

## Questions to you

The lead asks with `ask_user`. Questions show as cards in its chat, in the Team tab and on your phone; answering one
doesn't stop the lead. For a reversible choice, it can propose an answer with a timer ("Going with SQLite in 8 min",
10 minutes by default): pick another option, or **Hold** to stop the timer. When it runs out, the lead goes ahead with
its proposal and records it as its decision. There's never a timer on a blocking question, deleting or discarding
work, a merge of a sensitive path, or anything outward-facing (publishing, pushing, deploying, sending).

You can message the lead any time; your message reaches it at its next step.

Leads of different projects can message each other with `tell_lead`. It's on by default; turn off **Let project leads
message each other** in Settings › Project lead to stop it. Every message, sent or refused, shows under **Between
leads** in the Team tab. A message can't approve or grant anything.

## The Team tab, the all-done card, receipts and revert

The inspector's **Team** tab is meant to be glanced at: the lead's open questions, its recent decisions, then each task
in one line with its state and how long it has been in it ("Working 12m", "Rework 1 · 22m", "Needs audit 2m"). Under a
task at work, a dim line says what its agent is doing, written by a small Claude model (`claude -p` with Haiku, no
tools) at most every 3 minutes while the tab is open; "Summarize what each agent is doing with AI" in Settings ›
Project lead turns it off. Click a task for its checkpoints, report, audit and links to its
sessions. Below are the scorecard, answered questions and the lead's files.

The **scorecard** has four numbers over the lead's merged tasks: audit rounds to pass, the share passing the first audit
(both shown once there are enough audited tasks), minutes waiting on you per task, and reverts. A footnote says how many
merged without tests or without an audit. The [Statistics window](everyday-use.md#statistics) has the same across every
project.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/all-done-dark.png">
  <img alt="The all-done card" src="../images/all-done-light.png">
</picture>

When the board goes from open work to none, with at least one merge since the last one, the lead's chat shows an
**all-done card**: a headline and bullets saying what landed, the batch's tasks, and its cost.

Each merged, folded or abandoned task keeps a **receipt**: working and wall time, tokens and estimated cost for worker
and verifier, audit rounds, re-rolls, merge reruns, tests, your questions and how long they waited, and the rollback
point. Numbers only, no transcript text.

**revert** undoes a merge with one new commit: it runs the tests and fast-forwards, like a merge. Nothing is reset or
rewritten. It refuses if the tests fail or later commits conflict.

## The board and its archive

The board is `.vibeswitcher/board.json` in the repository (git-ignored). Merged, folded, abandoned or reverted tasks
with no worktree left, finished more than 24 hours ago, move to `.vibeswitcher/board-archive.jsonl`, one line each.
Failed tasks stay. Only the lead's tool server moves them: when it starts, and at most once an hour after merges.

## The witness

VibeSwitcher watches the team and tells the lead when a worker waits for input, stops without reporting, or dies, and
when one has stalled:

- it reads as working but its transcript hasn't grown for 15 minutes;
- it's been between turns for 10 minutes without reporting or asking (45 minutes while it waits on a background task
  of its own);
- its transcript ends at a mid-turn compaction for 5 minutes;
- a message has waited in its inbox for 5 minutes.

Reports wake a lead that's between turns: VibeSwitcher types one short prompt into its empty box ("2 new reports …
Call status."), never into your draft or over a dialog. A finished task's session that sits idle for over an hour is
named once an hour as stranded.

## The records

The lead's reasoning lives in the repository, in `records_dir` (`docs/lead` by default): `decisions.md`,
`progress.md`, `incidents.md` and `decisions-archive.md`. The lead can't commit, so its tool server commits these files
to the lead's branch, after each merge and at most every 5 minutes, as "Lead: decisions and progress". Your staged and
unstaged changes are left alone. `archive_decisions` moves old entries to `decisions-archive.md` unchanged. Workers may
not edit that folder.

`workflow.md` (in `.vibeswitcher/`, git-ignored) holds the limits and commands below. The lead changes it with its
`configure` tool, which keeps your comments. The guard rails (the test and setup commands, `merge_policy`,
`sensitive_paths`, `strict_paths`, `records_dir`, `max_workers`, `heavy_slots`, `audit_finders`, `audit_nit_cap`, `auto_advance`,
`risk_lines`, `risk_model`, `audit_sample_percent`; `Sources/VibeCore/LeadVaultGuarded.swift`)
count only as the lead last set them: when the file says anything else, `merge` and `start_worker` refuse until the
lead sets them again.

## Your working policy

Every lead, worker and verifier gets your working policy in its prompt. It's one text for all projects, kept in
`~/.vibeswitcher/policy.md` and edited in Settings › Project lead. The default is five rules: one agent owns each
change, affected tests while editing and the full suite once before merging, parallel work with builds and tests
serialized, only material bugs fixed, stop when it works. Running leads are told once when you change it.

## Defaults and where they come from

Each value as the code sets it today. Paths are under `Sources/VibeCore/` unless they say otherwise.

| Setting or rule | Default | Source |
| --- | --- | --- |
| `max_workers` | 3 | `LeadWorkflow.swift` |
| `task_budget_min` | 120 min (0: no budget) | `LeadBudget.swift` |
| `test_timeout_min` | 45 min | `Worktrees.swift` |
| `stall_min` | 10 min (0: off; merges, audits and `vs-heavy --stall`) | `StallWatch.swift` |
| `audit_finders` | 1 (at most 3) | `LeadWorkflow.swift` |
| `audit_nit_cap` | 5 | `LeadWorkflow.swift` |
| `risk_lines` | 400 | `LeadRisk.swift` |
| `risk_model` | true (a model pass may also raise a task to audit) | `LeadWorkflow.swift` |
| `audit_sample_percent` | 10 (0: off; review none tasks audited anyway at random, the draw kept on the task) | `LeadAdvance.swift`, `LeadAuditSample.defaultPercent` |
| `auto_advance` | true | `LeadWorkflow.swift` |
| `merge_policy` | unset: handled as `ask_sensitive` | `LeadWorkflow.swift` |
| `sensitive_paths` | the list above | `LeadWorkflow.swift` |
| `strict_paths` | none | `LeadWorkflow.swift` |
| `records_dir` | `docs/lead` | `LeadWorkflow.swift` |
| `disk_warning_gb`, `disk_floor_gb` | 10 GB, 3 GB | `LeadWorkflow.swift` |
| `watch_app_logs` | false | `LeadWorkflow.swift` |
| Audit round cap | 2 rounds | `LeadBoard.swift` |
| Flake limit | 3 flakes of one test in 7 days | `LeadBoard.swift` |
| Merge reruns | once, up to 20 named tests | `MergeRerun.swift` |
| Question timer (`decide_in`) | 10 min | `LeadBoard.swift` |
| Board archive age | 24 h; at most hourly | `LeadBoardArchive.swift` |
| `mac_max_sessions` | 10 | `MacLoad.swift` |
| `load_threshold` | 2 × cores | `MacLoad.swift` |
| `heavy_slots` | `VIBESWITCHER_HEAVY_SLOTS`, else Settings' (cores ÷ 6 unset); raised to boost's while on | `TestLock.slotCount`, `MacLimits.heavySlotsInForce` |
| `vs-heavy` timeout | 60 min | `Resources/bin/vs-heavy` |
| `vs-heavy` stall | 10 min with no progress, the Mac under `load_threshold` (`--stall`, `VIBESWITCHER_HEAVY_STALL`) | `Resources/bin/vs-heavy` |
| Battery hold | below 50 % on battery | `PowerSource.swift` |
| Usage back-off | 80 % of a limit on the model | `AccountUsage.swift` |
| Stall: silent, idle, compacted | 15, 10, 5 min | `LeadStall.swift` |
| Verifier ends after its verdict | 20 s | `Sources/VibeHost/HostServer.swift` |
| Records commit | after each merge, at most every 5 min | `LeadRecords.swift` |

The rules the lead itself follows (when to audit, when to ask) are in its prompt (`LeadWorkflow.swift`) and in
[docs/process/lead-rules.md](../process/lead-rules.md).
