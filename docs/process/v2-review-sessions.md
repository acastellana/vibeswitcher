# V2 feature review: sessions and terminals, updates and install, plugins and the rest, Linux-only new (2026-11-22)

The feature review's brief (`.build/notes/briefs/feature-review.md`), for four groups of
[the parity table](v2-parity.md): each row checked against V1's code (`Sources/VibeSwitcher`, `Sources/VibeCore`) and
V2's (the node's code, its command line), not against the row's own words. Verdicts: **good** (does what a V1 user
relies on, as well or better), **improve** (works, but worse than V1 in a way a user would notice), **missing**,
**blocked** (waits on a user decision or a real Mac), **not needed** (macOS only).

## Sessions and terminals

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| A session host that keeps sessions and hands them over | good | `HostLink`, the host under the node; `switch` hands over and never replaces (V1 can also replace and end sessions: on purpose) | |
| Start a Claude, Codex or shell session | good | `vibeswitcher new FOLDER [--agent claude\|shell\|codex] [--model M] [--preset NAME]`, the page drafts it; Codex as the user's own | |
| Launch presets | good | `presets`, `new --preset`, `preset add\|edit\|remove`, bound by digest, held by the seal until `config accept` | |
| End a session, Close Finished Shells | **improve** | `end` and `close-shells` work, but V1's `ShellTidier` also ends a Run card's shell by itself once its command went well, 10 minutes back at its prompt, untouched and leaving nothing running (`ShellTidy.due`). On the node every Run card leaves a shell for good, the pile-up V1 fixed on 2026-11-10 | the node's own tidier: the engine looks every 30 s and ends what `ShellTidy.due` names, a shell sent to since its command ended (`send`, `reply`) kept as the user's, recorded across restarts |
| Pause, rename, reset a name | good | `rename`, `pause` (the Mac's four pauses), kept by the session's keys | |
| Live terminal: type, select, find, scrollback, text size | blocked | watching works; typing from a page waits on H1's decisions (`docs/process/v2-h1-plan.md`), out of scope here | |
| Terminal look | good | the page's own per-viewer preferences, every V1 option | |
| Sessions in other terminals | good | `NodeSessions`, `hosted: false`, never typed into | |
| Terminal.app control | not needed | no Terminal.app on Linux | |
| Ended sessions: resume, copy the line or id | **improve** | `resume` lists and restarts the user's own *Claude* sessions only (`SessionReopen.reopenable`: `entry.agent == .claude`). Since 2026-11-21 the node starts the user's own Codex sessions too, and V1 resumes those (`codex … resume <id>`, `LaunchPlan.resumeCommand`) | Codex in `resume` and `reopen`: the conversation checked in Codex's own sessions folder as a Claude one is in Claude's, started as `codex resume <id>` by the Codex link |
| Reopen after the machine restarts | **improve** | the same Claude-only rule; V1's restart card reopens Codex sessions too, and a preset's session with its preset (`LaunchPlan.resumeRequest`'s `launchedFrom`) | as the row above for Codex; a preset's session reopened plainly is said so (its preset isn't carried: the preset file can have changed since, and reopening by name would run what the user didn't look at) |
| Status detection | good | hooks, OSC 7501, titles for hosted sessions, the process table | |
| Background shells shown on a session | good | `NodeSessions`' `BackgroundWork` from the screen, as V1's | |

## Updates and install

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Check for Updates, the update card | **improve** | the watch and `status --check-updates` (2026-11-21: the row's "no Check now" is out of date) work in a terminal. The page shows a newer build only as one notice line, and nothing when it is up to date or when the check failed; V1's card says each, with Check for Updates beside it | the node's `update` record on the wire's `node` shape, and the page's node view an Updates section: up to date as of when, the newer build with its two lines, or why it couldn't look, with `vibeswitcher status --check-updates` to copy |
| Install | good | `install-node.sh`, `install-record`, `start` | |
| Switch and roll back | good | `switch COMMIT`, `rollback` | |
| Open at login | good | `start --at-login` | |
| First-run setup, installing tools | good (on purpose) | `doctor` names every missing piece with its exact command; installing nothing is the design (agents install nothing; the user runs the line) | |
| Restart Session Host | good | `stop`, `start` (typed code, says how many sessions end); `switch` hands over | |

## Plugins and everything else

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| Shell requests: Run or Decline | good | `ShellCards`, the voice's `answer CARD run\|decline`, and the page's card under the asking session's chat (`WebApp/js/shellcard.js`, 373a95ec: the row's "the page lists no shell card" is out of date). Run-card shells' tidying is the sessions row above | |
| Wallet requests | blocked | browser signing waits on its own origin and signed approvals (the security document's items 11 and 16), out of scope | |
| Brief Me | good | `brief`, the page's Speak; ElevenLabs not ported (its key lives in the Mac's Keychain) | |
| Settings | good | `settings`, `set`, `--find`, the page drafts | |
| Projects folder | good | `set projects_folder`, `new-project` | |
| Mac permissions | not needed | macOS only | |
| App Nap, focus log, presence | not needed | macOS only | |
| Wallet and passage e2e | not needed | no wallet on the node | |

## Linux-only new

| Row | Verdict | Why | Fix |
| --- | --- | --- | --- |
| The user's voice | good | typed code, the vault and the journal | |
| The session sandbox | blocked | the row's "nothing launches a session in a box" is out of date: branch runs are boxed (SB6, `BranchRun`, through `SessionSandbox` in `PTYSpawn`); workers', leads' and verifiers' sessions (SB3, SB11) are the sandbox plan's next slices, its lane and the lead's call, not a review fix | |
| The host's allow-list and hardening | good | `ProjectAllowList`, `HostHardening` | |

## What gets built (most user-visible first)

1. The page's Updates section (the update record on the wire).
2. The node's Run-card shell tidier.
3. Codex sessions in `resume` and `reopen`.

Each its own commit with tests; the parity rows updated as each lands.
