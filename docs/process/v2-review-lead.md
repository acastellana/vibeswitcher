# V1 vs V2 review: the project lead, accounts and usage, hooks and the seal, diagnostics

2026-11-22, `v2-usage-summaries`, for the feature review (`.build/notes/briefs/feature-review.md`). One row each from
`docs/process/v2-parity.md`'s four groups, checked against V1's code on `main` (`Sources/VibeSwitcher`, the shared
`Sources/VibeCore`) and V2's node code and behaviour (the built command line on scratch nodes where a test runs it),
not the parity row's words.

Verdicts: **good** (a V1 user loses nothing they rely on), **improve** (works, but worse than V1 in a way a user would
notice: named), **missing**, **blocked** (waits on a user decision or a real Mac: named). The fixes are built below the
table, most visible first; each row says where it landed.

## The project lead

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Start a lead in a folder, with a goal | improve | V1 offers to make the repository when the folder isn't one, or has no commit (`LeadController`'s first-commit offer); V2 refuses with "git init, and a first commit" and leaves you to do it | `vibeswitcher lead FOLDER --init`: the repository and its first commit made in the folder (`ProjectCreation`'s steps, nothing left on a failure), then the lead, one typed code; the refusal names it |
| New Project… | improve | the command line has it (`new-project`); the page has no form for it (V1's sheet) | the page's start screen drafts the `vibeswitcher new-project` line from a form (pages never act) |
| Message a running lead, or send it a goal | good | `tell` and `lead --goal` reach the bound lead through the vault, held while it can't take them (A13) | |
| Questions to you, timers, Hold | good | cards, `answer`, `hold`, the timer and its proposal, on the page and the command line (A12, A13) | |
| Answer a card with one click | blocked | on purpose: a page is never the user's voice (LW-D6); one-click answers wait on the H1 decisions (which input a page may send, with what right) | |
| Approve a merge | good | approval cards with the commit's facts, `answer` approves that commit (A15) | |
| The board | good | tasks, decisions, scorecard, answered questions, files, results, between leads, task details, on `board` and the page; the Mac-wide foot (load, limits) is on `settings` and This node, a team's wall in its members' chats | |
| Workers, verifiers, audits, the merge gate, risk check, revert, provenance, auto_advance | good | the shared tool server runs on the node; the full scratch team run and A14 merge through the gate | |
| Codex workers | blocked | security decision 15 (Codex's sandbox not measured) | |
| The lead's own model | good | `LeadLaunch.leadRun` as the app's, Fable held back by the usage | |
| The witness: stalls, room watch, role sweep, stuck prompts, disk watch | good | `Witness`, `RoomWatch`, `RoleSweep`, `PromptDecline`, run each refresh | |
| Rotation | improve | V1 counts the user's typing into the lead (its two-minute quiet, a delivery cancelling an ask); V2 counts from the engine's start, so a lead you just typed to can be rotated mid-thought | the user's `vibeswitcher send` to a lead session restarts its quiet (`IdleHandover`) |
| A server or host restart | good | the lead rebound, held messages kept, `status` says how the host ended (RestartTests) | |
| The config seal and Accept cards | good | `config held`, `config accept`, now `approve`; Claude Code's self-updates stay held with the card saying so: a user decision (verify against Anthropic's manifest, or pin) | |
| Base moves | improve | V1 takes a move your own `!` git command (sent into the lead from the window) made without asking; V2 asks a card for it | a `!` line with a git command sent to a lead with `vibeswitcher send` accounts for the move it makes (V1's `typed`, `LeadVault.runs` and `judge`), within 5 minutes; a team session's command never does |
| Push to the remote | improve | the lead's tool reply tells it the user will "click Push on its card in VibeSwitcher", which the node has no card for: the lead says the wrong thing | on Linux the reply names `vibeswitcher push FOLDER` / `decline-push FOLDER` (shared file: a port-map row). **Built** (`LeadPush.waiting`, PushAsksTests) |
| Fetch from and merge the remote | improve (unverified) | a shared tool no node run had used (fetch is used by A16's push request) | a scratch node run: `fetch_remote` then `merge_remote` brings a remote commit into the base |
| Leads messaging each other, Between leads | good | `tell_lead` delivered, `mail` and the page's Between leads | |
| The prompt-audit reminder | good | the watch, the notice, snooze/off/on; nothing types the command (V1's Run now is a click; here the user types it in the lead) | |
| `small_task_min` | good | the vault told the sessions at work, as the app's | |
| Fable held back: halted workers on Opus | good | `WitnessWork` | |
| AI summaries | good | workers', verifiers', decisions', long messages' (TeamSummaryWatch) | |
| Records | good | the shared tool server | |
| Working policy | good | `set policy`, the leads told | |
| The review rules floor | good | recorded at accept, `set FOLDER floor_…`, the lead told | |

## Accounts, usage limits and performance

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| The account's usage, from the status line | good | through the door to the roles | |
| Workers and audits held back at 80 % | good | the shared tool server | |
| Usage shown to you | good | `status`, `settings`, the page, review rows waiting on a limit | |
| Ignore usage limits | good | `set ignore_usage_limits` | |
| Machine-wide limits | good | enforced, shown and set under the node's names | |
| Boost | good | set, decided, shown (`status`, the page's bolt) | |
| Heavy-job slots | good | `vs-heavy` on the sessions' PATH | |
| Battery hold, keep awake | blocked | not on WSL or a server (no battery); a Linux laptop node is a product decision | |
| Memory benches, malloc relief, hang watchdog, UI benches | good (not needed) | they measure the app's own process; the node's freezes are in the health digest | |

## Hooks, status line, config seal and git guards

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Install and remove the hooks | good | `hooks install/remove`, each config checked first, sealed; `approve` lists them when out of date | |
| Trust the hooks in Codex automatically | blocked | on purpose (a seal bypass on a node, 2026-11-21): the user trusts them in Codex's `/hooks` | |
| The status line for the roles | good | through the door | |
| Git guards | good | the shared `LeadLaunch.prepare` | |

## Diagnostics and health

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Sessions and the raw hook state | good | `status [--json]`, `status --probe` | |
| Logs | improve | V1's log is one file the Debug menu opens; the node's are the host's `debug/host.log` and the unit's journal, which a user has to know to look for | `vibeswitcher logs [--lines N]`: the host's log's last lines (already redacted), and where the server's are |
| The health digest, freeze reports | improve | V1 keeps crash reports; the node counts the server's restarts but never says how the last one ended | the host's notes keep how its server child last ended (signal or status, how long it ran, when): `status --health` and the page say it ("the server last ended: killed by signal 11 after 3 h") |
| The developer tools notice | good | `NodeToolchain`, `ToolchainLook` | |
| What plain mode doesn't promise | good | Linux-only, said by `start` and `status` | |

## Built

Each its own commit with tests; the parity rows say where.
