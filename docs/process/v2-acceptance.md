# VibeSwitcher 2: acceptance run

The whole node, used as a person uses it, on the real node with a scratch project (`~/projects/vs-acceptance`: a
tiny calculator with one pytest test). Each row: what is run, what must happen, and the result of the last run. A
failure becomes a fix task (the supervisor's agents or the project's lead) and the row is run again.

Automated: `Tests/VibeNodeTests/NodeAcceptanceTests.swift` runs each row as a case named after it (`a1…`, `a2…`) on a
scratch node with FakeClaude, through the built command line with the typed codes; it runs in the Linux CI's core job
and the full suite, and alone with `scripts/e2e/node-acceptance.sh [A1 A14 …]`. The column below names each row's case.
The run on the real node with a real Claude (this document's own) stays: it finds what a fake can't.

`vs` is `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher`. Sessions use the cheapest model (haiku) where a model
can be chosen.

What landed on 2026-11-21 after these rows (Brief me, your own Codex sessions, sessions named by terminal or name,
resume's grace message, the page's Between leads, Statistics, health, dev servers, dictation, the Boost mark, the lead's
results and all-done card, `settings --find`, switch's up-front refusal) has no row yet: `docs/guide/v2-try-it.md`
walks through all of it for the user's first try, and its findings become rows here.

| # | Area | Run | Must happen | Automated (`NodeAcceptanceTests`) | Last run |
|---|---|---|---|---|---|
| A1 | Node | `vs status` | build, host, server, sessions, leads, cards; no error | `a1Status` | pass (2026-11-20) |
| A2 | Node | `vs config held` / `config accept` | short card; accept clears it | `a2ConfigHeldAndAccept` | pass |
| A3 | Web | `vs web`, open the address | sessions, chat, board, settings render; no console error | `a3Web` (the wire; the console in a browser by hand) | pass: page pairs and renders; console errors while a terminal shows (fix in progress) |
| A4 | Session | `vs new ~/projects/vs-acceptance --model haiku` | a Claude session starts, listed in status and on the page | `a4New` | pass after adding the folder to the project allow-list (by design; the refusal says how) |
| A5 | Session | `vs send S "say hello in three words"` | the agent answers; the chat shows it on the page | `a5Send` (the page's chat: `ScratchNodeTests.aPageFollowsASessionsChat`) | pass (2026-11-21, build 2ceb69f7): haiku answered "Hello there, friend." |
| A6 | Session | a permission prompt, `vs reply S 1` | the prompt shows as a card/field; reply answers it | `a6Reply` (trust dialog, then a permission prompt, its three options checked in `status --json` before `reply` picks one) | pass (2026-11-21): a real permission prompt (a verifier's read) showed in `status` with its options; `vs reply SESSION 4` answered it as the user. (The user's auto mode prompts for no scratch command, so the scratch session couldn't raise one.) |
| A7 | Session | `vs send S "…" --now` while it works | steered mid-turn, nothing lost | `a7SendNow` | pass (2026-11-21): mid-count, `send --now` steered it; it stopped and answered "STEERED" |
| A8 | Session | `vs rename`, `vs pause`, `vs end` | name and pause shown; end removes it; resume lists it | `a8RenamePauseEnd` | pass (2026-11-21): name and pause shown in status; end removed it; `resume` lists it after the 30 s grace (says "none" before it: UX follow-up) |
| A9 | Session | `vs resume S` | the ended session comes back in its conversation | `a9Resume` | pass (2026-11-21): resumed in its same conversation; it recalled its earlier answer |
| A10 | Terminal | the page's Terminal tab on a hosted session | live, watch-only, keys go nowhere | `a10TerminalWatch` | pass: watch-only terminal shows the live screen |
| A11 | Lead | `vs lead ~/projects/vs-acceptance --goal "add a subtract function with a test"` | lead plans a task, starts a worker | `a11LeadWithAGoal` | pass: the lead planned one task and started its worker |
| A12 | Lead | `vs board`, `vs questions --wait` | the board shows the task; a question arrives as a card | `a12BoardAndQuestionsWait` | pass: board shows the task and its blocker |
| A13 | Lead | `vs answer CARD …`, `vs tell FOLDER …` | delivered; the lead acts on it | `a13AnswerAndTell` | pass (2026-11-21): `vs tell` reached the resumed scratch lead (no popup on build 2ceb69f7); it requeued and ran the task |
| A14 | Lead | the task's audit and merge | two finders, the gate's tests (pytest), merged into main | `a14AuditAndMerge` | pass (2026-11-21): worker → rework → audit → the gate's pytest in the box (sandbox_env/read) → merged 9dad0d8 into main; 2 tests pass |
| A15 | Lead | approval for a sensitive path | an approval card; `vs answer` approves the exact commit | `a15ApprovalCard` | |
| A16 | Lead | push request, `vs push` / `decline-push` | the card shows the URL without credentials; settles | `a16PushAndDecline` (credentials: `PushAsksTests.aURLsCredentialsAreNeverShown`) | |
| A17 | Settings | `vs settings FOLDER`, `vs set FOLDER max_workers 2` | shown; set recorded; the lead is told | `a17SettingsAndSet` | pass (2026-11-21): `settings` shows the node and project limits with defaults and files; `set FOLDER max_workers 1` recorded and the lead told. (Wording: "mac_max_sessions", "mac-limits.json" on Linux) |
| A18 | Presets | `vs presets`, `vs preset add …`, `config accept`, `vs new --preset` | strict rules; accept needed; starts | `a18Presets` (an accepted file's preset starting: `SessionPresetsTests.aPresetOfTheFileStartsOnlyFromAnAcceptedFile`) | pass (2026-11-21): `preset add` held the presets file until `config accept`; `new --preset` started Claude with `--model haiku` |
| A19 | Notifications | the page with notifications on | a question/prompt notifies; the title counts | skipped: needs a browser (`WebApp/tests/notify.test.mjs`) | |
| A20 | Restart | `vs stop`, `vs start`, accepts, `vs lead FOLDER --resume`, `vs reopen` | the lead returns in its conversation; own sessions reopen | `a20RestartResumeReopen` | |
| A21 | Switch | install a new build, `vs switch` | sessions survive the handover; hooks install after | `a21Switch` | |
| A22 | Security | from a session: `vibeswitcher answer …` | refused: not the user's voice | `a22AnswerFromASession` | pass (2026-11-21): a session's Bash ran `vibeswitcher tell …`: refused (exit 77), nothing done |
| A23 | Security | a page token tries `answer`/`send` | refused; only drafts | `a23PageTokenRefused` | |
| A24 | Tests | `scripts/nightly.sh` on the merged v2 | full suite passes (retry-failed); flaky list filed | skipped: the nightly run itself | |
| A25 | Self-improvement | VS's own lead on its clone | merges its tasks through the gate; keeps a goal list | skipped: needs a real Claude lead | |
| A26 | Node | `vs doctor` | what the node needs, each missing piece with its command | `a26Doctor` | |
| A27 | Node | `vs brief` (and `--json`) | what happened and what's asked of you; from the boards when no model is asked | `a27Brief` | |
| A28 | Node | `vs stats week` | the week's figures, no error | `a28Stats` | |
| A29 | Lead | `vs mail FOLDER` | a project's messages between leads, which way, what became of each | `a29Mail` | |
| A30 | Settings | `vs settings --find "team sessions"` | only the settings holding every word, under the node's names; none says so | `a30SettingsFind` | |
| A31 | Session | `vs new FOLDER --agent codex` | without the link: refused, naming it and the `ln -s`; with it: Codex starts, labelled Codex | `a31Codex` (a stand-in codex on the scratch node) | |
| A32 | Session | `vs rename TTY NAME`, `vs pause NAME …` | a session is found by the terminal `status` prints and by its given name | `a32SessionByTerminalOrName` | |
| A33 | Session | `vs end S`, then `vs resume` | "a session ended N s ago … it is listed in M s", not "none ended" | `a33ResumeGrace` | |
| A34 | Switch | `vs switch COMMIT` while a worker runs | refused at once, naming the worker, no code asked | `a34SwitchBlocked` | |
| A35 | Web | a page asks recent, brief, board.task, board.image, session.usage, chat.image; a session runs `vibeswitcher brief` and `mail` | the page's reads answered (never a voice refusal); the session's refused: not the user's voice | `a35PageReads` | |
| A36 | Node | `vs status --health` (and `--json`) | the health digest: freezes, slow refreshes, restarts, the last errors | `a36Health` | |
