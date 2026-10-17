# VibeSwitcher engineering health

Evaluation pass 1 of 4 (engineering: build, tests, code risks). Commit evaluated: `e992e0a` (main at branch start). Date: 2026-10-17.
Toolchain: Apple Swift 6.1.2 (swiftlang-6.1.2.1.2), arm64-apple-macosx15.0, Command Line Tools, Swift 5 language mode.

## Summary

| Area | Health | Top issue |
|---|---|---|
| Build | good | 0 errors, 14 unique warnings; one of them (`InspectorView.swift:152`) shows a "background" transcript read actually running on the main actor ([E-19](#e-19)) |
| Tests | ok | 393/393 pass in all 3 runs, no flakes. But the app target (11.6k lines) has no test target, and `SessionScanner` / `VibePaths` can't be tested (paths are hard-wired to the real home) ([E-32](#e-32)) |
| Hook binary (`vibeswitcher-hook`) | good | Exit 0 and no stdout on every malformed input tried. The waits on stdin EOF and on `flock` have no limit of their own, so only the agent's 5 s hook timeout bounds them. Long steered messages are cut, yet marked delivered ([E-05](#e-05)) |
| Session host (`VibeHost`, `vibeswitcher-host`) | ok | Pastes over 1 MB are silently cut, or arrive with a gap in the middle ([E-07](#e-07)) |
| Lead tool server (`vibeswitcher-mcp`, `LeadToolset`, `Worktrees`) | poor | A CRLF, BOM or non-UTF-8 `workflow.md` silently turns off the merge tests ([E-04](#e-04)). Host errors are read as "no sessions", so a live worktree can be removed and a second worker started ([E-09](#e-09)). Lead messages over ~8 KB can vanish while reported as typed ([E-06](#e-06)) |
| App (`VibeSwitcher`) concurrency | ok | Queue discipline is mostly sound: no `@Published` or AppKit mutation off main was found. But one AppleScript timeout wipes every Terminal tab for a cycle ([E-08](#e-08)), and Accessibility and git calls block the main thread ([E-11](#e-11), [E-14](#e-14)) |
| Crash risks | good | No reachable trap in parsing code (200k-input fuzz, every force unwrap reviewed). Remaining crash paths: SIGPIPE in the app ([E-02](#e-02)) and in the MCP server ([E-38](#e-38)) |
| Error handling | poor | A strict decode of `presets.json` can lead to the user's presets being overwritten ([E-01](#e-01)). Run on code blocks can run a different command than shown ([E-10](#e-10)). Several user-initiated saves fail with no message ([E-24](#e-24)) |
| Test coverage | ok | Thin or no tests: `SessionScanner`, `Paths`, `ProcessTable` (scan/ancestors), `HookInstaller` file I/O, `HostConnection`, `TypedText`, the hook and MCP `main.swift`, and the whole app target ([§ Coverage](#test-coverage-gaps)) |

Severity scale: **P0** crash / data loss / security, **P1** broken behaviour, **P2** quality / maintainability, **P3** polish. Each finding is tagged **confirmed** (reproduced by a probe, or the code path read end to end) or **plausible** (the mechanism is clear but wasn't reproduced). Findings are ranked by user impact within each severity. All probes ran from the session scratchpad; nothing outside `docs/eval/` was changed.

---

## 1. `swift build`

Clean build into a fresh scratch path (`swift build --scratch-path <tmp>/build`), so incremental state played no part:

```
Build complete! (63.25s)
swift build ...  120.36s user 13.12s system 207% cpu 1:04.46 total
exit=0
```

- **0 errors.**
- **14 unique warnings** (the raw log has 120 `warning:` lines because each diagnostic is echoed with its source excerpt).
- SwiftTerm 1.19.0 contributes none; all 14 are in `Sources/`.

| Category | Count | Locations |
|---|---|---|
| Swift 6 Sendable: `NSImage` isn't `Sendable` | 6 | `VibeSwitcher/MainWindow/Chat/ToolViews.swift:367:46, 367:51, 375:11, 417:26, 417:31, 417:90` |
| Swift 6 Sendable: non-sendable value crosses an isolation boundary | 3 | `ToolViews.swift:351:58` (`thumbnail(_:maxPixels:)` result), `ToolViews.swift:417:26` (`Task<NSImage?, Never>`), `ToolViews.swift:417:90` (`.value`) |
| Swift 6: async expression without `await` | 1 | `VibeSwitcher/MainWindow/InspectorView.swift:152:72`. Not cosmetic; see [E-19](#e-19) |
| Unused `try?` result | 2 | `VibeCore/LeadToolset.swift:93:9` (`try? store.prepare()`), `VibeSwitcher/MainWindow/Lead/LeadController.swift:148:9` (`try? LeadDelivery.deliver(...)`). Both swallow errors users care about; see [E-23](#e-23) |
| Unused value | 1 | `VibeCore/PreviewProxy.swift:165:13` (`let upgrade = PreviewGate.isUpgrade(head)` computed and never used) |
| Captured variable never read | 1 | `VibeSwitcher/RemoteServer.swift:78:47` (`[weak self]` in `stateUpdateHandler`) |

- All 10 Swift 6 diagnostics are errors in Swift 6 language mode, so they block moving the package to `swiftLanguageModes: [.v6]`.
- Today Swift 5 mode means the compiler does **not** check data races. The concurrency findings below were found by hand for that reason.

## 2. `swift test`, three runs

Command: `swift test`, exactly as written, in the worktree. Run 1 also built the default `.build`.

| Run | Exit | Result | Swift Testing time | Wall clock |
|---|---|---|---|---|
| 1 | 0 | `✔ Test run with 393 tests passed after 15.516 seconds.` | 15.5 s | 84 s (includes build) |
| 2 | 0 | `✔ Test run with 393 tests passed after 16.187 seconds.` | 16.2 s | 18 s |
| 3 | 0 | `✔ Test run with 393 tests passed after 14.783 seconds.` | 14.8 s | 15 s |

- **Pass/fail:** 393 passed, 0 failed, 0 skipped, in each run. There are 108 suites; all use Swift Testing (no XCTest cases).
- **Flakes:** none. No test failed or reported an issue in any run.
- **Slowest test:** `slowClientGetsResyncAndProgramKeepsRunning()` (HostServerTests) takes 14.8–16.2 s and sets the wall clock of the whole suite.
- **Next slowest:** `aRequestTheClientAbandonsReleasesTheDevServerConnection()` (PreviewProxyTests) takes about 7.5 s.

## 3. The hook binary's contract: never block or fail an agent

`Sources/vibeswitcher-hook/main.swift` (48 lines) promises: "print nothing … and always exit 0".

**How it was exercised.** `NSHomeDirectory()` **ignores `$HOME` on macOS**. Probe: `HOME=<tmp> ./home` printed `/Users/albert`. So a `HOME=<tmp>` run of the shipped binary *would* write the real `~/.vibeswitcher/state/<tty>.json` and take real steer messages. See [E-32](#e-32).

- I therefore built the hook from a scratch copy of the package, with `VibePaths.root` patched to read `$PROBE_HOME` (falling back to a nonexistent path).
- I ran it with a temp `PROBE_HOME`. The real state was never touched.
- Debug build, run from this Claude session, so the hook's agent ancestor is a real `claude` on `ttys003`.

| Input / condition | Exit | Stdout | Time | Notes |
|---|---|---|---|---|
| empty stdin (`< /dev/null`) | 0 | 0 B | 0.27 s | |
| `not json {{{` | 0 | 0 B | 0.03 s | |
| `[1,2,3]` (JSON, not an object) | 0 | 0 B | 0.02 s | |
| `{"foo":1}` (no `hook_event_name`) | 0 | 0 B | 0.03 s | `.ignore` |
| valid `PreToolUse` | 0 | 0 B | 0.03 s | state written 0600 |
| wrong types (`session_id: 5`, `tool_name: [1]`, `tool_input: "x"`, `cwd: 7`) | 0 | 0 B | 0.03 s | `as?` casts hold |
| `PermissionRequest` Bash with `command: [1,2]` | 0 | 0 B | 0.03 s | |
| lone surrogate `\ud800` in the prompt | 0 | 0 B | 0.03 s | |
| invalid UTF-8 bytes in the prompt | 0 | 0 B | 0.02 s | |
| 100,000-deep nested array | 0 | 0 B | 0.03 s | `JSONSerialization` depth limit; no stack overflow |
| 50 MB `Write` `tool_input` | 0 | 0 B | 0.11 s | |
| 2M-character `é` prompt plus 100k newlines | 0 | 0 B | **1.42 s** | redaction runs on the whole text before it is clipped ([E-35](#e-35)) |
| corrupt state file (`garbage`) | 0 | 0 B | — | replaced with fresh state |
| state path is a directory | 0 | 0 B | — | the write fails silently, as designed |
| **stdin held open 5 s without EOF** | 0 | 0 B | **5 s** | `readDataToEndOfFile()` has no limit of its own ([E-28](#e-28)) |
| **state `.lock` held by another process for 6 s** | 0 | 0 B | **6 s** | `flock(LOCK_EX)` waits with no limit of its own ([E-28](#e-28)) |
| steer inbox: 8,000-char message, then a short one | 0 | 8,358-char `additionalContext` | — | both delivered |
| steer inbox: 8,900-char message, then a short one, on `Stop` | 0 | `{"decision":"block","reason": <8,994 chars ending "[message cut]">}` | — | **2nd message missing, yet `delivered` lists `n1 n2`** ([E-05](#e-05)) |

**Verdict.**

- *Always exits 0:* holds for every input tried. All failure paths use `try?`, `guard … else { exit(0) }`, or `as?`.
- *Prints nothing:* holds, except the documented steer reply.
- *Malformed stdin:* handled safely.
- *Bounded time:* not guaranteed by the binary. The real limit is the `"timeout": 5` that `HookInstaller.addingOurs` writes into each hook entry (`HookInstaller.swift:55`). Within that, an agent can still be held up to 5 s per event.
- *Crash paths:* the only `try!` calls on this path are static regex constructions (`Redaction.swift:38`), which can't fail at run time.

---

## 4. Findings

### P0: crash / data loss / security

<a id="e-01"></a>**E-01 · P0 · confirmed: one strict decode of `presets.json` silently replaces every user preset with the built-ins, and the next edit overwrites the file**

- **Where:** `Sources/VibeCore/LaunchPresets.swift:102-106`, `Sources/VibeSwitcher/Preferences.swift:36`.
- **Code:**
  ```swift
  guard let data = try? Data(contentsOf: url),
        let presets = try? JSONDecoder().decode(LaunchPresets.self, from: data), !presets.global.isEmpty
  else { return builtIns(claudeCommand: claudeCommand, codexCommand: codexCommand) }
  ...
  @Published var presets: LaunchPresets { didSet { try? presets.save(to: VibePaths.presetsFile) } }
  ```
- **Evidence:** a probe decoded variants with the real types:
  - `hand-added preset without env/keepShell/place -> FAILS: whole file falls back to built-ins`
  - `newer app's place value -> FAILS: whole file falls back to built-ins` (the downgrade case)

  The first preset edit in Settings then saves the built-ins over the user's file. There is no backup, and the save error is swallowed too.
- **Fix:** decode leniently (`decodeIfPresent` with defaults, skip bad items). On a decode failure, keep a `presets.json.corrupt` copy and never save automatically over a file that didn't decode.

<a id="e-02"></a>**E-02 · P0 (rare trigger) · plausible: the app never ignores SIGPIPE, and `CodexTrust` writes to a child's stdin, so a Codex app-server that exits mid-handshake kills VibeSwitcher**

- **Where:** `Sources/VibeSwitcher/CodexTrust.swift:40`.
- **Code:**
  ```swift
  input.fileHandleForWriting.write(data)
  ```
- **Evidence:**
  - `grep -rn SIGPIPE Sources` finds only `vibeswitcher-host/main.swift:11` (`signal(SIGPIPE, SIG_IGN)`) and the `SO_NOSIGPIPE` on Unix sockets.
  - The app's pipes to child processes have neither.
  - "Install hooks" → `HookSetup.installAll` → `CodexTrust.trustOurHooks` sends several JSON-RPC lines to `zsh -lc "exec codex app-server"`. If Codex answers `initialize` and then exits (version mismatch, crash), the next `write(2)` raises SIGPIPE and the menu bar app dies.
- **Fix:** call `signal(SIGPIPE, SIG_IGN)` at app start (in `main.swift`), and use `try write(contentsOf:)` so EPIPE becomes an error.

<a id="e-03"></a>**E-03 · P0 (rare trigger) · plausible: two parallel merges into a base branch that isn't checked out can drop the first merge's commits from the base**

- **Where:** `Sources/VibeCore/Worktrees.swift:224` (ancestry check), then lines 238-240.
- **Code:**
  ```swift
  let target = Git.run(["rev-parse", branch], in: root).output
  let current = Git.run(["rev-parse", main], in: root).output
  let update = Git.run(["update-ref", "refs/heads/\(main)", target, current], in: root)
  ```
- **Evidence:**
  - The old-value guard of `update-ref` uses a `current` read *after* the `--is-ancestor` check, so it protects nothing.
  - `MCPServer` runs tool calls on a concurrent queue, and the merge lock is per task (`merge-<slug>.lock`), not per base.
  - If merge A moves the base between B's check and B's `rev-parse`, B's `update-ref` succeeds and A's commits leave the base.
  - `cleanup` then deletes `agent/A` with `-D`, leaving those commits only in the reflog.
  - Only the `.none` path (base not checked out anywhere) is affected.
- **Fix:** read `current` once, before the ancestry check, and pass it to `update-ref`. Or take the merge lock per base branch.

### P1: broken behaviour

<a id="e-04"></a>**E-04 · P1 · confirmed: a `workflow.md` with CRLF line endings, a BOM, or one non-UTF-8 byte silently disables `test_command`, so the lead merges untested work**

- **Where:** `Sources/VibeCore/LeadWorkflow.swift:25`, `Sources/VibeCore/LeadToolset.swift:81`, `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift:93`, `Sources/VibeCore/Worktrees.swift:207`.
- **Code:**
  ```swift
  var workflow = LeadWorkflow.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
  if lines.first?.trimmingCharacters(in: .whitespaces) == "---", ...      // "---\r" != "---"
  guard let test, !test.trimmingCharacters(in: .whitespaces).isEmpty else { return .passed(tested) }
  ```
- **Evidence:** a probe ran the real `LeadWorkflow.parse`:
  ```
  LF  : Optional("swift test") 2
  CRLF: nil 3
  BOM : nil
  Latin-1 é in notes: nil
  ```
  When the front matter vanishes, `max_workers` and `base_branch` reset too, and `rebaseAndTest` returns `.passed` without running anything.
- **Fix:** normalise `\r\n`, strip a BOM, and read lossily. Report "workflow.md front matter not found / unreadable" in `status` and in the lead prompt. Treat a missing test command as an explicit "no checks" state, not a pass.

<a id="e-05"></a>**E-05 · P1 · confirmed: steered messages past ~9,000 characters are cut, and later queued messages are dropped, while every one is recorded as delivered**

- **Where:** `Sources/VibeCore/Steer.swift:61-62` (take and truncate), `Sources/VibeCore/Steer.swift:170` (cut).
- **Code:**
  ```swift
  taken = decode(data).filter { $0.agentPid == agentPid }
  try handle.truncate(atOffset: 0)
  ...
  return text.count > contextLimit ? String(text.prefix(contextLimit - 20)) + "\n[message cut]" : text
  ```
- **Evidence:** in the hook probe (§3), message `n1` was 8,900 characters and `n2` was "SECOND MESSAGE stop now". On `Stop`, the reply was 8,994 characters ending in `[message cut]`, did not contain `SECOND`, and the `.delivered` file listed `n1 n2`.
- **Who is affected:** nothing caps the length upstream (`SteerInbox.post` callers are `MainWindowController.swift:363` and `LeadDelivery.swift:45,48,65`). A lead's long brief to a worker, or a pasted log, triggers this.
- **Fix:** take messages only while they fit, leaving the rest in the inbox for the next event. Cap or warn in the composer and in `message`.

<a id="e-06"></a>**E-06 · P1 · confirmed: `HostCall.send` reports success 50 ms after queueing, then closes the socket; lead messages over ~8 KB can be lost but reported as "typed"**

- **Where:** `Sources/VibeCore/SessionDigest.swift:97` (plus `defer { connection.close() }` at :80), used by `Sources/vibeswitcher-mcp/main.swift:57`.
- **Code:**
  ```swift
  if !expectsReply { queue.asyncAfter(deadline: .now() + 0.05) { done.signal() } }
  ```
- **Evidence:**
  - AF_UNIX socket buffers are 8 KB.
  - A probe built from the real `HostCall`, `HostConnection` and `HostProtocol` against a fake host busy for 300 ms printed: `HostCall.send returned success (caller reports the message as typed)` / `host: connection closed; bytes read after hello=8273, frames=1, leftover partial frame lost`.
  - `type()` returns true, so `message` tells the lead "Typed into … idle worker".
- **Fix:** wait for `outgoing` to drain (a flush completion) with a timeout that throws, or have the host acknowledge `.input`.

<a id="e-07"></a>**E-07 · P1 · confirmed (replica probe): pastes into a window session over ~1 MB are silently cut, or arrive with a hole in the middle**

- **Where:** `Sources/VibeHost/HostedSession.swift:169` (`maxPendingInput = 1 << 20` at :37), and `Sources/VibeSwitcher/HostClient.swift:311-318`, which sends 256 KB pieces back to back.
- **Code:**
  ```swift
  guard pendingInput.count + bytes.count <= Self.maxPendingInput else { return }
  pendingInput.append(bytes)
  ```
- **Evidence:**
  - A PTY master accepts about 1 KB before EAGAIN.
  - A probe reproducing `write`'s buffering against a real `openpty` printed `paste 3145728 bytes: written to pty at once 1022, queued+written 1048576, silently dropped 2097152`.
  - When pieces arrive in separate reads, a later piece can be accepted after a drain, so the agent receives the paste with a chunk missing from the middle.
- **Fix:** apply backpressure instead of dropping. Either let the input queue grow for already-framed input, or acknowledge `.input` so the client waits before the next piece. If input must be refused, return an error to the user.

<a id="e-08"></a>**E-08 · P1 · confirmed: one failed or slow Terminal AppleScript read wipes every Terminal tab for that scan**

- **Where:** `Sources/VibeSwitcher/TerminalBridge.swift:70-73`, consumed at `Sources/VibeSwitcher/SessionStore.swift:176-177`.
- **Code:**
  ```swift
  if result.status != 0 { return ([:], result.error.contains("-1743") ? .denied : .unknown) }
  ...
  let result = TerminalBridge.tabs()
  self.tabs = result.tabs
  ```
- **Evidence:**
  - `tabs()` has a 4 s osascript timeout.
  - Other queues send Apple Events to Terminal at the same time: the phone's `history of tab` reads (8 s), the screen polls, the mirror loop every 2 s, and focus scripts. Terminal serves Apple Events one at a time.
- **What the user sees, for one cycle:**
  - every session loses `inTerminalApp`, its position and its title;
  - the dots and ⌃1–9 reorder, so ⌃3 can jump to a different session;
  - the phone gets 409;
  - title-only sessions flip `done → unknown → done`, which resets `since`, re-marks them unseen and can re-fire the "is done" banner (`SessionStore.swift:305-317`).
- **Fix:** on any non-zero status other than -1743, keep the previous `tabs`. Funnel Terminal AppleScript through one serial queue so reads don't starve the scan.

<a id="e-09"></a>**E-09 · P1 · confirmed (code path): host errors in the MCP runtime read as "no sessions" or "killed", which defeats the lead tools' safety checks**

- **Where:** `Sources/vibeswitcher-mcp/main.swift:48` and `:81`, consumed at `Sources/VibeCore/LeadToolset.swift:264, 291, 388`.
- **Code:**
  ```swift
  _ = try? HostCall.request(.kill(id: id), timeout: 3)
  ((try? HostCall.sessions()) ?? []).map { session in
  ```
- **Consequences when the host times out or isn't reachable:**
  - `stop_worker` says "Stopped the worker" and sets the task to blocked, although the kill never arrived.
  - `start_worker` treats the worker as not running and starts a second agent in the same worktree.
  - `cleanup` sees no live sessions and runs `git worktree remove --force` under a running agent.
- **Fix:** make `LeadRuntime.sessions()` and `kill` throw, and return `isError` from these tools when the host can't be reached.

<a id="e-10"></a>**E-10 · P1 · confirmed: "Run" on a code block can run only part of it, or something different**

- **Where:** `Sources/VibeCore/RunnableCommand.swift:28` and `:38`.
- **Code:**
  ```swift
  if pending.isEmpty, command.isEmpty || command.hasPrefix("#") { continue }
  return "! " + commands.joined(separator: " && ")
  ```
- **Evidence:** a probe ran the real function:
  ```
  ! git stash   # save local work && git pull --rebase && git stash pop    ← only `git stash` runs; work stays stashed
  ! python3 -c 'print(1) && print(2)'                                     ← && inserted inside a quoted string
  ! npm run dev & && open http://localhost:3000                           ← syntax error
  ! if [ -f x ]; then && rm x && fi                                       ← syntax error
  ```
- **Fix:** don't offer Run when a line has an unquoted `#` after code, unbalanced quotes, a trailing `&`, or a line ending in `then`, `do`, `{` or `|`. Or send the lines joined by newlines inside a bracketed paste.

<a id="e-11"></a>**E-11 · P1 · confirmed: the debug status file makes Accessibility calls into Terminal on the main thread, on every popover open and every status change**

- **Where:** `Sources/VibeSwitcher/AppStatus.swift:28` (`"tabBars": TabOrder.tabBars()`), with `AppStatus.enabled = true` for the app (`AppStatus.swift:11`).
- **Code:**
  ```swift
  let app = AXUIElementCreateApplication(terminal.processIdentifier)
  AXUIElementSetMessagingTimeout(app, 0.5)
  for window in children(of: app, attribute: kAXWindowsAttribute) {
  ```
  This is `TabOrder.swift:22-36`, and the 0.5 s timeout is set only on the app element.
- **How it's reached:** `AppStatus.write` runs on main from `togglePopover` (`AppDelegate.swift:452`), from `SessionStore.apply` on every status change (`SessionStore.swift:196, 370`), from `updateFloatingPanel`, and after every `open()`.
- **Impact:** the window and tab elements fall back to the default (~6 s) Accessibility timeout, so a busy or hung Terminal freezes the popover and the menu bar icon.
- **Fix:** write the `tabBars` result the scan queue already computed, or drop it, and set the timeout on each element.

<a id="e-12"></a>**E-12 · P1 · confirmed (code path): cancelling a lead tool call also kills its cleanup steps and records a false failure**

- **Where:** `Sources/VibeCore/Worktrees.swift:72-73`, and `:202` (`rebase --abort`).
- **Code:**
  ```swift
  let cancel = ShellCancel.current
  while process.isRunning, Date() < deadline, cancel?.isCancelled != true { usleep(20_000) }
  ```
- **What happens:** the cancel flag stays set for the rest of the call, so every later `Git.run` is SIGTERMed as soon as it starts.
  - A cancelled `merge` during the tests comes back `.failed` ("The test command fails"), and the task is marked failed.
  - A cancel during the rebase also kills `git rebase --abort`, which can leave the worker's worktree mid-rebase on a detached HEAD.
- **Fix:** check cancellation between steps and return without touching the board. Run cleanup commands outside the cancel token.

### P2: quality / maintainability (real but lower-impact behaviour problems included)

<a id="e-13"></a>**E-13 · P2 · confirmed: installing hooks replaces a symlinked `~/.claude/settings.json` (or `~/.codex/hooks.json`) with a plain file**

- **Where:** `Sources/VibeCore/HookInstaller.swift:117`.
- **Code:**
  ```swift
  try (data + Data("\n".utf8)).write(to: url, options: .atomic)
  ```
- **Evidence:** a probe made an atomic `Data.write` to a symlink. Afterwards the link was a regular file (`-rwxr-xr-x … link.json`), and the dotfiles target still held `{"a":1}`.
- **Impact:** for dotfiles users, later edits in the repo no longer reach Claude. The same write also reorders the user's keys (`.sortedKeys`) and reformats numbers (`0.1` → `0.10000000000000001`).
- **Fix:** write to `url.resolvingSymlinksInPath()`, keep the original key order where possible, and skip the write when the hooks are already correct.

<a id="e-14"></a>**E-14 · P2 · confirmed: starting a lead runs git on the main thread (up to the 120 s `Shell.run` timeout per call)**

- **Where:** `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift:90-92`.
- **Code:**
  ```swift
  let boardStore = BoardStore(root: root)
  do {
      let workflowPath = try boardStore.prepare()
  ```
- **Evidence:**
  - `startLead(in:)` finds the repo off main, with the comment "git can be slow (a network volume, a git shim)". It then hops to main, and `prepare()` runs `git rev-parse --git-path` (`LeadBoard.swift:241`) and, on first start, `currentBranch` / `mainBranch`.
  - `BoardStore.update`'s `flock` and the steer `SteerInbox.post` / `withdraw` `flock` also run on main (`MainWindowController.swift:363`, `ChatModel.swift:319`). They share the lock with the MCP process.
- **Fix:** run `prepare()` and `LeadLaunch.prepare` in the existing background block, and only `host.spawn` on main.

<a id="e-15"></a>**E-15 · P2 · confirmed (code path): rebase failures are all reported as "conflict", and a failed `git status` counts as clean**

- **Where:** `Sources/VibeCore/Worktrees.swift:197-203`.
- **Code:**
  ```swift
  guard Git.run(["status", "--porcelain", "--untracked-files=no"], in: path).output.isEmpty else {
  ...
  guard rebase.ok else { Git.run(["rebase", "--abort"], in: path); return .conflict }
  ```
- **What happens:** with `index.lock` held (the worker is mid-commit), `status` fails with empty output, so the worktree passes as clean. The rebase then fails for an unrelated reason, and the worker is told to resolve a conflict that doesn't exist.
- **Fix:** check `status.ok`. Return `.error(rebase.error)` unless the output contains `CONFLICT`, and only abort a rebase this call started.

<a id="e-16"></a>**E-16 · P2 · confirmed (code path): ended sessions keep their PTY, a replay ring of up to ~10 MB, and a SwiftTerm buffer for 24 h**

- **Where:** `Sources/VibeHost/HostServer.swift:19`.
- **Code:**
  ```swift
  public var keepEnded: TimeInterval = 24 * 3600
  ```
- **Impact:** `HostedSession.close()` runs only on `forget` or `stop`, and the lead's `cleanup` only kills sessions. Every worker and verifier of a busy day therefore keeps a master fd and its buffers. That is hundreds of MB in the host, plus PTYs from the system pool (`kern.tty.ptmx_max`, which Terminal shares).
- **Fix:** when a session is reaped, close the master once its output has drained, and keep only the final screen and history text. Have `cleanup` send `.remove`.

<a id="e-17"></a>**E-17 · P2 · plausible: `Shell.run` waits with no limit for its pipe readers, so a test that leaves a background child hangs `merge` forever while it holds the merge lock**

- **Where:** `Sources/VibeCore/Worktrees.swift:83` (`group.wait()`).
- **Detail:** the timeout and cancel cover only the main process. A `test_command` that runs `server &` keeps stdout open, so `readDataToEndOfFile` never returns.
- **Fix:** after the process exits, use `group.wait(timeout:)`, then signal the process family and close the read ends.

<a id="e-18"></a>**E-18 · P2 · plausible: `start_worker` checks `max_workers` and spawns without holding the board lock**

- **Where:** `Sources/VibeCore/LeadToolset.swift:267-285`.
- **Code:**
  ```swift
  let running = board.tasks.filter { $0.status == .running }.count
  ```
  The count is read, the worker is spawned, and only then is the task marked running in `store.update`.
- **What happens:** parallel tool calls in one message all pass the limit, and they run `git worktree add` concurrently on one repository.
- **Fix:** reserve the slot inside `store.update` before spawning, and roll it back if the spawn fails.

<a id="e-19"></a>**E-19 · P2 · confirmed (compiler): the Activity tab's "background" transcript read runs on the main actor**

- **Where:** `Sources/VibeSwitcher/MainWindow/InspectorView.swift:152`.
- **Code:**
  ```swift
  let read = await Task.detached(priority: .userInitiated) { Self.read(path) }.value
  ```
- **Evidence:** the build warns `expression is 'async' but is not marked with 'await'`. `Self` is a SwiftUI `View`, which is main-actor isolated, so `Self.read` (file seek, read and JSONL parse, `:158-166`) hops back to main. The detach does nothing.
- **Fix:** mark `read` `nonisolated`, or move it to a non-View type.

<a id="e-20"></a>**E-20 · P2 · plausible: the app waits forever for a welcome from a host that accepted the connection but doesn't answer**

- **Where:** `Sources/VibeSwitcher/HostClient.swift:109`.
- **Code:**
  ```swift
  connection.send(.hello(...))
  ```
- **What happens:** the hello is sent with `send`, not `request()`, so the 15 s reply timeout doesn't apply, and `ensureHost` parks callers in `whenReady`. With a wedged host, new window sessions sit "starting" with no error.
- **Fix:** add a welcome timeout that fails the waiters and reconnects.

<a id="e-21"></a>**E-21 · P2 · plausible: the MCP server exits on stdin EOF while tool calls are still running**

- **Where:** `Sources/VibeCore/MCPServer.swift:79`.
- **Code:**
  ```swift
  while let line = readLine(strippingNewline: true) {
  ```
  When the loop ends, `main` returns.
- **What happens:** when Claude Code reconnects the server, an in-flight `merge` or `cleanup` dies mid-step, its git or test children are orphaned, and the board is left half-updated.
- **Fix:** on EOF, cancel the running tokens and wait (bounded) for the calls to finish.

<a id="e-22"></a>**E-22 · P2 · confirmed (code path): jumps to Terminal tabs queue up on an unfair `NSLock`, so a later click can lose to an earlier one**

- **Where:** `Sources/VibeSwitcher/AppDelegate.swift:755-761`.
- **Code:**
  ```swift
  DispatchQueue.global(qos: .userInitiated).async { ... RemoteInput.focusLock.lock()
  ```
- **What happens:** each `open()` starts a global-queue job that holds the lock for up to ~6 s (bring to front, focus report, focus log). With two or more waiters, `NSLock` doesn't guarantee FIFO, so Terminal can end on the session the user didn't pick last. Superseded jumps are never dropped.
- **Fix:** one serial focus queue plus a generation counter bumped on main; a stale job returns without moving focus.

<a id="e-23"></a>**E-23 · P2 · confirmed: when the lead can't register itself, or a delivery fails, nobody is told**

- **Where:** `Sources/VibeCore/LeadToolset.swift:93-99` (the `try?` at :93 is a build warning), `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift:148` (also a build warning), `Sources/VibeCore/LeadDelivery.swift:65`.
- **Code:**
  ```swift
  try? store.prepare()
  try? store.update { board in board.leadPid = me.pid ... }
  try? LeadDelivery.deliver(text, from: sender, to: agent, inputIsEmpty: nil, typeInto: nil)
  ```
- **What happens:** with an unreadable `board.json`, the lead never records its pid and tty, so every worker report says "There's no lead running". User answers are held in memory (lost on quit), and a failed `SteerInbox.post` in `flush` drops the message.
- **Fix:** surface the error in the lead's `status` and in an alert, and keep inbox messages until they have been typed.

<a id="e-24"></a>**E-24 · P2 · confirmed: user-initiated saves and launches fail with no message**

- **Where:** `Sources/VibeSwitcher/MainWindow/MainWindowController.swift:625` (Export chat), `Sources/VibeSwitcher/MainWindow/Chat/ToolViews.swift:425` (Save screenshot), `Sources/VibeSwitcher/Launcher.swift:44` (new Terminal session).
- **Code:**
  ```swift
  try? ChatExport.markdown(chat.log.entries, agent: agent).write(to: url, atomically: true, encoding: .utf8)
  try? image.data.write(to: url)
  if result.status != 0 { NSLog("VibeSwitcher: launch failed: \(result.error)") }
  ```
- **What happens:** for a new session, Automation denied (-1743) or a cold Terminal launch that takes longer than the 4 s osascript timeout means nothing happens on screen. The user clicks again and can get two windows.
- **Fix:** show an `NSAlert` with the error, and give a cold Terminal launch a longer timeout.

<a id="e-25"></a>**E-25 · P2 · confirmed (mechanism): a non-UTF-8 `.git/info/exclude` is rewritten as one line, losing the user's rules**

- **Where:** `Sources/VibeCore/LeadBoard.swift:245-250`.
- **Code:**
  ```swift
  let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
  ...
  try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
  ```
- **Evidence:** the read fails on any invalid UTF-8 byte (shown in the `workflow.md` probe for [E-04](#e-04)), and the file is then replaced with just `/.vibeswitcher/`.
- **Fix:** append bytes with `FileHandle.seekToEnd`, and tell "missing" apart from "unreadable".

<a id="e-26"></a>**E-26 · P2 · confirmed (code path): full-size images are read from disk on main, inside SwiftUI `body`, on every re-render**

- **Where:** `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift:607`, `ComposerView.swift:375`, `Lead/LeadViews.swift:189`.
- **Code:**
  ```swift
  if let image = NSImage(contentsOfFile: path) {
  ```
- **What happens:** `ChatModel.poll()` re-renders the chat every second, and the composer re-renders on every keystroke. Each pass reads multi-MB screenshots again. `ImageCache` (`ToolViews.swift:355`) already does this properly off main.
- **Fix:** route these through `ImageCache` (a `CGImageSource` thumbnail off main, keyed by path and mtime).

<a id="e-27"></a>**E-27 · P2 · confirmed (code path): `/` and `@` completions from the previous session can overwrite the current one's**

- **Where:** `Sources/VibeSwitcher/MainWindow/Chat/ChatModel.swift:365-387`.
- **What happens:** each chat switch starts an independent global job that walks up to 20,000 files, with no generation check (`show` and `poll` do have one). A slow walk of a big repo can land last, so `@` offers the wrong project's files.
- **Fix:** capture the generation or folder, and drop a stale result in the main block.

<a id="e-28"></a>**E-28 · P2 · confirmed: the hook binary itself has no time bound**

- **Where:** `Sources/vibeswitcher-hook/main.swift:11` and `:30`; also `Steer.swift:115`.
- **Code:**
  ```swift
  let input = FileHandle.standardInput.readDataToEndOfFile()
  if lock >= 0 { flock(lock, LOCK_EX) }
  ```
- **Evidence:** the §3 probes show stdin held open for 5 s blocks the hook for 5 s, and a lock held for 6 s blocks it for 6 s.
- **Limits:** the only bound is the `timeout: 5` in the installed hook config (`HookInstaller.swift:55`). That holds only as long as the user's config keeps it; a hand-edited or older entry without it gets Claude Code's default (60 s).
- **Fix:** `alarm(3)` with a SIGALRM handler that calls `_exit(0)`, and `flock(LOCK_EX | LOCK_NB)` in a short retry loop (give up after ~1 s).

<a id="e-29"></a>**E-29 · P2 · confirmed (code path): oversized host frames are dropped without telling the sender**

- **Where:** `Sources/VibeHost/ClientConnection.swift:45`, `Sources/VibeCore/HostConnection.swift:36-38`.
- **Code:**
  ```swift
  guard let payload = try? HostCoding.encode(envelope), payload.count <= HostFrame.maxPayload else { return }
  ```
- **What happens:**
  - A `screenText` or `historyText` reply that JSON escaping pushes past 1 MiB never arrives, and the app says "didn't answer" after 15 s.
  - `HostCall.send` of input over ~786 KB (base64 brings it past 1 MiB) is dropped but reports success.
- **Fix:** reply `.error("too large")` from the host, and make the client throw or split.

<a id="e-30"></a>**E-30 · P2 · confirmed: `swift test` can't isolate the app's real state, because `VibePaths` uses `NSHomeDirectory()`, which ignores `$HOME`**

- **Where:** `Sources/VibeCore/Paths.swift:6`.
- **Code:**
  ```swift
  URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vibeswitcher")
  ```
- **Evidence:**
  - `HOME=<tmp> ./home` printed `/Users/albert`.
  - Code with a hard-wired root: `SessionScanner.swift:93` (which *deletes* state files), `Attention.swift:143,156` (`ActivityLedger`), `DebugLog.swift:49` (`Breadcrumbs.shared`), and the `root:` defaults of `SteerInbox` and `LeadDelivery`.
  - Any test or probe that reaches these touches the real `~/.vibeswitcher`, and `SessionScanner` can't be unit-tested at all ([E-32](#e-32)).
- **Fix:** take the root from an environment override (`VIBESWITCHER_HOME`) or inject it, and pass it to `SessionScanner` and `ActivityLedger`.

<a id="e-31"></a>**E-31 · P2 · confirmed: Swift 6 readiness, 10 concurrency diagnostics in the app**

- **Where:** `Sources/VibeSwitcher/MainWindow/Chat/ToolViews.swift:351-417` (`ImageCache` sends `NSImage` across isolation), and `InspectorView.swift:152` ([E-19](#e-19)).
- **Evidence:** §1, where the build log says "this is an error in the Swift 6 language mode".
- **Impact:** without Swift 6 mode, every race in this report had to be found by hand.
- **Fix:** pass `CGImage`, or wrap the `NSImage` in an `@unchecked Sendable` box with a comment saying why. Then enable `-strict-concurrency=complete` target by target, VibeCore first.

<a id="e-32"></a>**E-32 · P2 · confirmed: test coverage gaps.** See [Test coverage gaps](#test-coverage-gaps) below.

### P3: polish

<a id="e-33"></a>**E-33 · P3 · confirmed (code path): quitting blocks main for ~5 s, and the CLI watchdogs only send SIGTERM**

- **Where:** `Sources/VibeSwitcher/AppDelegate.swift:682-684` (`restoreHiddenWindows(timeout: 1)`, then `phoneAccess.shutdown()` → `TailscaleCLI.stopServing(…, timeout: 4)`), `Sources/VibeSwitcher/Tailscale.swift:117` (`let watchdog = DispatchWorkItem { process.terminate() }`).
- **What happens:** a child that ignores SIGTERM, or a grandchild holding stdout, makes quit (and every `--install` relaunch) wait indefinitely.
- **Fix:** escalate to SIGKILL after a grace period, as `Shell.run` does, and bound the pipe-reader waits.

<a id="e-34"></a>**E-34 · P3 · confirmed: `runAppleScript`'s `timedOut` flag is written by the watchdog thread and read unsynchronised**

- **Where:** `Sources/VibeSwitcher/TerminalBridge.swift:332-349`.
- **What happens:** a script finishing right at the deadline can be reported as a timeout, which feeds [E-08](#e-08).
- **Fix:** use a lock or atomic, or decide from `terminationReason == .uncaughtSignal`.

<a id="e-35"></a>**E-35 · P3 · confirmed: the hook redacts the whole text before clipping it to 280 characters**

- **Where:** `Sources/VibeCore/HookState.swift:174`.
- **Code:**
  ```swift
  let flat = Redaction.secrets(in: text).split(...)
  ```
- **Evidence:**
  - A 2M-character prompt took 1.42 s in the §3 probe (debug build).
  - A probe of the real regexes on pathological repeats took 2.46 s for `"refresh_token_"`×2000 (28 KB) and 2.2 s for `"token"`×3200 (16 KB).
  - That is still under the 5 s hook timeout, but it is time charged to the agent.
- **Fix:** clip first (keep a margin of, say, 4× the limit), then redact.

<a id="e-36"></a>**E-36 · P3 · confirmed (code path): `.task(id:)` bodies write `@State` after awaiting a detached task, without checking for cancellation**

- **Where:** `Sources/VibeSwitcher/MainWindow/InspectorView.swift:110`, `SessionHeaderView.swift:54`, `TerminalPane.swift:275-277`.
- **Code:**
  ```swift
  branch = await Task.detached(priority: .utility) { GitBranch.current(in: cwd) }.value
  ```
- **What happens:** after a quick switch, the previous session's branch or mirror screen lands in the new view.
- **Fix:** add `guard !Task.isCancelled else { return }` after the await, as `ActivityView` already does.

<a id="e-37"></a>**E-37 · P3 · confirmed: `.receive(on: RunLoop.main)` only delivers in the default run-loop mode**

- **Where:** `Sources/VibeSwitcher/AppDelegate.swift:212-245`, `MainWindow/MainWindowController.swift:127-148`.
- **What happens:** while a menu is tracking or an `NSAlert.runModal` is up, the menu bar icon and the window model stop updating.
- **Fix:** use `.receive(on: DispatchQueue.main)`, or drop it (the publishers already fire on main).

<a id="e-38"></a>**E-38 · P3 · plausible: smaller MCP and host issues**

- **SIGPIPE in the MCP server:** `vibeswitcher-mcp` doesn't ignore SIGPIPE and writes replies with `FileHandle.write`. A reply written after Claude closes the pipe kills the server; the outcome is harmless because the client is gone.
- **Call-id collision:** `MCPServer.swift:95` keys running calls by `"\(id)"`, so the ids `1` and `"1"` collide and a cancel can hit the wrong call.
- **Shutdown race:** `HostServer.swift:202-205` checks for live sessions only when the request arrives. A spawn inside the following 100 ms is accepted and then torn down.
- **Host zombie:** `HostClient.swift:135` registers the exit source after `posix_spawn`, so a host that exits instantly can stay a zombie. `HostedSession` has a WNOHANG poll for exactly this case.
- **Fix:** `signal(SIGPIPE, SIG_IGN)` in the MCP main; key calls by the JSON value; add a `shuttingDown` flag; add the same exit poll.

<a id="e-39"></a>**E-39 · P3 · confirmed (code path): more quiet failures**

- **Test timeout:** a merge test that times out is reported as an ordinary test failure; the words "timed out" never appear (`Worktrees.swift:77,211`).
- **Timeout not enforced:** `signalFamily` does nothing when `ProcessTable.snapshot()` returns `[:]`.
- **Push payloads:** they aren't size-capped (`PhoneAccess.swift:821-827`); a body over ~3.9 KB gets a 413, which is dropped silently.
- **`checkChromeAccess`:** results can land out of order (`PhoneAccess.swift:220-224`).
- **Lock-file race:** `SessionScanner.swift:103-104` deletes `<tty>.json.lock` while a hook may hold it, so two hooks can lock different inodes. Low odds: it only happens for a tty that has been dead for 15 s.
- **Fix:** add a `timedOut` flag to `Git.Result`; fall back to `process.terminate()`; clip push bodies to ~3 KB; use a serial queue plus generation for the Chrome check; never delete lock files.

<a id="e-40"></a>**E-40 · P3 · confirmed: cosmetic warnings**

- **Where:** `PreviewProxy.swift:165` (unused `upgrade`), `RemoteServer.swift:78` (`self` captured, never read).
- **Fix:** delete them, so the warning list stays meaningful.

---

## 5. Crash-risk review: what was checked and found safe

These candidates were reviewed against their callers and judged unreachable:

- **`SessionOrdering.swift:59, 62, 73` (`screenPosition!`):** `readingOrder` is called only on the `placed` subset (`screenPosition != nil`).
- **`HostProtocol.swift:22` (`precondition(payload.count <= maxPayload)`):** every caller checks `maxPayload` first, and output is chunked to `maxPayload - 16`.
- **`WebPush.swift:95` (`SecRandomCopyBytes` precondition):** practically unreachable.
- **`HostClient.swift:53`, `LeadController.swift:39` (`Bundle.main.executableURL!`):** always set for an app.
- **`PhoneAccess.swift:710` (`key!`):** guarded by `text != nil || key != nil` two lines up.
- **`try!` regexes (`Redaction.swift:38`, `TypedText.swift:6,9`, `StatusRules.swift:72`):** constant patterns, compiled and exercised by the tests.
- **`fatalError` in `init?(coder:)` (3 sites):** never used (no nibs).
- **`Spaces.swift` `unsafeBitCast` of private CGS symbols:** these are looked up with `dlsym` and checked for nil before the cast.
- **Host frame decoder:**
  - the length is checked before slicing, with no 32/64-bit overflow;
  - `Data` slices are rebased (`Data(x.dropFirst(n))`);
  - cols and rows are clamped to 1000×500 before the `UInt16` conversion;
  - history lines are clamped to 1…5000;
  - `Scrollback.page` handles `Int.min`.
- **Sockets:**
  - socket mode 0600, `getpeereid` uid check, the path-length check includes the NUL;
  - `SO_NOSIGPIPE`, `O_NONBLOCK` and `FD_CLOEXEC` on every socket;
  - sessions are spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`;
  - short writes are looped in all three flush paths.
- **Peer-driven memory:** bounded. Host output queue 16 MB (then resync), control queue 64 MB, replay 1 MB, HTTP heads 16/64 KB, bodies 64 KB, preview proxy 512 connections, remote server 32 connections.
- **VibeCore parsers:** fuzzed with 200,000 adversarial strings (CRLF, NUL, combining marks, ZWJ emoji, fences, pipes, `❯/›` menus, quotes) plus 100,000 `OutputRing` cycles, with no trap. The targets were `MarkdownBlocks`, `ScreenMenu`, `TerminalInput`, `SyntaxHighlight` (4 languages), `TypedText`, `LineDiff`, `AppleScriptStrings`, `FuzzyMatch`, `RunnableCommand`, `Scrollback`, `GuardedTyping` and `OutputRing`.
- **Args only unsafe when non-default:** `LineDiff.hunks` with a negative context, `GuardedTyping.chunks(size: 0)`, and `SessionDigest` with `limit < 24` are unsafe only for such values, and all callers pass constants.
- **App concurrency checked and sound:**
  - `HostClient` / `HostConnection` run entirely on main;
  - `RemoteServer`'s NW handlers run on its serial queue and hop to main;
  - all `PhoneAccess` mutable state is written on main;
  - `SessionStore`'s scan-queue/main split holds, and the `scanning` flag prevents overlap;
  - `ChatModel` applies results with a generation check;
  - `DevPreviews`, `FocusLog`, `HangWatchdog` and `Breadcrumbs` are locked or serial;
  - no `DispatchQueue.main.sync` is reachable from main, and no semaphores wait on main.
  - **Latent risk:** `focusLock` is held across `main.sync` (`RemoteInput.swift:81-86`, via `bringToFrontAndWait`). That is safe today only because nothing on main takes `focusLock`, so it is worth a comment or a `dispatchPrecondition`.

## Test coverage gaps

Method: for each `Sources/VibeCore/*.swift`, count the tests that mention its types, and list its `func`s that no test names. This is a reference count, not line coverage.

- **Tests:** 5,687 lines.
- **Sources:** VibeCore 8,386 lines; VibeHost 764; the hook 48; the host binary 68; MCP 132; **app 11,602**.

**VibeCore logic with no or near-no tests:**

| File | Lines | Test references | What's untested |
|---|---|---|---|
| `SessionScanner.swift` | 120 | **0** | All of it: one session per TTY, choosing the oldest agent process, `isCurrent` (stale state from an earlier agent), deleting state files after 15 s, the caches. It can't be tested because `VibePaths.stateDir` is hard-wired ([E-30](#e-30)), yet it decides which sessions exist |
| `Paths.swift` | 34 | **0** | `ensurePrivateDirectories` (0700 fix-up), `stateFile` |
| `HostConnection.swift` | 115 | 2 (fixture use only) | Partial frames, `onClose` on EOF, oversized-request drop ([E-29](#e-29)), flush before close ([E-06](#e-06)) |
| `TypedText.swift` | 58 | 1 | `attribute`, `isInjected` |
| `ProcessTable.swift` | 151 | 4 | `trySnapshot` (ENOMEM retry), `ancestors`, `readArguments` (the KERN_PROCARGS2 parse), `makeInfo` |
| `HookInstaller.swift` | 119 | 6 (pure transforms only) | `install`, `uninstall`, `readConfigThrowing` (comments, whitespace, non-object), `backupOnce`, `writeConfig` (symlinks, [E-13](#e-13)) |
| `HookState.swift` | 181 | 4 call sites of `reduce` | `clip`, `inferNotificationType`, the `idle_prompt`-after-Stop suppression, session/pid mismatch resets |
| `SyntaxHighlight.swift` | 153 | 4 | `isInsideWord`, `stringEnd` |
| `PreviewCookieJar.swift` | 59 | 6 | `cookieHeader`, `httpDate` |
| `MarkdownBlocks.swift` | 217 | 23 | `cells`, `delimiterRow`, `fenceMarker`, `isRule`, `listItem` (exercised only through `parse`) |
| `PreviewGate.swift` | 250 | 54 | `hasClearFraming`, `isUpgrade`, `isSlotCookie`, `localPath`, `cookieName` (security-relevant; covered only indirectly) |
| `ChatTranscript.swift` | 588 | 75 | `execCommand`, `exitCode`, `claudeImage`, `dataURLImage` |
| `LeadWorkflow.swift` | 156 | 12 | CRLF, BOM and unreadable files ([E-04](#e-04)) |
| `LaunchPresets.swift` | 151 | 32 | Decoding of partial or newer files ([E-01](#e-01)) |
| `RunnableCommand.swift` | 40 | 10 | Inline comments, quotes, `&`, compound statements ([E-10](#e-10)) |
| `Steer.swift` | 172 | 52 | Over-limit delivery ([E-05](#e-05)) |
| `Worktrees.swift` | 266 | 85 | `signalFamily`, `currentBranch`, cancellation mid-merge ([E-12](#e-12)), concurrent merges ([E-03](#e-03)) |

**Executables and the app:**

- **`vibeswitcher-hook/main.swift`:** no tests. The exit-0 / silent-stdout contract and the steer reply are untested end to end; §3 shows how to do it with a root override.
- **`vibeswitcher-mcp/main.swift`:** `HostRuntime` has no tests. Its `try?` swallowing ([E-09](#e-09)) is exactly what a test with a fake host would catch.
- **App target `VibeSwitcher` (11,602 lines):** there is no test target at all. Logic that isn't UI but lives here:
  - `SessionStore.apply` (status transitions, unseen/acknowledged, banners);
  - `TerminalBridge` result handling;
  - the `PhoneAccess` request handlers (919 lines: auth and input routing);
  - the `ChatModel` generation logic;
  - `HookBinary.sync`.

  Moving the pure parts into VibeCore, as was done for `WindowRows` and `MenuBarDots`, is the cheapest way to cover them.

---

## Top 10 to fix first

Ranked by user impact × likelihood, not by severity label alone.

1. **[E-04](#e-04)** `workflow.md` CRLF, BOM or bad byte → merges skip the tests silently. Normalise line endings, read lossily, and make "no test command" explicit. (`LeadWorkflow.swift:25`)
2. **[E-09](#e-09)** MCP host errors read as "no sessions" or "killed" → a second worker in the same worktree, `worktree remove --force` under a live agent. Make `sessions()` and `kill` throw. (`vibeswitcher-mcp/main.swift:48,81`)
3. **[E-06](#e-06)** `HostCall.send` closes before flushing → lead and system messages over ~8 KB are lost but reported as typed. Flush, or ack, before closing. (`SessionDigest.swift:97`)
4. **[E-05](#e-05)** Steered messages cut at ~9 KB and later ones dropped, while marked delivered. Take only what fits and leave the rest queued. (`Steer.swift:62,170`)
5. **[E-01](#e-01)** One bad field in `presets.json` → the user's presets are replaced and then overwritten. Lenient decode, a `.corrupt` backup, never auto-save over an undecodable file. (`LaunchPresets.swift:102`)
6. **[E-08](#e-08)** One AppleScript timeout wipes all Terminal tabs for a cycle → reordering, wrong ⌃N jumps, repeated "done" banners. Keep the previous tabs on failure. (`TerminalBridge.swift:71`, `SessionStore.swift:177`)
7. **[E-07](#e-07)** Pastes over 1 MB are silently cut or holed in window sessions. Backpressure instead of dropping. (`HostedSession.swift:169`)
8. **[E-10](#e-10)** Run on a code block can execute a different command than shown (inline `#`, quotes, `&`). Refuse unsafe blocks. (`RunnableCommand.swift:28,38`)
9. **[E-11](#e-11)** + **[E-14](#e-14)** + **[E-19](#e-19)** Main-thread blocking: Accessibility calls in `AppStatus.write`, git in `startLead`, the "detached" transcript read. Move them off main. (`AppStatus.swift:28`, `LeadController.swift:92`, `InspectorView.swift:152`)
10. **[E-02](#e-02)** + **[E-12](#e-12)** + **[E-03](#e-03)** Rare but severe: ignore SIGPIPE in the app; don't let cancellation kill `rebase --abort`; read the `update-ref` old value before the ancestry check. (`CodexTrust.swift:40`, `Worktrees.swift:72,238`)

Next after these: make `VibePaths` overridable and add a `SessionScanner` test ([E-30](#e-30), [E-32](#e-32)); give the hook its own `alarm` and a non-blocking `flock` ([E-28](#e-28)); resolve symlinks in `HookInstaller` ([E-13](#e-13)).
