# How far the code is from compiling on Linux

Measured 2026-11-12 in a scratch copy (main at `f2ebe92b`, Swift 6.4.2, Ubuntu 24.04 on WSL2), for
[version 2's design](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md). The copy was thrown away; nothing here
is a port. The numbers are a floor: see "What the numbers don't cover".

## VibeCore: 505 errors in 34 of 171 files

The other 137 files type-check unchanged.

| Kind | Errors | Files | On Linux |
| --- | --- | --- | --- |
| Process inspection (`proc_pidinfo`, `sysctl` KERN_PROC, `kinfo_proc`, `proc_pidpath`, fd lists) | 177 | 11 | `/proc/<pid>/{stat,status,cmdline,exe,cwd,fd}`. `ProcessTable.swift` alone is 70 |
| `posix_spawn` | 74 | 4 | In glibc the attributes and file actions aren't optionals; `POSIX_SPAWN_CLOEXEC_DEFAULT`, `SETEXEC` and `addinherit_np` have no direct equivalent |
| Keychain (`SecItem*`, `SecAccess`, `SecTrustedApplication`) | 48 | 1 | No equivalent of the per-app access list: the security architecture's question |
| kqueue, `kevent`, `O_EVTONLY`, file-system sources | 38 | 3 | epoll, `pidfd_open`, inotify |
| Network.framework (`PreviewProxy.swift`) | 38 | 1 | Sockets. Understated: about 55 lines use it |
| Mach clocks and host statistics, `sysctlbyname`, `statfs` | 34 | 8 | `clock_gettime(CLOCK_MONOTONIC)`, `/proc/meminfo`, `statvfs` |
| CoreGraphics, ImageIO, UTType (`MenuBarDots`, `LeadImages`) | 33 | 2 | The dots are the Mac's; image sizes from headers |
| Darwin `stat` fields (`st_mtimespec`, `st_birthtimespec`, widths) | 19 | 9 | `st_mtim`; `statx` for the birth time |
| Peer credentials and socket options (`audit_token_t`, `LOCAL_PEERPID`, `getpeereid`, `SO_NOSIGPIPE`, `sun_len`) | 18 | 4 | `SO_PEERCRED`, `SCM_CREDENTIALS`, `MSG_NOSIGNAL` |
| Other libc (`O_EXLOCK`, `renameatx_np`, the `sigaction` union, `rlimit` types, `OPEN_MAX`) | 11 | 5 | `flock`, `renameat2`, `sa_handler` |
| CoreFoundation's boolean test | 6 | 2 | An `NSNumber` type test |
| Foundation gaps (`AttributedString(markdown:)` once, `NSSetUncaughtExceptionHandler`) | 6 | 2 | Own inline-markdown stripper; no handler |
| `SecRandomCopyBytes` | 3 | 1 | `SystemRandomNumberGenerator` |
| CryptoKit | 0 | 0 | swift-crypto 3.15.1 is a drop-in for the 20 files that use it |
| Objective-C runtime | 0 | 0 | Not used |

## VibeHost: 142 errors in 8 of 13 files

| Kind | Errors | Files |
| --- | --- | --- |
| `posix_spawn` | 62 | 3 |
| Code signing and Mach-O (`AppCode.swift`) | 29 | 1 |
| Keychain (`VaultStorage.swift`) | 25 | 1 |
| Process inspection | 12 | 2 |
| `DispatchSource.makeProcessSource` (pidfd on Linux) | 5 | 3 |
| Peer credentials | 5 | 4 |
| Other (`ptsname_r`, `ioctl`'s request type, a Dispatch block convention) | 4 | 2 |

The executables, type-checked against stubs: `vibeswitcher-hook` 0, `vibeswitcher-mcp` 1 (`F_SETNOSIGPIPE`),
`vibeswitcher-host` 4 (one `sigaction` line).

## What changes the plan

- **One construct is 103 of the errors**: optional `posix_spawnattr_t` and `posix_spawn_file_actions_t` at 9 spawn
  sites in 7 files, across both targets. One shared spawn wrapper removes them.
- **The trust chain is the design problem, not the count**: audit token, then the code-signature check, then the
  Keychain's access list.
- **SwiftTerm 1.19.0 builds on Linux unchanged.**
- **OpenCombine 0.14.0 builds** (three products) and lacks `combineLatest` and `merge`, which the app calls 10 times.
  Version 2's stores don't use Combine, so this matters only if a Mac model is ever compiled here.
- **The tests' home guard is inert on Linux.** `@_section("__DATA,__mod_init_func")` compiles and never runs;
  `@_section(".init_array")` runs at load. Until the Linux form exists, a bare `swift test` here is not refused.
- **`--build-system native`** is needed to see every error (the default build system stops at the first failing
  batch) and is deprecated in Swift 6.4.

## What the numbers don't cover

- How it was measured: `import CryptoKit` to `Crypto`, `import Darwin` to `Glibc`, the five framework imports behind
  `#if canImport`, and 89 `Darwin.`-qualified calls rewritten. `VibeHost` and the executables were checked against a
  `VibeCore` module emitted with errors allowed, so their numbers are softer.
- Closure bodies that failed inference were never checked.
- Checks that come after type-checking never ran on the 34 files with errors.
- Mac dependencies that only show at run time, counted by search and not compiled: `osascript` (4 lines), `Library/`
  paths (12), `/Applications` (7), `UserDefaults` (7), `/usr/bin/git` and `/bin/zsh` (16).

## A fully static build works

Tried 2026-11-12 with Swift's static Linux SDK 0.1.0 for 6.4.2 (musl), on a probe that prints a version, hashes with
swift-crypto 3.15.1, starts a child with `posix_spawn` and feeds a headless SwiftTerm 1.19.0 terminal:

| Build | Result | Size |
| --- | --- | --- |
| `--swift-sdk x86_64-swift-linux-musl -c release` | builds; "statically linked"; runs here, all four lines right | 152 MB, 58 MB stripped |
| `--swift-sdk aarch64-swift-linux-musl -c release` | builds; "statically linked"; not run (no ARM machine here) | 152 MB |
| the same probe against glibc, for comparison | builds and runs | 14.5 MB, plus the Swift runtime it needs installed |

So a node can ship as binaries with nothing to install beside them, for both architectures, from this machine or a
hosted runner. What it asks of the code:

- The platform layer has to compile against musl as well as glibc: `#if canImport(Glibc)` … `#elseif
  canImport(Musl)`, never a bare `import Glibc`. The spike's 89 `Darwin.`-qualified calls become unqualified or go
  through `Platform/`.
- Most of the size is Foundation and its Unicode data, and each static binary carries its own copy. Four binaries
  that size is 230 MB stripped, so the release is one binary that acts by the name it's called under (`vibeswitcher`,
  `-host`, `-hook`, `-mcp`, `-server`), or the small ones (the hook runs on every agent event) avoid Foundation.
  Decided in stage 1's plan, with the hook's start-up time measured both ways.
- SwiftPM puts cross-built products in `.build/out/Products/Release-staticlinux-<arch>/`.

## The hosted runners

- **macOS**: the `xcode-27` image (macOS 27.0.1, arm64) has Xcode 27.2 and Swift 6.4.2, the Xcode the Mac that builds
  main uses. `macos-26` stops at Xcode 26.6. The whole package builds there in about 3 minutes.
- **Ubuntu 24.04**: the image's own Swift is used when it is `.swift-version`'s, else swiftly installs that version.
- The Mac suite on the runner: what it can't run is in [the skip list](../../scripts/ci/macos-runner-skips.txt) (10
  entries at `8f87b8f0`, each with its reason), and how long it takes is below.

**The Mac suite's time on the runner** (read 2026-11-15 from `gh run view <id> --json jobs`). `v2 macos` runs one job a
test target, side by side, since `47636aaf`; a job's time is from its start to its end, the build included
(`scripts/test.sh` builds everything before it tests). The last eight green runs on `v2`:

| Run | Commit | platform | core | host | app |
| --- | --- | --- | --- | --- | --- |
| 43735006004 | `ad5e6f1a` | 9m30s | 53m59s | 16m10s | 18m09s |
| 43730429307 | `584220b8` | 8m15s | 48m17s | 9m37s | 13m14s |
| 43587007568 | `07c17611` | 21m52s (a re-run, attempt 2) | 47m07s | 13m07s | 17m56s |
| 43524475145 | `d44a29e2` | 12m32s | 48m43s | 13m17s | 12m32s |
| 43460059661 | `03b15058` | 16m01s | 51m25s | 13m45s | 13m31s |
| 43419880736 | `065b943c` | 16m40s | 48m31s | 12m02s | 12m26s |
| 43320958043 | `ca5c1a93` | 16m49s | 50m29s | 10m40s | 14m42s |
| 43308184833 | `4485b65a` | 13m26s | 49m07s | 10m11s | 18m45s |

So the core job sets the run's length, 47 to 54 minutes inside its `timeout-minutes: 90`; platform takes 8 to 22
minutes (its limit is 45), host 10 to 16 and app 12 to 19 (90 each). Run one after another, the four would take about
an hour and a half, which is why they are split.

## State at the end of stage 1 (2026-11-13)

- **Builds on Linux:** `VibePlatform`, `VibeCore`, `VibeNode`, the hook (`vibeswitcher-hook`), the tool server
  (`vibeswitcher-mcp`) and the command line (`vibeswitcher-cli`, installed as `vibeswitcher`).
- **The Linux suite** (`bash scripts/test.sh`, on this 24-core machine): 2,801 tests in 345 suites passed, with 1
  known issue.
- **`VibeHost` still doesn't build on Linux**, nor `vibeswitcher-host`: it is stage 2's
  ([its plan](../superpowers/plans/2026-11-13-v2-stage-2-session-host.md)). `scripts/ci/linux-core-errors.sh` counts
  its errors (142 in 8 files at `dbbeecbe`).
