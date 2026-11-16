# VibeSwitcher 2, Start, Install and the Seal (bootstrap steps 8 and 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The node runs from an installed, statically linked build of a pushed commit, never the working copy.
`vibeswitcher start` starts it as the user's systemd unit, or detached where the machine has no systemd. `stop` ends
it, through the server, or without the server when the server doesn't answer. `scripts/install-node.sh COMMIT` builds
and lays out a commit that both CI runners passed, fetched by its hash from GitHub. `hooks install` and
`switch`/`rollback` go through the server in the user's voice. The config seal watches what a worker can change on
Linux. After that, a full scratch team on Sonnet plans, builds, audits and merges under a scratch host, through the
command line's scratch-form checks (step 9).

**Architecture:** The logic of starting, stopping, switching and the unit lives in `VibeNode` under
`Sources/VibeNode/Start/`. It is pure where it can be. Every tool, path and side effect it uses is a parameter:
`systemctl`, the unit folder, the runtime folder, the host command, the install prefix, the journal writer and the
typed-code asker. The order of `start`'s and `stop`'s steps is in `StartSequence` and `StopSequence`, which the
command line only wires. Tests drive those types in process with scratch folders and recording stand-ins. The
installed command line passes constants: `/usr/bin/systemctl`, the home from `getpwuid`, `/run/user/<uid>`. No
environment variable changes any of these.

The server takes two new kinds, `hooks.install`/`hooks.remove` and `build.switch`, each in its own file under
`Sources/VibeNode/Server/`. A switch reaches the host through the server's connector, as the app's `HostClient` did.
The install is a shell script. It records the build with a hidden subcommand of the just-built command line, so
`build-info` is written by `BuildInfo`'s own encoder. The seal's Linux list is one hook in `ConfigSeal` into
`Sources/VibeCore/V2/LinuxSealList.swift`, and that list is empty on the Mac.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM `--build-system native`, `VibeNode`, `VibeCore`, `VibePlatform`;
bash for `scripts/install-node.sh`, using root-owned tools by absolute path only (`/usr/bin/git`, `/usr/bin/gh`,
`/usr/bin/jq`, `/usr/bin/readelf`, `/lib64/ld-linux-x86-64.so.2 --list`, `/usr/bin/sha256sum`, `/usr/bin/stat`,
`/usr/bin/find`, `/usr/bin/env`). No new dependency.

**Spec:**
- The bootstrap path, `docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md`: "Who starts the node and keeps it
  running", "The steps" items 8 and 9, "Things only you can do" (M3, M5 to M8), and decisions D2, D6, D9, D12, D14,
  D17.
- The security document, `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`: S1, S2, S3 (the table's
  `hooks install` and `build.switch` rows), S7, S8 (the rule on switches), S9 (the unit, the install, the static build,
  the tool server across a switch), S10, S11.
- The design, `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`.
- The engine plan, `2026-11-13-v2-engine.md`: EN-D5 (the typed word), EN-D6 (`stop`), EN-D8 (the scratch form),
  EN-D12 (the host lifecycle is step 8's), EN-D15 (the journal is the command line's), and its request table.
- The port map, `docs/process/v2-port-map.md`, rows 52, 55, 97 to 100, 223 and 224.

**Code references** are at `v2` `84769027`, plus the engine sweep (`v2-engine-sweep` at `8f13858c`, or the head that
is merged). The sweep has merged `84769027` and is not yet in `v2`. **This plan starts once the sweep is merged into
`v2`.** Its `ServerCheck` session rule (`getsid`), its `ScratchNode` rewrite and its `Edit(…)`-only deny rules are
assumed.

## What exists, and what this plan builds

| Piece | Today | This plan |
| --- | --- | --- |
| `start` | Only talks to a running node. With no server it exits 69. The S11 ack is recorded only after a server answers (`Start.swift:23-35`) | S1 to S3: preflight, unit, systemd start or detached start, the S11 ack before anything |
| `stop` | Through the server (EN-D6). With no server it exits 69 (`Stop.swift:16-19`) | S3: `systemctl --user stop`, or end the recorded host, after the typed code |
| `NodeCheck` | `.node` (unit cgroup and `MainPID`) and `.scratch` | S3: `.detached(record:)` |
| The install | Nothing. `BuildInfo` (format, parser, readers) is done, but there is no writer | S4a to S4c |
| `ServerBuild` on Linux | nil (`LeadGateBuild.swift:41-55`) | S5 |
| The host's commit and start line | Not in `HostNotes`; no `SWIFT_BACKTRACE` line | S5 |
| `hooks.install`/`remove` | Listed in `NodeWire.kinds` but not `taken`; the CLI writes locally with no seal | S6 |
| The seal's Linux list | `.bash_login` is already in `homeFiles` (`ConfigSeal.swift:311`); nothing else | S7 |
| `build.switch`, `switch`, `rollback` | Listed in `kinds` only. The host's side is done (stage 2's 9c/9d) | S8a to S8c |
| The real node (M7) | — | S9: what the agent prepares, then the user's steps |
| Step 9's scratch run | E9 Step 1 passes with fakes; E9 Step 2 (real Sonnet) is open | S10 |

## Global Constraints

- **All work on `v2`, never `main`.** Nothing under `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests` or `Web/` is
  edited.
