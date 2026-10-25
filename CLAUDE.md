# VibeSwitcher: project map

A macOS menu bar app (Swift, SwiftPM, macOS 14+) that tracks Claude Code and Codex sessions, plus a session host that
keeps window sessions alive and a project lead that runs a team of worker sessions. This file is a map: it says where
things are and points to the docs. The user-facing behavior is in `README.md`; designs in `docs/superpowers/specs/`.
Every repository path named here is checked to exist by `Tests/VibeCoreTests/ProjectMapTests.swift`: keep them real.

## Hard rules

- Never test input on real sessions: typed or steered input goes to scratch or fake ttys only (`Tests/VibeSwitcherTests/FakeClaude.swift`, the sandbox).
- Never hide, re-show or move real windows across Spaces: scratch windows only (`Sources/VibeSwitcher/Spaces.swift` touches the user's desktops).
- Never attach debuggers (lldb, sample, leaks, spindump): they put a password dialog on the user's screen. Use `dyld_info -disassemble` and ~/Library/Logs/DiagnosticReports.
- Never touch /Applications/VibeSwitcher.app or the user's running app: use the sandbox (`scripts/sandbox-app.sh`). `scripts/build-app.sh --install` is the user's call.
- No installs: no brew, npm -g, pip or app installs.
- A fix's test is shown failing without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, run it, re-apply.
- Tests run on a scratch home only: `scripts/test.sh`, never a bare `swift test` on your home (it refuses).

## Targets (`Package.swift`)

- VibeCore (`Sources/VibeCore/`): shared model, status rules, the lead's board, tools and vault, git and worktrees, phone crypto. No UI.
- VibeHost (`Sources/VibeHost/`): the session host's internals: PTYs, replay buffers, the socket server, the vault's storage.
- VibeSwitcher (`Sources/VibeSwitcher/`): the menu bar app and the window (AppKit and SwiftUI).
- vibeswitcher-host (`Sources/vibeswitcher-host/main.swift`): background process that keeps window sessions alive across app restarts.
- vibeswitcher-hook (`Sources/vibeswitcher-hook/main.swift`): tiny binary Claude Code and Codex hooks run on every lifecycle event.
- vibeswitcher-mcp (`Sources/vibeswitcher-mcp/main.swift`): the lead's tool server (MCP over stdio) for the lead, workers and verifiers.
- Tests: `Tests/VibeCoreTests/`, `Tests/VibeHostTests/`, `Tests/VibeSwitcherTests/`, phone web tests `Tests/Web/` (node).

## Where things are

Project lead (VibeCore unless noted):
- Lead tools (add_task, start_worker, merge, report, …): defined and handled in `Sources/VibeCore/LeadToolset.swift`; MCP plumbing `Sources/VibeCore/MCPServer.swift`.
- Merge gate: `merge` in `Sources/VibeCore/LeadToolset.swift`, the git side `Worktrees.merge` in `Sources/VibeCore/Worktrees.swift`, one rerun of failing tests `Sources/VibeCore/MergeRerun.swift`, test slots `Sources/VibeCore/TestLock.swift`.
- auto_advance (finished work moves on without the lead's turn): `Sources/VibeCore/LeadAdvance.swift`.
- Board (tasks, contracts, reports, findings; board.json): `Sources/VibeCore/LeadBoard.swift`; per-task scorecard `Sources/VibeCore/LeadScorecard.swift`.
- workflow.md (limits, commands, role prompts): `Sources/VibeCore/LeadWorkflow.swift`; the user's working policy `Sources/VibeCore/WorkingPolicy.swift`.
- Vault and guard rails (roles, grants, approvals, verdicts, guarded settings): `Sources/VibeCore/LeadVault.swift` and `Sources/VibeCore/LeadVaultGuarded.swift`, `Sources/VibeCore/LeadVaultApprovals.swift`, `Sources/VibeCore/LeadVaultReviews.swift`; host side `Sources/VibeHost/VaultStorage.swift`.
- Witness (waits, stalls, stops without reporting, time budget): `Sources/VibeCore/LeadWitness.swift`, `Sources/VibeCore/LeadStall.swift`, `Sources/VibeCore/LeadBudget.swift`.
- Starting roles: `Sources/VibeCore/LeadLaunch.swift`; message delivery (steer vs type) `Sources/VibeCore/LeadDelivery.swift`; handover to a new lead `Sources/VibeCore/LeadHandover.swift`.
- Records (decisions.md, progress.md, incidents.md in `docs/lead/`): `Sources/VibeCore/LeadRecords.swift`.
- Base moves (user sessions committing to the lead's base): `Sources/VibeCore/LeadBaseMoves.swift`.
- Lead UI: `Sources/VibeSwitcher/MainWindow/Lead/`; controller `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift`.
- Team panel rows: built in `Sources/VibeSwitcher/MainWindow/Lead/TeamRows.swift`, drawn in `Sources/VibeSwitcher/MainWindow/Lead/TeamViews.swift` (TeamRowView, LeadTeamPane).

Session host:
- Host process and protocol: `Sources/VibeHost/HostServer.swift`, `Sources/VibeHost/HostedSession.swift`, `Sources/VibeHost/PTYSpawn.swift`, `Sources/VibeCore/HostProtocol.swift`.
- Screen parsing (status rows, pickers): `Sources/VibeHost/SessionParser.swift`; input ordering `Sources/VibeHost/InputOrder.swift`.
- App's client and restarts: `Sources/VibeSwitcher/HostClient.swift`, `Sources/VibeSwitcher/HostRestart.swift`; handover `Sources/VibeHost/HostHandover.swift`.

Sessions and status:
- Session list and attention: `Sources/VibeSwitcher/SessionStore.swift`; scanning `Sources/VibeCore/SessionScanner.swift`, `Sources/VibeCore/ProcessTable.swift`.
- Status detection: `Sources/VibeCore/StatusRules.swift`, `Sources/VibeCore/HookState.swift`; hooks setup `Sources/VibeCore/HookInstaller.swift`.
- Terminal.app bridge (AppleScript, tabs): `Sources/VibeSwitcher/TerminalBridge.swift`; desktops `Sources/VibeSwitcher/Spaces.swift`.
- Steering messages into a working agent: `Sources/VibeCore/Steer.swift`.

App UI:
- Startup and wiring: `Sources/VibeSwitcher/AppDelegate.swift`.
- Menu bar list `Sources/VibeSwitcher/PopoverView.swift`, sidebar `Sources/VibeSwitcher/Sidebar.swift`, floating panel `Sources/VibeSwitcher/FloatingPanel.swift`.
- The window: `Sources/VibeSwitcher/MainWindow/` (session list, terminal pane, inspector, start page, ⌘K palette, menus).
- Chat view and composer: `Sources/VibeSwitcher/MainWindow/Chat/`; transcript model `Sources/VibeCore/ChatTimeline.swift`, `Sources/VibeCore/ChatTranscript.swift`.
- New Project sheet: `Sources/VibeSwitcher/MainWindow/NewProject/`; Briefing: `Sources/VibeSwitcher/Briefing/`.
- Settings: `Sources/VibeSwitcher/SettingsWindow.swift`; stored preferences `Sources/VibeSwitcher/Preferences.swift`.
- macOS notifications: sent by `Notifier` in `Sources/VibeSwitcher/Preferences.swift`, wired in `Sources/VibeSwitcher/AppDelegate.swift` (store.onAttention, onNudge, controller.notify).

Phone Access:
- Server and pairing: `Sources/VibeSwitcher/PhoneAccess.swift`, `Sources/VibeSwitcher/RemoteServer.swift`, `Sources/VibeSwitcher/RemoteInput.swift`, `Sources/VibeCore/RemoteAccess.swift`.
- Push to the phone: `Sources/VibeCore/WebPush.swift`; dev-page proxy `Sources/VibeCore/PreviewProxy.swift`, `Sources/VibeCore/PreviewGate.swift`.
- The phone's web client: `Web/` (app.js, sw.js); its tests `Tests/Web/`.

Sandbox and test helpers:
- Sandboxed app for UI checks: `scripts/sandbox-app.sh`, app side `Sources/VibeSwitcher/Sandbox.swift` (add new sheets to its sheet list).
- Fake agent sessions: `Tests/VibeSwitcherTests/FakeClaude.swift`; scratch homes and folders: `Tests/VibeCoreTests/TestSupport.swift` (Scratch).
- Paths (everything under ~/.vibeswitcher): `Sources/VibeCore/Paths.swift`.

## Build and test

```sh
bash scripts/worktree-init.sh                       # first thing in a new worktree
bash scripts/test.sh --filter LeadBoardTests        # builds, then focused tests (swift test options pass through), scratch home
vs-heavy bash scripts/test.sh                       # full suite: only when the contract asks, under vs-heavy
bash scripts/test.sh --filter 'AccessibilityLint|DebugAidsLint|HomePathLint|KeychainLint|PreferencesLint|PrivateWriteLint|ScriptScratchLint|SecretShapeLint|TemporaryFolderLint'
scripts/test-under-load.sh --load 24 -r 3 -f 'NewTests'   # new tests under load, before reporting done
bash scripts/test.sh --perf                         # benches only, on a calm Mac
```

Sandbox (UI changes), each step its own command: `bash scripts/sandbox-app.sh run`, then
`bash scripts/sandbox-app.sh chat` (or `type TEXT`, `send`, `settings TAB`, `sheet NAME`; `help` lists them),
`bash scripts/sandbox-app.sh shot NAME` (light and dark PNGs in .build/sandbox-shots/), `bash scripts/sandbox-app.sh quit`.

Helpers: `Resources/bin/vs-heavy` (Mac-wide slots for heavy work), `scripts/lib/scratch.sh` (scripts' scratch TMPDIR).

## Deeper docs

- `README.md`: every feature as the user sees it, install, Phone Access, status detection, command line, development.
- `docs/superpowers/specs/2026-10-17-project-lead-design.md`: the project lead's design; other designs beside it, plans in `docs/superpowers/plans/`.
- `docs/eval/`: engineering, security, runtime and UX evaluations (`docs/eval/security.md`, `docs/eval/engineering.md`).
- `docs/lead/`: the lead's decisions and progress logs (the lead writes them; workers don't).
