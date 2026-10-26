# Review rules for VibeSwitcher

## Important
- A host call, git, disk read, lock or wait on the main thread: give the call path from the UI event to it.
- An AppKit object (NSFont, attributed string, view) two threads can reach: a shared NSFont leaked and raced once.
- One session's state kept in a value all sessions share: switch to another session and back, and check it resets.
- A queue or buffer fed by a session's output or the user's input with no bound.
- A test that passes alone but fails in the full suite or under scripts/test-under-load.sh, or that waits on a pipe,
  process or file with no time limit.
- A test that reaches the real home: ~/.vibeswitcher, the host socket, the Mac-wide test lock (a default argument
  counts), real sessions or real windows.
- A secret, token, pairing code or session screen in a log line, an error text or a headless Claude prompt.
- A change to a role's allow or deny rules: try each allowed command with options that read or write elsewhere
  (--remote, --exec, --add-file, -o, a symlinked folder). One escape is Important.
- Branch code that merge runs (test scripts, the harness) able to reach host.sock, the vault or the lead's files.
- A setting or hold read once, then acted on after a step that takes minutes (a merge, a test run).

## Nit, never more
- Copy, naming, comments, blank lines, a doc comment that slid off its function, line length.

## Report
- Each finding: file:line from the repository root, and the command or the code that shows it.
- An Important finding gives its failure scenario: this input or state gives this wrong result, stall or crash.
- Last line: the count by severity ("2 Important, 1 Nit"), or "no issues".
