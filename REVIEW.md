# Reviewing VibeSwitcher

The owner's word for verifiers and the risk check. It is read from the base branch only: a branch's own edits to it
count from the merge on.

## What fails here (Important)

- Main-thread stalls: blocking work (disk, git, a process, a lock, a host call) on the main thread or in a SwiftUI
  body. A frozen menu bar is the worst bug this app has.
- Anything that touches real sessions, windows or the user's home: typed or steered input reaching a real session,
  real windows hidden or moved across Spaces, writes outside a scratch home in tests, the installed app or Keychain.
- Secrets in logs: tokens, keys, phone pairing codes or a session's screen in a log line, a crash report, a prompt to
  headless Claude or anything leaving the Mac. Redact before it is written.
- Tests that pass alone but not under load: a fixed sleep or wall-clock window, a wait on anything but the event
  itself. Run new tests under scripts/test-under-load.sh.
- The lead's guard rails: a review level, a verdict, a guarded setting or sensitive_paths that a worker can loosen
  from its own branch or through board.json.
- Processes, locks and threads left behind, or held across a call that can wait on the user.

## What to ignore

- The lead's records in docs/lead (decisions, progress, incidents): the lead writes them, not the branch.
- Snapshot images' pixel noise, and formatting a tool would fix.

## What is a Nit

Copy, naming and comments, unless the copy is wrong about what the code does or the user is told something false.
Never hold a merge for one.

## How to report

- Each finding: file:line (from the repository root) and what shows it (the command and its output, or what that
  line does).
- An Important finding gives a failure scenario: this input or state gives this wrong result, stall or crash.
- End with a summary line: the count by severity ("2 Important, 3 Nit"), or "no issues".
