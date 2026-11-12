# VibeSwitcher: rules for agents

## Hard rules (they protect the user's Mac, sessions and app; nothing else enforces some of them)

- Type or steer input only into fake ttys (`Tests/VibeSwitcherTests/FakeClaude.swift`) or the sandbox, not a real
  session: a test once answered another session's open question.
- Hide, show or move only scratch windows, not real ones: moving windows across Spaces stranded the user's terminals.
- Don't attach a debugger or inspect another process (lldb, debugserver, sample, leaks, spindump): each puts a password
  dialog on the user's screen. Use `dyld_info -disassemble` and ~/Library/Logs/DiagnosticReports instead.
- Leave /Applications/VibeSwitcher.app and the user's running app alone: check UI in the sandbox below.
  `scripts/build-app.sh --install` relaunches the user's app, so it's the user's call.
- Install nothing (brew, npm -g, pip, apps): ask the user.

## Commands

```sh
bash scripts/worktree-init.sh                       # first, in a new worktree
bash scripts/test.sh --filter LeadBoardTests        # focused tests on a scratch home (a bare swift test refuses to run)
vs-heavy bash scripts/test.sh                       # full suite, only when asked; vs-heavy: Mac-wide slots for heavy work
bash scripts/test.sh --filter 'LintTests/'          # every lint suite, before reporting done
scripts/test-under-load.sh --load 24 -r 3 -f 'NewTests'   # new or changed tests, under load, before reporting done
bash scripts/test.sh --perf                         # benches, only on a calm Mac
bash scripts/e2e/wallet-e2e.sh                      # on demand: sandbox → loop passage → ~/dev/wallet-manager and back, 5 cases
```

UI changes: show them in the sandbox, each step its own command: `bash scripts/sandbox-app.sh run`, then
`bash scripts/sandbox-app.sh chat` (or `type TEXT`, `send`, `settings TAB`, `sheet NAME`; `help` lists them),
`bash scripts/sandbox-app.sh shot NAME` (light and dark PNGs in .build/sandbox-shots/), `bash scripts/sandbox-app.sh quit`.
A new sheet goes in the sheet list in `Sources/VibeSwitcher/Sandbox.swift`.

## Practices

- A test waits on the event it checks (a file, a reply, a semaphore, an injected clock): a fixed sleep races on a busy Mac.
- Show a fix's test failing without the fix: `git diff <pre-fix> HEAD -- <fix files> | git apply -R`, run the test,
  then re-apply with the same command without `-R`.
- Long or many-core jobs (full suites, release builds, mutation testing, fuzzing, VMs, load and perf runs) run under
  `vs-heavy`: VibeSwitcher tells the lead of one that holds several cores for minutes outside it.
- `docs/lead/` is the lead's record: only the lead edits it.
