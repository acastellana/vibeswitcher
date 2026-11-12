# VibeSwitcher 2, Stage 2 (The Session Host on Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The security architecture document is written and reviewed first. Then `VibeHost` and `vibeswitcher-host`
build on Ubuntu, and `VibeHostTests` and the host's security audit pass there through `scripts/test.sh`. On Linux the
host names a session's terminal as everything else does (`ttypts<N>`), checks the sender of every message, counts as
"the app" only the server child it started (on any connection that child opens), starts sessions and parsers from its
own image, and keeps its own memory, its parsers' and its server's out of a worker's reach. The lead's tool server
lists its tools under a scratch host, and a real `claude` under a scratch host survives its client quitting, a
handover and a killed parser. The Mac build and suite stay green.

This stage is cut to what the bootstrap needs ([the bootstrap path](2026-11-13-v2-bootstrap-path.md)). Confinement
(the sandbox, the egress proxy) comes after the bootstrap, as the design says, and so do, by this plan's decisions,
sessions identified by an inherited socket, clones for workers, the host as a subreaper and the handover through
sealed memory.

**Architecture:** `VibeHost`'s Darwin calls switch to `VibePlatform` as `VibeCore`'s did. Its two Mac-only pieces
(the cdhash check in `AppCode.swift` and the Keychain half of `VaultStorage.swift`) move into `VibePlatform`'s Darwin
files, with Linux forms that answer "no such thing", and the names `AppCode.runs` and `VaultStorage.keychainKey()` stay
as forwards, so the Mac's path and its tests are unchanged. What the host does only for version 2 (the server child,
the project allow-list, the handover target's check) lives in new files under `Sources/VibeHost/V2/`, which main never
has. Each existing shared file gets a switched call, or a hook into a `V2/` file, each listed in
`docs/process/v2-port-map.md`.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM `--build-system native`, SwiftTerm 1.19.0 (pinned; builds on
Linux), swift-crypto 3.15.1. The C shim `CVibePlatform` gains `posix_openpt`/`grantpt`/`unlockpt`, `TIOCSCTTY`,
`prctl` (`PR_SET_DUMPABLE`, `PR_GET_DUMPABLE`), `O_PATH` and `pidfd_getfd`.

**Spec:** `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md` (Security; The node's processes; The bootstrap;
Stage 2), and the security architecture document Task 1 writes,
`docs/superpowers/specs/2026-11-13-v2-security-architecture.md`. **Measured:** `docs/process/v2-linux-inventory.md`
(`VibeHost`: 142 errors in 8 of 13 files), `docs/process/v2-stage1-recon.md` §1.2, §1.7, §1.9 (the host's four spawn
sites mapped onto `Platform.Spawn`). Where this plan and the recon differ, this plan is right. Code references are at
`47636aaf`.

**Facts about this machine that shape it** (read 2026-11-12 and 2026-11-13):

- Kernel 5.15.167.4-microsoft-standard-WSL2. No `SO_PEERPIDFD` (6.5+).
- No `/proc/sys/kernel/yama`: any process of the user may ptrace any dumpable process of the user.
- `net.core.wmem_max` is 212992.
- pid 1 is systemd (`/etc/wsl.conf`: `systemd=true`); the user's own `systemd --user` runs (pid 284), with lingering
  on (`/var/lib/systemd/linger/albert`). No user units in `~/.config/systemd/user`.
- No `bwrap` and no `zsh`. `script` (util-linux) and `nc` are installed.
- `locale -a`: C, C.utf8 and POSIX only.
- `claude` is `~/.local/bin/claude`, a link to `~/.local/share/claude/versions/2.1.322`.
- The agent sandbox this work runs in allows memfd and seals, `PR_SET_DUMPABLE`, `PR_SET_CHILD_SUBREAPER`,
  `pidfd_open` and Unix sockets; non-dumpable makes `/proc/<pid>/mem` and `exe` refuse with `EACCES`.

## Global Constraints

- Everything in stage 1's Global Constraints holds: all work on `v2`; nothing under `Sources/VibeSwitcher`,
  `Tests/VibeSwitcherTests` or `Web/` is edited; tests only through `scripts/test.sh`; agents install nothing; a fix's
  test is shown failing without the fix; Swift here is set up with `. ~/.local/share/swiftly/env.sh`; every job green
  before the next task's first push, under stage 1 R3's time box for Mac-only failures.
- An edit to an existing file under `Sources/VibeHost`, `Sources/vibeswitcher-host` or `Sources/VibeCore` is one of:
  1. a call switched to `VibePlatform`;
  2. a type spelled through the platform (`audit_token_t` to `Platform.PeerToken`, which is the same type on the Mac);
  3. a whole file or a named block moved with `git mv`, or a block's body moved into `VibePlatform` with the old name
     left as a forward;
  4. a hook of one or two lines into a new file under `Sources/VibeHost/V2/`;
  5. a `Config` field, or a member of `HostServer`, whose default keeps the Mac's behaviour;
  6. a field added to a `Codable` record as an optional, so the format number stays and older builds still read it.

  Kinds 4 to 6 each get a line in `docs/process/v2-port-map.md`'s Non-seam edits: file, line, why, merge cost. The
  ones this plan expects are listed in its tasks; an executor who needs another stops and asks.
- **No behaviour change on the Mac.** Every Darwin form is the old body moved. Where Linux gains something (the
  server child, hardening, the launcher from the own image), the Mac's form does nothing or keeps today's behaviour,
  and a test on the Mac says so.
- **How "on Linux" is decided outside `VibePlatform`.** `PlatformLint` forbids `#if os` there, so every switch this
  plan makes in `VibeHost`, `vibeswitcher-host` or a test reads one platform value: `Platform.CodeIdentity.isAvailable`
  (Task 4b), true on the Mac (the cdhash check exists) and false on Linux. Where this plan says "on Linux" in a shared
  file or a test, it means `!Platform.CodeIdentity.isAvailable`, and the Mac's form of that switch is "does nothing",
  with a Mac test saying so where the task lists one. A platform call whose Darwin form is "does nothing" (for
  example `Platform.Sockets.enableCredentials`) says so in its doc comment.
- Host tests use scratch hosts on their own lock and socket (`TestHost`), never the user's `~/.vibeswitcher`.
- **Never harden the test process itself.** A non-dumpable process's `/proc` entries become root's, and other tests
  read the test process's. Hardening is tested in helper processes only.
