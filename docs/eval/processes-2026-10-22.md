# Process handling: an audit, 2026-10-22

This audit covers how VibeSwitcher starts, watches, hands over and ends processes. That means:

- the session host and its handover between builds;
- PTY launchers and parser processes;
- Claude and Codex session detection, the process table, and Terminal.app sessions;
- worker and verifier lifecycles (start, stall, end, the roster sweep);
- orphans and zombies, signals, and crash recovery;
- the app's relaunch, and the test-and-build lock with `vs-heavy`.

It was written against project-lead at **fa9131e**. Items already in `docs/eval/open-2026-10-19.md` are left out, and so are items fixed since (role-sessions-end, ended-sessions-really, the orphan sweep, the test lock). An item that is only partly fixed is reported as such.

## How this was checked

- **Code reading.** Every finding cites today's file:line, and each race is named step by step.
- **Scratch-host reproductions.** These used a copy of the debug `vibeswitcher-host` built on 2026-10-20 07:41, which already holds the code in question: `drain`/`reap`/`pauseReading` date from 11b7998 and de4e4b2 on 2026-10-18. Each run had:
  - its own `--socket` and `--lock`;
  - `VIBESWITCHER_HOME` and `HOME` in a fresh folder under the session's TMPDIR;
  - `--parser-test-hooks` where noted, exactly as `ParserIsolationTests` does;
  - a Python client speaking the host's frame protocol.

  These hosts signalled only their own scratch sessions.
- **Standalone `swiftc` programs.** These were run on scratch PTYs and pipes, and signalled only their own children.
- **`vs-heavy` from the repo** (`Resources/bin/vs-heavy`), run with `VIBESWITCHER_TEST_LOCK_DIR` set to a scratch folder.
- **Live evidence.** This came from read-only `ps`, `lsof` and `pgrep`, from the user's `~/.vibeswitcher/debug/{host,app}.log`, and from `~/Library/Logs/DiagnosticReports`. No real session, real host or the installed app was signalled, typed into or ended. Nothing was installed.
- **No `swift build` or `swift test` was run.** The Mac's load was 24–47 at the start, and this task changes no code.

## Ranked findings

| # | Sev | Finding | Evidence |
|---|---|---|---|
| 1 | P1 | Ending a worker's or verifier's session leaves running what its agent started (dev servers, background jobs, suites) | live: orphans 3–4 days old, in deleted worktrees |
| 2 | P1 | The host crashes, ending every session in every project, when a session ends while its PTY reading is paused | scratch host, deterministic (2 of 2), plus crash report |
| 3 | P2 | A bench's private session host outlives the bench when the bench is killed, with live sessions | live: 4 hosts, 35 h, 216 processes |
| 4 | P2 | Killing `vs-heavy` frees the Mac-wide lock while its command runs on; a holder is never checked or bounded | scratch lock dir, reproduced |
| 5 | P2 | Any long-lived background shell blinds the lead's stall checks | code and test reading |
| 6 | P3 | A tool server that exits mid-merge leaves the test command running unlocked, and the merge worktree behind | code reading |
| 7 | P3 | `--install` can leave the old app running, or no app, and it kills benches named `VibeSwitcher` | code reading |
| 8 | P3 | The hook's own 3 s alarm can cut a steered-message delivery halfway: the message is duplicated or lost | code reading |
| 9 | P3 | A suspended (Ctrl-Z) agent hides the agent actually in use on the same terminal | code reading |

---

### 1 · P1 · Ending a session leaves running what its agent started

- **Failure.** stop_worker, cleanup, the role sweep, the host's end of a submitted verifier and the app's End Session all reach `HostedSession.terminate`. It sends SIGHUP, then SIGKILL 5 s later, only to two groups: the shell's process group (`info.childPID`) and the terminal's foreground group (`tcgetpgrp`). Claude Code runs each Bash tool command in a process group of its own, with no terminal. The tool server's own shell here has pgid = pid and tty `??`, and its stdout goes to a file. So neither signal reaches that command, nor anything it started (`run_in_background` servers, `npm run serve &`, a suite under `vs-heavy`). When the agent exits, those processes are reparented to launchd and run on. The host's housekeeping sweep (`endOrphans`) looks only for parsers and tool servers.
- **Sequence.**
  1. A worker starts a dev server, or a long suite.
  2. The lead calls stop_worker or cleanup, the role sweep ends the session, or the user clicks End Session.
  3. The agent and its shell die.
  4. The server keeps its port and its cwd, now in a worktree that `cleanup` removes.
