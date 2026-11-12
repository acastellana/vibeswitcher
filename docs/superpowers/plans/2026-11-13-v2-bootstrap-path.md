# VibeSwitcher 2: the path to the bootstrap

The order of work from where `v2` stands (2026-11-13, `47636aaf`) to the bootstrap, across stages 1 to 4, with what
each step proves. It is a map, not a task plan: each step points at the plan that holds its tasks, and the one piece
that has no plan yet, the lead engine, is outlined here so its plan can be written.

**The bootstrap** (the design's, unchanged): from an installed build, a lead on this machine plans a real version 2
task, a worker builds it, it is audited, and it merges into `v2` through the gate with the tests green. From then on
the lead builds the rest of version 2, supervised from Claude Code.

**Sources:** the design (`docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`, The bootstrap), the stage 1
plan's [remaining work](2026-11-12-v2-stage-1-core-on-linux.md#remaining-work-revised-2026-11-13), the
[stage 2 plan](2026-11-13-v2-stage-2-session-host.md), and the port map (`docs/process/v2-port-map.md`). Code
references are at `47636aaf`.

## What runs on a lead's path

| Piece | What it does for a lead | Where it stands |
| --- | --- | --- |
| `vibeswitcher-host` | PTYs, parsers, the vault (roles, seals, approvals), spawning, screens and input | doesn't build on Linux (142 errors); stage 2 |
| `vibeswitcher-mcp` | every lead tool: workers, worktrees, audits, `auto_advance`, the merge gate | builds on Linux; needs a host for its role |
| `vibeswitcher-hook` | hook state files, the steer inbox's hand-over | builds on Linux; not yet run with a real agent here |
| the lead engine | starts and wakes leads, delivers reports and answers, watches for stalls, holds | doesn't exist; the app's `LeadController` imports AppKit and Combine and can't be edited on `v2` |
| `vibeswitcher` (built as `vibeswitcher-cli`) | the user's voice: start, status, lead, questions, answers | doesn't exist |
| the install step | an installed build, never the working copy | doesn't exist |

The engine is the largest piece and the likeliest to slip, so it gets a plan of its own ([below](#the-engine)).

## Who starts the node and keeps it running

On the Mac the app starts the host and the host outlives the app. On Linux there is no app, so `vibeswitcher start`
does it, and the node has to outlive the terminal it was started from.

What this machine has (read, not changed): `/etc/wsl.conf` sets `systemd=true`; pid 1 is systemd; the user's own
`systemd --user` runs (pid 284) and lingering is on for the user (`/var/lib/systemd/linger/albert`), so the user's
manager runs without a login session; `~/.config/systemd/user` has no units. `claude` is in `~/.local/bin`, which the
interactive shell's PATH has and a user unit's default PATH doesn't. The Windows side's `.wslconfig` sets
`networkingMode=mirrored` and no idle timeout.

**`vibeswitcher start`** (author's call; the user confirms the "at login" part):

- Where the user's systemd answers (`$XDG_RUNTIME_DIR/systemd/private` exists), it writes
  `$XDG_CONFIG_HOME/systemd/user/vibeswitcher-node.service` (`~/.config` when unset), with
  `ExecStart=<prefix>/<commit>/bin/vibeswitcher-host --server <prefix>/<commit>/bin/vibeswitcher-server` (the
  commit's folder, not `current`, so a moved link changes nothing until the user switches), `Environment=HOME=…` and
  `Environment=PATH=…` set explicitly to the PATH `start` was run with (absolute folders only), and `Restart=no`;
  then starts it through `systemctl`, found on PATH. It is started, not enabled: nothing starts by itself after a
  reboot unless the user asks with `start --at-login`. A switch to another build (step 8) rewrites `ExecStart`.
- **Why `Restart=no`** (stage 2's S2-D1): a worker of the same user can kill the host, and with `on-failure` systemd
  would start it again from whatever the unit, its drop-ins, `~/.config/environment.d` and the manager's environment
  then name, with an empty vault (S2-D3). With `no`, a killed host stays down until the user's `vibeswitcher start`.
  This doesn't stop a worker that runs `systemctl --user` itself, which works from any session (S2-D12 doesn't keep
  it out); `vibeswitcher status` therefore shows the host's start time and marks a start the user's own `start`
  didn't make, until the user acknowledges it (`status --ack`).
- Where there is no user systemd (a container, WSL without systemd), it starts the host in a session of its own
  (`setsid`, a double fork, its output to the host log) and records its pid; `stop` ends it.
- Before either, it checks that the PATH it will give finds `claude` and `git` (`Platform.Tools.find`), and refuses,
  saying which is missing, when it doesn't.
- **How it is tested** without touching the user's systemd: `StartCommandTests` set `XDG_CONFIG_HOME` to a scratch
  folder and put a recording stand-in named `systemctl` first on PATH, and check the unit written and the
  `systemctl` calls made (`--user daemon-reload`, `start vibeswitcher-node`); the no-systemd path runs in a scratch
  home with `XDG_RUNTIME_DIR` pointing at an empty folder, and checks the host runs in its own session and `stop`
  ends it. Nothing in a test reaches the real `$XDG_RUNTIME_DIR`.
- The unit file and its folder are on the config seal's Linux list (milestone 8). That is a detector with a hole:
  a worker that edits the unit and then restarts the host starts a fresh vault, which before stage 2's
  `holdsFirstLook` would have taken the edit as its baseline. With it, a fresh vault holds every watched file until
  the user's `config accept`, which lists them, so the edit is shown to the user, not "caught".
- A host restart loses the vault (stage 2's S2-D3): the lead is started again from the command line, the config is
  accepted once, and the engine's restart path (E8) says what that costs.

**Whether WSL keeps it running with no terminal open is not known.** WSL may stop the distribution once the last
Windows terminal into it closes, whatever runs inside. It is measured in milestone 8: start the node, close every WSL
terminal for 10 minutes, reopen, and check that the host's start time is unchanged and a session is still live; the
result goes into `docs/process/v2-linux-inventory.md`. Closing every Windows terminal is the user's step (an agent
runs inside one), so it is among [the questions](#what-the-user-is-asked): the agent prepares the check and reads
the result, the user closes and reopens. If WSL stops it, the user decides how to keep it up (a terminal left open
during the bootstrap needs nothing changed; a Windows-side keep-alive is the user's to set up, never an agent's).

## The steps

Each ends in something that runs.

1. **Stage 1 closed** (stage 1 plan, remaining work: R1 to R3, R5, R7, R8a, R8b, R9, R10, R12; the failures by cause
   A to P are covered by the core-test fixes (2026-11-13)).
   - **Proves:** the core, the hook and the tool server run on Linux; the tool server answers MCP with no host; a real
     Claude Code session is seen going from working to needs-you to done (once the user's config folder exists).
   - **Also proves:** `VibeCoreTests` green on Linux, which the merge gate's `test_command` needs; every job green on
     one commit, as stage 1's R3 defines green.
2. **The user's answers, asked once** ([below](#what-the-user-is-asked)), in parallel with step 1. Nothing later
   stops to ask; a gated test waits as an open item.
3. **The security document reviewed** (stage 2, Task 1), before any of the host is ported.
4. **The host on Linux** (stage 2, Tasks 2 to 10).
   - **Proves:** `VibeHostTests` and the host audit green on Ubuntu; terminal names match the hook's (`ttypts<N>`);
     each message's sender checked; the app is only the host's live server child, on any connection it opens; host,
     parsers and server non-dumpable; nothing run from a file replaced after the host started; the project allow-list
     holds.
5. **The lead's tool server under a host** (stage 2, Task 11).
   - **Proves:** with a lead's role bound, `tools/list` has `start_worker`, `audit`, `merge` and `status`, and a call is
     served. (Moved from stage 1: with no host the tool server has no role and lists nothing.)
6. **A real Claude under the host** (stage 2, Task 12; gated, doesn't hold up step 7).
   - **Proves:** PTYs, parsers and handover hold with the real agent, on Sonnet.
7. **The engine** (its own plan, `docs/superpowers/plans/2026-11-13-v2-engine.md`, written from
   [the outline below](#the-engine) while stage 2's Tasks 2 to 5 run). E1 needs stage 2's Task 8 (it ends in the
   server running as the host's child). E2 and E3 can start after Task 5, under the engine's own test stand-in:
   `VibeNodeTests` depends on `VibeHost`, and the engine plan adds `Tests/VibeNodeTests/NodeTestHost.swift`, a scratch
   host that sets `appPrincipal` as stage 2's Task 5a does for `TestHost` (which lives in `VibeHostTests` and can't be
   shared). E4 onwards needs Task 8.
   - **Proves:** under a scratch host, a lead started from the command line on a scratch repository plans, asks a
     question, and is answered from the command line; an audit can't hang on a prompt; the lead hears every report.
8. **Start, install and the seal.**
   - `vibeswitcher start | stop` as [above](#who-starts-the-node-and-keeps-it-running).
   - `scripts/install-node.sh`: a release build of `vibeswitcher-host`, `vibeswitcher-server`, `vibeswitcher-cli`
     (installed as `vibeswitcher`), `vibeswitcher-hook` and `vibeswitcher-mcp` into `<prefix>/<commit>/bin`, with
     `Resources/bin/vs-*` in `<prefix>/<commit>/Resources/bin` (where `TestLock.commandFolder` looks: two folders up
     from the resolved executable, then `Resources/bin`), a `build-info` in the format stage 2's Task 9 fixes (the
     commit and each binary's SHA-256, which the handover-target check and the host's start check read), and
     `<prefix>/current` pointing at it. `<prefix>` is `~/.vibeswitcher/v2/builds`. The command the user runs is
     `<prefix>/current/bin/vibeswitcher`; nothing is put on PATH, and the user runs answers and accepts by that
     absolute path (or an alias the user writes), so a `vibeswitcher` a worker placed earlier on PATH isn't the one
     that runs.
   - `ServerBuild` reads `build-info` on Linux (`LeadGateBuild.swift:41-55` reads only an app bundle's `Info.plist`;
     a non-seam edit, logged), so merge receipts name the build.
   - `vibeswitcher hooks install`, now through the server, which writes as the app and so seals the change
     (`vault.appWrite`), as the app's `HookSetup` does. Because it seals, it takes only the user's voice (stage 2's
     S3): `aSessionsProcessCannotInstallHooks`.
   - The config seal's Linux list: `ConfigSeal.homeFiles` (`ConfigSeal.swift:306-315`) has the Mac's files only
     (the shell startup files `.bashrc`, `.bash_profile`, `.profile` among them). A platform answer, empty on the
     Mac, adds `~/.config/systemd/user`, `~/.config/environment.d`, `~/.config/autostart`,
     `~/.vibeswitcher/v2/projects`, `~/.vibeswitcher/v2/builds`, `~/.local/bin` (first on the interactive PATH, so a
     `vibeswitcher` or `git` placed there would shadow the real one) and the Claude Code install
     (`~/.local/share/claude/versions`), with one hook line in `ConfigSeal` (logged) and a test that a write to each is
     held. Until the sandbox this is the one check on what an unconfined worker changes there, and a host restart
     resets it to "held until accepted" (S2-D3). The user's crontab lives in `/var/spool/cron`, which the seal's file
     reads can't reach (only `crontab -l` shows it), so it goes on the not-promised list.
   - A switch and a rollback: install a new commit, switch (the unit's `ExecStart` is rewritten to the new commit's
     folder; the host hands over to the new host, which is checked as stage 2's S2-D7 says; the server is restarted from the new image once idle; tool servers switch themselves), and
     check that the host, the server and a fresh tool server all report the new commit; rollback restores all three.
   - The WSL measurement above, with the user (question 4).
   - **Proves:** the lead runs from an installed build, never the working copy.
9. **A full scratch run on Sonnet** (a harness through `scripts/test.sh`, gated like the real-agent tests, on a
   scratch host with its own `VIBESWITCHER_HOME` and lock, so the user's host and its allow-list aren't involved).
   - **Proves:** two workers in worktrees, one audit, one merge through the gate with tests green, one question
     answered from the command line: the design's stage 4 Done-when, on a scratch repository.
10. **The bootstrap.**
    - **Setup:** install from a `v2` commit both runners passed. The lead runs on its own clone
      (`~/projects/vibeswitcher-v2-lead`), base branch `v2`, so Claude Code's commits in the working copy don't move
      the lead's base under it; commits move between the two on purpose, and each move is accepted as a base move.
      The clone's `.vibeswitcher/workflow.md` (not in git): `base_branch: v2`, `records_dir: docs/lead-v2`, a
      `test_command` scoped to what passes on Linux, no remote. The user writes the clone's path as the one line of
      `~/.vibeswitcher/v2/projects`.
    - **Proves:** the design's bootstrap Done-when.

## The engine

The node's lead engine, in `VibeNode`, rebuilt from the app's code (which `v2` may not edit) and run in
`vibeswitcher-server`, the host's server child. It reaches the host through `VibeCore`'s calls (`HostCall`,
`LeadVault.standard`), each a new connection by path, which the host takes as the app because the process is its
server child (stage 2's S2-D1). Each app file it replaces has a row in `docs/process/v2-port-map.md`.

Rules for the port:

- Rebuilt, not moved: plain Swift, no AppKit, no Combine; a small change-stream type stands in for `@Published`.
  Pure helpers may be copied, each with a port-map line.
- What the app asks in a modal dialog becomes a command-line flag or a card the user answers from the command line.
- The app's tests are the engine's spec: their cases are ported into `VibeNodeTests` and run on Linux.
- The engine refreshes every 3 s, as the app's `Heartbeat` does. That breaks the design's "a store learns of changes
  from events, never from a timer"; stage 3's stores replace it after the bootstrap, and the design records the
  exception.
- `vibeswitcher-server` closes the held-image descriptor it inherits, makes itself non-dumpable and checks it isn't
  traced, as its first statements (stage 2's Task 3 and S2-D5), then settles SIGPIPE before its first write (stage
  1's R5).

The parts, in order. Line ranges are in `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` unless named.

| # | Part | Rebuilt from | Ends in | Tests ported or new |
| --- | --- | --- | --- | --- |
| E1 | `vibeswitcher-server` and its socket | new | The server runs as the host's child; a 0600 Unix socket under `~/.vibeswitcher/v2/` takes a small versioned request/reply protocol (a format number, a request id, a kind; an unknown kind answered, not fatal; a must-understand kind closes), the seed of stage 3's. `vibeswitcher start`, `stop` and `status` go through it. Every request kind is listed with the voice it needs (stage 2's S3); a user's-voice request is echoed to the server's log and shown by `status` | `theServerIsNotDumpable`, `anUnknownRequestIsAnsweredNotFatal`, `statusThroughTheServerMatchesTheProbe`, `aSessionsProcessCannotStopTheNode`, `anUnlistedRequestIsRefused`, `anAcceptedAnswerIsShownByStatus` |
| E2 | `HostLink` | `HostClient.swift`: connecting, the welcome and events (152-518), requests and spawning (656-761), input units (1046-1177), screens, history, kill and remove (1214-1252) | The engine's one view of the host: sessions as they change, spawn, input units, screens | the cases of `HostClientReplyTimerTests`, `HostClientReapTests`, `InputUnitDeliveryTests` |
| E3 | `NodeSessions` | `SessionStore.swift`: refresh and apply (202-264, 298-452), details (481-503), the state folder's watch (504-523); built on stage 1's `LocalSessions` and `HostLink` | One session list with statuses, the agent's quitting, background jobs | the cases of `SessionStoreTests` that aren't about Terminal.app or Spaces |
| E4 | Starting a lead | `startLead(in:)` 807-848, `startLead(root:)` 890-952, `startPending` 953-962, keeping leads running 963-995, `prepareLead` 996-1090, `spawnLead` 1091-1117, the lead sessions and roots 718-795 | `vibeswitcher lead FOLDER --goal "…" [--take-head] [--replace]` starts a lead (the dialogs at 2039-2063 become the two flags; the first-commit offer, 850-889, becomes a refusal that says the folder needs a commit) | `LeadRelaunchTests`, `LeadFilesTests`, the parts of `LeadStartsHostTests` not about starting the host; new: `aSessionsProcessCannotStartALead` |
| E5 | Delivery and wake | delivering and holding 1208-1252, waking 1335-1405, flushing and typing 1406-1468, telling a session 1989-2023 | A worker's report reaches an idle lead: the wake prompt is typed once for all that wait | the cases of `ComposerDeliveryTests` and `PasteDeliveryTests` that are about delivery, not the composer view |
| E6 | Questions, answers and holds | `answer` 1127-1165, `hold` 1166-1195, timers 1196-1207; `ConfigHolds.swift`; `BaseMoves.swift`; `PushRequests.swift` (listed and refused: no remote) | `vibeswitcher questions`, `answer ID TEXT`, `hold ID`, `config accept`, `base accept`, taken only from the user's voice as the security document's S3 defines it | `LeadApprovalAnswerTests`, `LeadChatQuestionTests`, `ConfigHoldsTests`, `BaseMovesTests`; new: `anAnswerFromASessionsProcessIsRefused`, `anAnswerFromAProcessCarryingASessionMarkerIsRefused`, `anAnswerFromBranchCodeIsRefused` |
| E7 | Refresh and the witness | `refresh` 1474-1525, `refreshed` 1526-1564, `sweepRoles` 1565-1585, `forgetFinished` 1813-1822, `witness` 1823-1885, `witnessed` 1886-1967, `stopForBudget` 1968-1988; `RoleSweep.swift`, `PromptDecline.swift`, `AllDoneWatch.swift`; `Heartbeat.swift` as the 3 s timer | Sessions whose tools never connected are ended; `auto_advance` is nudged for ended verifiers and releasable workers; stuck verifier prompts are declined; the budget is kept; finished teams forgotten | `WitnessOffMainTests`, `RoleSweepTests`, `StuckVerifierPromptTests`, `AllDoneWatchTests`, `HeartbeatTests` |
| E8 | Restarts | the rebind in `startLead(root:running:)` 916-952 and `keepRunning` 975-995 | After a server restart the lead is rebound and nothing it was told is lost; after a host restart (an empty vault) the engine says the team is gone, `status` shows the restart and whether the user's `start` made it, the fresh vault holds every watched file (stage 2's `holdsFirstLook`) until `config accept`, which lists names and modification times, and the lead is started again, its base accepted through `base accept` | new: `aServerRestartKeepsTheLeadAndItsHeldMessages`, `aHostRestartSaysTheTeamIsGone`, `aHostRestartHoldsWorkersUntilTheConfigIsAccepted`, `aStartTheUserDidntMakeIsShownUntilAcknowledged` |

Not ported before the bootstrap (the lead's own later work): rotation (2084-2287), replaced-lead routing (1253-1334),
the power, toolchain, heavy-slot, heavy-job, room and policy watches (1586-1774), app health (1775-1812), keep-awake,
summaries and mail, the wallet desk.

## What the user is asked

In one message, at the start, so the work never stops to ask:

1. **A Claude Code config folder** for the gated real-agent tests: made and logged in by the user, named in
   `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`. Until then those tests are skipped, saying why, and later work goes on.
2. **Stage 2's decisions marked "the user confirms"** (S2-D1, S2-D3, S2-D6, S2-D8 to S2-D12), each with its
   recommendation: chiefly, that until approvals are signed the app on Linux is the host's server child, and the
   residual risks before the sandbox are accepted on VibeSwitcher's own repository only; and that sessions identified
   by an inherited socket and clones for workers move to after the bootstrap.
3. **How the node starts:** `vibeswitcher start` through a user systemd unit, started but not enabled at login, with
   `Restart=no` (a killed host stays down until the user starts it), and after every host restart one `config
   accept` by the user.
4. **The WSL measurement, and if WSL stops the node** when no terminal is open: the user closes every Windows
   terminal for 10 minutes and reopens one (an agent can't); if the node stopped, keep a terminal open during the
   bootstrap, or set up a Windows-side keep-alive.
5. **The allow-list line** for the bootstrap clone, written by the user.
6. **How the user runs the command line:** by its absolute path (`~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`)
   or an alias the user writes, never a `vibeswitcher` found on PATH.

## Deliberately after the bootstrap

The lead's backlog, roughly in this order:

- **From stage 2:** the sandbox (and in it the subreaper), the inherited connector, clones for workers, the egress
  proxy, strong mode, the sealed handover, unreadable installed images, `vibeswitcher attach`.
- **From stage 3:** the stores with snapshot and delta, and the engine moved off its 3 s refresh onto them; the
  WebSocket; device keys and pairing; the terminal spike; the two-node smoke test.
- **From stage 4:** approvals as device signatures; the team seam with clones (rule 4); launch rules checked against
  the agents' adapters.
- **From the engine:** rotation, the watches, keep-awake, summaries, mail, the wallet desk.
- **From stage 1:** the static build and the binary decision, the cross-process start time, `platform-parity.md`,
  dev previews, thumbnails, `doctor`, the adapters, resources inside the binaries, format versions beyond the
  settings file, the Darwin cost follow-ups, Task 10's leftovers.

Until stage 4's signed approvals, an answer from the command line is a guard rail, not a lock (the security
document's S3 and S11). So, until the sandbox, are verdicts and merges: with no Yama a worker can ptrace a session's
agent or tool server and act as that session, the lead or a verifier included; and a worker can restart the host
into what the install folder and the unit name (stage 2's S2-D1). That is acceptable only because the one project on
the node is VibeSwitcher's own, which the project allow-list enforces in the user's host (S2-D11, held by S11).
