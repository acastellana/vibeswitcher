# VibeSwitcher: rules for agents

## Hard rules

- Never type or steer input into a real session: use fake ttys (`Tests/VibeSwitcherTests/FakeClaude.swift`) or the sandbox.
- Never hide, re-show or move real windows across Spaces: use scratch windows only.
- Never attach a debugger or inspect another process (lldb, debugserver, sample, leaks, spindump): each puts a password
  dialog on the user's screen. Use `dyld_info -disassemble` and ~/Library/Logs/DiagnosticReports instead.
- Never touch /Applications/VibeSwitcher.app or the user's running app: check UI in the sandbox below.
  `scripts/build-app.sh --install` relaunches the user's app, so it's the user's call.
- Never install anything (brew, npm -g, pip, apps).
- Run tests only through `scripts/test.sh` (a scratch home), never a bare `swift test`.
- Show a fix's test failing without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, run the test,
  then re-apply with the same command without `-R`.

## Commands

```sh
bash scripts/worktree-init.sh                       # first, in a new worktree
bash scripts/test.sh --filter LeadBoardTests        # focused tests (swift test options pass through)
vs-heavy bash scripts/test.sh                       # full suite, only when asked; vs-heavy: Mac-wide slots for heavy work
# lints, before reporting done:
bash scripts/test.sh --filter 'AccessibilityLint|DebugAidsLint|HomePathLint|KeychainLint|PreferencesLint|PrivateWriteLint|ScriptScratchLint|SecretShapeLint|TemporaryFolderLint'
scripts/test-under-load.sh --load 24 -r 3 -f 'NewTests'   # new or changed tests, under load, before reporting done
bash scripts/test.sh --perf                         # benches, only on a calm Mac
```

UI changes: show them in the sandbox, each step its own command: `bash scripts/sandbox-app.sh run`, then
`bash scripts/sandbox-app.sh chat` (or `type TEXT`, `send`, `settings TAB`, `sheet NAME`; `help` lists them),
`bash scripts/sandbox-app.sh shot NAME` (light and dark PNGs in .build/sandbox-shots/), `bash scripts/sandbox-app.sh quit`.
A new sheet goes in the sheet list in `Sources/VibeSwitcher/Sandbox.swift`.

## Practices

- A test waits on the event it checks (a file, a reply, a semaphore, an injected clock), never on a fixed sleep.
- `docs/lead/` is the lead's record: only the lead edits it.
