# Development

How to build, test and check changes to VibeSwitcher. The rules for agents working in this repository are in
[AGENTS.md](../../AGENTS.md); this guide explains the tools behind them.

## Layout

- `Sources/VibeCore`: the testable logic (status rules, hook reducer, process table, installer, the lead's board,
  tools and workflow).
- `Sources/VibeSwitcher`: the AppKit and SwiftUI app.
- `Sources/VibeHost`, `Sources/vibeswitcher-host`: the session host.
- `Sources/vibeswitcher-hook`: the hook binary.
- `Sources/vibeswitcher-mcp`: the project lead's tool server.
- `Sources/VibeNode`, `Sources/vibeswitcher-server`, `Sources/vibeswitcher-cli` (version 2): the node's engine, its
  server (the session host's server child, on `<root>/v2/server.sock`) and the command line, `vibeswitcher`, which
  goes through the server (`status --probe` reads this machine without it). Their tests start a scratch node as
  processes (`Tests/VibeNodeTests/ScratchNode.swift`), never the user's.
- `Web/`: the phone's web app. `Resources/`: Info.plist, entitlements, the app icon, `bin/vs-heavy`.
- `Tests/`: `VibeCoreTests`, `VibeHostTests`, `VibeSwitcherTests`, and the web tests in `Tests/Web`.

See [Architecture](architecture.md) for how the pieces fit.

## A new worktree

```sh
bash scripts/worktree-init.sh
```

In a worktree the lead made (`.vibeswitcher/worktrees/<task>`), this points SourceKit-LSP at the module cache shared
by every worktree (`.vibeswitcher/module-cache` in the main checkout), so each worktree doesn't build its own 300 MB
copy of the SDK's modules. `scripts/test.sh` uses the same cache. Anywhere else it does nothing.

## Tests

```sh
bash scripts/test.sh                          # the full suite, then the web tests
bash scripts/test.sh --filter LeadBoardTests  # focused tests (swift test options pass through)
bash scripts/test.sh --web Tests/Web          # only the web tests
bash scripts/test.sh --perf                   # only the benches, on a calm Mac
```

Run tests only through `scripts/test.sh`. It points `HOME`, `CFFIXED_USER_HOME`, `VIBESWITCHER_HOME` and `TMPDIR` at
a fresh folder under `/tmp` and removes it afterwards, so nothing a test writes reaches your `~/.vibeswitcher`,
`~/.claude` or login keychain. A plain `swift test` on your own home refuses to start.

After `swift test` it runs each `Tests/Web/*.test.mjs` with node (it stops before building if node isn't on PATH) and
ends with `web tests: N of M passed`. Then it checks that the run left nothing behind: a process still alive 10 seconds
after the tests (a scratch host, a parser, a bench's app) is ended and named, and the run fails. So does a preference
file the run added to `~/Library/Preferences`.

`swift build` and `swift test` run under `vs-heavy`, the Mac-wide slots for heavy work, so suites and builds from every
project's workers take turns. The count is `VIBESWITCHER_HEAVY_SLOTS`, else Settings › Performance's test and build
slots (the cores ÷ 6 while unset), raised to boost's while Boost mode is on. A run that finds every slot
held waits, saying who holds each. Run a full suite or a release build in a session as `vs-heavy <command>`; it gives
up after 60 minutes unless you pass `--timeout`.

A slot is one job's room, not the whole Mac. `vs-heavy` gives its command `VS_HEAVY_CORES`, the slot's share of the
cores: the cores ÷ the slots, rounded up, at least 2 (4 on a 12-core Mac with 3 slots). The job sizes its parallelism to
it. A merge's or an audit's test run gets it from the app (`TestLock.coreBudget`). Other projects' commands use it like
this:

```sh
vs-heavy sh -c 'node --test --test-concurrency="$VS_HEAVY_CORES"'                  # node --test
vs-heavy sh -c 'make -j "$VS_HEAVY_CORES"'                                         # make
vs-heavy sh -c 'npx vitest run --maxWorkers="$VS_HEAVY_CORES"'                     # a test runner's worker count
vs-heavy sh -c 'swift build -j 2 -Xswiftc -j$(( (VS_HEAVY_CORES + 1) / 2 ))'       # SwiftPM (swift test the same)
```

SwiftPM is the odd one. Its `-j N` builds N modules at once and gives each module's compiler `-j N` as well, so a build
can run N × N compiles. With `-j 4`, `swift test` built the test targets side by side with 12 `swift-frontend`
processes at about 1100 % CPU. The line above builds two modules at once, each with half the share of compiles. The
`-Xswiftc -j` comes after SwiftPM's own `-j`, so it wins. `scripts/test.sh` and `scripts/build-app.sh` build this way
(`heavy_swift` in `scripts/lib/swift-jobs.sh`).

The variable isn't set when the command runs without `vs-heavy`, so a project script that reads it should fall back to
its own default: `${VS_HEAVY_CORES:-4}`. Swift Testing 6.1 has no setting for how many tests run at once (it runs them on
Swift's thread pool, one thread per core), so only the build is limited. That's where the cores go: on 2026-11-01 one
merge's build ran 9 `swift-frontend` processes at about 900 % CPU while two other slots were busy too.

**Benches.** Tests judged by wall-clock time or memory are tagged `.perf` and skipped in the normal run, so its result
doesn't depend on how busy the Mac is. `scripts/test.sh --perf` runs them alone. Over the load threshold a bench prints
its numbers without judging them.

**The keychain.** Tests never touch your keychain: the app's key store is injected, and `KeychainLintTests` fails if
keychain code is reachable from a test any other way. The one test of the real keychain runs only when you ask:
`VIBESWITCHER_HOME=$(mktemp -d) VIBESWITCHER_KEYCHAIN_LIVE=1 swift test --filter KeychainLiveTests`.

## The lints

Run them before you call a change done; they take seconds:

```sh
bash scripts/test.sh --filter 'AccessibilityLint|AgentExportLint|ArchitectureDocLint|CLIChangeLint|CloseOnExecLint|CopiedFilesLint|DebugAidsLint|DocLinksLint|ElapsedGuardLint|ElapsedTimeLint|HomePathLint|KeychainLint|MacCompileLint|MacOnlyTestsLint|MCPLint|PhoneMainSyncLint|PlatformLint|PluginLint|PreferencesLint|PrivateNamesLint|PrivateWriteLint|RequestKindsLint|SandboxLint|ScriptScratchLint|SecretShapeLint|SecurityDocumentLint|ServerLint|ShebangWriteLint|StdioWriteLint|TemporaryFolderLint|WebAppLint'
bash scripts/test.sh --filter 'LintTests/'   # the same suites, as AGENTS.md runs them: every `…LintTests` type
```

| Lint | What it catches |
| --- | --- |
| `AccessibilityLint` | An SF Symbol the app shows that's neither named for VoiceOver nor hidden from it. |
| `AgentExportLint` | A script or test that writes a git tree into the worktree with its agent files (AGENTS.md, `CLAUDE*.md`, `.claude/`, `.mcp.json`). |
| `ArchitectureDocLint` | docs/guide/v2-architecture.md's kinds table not the one the code makes (`vibeswitcher kinds-doc --write` writes it), the page at 250 lines or more, or the docs' index not linking it. |
| `CLIChangeLint` | A state change the command line sends outside `NodeClient.change` (a state-changing kind sent as a plain `request`, a read sent through `change`), or a journal entry it writes elsewhere. |
| `CloseOnExecLint` | A descriptor made in the session host, its launcher, `UnixSocket` or `VibePlatform` that isn't close-on-exec from the call that makes it (a bare `socket(`, `socketpair(`, `accept(` or `pipe(`, or an `open(` naming flags without `O_CLOEXEC`), outside the exemptions the test lists with their reasons; or a `Platform.Spawn` in the host that doesn't name what its child keeps. |
| `CopiedFilesLint` | A verbatim copy of the Mac app's code in `Sources/VibeNode` (the port map's "Copied from the app": the Statistics files, `UsageWaits`, `WitnessWork`, `TeamReading`) that drifted from its original, other than its listed differences. |
| `DebugAidsLint` | A notification handler that writes a session's screen where the (unknown) sender says. |
| `DocLinksLint` | A relative link or `#anchor` in README.md or `docs/**/*.md` that doesn't resolve, an image in `docs/images` no doc shows, or a lint suite missing from the command above. |
| `ElapsedGuardLint` | An elapsed-time guard in the node's processes on the wall clock (`Date().timeIntervalSince(`, `.timeIntervalSinceNow`, a deadline on `Date()`, `Date()` compared): the wall clock steps; `Platform.Clock.steadyDate()` doesn't. |
| `ElapsedTimeLint` | A correctness test judging an elapsed time against a bare number (`took < 0.05`, `Date().timeIntervalSince(x) < 5`): it judges the order of events, a baseline from the same test, or it's a `.perf` bench; the short allow list is in `ElapsedTimeLintTests.swift`. |
| `HomePathLint` | A path under the home folder worked out once per process. |
| `KeychainLint` | A test that can reach the real keychain. |
| `MacCompileLint` | A glibc-only spelling (`SOCK_*.rawValue`, `st_mtim`, `pipe2(`, `prctl(`, `SOCK_CLOEXEC`, …) in a file the Mac's CI compiles, outside a Linux-only `#if` block or a `+Linux` file, and a name `Sources` declares only on Linux (in a `+Linux` file or a Linux-only block: `InotifyHub`) used there: nobody can build for the Mac locally. Not linted, having no spelling: a value optional on one system only (bind it per system) and an expression the two compilers type differently (annotate collection literals and optional maps: `let bytes: [UInt8] = …`). |
| `MacOnlyTestsLint` | A file of `Tests/VibeCoreTests` or `Tests/VibeHostTests` wrapped whole in `#if canImport(Darwin)` that its target's `MacOnlyTests.txt` doesn't list with its reason; a file listed there that is gone or has no such wrap; or a tenth of a target's files listed, besides those its plan counts apart. |
| `MCPLint` | A first statement of the tool server's or the hook's main, before the session sandbox's relay and porter hooks (`DoorRelay.runIfConfined`, `Porter.runIfAsked`), or a hook that finds its agent from its own pid rather than its caller's (`HookCaller`). |
| `PlatformLint` | A libc or Apple-only import, or an `#if os(`/`canImport(`, in the portable targets outside `VibePlatform` and `VibeCore/MacOnly`; or a file on its pending list (`Tests/VibePlatformTests/PlatformLintPending.txt`) that no longer has one; or two tracked paths (a folder's too) that differ only in case, which are one on the Mac. |
| `PreferencesLint` | A test that makes a defaults suite in the real `~/Library/Preferences`. |
| `PluginLint` | A source of the node, the command line or the page, outside a feature plugin's folder (`Sources/VibeNode/Plugins/<Name>/`) and the registry's list, that names `shell` or `wallet` as a card kind, a card's field, an answer word or a view: it asks the registry and draws the generic card. |
| `PrivateNamesLint` | A mention of the user's other projects (the list is in the test); write a stand-in, `project-b` or `project-c`. |
| `PrivateWriteLint` | A file under `~/.vibeswitcher` or a project's `.vibeswitcher/` written without `VibePaths.writePrivate` (0600). |
| `RequestKindsLint` | A request kind's lists out of step: a state-changing user's-voice kind missing from `Requests.recorded`, a carded kind unrecorded, a taken kind with no handler (the `act` switch, the hub, the lead's tool server, a page's drafts) or a handler for a kind not taken. |
| `SandboxLint` | A namespace or mount call (`unshare`, `fork`, `clone`, `mount`, `pivot_root`, `setns`, the new mount calls) outside the session sandbox's shim (`Sources/CVibePlatform/shim_sandbox.c`); `Platform.Sandbox.enter` called outside a launcher; or the shim's mutation switch (`VIBE_SANDBOX_MUTATION`, `scripts/sandbox-mutation.sh`'s) named by a build. |
| `ScriptScratchLint` | A script that runs `swift build`, `swift test` or `swift run` with the TMPDIR it was given. |
| `SecretShapeLint` | Text in the repository shaped like a vendor's credential. |
| `SecurityDocumentLint` | A numbered section of the [security architecture document](../superpowers/specs/2026-11-13-v2-security-architecture.md) whose `Held by:` line names a test (`Suite.test`) that no type or extension under `Tests/` declares, or puts a path in backticks; or a section with no `Doesn't promise` part, or no `Before the bootstrap:` line answering `yes` or `no`. |
| `ServerLint` | An exec in the server (`Sources/vibeswitcher-server`, `Sources/VibeNode`): `execve` or `execv`, `Platform.Spawn(…).replaceProcess`, `HostHandover.exec`, `BinaryWatch`, or a connection to the host by its path (`viaConnector: false`). |
| `ShebangWriteLint` | A test that writes a program (a `#!` text, or a helper that writes a parameter and gives it an execute mode) with Foundation's `write(to:)` or `createFile`, which a child forked meanwhile holds open ("Text file busy"): `installScript`, `writeClosedOnExec`, `copyClosedOnExec` or `ScratchNode.script` instead, or an exemption with its reason. |
| `StdioWriteLint` | `FileHandle.standardError` or `standardOutput` in a portable target: its `write(_:)` traps on a failed write (a full disk ends the process); `Platform.Stdio` writes with `write(2)` and ignores the failure. |
| `TemporaryFolderLint` | A test using the system temporary folder instead of its scratch folder; allowed uses are listed in `scripts/temporary-folder-lint.txt`. |
| `WebAppLint` | A file the web page runs (`WebApp/`, outside its Node tests' folders) that builds markup or code from text: `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `DOMParser`, `createContextualFragment`, `setHTML`, `srcdoc`, `eval(`, `Function(`, a string given to `setTimeout`, an `on…` attribute set, a `javascript:` address, or in a page an inline script or handler. |

## Tests under load

```sh
scripts/test-under-load.sh --load $((2 * $(getconf _NPROCESSORS_ONLN))) -r 3 -f 'NewTests'
scripts/test-under-load.sh --load 8 -- swift test --filter SomeTest
```

Run your new or changed tests here before calling them done, and any host, timing or concurrency test. It runs the
suite (or `-f` filtered tests) 3 times at once beside busy loops, the way a Mac running several sessions is loaded,
and fails a run that fails or leaves anything in its TMPDIR. A test must wait on the event it checks (a file, a reply,
a semaphore, an injected clock), never on a fixed sleep.

It's the only way to load the Mac for a test. `--load N` is the load it tops up to, not loops it adds: every few
seconds it runs as many busy loops (at most N, at most 2 × ncpu) as the other sessions' load leaves short of N, and
says how many it ran on average. One load run burns at a time on this Mac, and each holds one of `vs-heavy`'s
Mac-wide slots for the whole run: a second waits, saying for whose. It waits too while the 1-minute load is over
2 × ncpu (up to `--wait`, an hour), and refuses when free memory is under 25 % or the disk has under 15 GB free,
saying what to wait for. Every busy loop stops when the script, its parent or the session's claude process is gone, or after `--max-time` (30
minutes). Logs go to `.build/test-under-load/run-N.log`. `scripts/test-under-load-selfcheck.sh` shows the cleanup
works.

## The sandbox

To see a UI change in the real app without touching yours:

```sh
bash scripts/sandbox-app.sh run              # build this worktree's app and start a sandboxed copy
bash scripts/sandbox-app.sh chat             # show the fake session's chat
bash scripts/sandbox-app.sh type "hello"     # type into the composer; then: send
bash scripts/sandbox-app.sh lead             # a fake project lead; then: team, ask, extras
bash scripts/sandbox-app.sh settings phone   # Settings on a category
bash scripts/sandbox-app.sh sheet all-done   # a sheet: new-project, results, all-done, lead-team, …
bash scripts/sandbox-app.sh shot NAME        # light and dark PNGs of each window in .build/sandbox-shots/
bash scripts/sandbox-app.sh quit
```

The sandbox has its own home, defaults and session host, a throwaway app key, and fake sessions only (the tests'
`FakeClaude`). It never shows a window on screen or takes focus, has no menu bar icon, hot key or phone access, and
quits by itself after 10 minutes (`--minutes`). `bash scripts/sandbox-app.sh help` lists every command. A sheet a
change adds goes in the sheet list in `Sources/VibeSwitcher/Sandbox.swift`. The screenshots in [docs/images](../images)
come from it.

## Other scripts

| Script | What it does |
| --- | --- |
| `scripts/build-app.sh [--install]` | The release app in `build/`; `--install` replaces and relaunches the installed app ([Getting started](getting-started.md#build-and-install)). |
| `scripts/setup-signing.sh` | The local signing identity. `scripts/test-signing.sh` checks the signing scripts. |
| `scripts/ui-bench.sh -B main 2` | The window on a scratch home, idle and busy, against a base build, alternately; judges idle CPU against the base measured in the same run ([idle bench](../eval/runtime-data/idle-bench.md)). |
| `scripts/app-icon.sh` | Redraws the app icon from `scripts/app-icon.swift` ("A · Stack": three cards marked done, working and needs you) into `Resources/AppIcon.icns` and the web app's icons ([logo](../eval/logo/README.md)). |
| `scripts/verifier-eval.sh` | The verifier's evaluation set ([docs/process/verifier-eval.md](../process/verifier-eval.md)). |

Never run tools that inspect another process (lldb, sample, leaks): each puts a password dialog on the user's
screen. For a crash, read its report in `~/Library/Logs/DiagnosticReports`.