- **Shared files.** An edit to an existing file under `Sources/VibeCore`, `Sources/VibeHost` or an executable shared
  with main (`vibeswitcher-host`, `-hook`, `-mcp`) must be one of stage 2's edit kinds (1 to 8; the stage 2 plan's
  Global Constraints).
  - Each edit of kinds 4 to 8 gets a row in the port map's Non-seam edits. The ones this plan makes are listed under
    [Non-seam edits](#non-seam-edits-this-plan-makes). An executor who needs another stops and asks.
  - New `VibeCore` files go in `Sources/VibeCore/V2/`, new `VibeHost` ones in `Sources/VibeHost/V2/`.
- **No `#if os` outside `VibePlatform`** (`PlatformLint`). "On Linux" outside it reads
  `!Platform.CodeIdentity.isAvailable`. Its Mac form does nothing, and a Mac test says so.
- **Tests only through `scripts/test.sh`**, never a bare `swift test`. Lints run before a task is reported done. New or
  changed tests also run under `scripts/test-under-load.sh --load 24 -r 3`. Long or many-core jobs (the release build,
  the static spike, the gated static build) run under `vs-heavy`.
- **Tests never touch the real `~/.claude`, `~/.vibeswitcher`, `$XDG_RUNTIME_DIR`, the user's journal or systemd.**
  - Every start, stop, unit and switch test runs in process on `StartSequence`, `StopSequence` and the types they
    call, with scratch folders, a recording `systemctl` and a recording journal writer, or on a `ScratchNode`.
  - A `--node` host is never started by a test: it takes the account's real `~/.vibeswitcher`. That the real path
    carries `--node` is asserted from the arguments the code builds.
  - In node mode the command line refuses `start` and the `stop` fallback before any write unless it runs from an
    installed build (ST-D3). A command line under `.build` that ends up in node mode writes nothing.
  - `ScratchNode.environment` points `XDG_RUNTIME_DIR` and `XDG_CONFIG_HOME` at scratch folders and drops
    `DBUS_SESSION_BUS_ADDRESS`: defence in depth, since node mode reads neither (ST-D2).
  - Every `InstallTests` case that runs the script passes `--prefix <scratch>`, `--gh <stand-in>` and `--test-origin <scratch bare repo>`.
    No case reaches GitHub, the user's token or the real builds folder.
- **Agents start nothing in the user's systemd manager.** `vs start`, `vs stop`, `vs switch`, `vs rollback` and
  `vs hooks install` on the real node are the user's (M7; D14). The agent may run `vs status` and read
  `journalctl --user -u vibeswitcher-node`.
- **Real-agent tests only with `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` given** on the run's command line (D16), on
  Sonnet (the verifier on a smaller model, ST-D21). Each gated run needs the user's go-ahead.
- **A fix's test is shown failing** without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, run the
  test, re-apply. A new feature's tests fail first for the right reason.
- **Every job is green before the next task's first push.** "Green" means the `v2 linux` and `v2 macos` jobs on one
  commit. The lead pushes and watches the Mac's job until M2. After M2 the user pushes ([Order](#order)).
- **Never install anything** (brew, npm -g, pip, apps, toolchains). M3's toolchain is the user's.
- Commit messages end with the attribution line the session gives.

## Decisions this plan makes

Numbered ST-D1 and up. Each is the plan author's recommendation, recorded as **the lead's call**: the user has
accepted every recommendation so far. Each can be overruled before its task starts.

1. **ST-D1: Start's logic is in `VibeNode`, with its tools as parameters; scratch mode starts nothing.**
   - `StartSequence`, `StopSequence`, `NodeStarter`, `NodeUnit`, `StartPreflight`, `NodeStopper` and
     `SwitchFollowUp` take `systemctl`, the unit folder, the runtime folder, the host command, the prefix, the journal
     writer and the typed-code asker as arguments.
   - The CLI passes `NodeStarter.Tools.node`: `/usr/bin/systemctl`, `<getpwuid home>/.config/systemd/user`,
     `/run/user/<getuid()>`, and `NodeJournal`'s socket writer.
   - On a scratch node (EN-D8's mode), `start` with no server answering refuses with exit 69: "scratch node: started
     by its harness". It never writes a unit. The only `systemctl` it runs is its test's stand-in, for the facts'
     `show-environment`; it never asks for `daemon-reload`, `enable`, `start` or `stop`. `stop`'s fallback is refused
     the same way.
   - So `VIBESWITCHER_HOME` only ever narrows what the command line does. This keeps the spec's rule that "no
     environment variable changes" the tool the user's node runs.
   - The command line is an executable target that tests can't import. So every order the spec tests through the
     start command (the S11 list first, the typed code before the journal entry, the fallback's conditions) is in
     `StartSequence`/`StopSequence`, and the tests drive those.
2. **ST-D2: The node's folders are fixed; the manager is checked, not trusted.**
   - Unit folder: always `<getpwuid home>/.config/systemd/user`.
     - `systemctl --user show-environment` is the environment the manager gives its units. Any worker sets it with
       `set-environment`. It isn't the manager's own lookup path, so it can't choose the folder.
   - After `daemon-reload`, `start` runs `/usr/bin/systemctl --user show vibeswitcher-node -p
     FragmentPath,DropInPaths,ExecStart,ExecStartPre,ExecStartPost,ExecStopPost,Environment,UnsetEnvironment,Restart,KillMode,NeedDaemonReload`.
     It refuses, naming the field, unless `FragmentPath` is the file it wrote, `DropInPaths` is empty, and every other
     value matches `NodeUnit`. Drop-ins anywhere (the unit's `.d/`, the top-level `service.d/`,
     `~/.local/share/systemd/user`, `~/.config/systemd/user.control`, `/run/user/<uid>/systemd/{transient,user.control}`)
     show in `DropInPaths`. A unit file that shadows ours shows in `FragmentPath`.
     - *2026-11-16, the review of S2:* a `vibeswitcher-node.service.wants/`, `.requires/` or `.upholds/` link in any of
       those folders adds a dependency, not a drop-in: `DropInPaths` stays empty, and the linked unit starts with the
       node's, between start's last check and the host's exec. And a unit file put in place of start's between its
       rename and the reload passes the eleven properties with a directive they don't hold. So the `-p` list is
       `NodeUnit.showProperties`: the eleven, then `Type`, `StandardInput`, `EnvironmentFiles`, `PassEnvironment`,
       `ExecCondition`, `ExecStop`, `ExecReload`, `RootDirectory`, `RootImage`, `BindPaths`, `BindReadOnlyPaths`,
       `ExecSearchPath`, `WorkingDirectory`, `UMask`, and the dependencies that start another unit (`Wants`,
       `Requires`, `Requisite`, `BindsTo`, `Upholds`, `OnSuccess`, `OnFailure`), each empty or start's value, except
       `Requires` (only the slice and `basic.target`), `WorkingDirectory` (the home, `!<home>` as a user unit's
       default) and `UMask` (other users' write masked): `NodeUnit.defaultsMismatch`, from a read of
       `systemctl --user show dbus.service` (2026-11-16). `LoadCredential` and `SetCredential` print `[unprintable]`
       whether empty or not, so they aren't asked. A unit replaced with a directive outside the list still passes: only
       the host's own check of its environment, the item for the lead under S2, closes that. *For S9:* the real unit's
       `show` is the first measurement of these defaults on the user's node; a refusal there names the property.
   - `start` refuses while the manager's environment holds any name outside `NodeFacts.expectedManagerEnvironment`
     (`NodeFacts.extraVariables`). Today `start` only names them. `GIT_CONFIG_*`, `GIT_EXEC_PATH` and the like aren't
     in `UnsetEnvironment=`, and the host runs git. The refusal names each variable and says how to clear it:
     `systemctl --user unset-environment NAME`, and look in `~/.config/environment.d`. A manager `XDG_CONFIG_HOME` is
     refused this way too. *A change to the spec's "names anything extra".*
     - *The lead, 2026-11-16, measured here (names only, `systemctl --user show-environment`):* the manager holds
       `QT_ACCESSIBILITY`, `GSM_SKIP_SSH_AGENT_WORKAROUND` and `SSH_AUTH_SOCK` beyond the expected set. The first two
       are a desktop session's (gnome-keyring's start) and change nothing the host or a session runs: they join
       `expectedManagerEnvironment`, each with that basis in its comment. `SSH_AUTH_SOCK` (an agent socket, D9) joins the
       unit's `UnsetEnvironment=` (and `noNameIsBothUnsetAndAssigned` still holds), so the host never inherits it, and
       is then not refused. Every other extra name is refused as above.
   - The mode (ST-D6) comes from what a same-uid process can't change: `/run/systemd/system` exists and
     `/proc/1/comm` is `systemd`. On such a machine a missing `/run/user/<uid>/systemd/private` is refused ("the user
     manager's socket is missing"), never taken as "no systemd".
   - The command line's own `XDG_CONFIG_HOME` and `XDG_RUNTIME_DIR` are ignored. *A change to the spec's
     "`$XDG_CONFIG_HOME`"* (the spec's test defence through `XDG_CONFIG_HOME` becomes the in-process parameters).
   - Defence in depth for tests: `ScratchNode.environment` sets both to scratch folders. `scripts/test.sh` is not
     edited: it is shared with `main` and a sensitive path.
3. **ST-D3: Which build `start` starts; only `switch` and `rollback` change it.**
   - In node mode, `start` and the `stop` fallback first require the command line to run from an installed build. It
     resolves `/proc/self/exe` with `realpath` and requires `<prefix>/<40 hex>/bin/vibeswitcher`, whose `build-info`
     commit equals the folder's name, and whose own hash matches `build-info`'s `vibeswitcher` entry. Otherwise it
     refuses before any write or call: "start runs only from an installed build".
   - **With no unit file**, `start` starts the command line's own installed build. `vs` is `current/bin/vibeswitcher`,
     so the first `vs start` starts `current`.
   - **With a unit file**, `start` starts the commit its `ExecStart` names. It requires that `ExecStart` has exactly
     `NodeUnit.execStart`'s form, with a 40-hex commit whose folder is a direct child of the prefix (by `realpath`),
     and that folder's `bin` matching its `build-info`. It then rewrites the whole unit from `NodeUnit.text` for that
     commit, which restores every other line. It refuses otherwise, naming what failed, and says that removing the
     unit file lets `start` run `current`.
   - The spec's "a moved link changes nothing until the user switches" holds. An install moves `current`, but the next
     `start` (after a crash, say) still starts the unit's commit. When `current` names another commit, the confirmation
     says so: "the unit runs X; current is Y (installed later): `vs switch Y` runs it".
   - A successful switch or rollback rewrites `ExecStart` and moves `current` to the target (S8c).
4. **ST-D4: The unit's values.** Exactly the spec's lines (`ExecStart`, `Restart=no`, `KillMode=control-group`,
   `UnsetEnvironment=`, `Environment=SWIFT_BACKTRACE=enable=no`, `Environment="HOME=…"`, `Environment="PATH=…"`),
   plus:
   - `[Unit] Description=VibeSwitcher node`, `Type=simple` and `TimeoutStopSec=45`. The server's `stop` waits 30 s for
     sessions, then the shutdown follows.
   - `[Install] WantedBy=default.target`, used only by `start --at-login`. That runs `enable` before `start`. A plain
     `start` never enables, and says when the unit is found enabled.
   - **The swift and node folders come from fixed places, never from the shell's PATH.**
     - swift: `<home>/.local/share/swiftly/bin`, which must hold `swift`.
     - node: the one `<home>/.nvm/versions/node/v*/bin` that holds `node`. With more than one, `start --node-version
       vX.Y.Z` picks it, a flag the user types. With an existing unit, its node folder is kept unless the flag is
       given.
     - Each must be absolute and existing, owned by the user, and writable by nobody else. Every folder from it up to
       the home must be the same. No folder may be under `/mnt/`. They are printed in the confirmation.
   - Every path written into the unit is refused, naming it, if it holds `%`, `"`, `\`, `$`, whitespace or a control
     character. systemd expands `%` specifiers and splits on spaces.
5. **ST-D5: Order and typed codes of `start`** (`StartSequence.run`).
   1. Arguments.
   2. The interop refusal (`StartCheck`).
   3. The facts. The mode (ST-D2). In node mode, the installed-build check (ST-D3) and the manager-variable refusal.
   4. If a server answers and passes `ServerCheck`: today's "the node runs".
   5. Otherwise, the first time: the S11 list and its acknowledgment (its own code, then the `not-promised-ack` journal
      entry, as today).
   6. The preflight (claude, swift, node, root-owned git).
   7. The confirmation (`NodeTexts.start`): the unit's key lines, the commit (and `current`'s when it differs), the
      `KillMode` consequence in the spec's words, and the folders.
   8. The command line's own code (EN-D5 "own").
   9. The journal entry `NodeJournal.entry(event: "start", action:)`, so `status` doesn't show the user's own start as
      unexplained (`NodeJournal.unexplained`: an own `start` event at most 120 s before the job's).
      *2026-11-16, the review of S2:* written by the starter, after its checks in step 10 and before `enable` and
      `start`, so a refused start leaves no entry.
   10. Write the unit, `daemon-reload`, the `show` check (ST-D2), `enable` (only with `--at-login`), `start`, then wait
       for the server.

   This moves the acknowledgment from after a server answers to before anything is started (the spec's "the first
   time … before anything"). A running node's `start` keeps acknowledging after its answer, as today.
6. **ST-D6: The detached start (a machine with no systemd).**
   - Taken only where ST-D2's facts say pid 1 isn't systemd.
   - `Platform.Spawn` with `.ownSession` (`posix_spawn` `SETSID`), not a double fork. The spawning process is
     multithreaded, and a spawn is the safe form of the same. The host is the spawner's child until the command line
     exits, and then init's. The spawn names `keep` (`CloseOnExecLintTests`).
   - Its environment is exactly `HOME`, the unit's `PATH` and `SWIFT_BACKTRACE=enable=no`. Nothing comes from the
     user's shell (`LD_PRELOAD` from an edited `.bashrc` included).
   - stdin `/dev/null`; stdout and stderr appended to `<root>/v2/host.log` (0600, opened with `O_NOFOLLOW`). The host
     opens its terminals with `O_NOCTTY`, checked by the test (`tty_nr` 0).
   - The record `<root>/v2/node.pid` holds format 1 JSON: `pid` and `startTicks` (`Platform.Processes.token`), written
     0600 with `O_NOFOLLOW`.
   - `NodeCheck` gains `.detached(record:)`: no cgroup line. The parent is the recorded pid, honoured only while its
     `startTicks` match, its `/proc/<pid>/cmdline` has the installed host's form (ST-D7), and it is non-dumpable. The
     same session (the sweep's rule).
   - `status` says "no systemd: the weaker voice rule; the node's pid file is yours, and any worker's, to write".
7. **ST-D7: `stop` with no server** (`StopSequence.run`).
   - It falls back when no server answers (`.notRunning`), when a listener sends no hello within `NodeClient`'s
     timeout, and when a listener fails `ServerCheck`. Each is safe: `systemctl stop` acts on the unit, not on the
     listener.
   - Order: the installed-build check (ST-D3); the typed code first, as today; then
     `NodeJournal.entry(event: "stop", action:)`; then the stop.
   - Node mode runs `/usr/bin/systemctl --user stop vibeswitcher-node` and waits up to `TimeoutStopSec` + 15 s.
   - Detached mode signals the recorded host only if all of these hold:
     - its `startTicks` match;
     - its `/proc/<pid>/cmdline` is `<prefix>/<40 hex>/bin/vibeswitcher-host --node --node-root <prefix>/<same> …`;
     - it is non-dumpable.

     The confirmation shows the pid and the command line. Otherwise: "the recorded pid now names another process;
     nothing ended". It sends SIGTERM, waits 30 s, then SIGKILL. It reaps the host when it is its own child (a test).
8. **ST-D8: `install-node.sh` takes flags, never environment variables.**
   - `--prefix DIR` defaults to `<getent passwd home>/.vibeswitcher/v2/builds`. `--repo DIR` (only for the
     dirty-tree courtesy check) defaults to the current folder's top level. `--toolchain DIR` defaults to
     `/opt/swift-6.4.2` and is always checked.
   - Test-only: `--gh PATH`, `--test-origin URL` and `--test-products DIR`. `--test-products` copies built products
     instead of building, skipping the toolchain and the build; `DIR/swift-version` stands for `swift --version`'s
     output. All three are refused unless `--prefix` is given, and its `realpath` and device/inode differ from the
     account's default prefix, and it isn't inside `<home>/.vibeswitcher`.
   - A worker can't make the user type a flag, and the user runs the script by its absolute path.
   - Order: arguments; dirty tree (a courtesy); the toolchain; the fresh fetch; provenance (ST-D9); ancestry and CI
     (ST-D10); the checkout; the build; the link check (ST-D12); the layout. Every local refusal comes before any
     network call, and every refusal before any build.
9. **ST-D9: What the install trusts, and which copy of the script runs.**
   - **Nothing in `--repo` is trusted.** The script makes a fresh `git init` in a scratch folder. It fetches `<SHA>`
     and `refs/heads/v2` from the constant `https://github.com/<R>.git`, never from `origin`. Objects fetched by hash
     are verified by git, so a replace ref, graft, alternate, hook, filter or config in the user's clone plays no
     part.
   - Every git runs as `/usr/bin/env -i HOME=<scratch> PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1
     GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 /usr/bin/git -c core.hooksPath=/dev/null -c
     core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always`. `--test-origin` adds
     `protocol.file.allow=always`, and only then. If the repository is private, the fetch authenticates through `-c
     credential.helper= -c 'credential.helper=!/usr/bin/gh auth git-credential'` under ST-D10's gh environment.
   - **Before it sources anything**, the script checks its own bytes and those of `lib/scratch.sh` and
     `lib/swift-jobs.sh` beside it against `git cat-file blob` of the expected commit from that fetch:
     - On the first install (no `<prefix>/current`), the expected commit is `<SHA>`. So the first run is vouched for by
       CI and the clean commit, not by the working copy.
     - Once `<prefix>/current` exists, the script refuses to run from any path but
       `<prefix>/current/Resources/install-node.sh` (`realpath`). The expected commit is the one `current/build-info`
       names, fetched by hash too.

     It then sources the verified blobs, written into its 0700 scratch folder, never the files beside it.
   - A change to the script takes effect one install later: say so in its header.
   - The dirty-tree check of `--repo` stays, as a courtesy that catches an install of a commit the user meant to amend.
   - The agent runs installs. D14 doesn't deny it, and M7 switches to "a commit the agent installed".
   - Residual (S11): a first install run from a working copy a worker changed runs that worker's script, which can
     skip any check. Before step 10 no team runs, and after it the installed copy runs. Say so in S11.
10. **ST-D10: "Both runners passed", through GitHub's API.**
    - The token is read once with `/usr/bin/env -i HOME=<home> PATH=/usr/bin:/bin /usr/bin/gh auth token -h
      github.com`, a local read with no network call.
    - Every API call runs as `/usr/bin/env -i HOME=<scratch> PATH=/usr/bin:/bin GH_CONFIG_DIR=<scratch>/gh
      GH_TOKEN=<that token> /usr/bin/gh …`. The user's `~/.config/gh/config.yml` (`http_unix_socket` and the like),
      `HTTPS_PROXY`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `GH_HOST`, `GH_REPO` and `GITHUB_TOKEN` play no part.
    - The repository is a constant in the script (today's `origin`), never read from `origin`'s URL.
    - `gh api repos/<R>/compare/<SHA>...v2` must say `identical` or `ahead`. `git merge-base --is-ancestor <SHA>
      FETCH_HEAD(v2)` in the fresh clone is checked too.
    - `gh run list -R <R> --commit <SHA> --json
      databaseId,createdAt,workflowName,headSha,status,conclusion,attempt,event`, read by `/usr/bin/jq`. For each of
      `v2 linux` and `v2 macos`, the run with the highest `databaseId` on that head (event `push` or
      `workflow_dispatch`) must be `completed`/`success`. A re-run updates its run in place, so its latest attempt is
      what counts. A `cancelled` run, a missing workflow, or an older success under a newer failure is refused.
    - **M2's token must carry Actions: read** (and Contents: read for the fetch). S4c adds that to M2's text in the
      bootstrap path.
11. **ST-D11: The build's environment.**
    - `scratch_tmpdir install-node` makes `$tool_scratch` and sets `TMPDIR` (the helper alone does). The build runs
      as
      `"$src/Resources/bin/vs-heavy" --as scripts/install-node.sh /usr/bin/env -u NAME… HOME="$tool_scratch/home"
      PATH="<toolchain>/usr/bin:/usr/bin:/bin" /bin/bash -c '"$0" build … -j "$VS_HEAVY_CORES"' "<toolchain>/usr/bin/swift"`.
      - `vs-heavy` is the fetched commit's, never the working copy's. It runs outside `env`, so it sees the run's
        `VIBESWITCHER_TEST_LOCK*` and doesn't take a second slot under a holder (the gated case runs under `vs-heavy`
        already).
      - The `-u` list is every name `compgen -e` gives, minus `TMPDIR`, `VIBESWITCHER_TEST_LOCK*` and
        `VS_HEAVY_CORES`. `-j` is read inside the wrapped command, after `vs-heavy` sets `VS_HEAVY_CORES`.
      - The scratch `HOME` makes `~/.swiftpm`'s configuration, security and SDK folders and
        `~/.cache/org.swift.swiftpm` fresh at once.
    - The flags: `build -c release --build-system native --static-swift-stdlib --disable-local-rpath -Xswiftc
      -no-toolchain-stdlib-rpath --only-use-versions-from-resolved-file`, with `--scratch-path`, `--cache-path`,
      `--config-path` and `--security-path` in `$tool_scratch`. All of them are in swiftly's 6.4.2 `swift build
      --help` (checked 2026-11-16). The products are found with `swift build --show-bin-path` and the same flags.
    - The toolchain must report the commit's `.swift-version` (6.4.2).
    - **Why not musl.** The musl SDK is installed here, but under `~/.swiftpm/swift-sdks`: user-writable, and hidden by
      the build's scratch `HOME`. Using it would need a root copy in M3, and the design's risk table puts it after the
      bootstrap.
12. **ST-D12: The linked-library check, and how S9's maps test is met.** Every command runs under `env -i`.
    - `readelf -l`: the interpreter is exactly `/lib64/ld-linux-x86-64.so.2`, checked before anything is resolved.
    - `readelf -d`: no `RPATH`, `RUNPATH`, `DT_AUDIT` or `DT_DEPAUDIT`, and no `NEEDED` entry containing `/`.
    - The `NEEDED` set is exactly `libc.so.6`, `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1` and
      `ld-linux-x86-64.so.2`. This is what `swift_static/linux/static-stdlib-args.lnk` links dynamically (`-ldl
      -lpthread -lstdc++ -lm`, with libdl and libpthread inside libc since glibc 2.34). S4c's spike confirms or
      corrects the set.
    - Each is resolved with `/lib64/ld-linux-x86-64.so.2 --list` (never `ldd`, which runs the binary's own
      `PT_INTERP`), and must be a file whose every folder up to `/` is owned by root and writable by nobody else.
    - The toolchain (when built from): `find <toolchain> \( ! -user root -o \( ! -type l -perm /022 \) \) -print -quit`
      prints nothing. Links are left out of the mode test because a link's mode is always 0777.
    - `/proc/<pid>/maps` of a non-dumpable process is refused to the same uid, so the host, the server and the parsers
      can't be read that way. The test reads the maps of:
      - the installed host image, through a scratch host with `--test-stays-dumpable`;
      - a session launcher, the host's own sealed copy, held dumpable by `--launcher-test-hold`. It stands for the
        parsers, which run the same copy;
      - `vibeswitcher-mcp`, waiting on stdin.

      Each line names a file in a root-owned folder, or is one of `[heap]`, `[stack]`, `[vdso]`, `[vvar]`,
      `[vsyscall]`, an anonymous mapping, or `/memfd:… (deleted)`.
    - The server is covered by `readelf` and the resolution only. The refusal of its maps is measured and recorded in
      the inventory.
    - *A change to S9's test text*, recorded in the security document by S4c.
13. **ST-D13: `build-info` is written by `vibeswitcher install-record`.** A subcommand not in the usage text, run from
    the just-built binary:
    - `install-record FOLDER --commit C --swift-version-output F --resolved PATH`, where `F` holds the toolchain's
      `swift --version` output and `PATH` is the commit's `Package.resolved`.
    - It hashes every entry in `FOLDER/bin` with `BuildInfo.sha256(of:)`, as `BuildInfo`'s format says ("one entry per
      file in that build's `bin/`"). It refuses an entry that isn't a regular file, and a folder whose name isn't `C`.
      It writes `BuildInfo.encoded`.
    - The script requires `bin/` to hold exactly `BuildRecord.installedNames`. The cli is recorded under its installed
      name, `vibeswitcher`.
    - `Resources/` isn't hashed: the seal watches the builds folder, and ST-D9 checks the script's bytes against git.
    - `ScratchBuilds` keeps its `vibeswitcher-cli` name: its layout is a scratch one, and `BuildRecord` records
      whatever regular files `bin/` holds.
14. **ST-D14: The install record and `rollback`.**
    - The script appends `<commit> <ISO time>` to `<prefix>/installs`.
    - The server reads `<installRoot>/installs` and gives, in `status`, the rollback target: the commit installed
      before the running build's commit. The command line shows that commit and its `installs` line in `rollback`'s
      confirmation, since that file is any worker's to edit. `rollback` then sends `build.switch` with that `commit`.
      It refuses when there is none.
    - Both the record and `current` are in the watched builds folder.
15. **ST-D15: The rule on switches stays, though stage 2's Task 3b measurement passed (inventory, 2026-11-13).** Stage
    2's 9d review kept the server's 30 s idle bound on the grounds that no switch happens while a worker or verifier
    runs, and it left counting in-flight requests in `HostServer.handle` to after the bootstrap. The refusal names
    decision 6. It is lifted after the bootstrap together with the in-flight count. S8's "until measured" is reworded by
    S8b of this plan to say so.
16. **ST-D16: A worker started by a pre-switch lead runs the old build's tool server.**
    - `LeadToolset` names its own path for workers and verifiers (`LeadToolset.swift:2513-2517`). With ST-D15 no worker
      runs at a switch, but the lead may stay.
    - Accepted and said: a team keeps its build until its lead restarts.
    - `aToolServerStartedAfterASwitchIsTheNewBuilds` covers a lead started after the switch. A companion case asserts
      that the pre-switch lead's new worker names the old commit, and `switch`'s confirmation says so.
17. **ST-D17: `hooks.install` writes the server's own home, sealed, with only the build's programs.**
    - Args: `agents`, a list of `claude` and `codex`. The CLI with no `--agent` sends both, in one request with one
      code (today's CLI installs both).
    - The server opens each of `<node-root>/bin/vibeswitcher-hook` and `vibeswitcher-mcp` once (`O_NOFOLLOW`, a
      regular file) and hashes the bytes it read. It refuses unless the hash equals the `binaries` entry of the
      `build-info` the host loaded at its start, which the host passes in `HostNotes.binaries` (S5). A worker can
      rewrite the `build-info` on disk too, so the copy on disk isn't asked.
    - It writes those bytes to temporaries made beside `<home>/.vibeswitcher/bin` and renames them in. It writes
      `HookInstaller.configURL(for:home:)` under its own home (`getpwuid` on the node; the scratch home on a scratch
      node).
    - All of it runs inside `link.vault.appWrite`, then `sealAppWrites()`. `appWrite` matches paths by text against
      `ConfigSeal.homeWatched(home:)`, so the paths are passed as it spells them: `<home>/.vibeswitcher/bin/…` and
      `<home>/.claude/settings.json`, never `VibePaths.binDir` (on a scratch node that is `<root>/bin`, reached through
      the `<home>/.vibeswitcher` link).
    - The command line no longer writes locally, and its `CLAUDE_CONFIG_DIR` is ignored.
    - Harnesses that prepare a real-agent folder (E9 Step 2, S10) write its hooks with
      `HookInstaller.install(agent:at:hookBinary:)` directly.
18. **ST-D18: The seal reads large folders by their metadata.**
    - A new `Watched.Kind.listing` hashes each entry's relative name, type, mode, size, inode, `ctime` with
      nanoseconds, and a link's target. It never reads contents. A write changes `ctime`, which the user can't set.
    - It has no entry cap. Its largest item here is node's version folder at about 12,000 entries, and the read is
      metadata only. `maxEntries` stays for `.folder` (the Mac's behaviour doesn't change).
    - It is used for `~/.local/share/claude/versions`, `~/.local/share/swiftly/toolchains`,
      `~/.local/share/swiftly/bin`, node's version folder, `~/.local/bin`, `~/.config/gh` (its token file is never
      read) and `~/.vibeswitcher/v2/builds`. Reading their contents would be about 3.5 GB at every look.
    - The case and its one read branch are an edit outside the eight kinds, **approved by the lead** (port-map row).
19. **ST-D19: Folders that change with every session.**
    - A role's start writes `~/.vibeswitcher/lead/run/<key>/<name>`. Each Claude Code session writes a shell snapshot
      into `<config>/shell-snapshots`. Watched as plain folders, either could hold every team at each worker's start.
    - S7 first measures this on a scratch node: `aWorkersStartDoesNotHoldItsTeam`. For the measurement to see it,
      `Tests/VibeNodeTests/FakeClaude.swift` writes `<config>/shell-snapshots/snapshot-bash-<ms>-<random>.sh` at its
      start, as Claude Code does.
    - If the measurement holds the team, those folders take `.entries`: an added or removed entry is no change; an
      entry changed or replaced in place is. Its per-entry hashes go through the vault's existing `keyHashes`, and
      `judge` counts only changed keys. That is a lead-approved edit to `LeadVault.judge`, logged.
    - The real Claude Code is checked once, at M8's first lead (S9's "Prepared for M8").
20. **ST-D20: Entries outside the home.**
    - While `/mnt/c` is a 9p or drvfs mount, the list adds `/mnt/c/Users/<u>/.wslconfig` and
      `/mnt/c/Users/<u>/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup`, for each `<u>` but `Public`,
      `Default` and `All Users`.
    - `/run/user/<uid>/systemd/transient` and `/run/user/<uid>/systemd/user.control` (drop-ins of the highest
      priority) are watched too.
    - `ConfigSeal.isHome(key:)` accepts names starting `/mnt/` and `/run/user/`: one line, lead-approved.
    - After M5 there is no `/mnt/c` mount, so those entries matter only if the user keeps automount on (D2's
      otherwise).
21. **ST-D21: Step 9's run.**
    - `merge_policy: ask_sensitive` with `sensitive_paths: src/**`, which the goal's change touches. The run then
      answers two cards from the command line: the lead's question, and the merge approval
      (`LeadWorkflow.approval(of:)`). That is the bootstrap's own path.
    - Workers run on Sonnet. `verifier_model: haiku` meets the floor's `verifierDifferent`, and `audit_finders: 1`.
    - The real-claude script adds `--model sonnet` only when its arguments carry no `--model`.
    - `noLoadHold(maxSessions: 4)`; the suite's own `.timeLimit(.minutes(60))`.
    - `test_command: sh ./check.sh`, committed in the scratch repository. It runs on the lead tool server's
      `PATH=/usr/bin:/bin`.
    - First, an ungated rehearsal with `FakeClaude` (S10 Step 1) proves the harness, the verdict and the merge. Then at
      most three gated runs, each on the user's go-ahead, after E9 Step 2 has passed.
22. **ST-D22: The WSL measurement (M7) is of the host, then of a session at M8.**
    - Under D14 the agent can't run `vs lead`, and the host spawns nothing on the real node without a lead. So M7
      checks that the host's and the server's start times are unchanged, and that the journal shows no stop, across
      10 minutes with every WSL window closed.
    - The "a session still live" half is checked once, after M8's first lead, the same way.
23. **ST-D23: A switch, a rollback and an install leave the seal holding every team until `config accept`.**
    - Each one changes `current`, `installs` or the builds folder (all in the watched builds folder). A switch and a
      rollback also rewrite the unit (in the watched `~/.config/systemd/user`). A handover keeps the vault, so its
      next look holds these changes.
    - Accepted and said: `switch`'s and `rollback`'s confirmations say so, the install prints it at its end, and S9's
      card runs `config held`/`accept` after each.
    - The command line's writes can't be sealed as the app's: only the server is the vault's app, and the follow-up
      runs after the server's reply.
24. **ST-D24: The host's start line counts only from the host.** Every session is in the unit's cgroup, so `logger -t
    vibeswitcher-host …` from a worker lands under `-u vibeswitcher-node` too. `NodeJournal` takes a start line only
    when journald's trusted `_PID` equals the unit's `ExecMainPID` (`systemctl --user show -p ExecMainPID`) and
    `_TRANSPORT` is `stdout`. A handover keeps the pid. Lines from an earlier invocation are shown as "not checked".
    A process that inherited the host's stderr would pass. `CloseOnExecLintTests` keeps that fd out of sessions.

## Review Focus

1. **Nothing in a test, and no environment variable, reaches the user's node.**
   - Node-mode tools and folders are constants or come from `getpwuid` and fixed places. The manager's environment
     is refused when it holds anything extra, never trusted (ST-D2, ST-D4).
   - In node mode, nothing is written or called before the installed-build check (ST-D3).
   - Scratch mode never writes a unit and never asks a `systemctl` for more than its stand-in's `show-environment`.
   - No test starts a `--node` host, writes outside its scratch folder, or writes to the real journal (the journal
     writer is a parameter).
2. **The unit is what the spec says, and what the manager runs.**
   - `Restart=no`, `KillMode=control-group` with its consequence shown, and `TimeoutStopSec`.
   - `UnsetEnvironment=` and `Environment=` name disjoint sets.
   - `PATH` and `HOME` are quoted, with no `/mnt/`.
   - `ExecStart` names the commit's folder, never `current`. No unescaped `%`, quote or space reaches the file.
   - After `daemon-reload`, `FragmentPath` is the file written and there is no drop-in (ST-D2).
3. **An install is only ever of a clean, CI-passed commit, and trusts nothing in the user's clone.**
   - Fetched by hash from the constant URL; git and gh under `env -i`; the script's own bytes checked before
     anything is sourced (ST-D9, ST-D10).
   - Built from a root-owned toolchain with fresh caches; links nothing from a folder the user can write; no
     `RUNPATH`; the interpreter and `NEEDED` set exact (ST-D12).
   - The folder name equals `build-info`'s commit, and no `.git` lies under the prefix.
   - Every refusal comes before any build.
4. **Every new state change takes the user's voice and the typed code.**
   - The new state changes: `start` of a stopped node, the `stop` fallback, `hooks.install`/`remove` and
     `build.switch`. Each has a no-terminal case where nothing is written or called.
   - `hooks` writes go through `appWrite` and nothing else, and install only bytes the host's `build-info` names.
   - A switch is refused while a worker or verifier is live, and its reply reaches the command line before the server
     is replaced. The follow-up checks the target and the host before it rewrites anything.
5. **The Mac doesn't change.** Every shared-file edit is in [Non-seam edits](#non-seam-edits-this-plan-makes):
   - `LinuxSealList` is empty there;
   - `ServerBuild` still reads the app bundle, and the gate's text is today's;
   - `HostNotes.build` and `binaries` are optional;
   - the host's start line is Linux only.

   Each has a Mac test.

## Module structure

```
Sources/VibeNode/Start/
  StartRefusal.swift      S1  the refusal every Start type gives: text, Equatable
  NodeUnit.swift          S1  the unit's text from Inputs; parse back; disjointness; path refusals
  StartPreflight.swift    S1  claude resolves, swift and node in the unit's folders, root-owned git
  NodeFolders.swift       S1  the unit folder, the mode, the tool folders, the installed build, the unit's build
  StartSequence.swift     S2  ST-D5's order, with every step injected
  NodeStarter.swift       S2  systemd path: write, daemon-reload, show check, [enable], start, wait; detached path (S3)
  NodeTexts.swift         S2  the confirmations: start (S2), stop (S3), switch and rollback (S8a)
  NodeRecord.swift        S3  <root>/v2/node.pid (format 1): pid, startTicks
  StopSequence.swift      S3  ST-D7's order, with every step injected
  NodeStopper.swift       S3  the stop fallback's two forms
  BuildRecord.swift       S4a install-record: hashes, build-info
  SwitchPlan.swift        S8a already / not installed / refused (D6) / hand over
  SwitchFollowUp.swift    S8a check the target, rewrite ExecStart, daemon-reload, move current
Sources/VibeNode/Server/
  HooksRequest.swift      S6  hooks.install / hooks.remove
  SwitchRequest.swift     S8b build.switch: the rule, the handover through the connector, the outcome
Sources/VibeCore/V2/
  ServerBuildLinux.swift  S5  ServerBuild from build-info two folders up from the resolved executable
  LinuxSealList.swift     S7  the platform's extra watched things (empty on the Mac)
Sources/VibeHost/V2/
  HostStartLine.swift     S5  the host's start line to stderr: pid, commit, SWIFT_BACKTRACE; its build-info's binaries
scripts/install-node.sh   S4b
```

`TypedWord.Outcome` moves from `Sources/vibeswitcher-cli/TypedWord.swift` to `VibeNode` as `public enum TypedOutcome
{ typed, wrong, noTerminal }` (S2), so the sequences can take the asker as `() -> TypedOutcome`.

## Non-seam edits this plan makes

| File | What | Kind | Task |
| --- | --- | --- | --- |
| `Sources/VibeCore/LeadGateBuild.swift` 44-54, `read(executable:)` | one hook: no app bundle and on Linux → `ServerBuildLinux.read(executable:)` | 4 | S5 |
| `Sources/VibeCore/LeadGateBuild.swift`, `GateLag.refusal` | one hook: on Linux the install instruction is `ServerBuildLinux.installHint` ("install it with install-node.sh, then `vs switch`") | 4 | S5 |
| `Sources/VibeCore/HostProtocol.swift`, `HostNotes` | `build: String?` and `binaries: [String: String]?`, from the `build-info` the host loaded | 6 | S5 |
| `Sources/VibeHost/HostServer.swift` (where notes are made) | one hook line filling both from `HostStartLine` | 4 | S5 |
| `Sources/vibeswitcher-host/main.swift` | one hook line after the start checks: `HostStartLine.say(config:)` (Linux only) | 4 | S5 |
| `Sources/VibeCore/ConfigSeal.swift`, `homeWatched(home:)` | one hook line appending `LinuxSealList.watched(home:uid:)` | 4 | S7 |
| `Sources/VibeCore/ConfigSeal.swift`, `Watched.Kind` and its read | `.listing` (ST-D18), and `.entries` if ST-D19's measurement needs it; one read branch each, into `LinuxSealList` | lead-approved | S7 |
| `Sources/VibeCore/ConfigSeal.swift`, `isHome(key:)` | names starting `/mnt/` and `/run/user/` (ST-D20) | lead-approved | S7 |
| `Sources/VibeCore/LeadVault.swift`, `judge` | only if ST-D19's measurement holds the team: `.entries` keys judged per entry | lead-approved | S7 |

The port map's rows 223 and 224 become `made`, and the new rows are added. `Package.swift` doesn't change.

---

### Task S1: The unit, the folders and the preflight

**Needs:** the engine sweep merged into `v2`.

**Files:**
- Create: `Sources/VibeNode/Start/StartRefusal.swift`, `NodeUnit.swift`, `StartPreflight.swift`, `NodeFolders.swift`
- Modify: `Tests/VibeNodeTests/StartCommandTests.swift` (new cases; the four existing ones are kept)

**Interfaces:**
- Consumes: `VoiceRule.nodeUnit` (`Voice.swift:153`), `NodePreflight.claudeLink(root:accountHome:)`,
  `Platform.Tools.git`, `NodeFacts.extraVariables(showEnvironment:)`, `BuildInfo.read(buildFolder:)`,
  `BuildInfo.sha256(of:)`.
- Produces:
  - `public struct StartRefusal: Error, Equatable, CustomStringConvertible { public let text: String }`.
  - `public struct NodeUnit: Equatable, Sendable`:
    - `struct Inputs { prefix: String; commit: String; home: String; swiftBin: String; nodeBin: String }`;
    - `static func text(_ inputs: Inputs) -> Result<String, StartRefusal>`;
    - `static func parse(_ text: String) -> [String: [String]]` (key → values, in order);
    - `static func inputs(parsing text: String, prefix: String) -> Result<Inputs, StartRefusal>` (the commit from
      `ExecStart` in exactly `execStart`'s form, 40 hex; the folders from `PATH`);
    - `static let unset = ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH", "GCONV_PATH", "BASH_ENV", "ENV",
      "VIBESWITCHER_HOME", "CFFIXED_USER_HOME"]`;
    - `static func path(swiftBin:nodeBin:) -> String` = `/usr/local/bin:/usr/bin:/bin:<swiftBin>:<nodeBin>`;
    - `static func execStart(prefix:commit:) -> [String]` = `[<p>/<c>/bin/vibeswitcher-host, --node, --node-root,
      <p>/<c>, --server, <p>/<c>/bin/vibeswitcher-server]`;
    - `static func expectedShow(_ inputs: Inputs, unitFile: String) -> [String: String]` (ST-D2's properties as
      `systemctl show` prints them);
    - `static let timeoutStop = 45`, `static let fileName = VoiceRule.nodeUnit`;
    - `static let killModeConsequence: String` (the spec's sentence).
  - `public enum NodeFolders`:
    - `unitFolder(accountHome:) -> String` = `<home>/.config/systemd/user`;
    - `runtimeFolder(uid:) -> String` = `/run/user/<uid>`;
    - `enum Mode { systemd; noSystemd; socketMissing }` and `mode(runtimeFolder:systemdSystem: String =
      "/run/systemd/system", initComm: String = "/proc/1/comm") -> Mode` (ST-D2);
    - `toolFolders(accountHome:nodeVersion:existingUnit:) -> Result<(swiftBin: String, nodeBin: String),
      StartRefusal>` (ST-D4);
    - `verifyBuild(folder:prefix:) -> Result<BuildInfo, StartRefusal>`: a direct child of `prefix` by `realpath`,
      named 40 hex, its commit, and every `bin/` entry matching `build-info`;
    - `installedBuild(executable:prefix:) -> Result<(commit: String, folder: String), StartRefusal>` (ST-D3);
    - `unitBuild(unitText:prefix:) -> Result<NodeUnit.Inputs, StartRefusal>` (ST-D3, through `verifyBuild`);
    - `managerRefusal(showEnvironment:) -> StartRefusal?` (ST-D2: each extra name, and how to clear it);
    - `defaultPrefix(accountHome:)` = `<home>/.vibeswitcher/v2/builds`.
  - `public struct StartPreflight`:
    - `init(claudeLink: String, swiftBin: String, nodeBin: String, git: String = Platform.Tools.git)`;
    - `func check() -> Result<Found, StartRefusal>`, with `Found { claude; swift; node; git }`. It looks only in the
      given folders, with no shell.

- [x] **Step 1: Failing tests** (in `StartCommandTests`, `linuxOnly` where they touch the file system):
  - `theUnitStartsTheCommitsFolderNotCurrent`: `ExecStart` is exactly `execStart(prefix:commit:)`. It holds `--node`,
    `--node-root <p>/<c>` and `--server <p>/<c>/bin/vibeswitcher-server`, and no `current`.
  - `theUnitIsRestartNoKillModeControlGroupWithATimeout`: `Restart=no`, `KillMode=control-group`,
    `TimeoutStopSec=45`, `Type=simple`, `WantedBy=default.target`.
  - `theUnitUnsetsTheListedNamesAndSetsBacktraceOff`: `UnsetEnvironment` equals `NodeUnit.unset`, and
    `Environment=SWIFT_BACKTRACE=enable=no` is present.
  - `noNameIsBothUnsetAndAssigned`: parse the written text. No name in any `UnsetEnvironment=` is assigned by any
    `Environment=`. It is shown failing on a mutant that adds `SWIFT_BACKTRACE` to `unset`.
  - `theUnitsPathIsQuotedAndHasNoMnt`: `Environment="PATH=…"` is quoted and equals `path(swiftBin:nodeBin:)`. A
    swift folder under `/mnt/c/…` is refused, naming it. `HOME` is quoted.
  - `aPathSystemdWouldExpandIsRefused`: a prefix with `%h`, a space, `"` or `$` is refused, naming the character.
  - `theUnitFolderIsTheAccountsWhateverTheEnvironmentSays`: `unitFolder` is `<home>/.config/systemd/user`. A
    `show-environment` text with `XDG_CONFIG_HOME=/tmp/x`, and the process's own `XDG_CONFIG_HOME`, change nothing.
  - `anExtraManagerVariableRefusesStart`: `managerRefusal` on a text with `GIT_CONFIG_GLOBAL` and `XDG_CONFIG_HOME`
    names both and `unset-environment`. The expected set gives nil.
  - `aMissingManagerSocketOnASystemdMachineRefusesNotDetaches`: with a scratch `systemdSystem` folder present and a
    scratch `initComm` file saying `systemd`, a runtime folder without `systemd/private` gives `.socketMissing`. With
    neither, `.noSystemd`. With both and the socket, `.systemd`.
  - `theToolFoldersComeFromFixedPlaces`: in a scratch home, swiftly's `bin` and the one nvm version are found, and a
    `PATH` in the environment plays no part. These are refused, each naming the folder: two node versions without
    `--node-version`; a folder writable by group or others; a folder owned by another uid (a stand-in for the check's
    `stat`); a relative or missing folder.
  - `aCommandLineOutsideAnInstallDoesntStartTheNode`: `installedBuild` refuses a `.build` executable, a folder whose
    name differs from its `build-info` commit, and a cli whose hash differs.
  - `theUnitsBuildIsCheckedBeforeItIsStarted`: `unitBuild` takes a unit S1 wrote. It refuses these, each naming what
    failed:
    - an `ExecStart` naming `../x` as its commit;
    - an `ExecStart` naming a folder outside the prefix;
    - an `ExecStart` with an extra argument;
    - a commit whose `bin/vibeswitcher-host` differs from its `build-info`.
  - `thePreflightNamesWhatIsMissing`: in a scratch folder, it refuses with "claude", then "swift in
    ~/.local/share/swiftly/bin", then "node", then "git in a folder only root can write". All present: `Found` holds
    the four absolute paths.
- [x] **Step 2: Implement.** `text` writes `[Unit]`, `[Service]` and `[Install]` in a fixed order, one assignment a line.
  `ExecStart` is space-joined with no quoting, after the refusal of unsafe characters (ST-D4). `parse` is a line reader
  for the tests, `unitBuild` and `SwitchFollowUp`. The ownership checks take `stat` as a parameter so a test can stand
  in for another uid.
- [x] **Step 3: Verify.**
  - `bash scripts/test.sh --filter StartCommandTests`
  - the lints (AGENTS.md's command)
  - `scripts/test-under-load.sh --load 24 -r 3 -f 'StartCommandTests'`
- [ ] **Step 4:** commit ("v2: the node's unit, its folders and start's preflight"). Push and both jobs green, by the
  lead.

  *2026-11-16, S1 as made (committed; the push is the lead's):*
  - `NodeUnit` is an `enum`, not a `struct`: it has no instances, only the unit's values. Callers write the same
    `NodeUnit.text(…)`.
  - The lead's ST-D2 measurement: `QT_ACCESSIBILITY` and `GSM_SKIP_SSH_AGENT_WORKAROUND` joined
    `NodeFacts.expectedManagerEnvironment`, with that basis in its comment. `SSH_AUTH_SOCK` joined `NodeUnit.unset` as
    `NodeUnit.unsetFromManager` (so `unset` is the spec's eight plus it), and `managerRefusal` leaves out only
    `unsetFromManager`. `status` still names `SSH_AUTH_SOCK` as beyond the expected (`NodeFacts.extraVariables` is
    unchanged).
  - Added beside the listed interface, for S2's `show` check: `NodeUnit.showProperties` (the `-p` list, in order),
    `NodeUnit.showMismatch(_:expected:)` (the first property that differs, both values said), and `NodeUnit.words(_:)`
    (a value's words, quotes dropped). `expectedShow`'s `ExecStart` is its first part, up to `ignore_errors=no ;`:
    systemd 255 here prints the last run's `start_time`, `pid` and status after it (read with
    `systemctl --user show dbus.service`, a read), so `showMismatch` compares it as a prefix. An empty command list
    (`ExecStartPre`) isn't printed at all; a property not printed counts as empty.
  - `NodeFolders.toolFolders` takes `uid:` and `status:` (the `lstat` stand-in, `NodeFolders.fileStatus`), and
    `NodeFolders.installedCLI` is `vibeswitcher` until S4a's `BuildRecord.installedNames`. An existing unit's node
    folder is kept only when it is `<home>/.nvm/versions/node/v…/bin`; `--node-version` must read `vX[.Y[.Z]]`.
  - The unit refuses `'` too (systemd reads single quotes in `ExecStart`), besides ST-D4's characters.
  - `StartCommandTests`'s suite-wide `linuxOnly` moved onto its four scratch-node cases and the file-system ones, so
    the Mac runs the pure cases.
  - The task's note: `ServerTests.statusThroughTheServerListsWhatTheProbeLists` copied `/bin/sleep` with
    `FileManager.copyItem` and exec'd it at once ("the fake agent never ran" under load: a child forked meanwhile held
    the copy open for writing, "Text file busy"). `FakeAgent`'s `copyClosedOnExec` is now `TestSupport.swift`'s, and
    that case uses it.
  - Verified: `StartCommandTests`, `ServerTests` and `StatusCommandTests` alone and under load (24, 3 runs), the
    lints, and `VibeNodeTests|VibeCoreTests|VibePlatformTests` under `vs-heavy`. That run's one other failure,
    `LoadHarnessTests.itsBuildRunsOnItsSlotsShareOfTheCores` (its `build-homes-…` folder gone), passed alone; S1
    touches nothing it runs.

  *2026-11-16, S1's review fixes (committed; the push is the lead's):*
  - `verifyBuild` refuses a commit folder that is a link (`lstat` a folder, and its own name the resolved one's): a
    link `<prefix>/A` to a sibling build `<prefix>/B` had B checked and A's name returned. `unitBuild` also requires
    the commit it verified to be the one the unit names. `theUnitsBuildIsCheckedBeforeItIsStarted` gains the sibling
    link.
  - `NodeUnit.pathRefusal` judges a path on its names: an empty name (`//`, a trailing `/`) is refused, and `/mnt`
    is the first name, so `//mnt/c/…` no longer passes (`theUnitsPathIsQuotedAndHasNoMnt`).
  - `unitBuild`'s doc says only its commit (and, through `toolFolders`, its node folder) is taken; S2 rebuilds the
    unit's `Inputs` from `getpwuid`'s home and `toolFolders`, never from the unit's own `HOME` or swift folder.
  - Added `NodeFolders.managerConfigRefusal(accountHome:)`: `~/.config/systemd/user.conf` or `user.conf.d/*.conf`
    setting `DefaultEnvironment=` or `ManagerEnvironment=` refuses start, naming the file
    (`aManagerConfigThatSetsAnEnvironmentRefusesStart`). The manager applies them at its next `daemon-reload` or
    login, past a `show-environment` read before.
  - `managerRefusal`'s doc states S2's contract (S2's steps below): run again on a fresh `show-environment` after
    start's own `daemon-reload`, right before `start`.
  - `StartCommandTests`' five unit cases moved into the security document's S9 `Held by:`.

**Done when:** the cases pass on Linux. The Mac runs the pure cases (unit text, parse, disjointness, refusals, the
manager refusal).

---

### Task S2: `start` through systemd

**Needs:** S1.

**Files:**
- Create: `Sources/VibeNode/Start/StartSequence.swift`, `NodeStarter.swift`, `NodeTexts.swift`
- Modify:
  - `Sources/vibeswitcher-cli/Start.swift`: it only wires `StartSequence`. In node mode it passes
    `NodeStarter.Tools.node`, `NodeJournal`'s writer and `TypedWord`. Scratch mode refuses.
  - `Sources/vibeswitcher-cli/TypedWord.swift`: it returns `TypedOutcome`.
  - `Sources/vibeswitcher-cli/main.swift`: usage `start [--interop-is-on] [--at-login] [--node-version vX.Y.Z]`.
  - `Tests/VibeNodeTests/ScratchNode.swift`: `environment` sets `XDG_RUNTIME_DIR` and `XDG_CONFIG_HOME` to scratch
    and drops `DBUS_SESSION_BUS_ADDRESS`.
  - `Tests/VibeNodeTests/StartCommandTests.swift`.

**Interfaces:**
- Consumes: S1; `NodeClient.connect(_:timeout:)` and `ServerCheck` (the CLI's probe); `Platform.Spawn` (the systemctl
  runs, bounded `waitpid`, never Foundation's `waitUntilExit`: the memory note on the Mac hang);
  `NodeJournal.entry(event:action:)`; `NodeJournal.unexplained(starts:entries:rule:)`.
- Produces:
  - `public enum TypedOutcome { typed, wrong, noTerminal }`.
  - `public struct NodeStarter`:
    - `struct Tools { systemctl: String; unitFolder: String; runtimeFolder: String }`;
    - `static func node(accountHome:uid:) -> Tools` (the constants; `systemctl` is always `/usr/bin/systemctl`);
    - `init(tools: Tools, listen: @escaping () -> Probe, now: @escaping () -> TimeInterval)` (an injected clock, as
      `NodeClock`'s `now`);
    - `func startUnit(_ unit: NodeUnit.Inputs, atLogin: Bool) -> Result<Started, StartRefusal>`: write, then
      `daemon-reload`, then the `show` check, then `enable` (only `atLogin`), then `start`, then the wait;
      - *2026-11-16, from S1's review:* after the `show` check and before `enable`/`start`, `startUnit` reads
        `show-environment` again and refuses on `NodeFolders.managerRefusal` (a `daemon-reload` applies `user.conf`'s
        `DefaultEnvironment=` and `environment.d`, so a name written after step 3 shows only now; a case for it, with
        the stand-in's second `show-environment` answer holding `GIT_CONFIG_GLOBAL`, and no `start` called). Step 3's
        facts also run `NodeFolders.managerConfigRefusal`. The `Inputs` passed are built from `getpwuid`'s home,
        `toolFolders` and the commit (`unitBuild`'s or `installedBuild`'s), never from an existing unit's `HOME` or
        swift folder.
      - *For the lead:* a `set-environment` between that read and `start` is still a race no `systemctl` read
        closes, and the unit started at login (`--at-login`) has no start check at all. Only the host started with
        `--node` can close both, by checking its own environment against `expectedManagerEnvironment` plus the
        unit's names before it runs git. No task of this plan does that yet.
    - `enum Probe { case listening, notYet, refusedByCheck(String), unitEnded(result: String) }`;
    - `static let listenLimit: TimeInterval = 180` (the app's `hostStartLimit`).
  - The CLI's probe: `NodeClient.connect` followed by `ServerCheck` gives `.listening` or `.refusedByCheck`. `/usr/bin/systemctl
    --user show -p ActiveState,Result --value vibeswitcher-node` giving `failed` or `inactive` gives `.unitEnded`.
    Anything else is `.notYet`.
  - `public struct StartSequence`:
    - `struct Steps` holding the closures `facts`, `installedBuild`, `serverAnswers`, `acknowledged`, `showList`,
      `typed: () -> TypedOutcome`, `confirm: (String) -> Void`, `journal: ([(name: String, value: String)]) -> Bool`
      (`NodeJournal.entry`'s fields; the CLI passes `NodeContext.writeJournal`),
      `existingUnit: () -> String?`, `preflight`, `starter: (NodeUnit.Inputs, Bool) -> Result<Started, StartRefusal>`;
    - `func run(_ arguments: StartArguments) -> Result<Outcome, StartRefusal>`, with `enum Outcome { running;
      started(commit) }`.
  - `NodeTexts.start(unit:current:previousCommit:folders:) -> String`. It shows `NodeUnit.killModeConsequence`, the
    unit's commit, `current` when it differs, the commit the unit named before, and the swift and node folders.

- [x] **Step 1: Failing tests** (`StartCommandTests`):
  - `startWritesTheUnitAndAsksTheManagerToStartIt`:
    - In-process `NodeStarter` with a scratch unit folder, a scratch runtime folder holding `systemd/private`, and a
      recording `systemctl` stand-in. The stand-in appends its arguments to a file, and answers `show` with
      `NodeUnit.expectedShow`.
    - The unit file equals `NodeUnit.text`.
    - The calls are exactly `--user daemon-reload`, then `--user show vibeswitcher-node -p …`, then `--user start
      vibeswitcher-node`.
  - `startAtLoginEnablesFirst`: the calls are `daemon-reload`, `show`, `enable vibeswitcher-node`, `start
    vibeswitcher-node`. A plain start never calls `enable`.
  - `aDropInMakesStartRefuse`: the stand-in answers `DropInPaths=<scratch>/vibeswitcher-node.service.d/x.conf`, and
    separately `ExecStartPre=…` and `UnsetEnvironment=` empty. Each refuses, naming the field, and no `start` is
    called.
  - `aManagerXdgConfigHomeDoesntMoveTheUnit`: the stand-in answers `FragmentPath=/tmp/x/systemd/user/…`. Start
    refuses, naming `FragmentPath`, and the unit was written only in the unit folder given.
  - `theInstalledCommandLineRunsUsrBinSystemctl`: `NodeStarter.node(…).systemctl == "/usr/bin/systemctl"`, whatever
    the environment holds (a test sets `PATH` and `XDG_*` to scratch values).
  - `aScratchNodeIsNotStartedByTheCommandLine`: `start --interop-is-on` against a scratch root with no server exits
    69 with "started by its harness". The stand-in records no `daemon-reload`, `enable`, `start` or `stop` (its
    `show-environment` call for the facts is expected), and no unit file is written.
  - The `HostClientSlowStartTests` port (row 99), on `NodeStarter` with `listen` stubs on an injected clock:
    - `aNodeThatTakesSecondsToListenIsWaitedFor`: `notYet` for 5 s, then `listening`, gives `.success`.
    - `aNodeThatEndsWithoutListeningIsFailed`: `unitEnded(result: "exit-code")` gives the refusal "the node didn't
      start (exit-code); see journalctl --user -u vibeswitcher-node".
    - `aListenerThatFailsTheServerCheckIsNotTheNodeStarting` (the node form of
      `anotherHostListeningIsConnectedToWhileOursStillStarts`): `refusedByCheck("not the unit's MainPID's child")`
      is waited past, not taken. At the limit the refusal names the check's reason.
    - `aNodeAlreadyRunningIsNotStartedAgain`: a server answering before the start; the CLI on a `ScratchNode` says
      "the node runs" and writes nothing.
    - `theWaitIsTheAppsHostStartLimit`: `listenLimit == 180`.
  - On `StartSequence` with recording stand-ins for every step:
    - `theS11ListComesBeforeAnythingIsStarted`: the `not-promised-ack` entry is recorded before the first `systemctl`
      call. With the acknowledgment's code wrong, nothing is called, written or recorded.
    - `startJournalsItsOwnStartBeforeTheManagerIsAsked`: the `start` entry is recorded after the typed code and before
      `daemon-reload`. Stamped as journald stamps a terminal scope's entry, and followed by a systemd `JOB_TYPE=start`
      event 2 s later, `NodeJournal.unexplained` is empty.
    - `aStartWithNoTerminalIsRefused`: `typed` gives `.noTerminal`. Nothing is written, called or recorded, and the
      refusal is `TypedWord`'s text.
    - `aCommandLineBuiltInDotBuildRefusesNodeModeBeforeAnyWrite`: `installedBuild` refuses. No step after it runs:
      no facts beyond the mode, no unit, no call, no entry.
    - `startStartsTheUnitsCommitNotCurrent`: with a unit naming `A` and `current` naming `B`, the starter gets `A`,
      and the confirmation names both and `vs switch B`.
  - `theStartConfirmationSaysWhatKillModeMeans`: `NodeTexts.start` holds `killModeConsequence`, the previous commit,
    and the swift and node folders.
  - The existing four cases still pass, `startPrintsTheNotPromisedListOnceAndRecordsTheAck` included (a running node
    still acknowledges after its answer).
- [x] **Step 2: Implement.**
  - `Start.swift` builds `StartSequence.Steps` from `NodeContext` and runs it. It holds no order of its own. Until S3,
    `NodeFolders.Mode.noSystemd` refuses ("no systemd: the detached start is S3's").
  - The unit is written to a temporary file in the unit folder, then renamed (0644). The folder is made 0755 if absent.
  - Every systemctl run is spawned with the bounded wait.
  - The S11 text is printed through `ConfigSeal.inert` where it echoes anything read.
- [x] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'StartCommandTests|ServerCheckTests|ScratchNodeTests'`
  - the lints
  - `scripts/test-under-load.sh --load 24 -r 3 -f 'StartCommandTests'`
- [ ] **Step 4:** commit ("v2: start writes the node's unit and starts it"). Push, both green.

  *2026-11-16, S2 as made (committed; the push is the lead's):*
  - **The order.** On the user's node the installed-build check comes right after the mode, before the facts and so
    before the interop refusal (ST-D5 put that second): the facts run `systemctl --user show-environment`, and the
    Review Focus's "nothing is written or called before the installed-build check" and
    `aCommandLineBuiltInDotBuildRefusesNodeModeBeforeAnyWrite`'s "no facts beyond the mode" hold only so. The
    manager-variable and manager-configuration refusals run only where `NodeFolders.mode` says `.systemd`; a
    machine without the manager's socket or without systemd is refused after the server is asked, so a running node
    still answers there.
  - **`StartSequence.Steps`** takes, beside the plan's list: `home` and `prefix` (values), `kind` (`.scratch` or
    `.node(NodeFolders.Mode)`), `managerEnvironment` (read once: the command line hands the same text to the facts),
    `managerConfig`, `unitBuild`, `current`, `toolFolders` and `newAction`, so every disk read is a step and the Mac
    runs the sequence's cases. `typed` takes `(code, what)` (two codes are asked: the acknowledgment's and the
    start's own). The plan's `confirm` is `say`: every line the sequence prints. `serverAnswers` gives
    `ServerAnswer { running, notRunning(why), refusedByCheck(why), failed(StartRefusal) }`; on the user's node
    `notRunning` and `refusedByCheck` go on to the start (the wait waits past a listener that fails the check), on a
    scratch node they're refused (69 with the client's "the node isn't running" and "started by its harness", which
    `ServerCheckTests.theCommandLineWithNoNodeSaysSoNotConnectionRefused` still finds; 77 for the check).
  - **`StartRefusal` gains `exitCode`** (77 by default; 69 a scratch node with no server; 1 an entry not written or a
    manager that didn't start the unit). `StartArguments` (`parse`, `usage`) is `VibeNode`'s. A running node's
    acknowledgment keeps today's exits (77 a code not typed, 1 an entry not written); a stopped node's start refuses
    when the journal can't be read (the record of the acknowledgment and of the start is there).
  - **`NodeStarter.startUnit`'s calls** are `daemon-reload`, `show vibeswitcher-node -p …`, then `show-environment`
    (the second read from S1's review), `enable` with `--at-login`, `start`; the tests assert exactly that.
    `awaitListening() -> StartRefusal?` is the wait on its own (nil once the server answers), which the
    `HostClientSlowStartTests` port drives with an injected clock and `pause`. `Started { commit, enabledAtLogin }`
    (enabled: the `default.target.wants` link, read, not asked). Every `systemctl` runs with
    `NodeStarter.environment(runtimeFolder:)` (`PATH=/usr/bin:/bin`, `XDG_RUNTIME_DIR=<runtime>`) and nothing of the
    command line's; the stand-in records that it saw no `DBUS_SESSION_BUS_ADDRESS`. `NodeStarter.run` is the bounded
    spawn (`Platform.Spawn`, `waitpid` with `WNOHANG`), and the command line's `NodeContext` runs every tool through
    it now (`runTool`, the user's node with that environment), in place of Foundation's `Process.waitUntilExit`.
  - **The command line's probe** reads `systemctl --user show -p ActiveState,Result vibeswitcher-node` by name, not
    with `--value` (values without names, in an order it doesn't rely on).
  - **`NodeTexts.start(unit:current:previousCommit:atLogin:)`**: the plan's `folders:` is the unit's own `swiftBin`
    and `nodeBin`; `atLogin` says whether it is enabled.
  - **`theInstalledCommandLineRunsUsrBinSystemctl`** doesn't set `PATH` or `XDG_*` in the test process (process-wide,
    racing the suite's other cases). It asserts `NodeStarter.node`'s constants and `environment(runtimeFolder:)`, and
    reads `Sources/VibeNode/Start` for `getenv`, `ProcessInfo` and `environ` outside comments and strings.
  - Added cases beside the plan's: `aManagerVariableThatShowsAfterTheReloadRefusesStart` (S1's review),
    `aRunningNodeIsNotStartedAndAcknowledgesAfterItsAnswer`, `aScratchNodeWithNoServerIsRefusedByTheSequence`,
    `theManagerAndTheMachineAreRefusedBeforeTheServerIsAsked`, `startArgumentsAreTheUsagesOnly`.
    `aNodeAlreadyRunningIsNotStartedAgain` also checks `ScratchNode.environment`'s scratch `XDG_*` and no bus address.
  - `PrivateWriteLintTests.allowed` names `NodeStarter.swift`'s one `createDirectory` (the user's unit folder, 0755).
    The security document's S9 `Held by:` names S2's six unit and manager cases.
  - Verified: `StartCommandTests|ServerCheckTests|ScratchNodeTests|StatusCommandTests|ServerTests`, the lints,
    `StartCommandTests` and `ServerCheckTests|StatusCommandTests|ScratchNodeTests` under load (24, 3 runs), and
    `VibeNodeTests|VibeCoreTests|VibePlatformTests` under `vs-heavy`. That run's other failures,
    `LoginShellVariableTests` (two cases, timing under the full run's load), passed alone; S2 touches nothing they run.
    `aScratchNodeIsNotStartedByTheCommandLine` fails with `Start.swift` reverted.

  *2026-11-16, the review of S2 (committed as "v2 step 8: S2 review fixes"):*
  - **The show check reads more** (ST-D2's note of this date): the dependencies that start another unit, so a
    `vibeswitcher-node.service.wants/` link refuses, and the directives a unit put in place of start's before the
    reload could add. `NodeUnit.pulls`, `defaultRequires` and `defaultsMismatch(_:home:)` are new.
  - **The unit's state first.** `startUnit` reads `show -p ActiveState` before it writes anything and refuses unless
    the unit is `inactive` or `failed` (`NodeStarter.stoppedStates`): `systemctl start` on a running unit does nothing,
    and start would say it started a build that may not be what runs. Every call list in the cases begins with it.
  - **The `start` entry moves into the starter** (ST-D5's step 9 comes after the starter's checks now):
    `startUnit(_:atLogin:beforeStart:)` runs `beforeStart` after the manager's environment is read again and before
    `enable` and `start`, and `StartSequence` passes the journal write as it, so a start the checks refuse leaves no
    entry that explains a job someone else starts within its 120 s. `Steps.starter` takes the closure as a third
    argument. `startJournalsItsOwnStartBeforeTheManagerIsAsked` asserts the entry after the starter is reached and
    before `unit:start`.
  - **Enabled, before the code.** `Steps.enabledBy` (`NodeStarter.enabledBy(unitFolder:)`: every `*.wants`,
    `*.requires` and `*.upholds` folder of the unit folder holding the unit, a dangling link included) is read before
    the confirmation, and `NodeTexts.start(unit:current:previousCommit:atLogin:enabledBy:)` says "It is enabled already
    (…): the manager starts it at login, without start's checks" (ST-D4's "says when the unit is found enabled"). Another
    unit file's own `Wants=` isn't read. `isEnabled`, and so `Started.enabledAtLogin`, is the same read.
  - **Failures after `enable`** say the unit stays enabled and how to undo it; the wait's limit says the unit may still
    run and how to stop it. Start doesn't undo either itself.
  - **Scratch wiring.** On a scratch node `Start.swift` builds no `NodeStarter.Tools`: its starter refuses (69,
    `StartSequence.scratchNotStarted`) and it reads no unit, so a regression in the sequence's branches still can't
    reach the account's manager or unit folder. No case reaches the command line's wiring past the sequence: the
    guard is read, not tested.
  - **`NodeStarter.run`** has its own case (`theBoundedRunKillsWhatOutlivesItsTimeout`: an exit's status and output; a
    program in the foreground past its timeout, and one leaving a child that holds its stdout, come back nil in time
    with both pids ended). It fails with the timeout's group kill made a kill of the pid alone.
  - The security document's S3, S9 and S11 `Held by:` lines name S2's cases and the review's.
  - New cases: `aRefusedStartLeavesNoEntryThatExplainsALaterJob`, `aPlainStartOfAnEnabledUnitSaysSoBeforeItsCode`,
    `aDependencyOrDirectiveStartDidntWriteMakesStartRefuse`, `theStartEntryIsWrittenOnlyOnceTheChecksPass`,
    `aUnitThatAlreadyRunsIsNotStartedAgainOrClaimed`, `aFailedStartAfterEnableSaysTheUnitStaysEnabled`,
    `theEnabledLinksAreFoundInEveryWantsFolder`, `theBoundedRunKillsWhatOutlivesItsTimeout`. Each of the fixes'
    cases fails with its fix's behaviour taken out (the API kept).

**Done when:** the cases pass on Linux. The port map's `HostClientSlowStartTests` row is `ported`. The Mac runs
`NodeTexts`' and `StartSequence`'s cases.

---

### Task S3: The detached start, the record and `stop` without a server

**Needs:** S2.

**Files:**
- Create: `Sources/VibeNode/Start/NodeRecord.swift`, `StopSequence.swift`, `NodeStopper.swift`
- Modify:
  - `Sources/VibeNode/Start/NodeStarter.swift` (`startDetached`), `NodeTexts.swift` (`stop`);
  - `Sources/VibeNode/Facts/NodeCheck.swift` (`.detached(record:)`);
  - `Sources/vibeswitcher-cli/NodeClient.swift` (`NodeContext` takes the mode from `NodeFolders.mode`);
  - `Sources/vibeswitcher-cli/ServerCheck.swift` (the expected parent from the record);
  - `Sources/vibeswitcher-cli/Stop.swift` (wires `StopSequence`; its confirmation takes `NodeTexts.stop(live:)` from
    the `status` it asks first);
  - `Sources/vibeswitcher-cli/Status.swift` (the weaker-rule line);
  - `Tests/VibeNodeTests/StartCommandTests.swift`, `ServerCheckTests.swift`.

**Interfaces:**
- Consumes: `Platform.Spawn` `.ownSession` and `keep`; `Platform.Processes.token(_:)` (`startTicks`), `isDumpable`;
  `Platform.Files` (0600 writes, `O_NOFOLLOW`).
- Produces:
  - `public struct NodeRecord: Codable, Equatable { format = 1; pid: Int32; startTicks: UInt64 }`:
    - `static func read(root:) -> NodeRecord?` (`O_NOFOLLOW`);
    - `func write(root:) throws` (0600, `O_NOFOLLOW`);
    - `func isLive() -> Bool` (the token's `startTicks` match).
  - `NodeStarter.startDetached(host: [String], home: String, path: String, root: String) -> Result<NodeRecord,
    StartRefusal>`. The host command is a parameter; the installed command line passes `NodeUnit.execStart`. The
    environment is exactly `HOME`, `PATH` and `SWIFT_BACKTRACE=enable=no`.
  - `NodeCheck.Mode.detached(record: NodeRecord?)`, and `NodeCheck.refusal` for it: non-dumpable, parent == the
    record's pid while live and of the installed host's form, the same session. No cgroup line.
  - `public enum NodeStopper`:
    - `static func stopUnit(systemctl: String, wait: TimeInterval) -> Result<Void, StartRefusal>`;
    - `static func stopDetached(root: String, isHost: ([String]) -> Bool, grace: TimeInterval = 30) -> Result<Void,
      StartRefusal>`. The installed command line passes ST-D7's command-line form; a test passes its scratch host's
      arguments.
  - `public struct StopSequence`: `Steps` (`installedBuild`, `server: () -> ServerAnswer` with `ServerAnswer {
    answered(live: Int); notRunning; noHello; refusedByCheck(String) }`, `typed`, `confirm`, `journal`, `stopper`);
    `func run() -> Result<Outcome, StartRefusal>`.
  - `NodeTexts.stop(live: Int) -> String` ("This ends 3 sessions in all projects (the leads first), then stops its
    host."; the singular form; 0 live: "No session is live; this stops the host.").

- [x] **Step 1: Failing tests:**
  - `aNodeWithoutSystemdRunsInASessionOfItsOwnAndStopEndsIt`:
    - A scratch home whose runtime folder is empty, and mode stand-ins saying pid 1 isn't systemd.
    - `startDetached` with a scratch host command (`--lock <root>/scratch-host.lock`, no `--node`; `ScratchNode`'s
      arguments).
    - The host's `getsid == pid` and its `tty_nr` is 0. Its parent is the test process, the spawner, which exits in
      the real command line. `node.pid` holds its pid and `startTicks` (0600). Its output is in `host.log`.
    - `stopDetached` ends it within 30 s and reaps it. No descendant of it remains, and no zombie.
  - `theDetachedHostGetsOnlyTheListedEnvironment`: with `LD_PRELOAD`, `GIT_CONFIG_GLOBAL` and `VIBESWITCHER_HOME`
    set in the test's environment, the host's `/proc/<pid>/environ` (read while it is held dumpable by
    `--test-stays-dumpable`) holds exactly `HOME`, `PATH` and `SWIFT_BACKTRACE=enable=no`.
  - The `HostClientReapTests` port (row 98):
    - `stoppingByAStalePidLeavesTheProcessNowUnderItAlone`: a record whose pid now names another live process (its
      `startTicks` differ) is refused. So is a record whose pid has matching `startTicks` but another command line
      (a `sleep` the test starts). Each process is alive afterwards and isn't signalled.
    - `aHostThatExitsBeforeItIsWaitedForLeavesNoZombie`: a host command that exits at once leaves no zombie child of
      the starting process (the spawn's child is reaped by the bounded wait), and `startDetached` refuses: "the host
      ended at once; see <log>".
  - `stopWithNoServerStopsTheUnit`: in process, `stopUnit` with the recording stand-in calls exactly
    `--user stop vibeswitcher-node`. On a scratch node the CLI's `stop` with no server still exits 69 with "the node
    isn't running" (ST-D1).
  - On `StopSequence` with recording stand-ins:
    - `aStopWithAServerThatDoesntAnswerStopsTheUnit`: `noHello` and `refusedByCheck` each fall back to the stopper,
      after the typed code. `answered` never does.
    - `stopJournalsItsOwnStopBeforeTheManagerIsAsked`: the `stop` entry is recorded after the code and before the
      stopper. With a `JOB_TYPE=stop` event 30 s later, `NodeJournal.unexplained` is empty.
    - `aStopFallbackWithNoTerminalIsRefused`: nothing is recorded or called.
    - `aCommandLineBuiltInDotBuildRefusesTheStopFallbackBeforeAnyWrite`.
  - `theCommandLineChecksADetachedNodeByItsRecord` (`ServerCheckTests`):
    - `.detached` refuses a listener that isn't the recorded host's child, a recorded pid whose `startTicks` changed,
      a recorded process of another command line or a dumpable one, and a child in a session of its own.
    - It accepts the real child, with no cgroup line read.
  - `statusSaysTheWeakerRuleWithoutSystemd`: the line names the pid file as writable by any worker.
  - The `HostRestartTests` port (row 100), its second case: `anyOtherSaysHowManySessionsInAllProjectsItEndsAndAsksFirst`
    restated on `NodeTexts.stop(live:)` (3 sessions; 1 session; 0).
- [x] **Step 2: Implement.**
  - `Stop.swift` builds `StopSequence.Steps` and runs it. The fallback runs only in node mode (unit or record).
  - `NodeContext` chooses `.node` or `.detached` from `NodeFolders.mode`. `.socketMissing` refuses.
- [x] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'StartCommandTests|ServerCheckTests|StatusCommandTests|CloseOnExecLint'`
  - the lints
  - under load (`StartCommandTests|ServerCheckTests`)
- [ ] **Step 4:** commit ("v2: a node without systemd, its record, and stop without the server"). Push, both green.

  *2026-11-16, S3 as made (committed; the push is the lead's):*
  - **Test first.** The cases were written before the code: with the code's changes stashed, the two suites don't
    build (`NodeRecord`, `StopSequence`, `NodeStopper`, `NodeTexts.stop`, `NodeStarter.startDetached` missing).
  - **Names that differ from the interface above:**
    - `NodeStopper.stopUnit(systemctl:runtimeFolder:wait:)` takes the runtime folder too: the manager is reached
      through it (`NodeStarter.environment(runtimeFolder:)`), never through this process's `XDG_RUNTIME_DIR`. `wait`
      defaults to `NodeStopper.unitWait` (`TimeoutStopSec` + 15 s). `NodeStopper.detachedHost(root:isHost:)` is the
      check `stopDetached` and the confirmation share.
    - `StopSequence.ServerAnswer`'s `notRunning`, `noHello` and `refusedByCheck` carry why, and `failed(StartRefusal)`
      is an error reply to `status`. `Steps` holds `kind` (`StartSequence.Kind`), `installedBuild`, `server`,
      `typed(code, what)`, `say` (the plan's `confirm`), `journal`, `throughServer(action)` (the server's stop and its
      `request` entry, as before S3), `fallback(mode)` (what the fallback stops, said before the code: the unit, or the
      recorded host by pid and command line; or why nothing: a unit `inactive` or `failed`, or no live host recorded,
      is 69 "the node isn't running", a stale record "nothing ended"), `stopper(mode)` and `newAction`. `Outcome` is
      `throughServer` or `withoutServer`.
    - `NodeStarter.startDetached(host:home:path:root:settle:)` is static. `settle` (`detachedSettle`, 1 s) is how
      long it watches for an exit at once; it refuses before anything while the record names a process that still
      runs. Beside it: `detachedEnvironment(home:path:)`, `hostLog(root:)`, `Probe.hostEnded`, and
      `awaitListening(detachedLog:)`, whose refusals then name the log and `stop`.
    - `NodeCheck.recordedHost(_:isHost:startTicks:arguments:dumpable:) -> Recorded { host, none, other }`,
      `NodeCheck.isInstalledHost(_:prefix:)` (ST-D7's form), and `NodeCheck.listener(pid:)` (the command line's reads,
      shared with the test). `NodeRecord` also has `path(root:)`, `liveTicks(_:)`, `hasEnded()` (collects its own
      child) and `remove(root:ifStill:)`. `isLive` reads `Platform.Processes.link`, on both systems, not `token`
      (the Mac's token has no start ticks).
    - `NodeFolders.nodeRoot(accountHome:)`: the record and the log are in `<getpwuid home>/.vibeswitcher/v2/`, the
      root the `--node` host takes, whatever the command line's HOME says.
    - `NodeTexts.stopUnit`, `stopDetached(pid:arguments:)`, `startDetached(unit:current:log:record:)`, `weakerRule` and
      `statusLines(mode:)` beside `stop(live:)`.
  - **The detached start in `StartSequence`** (`Steps.detached`, whose default refuses): on `.node(.noSystemd)` no
    unit is read or written and no manager is asked. The build is the command line's own: a unit names a commit only
    the manager runs. `--at-login` is refused. The journal entry is `detached`'s `beforeStart`, before the spawn.
  - **No journal without systemd (for the lead).** journald is systemd's, so on a machine without systemd the
    acknowledgment and the start's and stop's entries can't be recorded. S2's order (refuse when the journal can't be
    read or written) would then keep the detached start and stop from ever running. In the detached mode only, S11's
    list and its code are asked at each start while the acknowledgment can't be read, and the start's and stop's
    entries are written when they can be and said not recorded when they can't. Through systemd nothing changed. To
    refuse instead, `StartSequence.acknowledgeWithoutJournal` and the two "isn't recorded" branches go.
  - **The stop's order.** The server is asked first: a connection, then `status` for the confirmation's count. The
    installed-build check comes only before the fallback, so `stop` through a server that answers works from any build,
    as before S3. A fallback on a machine whose manager's socket is missing is refused.
  - **`NodeContext`** takes `.detached(record:)` on Linux where `NodeFolders.mode` says `.noSystemd` (never on the
    Mac). `.socketMissing` keeps `.node`: its `MainPID` can't be read, so a server fails the check, and `start` and the
    fallback refuse it. A detached start's wait makes a fresh context for each probe, so the check reads the record
    just written.
  - **Tests that differ.**
    - `theDetachedHostGetsOnlyTheListedEnvironment` doesn't set `LD_PRELOAD`, `GIT_CONFIG_GLOBAL` or
      `VIBESWITCHER_HOME` in the test process: they are process-wide, and would reach every child the suite's other
      cases start (S2's note). The run's own variables (`VIBESWITCHER_HOME`, `TMPDIR`, `CFFIXED_USER_HOME` and the rest)
      stand for them. The host's environment is exactly the three.
    - The scratch host's `--socket` is spelled `<home>/.vibeswitcher/host.sock`: its server takes only its root's host
      socket, by path.
    - ST-D6's `tty_nr` check is `Platform.Processes.link(pid).terminal == nil`.
    - No case puts the command line itself in the detached mode: this machine has systemd, and the mode is read from
      fixed paths. `ServerCheck`'s detached branch and `Stop.swift`'s fallback wiring are read, not run.
      `theCommandLineChecksADetachedNodeByItsRecord` drives `NodeCheck` on the system's reads of a scratch host started
      detached.
    - Added: `aRecordIsReadOnlyFromARegularFileOfItsOwnFormat`, `aMachineWithoutSystemdStartsTheNodeDetached`.
      `theManagerAndTheMachineAreRefusedBeforeTheServerIsAsked`'s last part now checks that a machine without systemd
      asks no manager.
  - *For S8:* a handover execs a new image in the host's process (the pid and start kept), and its command line is
    then the new image's. Whether it still has ST-D7's form decides whether `stop`'s fallback and the server check take
    a detached host after a switch.
  - The port map's `HostClientReapTests` row is `ported`, `HostRestartTests` half ported, and the `HostClient.swift`
    row's starting and reaping (183-221, 293-366) `ported`. The security document's S3 and S9 `Held by:` lines name
    S3's cases.
  - Verified: `StartCommandTests|ServerCheckTests` (69 cases) and the lints with `StatusCommandTests` (132 cases),
    `VibeNodeTests|VibeCoreTests|VibePlatformTests` (3314 cases, green), and
    `StartCommandTests|ServerCheckTests|StatusCommandTests` under load (24, 3 runs, nothing left behind).

  *2026-11-16, the review of S3 (committed as "v2 step 8: S3 review fixes"):*
  - **The stop's count.** `status`'s `sessions` is the scan of every agent on a terminal, hosted or not, and no plain
    program the host runs; the server's stop ends the host's live sessions. `status` now gives `host.liveSessions`
    (`link.sessions.filter(\.isLive).count`) and `stop`'s confirmation counts it
    (`ServerTests.aStopFromTheUserEndsEverySessionThenTheHost` checks "This ends 2 sessions"; without the fix it said 6
    here, the machine's own agents).
  - **One detached start at a time.** `startDetached` holds an exclusive `flock` on `<root>/v2/node.pid.lock`
    (`NodeStarter.detachedLock(root:)`, 0600, `O_NOFOLLOW`) from the record's check through the record's write and the
    settle; another start meanwhile is refused before anything (`twoDetachedStartsAtOnceStartOneHost`).
  - **A record naming another process doesn't block a start.** `startDetached(host:home:path:root:isHost:settle:)`
    takes `isHost` (the command line passes `NodeCheck.isInstalledHost`) and refuses only while the recorded process
    runs from its start ticks with the host's command line; any other record is replaced and its process left alone.
    `stop`'s "now names another process; nothing ended" names the file whose removal clears it.
  - **The start's wait checks the host it spawned.** `detachedProbe` connects with
    `NodeContext(root:mode: .detached(record:))` holding the record `startDetached` returned; `node.pid` isn't read
    again during the wait (the note above about a fresh context per probe no longer holds). The command line's
    detached branch isn't run here (this machine has systemd), so this is read, not tested.
  - **A detached stop reads the tree again.** `NodeStopper.gathered(_:host:)`: what is under the host is read again
    every 100 ms while it ends and before its SIGKILL, and what is under each process found once it has ended and
    before each is killed (`aChildStartedWhileTheHostEndsIsFoundToo`). A process that left the tree before it was read
    still outlives the stop: the confirmation (`NodeTexts.stopDetached`), the code's comment and the security
    document's S3 and S11 item 13 say so instead of claiming `KillMode=control-group`.
  - **The handover's command line (the S8 note above).** `isInstalledHost` takes argv[0]
    `<prefix>/<commit>/bin/vibeswitcher-host`, `--node` at argv[1] and exactly one `--node-root` naming that same
    folder, wherever it comes: after a handover the new image's argv holds the handover's flags first and its build's
    `--node-root` near the end (`HandoverMemory.folderArguments`), and a fallback's its own back at the end. This
    widens ST-D7's literal form; `stoppingByAStalePidLeavesTheProcessNowUnderItAlone` holds both forms and the
    refusals (two `--node-root`, another build's, only the fallback's).
  - **The Mac's stop.** `StopSequence.kind(isScratch:onTheMac:mode:)`: on the Mac (`Platform.CodeIdentity`) a stop with
    no server refuses as before S3 (69, "the node isn't running"), with no installed-build check or fallback
    (`theMacsStopWithNoServerSaysTheNodeIsntRunning`).
  - **Found under load while checking these: a host collected too early.** `NodeRecord.hasEnded` took "no longer
    live" for ended, but a multithreaded host's main thread shows as a zombie while its other threads still exit,
    when `waitpid` can't collect it yet: `stopDetached` returned with the host left a zombie child
    (`aNodeWithoutSystemdRunsInASessionOfItsOwnAndStopEndsIt` failed 1 run in 3 to 5 under load). A child of this
    process now counts as ended only once collected; 8 runs of 8 green after.
  - **No journal without systemd (still the lead's call).** The security document now says what the code does: S3's
    doesn't-promise and S11 item 13 say that without a user systemd nothing is journalled and `status` can't flag an
    unexplained start, and name `~/.vibeswitcher/v2/node.pid` as a file any worker can rewrite (its readers refuse
    then); S9's seal list says why the record and `host.log` aren't watched. To refuse instead, the code change above
    (`acknowledgeWithoutJournal` and the two "isn't recorded" branches) still applies.

**Done when:** the cases pass on Linux. The port map's `HostClientReapTests` row is `ported` (EN-D12), `HostRestartTests`
is half ported (its first case is S8a's), and the `HostClient.swift` row's lifecycle part (183-221, 293-366) is
`ported`.

---

### Task S4a: `BuildRecord` and `install-record`

**Needs:** the sweep merged. Can run beside S1 to S3.

**Files:**
- Create: `Sources/VibeNode/Start/BuildRecord.swift`, `Tests/VibeNodeTests/InstallTests.swift` (its in-process cases)
- Modify: `Sources/vibeswitcher-cli/main.swift` (the unlisted `install-record`)

**Interfaces:**
- Consumes: `BuildInfo` (`format`, `init(commit:binaries:swift:resolved:)`, `encoded`, `sha256(of:)`, `read`).
- Produces:
  - `public enum BuildRecord`:
    - `static func write(folder:commit:swiftVersionOutput:resolved:) -> Result<BuildInfo, StartRefusal>`: hashes
      every entry of `folder/bin` (refusing one that isn't a regular file), `swift` is the version text, `resolved`
      the SHA-256 of the `Package.resolved` bytes;
    - `static let installedNames = ["vibeswitcher-host", "vibeswitcher-server", "vibeswitcher", "vibeswitcher-hook",
      "vibeswitcher-mcp"]`.
  - `vibeswitcher install-record FOLDER --commit C --swift-version-output F --resolved PATH` calls `BuildRecord.write`.

- [ ] **Step 1: Failing tests** (`InstallTests`, in process):
  - `aRecordForAFolderNamedOtherThanItsCommitIsRefused`.
  - `aRecordHashesEveryProgramAndRefusesALink`: `binaries` holds each regular file's SHA-256 and nothing else. A link
    in `bin/` is refused.
  - `aRecordNamesItsToolchainAndResolvedFile`: `swift` equals the given version text, and `resolved` equals the
    SHA-256 of the given `Package.resolved`. `BuildInfo.read` takes the result.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify.** `bash scripts/test.sh --filter InstallTests`; the lints; under load.
- [ ] **Step 4:** commit ("v2: the install's build record"). Push, both green.

**Done when:** the cases pass on both runners.

---

### Task S4b: `scripts/install-node.sh` and its ungated tests

**Needs:** S4a.

**Files:**
- Create: `scripts/install-node.sh`
- Modify: `Tests/VibeNodeTests/InstallTests.swift`

**Interfaces:**
- Consumes: `scripts/lib/scratch.sh` (`scratch_tmpdir`, `on_exit`), the verified copy (ST-D9); `install-record` (S4a).
- Produces:
  - `scripts/install-node.sh COMMIT [--prefix DIR] [--repo DIR] [--toolchain DIR]`, with the test-only `[--gh PATH]
    [--test-origin URL] [--test-products DIR]` (ST-D8). Exit codes: 0; 64 usage; 65 dirty; 66 provenance; 67 not on
    `v2` or CI not passed; 68 toolchain; 69 link check; 1 other (a failed fetch included). Each refusal is one line on
    stderr naming what failed.
  - The layout, under `<prefix>/<commit>/`:
    - `bin/` holds exactly `BuildRecord.installedNames`: regular files, 0755;
    - `Resources/bin/vs-*` (0755), `Resources/install-node.sh` and `Resources/lib/scratch.sh` and `swift-jobs.sh`,
      all from the checkout of `<SHA>`;
    - `build-info`.
  - Beside the builds: `<prefix>/current` (a relative link to `<commit>`, replaced by rename) and `<prefix>/installs`.
  - At its end the script prints: "the seal holds every team until `vs config accept` (the builds folder changed)".
  - The script logs "checked out <SHA> tree <tree>" after the checkout.

- [ ] **Step 1: Failing tests** (`InstallTests`, `linuxOnly`):
  - **Fixtures.** A small synthetic repository: one commit of the working copy's `scripts/install-node.sh`,
    `scripts/lib/*.sh`, `Resources/bin/vs-*`, `.swift-version` and `Package.resolved`, made with `git -c
    user.name=… -c user.email=…`. A scratch bare "origin" whose `v2` is that commit, given as `--test-origin
    file://…`, its config setting `uploadpack.allowReachableSHA1InWant` as GitHub does, so a commit is fetched by its
    hash. A scratch clone as `--repo`. A stand-in `gh` that prints canned JSON and records its arguments and
    environment. Under TDD the working copy's script is what is committed, so provenance passes. CI's shallow
    checkout plays no part.
  - `anInstallFromADirtyTreeIsRefused`: a tracked file changed, and separately an untracked file under `Sources/`.
    Each exits 65 naming the file. The stand-in `gh` records no call, and the prefix is untouched.
  - `aCommitNotOnOriginV2IsRefused`: a commit on another branch of the origin, not reachable from its `v2`, exits 67.
  - `aCommitBothRunnersDidntPassIsRefused`: four canned answers each exit 67, naming the workflow:
    - `v2 macos` missing;
    - `v2 linux` failed;
    - the latest run `cancelled`;
    - an older run (lower `databaseId`) passed under a newer failure.
  - `ghRunsWithNothingFromTheUsersEnvironmentOrConfig`: with `GH_TOKEN`, `GH_REPO`, `GITHUB_TOKEN`, `HTTPS_PROXY`
    and `SSL_CERT_FILE` set, and a `config.yml` holding `http_unix_socket` in the test home's `~/.config/gh`, the
    stand-in sees none of them. Its `GH_CONFIG_DIR` and `HOME` are under the scratch folder, and every call carries
    `-R <the constant>` or `repos/<the constant>/`.
  - `aToolchainTheUserCanWriteIsRefused`: `--toolchain` as swiftly's folder, and as a scratch folder, exits 68 before
    any fetch, naming the writable path.
  - `aFirstInstallRunsOnlyTheCommitsOwnScript`: a working copy whose script differs from `COMMIT`'s exits 66. So does
    one whose `scripts/lib/scratch.sh` differs, and its changed line (a marker write) never runs.
  - `theNextInstallRunsThePreviousBuildsScript`:
    - With `<prefix>/current` present (laid out by hand: `Resources/` from the commit, `build-info` by `BuildRecord`),
      running the repository's script exits 66, naming `<prefix>/current/Resources/install-node.sh`.
    - Run from `<prefix>/current/Resources/install-node.sh` with `--test-products <debug products>`, it passes
      provenance and stops at the link check (69).
  - `theTestFlagsNeedAScratchPrefix`: `--gh`, `--test-origin` or `--test-products` without `--prefix`, with the
    account's default prefix through a link to it, or with a prefix inside `<home>/.vibeswitcher`, exits 64.
  - `nothingInTheUsersCloneOrConfigShapesTheBuild`: a replace ref for `<SHA>` in `--repo` and in the origin, a
    `post-checkout` hook and `core.hooksPath` in `--repo`, and a smudge filter in the test home's `~/.gitconfig`
    named by the commit's `.gitattributes`. Each run exits 69 (the link check, after the checkout, with debug
    products). Its "checked out" line's tree equals the origin's `<SHA>^{tree}` read with `GIT_NO_REPLACE_OBJECTS=1`,
    and no hook's or filter's marker file exists.
  - `aBinaryWithARunpathIsRefused`: `--test-products <the debug products>` (RUNPATH into swiftly) exits 69, naming
    the binary and the entry. Nothing is under the prefix.
- [ ] **Step 2: Implement** the script in this order:
  1. arguments;
  2. the courtesy check: `git -C repo diff --quiet HEAD` plus `ls-files --others --exclude-standard`, under ST-D9's
     environment;
  3. the toolchain (`stat` up the whole path, ST-D12's `find`, version equal to the fetched `.swift-version` once
     fetched), skipped under `--test-products`;
  4. `early=$(/usr/bin/mktemp -d /tmp/install-node-early.XXXXXX)`, removed by a `fail` function until `on_exit` is
     available; a fresh `git init` there; fetch `<SHA>` and `refs/heads/v2` (and the `current` commit, ST-D9);
  5. provenance (ST-D9); write the verified `lib/*.sh` blobs into `$early/lib/`; `source "$early/lib/scratch.sh"`;
     `scratch_tmpdir install-node`; `on_exit "rm -rf '$early'"`;
  6. the ancestry check and the CI check (ST-D10);
  7. `git worktree add --detach "$tool_scratch/src" <SHA>` in the fresh clone, then the "checked out" line;
  8. the build (ST-D11), skipped under `--test-products`;
  9. the link check (ST-D12);
  10. copy into `<prefix>/<commit>.partial`, `install-record`, rename to `<prefix>/<commit>` (refused if it exists);
  11. `installs`, then `current` by a link renamed over, then the seal line.

  The script obeys `ScriptScratchLintTests`: it calls `scratch_tmpdir` before the build, never sets `TMPDIR` and
  never traps `EXIT`.
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'InstallTests|ScriptScratchLint'`
  - the lints
  - under load (`InstallTests`)
- [ ] **Step 4:** commit ("v2: the node's install script"). Push, both green.

**Done when:** the ungated cases pass on Linux.

---

### Task S4c: The static spike, the static-product cases and the gated build

**Needs:** S4b. Its gated case needs **M3**.

**Files:**
- Modify: `Tests/VibeNodeTests/InstallTests.swift`, `scripts/install-node.sh` (only if the spike corrects ST-D12's
  `NEEDED` set), `docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md` (M2: the token also reads Actions and
  Contents; M3: the agent's check of the toolchain), `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`
  (S9's test text, ST-D12; S11's residuals: ST-D9's first run, and the build below),
  `docs/process/v2-linux-inventory.md`

- [ ] **Step 1: The static spike** (no code). Under `vs-heavy`, run ST-D11's exact build command with swiftly's
  6.4.2 (the same release as M3's) and a scratch path. Record in the inventory: `readelf -l` and `readelf -d` of the
  five products, the absence of `RUNPATH`, each size, and the time. Keep the products in
  `~/.cache/vibeswitcher-static-products/<commit>/` (outside every watched folder) for Step 2. If the `NEEDED` set
  differs from ST-D12's, correct the script's list and its test in this task.
- [ ] **Step 2: Failing tests on static products**, enabled only with `VIBESWITCHER_STATIC_PRODUCTS=<that folder>`
  on the run's command line (skipped otherwise, saying "the static products aren't built: S4c Step 1"):
  - `aScratchInstallLaysOutTheBuildAndItsRecord`: `--test-products <static products>` gives this:
    - the layout above, with every `bin/` entry a regular file and no `.git` anywhere under the prefix;
    - `current` naming the commit, and `installs` gaining one line;
    - `build-info` that `BuildInfo.read` takes, its commit equal to the folder's name, five `binaries` matching the
      files, `resolved` equal to the SHA-256 of the commit's `Package.resolved`, and `swift` equal to the given
      version output;
    - `TestLock.commandFolder(besideExecutable: <commit>/bin/vibeswitcher-mcp)` equal to `<commit>/Resources/bin`.
  - `aHostStartsFromAnInstalledFolder`: a scratch host with `--node-root <prefix>/<commit>`, `--server
    <commit>/bin/vibeswitcher-server` and `--lock` in scratch passes `HostImages.load`'s `build-info` check. One byte
    changed in a copy of the installed server makes it refuse.
  - `anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite` (its maps half):
    - The maps of the installed host (`--test-stays-dumpable`), a held launcher (`--launcher-test-hold`) and
      `vibeswitcher-mcp` show only ST-D12's allowed lines.
    - Reading the server's maps fails with `EACCES` (measured; ST-D12).
- [ ] **Step 3: The gated build**, `anInstallBuildsWithTheRootToolchain`, enabled only with
  `VIBESWITCHER_INSTALL_TOOLCHAIN=/opt/swift-6.4.2` on the run's command line and that folder present (M3). Otherwise
  it is skipped, saying "M3: the root toolchain isn't installed". It runs the real build through the script with
  `--prefix <scratch>`, `--test-origin` and the stand-in `gh`, on a fixture of a `git clone --no-local` of this
  repository with the working copy's script committed on top. Every binary passes the link check. It adds to the
  static cases only the root-owned toolchain and the build itself.
- [ ] **Step 4: Docs.** The three documents above. S11 gains the build's residual: the build's scratch folder is the
  user's. So a worker can change sources or objects during the minutes-long build, or ptrace `swift-build`.
  `build-info` then vouches for the result, and the CI check still passes.
- [ ] **Step 5: Verify.**
  - `VIBESWITCHER_STATIC_PRODUCTS=~/.cache/vibeswitcher-static-products/<commit> vs-heavy bash scripts/test.sh
    --filter InstallTests`
  - The gated case once M3 is done: `VIBESWITCHER_INSTALL_TOOLCHAIN=/opt/swift-6.4.2 vs-heavy bash scripts/test.sh
    --filter InstallTests/anInstallBuildsWithTheRootToolchain`. Its sizes, time and link-check output go in the
    inventory.
  - the lints
- [ ] **Step 6:** commit ("v2: the install's static build, checked"). Push, both green.

**User step, M3:** before the gated case and before S9. The agent prepares the exact commands from the bootstrap path's
M3, and how to check the tarball's signature (swift.org's key and the `.sig`). Afterwards it checks, read-only, that
`/opt/swift-6.4.2/usr/bin/swift --version` says 6.4.2, and that ST-D12's `find` over the tree prints nothing.

**Done when:** the static-product cases passed here, and the gated case passed once (or is skipped as an open item,
waiting on M3).

---

### Task S5: Builds report themselves

**Needs:** S4a's `BuildRecord` (tests write `build-info` with it). Can run beside S2 and S3.

**Files:**
- Create: `Sources/VibeCore/V2/ServerBuildLinux.swift`, `Sources/VibeHost/V2/HostStartLine.swift`,
  `Tests/VibeCoreTests/ServerBuildLinuxTests.swift`
- Modify:
  - the five Non-seam rows' files (`LeadGateBuild.swift` twice, `HostProtocol.swift`, `HostServer.swift`,
    `vibeswitcher-host/main.swift`);
  - `Sources/VibeNode/Server/Requests.swift` (`value(_ notes:at:)` carries `build`; `status` and the hello carry the
    host's pid from the welcome);
  - `Sources/VibeNode/Facts/NodeJournal.swift` (the start line as a `start` event's detail, ST-D24);
  - `Sources/vibeswitcher-cli/Status.swift` (the host's build);
  - `Tests/VibeNodeTests/ScratchNode.swift` (the host's environment gains `SWIFT_BACKTRACE=enable=no`; today it has
    none, line 111);
  - `Tests/VibeNodeTests/ScratchNodeTests.swift`, `NodeJournalTests.swift`; the port map.

**Interfaces:**
- Produces:
  - `enum ServerBuildLinux`:
    - `static func read(executable: String) -> ServerBuild?`: resolves the path, reads the `build-info` two folders
      up from it (`<c>/bin/x` → `<c>/build-info`), and gives `commit`. `changed` is whether the executable's SHA-256
      differs from its `binaries` entry (so the gate fails closed). nil when either can't be read. `builtAt` is nil.
    - `static let installHint = "install it with ~/.vibeswitcher/v2/builds/current/Resources/install-node.sh COMMIT, then vs switch COMMIT"`.
  - `HostNotes.build: String?` and `HostNotes.binaries: [String: String]?`.
  - `enum HostStartLine`:
    - `static func say(config:)`, which writes "vibeswitcher-host: started pid <p> build <commit|unknown>
      SWIFT_BACKTRACE=<value|unset>" to stderr on Linux;
    - `static var commit: String?` and `static var binaries: [String: String]?`, from the `build-info`
      `HostImages.load` checked.
  - `NodeJournal` parses the line as a `start` event's detail, only from the host (ST-D24).
  - The host's pid reaches the command line from the welcome (`.welcome(… pid, startedAt)`), which `HostLink`
    already reads, through `status` and the hello. `HostNotes` has no pid.

- [ ] **Step 1: Failing tests:**
  - `aLinuxToolServerNamesItsBuild` (linuxOnly): an executable in a scratch `<c>/bin/` with `build-info` gives
    `commit == c`, `changed == false`. One byte changed gives `changed == true`. No `build-info` gives nil.
  - `theMacStillReadsOnlyTheAppBundle` (Mac only): a path outside a `.app` gives nil, as today.
  - `aMergeReceiptNamesTheInstalledBuild`: `LeadToolset.runningBuild` from that executable reaches the receipt
    (MergeProvenance's form).
  - `theGateNamesTheLinuxInstallOnLinux` (`ServerBuildLinuxTests`): `GateLag.refusal` names `install-node.sh` and `vs switch` on Linux, and
    `scripts/build-app.sh --install` on the Mac (a Mac case).
  - `theHostSaysItsBuildAndBacktraceAtItsStart` (`ScratchNodeTests`): the scratch host's output has the line with
    the `ScratchNode` build's commit and `SWIFT_BACKTRACE=enable=no`.
  - `aStartLineFromASessionIsNotTheHosts` (`NodeJournalTests`): an entry with the line's text whose `_PID` isn't
    `ExecMainPID`, or whose `_TRANSPORT` is `syslog`, isn't taken as a start line.
  - `statusNamesTheHostsBuild`: `status` prints "host … build <commit>" from `HostNotes.build`.
  - `anOlderHostsNotesWithoutABuildStillRead`: `HostNotes` decoded with no `build` or `binaries` key.
- [ ] **Step 2: Implement** the hooks as listed.
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'ServerBuildLinuxTests|MergeProvenanceTests|ScratchNodeTests|StatusCommandTests|NodeJournalTests'`
  - the lints
  - under load
- [ ] **Step 4:** commit ("v2: the host, the server and the tool server name their build"). Push, both green.

**Done when:** the cases pass. The port map's row 223 is `made`, and the `HostNotes`, gate-text and start-line rows are
added. The Mac runs `theMacStillReadsOnlyTheAppBundle`, the gate's Mac case and `anOlderHostsNotesWithoutABuildStillRead`.

---

### Task S6: `hooks install` through the server

**Needs:** S5 (`HostNotes.binaries`).

**Files:**
- Create: `Sources/VibeNode/Server/HooksRequest.swift`
- Modify:
  - `Sources/VibeNode/Server/NodeWire.swift` (`taken` gains `hooks.install` and `hooks.remove`);
  - `Sources/VibeNode/Server/Requests.swift` (two `act` cases into `HooksRequest`; `recorded`);
  - `Sources/vibeswitcher-cli/Hooks.swift` (through the server, with the typed code; no `--agent` sends both);
  - `Tests/VibeNodeTests/HooksCommandTests.swift` (restated), `ServerTests.swift` (`anUnlistedRequestIsRefused` now
    lists `build.switch` only), `EngineEndToEndTests.swift` and `RealClaudeStatusTests.swift` (their hooks written
    with `HookInstaller`, ST-D17);
  - the port map (row 55).

**Interfaces:**
- Consumes: `LeadVault.appWrite(_:home:_:)`, `sealAppWrites()` (`ConfigSeal.swift:1050, 1074`) on `link.vault`;
  `HookInstaller.install(agent:at:hookBinary:)`, `uninstall(agent:at:)`, `configURL(for:home:)`;
  `ServerArguments.nodeRoot`; `HostNotes.binaries`.
- Produces:
  - `struct HooksRequest`:
    - `init(nodeRoot: String, home: String, binaries: [String: String]?, vault: LeadVault)`;
    - `func install(agents:) -> Result<Installed, StartRefusal>` and `func remove(agents:) -> Result<Void,
      StartRefusal>`;
    - `Installed { programs: [String]; configs: [String] }`.
  - The wire: `hooks.install` / `hooks.remove`, args `agents` (a list of `claude`|`codex`); voice the user's; code
    "own".

- [ ] **Step 1: Failing tests:**
  - `aSessionsProcessCannotInstallHooks` (S3): the request from a scratch session's process is refused `voice`, and
    the config file is unchanged.
  - `aHooksInstallWithNoTerminalIsRefused`: `setsid --wait` with no controlling terminal. The CLI refuses with
    `TypedWord`'s text, and the server records no request.
  - `hooksInstallWritesAsTheAppAndSealsIt`: on a `ScratchNode` holding its first look, after `config accept`:
    - `hooks install` on a pty (one code typed for both agents);
    - the scratch home's `.claude/settings.json` and `.codex/hooks.json` hold the hooks;
    - `<home>/.vibeswitcher/bin` holds the two programs, byte-equal to `<node-root>/bin`'s;
    - the vault's next look holds nothing (sealed as the app's write);
    - the same edit made by the test directly, not through the server, is held.
  - `aHooksInstallBeforeTheFirstAcceptIsSealedToo`: the same with `hooks install` before `config accept` (S9's card
    order is accept first; this pins the other).
  - `aNodeRootProgramThatDiffersFromBuildInfoIsNotInstalled`:
    - The test replaces the scratch node-root's `bin/vibeswitcher-hook` link (ScratchNode links it to the `.build`
      product) with a copy, then appends one byte to the copy. The shared product is never written.
    - `hooks install` is refused, naming the program. `<home>/.vibeswitcher/bin` and the configs are unchanged.
    - A link put in its place is refused (`O_NOFOLLOW`).
  - `noTemporaryIsLeftInTheWatchedFolder`: during and after, `<home>/.vibeswitcher/bin` holds only the two names.
  - `hooksRemoveTakesThemOut`.
  - The five `HooksCommandTests` restated against a `ScratchNode` (the scratch home's config, not `CLAUDE_CONFIG_DIR`).
  - `ServerTests.anUnlistedRequestIsRefused`: `build.switch` alone answers `unknown-kind`.
- [ ] **Step 2: Implement.** The programs are written as temporaries beside `<home>/.vibeswitcher/bin` (the app's way,
  `AppDelegate.swift:1229`), then renamed in. The config writes and the renames run inside one `appWrite` naming every
  path as `homeWatched` spells it, then `sealAppWrites()`. The handler runs on the engine's read queue.
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'HooksCommandTests|ServerTests|RequestsTests|VoiceRuleTests|EngineEndToEndTests'`
  - the lints
  - under load (`HooksCommandTests|ServerTests`)
- [ ] **Step 4:** commit ("v2: hooks install through the server, sealed as the app's"). Push, both green.

**Done when:** the cases pass on Linux, E9 Step 1 still passes, and row 55 is `ported`.

---

### Task S7: The seal's Linux list

**Needs:** the sweep merged. Independent of S1 to S6. ST-D19's measurement uses S6's harness changes if they have
landed; otherwise it uses E9's.

**Files:**
- Create: `Sources/VibeCore/V2/LinuxSealList.swift`, `Tests/VibeCoreTests/LinuxSealListTests.swift`
- Modify: `Sources/VibeCore/ConfigSeal.swift` (the Non-seam rows), `Sources/VibeCore/LeadVault.swift` (only if
  ST-D19's measurement needs it), `Tests/VibeNodeTests/FakeClaude.swift` (the shell snapshot, ST-D19),
  `Tests/VibeNodeTests/` (one scratch-node case), the port map (row 224 and the new rows),
  `docs/process/v2-linux-inventory.md`

**Interfaces:**
- Produces:
  - `enum LinuxSealList`:
    - `static func watched(home: String, uid: uid_t, mounts: String = "/proc/mounts") -> [ConfigSeal.Watched]`, empty
      where `Platform.CodeIdentity.isAvailable`;
    - `static let homeEntries: [(String, ConfigSeal.Watched.Kind)]`:
      - what the startup files source here: `.bash_aliases`, `.nvm/nvm.sh`, `.nvm/bash_completion`,
        `projects/rally/.rally-aliases`, `.local/share/swiftly/env.sh` (file);
      - `.local/share/swiftly/config.json` (file: swiftly's `bin` proxies choose their toolchain from it);
      - `bin` (folder);
      - `.claude/shell-snapshots` and `.codex/shell-snapshots` (folder, or `.entries` per ST-D19);
      - `.config/systemd/user`, `.config/systemd/user.control`, `.config/systemd/user.conf.d`,
        `.config/environment.d` and `.config/autostart` (folder); `.config/systemd/user.conf` (file);
      - `.local/share/systemd/user` (folder);
      - `.config/gh` (listing);
      - `.vibeswitcher/v2/projects` (file);
      - `.vibeswitcher/v2/builds` (listing);
      - `.vibeswitcher/lead/run` (folder, or `.entries`);
      - `.vibeswitcher/lead/git-hooks` (folder);
      - `.local/bin` (listing);
      - `.local/share/claude/versions` (listing);
      - `.local/share/swiftly/toolchains` (listing);
      - `.local/share/swiftly/bin` (listing);
    - `static func sourced(startupFile text: String, home: String) -> [String]`: each `.` or `source` target in a
      startup file written `~/…`, `$HOME/…` or `${HOME}/…`, watched as a file beside the static entries;
    - node's version folder (the parent of node's `bin`) from the unit's `PATH` when the unit exists, else each
      `.nvm/versions/node/v*` (listing);
    - `/run/user/<uid>/systemd/transient` and `/run/user/<uid>/systemd/user.control` (folder, ST-D20);
    - the `/mnt/c` entries (ST-D20).
  - `ConfigSeal.Watched.Kind.listing` (and `.entries` if needed).
  - Every entry `executes` (none is in `instructions`).

- [ ] **Step 0: Check the real startup files** (an agent step, read only, outside the suite). List every `.` and
  `source` target in `~/.bashrc`, `~/.profile`, `~/.bash_profile` and `~/.bash_login`. Record in the inventory that
  each user-writable target is in `homeEntries` or found by `sourced`. Targets under root-owned folders
  (`/usr/share/bash-completion`, `/etc/bash_completion`) are left out.
- [ ] **Step 1: Failing tests:**
  - `aWriteToEachItemOfTheLinuxListIsHeld` (linuxOnly, `LinuxSealListTests`): for every entry, a write in a scratch
    home changes that entry's fingerprint, and no other entry's. For listings, the write keeps size and mtime: a
    `touch -d` back, contents changed. Absent items hash as absent and change when created.
  - `aSourcedFileIsWatched`: a scratch `.bashrc` with `. ~/x.sh`, `source "$HOME/y.sh"` and `[ -f ${HOME}/z ] &&
    source ${HOME}/z` gives the three files. A write to each is held.
  - `theMacsListIsEmpty` (Mac only): `watched(home:uid:)` is `[]`, and `homeWatched` is today's.
  - `aListingNeverReadsContents`: an unreadable 0000 file in a listing still fingerprints (by its metadata).
  - `aListingIsNotCut`: a listing of 25,000 entries changes its fingerprint when the last entry changes.
  - `theWindowsFilesAreWatchedOnlyWhileMounted`: a stand-in mounts file with and without a 9p `/mnt/c`.
  - **Gated** `aLookOfTheLinuxListIsTimed`: enabled only with `VIBESWITCHER_SEAL_TIMING_HOME=<the getpwuid home>` on
    the run's command line. It fingerprints `LinuxSealList.watched` of that home, leaving out every entry under
    `~/.claude` and `~/.vibeswitcher` (so it touches neither), read only. It is timed and recorded in the inventory.
    The agent runs it once: `VIBESWITCHER_SEAL_TIMING_HOME=$(getent passwd $(id -un) | cut -d: -f6) bash
    scripts/test.sh --filter LinuxSealListTests/aLookOfTheLinuxListIsTimed`.
  - **The measurement**, `aWorkersStartDoesNotHoldItsTeam` (linuxOnly, `ScratchNode` with fakes, `FakeClaude`
    writing its shell snapshot): a lead starts a worker. The next look holds nothing, and a merge isn't refused for
    the seal. If this fails on the plain-folder form, the step takes `.entries` for the churning folders (ST-D19), and
    the case passes on it.
- [ ] **Step 2: Implement** the hook line and the kinds as in [Non-seam edits](#non-seam-edits-this-plan-makes). The
  `.folder` walk keeps `maxEntries`; `.listing` has no cap (ST-D18).
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'LinuxSealListTests|ConfigSealTests|LeadVaultTests|EngineEndToEndTests|FakeClaudeTests'`
  - the lints
  - under load
- [ ] **Step 4:** commit ("v2: the config seal's Linux list"). Push, both green.

**Done when:** the cases pass. Row 224 is `made`. The look's time on the real home and Step 0's check are in the
inventory. The Mac runs `theMacsListIsEmpty`.

---

### Task S8a: The switch's pure parts

**Needs:** S1 (`NodeUnit`), S2 (`NodeTexts`).

**Files:**
- Create: `Sources/VibeNode/Start/SwitchPlan.swift`, `SwitchFollowUp.swift`, `Tests/VibeNodeTests/SwitchTests.swift`
- Modify: `Sources/VibeNode/Start/NodeTexts.swift` (`switch`, `rollback`), the port map (rows 99, 100)

**Interfaces:**
- Produces:
  - `public enum SwitchPlan`:
    - `static func plan(running: String?, target: String, installed: [String], live: [LeadLaunch.Role]) -> Plan`,
      with `enum Plan { already; notInstalled; badCommit; refusedWhileTeamsWork(roles); handOver(target) }`.
      `badCommit` is any target not matching `^[0-9a-f]{40}$`;
    - `static func rollbackTarget(installs: [String], running: String) -> (commit: String, line: String)?`.
  - `SwitchFollowUp.apply(unitFolder:systemctl:prefix:commit:hostCheck:) -> Result<Void, StartRefusal>`:
    1. the target is 40 hex and its folder a direct child of the prefix (`realpath`), its `bin` matching its
       `build-info` (`NodeFolders.verifyBuild`);
    2. `hostCheck()` confirms, through a freshly checked server, that the host's pid is unchanged and `HostNotes.build`
       names the target;
    3. rewrites `ExecStart` only (via `NodeUnit.inputs(parsing:)` and `text`);
    4. runs `daemon-reload`;
    5. moves `current`.
  - `NodeTexts.switch(from:to:) -> String` ("keeps every session; a running team keeps its build until its lead
    restarts; the seal holds every team until `vs config accept`, since the builds folder and the unit change").
  - `NodeTexts.rollback(from:to:line:) -> String`: the same, with the target and its `installs` line.

*2026-11-16, as built:*
- `SwitchFollowUp.apply(tools:prefix:commit:hostPid:hostCheck:)`: the plan's `unitFolder:systemctl:` are
  `NodeStarter.Tools` (each `systemctl` runs with the runtime folder in its environment, as start's do), and the pid
  the host had before the switch is `hostPid:`. `hostCheck` returns what it saw, `SwitchFollowUp.Host(pid:build:)`,
  and the follow-up judges it, so "a `hostCheck` that reports another pid or build" is a case of its own. A missing
  unit file is refused (`vs start` writes it). A `daemon-reload` the manager refuses leaves the unit rewritten (said)
  and `current` unmoved (`aReloadThatFailsLeavesCurrentAndSaysTheUnitChanged`). *For S8c:* a detached node (no
  systemd, ST-D6) has no unit, so its CLI skips the follow-up or moves only `current`; S8c decides.
- The unit is written and `daemon-reload` asked through `NodeStarter`'s own `write` and `ask`, made internal to the
  module (they were private).
- `Plan.refusedWhileTeamsWork` carries the live workers' and verifiers' roles, in the order given; a target not
  installed is said before the rule.
- `rollbackTarget` takes the nearest earlier line naming another commit before the running commit's last line, and
  skips lines whose first word isn't 40 lowercase hex digits.
- `aSwitchLeavesTheSealHoldingUntilAccepted`: `LinuxSealList` is S7's and not in this lane yet, so the case
  fingerprints `~/.vibeswitcher/v2/builds` and `~/.config/systemd/user` as `ConfigSeal.Watched` `.folder`s (today's
  kinds). When S7 lands, the case takes `LinuxSealList.watched(home:uid:)`'s entries for those names (the builds folder
  as `.listing`).
- The app's cases map as row 99 says: `theBundledBuildIsUsed` and `noRestartIsOfferedWithoutAnOutdatedHost` as
  `theRunningCommitIsAlreadyRunning`; the replace and handover cases as `aSwitchWithNoLiveSessionOrOnlyLeadsHandsOver`;
  `anOlderHostKeepsItsSessionsUntilTheyEnd` as `aSwitchWhileWorkersOrVerifiersAreLiveIsRefused`. The app's "no
  confirmation" (`!needsConfirmation`) becomes `NodeWire.changesState("build.switch")` in `aSwitchSaysItKeepsSessions`.

*2026-11-16, the review of S8a:*
- The follow-up builds the switched unit as `start` does (ST-D3, ST-D4), never writing the unit's HOME or PATH back:
  `apply(tools:prefix:accountHome:commit:hostPid:hostCheck:)` takes the account's home (`getpwuid`'s; S8c passes it),
  and swiftly's and node's folders come from `NodeFolders.toolFolders(accountHome:nodeVersion: nil, existingUnit:)`,
  which takes only the unit's node folder and checks it. A worker's edited HOME or swift folder is undone; a node
  folder outside `<home>/.nvm/versions/node/v*/bin`, or a folder start wouldn't take, is refused before anything is
  written, called or moved (`aUnitsEditedHomeOrPathIsNotCarriedThroughASwitch`).
- The way back from a follow-up a failure left unfinished (the host runs the target; the unit or `current` don't name
  it): `vs switch <target>` again, which each refusal past the handover names. *For S8c:* when the server answers that
  the host runs the target already, in node mode, the CLI asks `SwitchFollowUp.isDone(tools:prefix:commit:)` and, when
  it says no, runs `apply` with the welcome's pid as `hostPid` (its host check passes: the same pid, on the target).
  `aReloadThatFailsLeavesCurrentAndSaysTheUnitChanged` runs the follow-up again after the failed reload, and
  `theFollowUpIsDoneOnlyWhenTheUnitAndCurrentNameTheTarget` holds `isDone`.
- `switch`'s confirmation now names who keeps the old tool server (ST-D16): "a lead started before the switch keeps
  starting its workers with the old build's tool server" (asserted in `aSwitchSaysItKeepsSessions`).
- The security document gains S8a's cases under `Held by:` (S9: the rewrite and its checks; S7: the seal's hold,
  ST-D23; S8: the plan's rule on switches), beyond S8a's Files list, as S1 to S3 did for theirs.
- `StartCommandTests.makeFolder(_:below:)` and `makeProgram(_:_:)` are internal (were private), for `SwitchTests.World`'s
  tool folders.

- [x] **Step 1: Failing tests** (`SwitchTests`, pure unless said):
  - The `HostClientPlanTests` port (row 99) on `SwitchPlan`:
    - the running commit gives `.already`;
    - a commit not in the install root gives `.notInstalled`;
    - `../x`, a short hash and an uppercase hash give `.badCommit`;
    - live sessions with a worker or verifier give `.refusedWhileTeamsWork`;
    - a switch with no live session, or with only leads, gives `.handOver` (the node never replaces its host to
      switch: the app's `replace` and `endAndReplace` are not needed, and the port map says so);
    - `rollbackTarget` gives the previous install and its line, or nil.
  - `aSwitchRewritesOnlyExecStartAndReloads` (linuxOnly): `SwitchFollowUp` in process on a unit S1 wrote. Only
    `ExecStart`'s commit changes; the calls are `daemon-reload`; `current` names `B`.
  - `aFollowUpChecksTheTargetAndTheHostFirst` (linuxOnly): a target outside the prefix, one whose `bin` differs from
    its `build-info`, and a `hostCheck` that reports another pid or build each refuse with nothing rewritten, called
    or moved.
  - `aSwitchLeavesTheSealHoldingUntilAccepted` (linuxOnly): after the follow-up in a scratch home, the fingerprints
    of `LinuxSealList`'s `~/.vibeswitcher/v2/builds` and `~/.config/systemd/user` entries both changed.
  - The `HostRestartTests` port, its first case: `aSwitchSaysItKeepsSessions`, on `NodeTexts.switch`. It names no
    count, and says the seal's hold. The code is still typed (EN-D5). Row 100's name for it changes from
    `aHostThatHandsOverKeepsSessionsWithoutAsking`, because the node asks a code where the app asked nothing.
  - `aRollbackSaysWhereItGoes`: `NodeTexts.rollback` holds the target and its `installs` line.
- [x] **Step 2: Implement.**
- [x] **Step 3: Verify.** `bash scripts/test.sh --filter SwitchTests`; the lints; under load.
- [ ] **Step 4:** commit ("v2: the switch's plan and follow-up"). Push, both green. *2026-11-16:* committed on
  `v2-step8-a` as "v2 step 8: S8a, the switch's plan and follow-up"; the push and both jobs are the lead's.

**Done when:** the cases pass. The Mac runs the pure cases.

---

### Task S8b: `build.switch` in the server

**Needs:** S8a, S4a, S5.

**Files:**
- Create: `Sources/VibeNode/Server/SwitchRequest.swift`
- Modify:
  - `NodeWire.swift` (`taken` gains `build.switch`), `Requests.swift` (the case; `recorded`; `status` gains
    `builds: {installRoot, installed, rollback: {commit, line}?}` from `<installRoot>/installs`);
  - `Sources/VibeNode/Server/ServerArguments.swift` (`--test-install-root=` parsed, and listed in `refused` under
    `--node`);
  - `Tests/VibeNodeTests/ScratchNode.swift`: `installRoot:` gives `--server-arg --test-install-root=` to the server.
    `ScratchBuilds.install(commit:into:)` copies real products, not links, writes `build-info` with `BuildRecord`,
    and appends to `<installRoot>/installs`;
  - `Tests/VibeNodeTests/SwitchTests.swift`, `ServerTests.swift` (no kind left unanswered; the install root's flag);
  - the security document (S8's wording, ST-D15; S9, ST-D16); the port map (rows 97, 99).

**Interfaces:**
- Consumes:
  - `HostCall.request(.handover(executable:), socket:, appKey: nil, timeout:)`, through the server's registered
    connector;
  - `HandoverTarget` (the host checks the target);
  - `HostLink.notes()` (`build`) and the welcome (the host's pid);
  - `LeadTeams.role(label:)` on the live sessions;
  - `HostHandover.probeLimit` (180; restated as `SwitchRequest.probeLimit` with a test tying the two).
- Produces:
  - `struct SwitchRequest`:
    - `func run(commit:reply:)`;
    - `static let replyWait = probeLimit + 15`;
    - `static func outcome(before: (pid, build), after: (pid, build)?, refusal: String?, afterTheWait: Bool) ->
      Outcome`, with `enum Outcome { handedOver(commit); oldBuildAnswered; otherHostAnswered(pid); hostGone;
      refused(String) }`.
  - The wire: `build.switch`, args `commit` (40 hex); voice the user's; code "own".

- [ ] **Step 1: Failing tests** (`SwitchTests`, linuxOnly unless pure):
  - `aSwitchWhileAWorkerRunsIsRefused` (S8): on a `ScratchNode` with a fake lead and worker, `build.switch` is
    refused, naming decision 6 and the worker. The host's pid and build are unchanged. With only the lead live, it
    hands over.
  - `theTestInstallRootIsRefusedUnderNode` (`ServerTests`, on `ServerArguments`): `--node --test-install-root=/x` lands in
    `refused`; without `--node` it is parsed.
  - `statusGivesTheRollbackTarget`: with `installs` holding `A`, `B` and the node on `B`, `status`'s `builds.rollback`
    is `A` and its line.
  - The `HostClientHandoverTests` port, its ten remaining cases (row 97), on `SwitchRequest.outcome` and against a
    `StubHost`:
    - handed over: the same pid with the new build;
    - the old build answering is a failure;
    - a different host answering is a failure;
    - a host that goes away is a failure;
    - a refusal is a failure, with its text;
    - a probe past 15 s is waited for;
    - handed over after the wait;
    - a refusal after the wait;
    - `theSwitchWaitCoversTheHostsProbe` (`replyWait >= HostHandover.probeLimit + 15`);
    - `theOutcomeNamesWhoAnswered`.

    (`otherRequestsKeepTheirFifteenSecondsDuringAHandover` was ported by E2 as
    `HostLinkTests.otherRequestsKeepTheirTimersDuringAReconnect`.)
  - The `HostClientSlowProbeTests` port (row 99): `aSwitchWhoseProbeTakesTwentySecondsIsWaitedForWithNoFalseFailure`.
    A `ScratchNode` with `--handover-test-hold PATH`, released after 20 s; the outcome is `handedOver`, and the live
    lead is kept.
  - `aRollbackTheHostRefusesSaysWhy`: a target the host refuses (its state format) leaves `A` running, and the reply
    names the host's reason.
- [ ] **Step 2: Implement.**
  - The server sends the handover through the connector with the target
    `<installRoot>/<commit>/bin/vibeswitcher-host`. Its install root is `NodeFolders.defaultPrefix` from `getpwuid` on
    the node, or `--test-install-root` on a scratch node.
  - It reads the host's notes after the reply to decide the outcome, and replies before its own replacement.
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'SwitchTests|ServerTests|HostLinkTests'`
  - the lints
  - under load (`SwitchTests`)
- [ ] **Step 4:** commit ("v2: build.switch in the server"). Push, both green.

**Done when:** the cases pass on Linux. Row 97 is `ported`. No kind in `NodeWire.kinds` is left answering
`unknown-kind`.

---

### Task S8c: `switch` and `rollback` in the command line

**Needs:** S8b, S2.

**Files:**
- Create: `Sources/vibeswitcher-cli/Switch.swift`
- Modify: `Sources/vibeswitcher-cli/main.swift` (usage: `switch COMMIT | rollback`), `Tests/VibeNodeTests/SwitchTests.swift`,
  the port map (rows 52, 99, 100)

**Interfaces:**
- The CLI's `switch` / `rollback`:
  - `rollback` reads `status`'s `builds.rollback` and shows it in `NodeTexts.rollback`; `switch` shows
    `NodeTexts.switch`. Then the typed code, then `build.switch`.
  - After the server's reply, in node mode only, `SwitchFollowUp.apply`. Its `hostCheck` connects again, runs
    `ServerCheck`, and compares the welcome's pid and `HostNotes.build`.
    *2026-11-16 (the review of S8a):* `apply` takes `accountHome:` (`getpwuid`'s). When the server answers that the
    host runs the target already, in node mode, `SwitchFollowUp.isDone` is asked and, when it says no, `apply` runs
    with the welcome's pid: the way back every follow-up refusal names ("`vs switch <target>` again finishes this").
  - Then the journal's start line (ST-D24) read back and shown.
  - A scratch CLI skips the follow-up, saying "scratch node: no unit to rewrite".

- [ ] **Step 1: Failing tests:**
  - `aSwitchHandsOverToTheInstalledBuildAndEverythingNamesIt`:
    - Two `ScratchBuilds` (`A`, `B`) under a scratch install root; the node runs `A`.
    - `switch B` on a pty, then `status` shows host build `B` and server build `B` once the server is restarted
      (within `ServerChild.idleLimit`).
    - The host's output has `B`'s start line with `SWIFT_BACKTRACE=enable=no`. `rollback` restores all of `A`.
  - `theSwitchsReplyReachesTheCommandLineBeforeTheServerIsReplaced`: the CLI gets the reply with `handedOver(B)` and
    exits 0, though the server it asked is replaced afterwards.
  - `aSwitchWithNoTerminalIsRefused`: `setsid --wait`; the server records no request, and the host's build is
    unchanged.
  - `aRunningToolServerKeepsItsBuildAcrossASwitch` (S9): a tool server started from `A/bin/vibeswitcher-mcp` before
    the switch still runs `A` after it. `BinaryWatch` reports no change, and its reported commit is `A`.
  - `aToolServerStartedAfterASwitchIsTheNewBuilds` (S9): a lead started after `switch B` has a tool server from
    `B/bin`, whose commit is `B`.
  - `aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild` (ST-D16): its MCP config names `A`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter 'SwitchTests|RestartTests'`
  - the lints
  - under load (`SwitchTests`)
- [ ] **Step 4:** commit ("v2: switch and rollback between installed builds"). Push, both green. This commit is
  **C1** for S9.

**Done when:** the cases pass on Linux. Rows 99 and 100 are `ported` (with `not needed` for the app's replace and
restart offer, saying why). Row 52 is `ported` whole.

---

### Task S9: The real node, with the user (M7)

**Needs:** S1 to S8c green on one commit (C1); **M3**, **M5** and **M6** done by the user. M2 isn't needed here: the
user's present `gh` login is expected to read Actions, and the first install's CI check shows whether it does.

**Files:** `docs/process/v2-linux-inventory.md` (the record). No code.

- [ ] **Step 1: The agent prepares, before M5.**
  - Write the user's command card (below) into the inventory, commit, push and watch both jobs. That commit is
    **C2**, the second pushed commit both runners passed.
  - Tell the user M5 can run now: `wsl --shutdown` ends every agent session, so no agent task (S10's gated run
    included) may be running.
- [ ] **Step 2: The agent checks, after M3, M5 and M6.**
  - Read-only checks, reported to the user, not changed:
    - `/opt/swift-6.4.2`: ST-D12's `find` prints nothing (M3);
    - `/etc/wsl.conf` has `[interop] enabled=false` and `appendWindowsPath=false`, and `[automount] enabled=false`.
      binfmt shows no enabled `WSLInterop` (M5);
    - WSLg is off: no `/mnt/wslg`, and no `/run/user/<uid>/wayland-0` (M5's `guiApplications=false`);
    - the sudo rule: `/etc/sudoers.d` can't be read without root, so the user confirms either "no sudo while a team
      runs" or the `timestamp_timeout=0` file (M5);
    - the supervising Claude Code's `permissions.deny` holds M6's rules (both spellings, every subcommand of D14,
      `switch` and `rollback` included, and `Edit(~/.vibeswitcher/v2/**)`).
  - Install **C1** only. Record the install's time and `build-info`.
- [ ] **Step 3: The user's steps, M7.** The agent doesn't run any of the user's steps. After each, the agent reads
  `vs status` and `journalctl --user -u vibeswitcher-node -n 50 --no-pager` (reads D14 allows). The card, in order,
  with what each should print:
  1. `vs status` (none running);
  2. `vs start` (S11's list, its code, the confirmation naming C1, start's code);
  3. `vs status` (the host on C1; no unexplained start);
  4. `vs config held` / `accept` for the first look (the builds folder, `~/.config/systemd/user` with its
     `home-net-review` units, and the rest of the Linux list);
  5. `vs hooks install` (one code for both agents);
  6. the WSL measurement (ST-D22): note the host's and server's start times; close every Windows Terminal and WSL
     window for 10 minutes; reopen one; run `vs status`. If the times changed, the user decides how to keep the node
     up: a terminal left open, or a Windows-side keep-alive of the user's own;
  7. **the agent installs C2 now** (an agent step; the second install runs
     `<prefix>/current/Resources/install-node.sh`, ST-D9), then `vs config held` / `accept` (the builds folder);
  8. `vs switch C2` (the confirmation says the seal's hold), then `vs status`, then `vs config held` / `accept`;
  9. `vs rollback` (the confirmation names C1 and its `installs` line), then `vs status`, then `vs config held` /
     `accept`.

  The card says to type `vs` as `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher` or an alias the user writes.
- [ ] **Step 4: Record** in the inventory, with the date and kernel:
  - each step's output, as lines the user pastes or the agent read;
  - the measurement's result;
  - the switch and rollback outcomes: the host, server and a later tool server's build, and the journal's
    `SWIFT_BACKTRACE=enable=no` line;
  - the open half of ST-D22, and ST-D19's real-snapshot check, for M8.

**Done when:** the node ran from C1, switched to C2 and rolled back, as the user's steps; the measurement is recorded;
and the bootstrap path's step 8 "Proves" holds.

**Prepared for M8 (step 10, the user's):**
- The agent checks, read-only, whether `gpg-agent-ssh.socket` is active.
- It drafts the clone's `.vibeswitcher/workflow.md` floor lines (D13) for the user to read.
- It writes the `printf` line for `~/.vibeswitcher/v2/projects`.
- After the first lead, it reads `vs status` for ST-D22's session half, and `vs config held` for whether a worker's
  start held its team through `~/.claude/shell-snapshots` (ST-D19).

---

### Task S10: A full scratch run (step 9)

**Needs:** S6 (hooks written with `HookInstaller` in harnesses) and S7 (so the run exercises the seal's Linux list
with a full team); E9 Step 2 passed once (M1, after the weekly limit resets). Can run beside S8a to S8c and S9, but
not during M5.

The spec says step 9's task is written once step 8 and E9 are done. It runs on a `ScratchNode`, never the user's node,
so it uses no part of step 8's start, install or switch. It uses only S6's hook path and S7's seal list, and those are
its Needs. E9's Step 2 is still required, as the spec says.

**Files:**
- Create: `Tests/VibeNodeTests/ScratchRunTests.swift`
- Modify: `docs/process/v2-linux-inventory.md`, `docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md` (step 9's
  owner ticked)

**Interfaces:**
- Consumes: `ScratchNode` (`noLoadHold(maxSessions:)`, `runOnTerminal(_:answer:)`, `stop()`), `FakeClaude` (its `mcp`
  op), E9's real-claude script and cleanup pattern (`RealClaudeStatusTests.trust`), `HookInstaller.install`,
  `LeadWorkflow.approval(of:)`, `Worktrees` (`<repo>/.vibeswitcher/worktrees/<slug>`, `agent/<slug>`).
- Produces: `@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(60))) struct ScratchRunTests`, with helpers:
  - `scratchRepository(in:)`: a commit with `src/`, `check.sh` and `workflow.md` per ST-D21;
  - `realClaudeScript(root:config:)`: `--model sonnet` only when absent;
  - `assertScratchForm(_ output:)`: stderr names "scratch node at <root>", and every state change printed its code
    prompt.

- [ ] **Step 1: The rehearsal, ungated.** `aScratchTeamOfFakesBuildsAuditsAndMerges`:
  - The accepts.
  - `lead` (a fake), whose `mcp` ops are: `ask_user`; `start_worker` twice (both live at once in their worktrees,
    under room 4); `audit`; `merge`.
  - The test commits for each fake worker in its worktree. The fake verifier calls its verdict tool, and the vault
    holds the verdict.
  - `questions` lists the question; `answer` is typed.
  - The approval card is answered with `LeadWorkflow.approval(of: commit)`.
  - The merge lands on the base with `check.sh` run (its marker file present).
  - Every CLI call passes `assertScratchForm`.

  Shown failing on two mutants: a merge with no recorded verdict, and an approval bound to another commit. Each must
  fail on its own assertion.
- [ ] **Step 2: The gated run.** `aScratchTeamPlansBuildsAuditsAndMerges`, enabled only with
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` on the run's command line.
  - A real lead on Sonnet with a scripted goal: exactly two tasks touching `src/`, one question to the user, both
    workers started, one audit, one merge.
  - The harness answers the question and the approval from the command line under `script`'s pty.
  - It waits on the board, the vault and git (never a fixed sleep), up to the suite's limit.
  - Cleanup is registered before anything is written into the user's folder: the hooks, then the trust entries for
    the repository and each worktree (each undone only if begun), and the node stopped on every way out.
  - Asserted:
    - two `agent/*` branches each with a worker's commit;
    - a verdict in the vault from a verifier on a model other than the workers';
    - one merge commit on the base whose tests ran;
    - the lead's question answered as the user's (its action and digest in the vault);
    - `assertScratchForm` on every call.
- [ ] **Step 3: Verify.**
  - `bash scripts/test.sh --filter ScratchRunTests`: Step 1 runs, Step 2 is skipped.
  - under load: `scripts/test-under-load.sh --load 24 -r 3 -f 'ScratchRunTests'`.
  - With the user's go-ahead, per run (at most three):
    `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=~/.vibeswitcher-test-claude vs-heavy bash scripts/test.sh --filter
    ScratchRunTests/aScratchTeamPlansBuildsAuditsAndMerges`.
  - Record each run in the inventory: Claude Code version, models, each step's time, the cost seen, and what failed.
- [ ] **Step 4:** commit ("v2: a full scratch team run"). Push, both green: by the lead before M2, by the user after.

**Done when:** Step 1 passes on Linux, and Step 2 passed once here (or waits, saying why, as an open item). That is the
bootstrap path's step 9 "Proves": the design's stage 4 Done-when on a scratch repository.

---

## Order

| Task | Needs | Runs beside | The user |
| --- | --- | --- | --- |
| S1 | the engine sweep merged into `v2` | S4a, S6, S7 | — |
| S2 | S1 | S4a, S4b, S5, S7 | — |
| S3 | S2 | S4b, S4c, S5, S6, S7 | — |
| S4a | the sweep | S1 to S3 | — |
| S4b | S4a | S2, S3, S5 to S7 | — |
| S4c | S4b | S3, S5 to S8c | **M3** before its gated case (the agent prepares the commands and checks the result) |
| S5 | S4a | S2, S3, S4b, S4c, S7 | — |
| S6 | S5 | S3, S4b, S4c, S7 | — |
| S7 | the sweep | S1 to S6 | — |
| S8a | S1, S2 | S3 to S7 | — |
| S8b | S8a, S4a, S5 | S6, S7, S4c | — |
| S8c | S8b, S2 | S6, S7, S10 | — |
| S9 | S1 to S8c green on C1 | S10 (not during M5) | **M3, M5, M6** before Step 2; **M7** is Step 3; the agent prepares **M8** |
| S10 | S6, S7; E9 Step 2 passed | S8a to S8c, S9 (not during M5) | **M1** folder and a go-ahead per gated run |

- Every job is green before the next task's first push, whatever runs beside.
- **M5** runs after C2 is green and before S9 Step 2, while no agent task runs: `wsl --shutdown` ends every agent
  session.
- **M2** (the read-only token) comes after the lead's last push: C2 at the latest, or S10's commit if S10 finishes
  first. M2 is needed before step 10, not before S9. After M2 the user pushes every remaining commit of this plan.

## The port-map rows each task fills

| Task | Rows of `docs/process/v2-port-map.md` it makes `ported`, `made` or `not needed` |
| --- | --- |
| S2 | `HostClientSlowStartTests` (part of row 99; `anotherHostListeningIsConnectedToWhileOursStillStarts` as `aListenerThatFailsTheServerCheckIsNotTheNodeStarting`) |
| S3 | `HostClientReapTests` (row 98); `HostRestartTests` (its second case, row 100); `HostClient.swift` (row 52): starting and reaping (183-221, 293-366) |
| S5 | Non-seam row 223 (`LeadGateBuild.swift`), and the new gate-text, `HostNotes`, `HostServer.swift` and `vibeswitcher-host/main.swift` rows |
| S6 | `AppDelegate.swift`'s `HookSetup`/`HookBinary` (row 55) |
| S7 | Non-seam row 224 (`ConfigSeal.swift`), and the new `Watched.Kind`, `isHome` and (if needed) `LeadVault.judge` rows |
| S8a | `HostClientPlanTests` (row 99); `HostRestartTests` (its first case, renamed `aSwitchSaysItKeepsSessions`; row 100) |
| S8b | `HostClientHandoverTests` (its ten remaining cases; row 97); `HostClientSlowProbeTests` (row 99) |
| S8c | `HostClient.swift` (row 52): the plan and handover outcome (527-650), and so the whole row |

## Changes to the spec

What this plan does differently from the bootstrap path and the security document, each for the reason in its
decision. S4c and S8b write them into those documents.

- The unit folder is always `<getpwuid home>/.config/systemd/user`, and the manager is checked after `daemon-reload`
  (`FragmentPath`, no drop-in). The command line's `XDG_*` play no part (ST-D2).
- `start` refuses, not only names, an extra variable in the manager's environment (ST-D2).
- On a machine whose pid 1 is systemd, a missing manager socket is refused, never taken as "no systemd" (ST-D2,
  ST-D6).
- The start command's tests run on `VibeNode` types in process; the scratch command line starts nothing (ST-D1).
- The unit's swift and node folders come from fixed places, not the shell's PATH (ST-D4).
- The detached start is a `posix_spawn` with `SETSID`, not a double fork, with a fixed environment (ST-D6).
- `stop` falls back when the server doesn't answer or fails its check, not only when nothing listens (ST-D7).
- The install fetches the commit by its hash from GitHub into a fresh repository, and trusts nothing in the user's
  clone. "A clean, detached `git worktree add`" is of that fresh repository (ST-D9).
- S9's maps test reads the host image's maps through dumpable stand-ins. The server is covered by `readelf` and the
  loader's resolution, since a non-dumpable process's maps are refused to its own uid (ST-D12).
- M2's token also reads Actions and Contents (ST-D10).
- `hooks.install`'s argument is a list of agents, and it installs only bytes the host's `build-info` names (ST-D17).
- The rule on switches stays after Task 3b's measurement, until the in-flight count (ST-D15).
- A team keeps its build until its lead restarts (ST-D16).
- A switch, a rollback and an install leave the seal holding every team until `config accept` (ST-D23).
- The host's start line counts only from the unit's main pid on stdout (ST-D24).
- The seal's list adds what this machine's startup files source (`.bash_aliases`, nvm's scripts, rally's aliases),
  swiftly's `config.json`, systemd's other unit and drop-in folders, and `~/.config/gh` (S7).
- `~/.config/systemd/user` is no longer empty here: it holds the user's `home-net-review` units, so the seal's first
  look holds them until accepted (the spec's "has no units" is stale).
- `.bash_login` is already watched (`ConfigSeal.swift:311`); S7 adds only the rest.

## Done when

- `StartCommandTests`, `ServerCheckTests`, `InstallTests` (ungated), `ServerBuildLinuxTests`, `HooksCommandTests`,
  `LinuxSealListTests`, `SwitchTests` and `ScratchRunTests` (Step 1) pass on Linux, with the lints.
- The `v2 linux` and `v2 macos` jobs are green on one commit, the Mac running the pure and Mac-only cases each task
  names.
- The static-product cases passed here, and the gated static build passed once (after M3).
- The user's M7 steps ran the node from an installed build and switched and rolled it back, recorded in the
  inventory, with the WSL measurement.
- The gated scratch team run passed once, or waits as an open item, saying why.
- Every port-map row above is `ported`, `made` or `not needed` with its reason, and every shared-file edit is in
  [Non-seam edits](#non-seam-edits-this-plan-makes).
