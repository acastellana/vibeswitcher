# VibeSwitcher docs

Start with the [README](../README.md) for what VibeSwitcher is and how to install it. The guides below go into each
area in depth; the records further down are history, kept as written.

## Guides

| Guide | What's in it |
| --- | --- |
| [Getting started](guide/getting-started.md) | Requirements, building and signing, the keychain dialog, the first run, troubleshooting, where the logs are. |
| [Everyday use](guide/everyday-use.md) | Statuses, the menu bar, the main window, starting sessions, the chat, notifications, briefings, the command line. |
| [The project lead](guide/project-lead.md) | How a lead plans, the task contract, workers in worktrees, review levels and audits, the merge gate, auto_advance, Mac-wide limits, the battery hold, receipts, revert, the board archive, and a table of every default with its source. |
| [Phone access](guide/phone-access.md) | Tailscale, pairing, what the phone shows, replies and answering a lead, dev pages, how it's kept safe. |
| [Architecture](guide/architecture.md) | The app, the session host and its handover, parsers, hooks, status detection, the tool server and its keeper, the vault and roles, the host's security model and the census, privacy, the files in `~/.vibeswitcher`. |
| [Development](guide/development.md) | Worktree setup, `scripts/test.sh`, the lints, tests under load, the sandbox, other scripts. |

The rules for agents working in this repository are in [AGENTS.md](../AGENTS.md); what a reviewer checks is in
[REVIEW.md](../REVIEW.md). Screenshots used by the guides are in [images](images), taken from the sandbox.

## Records

These are records of how the project was run and checked. They describe the state when each was written; the guides
describe the app today.

### The lead's record: [lead/](lead)

Written by the project lead, and only by it.

- [decisions.md](lead/decisions.md): the lead's decisions and why, newest last.
- [decisions-archive.md](lead/decisions-archive.md): superseded or obsolete decisions, moved there unchanged.
- [progress.md](lead/progress.md): what was planned, merged and reported, as it happened.
- [incidents.md](lead/incidents.md): setbacks and the check each one became.

### Process: [process/](process)

- [lead-rules.md](process/lead-rules.md): every rule the lead follows, and what enforces each.
- [verifier-eval.md](process/verifier-eval.md): the verifier's evaluation set, built from real misses.

### Security: [security/](security)

- [SECURITY-AUDIT.md](security/SECURITY-AUDIT.md): the audit of the session host from PR #1. Its file and line
  references are to the code before the fixes.
- [SECURITY-FIXES.md](security/SECURITY-FIXES.md): the fixes made for it; its "Changes made when landing PR #1" section
  records where the landed code differs from the sections above it.
- [PUBLICATION-REVIEW.md](security/PUBLICATION-REVIEW.md): a scan of the repository and its history for
  secrets before the security fixes were published.

### Evaluations and benches: [eval/](eval)

Audits, measurements and the screenshots taken for them, each dated.

- [engineering.md](eval/engineering.md), [runtime.md](eval/runtime.md), [ux.md](eval/ux.md),
  [security.md](eval/security.md): the four evaluations of 2026-10-17; [open-2026-10-19.md](eval/open-2026-10-19.md)
  re-checks their open items.
- [memory-2026-10-22.md](eval/memory-2026-10-22.md), [messaging-2026-10-22.md](eval/messaging-2026-10-22.md),
  [processes-2026-10-22.md](eval/processes-2026-10-22.md), [ui-2026-10-22.md](eval/ui-2026-10-22.md): the audits of
  2026-10-22.
- [chat-bench-settle-2026-10-20.md](eval/chat-bench-settle-2026-10-20.md) and
  [runtime-data/idle-bench.md](eval/runtime-data/idle-bench.md): benches.
- [stop-hook-shapes](eval/stop-hook-shapes/README.md): how a message delivered at the end of a turn shows in Claude
  Code.
- [logo](eval/logo/README.md): the app icon concepts and the one picked, A · Stack.
- [questions](eval/questions/questions.md), [ux-fixes](eval/ux-fixes), [ux](eval/ux), [activity](eval/activity):
  screenshots and notes from UI work.

### Plans and specs: [superpowers/](superpowers)

Design specs and implementation plans from the early features (the window, the session host, the chat, the project
lead, phone history and dev previews), in [plans](superpowers/plans) and [specs](superpowers/specs).