- **What remains of stage 1** ([its plan](../superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md#remaining-work-revised-2026-11-13)):
  nothing in stage 1 itself. R3 was met at `4485b65a`, the first commit with every `v2 linux` and `v2 macos` job green
  ([the plan's done-when](../superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md#done-when-revised-2026-11-13)),
  and R10, a real Claude Code session from working to needs-you to done, passed here on 2026-11-13 (below). R2's
  twenty Linux runs of the three signal suites were recorded on 2026-11-15 at `8f87b8f0`: with the fix undone, 20 of
  20 passed (the collision didn't show on Linux; the Mac's run 43249423203 is what showed it); with the fix, 20 of 20
  passed, no failure and no run ending on a signal. Three of the plan's steps stay open, each moved to the plan's R13
  (after the bootstrap): Task 10 Step 3 (the developer-tools callers through `Platform.Tools.hasDeveloperTools()` and
  the three hard-coded tools: "Task 10's leftovers"), Task 12 Step 5 (`platform-parity.md` and its lint) and Task 13
  Step 5 (the hook's start-up time, static and glibc, for the binary decision: "The static build, the hook's start-up
  time and the binary decision"), which waits for a pinned `swift sdk install` step in CI: the musl SDK is only on this
  machine.

## A real Claude Code session on Linux (2026-11-13)

Stage 1's R10, on this machine (Ubuntu 24.04 under WSL2): `RealClaudeStatusTests.aRealSessionGoesFromWorkingToNeedsYouToDone`
in `Tests/VibeNodeTests/RealClaudeStatusTests.swift`, run by
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter RealClaudeStatusTests`, `<config>` being
a throwaway Claude Code config folder the user logged in once. Claude Code **2.1.323** (the native build, run as
`~/.local/bin/claude`, a link to `~/.local/share/claude/versions/2.1.323`), model sonnet (Sonnet 5.5 on the screen).
Without the variable the test is skipped, saying why.

The test installs the hooks into `<config>` (`vibeswitcher hooks install --agent claude`, a scratch
`VIBESWITCHER_HOME`), writes the scratch project's trust entry into `<config>/.claude.json`, and starts
`claude --model sonnet --permission-mode manual '<prompt>'` on a pty of its own (util-linux `script`), the prompt
asking it to run `touch made-by-claude` with Bash. It polls `vibeswitcher status --json` every 0.5 s, presses Enter
on the permission question, and quits with Ctrl-C twice.

**What `status` said, in order**, the same in each of the three passing runs:
`unknown -> working -> needs-you -> working -> done`. Unknown is the first poll, before the first hook wrote. The
session was found on its terminal (`ttypts4`) although the native `claude`'s process name is `2.1.323`: argv[0]
tells it apart, in the hook's lineage and in the status scan. The whole turn took about 2.3 s from the prompt to
Stop; the test, about 4 s.

**The state files** (`state/ttypts4.json`) a poll saw, without the prompt, transcript, folder and session id that
each also carried:

| `lastEvent` | Also there | `status` |
| --- | --- | --- |
| `UserPromptSubmit` | `agentPid` | working |
| `PermissionRequest` | `toolName` Bash, `request` "Run: touch made-by-claude", `notice` "Wants permission to use Bash", `toolDetail` "Create empty file" | needs-you |
| `PostToolUse` | the same tool, its notice kept | working |
| `Stop` | `lastMessage` "finished" | done |

After Ctrl-C twice the session ended and its `SessionEnd` hook removed the state file. In the second run the quit,
as first written, looked for "again to exit" on a screen whose spaces are cursor moves, waited its 2 s out and sent
the second Ctrl-C after Claude Code's window: the session was still running 15 s later and was killed (that run took
31 s, the others 4), and the file stayed, saying Stop. No hook runs on SIGKILL; `status`'s sweep of state files with
no agent on their terminal, 15 s after their last write, is what clears it then.

**Found on the way:**

- **2.1.323's default permission mode is auto mode** ("auto mode on" on the screen): the first run's Bash command ran
  unasked and the session went from working to done with no needs-you. The test starts it with
  `--permission-mode manual` (2.1.323's choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`,
  `plan`; there is no `default` any more).
- **No product change was needed on Linux**: the hook, the status scan and `ProcessTable` worked as they were.

**What each run leaves in `<config>`:** the hooks are taken out again (`hooks remove`; `settings.json` keeps its own
settings, and `HookInstaller` leaves `settings.json.vibeswitcher-backup` beside it), and the project's trust entry is
taken out of `.claude.json` again after Claude Code has ended. Claude Code's own files for the session stay, as for
any session: its transcript under `projects/<the scratch project's name>/`, a folder in `session-env/` and in
`shell-snapshots/`, and the prompt in `history.jsonl`.

## A real Claude Code under a scratch host (2026-11-14, Linux 5.15.167.4-microsoft-standard-WSL2)

Stage 2's Task 12a, on this machine (Ubuntu 24.04 under WSL2, 24 cores):
`RealClaudeHostTests.aClaudeSessionSurvivesItsClientAHandoverAndAKilledParser` in
`Tests/VibeHostTests/RealClaudeHostTests.swift`, run by
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter RealClaudeHostTests`, `<config>` the
throwaway Claude Code config folder of R10. Claude Code **2.1.323** (`~/.local/bin/claude`, the native build), model
sonnet (Sonnet 5.5 on the screen). Without the variable the test is skipped, saying why.

A scratch host (`ScratchHostProcess`: its own home, socket and lock, the test its app through the connector stand-in)
spawns `exec claude --model sonnet --permission-mode manual` in a scratch repository whose trust entry the run writes
into `<config>/.claude.json` (and takes out at its end), `CLAUDE_CONFIG_DIR` coming through the spawn request's
`env`. No prompt is sent. Each step's time, from the step before, in the passing run (the same within 0.1 s in the
two runs before it, which failed only at step 6):

| Step | Time | From the spawn |
| --- | --- | --- |
| 1. A client reads the screen until the prompt shows (Claude Code's box, `⏸ manual mode on · ? for shortcuts`), its screen the same a second later; it disconnects | 1.4 s | 1.4 s |
| 2. A new client attaches: the same screen | 0.1 s | 1.5 s |
| 3. A handover to the same code's build (`newBinary`, through sealed memory): listed with the same id and terminal (`ttypts4`), still running, the same screen | 0.2 s | 1.8 s |
| 4. The parser killed (`SIGKILL`): the watchdog starts another from the replay, and its screen is the same | 0.1 s | 1.9 s |
| 5. `/exit` sent as an `inputUnit` (the text, Enter 0.06 s later): the session's exit recorded, "exited 0" | 0.4 s | 2.3 s |

**Step 6, no parser reply dropped (Task 9e), found two replies Claude Code's start draws from the headless terminal
that 9e's table didn't answer:**

- **The focus report.** Claude Code turns focus events on as it starts (`CSI ? 1004 h`), and SwiftTerm 1.19.0, as
  xterm does, says at once that it has focus (`CSI I`, `sendFocusReport`). 9e's table took that responder for a
  view's only, so on Linux the report was dropped and logged, and Claude Code never heard it had focus while no view
  was attached (the Mac types it). Fixed in `ParserReplies`: DECSET 1004 is a query whose reply is `CSI I` or
  `CSI O`, one per 1004 the setting names (`ParserReplyTests.aProgramTurningFocusEventsOnIsToldItHasFocus`, and
  `everyQueryIsAnsweredInItsGrammar`'s cases).
- **The kitty graphics probe** (`APC G i=31,…,a=q;… ST`), which the headless terminal answers `APC G i=31;OK ST`.
  9e leaves kitty graphics out on purpose, so the reply is dropped and logged ("it is no reply"), once per session
  start: Claude Code then takes the terminal for one without kitty graphics, which a headless parser is in effect.
  The test allows that drop and no other. The probe stays unanswered (the lead's call, 2026-11-14: the allowance
  kept, as made).

**The 12a review (2026-11-14): a drop was hiding behind the log's once-a-second line.** The host logged a dropped
reply a line a second at most; a drop within that second was only counted, and the count reached the log only with
the next logged drop, so a drop held back when the parser stopped was never logged (the passing run above could not
see one). `ParserReplies.flushDropped` now logs what was held back when a session's parser stops (the session ending,
a handover's exec, the host quitting), and step 6 waits for the parser to stop and allows a line only if every drop it
counts is named and is a kitty graphics reply. The run after that fix (16:25, Claude Code 2.1.323, steps 1 to 5 in
1.5, 0.1, 0.2, 0.1 and 0.4 s) **failed step 6**: the first host image logged, as its parser stopped for the handover,
"1 more dropped since the last line", 1.2 s after the kitty probe's drop. That build counted without naming, so which
reply it was is not known; the flush line now names it, and the next gated run will say. Claude Code's binary holds a
second kitty graphics probe (`s=1,v=1,a=q,t=f,f=32`) beside the `t=d,f=24` one whose reply was logged: a likely
candidate, not confirmed. The slice's four gated runs are spent.

**Step 6 identified and made exact (2026-11-14, two gated runs, Claude Code 2.1.323, sonnet).** A dropped reply's
log line now names its kind as well as its bytes (escaped, the first 64): a reply a left-out responder makes is "a
kitty graphics reply, left out" (or clipboard, title report, DECRQCRA, mouse report), not "no reply"
(`ParserReplies.leftOutKind`, `ParserReplyTests.aDroppedRepliesLineNamesItsKind`, shown failing first). The first
run (17:29; steps 1 to 5 in 1.5, 0.1, 0.2, 0.1 and 0.4 s, 2.4 s from the spawn) named the drop held back: **a second
kitty graphics answer, the same 12 bytes `ESC _ G i=31;OK ESC \`**, held back within a second of the first and logged
by the flush as the first host image's parser stopped for the handover; nothing else was dropped, in either log.
2.1.323 sends two probes, both id 31, as it starts: `i=31,s=1,v=1,a=q,t=d,f=24;AAAA` and `i=31,s=1,v=1,a=q,t=f,f=32;<a
file name, base64>`, each queued behind a DA1 sentinel (`CSI c`): a query unanswered when the sentinel's DA1 reply
comes is resolved as unsupported. So Claude Code needs neither answer and goes on without kitty graphics, as a
headless parser is in effect; both stay dropped (9e's choice, the lead's call above). Step 6's allowance is now
exact: each log (the session log and the host's) must count exactly two drops (`kittyGraphicsProbes`), every drop
it counts named, each that 12-byte answer and nothing else; a line with "(and N more …)", a flush naming fewer than
it counts, or anything cut short ("…") fails (`RealClaudeHostTests.kittyGraphicsDrops`,
`onlyTheKittyGraphicsDropsAreCounted`). The second run (17:33), with that step 6, **passed**: steps 1 to 5 in 1.4,
0.1, 0.2, 0.1 and 0.4 s (2.3 s from the spawn), the same two kitty graphics drops in each log and none other.

## Claude Code's shell snapshot and a verifier's command, measured (2026-11-14, Linux 5.15.167.4-microsoft-standard-WSL2)

Stage 2's Task 12b, on this machine (Ubuntu 24.04 under WSL2, 24 cores): `RealClaudeTests` in
`Tests/VibeHostTests/RealClaudeTests.swift`, run by
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter RealClaudeTests`, `<config>` the
throwaway config folder of R10. Claude Code **2.1.323**, model sonnet. Each test's scratch host (`ScratchHostProcess`,
its `SHELL` set to `/bin/bash` as the node's unit has it from the account) spawns `exec claude --model sonnet
--permission-mode manual --settings '<json>' '<prompt>'` in a scratch repository trusted in `<config>`, the settings
allowing only the command the prompt names (no permission question was shown in any run). Four gated runs: the first
two ran both tests (the snapshot's passed both times, the same; the verifier's failed at once, below), the last two
the verifier's only (the third failed on the timeout assertion as first written, the fourth passed). A fifth, after
the 12b review's fixes (17:38, Claude Code 2.1.323, sonnet), ran all three tests and **passed**: the snapshot's in
both homes (4.8 s for the two), the verifier's in 40.9 s, bash's own in 0.1 s; its results are below, marked "run 5".

**What Claude Code's Bash tool sources** (`whatClaudesBashToolSourcesIsMeasured`). The session starts as Task 10a
starts one (`/bin/bash --noprofile --norc -c "exec claude …"`, no startup file read there), in a scratch `HOME` whose
`.bashrc`, `.bash_profile`, `.profile` and `.zshrc` each export a variable, define a function and an alias, and log the
shell that read them (since the review's fixes each also puts a folder of its own, `$HOME/vs-<name>-bin`, first on
`PATH`). Claude Code's Bash tool is asked to run a script that prints the variables and the `PATH` it sees. Read, in
order, within 30 ms of the start (runs 1, 2 and 5):

| Who | Its command line | What it read |
| --- | --- | --- |
| Claude Code at its start, reading the shell's environment | `/bin/bash -c env`, stdin a socket, `SHLVL` 1 | `~/.bashrc` |
| The snapshot's shell | `/bin/bash -c -l <script>` (a login shell), stdin a socket | `~/.bash_profile` (the first of `.bash_profile`, `.bash_login`, `.profile` there is), then `~/.bashrc`, which the script sources itself |
| Each Bash tool command's shell | `/bin/bash -c "source <snapshot> … && eval '<command>' …"`, stdin a socket, `SHLVL` 1 | `~/.bashrc` |

**In a home shaped like this node's, `.profile` and `.bashrc` only (run 5):** the same three readers, within 24 ms:
`~/.bashrc` for `bash -c env`; `~/.profile` for the snapshot's login shell (stdin a socket), then `~/.bashrc` in the
same shell (its script's `source ~/.bashrc < /dev/null`: stdin `/dev/null` in the log); `~/.bashrc` for the command's
shell. The snapshot (5,997 bytes) held the functions and aliases of `.profile` and `.bashrc`, no variable, and
`export PATH=/usr/bin:/bin`. The command saw `SHELL=/bin/bash`, `PATH=/usr/bin:/bin`, `SHLVL=2`, `BASH_ENV` unset and
`VS_MARK_BASHRC=1` only. In the home with every file (run 5, within 30 ms) the readers were as in the table above,
the snapshot (6,007 bytes) held the functions and aliases of `.bashrc` and `.bash_profile` and the same
`export PATH=/usr/bin:/bin`, and the command saw the same.

- The snapshot (`<config>/shell-snapshots/snapshot-bash-<ms>-<id>.sh`, 6 KB) holds the functions and aliases of
  `.bashrc` and `.bash_profile`, `shopt` and `set -o` settings, Claude Code's own `rg`, `find`, `grep` and `pkill`
  wrappers and `export PATH=…`; no variable either file exported.
- The command saw `VS_MARK_BASHRC=1` and no other marker (`SHLVL` 2, `BASH_ENV` unset): its shell reads `~/.bashrc`
  itself, not through the snapshot. `BASH_ENV` was unset in every reader; each non-interactive bash that read
  `~/.bashrc` unasked had a socket for its stdin and `SHLVL` under 2. That is bash's own rule (bash(1), INVOCATION:
  a non-interactive bash whose stdin is a network connection, as under rshd or sshd, reads `~/.bashrc`; bash takes
  any socket for one), not a distribution's: Debian's `SSH_SOURCE_BASHRC` only adds the `SSH_CLIENT` check. Claude
  Code's children get socket pairs for their standard streams.
- `.profile` was read by nobody here: a login bash reads the first of `.bash_profile`, `.bash_login` and `.profile`
  there is, and `.bash_profile` was there. `.zshrc` by nobody (no zsh here; the snapshot is bash's because `SHELL` is
  bash).
- **This node's home is not that home**: it has `.profile` and `.bashrc` and no `.bash_profile` or `.bash_login`.
  `.profile` has no interactive guard; it sources `.bashrc`, puts `~/bin` (when it exists) and `~/.local/bin` first on
  `PATH` and sources `~/.local/share/swiftly/env.sh`, which puts swiftly's `bin` first. `.bashrc` returns at its
  interactive guard (line 8) in any non-interactive shell. Measured with bash alone, ungated, in Claude Code's shapes
  (`theStartupFilesBashReadsInClaudeCodesShapesAreMeasured`, a scratch home, stdin a socket, no `SSH_CLIENT`): the
  login bash in a home with `.profile` and `.bashrc` only reads `.profile` and keeps the PATH it sets; with a
  `.bash_login` added it reads only that, with a `.bash_profile` added only that; the non-login `bash -c` reads
  `.bashrc` with stdin a socket and nothing with stdin `/dev/null`. Run 5 confirmed it with Claude Code in a home
  shaped like the node's (above): the snapshot's shell reads `~/.profile`, and a worker that creates
  `~/.bash_profile` or `~/.bash_login` replaces it.
- **The command's PATH is the one Claude Code started with, not the startup files'** (run 5, correcting the review's
  reading of the binary, which said the snapshot took its login shell's). Every startup file put a folder of its own
  first on `PATH`, the login shell read `.profile` (or `.bash_profile`) and `.bashrc`, and the command's own shell
  read `.bashrc`; yet both snapshots held `export PATH=/usr/bin:/bin` and the command saw `PATH=/usr/bin:/bin`, the
  scratch host's, which the session's bash and Claude Code had. The binary says why: on Linux the snapshot's script
  writes `export PATH=<Claude Code's PATH>` (a settings `env.PATH` if one is given, else its own `process.env.PATH`,
  plus any plugin `bin` folder not on it, `bns` in 2.1.323); the branch commented "Add PATH to the file, as this shell
  has it, plus missing plugin dirs" (`__cc_path=$PATH`) runs only on Windows, when Claude Code couldn't read the
  shell's PATH. Each command sources the snapshot after its shell has read `~/.bashrc`, so `~/.bashrc`'s PATH change
  is overwritten too. On this node Claude Code starts with the unit's PATH
  (`/usr/local/bin:/usr/bin:/bin:<swiftly's bin>:<node's bin>`), so that is what every agent's Bash command runs
  with; `~/.local/bin` and `~/bin`, which `.profile` puts first, aren't on it.
- So the plain bash a team session starts in (Task 10a) keeps the startup files out of the session's shell, and out
  of the commands' PATH, but not out of the commands: each command's shell runs `~/.bashrc`, and sources the
  snapshot, which keeps the functions and aliases of the first of `~/.bash_profile`, `~/.bash_login` and `~/.profile`
  there is and of `~/.bashrc` (a function named `git` runs ahead of any PATH) (S9, S10, S11 items 8 and 10).

**A verifier's command in a session of its own** (`aVerifierCommandInItsOwnSessionStillTimesOut`). The session gets a
verifier's environment through its inline settings (`LeadLaunch.verifierEnvironment` with the built
`vibeswitcher-mcp`), so each Bash command runs as `vibeswitcher-mcp '<line>'` and `BranchCode.runPrefix` starts the
branch-code wrapper as a child in a POSIX session of its own (Task 10c).

- 2.1.323's Bash tool refuses a standalone `sleep 611` ("rejected sleep 611 as a standalone sleep", runs 1 and 2), so
  the command is a script that sleeps, `./hold.sh 611`.
- Its processes, as it ran: the prefix in a session of its own (Claude Code starts each command's shell as a session
  leader: `setsid()` in place would fail there, Task 10c's reason), the wrapper in a new session, and under it the
  shell, the script and `sleep` in the wrapper's session.
- **The timeout (5000 ms) ended nothing**, in runs 3 and 4: Claude Code moved the command to the background ("The
  command hit the 5-second timeout and is now running in the background") and every process of it, the prefix
  included, still ran 30 s later. So a SIGKILL to the prefix that couldn't be passed on never happens at a timeout:
  the tree stays whole, Claude Code's. Run 5 the same: all five (prefix, wrapper, shell, script, `sleep`) still ran
  30.0 s later, the screen saying the command "didn't finish within the 5-second timeout, so the harness moved it to
  the background".
- **The interrupt (Escape, 2.0 s after the `sleep` started) ended every process of it** (prefix, wrapper, shell,
  script, `sleep`) within 0.1 s, runs 3 and 4; in run 5 all five ended at 2.1 s from the start.
- **`/exit` with that command still in the background** asked first ("Background work is running … 1. Exit and stop
  tasks 2. Move to background and exit 3. Stay"); Enter (1) ended the session 5.2 s after `/exit`, and every process
  of the command was gone at the same look (run 5: 5.2 s, all five ended at 38.5 s from the command's start).
- In run 5 the prefix was again in a session of its own (its pid's), the wrapper in a new one, and the shell, the
  script and `sleep` in the wrapper's, for both commands.
- Not measured: "Move to background and exit", which leaves the command running past its session by design (in its
  own POSIX session, with no terminal: no session's to the host, as an escape is); and Claude Code ended by a SIGKILL
  with a command running, which can't be passed on to the wrapper's session.

## Sealed copies: the measurement (2026-11-13)

Stage 2's Task 3b, on this machine: kernel 5.15.167.4-microsoft-standard-WSL2, Ubuntu 24.04 under WSL2, 24 cores,
three other builds running beside it. `SealedCopyTests` in `Tests/VibePlatformTests/SealedCopyTests.swift`, run by
`bash scripts/test.sh --filter SealedCopyTests`, and three times more under `scripts/test-under-load.sh --load 24`.

**The measurement holds.** A helper of the test binary, non-dumpable from its first statement, made a sealed copy of
`/bin/sleep` (a memfd, all four seals, `0111`) and started it as a child from `/proc/self/fd/<n>`. From the moment
the child's pid was known until 2 s later the test tried, every 2 ms, `pidfd_getfd` of the child's descriptor 0 and
an open of `/proc/<child>/mem`: 942 of each, every one refused (`EPERM`, `EACCES`), none let through. The same child
started from the readable `/bin/sleep` was taken on the first try of each (955 of 955 when the copy was left
readable, the failing form). So the exec windows of the security document's S6 are closed on this kernel: the
measurement decision 6 rests on passes here.

Also measured there:

- A copy held by a non-dumpable process can't be opened for writing (`EACCES`), `chmod`ded (`EACCES`) or taken
  (`pidfd_getfd`: `EPERM`) by another process of the user; its holder's own `write` and `ftruncate` fail `EPERM`
  (the seals). A copy held by a dumpable process is `chmod`ded and taken, which is why only a hardened process
  makes them.
- A copy runs as it was read after its file is rewritten in place (no process runs the file, so no `ETXTBSY`), and
  the bytes `withBytes` gives are those, not the file's new ones.
- A script's copy left `0555` runs; made `0111` it can't (`/bin/sh` exits 2, refused the read).

**What copies cost** (`VIBE_SEALED_COPY_COST=1 bash scripts/test.sh --filter SealedCopyTests/whatCopiesCost`):

| Copy | Size | Time | `Shmem` |
| --- | --- | --- | --- |
| `vibeswitcher-mcp` (debug) | 56.2 MB | 21 ms | +53.3 MB |
| the test binary (debug, `VibeSwitcherPackageTests.xctest`) | 202.3 MB | 66 ms | +192.5 MB |
| ten copies of the test binary at once | 2,023 MB | 123 ms | +2,100 MB |
| `vibeswitcher-host` (debug) | not built on Linux yet (Task 4); measured once it is | | |

Ten at once take 2.1 GB, under a quarter of a GitHub Ubuntu runner's 16 GB (4 GB): the suites that start hosts as
processes (`ServerChildTests` and the others) needn't run `.serialized` on Linux for the copies' sake. A copy's
memory is gone when its last descriptor closes.

## The session host's tests on Linux: what differed (2026-11-13)

Measured while sorting `VibeHostTests` on this machine (kernel 5.15.167.4-microsoft-standard-WSL2, Ubuntu 24.04, Swift
6.4.2), the stage 2 plan's Task 5b. None of these is the Mac's behaviour changing; each is a thing the tests or the
host took from the Mac:

- **Foundation's file copy doesn't keep the modification date** (swift-corelibs-foundation's `copyItem`: the copy is
  dated when it was made). The host names its launcher copy by that date (`HostBuild.id`), so a host that went back
  after a failed handover said it was the newer build. `Platform.Files.copyKeepingModificationDate` sets the date on
  Linux; the Mac's copy keeps it by itself.
- **`components(separatedBy: "\n")` doesn't split `"\r\n"`** on Linux's Foundation (one `Character`); the Mac's, through
  `NSString`, does. A test reading a terminal's lines drops the carriage returns first.
- **`/bin/sh` is dash**: no function name with a hyphen, no `\x` in `printf`; run with `-i` it doesn't exec a lone
  command (a session's program stays `sh` over `sleep`; `exec sleep` makes it `sleep`); and a background job's
  redirections keep a copy of its stdout (fd 10) until they are all made, so a pipe read to its end waits for the
  job's FIFO to open.
- **Ubuntu's `nc` (OpenBSD's with Debian's patches) keeps the connection after its input ends** until the far end
  closes it; the host doesn't close a client that hasn't hung up. The tests pass `-N` there.
- **Foundation's `Process` didn't see a child end while a process the child started still held what it had inherited**
  (a starter `sh` a zombie with `isRunning` true for 300 s, its background job holding a socket of the test process's).
  Tests that start a process which leaves another behind use `Platform.Spawn` and `waitpid`.
- **No `plutil`**: the fake `claude` of `WorkerToolsTests` reads its config with `python3` where `plutil` is missing.

## A Unix socket's file, from the kernel (2026-11-14, Linux 5.15.167.4-microsoft-standard-WSL2)

- **unix_diag answers here** (`CONFIG_UNIX_DIAG=y`): a `NETLINK_SOCK_DIAG` request (`SOCK_DIAG_BY_FAMILY`) for one
  `AF_UNIX` socket by its sockfs inode number and its cookie (`SO_COOKIE`, which this kernel gives), with
  `UDIAG_SHOW_VFS`, returns `UNIX_DIAG_VFS`: the device and inode of the file the socket is bound to, the same after
  the file is renamed. `Platform.Sockets.boundFile` (`SocketsTests.boundFileIsTheFileTheSocketIsBoundTo`).
- **Its device is the kernel's own `dev_t`** (the file system's `s_dev`: major from bit 20), not `stat`'s: the root
  file system here, 8:32, is 0x800020 to unix_diag and 0x820 in `st_dev`. The shim converts with `makedev`.
- **Its device is the superblock's, which `stat` doesn't always give**: on ext4 and tmpfs here `st_dev` is the same
  device, but on an overlay whose lower and upper layers are two tmpfs mounts (made in an unprivileged user and mount
  namespace) unix_diag gave 0:110 (the overlay's) and `st_dev` 0:111 (the upper layer's); btrfs gives a subvolume's
  own device in `st_dev` (`btrfs_getattr`, not measured here). `/proc/self/mountinfo` gives the superblock's device
  for each mount, and `/proc/self/fdinfo/N` the mount (`mnt_id`) and, from Linux 5.14, the inode number (`ino`) of an
  `O_PATH` descriptor on a socket file (opening it otherwise is `ENXIO`): `Platform.Sockets.boundFile(of:at:)`
  compares those (`HostPathDeviceTests.aSocketOnAFileSystemWhoseStatDeviceIsNotItsOwnIsTheHosts`).
- **Its inode is 32 bits** (`udiag_vfs_ino` is a `__u32`): compared with the low 32 bits of the kernel's (`fdinfo`'s
  `ino`; `st_ino` before 5.14). ext4 here (`/`, which holds the home and `/tmp`), whose inode numbers fit them. A
  path's file whose number passes 32 bits matches on the low bits only, and the host's watch then checks by a
  connection too (`Platform.Sockets.kernelMatch`, `SocketsTests.aKernelMatchOnTheLowBitsOfAnInodePast32BitsIsNotConclusive`).
- **The listener is found by its sockfs inode number** (32 bits) **and its cookie** (`SO_COOKIE`, Linux 4.12): a
  kernel before 4.12 is asked by the number alone, which comes round after 2^32 sockets.
- **`fchmod` of a Unix socket before its `bind` sets the mode of the file `bind` makes** (the kernel takes the socket
  inode's mode, less the umask): `fchmod(fd, 0600)` then `bind` gave a 0600 file under umask 0, 022 and 077; without
  it, 0777 under umask 0. `glibc`'s `fchmodat(…, AT_SYMLINK_NOFOLLOW)` refuses a link (`EOPNOTSUPP`; this kernel has no
  `fchmodat2`, ENOSYS, so glibc 2.39 goes through `O_PATH`).

## WSL interop's binfmt_misc entries (the engine's E1 review, 2026-11-15, Linux 5.15.167.4-microsoft-standard-WSL2)

`ls /proc/sys/fs/binfmt_misc/` here gives `WSLInterop WSLInterop-late register status`: WSL with systemd registers a
second entry, `WSLInterop-late`, and both say `enabled` / `interpreter /init` (flags `PF` and `P`); `status` says
`enabled`. Either entry runs Windows programs, so turning `WSLInterop` off alone (`echo 0 >`, or `-1` to remove it)
leaves interop on. `NodeFacts` reads every entry of the folder: interop is on when any entry named `WSLInterop…`, or
any entry whose interpreter is `/init`, is enabled while `status` isn't `disabled`; one that can't be read makes it
"can't be told". Decision 2's step that turns interop off must leave both off (or set `[interop] enabled=false` in
`/etc/wsl.conf`, which registers neither); `vibeswitcher status` says whether interop is still on.

## The voice rule's scopes (the engine's E1, 2026-11-15, Linux 5.15.167.4-microsoft-standard-WSL2)

What `/proc/<pid>/cgroup` says for each process the voice rule (`VoiceRule`, the security architecture document's S3)
must tell apart. The layout here is **hybrid**: a unified `0::` line and v1 lines, `name=systemd` among them; the rule
reads both, and each that is there must pass. Every process measured so far gave the same lines:

```
29:name=systemd:/init.scope
26:pids:/init.scope
20:devices:/init.scope
19:memory:/init.scope
(the other v1 lines: /)
0::/init.scope
```

| Process | Lines | Source |
| --- | --- | --- |
| the agent's own Bash tool's child (a `claude` started by WSL's `/init` relay, its Bash tool's `bash`) | `0::/init.scope`, `name=systemd:/init.scope` | measured by the agent, 2026-11-15 |
| a scratch host started by a test (`ScratchNode`), its server child (from its sealed copy), and a session's program | `0::/init.scope`, `name=systemd:/init.scope` (the test process's own) | measured by the agent, 2026-11-15 |
| a shell in a new Windows Terminal tab here (`cat /proc/self/cgroup`; its chain is `init-systemd(Ub` → `SessionLeader` → `Relay(pid)` → `bash`) | `0::/init.scope`, `15:name=systemd:/init.scope`, `12:pids:/init.scope`, `6:devices:/init.scope`, `5:memory:/init.scope`; every other controller `/` | measured by the user, 2026-11-17 (the bootstrap path's M4), after a `wsl --shutdown` |
| a `claude` started in that tab, its Bash tool's child | the same lines, all `/init.scope` | measured by the user, 2026-11-17 (M4) |
| a `systemd-run --user --wait --pipe cat /proc/self/cgroup` | the unit was `run-u0.service`, started by the user's manager (the user journal: `Started run-u0.service - /usr/bin/cat /proc/self/cgroup.`, from `systemd[282]`, whose own `_SYSTEMD_CGROUP` is `/user.slice/user-1000.slice/user@1000.service/init.scope`). The line the unit printed wasn't captured: `0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-u0.service` is derived from the unit's name and the manager's cgroup, not pasted. The rule refuses it | the unit's name and the manager's cgroup measured by the user, 2026-11-17 (M4); the line derived |
| whether `journalctl --user` lists the user's own entries (`logger -t vibeswitcher-probe hello; journalctl --user -t vibeswitcher-probe -n 1 --no-pager`), or the command line needs `_UID=` | it lists them, without `_UID=`: the entry has `_UID=1000`, `_TRANSPORT=syslog` (`logger`'s; the command line's own go by the native socket) and `_RUNTIME_SCOPE=system` | measured by the user, 2026-11-17 (M4) |
| a journal entry whose writer ended at once (`logger`) | no `_SYSTEMD_CGROUP`, no `_SYSTEMD_UNIT`, no `_COMM`: journald read `/proc/<pid>` after the process was gone | measured by the user, 2026-11-17 (M4) |
| a journal entry whose writer stayed alive 2 s after its datagram | `_SYSTEMD_CGROUP=/init.scope`, `_SYSTEMD_UNIT=init.scope`, and `_COMM` | measured by the user, 2026-11-17 (M4) |
| cron (`/system.slice/cron.service`), at (`/system.slice/atd.service`) | refused | documented fixtures, not measured: no crontab for this account, no `atd` |
| ssh (`/user.slice/user-<uid>.slice/session-<n>.scope`) | taken | a documented fixture, not measured: no sshd here |

So `VoiceRule.terminalScopes` holds `/init.scope` (measured, by the agent on 2026-11-15 and by the user's M4 on
2026-11-17) and `/user.slice/user-{uid}.slice/session-*.scope` (documented); anything else is refused, and so is
anything under `user@<uid>.service` or in the node's unit. The agent started nothing in the user's systemd manager and
read nothing from the user's journal for this: the M4 rows are what the user ran and gave. The v1 hierarchies' numbers
are a boot's own (29, 26, 20 and 19 on 2026-11-15; 15, 12, 6 and 5 after the `wsl --shutdown` before M4): the rule
reads the `name=systemd` line by its name and the unified one by `0::`, never by number.

What this means, and what S3 already says it doesn't promise: **the agent's own Bash tool runs in `/init.scope`, as a
user's terminal does**, so the cgroup line can't tell the user's own Claude Code from the user; the typed word (EN-D5)
and the user's deny rules (decision 14) are the guard rails there. A scratch host's children are in the test
process's scope too: a scratch node's tests give the server their own scope (`--test-user-scopes`), and a session's
process is refused by the other lines (its ancestry holds the host, its terminal is a session's, its environment
carries `VIBESWITCHER_SESSION`).

**The M4 follow-up, done 2026-11-17** (Linux 5.15.167.4-microsoft-standard-WSL2):

- **No new scope.** The Windows Terminal tab's shell, the `claude` started there and its Bash tool's child are all in
  `/init.scope`, the row `VoiceRule.terminalScopes` already held; its basis now names the user's measurement too, and
  `VoiceRuleTests.aTerminalScopeIsTheUser` reads the tab's lines as measured.
- **The `systemd-run --user` unit is refused**, as expected: `run-u0.service` is under `user@1000.service`, so the
  rule's first line refuses it (`VoiceRuleTests.anAnswerFromATransientUserUnitIsRefused`, on the derived line, in the
  unified form alone and in the hybrid one; the manager's own `…/user@1000.service/init.scope` is refused there too).
- **`journalctl --user` lists the user's own entries without `_UID=`.** `NodeContext.journalEntries` adds
  `_UID=<uid>` to its matches all the same (`NodeJournal.readArguments`): it changes nothing that is read here and
  narrows the read to the user's entries wherever a journal holds more
  (`NodeJournalTests.theJournalIsAskedForTheUsersEntriesOnly`).
- **journald stamps `_SYSTEMD_CGROUP` only for a writer it can still read.** It reads `/proc/<pid>` when it takes the
  datagram, not when the datagram was sent: `logger`, which exits at once, left an entry with no `_SYSTEMD_CGROUP`,
  `_SYSTEMD_UNIT` or `_COMM`, and a writer alive 2 s later got all three. The command line's entries count only by
  `_SYSTEMD_CGROUP` (`NodeJournal.passes`), and on the user's node it sent its datagram and returned: a command that
  ended right after writing (`status --ack`, `start`'s acknowledgment of S11, the stop fallback's entry, any entry
  written last) could leave an entry that never counts, and `status` then showed the user's own action as "not a
  terminal's" or as accepted with no entry. Fixed the same day: the command line stays until journald has the entry
  (`NodeContext.writeJournal`, `NodeJournal.awaitEntry`: a look for the entry's nonce with `journalctl --user`, up to
  5 s), and `status` lists an entry of the user's uid without one on a line of its own, "journald recorded no cgroup
  (the writer ended first), so who wrote it can't be told": it still doesn't count, and changes no other mark (the
  security architecture document's S3; the engine plan's E1, its Step 3 note of 2026-11-17).

## The user manager's environment (2026-11-17, Linux 5.15.167.4-microsoft-standard-WSL2)

`systemctl --user show-environment | cut -d= -f1`, read by the agent after the `wsl --shutdown` before M4 (names only;
nothing was set there and nothing started in the manager), gave twelve names:

```
DBUS_SESSION_BUS_ADDRESS GSM_SKIP_SSH_AGENT_WORKAROUND HOME LANG LOGNAME PATH QT_ACCESSIBILITY SHELL SSH_AUTH_SOCK
USER XDG_DATA_DIRS XDG_RUNTIME_DIR
```

Against `NodeFacts.expectedManagerEnvironment`: eleven are in it, and `SSH_AUTH_SOCK` isn't. That is the lead's
measurement of 2026-11-16 again (the start plan's ST-D2), so nothing changes: `start` doesn't refuse this manager
(`NodeFolders.managerRefusal` leaves out `NodeUnit.unsetFromManager`, which is `SSH_AUTH_SOCK`: the unit unsets it), and
`status` names `SSH_AUTH_SOCK` as beyond the expected, as ST-D2's note of 2026-11-16 says it does. No name the manager
holds here would make `start` refuse. The expected set's other names (`MANAGERPID`, `INVOCATION_ID`, `JOURNAL_STREAM`,
`WSL_DISTRO_NAME`, `DISPLAY` and the rest) aren't in this manager's environment: they are expected, not required.

## The engine's proof under a scratch host (the engine's E9, 2026-11-16, Linux 5.15.167.4-microsoft-standard-WSL2)

`EngineEndToEndTests` in `Tests/VibeNodeTests/EngineEndToEndTests.swift`, on this machine (Ubuntu 24.04 under WSL2, 24
cores), each on a `ScratchNode` (a scratch host started from the build, its server the built `vibeswitcher-server`,
holding its fresh vault's first look as the user's host does), everything driven through the built command line on a
pty of its own (`script`).

**`aLeadStartedFromTheCommandLineAsksAndIsAnswered` (`FakeClaude` as the lead, and as the worker and verifier its tool
server starts) passes, in 217 s**: `lead` refused until `config held`/`config accept CARD` and `base show
--from`/`base accept CARD` (each code typed), then `lead REPO --goal "say hi"` started by the fake's resolved path; the
lead's `ask_user` with two options made a card `questions` lists; `answer CARD "the second"` (its code typed) was in the
vault (the request's action, and the message's digest under it) and then typed into the idle lead as its prompt, as the
user's, the message as it is. A second `start_worker` refused for `mac_max_sessions` (1, in the root's
`mac-limits.json`) was followed by one message from the room watch once the limit was raised (within its 60 s look),
with one wake prompt; the worker's blocked report reached the idle lead with one wake prompt; the verifier `audit`
started, waiting on a Bash permission prompt (Claude Code 2.1.316's form) its hooks reported, was declined after
`LeadWitness.promptWait` (120 s, real time) with the reason, and the lead told once. Two mutants of the engine fail it:
the user's answer recorded but never delivered (no prompt ending with the answer), and the witness never declining
(the verifier never declined, no report for the lead).

**A scratch node's workers couldn't reach their host** until the test gave the node's home a `.vibeswitcher` link to
its root (`ScratchNode`). The lead is given `VIBESWITCHER_HOME` on a scratch node (`LeadEngine.environment`), but the
workers and verifiers its tool server starts get only the host's session variables (`Platform.Tools.sessionEnvironmentNames`:
HOME, not `VIBESWITCHER_HOME`), so their tool servers looked for `<home>/.vibeswitcher/host.sock`, never asked their
role, and `start_worker` ended each worker 45 s on ("its vibeswitcher tools didn't connect"). The user's node is not
affected (its root is `<home>/.vibeswitcher`, and its sessions' HOME is the user's); on a scratch node the link is the
same layout.

**`aRealLeadOnSonnetAsksAndIsAnswered` (gated on `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`) did not pass on 2026-11-16; it
passed on 2026-11-17 (the next section).**
Three gated runs, Claude Code **2.1.325** (`~/.local/bin/claude`, the native build), `--model sonnet` (Sonnet 5.5 on the
screen), the scratch node's `<root>/v2/test/claude` a script running it with the config folder; the scratch
repository's trust entry written into the folder's `.claude.json` and taken out at the end:

| Run | Steps 1 (config and base accepted) and 2 (the lead started) | What happened |
| --- | --- | --- |
| 1 | 0.6 s, 0.2 s | the test process crashed (SIGSEGV in Foundation's `Process.run`, under `TestSupport.swift`'s `run`) while it polled `questions --json` with a child every 200 ms; the run's trust entry stayed and was taken out by hand. The wait now asks the server over the wire (`WireClient`), and the command line lists the card once |
| 2 | 0.5 s, 0.2 s | no card in 5 min; the screen in the failure was cut at its first empty cell (a NUL), so what it showed wasn't seen. The test now prints the screen (NULs as spaces), the lead's hook state and the board every 30 s |
| 3 | 0.6 s, 0.2 s | the lead started and took its start prompt, the goal in it; then **"You've hit your weekly limit · resets Nov 18, 6pm (Europe/Madrid)"**, and Claude Code's menu (stop and wait, wait and continue, usage credits) stayed up to the end |

What run 3's screen showed besides:

- **Claude Code 2.1.325 warns that eight of the lead's deny rules never match**: `Write(~/.vibeswitcher/mac-limits.json)`,
  `Write(~/.vibeswitcher/boost.json)`, `Write(~/.vibeswitcher/policy.md)`, `Write(~/.config/systemd/**)`,
  `Write(~/.config/environment.d/**)`, `Write(~/.vibeswitcher/v2/**)`, `Write(~/.vibeswitcher/lead/**)` and
  `Write(//mnt/c/**)`, each "never matches · use Edit(…)". No path is left open: each of the eight has its `Edit(…)`
  rule beside it (stage 2's Task 10b's Linux rules in `Platform.Tools.roleDenyRules`, `LeadLaunch.userSettings`), and an
  `Edit(…)` rule binds every built-in tool that edits a file, Write too. The `Write(…)` rules are only redundant; the
  follow-up, for the lead to decide, is to drop them so the warning goes. Not changed here. *2026-11-16, the engine
  sweep:* checked against the 2.1.325 binary's own rule check (a `Write`, `MultiEdit` or `NotebookEdit` rule with a
  path "is not matched by file permission checks — only Edit(path) rules are … Edit rules cover all file-editing
  tools"); Linux's five dropped from `Platform.Tools.roleDenyRules` (VibePlatform, `v2`'s own). `LeadLaunch.userSettings`'
  three stay: every role's on the Mac too, in a shared file, so their removal is owed on main
  ([v2-mac-tasks](v2-mac-tasks.md#owed-on-the-mac)); the lead will be warned of those three until then.
- **No status hook ran for the lead** (no state file under the node's root): the role's settings hold only the
  read-only PermissionRequest hook, and the status hooks are the user's settings' (`hooks install`), which the config
  folder didn't have. Without them the engine never sees the lead between turns and would type nothing into it. The
  test now runs `hooks install --agent claude` into the config folder first (this node's copy of the hook, which writes
  under the node's root through the lead's `VIBESWITCHER_HOME`) and `hooks remove` at its end, as R10 does.

The next run, after the weekly limit resets (Nov 18) and with the user's go-ahead (the three runs this task allowed are
spent): `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter EngineEndToEndTests/aRealLead`,
its `E9:` lines giving each step's time here.

## A real lead asks and is answered, both ways (the engine's E9 Step 2, 2026-11-17, Linux 5.15.167.4-microsoft-standard-WSL2)

`EngineEndToEndTests.aRealLeadOnSonnetAsksAndIsAnswered`, run as `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=~/.vibeswitcher-test-claude
bash scripts/test.sh --filter 'EngineEndToEndTests/aRealLead'`: a `ScratchNode` holding its first look, the lead a
real Claude Code **2.1.326** (`~/.local/bin/claude`, the native build) with `--model sonnet` (Sonnet 5.5 on the
screen), its status hooks and the repository's trust entry written into the throwaway config folder for the run and
taken out at its end (checked after each run: no hook, no trust entry; `settings.json.vibeswitcher-backup` is the
installer's one-time copy). Three runs, **the last two passed**:

| Step (`E9:` lines) | Run 1, 18:11 | Run 2, 18:27 | Run 3, 18:30 |
| --- | --- | --- | --- |
| 1, config held and accepted, base shown and accepted | 0.4 s | 0.6 s | 0.6 s |
| 2, the lead started | 0.2 s | 0.2 s | 0.3 s |
| 3, the lead asked; `questions` lists the card | 3.8 s | 3.8 s | 4.6 s |
| 4, its turn ended (its Stop hook) | not waited for | 1.2 s | 0.9 s |
| 5, `answer CARD Reader`, the code typed, to the answer in the lead | 0.0 s to answer, then never typed | 0.3 s, typed in as its prompt | 0.3 s, typed in as its prompt |
| 6, the lead asked its second question | | 2.1 s | 1.2 s |
| 7, `answer CARD Scanner` at once, to the answer in the lead | | 1.4 s, handed over by its Stop hook | 1.6 s, handed over by its Stop hook |
| 8, what it said next named the answer, its turn ended | | (checked on the wrong message) | 0.9 s |
| In all | failed after 305 s | passed, 10.3 s | passed, 11.3 s |

- **Run 1 failed on the case, not the node.** The answer was given 0.1 s after the lead asked, while its turn was still
  running (its hooks' last event PostToolUse). The engine types only into a lead between turns, so the answer waited
  in its inbox and the lead's own Stop hook handed it over about 1.5 s later: "Stop hook says: … The user sent this while you
  were working (through VibeSwitcher) … > Answer to your question DB5A8357 “Which name should we use for the project's
  parser?”: Reader", and the lead went on: "The user chose Reader as the parser's name…". The case waited 5 minutes for
  the answer as a typed prompt (`lastPrompt`), which was never due. Both are the product's ways; the case asserted one.
- **The case now shows both, each checked by the way it went** (the lead's transcript: a prompt whose digest is the
  one the vault records for the user's message, or a hook's added context holding that message under the user's
  sender line, which the hook gives only a message whose seal the vault took). The idle lead (its Stop hook waited
  for) had its answer typed in 0.3 s after `answer`, the message as it is, not prefixed; the second answer, given at
  once, was handed over by the Stop hook of the turn that asked, the inbox's delivered record gained it, nothing was
  typed, and the lead's next words named it ("You chose Reader for the parser and Scanner for the lexer."). Each
  answer reached the lead once.
- **Run 2's check of the lead's next message was satisfied too early**: the message its Stop hook reported as it handed
  the answer over ("…whether to call the lexer Lexer or Scanner, and I'm waiting for your answer") names both options.
  The case now reads the lead's own words after the answer in its transcript; run 3 passed with it.
- A real transcript (2.1.326) records a hook's added context as an `attachment` of type `hook_additional_context`
  (`hookEvent: Stop`, `content` a list of strings), as `FakeClaude`'s does, and a typed prompt as a `user` line whose
  content is the text.
- The hook's way with `FakeClaude`, ungated: `anAnswerBeforeTheTurnEndsIsTakenByTheLeadsHookAsTheUsers` (the answer
  waits sealed as the user's while the turn runs, nothing typed; the Stop hook, its seals checked by the scratch
  host's vault, hands it over under the user's sender line; the delivered record holds it; its seal is retired and it
  is typed no more).

## A full scratch team run (the bootstrap path's step 9, the start plan's S10, 2026-11-16, Linux 5.15.167.4-microsoft-standard-WSL2)

`ScratchRunTests` in `Tests/VibeNodeTests/ScratchRunTests.swift`, on a `ScratchNode` (never the user's node), everything
driven through the built command line on a pty of its own (`script`). The scratch repository commits `src/` and
`check.sh` (the test command, `sh ./check.sh`, which notes the folder it ran in); its `workflow.md` sets `merge_policy:
ask_sensitive` with `sensitive_paths: src/**`, `verifier_model: haiku` and `audit_finders: 1` (ST-D21).

**`aScratchTeamOfFakesBuildsAuditsAndMerges` (`FakeClaude` as every session) passes, in 53 s, and 3 of 3 under load
24**: the config and base accepted (each code typed); `lead` started; its `ask_user` listed by `questions` and answered
(in the vault, then typed into the lead as the user's); two tasks touching `src/` and a worker on each, both live at once
under `mac_max_sessions` 4; the test's commit in each worktree, on `agent/<slug>`; a merge before the audit refused for
"no passing audit"; the verifier's `submit_audit` through its own tool server, the verdict in the vault on the worker's
commit; the merge held for the user's approval, the lead's approval card answered with `LeadWorkflow.approval(of:)`
(the vault holds it for that task and commit only); the merge landed on `main` with `VS-Task` and `check.sh` run in the
merge's worktree. Every command line call named "scratch node at <root>" on stderr, and each state change showed its
code prompt. Three mutants of the product fail it, each on its own assertion: the gate merging with no verdict, the
vault recording the approval under another commit, and `approved` ignoring the task and commit.

**`aScratchTeamPlansBuildsAuditsAndMerges` (gated on `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`, a real lead on Sonnet,
the verifier on haiku) had not run on 2026-11-16** (the test account at its weekly limit, E9's Step 2 not passed).
**It passed on 2026-11-17, on its first run** (one of the three allowed):
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=~/.vibeswitcher-test-claude bash scripts/test.sh --filter
ScratchRunTests/aScratchTeamPlansBuildsAuditsAndMerges`, 18:46, Claude Code **2.1.326** (`~/.local/bin/claude`), the
test passing in 75.2 s. Its `S10:` lines, the time from the run's start:

| At | What the run was at |
| --- | --- |
| 0.4 s, 0.6 s | 1, the config and the base accepted (each code typed); 2, the lead started |
| 4.9 s | the lead's question listed ("Which greeting word should src/greeting.txt hold?") and answered with its first option, Hello |
| 9.1 s, 11.2 s | `add-the-greeting` planned, then `add-the-farewell` (the slugs of the goal's titles, whose worktrees the case trusted beforehand) |
| 13.2 s, 15.3 s | the greeting's worker live, then the farewell's: both at once beside the lead |
| 21.6 s, 25.8 s | a worker's commit touching `src/` on `agent/add-the-greeting`, then on `agent/add-the-farewell` |
| 36.3 s | both tasks in review (each worker reported done) |
| 44.7 s | the greeting's verifier live |
| 55.2 s | the vault holds a passing verdict at `cda96ecb` |
| 67.9 s | the lead's approval card listed, and answered with exactly `Approve cda96ecb…` (the verdict's commit), the code typed |
| 74.3 s | 3, `add-the-greeting` done: merged on `main`; 4, checked |

- **Checked:** two `agent/*` branches each with a worker's commit; the verdict passing; the user's approval recorded
  for the greeting at the verdict's commit, and the landed commit's `VS-Review` naming it; exactly one commit on
  `main` with a `VS-Task` trailer (the greeting's); `check.sh` run in the merge's worktree (its marker); the question's
  `answer` action and its message's digest in the vault; every command line call in scratch form.
- **Models, from each role's own transcript in the config folder:** both workers on `claude-sonnet-5-5`, the verifier
  on `claude-haiku-5-5`; the landed commit's `VS-Verifier-Model` says haiku and its `VS-Worker-Model` "unknown" (the
  node's receipts read its scratch home, not the config folder, as the case's review noted).
- **The cost seen** (each session's own `cost-state` in its transcript, what Claude Code counts at list prices; the
  account is a subscription): the lead $0.20, the greeting's worker $0.20, the farewell's $0.15, the verifier $0.007:
  $0.56 in all. The lead's status line read "weekly 29%" just before the run (E9's last).
- **Nothing failed, in the product or in the harness.** No file of the config folder was left changed (no hook, no
  trust entry), and no process of the run was left.
- **What the harness gained before the run** (from E9's Step 2, and for a run that stops): each change of the board's
  tasks, the live sessions, the branches with a worker's commit and the vault's verdict is printed with its time (the
  table above); the run stops early, printing every session's screen, the board, the open cards and the node's log,
  when a session's screen shows the account's usage limit or nothing at all has moved for 12 minutes (the board, git's
  branches, the cards, each session's hooks' last event), instead of waiting out its 55 minutes; the greeting's task is
  found by its slug or, failing that, its title; the workers' commits are noted as the run goes (a `cleanup` would take
  a merged task's branch away), the second worker's waited for. The answers go as E9's Step 2 showed: one given while
  the lead's turn runs reaches it through its own hook, one given to an idle lead is typed in; the case takes either.

**The rehearsal on a machine with one test and build slot (2026-11-17).** The `v2 linux` run on `200e2c32` (its core
job, a 4-core runner) failed `aScratchTeamOfFakesBuildsAuditsAndMerges` after 386 s: the fake lead's `merge` call
answered "TimeoutError: no reply to request 2", so nothing had landed (no `VS-Task` trailer, no `src/parser.txt` on
`main`). The timeout that fired is the test's own (the fake's MCP client, 300 s for that call); the merge wasn't slow,
it was waiting. Its tests run under a slot of the account's test and build lock (`/tmp/vibeswitcher-<uid>`, `TestLock`);
`scripts/test.sh` runs the whole suite under `vs-heavy`, holding one; a machine under 12 cores has one slot
(`MacLimits.defaultHeavySlots`, the cores ÷ 6); and the scratch node's lead has none of the suite's environment
(`VIBESWITCHER_TEST_LOCK`, by which `vs-heavy` knows it runs under its own holder). So the merge queued behind the
suite that started it, until its call gave up. Here (24 cores, 4 slots) it took the next slot, and passed. Reproduced
with one slot forced (`VIBESWITCHER_HEAVY_SLOTS=1` on the run and `heavy_slots: 1` in the scratch workflow): the same
three issues, and while the merge waited the account's lock folder held its ticket ("VibeSwitcher's merge test of
c92b15b8 in …/vsn-CC48ED34/repo … slots 1") behind slot 1's holder, "scripts/test.sh in …/step8".
**Fixed in the engine:** a scratch node's lead gets `VIBESWITCHER_TEST_LOCK_DIR=<root>/tmp` (`LeadEngine.environment`),
where its sessions' temporary folders are, as the user's node keeps both in `vibeswitcher-<uid>`, and as the bootstrap
path's step 9 says of a scratch host ("its own `VIBESWITCHER_HOME` and lock"): its merges and audits neither wait on
the account's slots nor show among them. With it the forced-single-slot run passes in 53 s.
`LeadStartTests.theLeadsTestAndBuildSlotsAreUnderTheScratchRoot` and the rehearsal's check of the node's own slot file
(`<root>/tmp/test-build.lock`) each fail without it. Left as it is: a scratch node's workers get the host's session
variables only, so a `vs-heavy` a real worker runs there still takes the account's slots, and the server's witness
reads the workers' waits from the account's lock.

## The config seal's Linux list (the start plan's S7, 2026-11-16, Linux 5.15.167.4-microsoft-standard-WSL2)

**Step 0, the startup files' targets** (read by the agent, read only). Each `.` and `source` in `~/.bashrc`,
`~/.profile`, `~/.bash_profile` and `~/.bash_login` (the last two absent here; all four are watched whether they
exist or not, `ConfigSeal.homeFiles`):

| File, line | Target | Watched by |
| --- | --- | --- |
| `.bashrc` 105 | `~/.bash_aliases` (absent here) | `LinuxSealList.homeEntries`, and `sourced` |
| `.bashrc` 113, 115 | `/usr/share/bash-completion/bash_completion`, `/etc/bash_completion` | left out: root-owned |
| `.bashrc` 120, 121 | `$NVM_DIR/nvm.sh`, `$NVM_DIR/bash_completion` (`NVM_DIR="$HOME/.nvm"`, line 119) | `homeEntries` (`.nvm/nvm.sh`, `.nvm/bash_completion`); `sourced` doesn't expand `$NVM_DIR` |
| `.bashrc` 124 | `~/projects/rally/.rally-aliases` | `homeEntries`, and `sourced` |
| `.profile` 15 | `"$HOME/.bashrc"` | `ConfigSeal.homeFiles` |
| `.profile` 33 | `'/home/<user>/.local/share/swiftly/env.sh'` (by the home's own path) | `homeEntries`, and `sourced` (it takes the home's own path too) |

**One look at the real home's list**, timed: `VIBESWITCHER_SEAL_TIMING_HOME=$(getent passwd $(id -un) | cut -d: -f6)
bash scripts/test.sh --filter LinuxSealListTests/aLookOfTheLinuxListIsTimed`, read only, leaving out every entry under
`~/.claude` and `~/.vibeswitcher`: **33 entries hashed in 0.48 s**. They were the 6 files of `homeEntries`, `~/bin`, the 7
systemd and autostart folders and `user.conf`, `~/.codex/shell-snapshots`, the 5 listings (`~/.config/gh`,
`~/.local/bin`, `~/.local/share/claude/versions`, swiftly's `toolchains` and `bin`), node's
`~/.nvm/versions/node/v22.16.0` (no unit yet: each `v*`), the 2 `/run/user/1000/systemd` folders, and
`/mnt/c` mounted (9p), each of 5 Windows users' `.wslconfig` and Startup folder (`CodexSandboxOffline`, `WsiAccount`,
`kstel`, `monts`, `postgres`; `Default User` is a junction, so left out, as are `Public`, `Default` and `All Users`). The
look reads metadata only for the listings: the swiftly toolchain and node's folder are the large ones.
*2026-11-16, S7's review:* the gated test now also leaves out the `/run/user/<uid>/systemd` folders (the plan's Global
Constraints: never the user's `$XDG_RUNTIME_DIR`); the run above read the 2 that were listed then, and the list now has
a third (`user`). Node's folder is now one listing of all of `~/.nvm/versions/node` (here the same single `v22.16.0`,
so the same entries) and `~/.nvm/alias` is a second. The look wasn't run again: the plan allows the agent one run.

**The measurement (ST-D19)**, `EngineEndToEndTests.aWorkersStartDoesNotHoldItsTeam` on a scratch node with the fakes:
on plain folders the first `start_worker` was refused for `~/.claude/shell-snapshots`, `~/.vibeswitcher/lead/run`
and `~/.vibeswitcher/lead/git-hooks` (GitGuard's baseline at the first guarded git, then the lead's tool server setting
`told` in `accepted.json`). On `.entries` for all four (and `told` left out of the hooks record's per-path hash) it
passes: two workers start, and `config held` holds nothing after either. The real Claude Code's snapshot is checked
once, at M8's first lead (S9's "Prepared for M8").
*2026-11-16, S7's review:* the scratch repository has a hook of the user's (`pre-commit`), and after the two starts a
second repository's first guarded git writes a new store with a shim: `config held` still holds nothing (the guard's
baseline of a repository the seal hasn't seen comes as entries added; anything else added under `git-hooks` is held).

**The manager's runtime units (ST-D20), 2026-11-17** (read only, `ls` and `stat` of the folder, from the step 8 sweep):
`/run/user/1000/systemd/transient` held `app-com.google.Chrome-3924612.scope` (92 bytes: only the header "This is a
transient unit file, created programmatically via the systemd API"), its mtime and the folder's 11:47:32, the start of
that Chrome. The manager writes such a file each time an app registers a scope of its own, and removes it when the
scope goes, so on a `.folder` each browser start and exit held every team. The folder is now `.entries`: a top-level
`*.scope` regular file comes and goes as no change (`LinuxSealList.transientEntryMayCome`);
a service, a timer, a drop-in folder, a link, a hidden or deeper file, or a scope's file changed in place still holds.
What the sweep's review found not held, and the security follow-ups closed (items 31 and 32, 2026-11-17): a new scope's
file comes only in the form systemd writes for a scope made through its API (the header, then `[Unit]` and `[Scope]`
keys it writes for one, no dependency or trigger: `LinuxSealList.hasScopeForm`, judged on the bytes the seal hashed),
and a scope gone leaves a tombstone of its last hash for 64 recorded looks, so one back changed under its name holds.
The form, read only on 2026-11-17: `/run/systemd/transient/session-2.scope` (the system manager's, logind's session
scope) is the header, then `[Scope]` `Slice=`, `[Unit]` `Description=`, `Wants=`, `After=`, `RequiresMountsFor=`, then
`[Scope]` `SendSIGHUP=`, `OOMPolicy=`, `TasksMax=` (logind's dependencies, which an app's scope in the user's folder
doesn't carry and which hold there); the user manager's folder wasn't there at the follow-ups' read. `/run` is emptied
at reboot.

## The install's static build (the start plan's S4c, 2026-11-16, Linux 5.15.167.4-microsoft-standard-WSL2)

The spike ran the install's build command (ST-D11) by hand, under `vs-heavy` (6 cores), with swiftly's 6.4.2 (the same
release as M3's root toolchain, which isn't installed yet) in place of `/opt/swift-6.4.2`, on a `git clone --no-local`
of commit 5d774d7f, with every SwiftPM folder and `HOME` in a scratch folder and only `HOME`, `PATH` and `TMPDIR` in
the build's environment. glibc 2.39 (Ubuntu 24.04).

- **ST-D11's flags as written fail.** With `-Xswiftc -no-toolchain-stdlib-rpath`, the flag reaches the package's
  build-tool plugins too: SwiftTerm's `SwiftTermBuildInfoGenerator-tool` is linked against the toolchain's Swift
  runtime dynamically (its `NEEDED` names `libswiftCore.so`, `libFoundation.so` and the rest) with no `RUNPATH`, so at
  step 139 of 406 it stops: "error while loading shared libraries: libswiftCore.so: cannot open shared object file".
  Without that flag the build completes, and the products still carry no `RUNPATH`: the driver adds the toolchain's
  library folder only when it links the Swift runtime dynamically. `scripts/install-node.sh` drops the flag; its link
  check still refuses any `RUNPATH`.
- **The build:** 236 s of wall time for the second run, which kept the first run's 138 finished steps (C and assembly
  of the dependencies); a run from nothing takes longer. SwiftPM fetches the resolved dependencies from their own
  origins (GitHub) into the scratch cache.
- **The products** (unstripped):

  | Product | Size (bytes) |
  | --- | --- |
  | `vibeswitcher-host` | 136,231,856 |
  | `vibeswitcher-server` | 136,796,656 |
  | `vibeswitcher-cli` | 137,552,600 |
  | `vibeswitcher-hook` | 128,939,768 |
  | `vibeswitcher-mcp` | 129,128,632 |

- **`readelf -l` and `readelf -d`, each of the five alike:** interpreter `/lib64/ld-linux-x86-64.so.2`; `NEEDED`
  exactly `libm.so.6`, `libstdc++.so.6`, `libgcc_s.so.1`, `libc.so.6` and `ld-linux-x86-64.so.2` (ST-D12's set,
  confirmed: libdl and libpthread are inside libc since glibc 2.34); no `RPATH`, `RUNPATH`, `AUDIT` or `DEPAUDIT`. The
  loader's `--list` resolves them to `/lib/x86_64-linux-gnu/` (`/lib` a link to `/usr/lib`), every folder root's.
- **The maps** (`InstallTests.anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite`, on the products installed into
  a scratch prefix): the installed host (held dumpable) maps its own installed file,
  `/usr/lib/x86_64-linux-gnu/{ld-linux-x86-64.so.2, libc.so.6, libgcc_s.so.1, libm.so.6, libstdc++.so.6.0.33}`,
  `[heap]` and anonymous mappings. Its sealed copies are descriptors, not mappings. A held session launcher maps
  `/memfd:vibeswitcher-launcher (deleted)`, the same five libraries, `[heap]`, `[stack]`, `[vdso]`, `[vvar]` and
  anonymous mappings. `vibeswitcher-mcp`, in its poll of stdin, maps its own installed file, the same libraries and
  `[heap]`. The server's maps: `open` fails with `EACCES` (non-dumpable), as ST-D12 expected.
- The products are kept in `~/.cache/vibeswitcher-static-products/5d774d7f54bffc21f3538fcc35c4cf01d3e86a2a/` (with
  `swift-version` and the commit's `Package.resolved`), outside every watched folder, for
  `VIBESWITCHER_STATIC_PRODUCTS=<that folder> vs-heavy bash scripts/test.sh --filter InstallTests`.
- **Not yet measured:** the gated build with the root toolchain (`InstallTests.anInstallBuildsWithTheRootToolchain`),
  waiting on M3. Its sizes, time and link-check output go here when it has run.

## The session sandbox, measured (the session sandbox plan's SB0, 2026-11-17, Linux 5.15.167.4-microsoft-standard-WSL2)

Ubuntu 24.04.1 under WSL2, glibc 2.39, util-linux 2.39.3, uid 1000. The first table is the plan's, measured read-only
before SB0 (docs/superpowers/plans/2026-11-17-v2-session-sandbox.md, "Measured on this machine"); the rest is SB0's,
in the prototype box `Tests/Fixtures/sandbox/prototype.sh` (unshare(1) over scratch folders; nothing in the product
runs it). Rows that a test can hold are held by `SandboxPrototypeTests` and SB1's `SandboxFactsTests`,
`SandboxShimTests` and `SandboxSeccompTests`.

| What | Command or call | Output | What follows |
| --- | --- | --- | --- |
| User namespaces | `unshare -U true`; `unshare -Ur id` | exit 0; `uid=0(root) gid=0(root) groups=0(root),65534(nogroup)` | Works without root |
| Debian's knob | `/proc/sys/kernel/unprivileged_userns_clone` | No such file or directory | Nothing here to turn them off with |
| Limits | `/proc/sys/user/max_user_namespaces` (and `max_mnt_`, `max_pid_`, `max_net_`, `max_cgroup_namespaces`) | 384738 each | No practical limit |
| AppArmor's restriction | `/proc/sys/kernel/apparmor_restrict_unprivileged_userns`; `aa-status` | No such file or directory; `apparmor not present.` (`# CONFIG_SECURITY_APPARMOR is not set`, `# CONFIG_SECURITYFS is not set`: there is no `/sys/kernel/security`) | No profile is needed here. Ubuntu 24.04 on bare metal, and GitHub's hosted runner, refuse them (SB-D15, SB-D18) |
| bubblewrap | `bwrap --version` | `bwrap: command not found` | Not used (SB-D1) |
| Landlock | `/sys/kernel/security/landlock`; `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` | the path doesn't exist (no securityfs); the call returns `1` (`CONFIG_SECURITY_LANDLOCK=y`, first in `CONFIG_LSM`) | Landlock is on, at ABI 1 |
| Landlock ABI 1 and renames | a process restricted with every ABI-1 right allowed under a scratch folder, and another with every right allowed under `/` | rename within one directory: ok; rename across two allowed directories: `EXDEV`; hard link across them: `EXDEV`; read `~/.profile` outside the rule: `EACCES`; read the parent's `/proc/PID/environ`: `EACCES` | Under ABI 1 any restricted process loses renames and links between folders (ABI 2, kernel 5.19, adds `REFER`). Package managers and builds rename between folders, so **Landlock is not the file lock on this kernel** (SB-D1). It does scope ptrace |
| seccomp | `/proc/sys/kernel/seccomp/actions_avail`; `/proc/1/status` | `kill_process kill_thread trap errno user_notif trace log allow`; `Seccomp: 2`, `Seccomp_filters: 1` on pid 1 and on every process | Filters work, and WSL already puts one on everything: ours stacks on it |
| Yama | `/proc/sys/kernel/yama/ptrace_scope`; `prctl(PR_SET_PTRACER)` | No such file or directory (`# CONFIG_SECURITY_YAMA is not set`); `EINVAL` | No ptrace scope: only a pid namespace keeps one session out of another |
| pidfds | `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd` of a child of the same uid, `waitid(P_PIDFD)` | an fd; 0; an fd; ok | All there. `pidfd_getfd` of a dumpable process of the user works, which is S11 item 6's route |
| Peer pidfds | `getsockopt(SO_PEERPIDFD)`, `setsockopt(SO_PASSPIDFD)` | `ENOPROTOOPT` both (kernel 6.5) | 5.15 lacks them, and `PIDFD_THREAD` (6.9: `EINVAL`). A peer is a pid number here; this plan's identity needs no pid (SB-D4) |
| Other calls | `clone3`, `close_range`, `openat2`, `mount_setattr`, `memfd_secret` | present; present; present; present; `ENOSYS` | Enough for the shim; idmapped mounts need root, and aren't needed |
| cgroups | `/proc/self/cgroup`; `/sys/fs/cgroup/unified/cgroup.controllers`; `systemctl show user@1000.service -p Delegate,DelegateControllers`; `ls -ld` of the v1 `pids` and `memory` folders of `user@1000.service` | `0::/init.scope` from a terminal; empty; `Delegate=yes`, `DelegateControllers=cpu memory pids`; both `root root` | Hybrid: the user owns its subtree in the v2 tree (`cgroup.procs`, `cgroup.kill`, `cgroup.freeze`), which has no controller, and the v1 controllers are root's. **No pids or memory limit can be set for a box here** (SB-D13). From a terminal there is no delegated cgroup at all |
| overlayfs in a user namespace | `mount -t overlay overlay -o lowerdir=…,upperdir=…,workdir=…` as mapped root | mounted; the lower file read through it | `private` mounts work (`CONFIG_OVERLAY_FS=y`) |
| The other mounts | tmpfs; `mount --rbind /usr` then `remount,bind,ro`; `proc`; `devpts -o newinstance`; `pivot_root`; `umount -l` of the old root | each ok; `touch /usr/x`: `Read-only file system` | The whole shape can be built without root |
| A whole box, with `unshare(1)` | user, mount, pid, net, ipc, uts and cgroup namespaces, a tmpfs root, `/usr` and `/etc` read-only, a scratch worktree read-write, then a second user namespace mapping uid 1000 and `setpriv --no-new-privs` | `id: 1000:1000  caps: 0000000000000000  NoNewPrivs: 1`; 4 processes visible, pid 1 the shell; `~/.ssh`, `~/.config`, `~/.vibeswitcher`, `~/.claude`, `~/projects`, `/run/user/1000/bus`, `/run/user/1000/systemd/private`, `/run/systemd/journal/socket`, `/run/WSL`, `/init`, `/mnt/c`, `/tmp/.X11-unix`, the docker socket and `/sys/fs/cgroup` all absent; the worktree writable; `net links: lo`; `curl https://1.1.1.1`: `000`; a service on the host's loopback: refused; `systemctl --user`: `offline`; `kill -0` of a process outside: `No such process`; a new pty inside: `/dev/pts/0`; `unshare -Ur true` inside: allowed | The file, process and network halves of S12 item 1 hold as built by hand. Nested user namespaces work, which SB6 and the project's own tests need (SB-D10) |
| Lifting a cover from a nested namespace | a tmpfs mounted over a folder with a file in it; then, in a second user and mount namespace made inside the first, `umount` and `umount -l` of that tmpfs | `not mounted` both times (how `umount` words the kernel's `EINVAL` for a locked mount); the folder still empty | A mount the box inherited can't be taken off from a namespace nested in it: what the plan covers stays covered (SB-D10) |
| WSL interop | `cat /proc/sys/fs/binfmt_misc/WSLInterop*`; `ls -la /run/WSL /init` | two entries, both `interpreter /init`, `magic 4d5a`, flags `PF` and `P`; the sockets `srwxrwxrwx`; `/init` `-rwxrwxrwx root` | Interop is on today (M5 isn't done yet) |
| A Windows program from inside | a copy of `cmd.exe` run outside any namespace; inside a box (no `/init`, no `/run/WSL`); with only `/run/WSL` covered | it runs; `failed to run command './cmd.exe': No such file or directory`; `/init` starts, finds no socket and fails (`UtilGetPpid … Failed to parse: /proc/1/stat`) | A box with neither path runs no Windows program. Here the missing `/init` was enough, because the entry tried first names it by path. The other entry holds the interpreter open (flag `F`), so where that one is tried only the missing `/run/WSL` stops it: the box hides both, and the attack checks both |
| Hyper-V sockets | `socket(AF_VSOCK, SOCK_STREAM)` in the host's network namespace, and inside a new one | `ok` both (`CONFIG_HYPERV_VSOCKETS=y`) | **A network namespace doesn't cover `AF_VSOCK`**: a box could still talk to the Windows side over a Hyper-V socket. The filter refuses the family (SB1). New for S11 |
| Other families | `AF_PACKET`, raw `AF_INET`; `AF_ALG`, `NETLINK_NETFILTER` | `EPERM`; `ok` | The filter leaves `AF_UNIX`, `AF_INET`, `AF_INET6` and route netlink only |
| nftables | `nft list tables` as the user; `nft add table …` in an own user and network namespace | `Operation not permitted (you must be root)`; a ruleset listed | A rule for the uid in the host's network needs root, so egress isn't filtered that way. Inside a namespace of its own any process can load netfilter rules: kernel surface the filter cuts |
| slirp4netns, pasta | `command -v` | missing both (`/dev/net/tun` is `crw-rw-rw-`, and a tap device can be made in an own namespace, so either would work if installed) | Not needed (below) |
| Egress with nothing installed | a TCP listener bound to `127.0.0.1:3128` inside a new network namespace, its descriptor passed out with `SCM_RIGHTS`, accepted by a process outside that answers `CONNECT` | outside: `bound to ('127.0.0.1', 3128)` while its own namespace has 9 links; inside: `links = lo`; `curl -x http://127.0.0.1:3128 https://example.com/`: `200`; with no proxy: `Could not resolve host` | **A socket belongs to the namespace it was made in, whoever holds it.** The proxy needs no tap device and no relay (SB-D7) |
| Unix sockets across namespaces | a path socket bound outside, connected from inside a user, net and pid namespace; an abstract one | connected; `SO_PEERCRED` gives the connector's pid as the listener numbers it, whose `/proc/<pid>/ns/pid` differs from the listener's; the abstract one: `Connection refused` | A path socket is reachable exactly when it is in the mount view: hiding is the lock. Abstract sockets stay behind with the network namespace |
| A terminal made outside | the slave of a pty as stdin of a process whose `/dev/pts` is a devpts of its own | `isatty(0)`: True; `ttyname(0)`: `ENODEV` (`tty` says `not a tty`); `/proc/self/fd/0`: `/dev/pts/5`; `/dev/tty` opens; `getsid(0)`: 0; a new pty inside: `/dev/pts/0`; `tty_nr`: `136:5`; an interactive bash turns job control on | The session keeps its host terminal number (`ttypts5`), so every tty-keyed record still matches. Programs that ask the terminal's name get none: SB0 measures Claude Code |
| Writing the uid map | a non-dumpable process after `unshare(CLONE_NEWUSER)`; a dumpable one, made non-dumpable after | `EACCES`; written | The launcher runs from an unreadable copy, so it must be dumpable while it writes its maps, which it already is before its exec (`HostImages.beforeProgram`). Init hardens again afterwards |
| Claude Code 2.1.326 | the loader's `--list` of the binary; `stat` of `~/.claude.json` five minutes apart; the files beside it | `librt`, `libc`, `libpthread`, `libdl`, `libm` from `/lib/x86_64-linux-gnu`; inode 1789508, then 771029; seven `~/.claude.json.tmp.<pid>.<ms>` files; `.credentials.json` unchanged | The agent needs `/usr` and its own file. It replaces `~/.claude.json` by a temporary file and a rename beside it, so that file can't be a single bound file: the home inside is a folder of the session's own |
| Around it | `kernel.unprivileged_bpf_disabled`; `perf_event_paranoid`; `vm.unprivileged_userfaultfd`; `/proc` | 2; 2; 0; no `hidepid` | The filter refuses `bpf`, `perf_event_open` and `userfaultfd` anyway |
| This network | `/etc/resolv.conf`; `ip -o addr`; `ss -ltn` | the tailnet's resolver (`100.100.100.100`); a `tailscale0` link beside the LAN's; three listeners on loopback | What the proxy must refuse is really here |

### SB0's prototype, ungated

The prototype builds the worker's box of the plan's tables: a tmpfs root, `/usr`, `/etc` and `/opt` read-only (every
mount under them too), `/bin`, `/lib`, `/lib64`, `/sbin` as links, its own `/proc`, `/dev` (six nodes, a devpts of its
own, `shm`), `/tmp` and `/var/tmp`, the scratch home and worktree read-write, the user's uid mapped to itself, no
capability in any set, `no_new_privs`. It refuses a `HOME` that is or holds the account's home
(`SandboxPrototypeTests.thePrototypeRefusesTheAccountsHome`), and its box shows a program the user with no capability
and nothing else of the home (`aProgramInThePrototypeIsTheUserWithNoCapabilityAndSeesOnlyItsBox`).

| What | Command | Output | What follows |
| --- | --- | --- | --- |
| A recursive bind of `/usr` | `mount --rbind /usr R/usr`, then `mount -o remount,bind,ro` of the top | `R/usr` `ro`; below it `/usr/lib/wsl/drivers` `ro,noatime` (9p), `/usr/lib/wsl/lib` **`rw`**,`noatime` and `/usr/lib/modules/5.15.167.4-microsoft-standard-WSL2` **`rw`** (both overlays WSL mounts) | A read-only bind must make every mount under it read-only (the shim: `mount_setattr` with `AT_RECURSIVE`), keeping each one's atime flag, which the kernel locks. A non-recursive bind of `/usr` is refused in a user namespace (`EINVAL`: it would uncover what the locked mounts under it hide). util-linux's `-o ro=recursive` left the lower ones `rw` here |
| `swift build` and `swift test` of a package with no dependency | inside, swiftly's folder read-only on PATH, `~/.swiftpm` private | `Build complete!`, `1 test passed`; it wrote `~/.cache/org.swift.swiftpm/manifests/manifest.db`, `~/.cache/org.swift.foundation.URLCache`, `~/.cache/clang/ModuleCache` in the box's home | A build needs its home's `.cache` writable: `own` (or `private`) |
| Dependencies with no network | a package naming `swift-crypto` 3.15.1, `--net none`, `HOME` the real path with `~/.swiftpm` and `~/.cache` private | `swift package resolve`: "Computed … at 1.7.4", working copies of swift-crypto and swift-asn1, status 0 | Private caches spare the network for what is already cached |
| git with the common folder read-only | a scratch repository; `.git` `ro`, with `objects/`, `worktrees/w1/`, `refs/heads/agent/`, `logs/refs/heads/agent/` `rw` (`LeadLaunch.codexWritableRoots`'s list); `gc.auto=0` | `commit`, `status`, `log`: ok; `rebase main`: "Successfully rebased", after "error: Unable to create '…/.git/packed-refs.lock': Read-only file system"; `branch -f main`: refused (`main` is checked out elsewhere); `tag`: `refs/tags/t1.lock` read-only; `config x.y`: "could not lock config file"; writing `hooks/pre-commit`: read-only; `update-ref refs/heads/agent/other`: ok | The worker's own work runs. **Deleting any ref** (a rebase's, `git branch -d agent/x`) needs `packed-refs.lock` and fails with the common folder read-only: a worker can't delete its branches (the lead's tools do it outside). Another `agent/` ref stays writable (SB-D5's cost) |
| `vs-heavy` with the slots' folder | the slots' folder (a scratch one: `VIBESWITCHER_TEST_LOCK_DIR`) bound `rw`; `vs-heavy --as inside-box` holds slot 1; outside, `vs-heavy --as outside true` with one slot | inside: `test-build.lock.holder` reads "pid 63, inside-box in …"; outside waited until killed by `timeout 5` (status 143) | A flock taken inside holds outside: the slots are shared. The holder note names the box's own pid (SB-D14's cost) |
| `/sys` | `--sys` with the host's network; with `--net none` | "the box couldn't be built: /sys" (sysfs refused: the network namespace isn't the box's); with its own: `block bus class dev devices firmware fs kernel module`, `class/net` holds `lo` alone, `fs/cgroup` empty, writes `Read-only file system` | `/sys` only in a box with a network of its own. The plan's tables give none for slice 1's worker |
| `RLIMIT_NPROC` before the user namespace | `--nproc` at the user's task count + 60 (378, with 318 tasks of uid 1000 outside); inside and outside, children forked until refused | inside: refused after 20 children; outside, the same limit: after 22 | The limit counts every task of the uid, outside the box included (kernel 5.14's counts are checked at every level up to the first namespace): **no per-box process limit** this way (SB-D13 stands) |

### A real Claude Code turn in the prototype (gated, `RealClaudeSandboxTests.aRealClaudeTurnRunsInThePrototype`)

Run twice with the user's go-ahead, on Sonnet, with the test login (`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` naming
`~/.vibeswitcher-test-claude`); the first run's wait ended early (the prompt's own text, echoed, matched), the second
waited for the Stop hook. Claude Code 2.1.326, the versioned binary read-only. The box's config folder was a scratch
`HOME/.claude` (`CLAUDE_CONFIG_DIR`), its `.claude.json` seeded from the test folder's (every key but `projects` and
`mcpServers`, then the worktree's trust entry); the test folder's `settings.json`, `plugins/`, `skills/` and
`.credentials.json` bound into it read-only (nothing read or copied them: the kernel bound them). Hooks given with
`--settings`, each appending its event to a file of the box's home: a stand-in for the door. `HTTPS_PROXY` and the
other three named a logging stand-in proxy (`Tests/Fixtures/sandbox/logging-proxy.py`). `DISABLE_AUTOUPDATER=1`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `--allowedTools "Bash(touch made-in-the-box)"`.

- **The turn ran:** `made-in-the-box` in the worktree; the answer drawn; hook events `SessionStart UserPromptSubmit
  PreToolUse PostToolUse Stop`, in that order.
- **What it wrote in its config folder** (all in the box's own): `.claude.json` (by a temporary file and a rename
  beside it: six times in one turn), `backups/`, `debug/` (`--debug`), `history.jsonl`, `mcp-needs-auth-cache.json`,
  `projects/` (the transcript), `session-env/`, `sessions/`, `shell-snapshots/`; it watched `jobs/<id>` (absent). It
  wrote nothing to a read-only entry and no write was refused (no `EROFS`, `EACCES` or `EPERM` in its debug log).
- **In the home beside it:** `.cache/`, `.config/`, `.local/`; among them it registers a URL handler at
  `~/.local/share/applications/claude-code-url-handler.desktop` at every start (in the box's own home: thrown away; for
  an unconfined session it is a file the agent writes into the desktop's folder), and its install check says
  "claude command at ~/.local/bin/claude missing or broken" (cosmetic).
- **The given folder:** no entry changed or appeared (inode, change time and size of each, before and after; a second
  listing by hand agreed). `.credentials.json` unchanged. **No login refresh** was asked in either turn (the token
  was valid): whether a long session rewrites the login stays unmeasured; with the file bound read-only such a write
  would fail with `EROFS` (SB-D8).
- **Hosts asked of the proxy**, all as `CONNECT`: `api.anthropic.com:443` (twice) and `mcp-proxy.anthropic.com:443`
  (eight times: the account's claude.ai connectors, which Claude Code loads from the account, not from `.claude.json`,
  even with non-essential traffic off; those not authorized answered `mcp_unauthorized_no_token`). No telemetry,
  update or other host. Claude Code honours `HTTPS_PROXY`: nothing went around it.
- **A terminal with no name:** the TUI drew, took typed text into its prompt, and ended on Ctrl-C twice, on a pty made
  outside whose name doesn't resolve inside (`ttyname`: `ENODEV`).
- **Trust:** the seeded trust entry spared the trust question (none shown).
- **Not shown inside:** `/mnt/c/Users` (its "WSL IDE lockfile path detection" fails `ENOENT`: harmless).

What follows, for SB2 (`ClaudeFiles`) and SB-D7's list: the own entries are the ones above; the read-only list
stands; the default hosts are `api.anthropic.com`, and `mcp-proxy.anthropic.com` only if the account's connectors are
wanted in a box (the user's call with SB-D7 and SB-D9).

### A worker's git with only its own ref and objects writable (the security review, 2026-11-18)

In the prototype, a worktree on branch `agent/w1/head`; `.git` read-only, with `worktrees/w1/`, `refs/heads/agent/w1/`
and `logs/refs/heads/agent/w1/` read-write; `GIT_OBJECT_DIRECTORY` a session folder of its own and
`GIT_ALTERNATE_OBJECT_DIRECTORIES` the shared `objects`. `commit`: ok; `rebase main`: ok (after the same
`packed-refs.lock` error as above); `update-ref refs/heads/agent/w2/head`: "cannot lock ref … Read-only file system";
`branch agent/x`: the same; `update-ref refs/heads/agent/w1/other`: ok. Outside, the session folder held 5 objects;
`git log agent/w1/head` in the main checkout: "fatal: bad object", and with the session folder as an alternate, the
three commits. A single ref file can't be the writable part: git takes `<ref>.lock` beside it and renames it over.

### The third gated run (2026-11-18): the allow-listed `.claude.json`, and a revoked login

The same test, its box's `.claude.json` now `ClaudeFiles.seededConfig`'s allow-list (with the login). No trust
question, no onboarding screen; the TUI drew and took typed text. The turn didn't run: "API error · retrying … OAuth
token revoked · Please run /login". Hosts asked: `platform.claude.com:443` (twice: where Claude Code takes a new
token, which it now asks for) and `api.anthropic.com:443`. `.credentials.json` unchanged (bound read-only; with the
login revoked there was nothing to write). The test login needs logging in again (the user's; an agent never logs
in), and until then the allow-list is unproven against a real turn. `platform.claude.com` joins SB-D7's list of what
Claude Code asks for.

## A hook through the session sandbox's door (the session sandbox plan's SB4, 2026-11-17, Linux 5.15.167.4-microsoft-standard-WSL2)

`DoorTests.aHookThroughTheDoorAnswersWithinItsThreeSeconds`: one `UserPromptSubmit` event, the built hook as the relay
inside (a door stand-in for init, a scratch path for the door), the built tool server as the porter outside starting
the built hook from a sealed copy, measured by the agent stand-in's shell around the hook's command. Through the door:
0.021 s; the same hook run plain on the same folders: 0.015 s. The door adds about 5 ms (two socket crossings, one
`posix_spawn` from a sealed copy), against the hook's 3 s.