- **Where.** `Sources/VibeHost/HostedSession.swift:663-671` (`terminate`); `Sources/VibeHost/HostServer.swift:700-715` (`endOrphans`, parsers and tool servers only).
- **Evidence (live, read-only).**
  - pid 66813 `node test/ui/harness/serve.mjs 8833`: ppid 1, running 3 days 16 h, listening on 8833. Its cwd is `genswap/.vibeswitcher/worktrees/fix-connecting-a-wallet`, which no longer exists. Its environment carries `VIBESWITCHER_SESSION=20691B6C-…`, the host session that `app.log:1405` shows as that worker's (`fix-connecting-a-wallet`).
  - pid 14391 `npm run serve`: ppid 1, running 4 days, cwd `genswap/.vibeswitcher/worktrees/prototype-genswap-as-the` (also gone).
- **Impact.**
  - Ports stay taken, so the next worker's server fails to bind. Worse, its tests can reach the stale server, which serves deleted code.
  - Memory and CPU leak for days.
  - A suite orphaned this way keeps running beside the next holder of the heavy-work lock (see #4).
- **Fix sketch.** In `terminate`, before the SIGHUP:
  - Take the session's family from one process-table read (`Shell.signalFamily`'s walk, pid plus start time). Signal it TERM, then KILL at the 5 s mark.
  - Every process the session started, even a setsid'd one reparented to launchd, carries `VIBESWITCHER_SESSION=<id>` in its environment (`HostedSession.environment`, `:105`). After the end, a sweep of the user's launchd children that carry an ended session's id catches the rest (KERN_PROCARGS2, same uid only). `cleanup` also ends processes whose cwd is inside the worktree it removes.
- **Check.** A scratch-host test whose session runs `perl -e 'setsid; sleep 300' &` (or `setsid sleep 300 &` where available). After `kill(id)`, that sleep is gone within 10 s. A second test does the same for a process whose cwd is in a worktree that `cleanup` removes.

### 2 · P1 · A session that ends while its PTY reading is paused crashes the host

- **Failure.**
  1. When a session's parser falls more than 4 MB behind, the host stops reading the PTY: `pauseReading` suspends `readSource`.
  2. If the program then exits with nothing left in the PTY's queue, `reap()` calls `drain(reads: 256, pausing: false)`.
  3. `drain` reads the end of file and runs `readSource?.cancel(); readSource = nil` on the source, which is still suspended.
  4. Releasing a suspended dispatch source is a libdispatch trap. The host dies, every PTY master closes, and every session in every project gets SIGHUP.

  `close()` already resumes before cancelling (`:678-679`, "A suspended watcher can't be cancelled"). The end-of-file branch of `drain` doesn't.
- **Sequence.** A program prints over 4 MB while its parser is stalled (the watchdog only acts after `stallLimit`, 10 s) or slower than the output (a loaded Mac). Its output ends with that burst, and then it exits: `cat` of a big log, a verbose build or test run as a session command, or an agent dumping a large diff and quitting.
- **Where.**
  - `Sources/VibeHost/HostedSession.swift:330-332`: `readSource?.cancel(); readSource = nil`, with no resume.
  - `:326` and `:273-277`: the pause.
  - `:374`: `reap`'s drain.
- **Evidence (scratch host, deterministic).**
  - The session command was `printf '\033]7599;stall\007'; sleep 0.5; head -c 4194304 /dev/zero | tr '\0' x; sleep 1`, on a host started with `--parser-test-hooks --parser-stall-limit 30`. The hook stalls the parser, as in `ParserIsolationTests`. Result: the host died with wait status 133 (SIGTRAP) in **2 of 2 runs**.
  - The crash report (`host-bin-2026-10-22-024152.ips`) reads `BUG IN CLIENT OF LIBDISPATCH: Release of a suspended object`, at `-[OS_dispatch_source _xref_dispose]` ← `HostedSession.drain(reads:pausing:)` ← `HostedSession.reap()` ← the exit source's handler.
  - Control: the same flood without the stall hook ended normally, exit code 0, and the host carried on.
  - A standalone program doing just `suspend(); cancel(); = nil` on a read source also exits 133.
