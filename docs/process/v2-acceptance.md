# VibeSwitcher 2: acceptance run

The whole node, used as a person uses it, on the real node with a scratch project (`~/projects/vs-acceptance`: a
tiny calculator with one pytest test). Each row: what is run, what must happen, and the result of the last run. A
failure becomes a fix task (the supervisor's agents or the project's lead) and the row is run again.

`vs` is `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`. Sessions use the cheapest model (haiku) where a model
can be chosen.

| # | Area | Run | Must happen | Last run |
|---|---|---|---|---|
| A1 | Node | `vs status` | build, host, server, sessions, leads, cards; no error | pass (2026-11-20) |
| A2 | Node | `vs config held` / `config accept` | short card; accept clears it | pass |
| A3 | Web | `vs web`, open the address | sessions, chat, board, settings render; no console error | pass: page pairs and renders; console errors while a terminal shows (fix in progress) |
| A4 | Session | `vs new ~/projects/vs-acceptance --model haiku` | a Claude session starts, listed in status and on the page | pass after adding the folder to the project allow-list (by design; the refusal says how) |
| A5 | Session | `vs send S "say hello in three words"` | the agent answers; the chat shows it on the page | blocked: Claude's folder-trust dialog not read as a prompt (fix in progress) |
| A6 | Session | a permission prompt, `vs reply S 1` | the prompt shows as a card/field; reply answers it | fail: trust dialog → prompt nil → reply refuses (fix in progress) |
| A7 | Session | `vs send S "…" --now` while it works | steered mid-turn, nothing lost | |
| A8 | Session | `vs rename`, `vs pause`, `vs end` | name and pause shown; end removes it; resume lists it | |
| A9 | Session | `vs resume S` | the ended session comes back in its conversation | |
| A10 | Terminal | the page's Terminal tab on a hosted session | live, watch-only, keys go nowhere | pass: watch-only terminal shows the live screen |
| A11 | Lead | `vs lead ~/projects/vs-acceptance --goal "add a subtract function with a test"` | lead plans a task, starts a worker | pass: the lead planned one task and started its worker |
| A12 | Lead | `vs board`, `vs questions --wait` | the board shows the task; a question arrives as a card | pass: board shows the task and its blocker |
| A13 | Lead | `vs answer CARD …`, `vs tell FOLDER …` | delivered; the lead acts on it | fail: Claude Code 2.1.329's "Teach auto mode" popup blocks deliveries to the lead (fix in progress) |
| A14 | Lead | the task's audit and merge | two finders, the gate's tests (pytest), merged into main | fail → fixed by config: the merge's scratch HOME hides pip --user packages (general fix with the lead) |
| A15 | Lead | approval for a sensitive path | an approval card; `vs answer` approves the exact commit | |
| A16 | Lead | push request, `vs push` / `decline-push` | the card shows the URL without credentials; settles | |
| A17 | Settings | `vs settings FOLDER`, `vs set FOLDER max_workers 2` | shown; set recorded; the lead is told | |
| A18 | Presets | `vs presets`, `vs preset add …`, `config accept`, `vs new --preset` | strict rules; accept needed; starts | |
| A19 | Notifications | the page with notifications on | a question/prompt notifies; the title counts | |
| A20 | Restart | `vs stop`, `vs start`, accepts, `vs lead FOLDER --resume`, `vs reopen` | the lead returns in its conversation; own sessions reopen | |
| A21 | Switch | install a new build, `vs switch` | sessions survive the handover; hooks install after | |
| A22 | Security | from a session: `vibeswitcher answer …` | refused: not the user's voice | |
| A23 | Security | a page token tries `answer`/`send` | refused; only drafts | |
| A24 | Tests | `scripts/nightly.sh` on the merged v2 | full suite passes (retry-failed); flaky list filed | |
| A25 | Self-improvement | VS's own lead on its clone | merges its tasks through the gate; keeps a goal list | |
