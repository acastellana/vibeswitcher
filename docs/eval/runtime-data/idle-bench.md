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
