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
project's workers take turns. The count is `VIBESWITCHER_HEAVY_SLOTS`, else the cores ÷ 4. A run that finds every slot
held waits, saying who holds each. Run a full suite or a release build in a session as `vs-heavy <command>`; it gives
up after 60 minutes unless you pass `--timeout`.

**Benches.** Tests judged by wall-clock time or memory are tagged `.perf` and skipped in the normal run, so its result
doesn't depend on how busy the Mac is. `scripts/test.sh --perf` runs them alone. Over the load threshold a bench prints
its numbers without judging them.

**The keychain.** Tests never touch your keychain: the app's key store is injected, and `KeychainLintTests` fails if
keychain code is reachable from a test any other way. The one test of the real keychain runs only when you ask:
`VIBESWITCHER_HOME=$(mktemp -d) VIBESWITCHER_KEYCHAIN_LIVE=1 swift test --filter KeychainLiveTests`.

## The lints

Run them before you call a change done; they take seconds:

```sh
bash scripts/test.sh --filter 'AccessibilityLint|DebugAidsLint|DocLinksLint|HomePathLint|KeychainLint|PreferencesLint|PrivateWriteLint|ScriptScratchLint|SecretShapeLint|TemporaryFolderLint'
```

| Lint | What it catches |
| --- | --- |
| `AccessibilityLint` | An SF Symbol the app shows that's neither named for VoiceOver nor hidden from it. |
| `DebugAidsLint` | A notification handler that writes a session's screen where the (unknown) sender says. |
| `DocLinksLint` | A relative link or `#anchor` in README.md or `docs/**/*.md` that doesn't resolve. |
| `HomePathLint` | A path under the home folder worked out once per process. |
| `KeychainLint` | A test that can reach the real keychain. |
| `PreferencesLint` | A test that makes a defaults suite in the real `~/Library/Preferences`. |
| `PrivateWriteLint` | A file under `~/.vibeswitcher` or a project's `.vibeswitcher/` written without `VibePaths.writePrivate` (0600). |
| `ScriptScratchLint` | A script that runs `swift build`, `swift test` or `swift run` with the TMPDIR it was given. |
| `SecretShapeLint` | Text in the repository shaped like a vendor's credential. |
| `TemporaryFolderLint` | A test using the system temporary folder instead of its scratch folder; allowed uses are listed in `scripts/temporary-folder-lint.txt`. |

## Tests under load

```sh
scripts/test-under-load.sh --load 24 -r 3 -f 'NewTests'
scripts/test-under-load.sh --load 8 -- swift test --filter SomeTest
```

Run your new or changed tests here before calling them done, and any host, timing or concurrency test. It runs the
suite (or `-f` filtered tests) 3 times at once beside busy loops, the way a Mac running several sessions is loaded,
and fails a run that fails or leaves anything in its TMPDIR. A test must wait on the event it checks (a file, a reply,
a semaphore, an injected clock), never on a fixed sleep.

It's the only way to load the Mac for a test. It starts at most 2 × ncpu busy loops, and none while the 1-minute load
is already over 2 × ncpu, free memory is under 25 %, or the disk has under 15 GB free; it says what to wait for. Every
busy loop stops when the script, its parent or the session's claude process is gone, or after `--max-time` (30
minutes). Logs go to `.build/test-under-load/run-N.log`. `scripts/test-under-load-selfcheck.sh` shows the cleanup
works.

## The sandbox

To see a UI change in the real app without touching yours:

```sh
bash scripts/sandbox-app.sh run              # build this worktree's app and start a sandboxed copy
bash scripts/sandbox-app.sh chat             # show the fake session's chat
bash scripts/sandbox-app.sh type "hello"     # type into the composer; then: send
bash scripts/sandbox-app.sh lead             # a fake project lead; then: team, ask, extras
bash scripts/sandbox-app.sh settings phone   # Settings on a tab
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
| `scripts/ui-bench.sh -B project-lead 2` | The window on a scratch home, idle and busy, against a base build, alternately; judges idle CPU against the base measured in the same run ([idle bench](../eval/runtime-data/idle-bench.md)). |
| `scripts/app-icon.sh` | Redraws the app icon from `scripts/app-icon.swift` ("A · Stack": three cards marked done, working and needs you) into `Resources/AppIcon.icns` and the web app's icons ([logo](../eval/logo/README.md)). |
| `scripts/verifier-eval.sh` | The verifier's evaluation set ([docs/process/verifier-eval.md](../process/verifier-eval.md)). |

Never run tools that inspect another process (lldb, sample, leaks): each puts a password dialog on the user's
screen. For a crash, read its report in `~/Library/Logs/DiagnosticReports`.
