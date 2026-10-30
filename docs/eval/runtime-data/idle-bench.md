# Idle CPU and memory (R3, R7, R8), 2026-10-18

Method: `CFFIXED_USER_HOME=$(mktemp -d "$TMPDIR/vsb.XXXX") .build/release/VibeSwitcher --idle-bench 20 --sidebar --transcript <12 MB transcript>`
(a short home folder: the private session host's socket path must fit). Release builds; "before" is ebd2522 with only
the bench added. In-process, nothing touches the real app or `~/.vibeswitcher`. The bench runs 7 made-up agent
sessions through the real `SessionStore` (one with a background shell), a private session host with 5 shells (one
spins its title like a working agent), the hang watchdog, the lead controller and the main window off screen.
Each phase settles 5 s, then is measured.

| phase | before | after (with fix-the-chat-layout applied) |
|---|---|---|
| window open, chat | 20.9–24.9 % CPU, 43–49 wakeups/s, sections published ~10/s | 1.1–1.8 %, 18–19/s, 0 |
| window open, terminal | 15.1–15.2 %, 25–28/s | 0.6–1.2 %, 18/s |
| window closed | 0.34–0.80 % | 0.20 % |
| window closed, sidebar on | 0.41–0.88 %, 12.8–13.5 wakeups/s | 0.19–0.21 %, 7.9–8.1/s |
| attached terminals holding a drawing (5 attached, 1 shown) | 5 (~39.5 MB) | 1 (~7.9 MB) |

What remains when closed is the hang watchdog's 4 Hz beat and 1 Hz snapshot (not changed here).

Chat memory, `--chat-bench` on the 3 largest transcripts (max RSS / peak footprint, plain):

| transcript | rows | before (page 120) | after (page 60) |
|---|---|---|---|
| cb896e2c, 129 MB | 32 | 123 / 76 MB | 123 / 75 MB (peak is the parse at open; 55 MB after) |
| c75103a3, 108 MB | 89 | 160 / 115 MB | 125 / 77 MB |
| 801dfe04, 82 MB | 184 | 161 / 106 MB | 111 / 63 MB |

`scripts/chat-bench-settle.sh -n 3` (6d824633 → cb896e2c, all widths, scenarios and variants) on this branch with
fix-the-chat-layout applied: 64 of 64 cases settled 3/3, as with fix-the-chat-layout alone.

## The UI bench's verdict: relative to a base, and only at low load (2026-10-19)

`scripts/ui-bench.sh` (the window with two leads on a scratch home: clicks, busy leads, then MINUTES idle) used to
fail when the idle phase ran over 50 M instructions/s. That line was measured on a quiet Mac (30 M), and the rate
rises with the Mac's load: on 2026-10-19 ~11:30, at load 30–90, project-lead itself ran 77–79 M and the branch under
review 73–78 M, so both failed and the verdict said nothing about the branch (CPU %, under 2 %, passed on both).
The same run also crashed once in the harness itself: the made-up process table was built with
`Dictionary(uniqueKeysWithValues:)`, and a lead started again could draw the pid its old session's agent still held
("Duplicate values for key: '60176'"). The table now keeps one process per pid and each agent started gets a pid of
its own (`UIBench.processTable`, tested with colliding pids).

How it judges now:

- `scripts/ui-bench.sh -B main [-r ROUNDS] [-t PCT] MINUTES` builds the base once a run (a `git archive` of the
  ref in the run's scratch folder under /tmp, removed on exit: never in the worktree, where its AGENTS.md and CLAUDE.md
  would hold a verifier on a trust question; `-B` also takes a built binary) and runs base and branch alternately,
  ROUNDS times each (2), each in a fresh scratch home, so both see the same load. The branch's idle instructions/s
  (median of its runs) may be at most PCT % (20) over the base's: `PASS/FAIL  idle: B M instructions/s, the base
  A M (+x %; at most +20 %; medians)`. Logs: `.build/ui-bench/{base,branch}-N.log`.
- The 50 M line is shown, not checked (`INFO  idle: … (50 M on an idle Mac's budget)`); each run prints its rate as
  `RESULT idle-instructions-per-second N`.
- Over `scripts/test-under-load.sh`'s threshold (1-minute load over 2 × ncpu) it doesn't judge: at the start it
  runs nothing, says so and exits 0; if the load goes over it during the runs, instructions/s is left unjudged (with
  a note) and the other checks still count.
- The exit status is the branch's: its failed checks or crash. A base run that fails or crashes is a note; with no
  base rate, instructions/s is left unjudged. Without `-B` the rate is shown only.
- The other checks keep their own lines: SwiftUI faults on clicks, a switch under 2.5 G instructions, idle CPU under
  2 %, RSS growth at most 10 % after the first minute.