- **Related (same runs).** While reading is paused, a session that is killed doesn't finish ending. The kernel drains the terminal's output when the session leader exits, so the exit completes only once the host reads again. In one run, a `kill -9` at 6 s was reaped at 31 s, when the watchdog replaced the parser. Meanwhile the lead's `end()` (`stopWait` 10 s, `LeadToolset.swift:106`) reports "still running".
- **Likelihood.** It needs a parser 4 MB behind. A healthy parser kept up with 60 MB of plain text and 30 MB of escape-heavy output at load 6. The real `host.log` has only 2 parser stalls since 2026-10-18 (60 and 148 bytes unparsed). So it's rare, but deterministic once the condition is met, and it takes every session down.
- **Fix sketch.** In `drain`'s end-of-file branch, `resumeReading()` (or `if readingPaused { readSource?.resume(); readingPaused = false }`) before `cancel()`, as `close()` does.
- **Check.** Add a `ParserIsolationTests` case with the session command above (stall hook, flood of exactly 4 MB, `sleep 1`). It asserts the host is still running, the session reads as ended, and a second session is unaffected. It fails today, deterministically.

### 3 · P2 · A bench's private session host outlives a killed bench, with its sessions

- **Failure.** `--idle-bench` and `--power-bench` start a private host from the build folder, under a scratch home. The host is ended only by `finish()`, at the end of a completed run, which kills the shells and then SIGTERMs the host. The bench doesn't route SIGTERM or SIGKILL to that host. When `PowerBenchTests`' or `FootprintBenchTests`' hang guard calls `process.terminate()`, or a runner is killed, the host stays behind. Its sessions are live, so `--idle-exit` never fires. The TestHosts watchdog covers only hosts the tests start themselves, and `scripts/test.sh`'s leftover sweep covers only runs made through `test.sh`.
- **Sequence.** A bench hangs, or is stopped by its test's guard or by a killed `swift test --filter`. Its host keeps its sessions running indefinitely.
- **Where.** `Sources/VibeSwitcher/IdleBench.swift:579-588` (`finish`, the only end); `Tests/VibeSwitcherTests/PowerBenchTests.swift:45` and `FootprintBenchTests.swift:60` (`process.terminate()`).
- **Evidence (live, read-only).** Four debug hosts from `worktrees/selecting-text-in-the/.build/debug/vibeswitcher-host`, all with ppid 1, have run for 35 h: pids 33160, 55000, 73472 and 88054.
  - Between them they hold 10 + 10 + 98 + 98 child processes.
  - Their sessions include `while :; do … printf '\033]0;%s Working on the bench\007'; sleep 0.1; done` title loops, about 10 forks a second each, plus their parsers and `cat` sessions.
  - Their scratch homes (`/tmp/vsh.*` …) are gone.
- **Impact.** Constant fork and CPU load on the shared Mac, the very thing the load tests and `vs-heavy` try to keep down, plus about 200 processes and their memory. Nothing in the app shows these hosts.
- **Fix sketch.** The bench passes its pid to the host it starts, for example `--exit-with <pid>`: a process source on that pid ends every session and exits the host when the bench goes. Alternatively, use the TestHosts watchdog for bench hosts too.
- **Check.** A test SIGKILLs a running `--idle-bench`. Its host and every session are gone within 10 s.

### 4 · P2 · Killing `vs-heavy` frees the lock while its command runs on; a holder is never checked

- **Failure.**
  - **(a)** `vs-heavy` runs `"$@" 9>&-`. It doesn't exec, trap or forward signals. Killing the script by its pid (`kill <pid>`, exactly how workers are told to stop what they started) closes fd 9, so the lock is free. The command, a full suite or a release build, runs on unlocked, reparented to launchd.
  - **(b)** The wait has no bound, and nothing checks that the `.holder` pid is alive or how long it has held the lock. A hung suite, or one orphaned by #1, holds every project's heavy work indefinitely. Merges and audits wait up to `testTimeout` (45 min) each and then refuse.
- **Where.** `Resources/bin/vs-heavy:47-63` (the unbounded perl wait) and `:68` (`"$@" 9>&-`); `TestLock` callers at `Sources/VibeCore/LeadToolset.swift:1136,1458` (`timeout: workflow.testTimeout`).
- **Evidence (reproduced, scratch `VIBESWITCHER_TEST_LOCK_DIR`).** `vs-heavy --as first bash -c 'sleep 4; …'`, then `kill <vs-heavy pid>` at 02:44:11:
  - The command was still running.
  - A second `vs-heavy` "took the lock at 02:44:11".
  - The first command "finished at 02:44:14", while the second held the lock.