- Real agents only in gated tests, on Sonnet, in a Claude Code config folder the user prepared and named in
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`, never the user's own `~/.claude`.
- A new test suite whose name ends in `Lint` is named in `docs/guide/development.md`.
- Commit messages end with the attribution line the session gives.

## Decisions this plan makes

Each is the author's call, numbered S2-D1 and up (stage 1's Decision 6 is "the binary decision"). Each says what the
user is asked to confirm. The user's answers are recorded in the design's Decided section before Task 2 starts; the
document Task 1 writes holds the reasoning in full.

1. **S2-D1: Who "the app" is on Linux: the server child the host started, recognised by its pid and start time.**
   The host is started with `--server PATH`. It starts PATH itself and records the child's pid and start ticks on its
   own queue, in the same turn as the spawn, so no connection can be accepted before the record exists. From then on,
   any connection to the host's socket whose `SO_PEERCRED` pid and start ticks are the child's is `.app` at once, with
   no challenge, and each message on it is checked again by `SCM_CREDENTIALS` (S2-D4). The child's own children are
   not the app. When the child exits, the record is cleared before the child is reaped, so its pid can't be reused
   while the record stands; the host then starts it again. *Why:* the engine is rebuilt from the app's code, which
   reaches the host through `HostCall` and `LeadVault.standard`, and these open a new connection by path for every
   call (`SessionDigest.swift` 147-164), so "the one connection the host handed over" can't be the app. Nothing in
   `/proc` proves which code a process runs, a key file in `~/.vibeswitcher` is readable by every unconfined worker,
   and rule 6 forbids "the app" as a principal: a process the host started and watches is one the host created.
   *No inherited descriptor:* the server connects by path like any client, so `Platform.Spawn` needs no way to move a
   descriptor to another number (its `keep` keeps numbers; only 0 to 2 can be given another descriptor). When stage 3
   hands the server the listeners the host owns, their numbers go in an environment variable, as systemd's socket
   activation does. *The Mac is unchanged:* `identify` still asks `config.appExecutable` through `AppCode.runs`
   (cdhash) and then `AppProof`'s HMAC, so the eleven app test files that build `HostServer.Config` with
   `appExecutable` (`AppKeyStoreTests`, `HostProofRefusedTests`, `InputUnitDeliveryTests`, `LeadRelaunchTests` and
   seven more) keep working; the Linux principal is a separate member, `HostServer.appPrincipal`, nil on the Mac.
   *What a worker can and can't do against it before the sandbox* (written into S2 and S11):
   - It can't connect as the app: its pid isn't the child's.
   - It can't send on the server's connections: a message from another pid turns that connection into nobody's
     (S2-D4), and the server's descriptors can't be taken with `pidfd_getfd` or reopened through `/proc`, because the
     server is non-dumpable (S2-D5) and a socket can't be opened by path through `/proc/<pid>/fd`.
   - It can kill or stop the server (the same user may signal it). The host restarts it, from the image it held at its
     own start, not from the file on disk (S2-D7). That is a denial of service, not a takeover.
   - It can ptrace the server in the moment between its `exec` and its first statement, before it makes itself
     non-dumpable. The server checks `TracerPid` right after and exits if traced, but a tracer that attached in that
     moment can change the code before the check runs. This is on the not-promised list.
   - It can replace the installed binaries on disk, which the user can write, and **it chooses when the next start of
     the host happens**. The host can be signalled by the same user, and a worker can run `systemctl --user stop`,
     `start`, `restart`, `edit`, `set-environment` and `daemon-reload` itself: `systemctl` finds the user's manager
     at `/run/user/<uid>` without `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS`, so S2-D12's environment list gives
     no protection here. The restarted host runs whatever the unit file, its drop-ins, `~/.config/environment.d`, the
     manager's environment (`LD_PRELOAD` included) and the install folder name, and that includes the `--server`
     program, which becomes the app. So before the sandbox, a worker that tries can put its own code in the host and
     in the app within seconds. S2-D7's held images protect only the restarts the host makes itself. On the Mac,
     replacing files never makes anyone the app, because the cdhash check refuses it: this weakness is Linux's.
     What reduces it before the bootstrap (the bootstrap path, step 8, and Task 9): the unit has `Restart=no`, so a
     killed host stays down until the user's `vibeswitcher start`; `ExecStart` names the commit's folder, not
     `current`; at start the user's host checks its own image and its `--server` image against `build-info` (a
     record the worker can rewrite too, so this catches a slip, not an attacker); and `vibeswitcher status` shows the
     host's start time and any start the user didn't make, for the user to acknowledge. All of it is on the
     not-promised list.
   - It can act as any session, the lead and the verifiers included. With no Yama, it can ptrace a session's agent or
     tool server (dumpable, as session programs are) and send on that process's host connection, or open new
     connections from inside it: that process really is in that session. So it can call the lead's tools
     (`start_worker`, `merge`, the vault's lead requests) or cast a verifier's pass ballot. Before the sandbox,
     verdicts and merges are guard rails on Linux, not locks. On the Mac, `task_for_pid`'s rules keep a worker from
     doing this.
   - It can act as the user towards the server's command-line socket by escaping its session (S2-D6 and S3), or
     through the user's own processes (a `vibeswitcher` earlier on PATH, an alias in a shell startup file, ptrace of
     the user's shell or of a running `vibeswitcher`), which is a guard rail until approvals are signed.

   *The user confirms:* that until signed approvals (after the bootstrap), "the app" on Linux is this principal, and
   that the residual risks above (chiefly: a worker that tries can restart the host into its own code, and can act as
   any session) are acceptable while the only project on the node is VibeSwitcher's own.
2. **S2-D2: The Mac-only bodies move into `VibePlatform`; the names stay.** `AppCode`'s cdhash check and
   architecture read become `Platform.CodeIdentity` (Darwin: the bodies moved; Linux: `runs` is false and the reads
   nil). `VaultStorage.keychainKey` and `removeKeychainKey`'s `SecItem` calls become `Platform.Keychain` (Darwin: the
   bodies moved; Linux: nil and nothing). `AppCode.runs` and `VaultStorage.keychainKey()` stay as one-line forwards,
   so `HostServer.identify`, `AppCodeTests` and `KeychainLintTests`' rule about who calls `keychainKey(` hold.
   `KeychainLintTests.onlyTheKeyStoresCallTheKeychain` gets the new path. *Why not `VibeHost/MacOnly`:* both names are
   called from portable code (`HostServer.swift:666`, `vibeswitcher-host/main.swift:129`), and a Linux stand-in would
   need an `#if` outside `VibePlatform`. *The user confirms:* nothing; it's mechanical.
3. **S2-D3: In plain mode the vault's key lives in memory only.** `VaultStorage` with a nil key already keeps the
   vault in memory (`VaultStorage.swift:11, 40`), and a handover carries it as the secret. A host restart (a WSL
   shutdown, a reboot, or a worker that restarts it: S2-D1) loses the teams' roles, verdicts and ballots, the user's
   sealing key and **the config seal's hashes** (`ConfigSeal.swift:10-14`), and the host log says "vault in memory
   only". The strong mode's key file comes after the bootstrap; before the sandbox it wouldn't help, since a worker
   can read a 0600 file of the user's.
   *The seal after a restart.* A fresh vault seals what is on disk at its first look: a key with nothing recorded
   never differs (`LeadVault.swift:1366`, `differ` needs `recorded[key] != nil`). So a worker could edit
   `~/.bashrc`, `~/.vibeswitcher/bin/vibeswitcher-hook` or `~/.claude/settings.json`, restart the host, and have the
   edit taken as the baseline. On the Mac the seal outlives a host restart, sealed on disk under a Keychain key. So
   on Linux, a memory-only vault **holds what it first sees**: `LeadVault.Book` gains `holdsFirstLook: Bool` (false by
   default, so the Mac's vault is unchanged; kind 5), which `main.swift` sets on Linux when the vault is memory-only
   and not handed over. At that first look every watched thing is held as "first watched", as a plugin first seen is
   today; the lead's own start is never held; workers, verifiers and merges wait until the user's `vibeswitcher
   config accept`, which shows the names and modification times of what it accepts (Task 10, and the engine's E8).
   *The user confirms:* that a host restart ends the lead's team state, and the lead is started again (the engine
   plan's restart path); and that after every host restart the user accepts the config once from the command line.
4. **S2-D4: Each message's sender is checked.** On Linux each read takes its sender from `SCM_CREDENTIALS`
   (`Platform.Sockets.receive`). A missing sender (it exited before the read), a different sender, or a frame made of
   two senders' bytes turns the connection into `.unknown` for good. On the Mac `LOCAL_PEERTOKEN` already names the
   last sender (`checkPeer`, `HostServer.swift:642-654`). *Doesn't promise:* that nobody else reads from a connection,
   or that the sender didn't exec another program (the token keeps its pid and start). *The user confirms:* nothing.
5. **S2-D5: The host, its parsers and its server are non-dumpable.** First thing in each of those modes:
   `PR_SET_DUMPABLE 0` and `RLIMIT_CORE 0`, then `TracerPid` from `/proc/self/status`; a traced process refuses to
   start, and a traced new image after a handover refuses its secrets and goes back. Session programs are left as they
   are. On this kernel, with no Yama, this is what keeps a worker out of the vault's memory and the screens.
   *Doesn't promise:* the moment between `exec` and that first statement (above). Making the installed images
   unreadable (mode `0111`) would close it, because the kernel then makes the image non-dumpable from `exec`; it is
   left for after the bootstrap, since the handover target's check (S2-D7) reads the image to hash it. *The user
   confirms:* nothing.
6. **S2-D6: The host is not a subreaper before the bootstrap.** The design lists the subreaper under "also
   required". It is deferred, with the sandbox, whose own process namespace makes ancestry exact. *Why:* as a
   subreaper the host would adopt every orphan of its sessions, and reaping them takes exit statuses from code in the
   host that waits for its own children by pid (`Git.run` in the vault's base moves, `LeadBaseMoves.swift:121-133`;
   `PipeCommand+Linux.swift:128`; `HostHandover.swift:187`): a reaped `git merge-base --is-ancestor` reads as success.
   Nor would it give a double-forked process a session: `session(of:)` (`HostServer.swift:672-689`) finds a session by
   its program in the ancestry or by its terminal, and an adopted orphan's ancestry is `[orphan, host, …]`. *Instead:*
   on Linux the orphan sweep looks for a tool server whose parent is pid 1 or the subreaper an orphan of the host's
   gets (on this machine, the user's systemd). That parent is found at start, not guessed from the host's ancestors
   (which, for a scratch host, include the test runner and Claude Code, whose live tool servers must never be ended):
   the host starts a probe that orphans a child of its own and reads the parent that child is given. On the Mac that
   set is `{1}`, as today. *Doesn't promise:* a worker process that double-forks and calls `setsid` leaves its session's
   ancestry and terminal; to the host it is nobody (it gets no session's rights), but to the server's command-line
   socket it looks like the user (S3). *The user confirms:* that this escape is accepted until signed approvals, on
   VibeSwitcher's own repository only.
7. **S2-D7: What the host executes.** On Linux the launcher is `/proc/self/exe`, resolved in the spawned child before
   its exec, so sessions and parsers start from the host's own image; no copies are made under
   `~/.vibeswitcher/host`. At start the host opens its own image and its server's with `O_PATH` and keeps both
   descriptors: a failed handover falls back through `/proc/self/fd/<own>` (the descriptor is kept across the
   handover's exec, Task 9), and the server is started through `/proc/self/fd/<server>` with that descriptor kept in
   the child (`keep: [fd]`: `Platform.Spawn` closes everything else from 3 up before `execve` resolves the path, so a
   descriptor not kept would make the path vanish), so a file replaced on disk is never what runs next. In the
   user's host (`HostServer.Config.installRoot` set, Task 9) a handover target must be in the install folder and match
   the SHA-256 the install recorded for it in `build-info`; a path inside a worktree or under a session's working
   folder is refused. Scratch hosts have no install root and hand over as today. Signed releases come in stage 8. The
   Mac keeps its launcher copies. *Doesn't promise:* the install folder and its record are the user's to write before
   the sandbox, and a restart the worker causes runs what they name (S2-D1). *The user confirms:* nothing beyond
   S2-D1.
8. **S2-D8: The handover keeps its state file and socket channel on Linux before the bootstrap.** The state goes to
   `lockPath + ".handover"` and the secret through a socket, as on the Mac. On Linux the socket takes about 200 KB
   (`wmem_max` 212992): a vault bigger than that makes the handover fail before the exec, and the host stays as it was
   (`HostHandover`'s rule: anything failing before the exec leaves the host as it was). The sealed-memory channel is
   after the bootstrap.
   *The state file is checked on Linux.* The file is written by path and read back by path (`HostHandover.swift`
   96-126, `main.swift` 106-117), so a worker of the same user could rename a forged file into place during the
   probe (up to `HostHandover.probeLimit`, 180 s). The file names each session's `childPID`, `tty`, `startedBy` and
   `openedByApp`, and from Task 8 the server child's record: forged, it could make a worker's process any session's
   program (the lead's included), mark its session as opened by the user (`HostServer.swift:168-172`, `isYours` at
   627), or make it the app. So on Linux the build handing over sends the SHA-256 of the bytes it wrote (hashed in
   memory, never read back) through the secret channel, which only the new image inherits; the new image refuses a
   state whose hash differs and goes back, giving its fallback the expected hash in the fallback's argv (set inside
   the host's own process, which a worker can't change). On the Mac nothing changes. Task 8 builds it, since Task 8
   is first to put an identity in the file.
   *Doesn't promise:* a worker can delete or spoil the file, which makes the handover fail and the host go back (a
   denial of service, not a takeover). *The user confirms:* that this is accepted until the sandbox, on
   VibeSwitcher's own repository only.
9. **S2-D9: Sessions identified by an inherited socket come after the bootstrap.** Identity stays process ancestry,
   the session's terminal and `BranchCode`. The connector (one `SOCK_SEQPACKET` pair per session, its number in
   `VIBESWITCHER_HOST_FD`, connections passed over it with `SCM_RIGHTS`) is specified in the security document and
   built with the sandbox it serves. *Why:* it changes `HostConnection` in `VibeCore`, which main changes often; it
   needs Claude Code and Codex to pass a descriptor through to their tool servers and hooks, which nobody has checked;
   and until the sandbox, ptrace takes a connector anyway. *The user confirms:* this moves an item of the design's
   bootstrap table (stage 2, before) to after.
10. **S2-D10: Clones for workers come after the bootstrap.** They are `VibeCore`'s (`Worktrees`,
    `LeadToolset.start_worker`), not the host's, and exist for the sandbox. *The user confirms:* the same move.
11. **S2-D11: A project allow-list in the user's host on Linux.** A `spawn` whose working folder isn't inside an
    allowed repository is refused, saying why. The list is `~/.vibeswitcher/v2/projects`, one path a line. A folder
    is inside an allowed repository when it is the repository or one of its worktrees, found by reading files, never
    by running git in a folder a worker controls: the folder's `.git` file names `gitdir:`, that folder's `commondir`
    names the common `.git`, and the allowed repository's own `.git/worktrees/*/gitdir` must point back at the folder
    (a forged `.git` file is refused). The list's place is `HostServer.Config.projectAllowList: URL?`, nil by default
    (the Mac's behaviour; kind 5), which `main.swift` sets on Linux for the user's host only. Scratch hosts have no
    list. It goes when the user marks stage 6 passed. A guard
    rail, written down as one. *The user confirms:* the file's place, and that the user (not an agent) writes its one
    line for the bootstrap clone.
12. **S2-D12: The sessions' environment is a platform answer.** The Mac keeps today's list (`vibeswitcher-host/main.swift:27`).
    Linux passes `HOME USER LOGNAME SHELL TMPDIR PATH LANG LC_ALL LC_CTYPE XDG_RUNTIME_DIR` and never `SSH_AUTH_SOCK`,
    `WSL_INTEROP` or `DBUS_SESSION_BUS_ADDRESS`. A session's default `LANG` is `C.UTF-8` on Linux (`en_US.UTF-8` isn't
    installed here; `HostedSession.swift:129`). *Doesn't promise:* keeping a session away from the user's systemd:
    `systemctl --user` finds the manager at `/run/user/<uid>` with none of these variables (S2-D1). *The user
    confirms:* that a lead's session can't use the user's ssh agent (the bootstrap's lead pushes nothing).
13. **S2-D13: No `vibeswitcher attach` in this stage.** The command line talks to the server (rule 2), not the host.
    The proofs here are tests.

## Review Focus

1. No connection is `.app` on Linux except one whose process is the host's live server child; a message on it from
   any other process makes it nobody's; the child's own children are never the app (Tasks 4b, 7, 8).
2. The Mac's app check is untouched: a `Config` with only `appExecutable` set still makes the app's code the app after
   its proof, and the app's eleven test files that rely on it pass unchanged (Task 4b).
3. Without Yama, a worker can't open the host's, a parser's or the server's memory or descriptors, after start and
   after a handover (Task 9).
4. A session's terminal is `ttypts<N>` in `HostSession.tty`, in `ProcessTable`, in the hook's state file name and in
   the steer inbox (Task 6).
5. Nothing the host runs comes from a file replaced after its start: launcher, parser, fallback, restarted server
   (Tasks 8, 9). Nothing the handover's state file says is believed unless its hash came through the secret channel
   (Task 8).
6. No test-only flag (`--test-app-pid`, `--handover-test-secret`, `--handover-test-secret-file`, `--install-root`,
   `--handover-test-traced`) is honoured by the user's host (Tasks 5a, 9).
7. The Mac: every Darwin path is the old body; every "on Linux" switch reads `Platform.CodeIdentity.isAvailable` and
   does nothing on the Mac; the host and app jobs of `v2 macos` are green after every task.

---

### Task 1: The security architecture document

Written and reviewed before Task 2 starts.

**Files:**
- Create: `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`,
  `docs/process/reviews/v2-security-review-<date>.md`
- Test: `Tests/VibeCoreTests/SecurityDocumentLintTests.swift`. Modify `docs/guide/development.md` (name the suite).

**Interfaces:**
- One section per decision, `S1` to `S12`. Each states the decision, why, what it doesn't promise, whether it is
  needed before the bootstrap, the stage that builds it, and a `Held by:` line naming tests (`Suite.test`) or
  `planned: <plan> task <n>`.

- [ ] **Step 1: The failing lint.** `SecurityDocumentLintTests.everyNamedTestExists`: each `Suite.test` in a `Held by:`
  line has a `func test` in that suite under `Tests/`. `everySectionSaysWhatItDoesNotPromise` and
  `everySectionSaysWhenItIsNeeded` ("Before the bootstrap:" yes or no). Shown failing on a draft naming a test that
  doesn't exist.
- [ ] **Step 2: Write it.** Each section takes the recommendation below unless the user decided otherwise.

  | § | Subject | Recommendation | Before the bootstrap |
  | --- | --- | --- | --- |
  | S1 | Threat model and modes | The design's four adversaries; plain mode and strong mode; this machine's facts, the missing Yama first | yes |
  | S2 | The app on Linux | S2-D1, with the list of what a worker can and can't do; the server non-dumpable from its first statement | yes |
  | S3 | The user's voice before signed approvals | The command line talks to the server's 0600 Unix socket. "The user's voice" is a peer of the same uid whose ancestry contains no live session's program, no parser, the server or the host, whose terminal is no session's, whose environment has no `VIBESWITCHER_SESSION`, and that isn't under a `BranchCode` runner. Every request the socket takes is listed with the voice it needs: **the user's voice** for `lead` (it opens an app session, whose git commands `isYours` treats as the user's), `stop`, `hooks install` and `hooks remove` (written as the app, `vault.appWrite`, so sealed), `answer`, `hold`, `config accept`, `base accept`, and any later request that changes state; **anyone of the uid** for `status` and `questions`; anything not listed is refused. Each accepted user's-voice request is echoed to the server's log and shown by `status` (what was sent, when, from which pid), so the user can see what went in their name. Doesn't promise: a worker that double-forks and calls `setsid`, or uses `systemd-run --user`, `at`, cron, `ssh localhost`, WSL interop or a new pty of its own, can pass; so can the user's own genuine processes acting for a worker: a `vibeswitcher` placed earlier on PATH (`~/.local/bin` is writable and first), an alias or function in a shell startup file, or ptrace of the user's shell or of a running `vibeswitcher` (dumpable, no Yama), any of which can send the user's `answer ID no` as yes or turn it into `config accept`. Acceptable only on VibeSwitcher's own repository until stage 4's signed approvals. Held by the engine plan's tests | yes |
  | S4 | Session identity | Today's rule (ancestry, terminal, `BranchCode`), and the inherited connector in full for after the bootstrap (S2-D9): the pair's type, its number, `SCM_RIGHTS` adoption, the `BranchCode` wrapper closing it, the handover carrying it, `HostConnection` trying it first | no (the connector) |
  | S5 | Per-message credentials | S2-D4; `SO_PEERPIDFD` where the kernel has it (6.5+; not here); a sender gone before the read is refused | yes |
  | S6 | Hardening | S2-D5; what non-dumpable makes root's under `/proc/<pid>` and which readers that touches (`SessionStrays`, `ProcessTable` reading the host): an unreadable host is "the host", never "gone"; the exec window; the `0111` install mode for later | yes |
  | S7 | The vault's key per mode | S2-D3, with what a restart erases (seals, verdicts, ballots, held changes) and that a worker can cause one at will; a fresh memory vault holds what it first sees until `config accept`; strong mode's 0600 key file under `~/.vibeswitcher/keys`, never mounted into a sandbox (and no help before the sandbox, since a worker reads the user's files) | plain mode yes; strong mode no |
  | S8 | The handover | S2-D8: the state file's hash through the secret channel on Linux, a forged file refused, a spoiled one a denial of service; the server child's record checked again on restore (its parent is the host, its start ticks match, it is no session's program or parser); a downgrade refused (rule 11, `HostHandover.format`); the test-only secret flags refused by the user's host; sealed memory after the bootstrap, and with it the 4 MB secret | the file and socket, yes; sealed memory no |
  | S9 | What the host executes | S2-D7. Notes that the kernel refuses an in-place write to a running image (`ETXTBSY`), so the realistic replacement is a rename; that held images protect only the restarts the host makes itself; and what a restart from systemd runs (the unit, its drop-ins, `environment.d`, the manager's environment, the install folder), with the bootstrap's `Restart=no`, `ExecStart` on the commit folder and the start-time check against `build-info` | yes |
  | S10 | The sessions' environment | S2-D12 | yes |
  | S11 | What plain mode doesn't promise on Linux | **A worker can restart the host at will** (a signal, `systemctl --user`), and the restarted host runs what the unit, its drop-ins, `environment.d`, the manager's environment and the install folder name, the `--server` program (the app) included; the restart also empties the vault (S2-D3). **A worker can act as any session**, the lead and the verifiers included: ptrace of a session's agent or tool server, and `pidfd_getfd` of its descriptors, put it inside that session, so it can call the lead's tools or cast a verifier's ballot, and verdicts and merges are guard rails. Another session's `/dev/pts/N` is the user's to read and write; the user's own processes can act for a worker (PATH, aliases, ptrace of the user's shell or CLI; S3); `/proc/<pid>/environ` and `cmdline` of the user's processes; the escapes in S3; `SCM_CREDENTIALS` names no reader and no exec; `LD_PRELOAD` into a fresh host binary (the Mac's `library-injection` audit has no Linux form); the exec window before hardening (S2-D5); the installed binaries and their recorded hashes are the user's to replace, taking effect at the next host start, which a worker can cause (S2-D1, S2-D7); a spoiled handover state file, a denial of service (S2-D8); the user's crontab (`/var/spool/cron`, read only through `crontab -l`, not by the seal); the project allow-list is the user's to edit; the vault is lost with the host (S2-D3); logs: the host and tool server logs aren't yet checked for tokens, codes and terminal text (a lint after the bootstrap) | yes (the list itself) |
  | S12 | After the bootstrap | The sandbox through the shim (`unshare`/`clone3`, `pivot_root`, a devpts of its own with only the slave passed in), not bubblewrap, which isn't installed and an agent may not install; an AppArmor profile for the host on Ubuntu 24.04 bare metal (`kernel.apparmor_restrict_unprivileged_userns=1` there); the egress proxy; clones for workers; the connector; the subreaper, inside the sandbox; strong mode; sealed handover; `0111` images; signed approvals; the support matrix rows | no |

- [ ] **Step 3: Review.** A reviewer who didn't write it (a fresh subagent with the design, this plan and the host's
  code) reads it as an attacker and records findings in `docs/process/reviews/v2-security-review-<date>.md`. Each
  finding is answered in the document or in that record.
- [ ] **Step 4: The user's answers.** The decisions above marked "the user confirms" are put to the user in one
  message (with the other questions of [the bootstrap path](2026-11-13-v2-bootstrap-path.md#what-the-user-is-asked)),
  and the answers go into the design's Decided section.
- [ ] **Step 5:** `bash scripts/test.sh --filter 'DocLinksLintTests|SecurityDocumentLintTests'`; push; both workflows
  green; commit ("v2: the security architecture document").

**Done when:** the document and its review are committed, the lint passes, and the user's answers are recorded.

---

### Task 2: The platform's terminals, pairs and pipes

**Files:**
- Modify: `Sources/VibePlatform/Terminals.swift`, `Sockets.swift`, `Sockets+Linux.swift`, `Sockets+Darwin.swift`, `Sys.swift`
- Create: `Sources/VibePlatform/Terminals+Linux.swift`, `Terminals+Darwin.swift` (the Mac's `openpty` with its lock,
  moved from `Sources/VibeHost/PTYSpawn.swift` 27-41 unchanged)
- Modify: `Sources/CVibePlatform/include/CVibePlatform.h`, `shim.c` (`vibe_openpt`, `vibe_make_controlling`)
- Test: `Tests/VibePlatformTests/TerminalsTests.swift`, `SocketsTests.swift`, `SysTests.swift`

**Interfaces:**
- `Platform.Terminals.PseudoTerminal { master: Int32; slave: Int32; devicePath: String; name: String }`, `name` being
  `Terminals.name(devicePath:)`.
- `Platform.Terminals.open(rows: UInt16, cols: UInt16) -> Result<PseudoTerminal, Platform.Errno>`. Both ends
  close-on-exec from their making on Linux (`posix_openpt(O_RDWR|O_NOCTTY|O_CLOEXEC)`, `grantpt`, `unlockpt`,
  `vibe_ptsname_r`, the slave opened `O_RDWR|O_NOCTTY|O_CLOEXEC`, then `TIOCSWINSZ`).
- `Platform.Terminals.devicePath(master: Int32) -> String?` (`ptsname_r`'s answer, for the host's existing line).
- `Platform.Terminals.makeControlling(_ fd: Int32) -> Int32` (`TIOCSCTTY`).
- `Platform.Sockets.pair(type: Int32) -> (Int32, Int32)?`: close-on-exec from its making on Linux (`SOCK_CLOEXEC`);
  on the Mac `socketpair` then `fcntl`, as today.
- `Sys.pipeClosedOnExec(_ fds: inout [Int32]) -> Int32`: `pipe2(O_CLOEXEC)` on Linux; `pipe` and `fcntl` on the Mac.

- [ ] **Step 1: Failing tests**, on both systems unless marked.
  - `aNewTerminalIsNamedAsTheTableNamesIt`: open one; start a helper mode of the test binary through
    `Platform.Spawn` with stdin `.path(devicePath, flags: O_RDWR)`, stdout and stderr `.sameAsStdin`, group
    `.ownSession`; the helper calls `Platform.Terminals.makeControlling(0)` and sleeps, as the host's launcher does
    (`execIfLaunched`). `Platform.Processes.record(pid)`'s terminal equals `name`; on Linux it starts `ttypts`.
    (Corrected from the draft: a plain `sleep` would get the terminal as its controlling one on Linux by opening it,
    but not under BSD's rules, so the Mac would fail for the test's sake.)
  - `bothEndsAreClosedOnExecFromTheStart` (`fcntl(F_GETFD) & FD_CLOEXEC` on both, read right after `open`).
  - `theSizeGivenIsTheTerminals` (`TIOCGWINSZ` gives 40×120).
  - `aPairIsClosedOnExecFromItsMaking`; `aPipeIsClosedOnExec`.
- [ ] **Step 2: Implement.** The Mac's `open` is the existing `openpty` body with `openptyLock` and the two `fcntl`
  lines, moved.
- [ ] **Step 3:** push; both green (the host job too: nothing in `VibeHost` uses these yet); commit ("v2: terminals,
  pairs and pipes through the platform").

**Done when:** `bash scripts/test.sh --filter VibePlatformTests` is green on Linux and the Mac's platform job is green.

---

### Task 3: The platform's own-process calls

**Files:**
- Create: `Sources/VibePlatform/ProcessSelf.swift`, `ProcessSelf+Linux.swift`, `ProcessSelf+Darwin.swift`
- Modify: the shim (`vibe_set_dumpable`, `vibe_get_dumpable`, `O_PATH`, and `vibe_pidfd_getfd(pidfd, targetfd,
  flags)` beside the existing `vibe_pidfd_open`: glibc here has no wrapper and Swift can't call the variadic
  `syscall`); `Sources/VibePlatform/Processes.swift`, `Processes+Linux.swift`, `Processes+Darwin.swift` (`token(_:)`)
- Test: `Tests/VibePlatformTests/ProcessSelfTests.swift`, `ProcessesTests.swift`, with a helper mode of the test binary (as
  `replaceProcessKeepsOnlyWhatItWasTold` has one)

**Interfaces:**
- `Platform.ProcessSelf.harden() -> Bool`: Linux, `PR_SET_DUMPABLE 0` and `RLIMIT_CORE 0`; the Mac does nothing and
  returns false.
- `isDumpable() -> Bool?`; `tracer() -> pid_t?` (`TracerPid`; nil on the Mac) and `tracer(fromStatus: String) -> pid_t?`.
- `holdImage(_ path: String) -> Int32?`: an `O_PATH|O_CLOEXEC` descriptor on Linux, nil on the Mac.
  `heldImagePath(_ fd: Int32) -> String`: `/proc/self/fd/<fd>`. **How a held image is started:** in place
  (`Platform.Spawn(…).replaceProcess()`) as it is, since close-on-exec acts after `execve` has resolved the path; as
  a child, with `keep: [fd]`, because `Platform.Spawn` on Linux closes every descriptor from 3 up in the child before
  `execve` (`addCloseFromThree`, `Spawn+Linux.swift:98-107`), which would leave `/proc/self/fd/<fd>` naming nothing.
  The started program closes the inherited descriptor as its first act (`Platform.ProcessSelf.closeInheritedImage()`,
  which reads its number from `VIBESWITCHER_HELD_IMAGE_FD` and unsets it).
- `ownImagePath: String?`: `/proc/self/exe` on Linux, nil on the Mac.
- `Platform.Processes.token(_ pid: pid_t) -> Platform.PeerToken?`, public: on Linux the pid, uid and start ticks from
  the stat line (what `Sockets.token(pid:uid:)`, internal, builds today); nil on the Mac, where an `audit_token_t`
  can't be had for another pid without privileges. The server child's record (Task 8) is this token, compared with
  `sameImage(as:)`, which both systems have.

- [ ] **Step 1: Failing tests.**
  - `aHardenedProcesssMemoryCantBeOpened` (Linux): the helper hardens and sleeps; the test's
    `open("/proc/<pid>/mem")` fails with `EACCES`. Without `harden()` it opens, which is the failing form.
  - `aHardenedProcesssDescriptorsCantBeTaken` (Linux): `pidfd_getfd` of the helper's descriptor 0 fails `EPERM`.
  - `hardeningIsNothingOnTheMac`.
  - `tracerPidIsReadFromStatus` (fixtures with 0 and 4242).
  - `aHeldImageRunsAfterItsFileIsReplaced` (Linux): copy the test binary to a scratch path; a helper holds it; a
    script printing "replaced" is renamed over the path (an in-place write would fail with `ETXTBSY`); the helper
    starts `heldImagePath(fd)` as a child exactly as Task 8 will (`Platform.Spawn`, `keep: [fd]`), which runs the
    original: it prints its helper mark, not "replaced", and reports that it closed the inherited descriptor. Shown
    failing with `keep: []` (`ENOENT`).
  - `aPidsTokenIsItsPeerToken` (Linux): `Platform.Processes.token(pid)` of a helper equals the `peerToken` of a
    connection the helper opens; after the helper ends and a new one runs, the old token isn't `sameImage` as any
    new one. `thereIsNoTokenForAPidOnTheMac` (Mac).
- [ ] **Step 2: Implement.** Helper modes only; never in the test process (Global Constraints).
- [ ] **Step 3:** push; both green; commit ("v2: the process's own hardening and held images through the platform").

**Done when:** the tests pass on Linux, and the Mac's platform job asserts the Mac's forms do nothing.

---

### Task 4: `VibeHost` compiles on Linux, in three slices

Each slice is its own commit and its own Mac proof. Measure after each file with
`scripts/ci/linux-core-errors.sh VibeHost`, then `vibeswitcher-host`.

#### Task 4a: Terminals, spawning and exit watches

**Files:** `Sources/VibeHost/PTYSpawn.swift`, `HostedSession.swift`, `SessionParser.swift`

- [ ] **Step 1: Switch each site, mechanically.**
  - `PTYSpawn.spawn` onto `Platform.Terminals.open` and `Platform.Spawn` (stdin `.path(devicePath, flags: O_RDWR)`,
    stdout and stderr `.sameAsStdin`, group `.ownSession`, directory, environment; the slave closed once `start()`
    returns). `execIfLaunched` uses `Platform.Terminals.makeControlling(0)`.
  - `HostedSession.spawn`: `ptsname_r` becomes `Platform.Terminals.devicePath(master:)`. The next line, which drops
    `/dev/` and so gives `pts/3` on Linux (160-162), is **kept as it is**: Task 6 changes it after its failing tests.
  - `isExiting` becomes `Platform.Processes.record(pid)` with `.zombie` or exiting. The Darwin record already carries
    `PROC_FLAG_INEXIT` as `exiting` (`Processes+Darwin.swift:48`), so the Mac keeps its "on its way out" case.
  - The exit source (line 348) becomes `Platform.ProcessExit.watch`, kept in `exitSource`'s place (a watch nobody
    keeps never reports), with the exit poll kept.
  - `ParserLink.start` uses `Platform.Sockets.pair` and `Platform.Spawn` per recon §1.2, and
    `Platform.Sockets.noSigPipe(socket:)`.
  - `SessionParser.runIfAsked` watches the host with `Platform.ProcessExit.watch(getppid())`, held for the run; if it
    reports at once, the parser exits. (On Linux a dead host's parser goes to the user's systemd, not pid 1, so the
    `parent == 1` test alone wouldn't notice.)
- [ ] **Step 2:** push; the Mac's host and app jobs green (`VibeHostTests` there exercise each site); commit ("v2: the
  host's terminals, spawns and exit watches through the platform").

#### Task 4b: The server's peers, identity and orphans

**Files:**
- Modify: `Sources/VibeHost/ClientConnection.swift` (`peer: Platform.PeerToken?`), `HostServer.swift`,
  `AppCode.swift` (bodies to the platform; the name and its functions stay as forwards)
- Create: `Sources/VibePlatform/CodeIdentity.swift`, `CodeIdentity+Darwin.swift` (the cdhash check and
  `proc_archinfo` read, moved), `CodeIdentity+Linux.swift`
- Test: `Tests/VibeHostTests/HostIdentitySeamTests.swift`

**Interfaces:**
- `HostServer.appPrincipal: ((Platform.PeerToken) -> Bool)?`, nil by default (a member whose default keeps the Mac's
  behaviour; Non-seam edits). In `acceptAll`, two lines: a connection whose token `appPrincipal` names, and that
  `session(of:)` places in no session, is `.app` at once and is sent no challenge; every other connection goes through
  `identify` and the challenge as today. `HostConnection` already handles a host that sends no challenge.
- `HostServer.executable(of:)` stays a static, now a forward to `Platform.Processes.executable` (the tests call it,
  and `TestHost`'s default `appExecutable` comes from it).
- `Platform.CodeIdentity.isAvailable: Bool`: true on the Mac, false on Linux. The one value every "on Linux" switch
  outside `VibePlatform` reads (Global Constraints).
- `HostProcesses.isOrphan(parent:…)` takes the set of parents an orphan can have, and
  `HostProcesses.orphans(running:)` (`HostServer.swift:946-955`, which today looks only at `children(of: 1)`) looks
  at the children of each member of that set. `HostProcesses.orphanParents` is `{1}` on the Mac and, on Linux, `{1}`
  plus the parent an orphan of the host's is given, found once at start by a probe (S2-D6): the host starts
  `/bin/sh -c 'sleep 30 & echo $!'` through `Platform.Spawn`, reads the pid, waits for the shell, reads that pid's
  parent from `Platform.Processes.record`, and ends it. Non-seam edit.

Run on the Mac in this task. On Linux, `VibeHostTests` builds only from Task 5a: this task's Linux tests are written
here and run first in 5a, where each Linux-only one is shown failing by reverting its change from this task.

- [ ] **Step 1: Failing tests.**
  - `theMacsAppIsStillTheCdhashCheck` (Mac): a `Config` with only `appExecutable` set; the app's code answering the
    challenge with the key is `.app`; another process is refused `proveApp`.
  - `aPrincipalsConnectionIsTheAppWithNoChallenge` (both): a scratch host with `appPrincipal = { $0.pid == getpid() }`
    takes the test's connection as `.app`, and its first event is the welcome, not a challenge.
  - `aPrincipalInsideASessionIsNotTheApp` (both): a process the principal names but that runs in a live session is
    that session's.
  - `anOrphanedToolServerIsFoundOnLinux` (Linux): a tool-server stand-in whose parent ended is listed by
    `HostProcesses.orphans`, and its new parent is in `orphanParents` (asserted that way, not by naming systemd or
    pid 1: the subreaper depends on where the tests run).
  - `aLiveToolServerWhoseParentIsTheTestIsNotAnOrphan` (Linux): a stand-in that is the test process's child, with
    the test process among the scratch host's ancestors, isn't listed.
- [ ] **Step 2: Switch the sites.** `audit_token_t` to `Platform.PeerToken` (lines 13 and 663); `watch(owner:)`
  (line 197) to `ProcessExit.watch`, kept; `executable(of:)` (691) forwards; the `HostProcesses` reads (944-960) to
  `Platform.Processes.record`, and `orphans(running:)` over every member of `orphanParents`.
- [ ] **Step 3:** push; the Mac's host job green, and its **app job** green with the eleven app test files unchanged:
  that is the proof the Mac's app identity is intact; commit ("v2: the host's peers and identity through the platform").

#### Task 4c: The handover, the vault and the host's main

**Files:**
- Modify: `Sources/VibeHost/HostHandover.swift`, `VaultStorage.swift`, `HostStart.swift`,
  `Sources/vibeswitcher-host/main.swift`, `Package.swift` (`VibeHost` and `vibeswitcher-host` into `portableTargets`),
  `Tests/VibePlatformTests/PlatformLintPending.txt` (empty), `Tests/VibeCoreTests/KeychainLintTests.swift` (the
  Keychain's new path)
- Create: `Sources/VibePlatform/Keychain.swift`, `Keychain+Darwin.swift` (the `SecItem` bodies of
  `VaultStorage.swift` 122-149, moved), `Keychain+Linux.swift`

- [ ] **Step 1: Switch.** `HostHandover.probe` uses `Platform.Spawn` with stdout `.descriptor` of a
  `Sys.pipeClosedOnExec` pipe; `exec` uses `Platform.Spawn(keep:).replaceProcess()`; `SecretChannel` makes its pair
  through `Platform.Sockets.pair`, with its `SO_SNDBUF` rule unchanged. `VaultStorage.keychainKey()` and
  `removeKeychainKey` forward to `Platform.Keychain`. `main.swift`'s `sigaction` line through `Platform.Signals`.
- [ ] **Step 2: Build.** `swift build --build-system native` on Linux builds every portable target, `VibeHost` and
  `vibeswitcher-host` included; `linux-core-errors.sh` reports 0; the lint's pending list is empty. Each Non-seam edit
  of Task 4 is in the port map.
- [ ] **Step 3:** push; the Mac's host and app jobs green; commit ("v2: the session host builds on Linux").

**Done when** (Task 4): both systems build everything, `bash scripts/test.sh` on Linux is as green as before, and the
Mac's host and app jobs are green.

---

### Task 5: `VibeHostTests` and the host's audit on Linux, in two slices

#### Task 5a: Compile, the guard, the list, the job

**Files:** `Package.swift` (`VibeHostTests` on Linux, with its `Fixtures` resource and `exclude: ["MacOnlyTests.txt"]`);
`Tests/VibeHostTests/` files as found; `TestHost` in `HostServerTests.swift`; create `Tests/VibeHostTests/MacOnlyTests.txt`;
`Tests/VibePlatformTests/MacOnlyTestsLintTests.swift` (both lists); `scripts/test.sh` (line 323's "skipped on Linux
until the session host builds here" goes); `.github/workflows/v2-linux.yml` (a `host` job, 90 minutes).

- [ ] **Step 1: Compile.** The 30 test files that import Darwin get the smallest change that compiles:
  `EndedSessionTests` uses `Platform.Processes.openDescriptorCount`; `HostStopReapsTests` uses
  `Platform.Processes.record`; `TestHostsTests` uses `Platform.ProcessExit`; `HostHandoverTests` uses
  `Platform.Processes.executable`; a test that runs `/bin/zsh` takes `Platform.Tools.loginShell`. Listed Mac-only with
  reasons: `AppCodeTests` (cdhash), `ParserCostTests` (`/usr/bin/footprint`), `UpgradeFromLeadHostTests` (`xcrun`).
- [ ] **Step 2: The app's stand-ins on Linux.**
  - **In-process hosts.** `TestHost` sets `appPrincipal` to the test process's token
    (`Platform.Processes.token(getpid())`, compared with `sameImage`) only when `!Platform.CodeIdentity.isAvailable`
    **and** its `appExecutable` is the default (the test runner). A `TestHost` built with another `appExecutable`
    (`AppKeyTests`' and `LeadVaultHostTests`' `/usr/bin/nc`) means "the test process isn't the app", and gets no
    stand-in, so those tests keep testing a refusal. On the Mac `appPrincipal` stays nil and the cdhash and HMAC proof
    are exercised as today: `theMacsTestHostHasNoPrincipal` (Mac).
  - **What the stand-in can't do.** A principal is `.app` without `runsAppCode`, and `prove`, `enrollApp` and
    `replaceAppKey` require `runsAppCode` (`HostServer.swift:301, 318, 327`). The tests of the app's key (`AppKeyTests`,
    the `proveApp` cases of `HostServerTests` such as line 223, and any enroll or replace case
    found) are listed Mac-only, by test name, with the reason "the Linux app is a principal and holds no key".
  - **Scratch hosts started as processes.** `TestHosts.authorize` (`TestHosts.swift:16-33`) makes the test process
    the app by copying the runner beside the host as `VibeSwitcher` and answering the challenge, which rests on
    `AppCode.runs` (false on Linux, S2-D2). On Linux it passes `--test-app-pid <getpid()>` instead: the host takes
    that pid's token (`Platform.Processes.token`) as `appPrincipal`. The flag is refused, with a log line, by the
    user's host (`ownsLaunchers`), as `--parser-test-hooks` is (`main.swift:71`), and stripped from
    `config.arguments`. Non-seam edit (`main.swift`, one hook into `V2/TestAppPrincipal.swift`). The files that start
    hosts this way (`HostHandoverTests`, `HostLogTests`, `EndedSessionTests`, `EndingASessionTests`,
    `OrphanSweepTests`, `TestHostsTests`, `VaultHandoverTests`, `LeadToolServerHandoverTests`, and any others found)
    then need no change for the app's rights. Audit case: `host-access.test.mjs` starts a host in a scratch home
    with no `--lock` (so it is that home's user's host) and `--test-app-pid` of its own pid, and is refused every
    app-only request.
  - Each of the 29 files that use `TestHost` is checked, not assumed.
- [ ] **Step 3: The home guard** in its Linux form (`.init_array`, SIGPIPE ignored), as in the other test targets.
- [ ] **Step 4:** push; the new Linux `host` job runs; commit.

#### Task 5b: Run and sort, and the audit

**Task 6 is done between 5a and 5b.** Until it is, a hosted session's tty is `pts/3` on Linux while `ProcessTable`
and the hook say `ttypts3`, and every test that matches a session by terminal fails for that one cause, which could
be misread as "the test assumes the Mac" or counted toward the tenth.

- [ ] **Step 1: Run and sort**, after Task 6, in stage 1's order (the platform wrong; the test assumes the Mac; the Mac's own).
  Stop and report if more than a tenth of the 55 files would be listed (the lint computes it), or if a failure shows a
  change in the Mac's behaviour.
- [ ] **Step 2: The audit.** `Tests/SecurityAudit/host-access.test.mjs` runs on Linux unchanged: a fresh
  `--app-executable` still grants nothing (lines 63-83). `library-injection.test.mjs` tests the Mac's Hardened Runtime:
  `scripts/test.sh` skips it on Linux, saying so, and S11 lists `LD_PRELOAD`. The audit's Linux case for the server
  child is Task 8's.

**Done when:** `bash scripts/test.sh --filter VibeHostTests` and the audit are green on Ubuntu with every skip listed,
and the `v2 linux` host job is green.

---

### Task 6: Terminal names (test first; done straight after Task 5a, before 5b's sort)

**Files:** `Sources/VibeHost/HostedSession.swift` (160-162); Test: `Tests/VibeHostTests/HostedSessionTerminalTests.swift`

The bug: `HostedSession.spawn` names the terminal `pts/3` on Linux (`ptsname_r`'s `/dev/pts/3` less `/dev/`), while
`ProcessTable`, the hook and the steer inbox use `Platform.Terminals.name`, which gives `ttypts3`. Every match by
terminal fails without an error: `session(of:)`'s terminal fallback, `VibePaths.stateFile(tty:)` (which would even write
`state/pts/3.json`), the steer inbox, `HostRuntime.steer`, `LeadAgent.running(on:)`.

- [ ] **Step 1: Failing tests** (Linux; run on the Mac too, where they pass):
  - `aSessionsTerminalIsTheTablesName`: a scratch host spawns `sleep 30`; `HostSession.tty` equals
    `ProcessTable.info(pid:)?.tty` of the program, and starts `ttypts` on Linux.
  - `aProcessOnTheSessionsTerminalIsThatSessions`: a second process on that terminal is `session(of:)`'s session.
  - `theHookStateFileOfASessionIsDirectlyInState`: `VibePaths.stateFile(tty:)` for the session's tty has `state/` as
    its parent folder.

  Shown failing against lines 160-162 as Task 4a left them.
- [ ] **Step 2: Fix.** The tty is `Platform.Terminals.name(devicePath:)` of the device path (a call switched to the
  platform; on the Mac `/dev/ttys003` still gives `ttys003`).
- [ ] **Step 3:** push; both green; commit ("v2: a session's terminal is named as the process table names it").

**Done when:** the three pass on both systems.

---

### Task 7: Each message's sender

**Files:** `Sources/VibeHost/ClientConnection.swift` (`readAvailable`: `Sys.read` to `Platform.Sockets.receive`;
`onRead` passes each chunk's sender; the frame decoder notes the senders of a frame's bytes), `HostServer.swift`
(`checkPeer(client, sender:)`; `Platform.Sockets.enableCredentials` on the listener in `start()` and
`start(restoring:)`, so accepted connections carry senders from their first byte). Non-seam edits: the `checkPeer`
signature and the decoder's sender list. Test: `Tests/VibeHostTests/PeerPerMessageTests.swift`.

- [ ] **Step 1: Failing tests**, both systems.
  - `aForkedChildWritingOnALeadsConnectionMakesItNobodys`: a client is bound as a team's lead; a helper started with
    that connection's descriptor (`keep: [fd]`) writes a `sessions` request; the connection's caller is `.unknown`, and
    the next lead-only request is refused.
  - `aFrameSplitAcrossTwoSendersIsHandledAsNobodys`: half a frame from the test, half from the helper, on a lead's
    connection; the connection is `.unknown`, and the frame is handled as an unknown caller's request (refused
    anything beyond an unknown caller's rights), not dropped. That is what the Mac does today: `readAvailable` calls
    `onRead` (`checkPeer`) before it appends and delivers (`ClientConnection.swift:153-157`), so the frame arrives
    after the caller became `.unknown`. Asserting a drop would change the Mac.
  - `theAcceptedProcessKeepsItsIdentityOverAThousandWrites`.
  - `aMissingSenderMakesTheConnectionNobodys`: the host's rule as a pure function
    (`HostServer.senderKeepsIdentity(accepted:sender:)`, `@testable`): a nil sender is never the accepted process.
    The case where it happens (bytes whose sender was reaped before the read) is tested where the reap can be
    ordered, in `SocketsTests.bytesFromAReapedSenderComeWithNoSender` (Linux): a child writes, exits and is reaped
    before the test reads. (Corrected from the draft: a host-level "writes and exits" test depends on whether the
    host reads before the reap.)

  On Linux the first two fail before the change, because `SO_PEERCRED` is fixed at connect. On the Mac they pass
  already, through `LOCAL_PEERTOKEN`, and keep passing.
- [ ] **Step 2: Implement.** `PeerToken.sameImage` is the comparison. On the Mac `receive` returns the token after the
  read, so one code path serves both. `Platform.Sockets.enableCredentials` (`SO_PASSCRED`) on Linux; on the Mac it
  does nothing, since `LOCAL_PEERTOKEN` needs no option.

**Done when:** the tests pass on both systems and the host job is green on both.

---

### Task 8: The app on Linux is the server child

**Files:**
- Create: `Sources/VibeHost/V2/ServerChild.swift`:
  - at the host's start, `Platform.ProcessSelf.holdImage(PATH)` of `--server PATH`, then the child started from
    `heldImagePath(fd)` with `Platform.Spawn` (`keep: [fd]`, as Task 3 says; group `.ownGroup`; the host's base
    environment plus `VIBESWITCHER_HELD_IMAGE_FD`); the server closes that descriptor as its first act;
  - on the host's queue in the same turn as the spawn, the record (`Platform.Processes.token(pid)`) and
    `server.appPrincipal = { $0.sameImage(as: record) }`, which compiles on both systems (the Mac starts no server
    child, so the closure is never set there);
  - on its exit (`Platform.ProcessExit.watch`): the principal cleared and every connection whose peer was the child
    made `.unknown`, then `waitpid` of that pid, then a restart after 1 s, doubling to 30 s, reset after 10 minutes up;
  - while it runs, the host doesn't count as idle.
- Modify: `Sources/VibeHost/HostServer.swift`: `tidy`'s idle test asks `ServerChild.isRunning` (one line; Non-seam
  edit, kind 4).
- Modify: `Sources/VibeHost/HostHandover.swift`: `State.serverChild: ServerChildRecord?` (pid, start ticks, the held
  image's descriptor, the path), optional so the format stays 1, and its descriptor in `descriptors`. **The state's
  hash through the secret channel** (S2-D8): on Linux the build handing over sends the SHA-256 of the state bytes it
  wrote before the secrets, the channel is made even when there is no secret, and `read` takes the expected hash and
  refuses a state that differs; `goBack` passes the hash to the fallback as `--handover-state-hash` (an argument set
  inside the host's process). Non-seam edits.
- Modify: `Sources/vibeswitcher-host/main.swift`: `--server PATH`, kept in `config.arguments` across a handover; the
  new image restores the record only when the pid's parent is its own pid, its token's start ticks match, and it is
  no restored session's program and no parser; otherwise it clears the record and starts the server again from the
  held image. Non-seam edit.
- Test: `Tests/VibeHostTests/ServerChildTests.swift`. The child is a helper mode of the test binary that calls
  `Platform.ProcessSelf.harden()` as its first statement (as `vibeswitcher-server` must, in the engine plan), then
  speaks to the host through `HostCall` by path.

- [ ] **Step 1: Failing tests** (Linux unless marked).
  - `theServerChildsConnectionsAreTheApp`: the helper makes three `HostCall` calls (three connections); each app-only
    request (`vault .issue(role: .lead, …)` on a scratch repository, `spawn`) is answered.
  - `aConnectionFromAnotherProcessIsNotTheApp`: the test's own connection, with `appPrincipal` set by the
    `ServerChild` and not by `TestHost` (a scratch host built without `TestHost`'s stand-in), is refused app-only
    requests.
  - `aChildOfTheServerIsNotTheApp`: a process the helper starts is refused.
  - `anotherProcessWritingOnTheServersConnectionMakesItNobodys` (Task 7's rule).
  - `theServerIsStartedAgainAfterItDies`: kill the helper; a new pid is the app; a connection the old pid left open is
    nobody's.
  - `aReplacedServerFileIsNotWhatRestarts`: rename a script printing "replaced" over PATH, kill the helper; what
    restarts reports the helper's mark.
  - `theServerChildSurvivesAHandover`: after a handover to the same build, the same pid is the app and an app-only
    request is answered.
  - `aForgedStateFileIsRefused`: the scratch host hands over to a target the test made, a script that, when run as
    the probe, renames a state file of the test's over `lockPath + ".handover"` and then execs the real build with
    its arguments (deterministic: the swap happens inside the probe). The new image refuses the state (hash mismatch)
    and the old build serves on with its sessions. `HostHandover.read(from:expectedHash:)` refusing a single changed
    byte is also tested directly.
  - `aForgedServerChildInTheStateFileIsNotTheApp`: the restore's own check, with the hash check bypassed through
    `@testable`: a record naming a session's program (a child of the host, but not the server) is cleared, that
    process is refused app-only requests, and a new server child is started.
  - `aHostWithAServerChildDoesNotExitIdle`.
  - `theServerHelperIsNotDumpable`: `/proc/<helper>/mem` gives `EACCES`.
  - `host-access.test.mjs`, a Linux case: a scratch host with `--server` set to a small script that only sleeps; the
    audit's own client and a client the script starts both get errors for `proveApp`, `replaceAppKey`, `handover`,
    `vault` and `spawn`.
  - `theMacStartsNoServerChild` (Mac): with no `--server`, `appPrincipal` stays nil.
- [ ] **Step 2: Implement.**
- [ ] **Step 3:** push; the host and app jobs green on both; commit ("v2: the app on Linux is the host's server child").

**Done when:** the tests pass, S2's and S8's `Held by:` name them, and the Mac's host and app jobs are green.

---

### Task 9: Hardening, the launcher, the fallback and the handover's target

**Files:**
- Create: `Sources/VibeHost/V2/HostHardening.swift` (`atStart(mode:)`: `harden()`, then `tracer()`),
  `Sources/VibeHost/V2/HandoverTarget.swift` (`allowed(_ path:, installRoot:) -> Result<Void, String>`: inside
  `installRoot`, and its SHA-256 equal to the one recorded in that build's `build-info`), and
  `Sources/VibeHost/V2/BuildInfo.swift`, which **fixes the `build-info` format here** (bootstrap step 8's install
  script writes it, and `ServerBuild` reads it): `<installRoot>/<commit>/build-info`, JSON
  `{"format":1,"commit":"<40 hex>","binaries":{"vibeswitcher-host":"<sha256 hex>",…}}`, one entry per file in that
  build's `bin/`. A file newer in format is refused (rule 11).
- Modify: `HostServer.swift`: `Config.installRoot: URL?`, nil by default (the Mac's and every scratch host's
  behaviour; kind 5); one line in `handOver(to:)` asking `HandoverTarget.allowed` only when it is set. Non-seam edits.
- Modify: `Sources/vibeswitcher-host/main.swift`: the host and parser modes call `HostHardening.atStart` first (the
  launcher mode doesn't: it execs the session's program at once); `launcher: Platform.ProcessSelf.ownImagePath ??
  ensureLauncher()`; the launcher cleanup loop runs only where copies are made. `config.installRoot` is
  `~/.vibeswitcher/v2/builds` for the user's host on Linux (`ownsLaunchers`), or a scratch host's `--install-root`
  (refused by the user's host), and with it set the host checks at start that its own image and its `--server`
  image match `build-info`, refusing to start otherwise (S2-D1: a slip caught, not an attacker). A traced new image
  refuses `takeSecrets` and goes back. Non-seam edits.
- **The fallback on Linux.** Today `config.fallback = config.launcher` whenever the launcher isn't the executable
  (`main.swift:85`); with the launcher `/proc/self/exe` that would make the fallback the new, failing image itself.
  On Linux the fallback is `heldImagePath(ownFD)`, never the launcher, and the own image's descriptor is kept across
  the handover's exec: `State.ownImageFD: Int32?` (optional, kind 6), in `descriptors`, so `/proc/self/fd/<own>` still
  names the old build in the new image. Non-seam edits.
- **The test-only secret flags.** `--handover-test-secret` is honoured by any host today (`main.swift:142-143`) and
  kept across handovers (not in `handoverFlags`), and the handed-over secret becomes the next image's vault (line
  129). It and the new `--handover-test-secret-file` are taken only when `!ownsLaunchers`, as `--parser-test-hooks` is,
  and both are stripped from `config.arguments`. Non-seam edit.
- Test: `Tests/VibeHostTests/HostHardeningTests.swift`, `HandoverLinuxTests.swift`

- [ ] **Step 1: Failing tests** (Linux unless marked).
  - `theHostIsNotDumpableAfterStartAndAfterAHandover`: `open("/proc/<host>/mem")` from the test fails `EACCES`, before
    and after a handover to the same build.
  - `aParserIsNotDumpable`; `aSessionsProgramIsDumpableAsUsual`.
  - `aTracedNewImageGoesBack`: a scratch host given a test-only `--handover-test-traced` flag (accepted only by a
    scratch host) reports a tracer, refuses its secrets, and the previous build carries on.
  - `aSessionStartedAfterTheHostsFileWasReplacedRunsThisBuild`: start the host from a scratch copy, rename another
    program over the copy, spawn a session; its launcher reports the first build's mark, and no `launcher-*` file
    exists under the scratch home's `host/`.
  - `aFailedTakeOverGoesBackThroughTheHeldImage`: `--handover-fail-restore` with the host's file replaced; the old
    build serves again, from the descriptor carried across the exec.
  - With a scratch `--install-root` holding a build folder and a `build-info` the test writes:
    `aHandoverToAPathInsideAWorktreeIsRefused`; `aHandoverToABuildOutsideTheInstallFolderIsRefused`;
    `aHandoverWhoseHashDiffersFromTheRecordIsRefused`; `aHandoverToAnInstalledBuildIsAllowed`;
    `aHostWhoseImageDiffersFromItsBuildInfoDoesNotStart`; `aNewerBuildInfoFormatIsRefused`.
  - `aScratchHostWithNoInstallRootHandsOverAsToday` (both): `HostHandoverTests`' handovers to `<scratch>/new/` are
    unaffected.
  - `theUsersHostIgnoresTestSecretFlags`: a host in a scratch home with no `--lock` (that home's user's host) given
    `--handover-test-secret` and `--install-root` hands over its real vault and uses the fixed install root.
  - `aSecretTooBigForTheSocketLeavesTheHostAsItWas`: a 1 MB secret, given by a test-only `--handover-test-secret-file`
    (argv can't hold it: one argument is at most 128 KiB on Linux); the handover fails before the exec and the host
    serves on with its sessions.
  - `aDowngradeIsRefused` (both): a state with a newer `format` is refused and the host goes back.
- [ ] **Step 2: Implement.** Check every reader of the host's own `/proc` entries (`SessionStrays`, `ProcessTable`
  reading the host): an unreadable host is "the host", never "gone".
- [ ] **Step 3:** push; both green; commit ("v2: the host hardened, its launcher its own image").

**Done when:** these and all of `HostHandoverTests` pass on Linux, S6 and S9 name them, and the Mac's host job is
green.

---

### Task 10: The sessions' environment, the project allow-list and the fresh vault's first look

**Files:**
- Modify: `Sources/VibePlatform/Tools.swift` (`sessionEnvironmentNames: [String]`: the Mac's list unchanged, Linux's
  from S2-D12; `defaultLocale: String`: `en_US.UTF-8` on the Mac, `C.UTF-8` on Linux)
- Modify: `Sources/vibeswitcher-host/main.swift` (`inherited` becomes `Platform.Tools.sessionEnvironmentNames`),
  `HostedSession.swift:129` (`Platform.Tools.defaultLocale`)
- Create: `Sources/VibeHost/V2/ProjectAllowList.swift`, with one hook where `HostServer` handles `.spawn`, active
  only when `HostServer.Config.projectAllowList: URL?` is set (nil by default, kind 5). `main.swift` sets it to
  `~/.vibeswitcher/v2/projects` for the user's host (`ownsLaunchers`) when `!Platform.CodeIdentity.isAvailable`.
  Non-seam edits (the `Config` field, the hook line, the `main.swift` line).
- Modify: `Sources/VibeCore/LeadVault.swift` and `ConfigSeal.swift`: `LeadVault.Book.holdsFirstLook` (S2-D3), false
  by default (kind 5): with it set, the home seal's first look holds every watched thing as "first watched" instead
  of sealing it. `main.swift` sets it on Linux when the vault is memory-only and wasn't handed over. Non-seam edits.
- Test: `Tests/VibePlatformTests/ToolsTests.swift`, `Tests/VibeHostTests/SessionEnvironmentTests.swift`,
  `ProjectAllowListTests.swift`, `Tests/VibeCoreTests/ConfigSealFirstLookTests.swift`

- [ ] **Step 1: Failing tests.**
  - `aLinuxSessionGetsNoAgentSocketNoInteropNoBus`: with those variables in the host's environment, the session's
    `env` has none of them.
  - `aSessionsProgramStartsWithSIGPIPEAtItsDefault` (both): the host ignores SIGPIPE; a session's program reads its
    own disposition (on Linux `SigIgn` in `/proc/self/status`) and it is the default.
  - `ConfigSealFirstLookTests.aVaultThatHoldsItsFirstLookHoldsEveryHomeFile`;
    `aVaultThatDoesntSealsItsFirstLookAsToday` (both); `theLeadsStartIsNeverHeldByAFirstLook`.
  - `theLocaleASessionGetsIsInstalled` (Linux: `LANG` is in `locale -a`, compared without case).
  - `theMacsListIsTodays`.
  - `ProjectAllowListTests.aSpawnOutsideTheListIsRefusedWithItsReason`; `aWorktreeOfAnAllowedRepositoryIsAllowed`;
    `aForgedGitFileIsRefused` (a folder whose `.git` names an allowed repository's worktree folder that doesn't point
    back); `aScratchHostHasNoList`; `aMissingListRefusesEverySpawnAndSaysWhereTheListGoes`; `noGitRunsInTheHost` (the
    check reads files only: a `git` that records being run, first on PATH, is never run).
- [ ] **Step 2: Implement; push; both green; commit.**

**Done when:** the tests pass, and S7, S10 and S11 name them.

---

### Task 11: The lead's tool server under a scratch host

Moved here from stage 1 (its R9), because the tool server learns its role from the host.

**Files:** `Tests/VibeHostTests/ToolServerUnderAHostTests.swift`

- [ ] `theLeadsToolServerListsItsToolsAndServesStatus`: a scratch host with the test as app (`TestHost`'s stand-in);
  the test asks the vault for a lead grant (`.issue(role: .lead, root:)`) on a scratch repository, spawns a session
  whose program starts the built `vibeswitcher-mcp` with its stdin and stdout on two FIFOs in the scratch folder, and
  binds the grant to that session (`.bind`). Over the FIFOs: `initialize`; `tools/list` within 50 s (the tool server
  waits up to `roleWait`, 45 s, for a role) includes `start_worker`, `audit`, `merge` and `status`; a `status` call
  answers with the scratch board. Shown failing with the bind left out (no tools listed).

**Done when:** it passes on Linux and on the Mac.

---

### Task 12: A real `claude` under a scratch host

**Files:** `Tests/VibeHostTests/RealClaudeHostTests.swift`; `docs/process/v2-linux-inventory.md`

- [ ] **Step 1: The test.** `aClaudeSessionSurvivesItsClientAHandoverAndAKilledParser`, enabled only when
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` is set (the folder the user prepared for stage 1's R10). A scratch host spawns
  `claude --model sonnet` in a scratch repository whose trust entry was written into that folder's `.claude.json`,
  with `CLAUDE_CONFIG_DIR` passed through the request's `env` (which `LaunchPlan.validEnvName` passes). Then:
  1. a client reads the screen until Claude Code's prompt shows, and disconnects;
  2. a new client attaches, and the same screen is there;
  3. a handover to the same build; the session is listed with the same id and tty;
  4. the parser is killed (`kill -9`), and a new parser's screen matches within 10 s;
  5. the session ends by `/exit` sent with an `inputUnit` request (there is no `type` request), and its exit is
     recorded.
- [ ] **Step 2:** the run, the Claude Code version and each step's time go into the inventory.

**Done when:** the gated test passed once here with the user's folder, and the record is committed. Until the folder
exists the test is skipped, saying why, and later work goes on.

---

## Done when

On Ubuntu, `bash scripts/test.sh` is green for `VibePlatformTests`, `VibeCoreTests`, `VibeNodeTests` and
`VibeHostTests`, with each Mac-only file listed with its reason, and `host-access.test.mjs` passes with its Linux
case. The security architecture document is reviewed, its lint passes, and the user's answers are in the design. On
Linux:

- a session's terminal is `ttypts<N>` everywhere;
- each message's sender is checked;
- the only app is the host's live server child, on any connection it opens;
- the host, its parsers and the server child are non-dumpable;
- launcher, parser, fallback and restarted server come from images held at start, and the user's host hands over
  only to an installed build whose hash matches;
- a forged handover state file is refused;
- the project allow-list holds in the user's host, and a fresh memory vault holds what it first sees;
- the lead's tool server lists its tools under a scratch host.

A real `claude` under a scratch host survived its client quitting, a handover and a killed parser, and that is
recorded (or the gated test waits on the user's folder, as an open item). Every Non-seam edit is in the port map. The
`v2 linux` jobs and the `v2 macos` jobs are green on one commit, as stage 1's R3 defines green.

## After the bootstrap, from this stage

Not tasks here; the lead's early work, in this order:

1. The sandbox through the shim: a process namespace of its own (and in it, the subreaper question settles itself), a
   devpts of its own with only the slave passed in, the lead confined too, a verifier never in the sandbox of the code
   it judges.
2. The inherited connector for sessions (S4, S2-D9), with the sandbox.
3. Clones for workers (S2-D10).
4. The egress proxy.
5. Strong mode's key file; the AppArmor profile; the installed images unreadable (`0111`).
6. The handover through sealed memory, with a 4 MB secret and no state file (S2-D8).
7. A lint that the host's and the tool server's logs carry no token, code or terminal text.
8. `vibeswitcher attach ID`, through the server.
9. The second half of the design's stage 2 Done-when: from inside a confined session, another session's screen, the
   node's state and the host's memory are all refused.
