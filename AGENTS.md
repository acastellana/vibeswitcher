# VibeSwitcher: rules for agents

## Hard rules (they protect the user's Mac, sessions and app; nothing else enforces some of them)

- Type or steer input only into fake ttys (`Tests/VibeSwitcherTests/FakeClaude.swift`) or the sandbox, not a real
  session: a test once answered another session's open question.
- Hide, show or move only scratch windows, not real ones: moving windows across Spaces stranded the user's terminals.
- Don't attach a debugger or inspect another process (lldb, debugserver, sample, leaks, spindump): each puts a password
  dialog on the user's screen. Use `dyld_info -disassemble` and ~/Library/Logs/DiagnosticReports instead.
- Keychain (`security`, SecItem): scratch keychain files only, made never to lock (`scripts/lib/scratch-keychain.sh`), no-UI on every SecItem call, no access-list calls, never kill a process in a keychain call, live probes only with the user at the keyboard: on 2026-11-26 dialogs hit the user's screen and a killed probe crashed securityd, locking the login keychain.
- Leave /Applications/VibeSwitcher.app and the user's running app alone: check UI in the sandbox below.
  `scripts/build-app.sh --install` relaunches the user's app, so it's the user's call.
- Install nothing (brew, npm -g, pip, apps): ask the user.

## Commands

```sh
bash scripts/worktree-init.sh                       # first, in a new worktree
bash scripts/test.sh --filter LeadBoardTests        # focused tests on a scratch home (a bare swift test refuses to run)
vs-heavy bash scripts/test.sh                       # full suite, only when asked; vs-heavy: Mac-wide slots for heavy work
bash scripts/test.sh --filter 'LintTests/'          # every lint suite, before reporting done
scripts/test-under-load.sh --load $((2 * $(getconf _NPROCESSORS_ONLN))) -r 3 -f 'NewTests'   # new or changed tests, under load (2 × cores, the script's cap), before reporting done
bash scripts/test.sh --perf                         # benches, only on a calm Mac
bash scripts/e2e/wallet-e2e.sh                      # on demand: sandbox → loop passage → ~/dev/wallet-manager and back; its header lists the cases
```

UI changes: show them in the sandbox, each step its own command: `bash scripts/sandbox-app.sh run`, then
`bash scripts/sandbox-app.sh chat` (or `type TEXT`, `send`, `settings TAB`, `sheet NAME`; `help` lists them),
`bash scripts/sandbox-app.sh shot NAME` (light and dark PNGs in .build/sandbox-shots/), `bash scripts/sandbox-app.sh quit`.
A new sheet goes in the sheet list in `Sources/VibeSwitcher/Sandbox.swift`.

## Practices

- A test waits on the event it checks (a file, a reply, a semaphore, an injected clock): a fixed sleep races on a busy Mac.
  Helpers: each target's TestSupport.swift (`eventually`/`until`, `hangGuard`, `offPool`, `Scratch`); `LeadTeamFixture` in LeadToolsetTests.
- TemporaryFolderLint: a test's files go in a `Scratch` (a socket: `shortFolder`), never `/tmp` or `temporaryDirectory`.
- Show a fix's test failing without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, test, then without `-R`.
- A failed merge's log is copied into the task's worktree, `.vibeswitcher/merge-failure/`: `~/.vibeswitcher/lead` is refused.
- `docs/lead/` is the lead's record: only the lead edits it.