- **Impact.** Two heavy runs side by side again: the starvation the lock exists to prevent (3–4 min suites, measured 2026-10-21). Or a lock held for good by something nobody is watching.
- **Fix sketch.**
  - Start COMMAND in its own process group, trap TERM, HUP and INT, forward them to the group, and wait.
  - Release the lock only once the group is gone.
  - An optional ceiling (`--timeout`, default about 60 min) kills the group and exits 124.
  - Waiters print the holder's age and whether its pid is still alive. `TestLock`'s busy text says the same.
- **Check.** A script test kills `vs-heavy` by its pid while it runs `sleep 5`: the sleep is gone, and a second `vs-heavy` takes the lock only after that. A second test checks that the timeout exits 124 with the group gone.

### 5 · P2 · Any long-lived background shell blinds the lead's stall checks

- **Failure.** `shellRunning` is true while *any* shell of the agent's runs (`!session.backgroundJobs.isEmpty`). `BackgroundJobs.jobs` takes every `zsh`/`bash`/`sh` child of the agent carrying a shell snapshot, however old it is. Three checks depend on it:
  - The silent stall ("reads as working, transcript hasn't grown for 15 min") needs `!shellRunning`.
  - The undelivered stall is skipped while `working && shellRunning`.
  - Between turns, any shell sets `waitingOn`. That suppresses "stopped without reporting" and stretches the idle stall from 10 to 45 min (`backgroundCeiling`).

  Claude's foreground Bash calls are capped at 10 min, so a shell that is hours old is never what a turn is blocked on. A `run_in_background` dev server is exactly such a shell.
- **Sequence.**
  1. A worker starts a server with `run_in_background`.
  2. Later its turn hangs mid-stream: it reads as working, but nothing is written.
  3. The lead is never told, for as long as the server runs.
- **Where.** `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift:967-971`; `Sources/VibeCore/LeadStall.swift:111,113,118`; `Sources/VibeCore/LeadWitness.swift:313`; `Sources/VibeCore/BackgroundJobs.swift:14-20`.
- **Evidence.** Code reading. `LeadStallTests.aWorkerThatReadsAsWorkingButWroteNothingFor15MinIsStalled` asserts that a shell (and `shellRunning: true` covers "a long build, a background job" alike) means no stall.
- **Impact.** A hung worker holds its task, and the user's wall-clock, until someone looks. "Stopped without reporting" comes 35 min late.
- **Fix sketch.** For the silent and undelivered checks, count only shells started within the Bash tool's 10-min ceiling, or after the transcript's last write. Make `waitingOn` the transcript's named background task, not any shell.
- **Check.** A `LeadStallTests` case: mid-turn, quiet for 20 min, shells = [a server started 2 h ago] → a silent stall. A shell started 3 min ago → none.

### 6 · P3 · A tool server that exits mid-merge leaves the test run going, unlocked

- **Failure.** On stdin EOF, `MCPServer.serve()` returns and `vibeswitcher-mcp` exits. EOF is what a closed or restarted lead gives it, and the host's orphan sweep sends SIGTERM, for which there's no handler. Tool calls still running aren't cancelled:
  - Merge's test command runs in a process group of its own (`Shell.run`), so it outlives the process.
  - The process's `TestLock` fd closes with it, so the command runs on without the lock.
  - `rebaseAndTest`'s `defer { remove() }` never runs, so the `merge-<slug>` worktree stays registered.
- **Sequence.** The lead's session is closed or restarted during a merge's test run, for example the restart after an install.
- **Where.** `Sources/VibeCore/MCPServer.swift:533-535`; `Sources/vibeswitcher-mcp/main.swift:288`; `Sources/VibeCore/Worktrees.swift:105-118` (the child's own group).
- **Evidence.** Code reading.
- **Impact.** An unlocked suite beside the next holder (as in #4), plus a stale merge worktree.
- **Fix sketch.** On EOF or SIGTERM, cancel every running `ShellCancel` and wait (10 s at most) for the calls to unwind and their `defer`s to run, then exit.
- **Check.** An `MCPServerTests` case: a call running a grouped `sleep 60`. After closing stdin, the sleep is gone and the call's cleanup ran.

### 7 · P3 · `--install` can leave the old app running, or no app, and kills benches named `VibeSwitcher`

- **Failure.** The install path runs:
  1. `pkill -x VibeSwitcher`;
  2. a wait of up to 10 s on `pgrep -x VibeSwitcher`;
  3. `rm -rf` of the bundle, `cp`, then `open`.

  There's no SIGKILL fallback. The app routes SIGTERM to `NSApp.terminate` on the main queue, so a hung main thread (this app's worst history, R1) never quits. `open` then activates the old instance, running from a deleted bundle, or is dropped while it quits, leaving no app. `-x VibeSwitcher` also matches the debug bench apps of other workers' perf runs: it kills them, and the wait waits on them.
- **Where.** `scripts/build-app.sh:156-161`; `Sources/VibeSwitcher/AppDelegate.swift:112-114`.
- **Evidence.** Code reading. Not reproduced: it would need the installed app.
- **Impact.** After an install the user may be on the old binary without knowing, or have no app at all. A worker's bench fails for no reason of its own.
- **Fix sketch.** Match on the `/Applications/VibeSwitcher.app` executable path (`pgrep -f`), SIGKILL after the wait, then check that the running pid's executable is the new one.
- **Check.** A script test with a fake app at a scratch path that ignores SIGTERM: the install ends it and launches the new one. A same-named process elsewhere is untouched.

### 8 · P3 · The hook's own 3 s alarm can cut a steered-message delivery halfway

- **Failure.** `SteerInbox.deliver` is not safe against the hook's `alarm(3)` → `_exit(0)`, or against a SIGTERM from the agent cancelling its hooks. It runs in this order:
  1. It hands the batch to stdout (`hand`).
  2. It appends the `.delivered` log.
  3. It rewrites the inbox in place, `truncate(atOffset: 0)` and then `write(rest)`.

  Killed after (1), the messages stay queued and are delivered again. Killed between the truncate and the write, the rest of the queue (a long message's later parts, or messages beyond one batch) is lost. The hook can spend about 3 s before the handover (state lock, vault, inbox lock, seal check: up to 1 s each on a loaded Mac), so the alarm can land right there.
- **Where.** `Sources/vibeswitcher-hook/main.swift:14-15`; `Sources/VibeCore/Steer.swift:132-152`.
- **Evidence.** Code reading. Narrow window.
- **Impact.** The user's steered words are acted on twice, or occasionally lost silently.
- **Fix sketch.**
  - Write `rest` to a temporary file and rename it over the inbox under the lock.
  - Block SIGALRM and SIGTERM from the stdout write through the rename.
  - Hand nothing over once less than about 0.5 s of the alarm's budget remains.
- **Check.** A test runs `deliver` in a child whose `hand` exits after writing, killed at each step. The queue never comes back shorter than expected, and no id in `.delivered` is handed over again.

### 9 · P3 · A suspended agent hides the agent in use on the same terminal

- **Failure.** On each tty, the scanner takes the earliest-started agent process as the session. The Codex daemon hook's `codexTerminals` does the same. A stopped (Ctrl-Z) agent isn't excluded:
  1. `claude`, suspended; then `codex` in the same tab.
  2. The tab shows the frozen Claude.
  3. Codex's state file is discarded (`state.agent != agent`).
  4. Codex's daemon hooks find no Codex root on that tty and write nothing.
- **Where.** `Sources/VibeCore/SessionScanner.swift:94-95,124`; `Sources/VibeCore/SessionIdentity.swift:78-86`.
- **Evidence.** Code reading.
- **Impact.** The session the user works in has the wrong status, notifications and phone view, and a steered message waits on a stopped process. Niche.
- **Fix sketch.** Add the process group and the terminal's foreground group (`e_pgid`, `e_tpgid`) to `ProcInfo`. Prefer the agent in the foreground group, else the earliest one that isn't stopped. Use the same rule in `codexTerminals`.
- **Check.** A `SessionDetectionTests` case with a fake table: an older Claude in a background group and a newer Codex in the foreground group on the same tty. Today it picks Claude; after the fix, Codex. The same table goes through `codexTerminals`.

---

## Looked at, fine

- **PTY spawn** (`PTYSpawn`). There's no fork in the multithreaded host: posix_spawn with SETSID, CLOEXEC_DEFAULT, default signals and an empty mask, then an explicit TIOCSCTTY and exec, so the program keeps its pid. The master is CLOEXEC, so later sessions don't inherit it.
- **Session end.**
  - An exit source, backed by the exit poll (0.05 / 1 / 5 / 30 s).
  - `waitpid` with WNOHANG on the session's own pid only, and the PTY closed only after its watchers are cancelled.
  - On macOS the session leader's exit revokes the terminal, so the master reads end of file even when something it left still holds the slave (checked with a scratch PTY). So `terminate` on an ended session returns at its guard, and never reaches the closed (possibly reused) master fd or the reaped pid. A scratch program confirmed that the fd number *is* reused by the next PTY and that `tcgetpgrp` on it names the new session. The guard is what keeps that harmless.
- **Handover.**
  - The new build is probed first (180 s limit, killed and reaped after it).
  - The state file is 0600, written atomically, with the format checked.
  - Only the lock, the socket, the secret channel and the masters are inherited. Parsers are stopped before the exec, and a failed exec resumes them.
  - A build that can't restore execs the old build's own copy again (`--handover-fallback`).
  - Children stay the host's, so `waitpid` still works after the exec.
  - Residual, not material: the 5 s SIGKILL follow-up of a `terminate` issued just before a handover is an in-memory timer and is lost with the exec. Only a program that ignores SIGHUP survives that, within a 5 s window. Verifiers are ended again at housekeeping anyway.
- **E-09 (2026-10-19).** Now fixed: a host that closes before its welcome or its reply throws (`SessionDigest.swift:150-156`).
- **Parsers.**
  - Each runs in its own process group with default signals and only its own fds, and watches the host with an exit source plus a `getppid` check.
  - A stalled or failed parser is SIGKILLed and reaped. A parser that fails too often isn't restarted.
  - The stray-parser sweep is limited to the host's own children.
- **Orphan tool-server sweep.** It needs ppid 1, the user's uid and the exact resolved path. It sends SIGTERM only.
- **Signals in the host.** SIGTERM and SIGINT are logged with their sender through a pipe, then re-raised, with `_exit` as a backstop. SIGPIPE and SIGHUP are ignored, and a handover's exec restores the defaults.
- **The app and the host.**
  - The host is started detached (SETSID) and reaped by an exit source.
  - Reconnects back off (about 12 s in all) before sessions are marked ended.
  - A connection dropped by a handover waits for the new build's welcome.
  - The vault's Keychain read never prompts (`SecKeychainSetUserInteractionAllowed(false)`), so a new build can't hang on a dialog mid-handover.
- **Process table.**
  - Mid-exec reads count as unknown.
  - Zombies and exiting processes count as gone.
  - The argv cache is keyed on (pid, start, comm).
  - Reads are bounded. A cold read of 656 processes and 165 argv took 4–5 ms at load 39.
  - Pid-only identity checks are always paired with the start time or the tty.
- **Terminal.app.**
  - R6 is fixed: in-process reads through one compiled script, with deadlines.
  - The remaining `osascript` calls drain both pipes, run under a watchdog and are reaped.
  - AX calls run off main with 0.5 s timeouts.
- **The hook.** The E-28 bound holds (3 s alarm, bounded stdin and lock waits), and its state writes are atomic. #8 is the only gap found.
- **`Shell.run` and `TestLock`.**
  - `Shell.run` has a timeout plus grace and kills both the group and the family (pid plus start time). Its pipes are drained.
  - `TestLock`'s fd is CLOEXEC, and its folder's owner and link status are checked.
  - `VIBESWITCHER_TEST_LOCK` is set only while the lock is held, and `vs-heavy` runs COMMAND without fd 9.
- **Role sweep and stop_worker.**
  - The role sweep is scoped to the vault's roster and never ends a lead.
  - `start_worker` runs under its own lock and refuses when the host can't be read.
  - `stop_worker` waits for the end, with a deadline.

## Suggested order

1. **#2 first:** a one-line fix with a deterministic test, and its failure takes every session down.
2. **#1 with #4 together:** the orphaned suites are what make the lock's holder problem bite.
3. **#3:** live leftovers are costing the Mac now. The four hosts listed above are the user's to end. This audit didn't touch them.
4. **#5,** then the P3s as capacity allows.
