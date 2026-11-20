# One lead engine for the Mac app and the node: a proposal

For whoever maintains `main`. Written on `v2` (at `4b09648a`), read only; nothing here changes code. The app's lead
files on `v2` are identical to `origin/main` at `347a650d` (`git diff` over `Sources/VibeSwitcher/MainWindow/Lead` and
`HostClient.swift` is empty), so every app line number below holds on `main` today.

## Summary

1. The lead's lifecycle (start, rebind, deliver, wake, witness, sweep, hand over) is written twice: about 2,450 lines
   in `LeadController.swift` (plus 133 in `RoleSweep`/`PromptDecline`) on the Mac, about 3,650 in
   `Sources/VibeNode/Engine/` on the node.
2. Most of the actual rules already live in `VibeCore` (`LeadWake`, `LeadDelivery`, `LeadHandover`, `LeadWitness`,
   `LeadRotation`, `LeadVault`). What is duplicated is the glue: what runs in what order, which checks come before
   typing, what state is kept.
3. Part of that glue is copied word for word (`WitnessWork`, `TeamReading`, `StartPlan`, `LeadFiles`, `PromptDecline`,
   `RoleSweep`). Part has drifted on purpose (the node's stricter delivery target and replaced-lead check). Part has
   drifted by accident (the node lacks `lead_model`, `noteWorking`, resume; the Mac lacks the node's two security
   checks).
4. Of the 13 merge rows in the port map against `LeadController`'s logic, 6 touched the witness's code (`TeamReading`,
   `WitnessWork`, `sender`, `witnessed`) and 3 touched lead start.
5. What blocks moving the glue into `VibeCore`: it runs on the main thread, holds `HostClient`/`SessionStore`, asks
   modal dialogs (one from a background thread via `DispatchQueue.main.sync`), reads `UserDefaults` and presets, and
   publishes `@Published` state for views.
6. Target: one engine in `VibeCore` on an injected queue, driven through seven small protocols (clock, session host,
   session facts, ask-the-user, tell-the-user, settings, state at rest). The app and the node become thin drivers.
7. Migration: eight steps on `main`, each mergeable alone, Mac behaviour unchanged unless a step says otherwise. Steps
   1, 2 and 5 are small to medium and remove most of the porting load.
8. Cost: churn in a file `main` changed 31 times in the last two weeks, and it reverses the 2026-11-12 "strict
   isolation" decision for this slice. That decision is the user's.
9. Cheaper interim: a shared contract table both engines must pass, plus steps 1 and 2 only.
10. Recommendation: do steps 1, 2 and 5 now (with the user's OK), flip the Mac to the node's two security rules, and
    leave the full engine move (step 7) for milestone 5.

## 1. Inventory

Line ranges are in `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift` (2,456 lines) unless named. "Node"
files are in `Sources/VibeNode/Engine/` unless named. Drift: **same** (same algorithm, cosmetic differences),
**rules** (the same skeleton with different rules), **one side** (missing on the other).

| Piece | App: where, about how many lines | Node: where, lines | Drift | Genuinely UI in the app's version |
| --- | --- | --- | --- | --- |
| Board reads and their queue (`LeadFiles`, `LeadNames`, `LeadReads`) | 25-128, 393-418; ~140 | `Stores/BoardFiles.swift`, 130 | same (copied; `Stamp` via `Platform.Files`; mail not copied) | mail and decisions are only for the Team tab |
| Team reading for the witness (`TeamReading`) | 242-316; 75 | `TeamReading.swift`, 72 | same algorithm; node takes `inbox:`/`lock:` as parameters; the app also reads account usage, `workerModel` and `ignoreUsageLimits`, used only for the team rows' usage waits | the usage fields serve `TeamRows` |
| Witness computation (`WitnessWork`) | 317-392; 76 | `WitnessWork.swift`, 81 | same (diff is comments only, checked) | none |
| Start plan (`StartPlan`, `plan`) | 932-951; 20 | `LeadStart.swift` 42-55 | same (copied, on `HostLink.State`) | none |
| Starting a lead (`startLead` ×3, `prepareLead`, `spawnLead`, `answerTrust`) | 864-1202, 1534-1544; ~350 | `LeadStart.swift` 482, `NodePreflight.swift` 75, part of `LeadEngine.swift` | **rules.** App: `LaunchPreflight` plus the install offer, the first-commit offer, starting the host if it isn't running, the head-moved question as a modal, the review floor seeded, `LeadHandover.begin` on whatever the board names, `leadRun` (model and advisor), `resume` for the restart card. Node: the program by resolved path (EN-D13), a refusal for no commit, `--take-head`/`--replace`, the first-look refusal, no floor (EN-D7), the replaced lead verified (`replacedLead`), joined starts, notes instead of alerts. **Owed to the node:** `lead_model`/`lead_advisor` (`a3e2a30e`), resume with presets (`63a67b85`). **Owed to the Mac:** the replaced-lead check (`v2-mac-tasks.md`) | `alert`, `confirm`, `askToReplace`, `askToTakeHead`, `offerFirstCommit`, `offerHostRestart` (2155-2212), `ToolInstaller`, `select` |
| Rebinding running leads (`keepRunningLeads`, `keepRunning`, `startPending`) | 1028-1071; ~45 | `Restarts.swift` 143-198, `LeadStart.swift` 131-158 | same algorithm; the node retries after a dropped link and keeps `bound` at rest | `keptLeads` is `@Published` for the window |
| Answers, holds, timers | 1203-1291; ~90, plus `AlertRules.look` in `refreshed` | `Answers.swift` 795, `Stores/CardStore.swift` 173 | **rules, on purpose.** App: answers a board question by id, phone path, notices on the card. Node: a question is a card only from the lead's tool server's sealed post (EN-D10); every user action is recorded in the vault before it acts (EN-D11); approval cards built from git and the vault. Shared already: `LeadAnswerOutcome`, `holdMessage`, `BoardStore.runTimers` | `answerNotices` for the card view |
| Delivery and held messages (`deliver` ×2, `hold`, `next`) | 1287-1336; ~50 | `Delivery.swift` 261, `EngineState.swift` 177 | **rules.** App: the lead the board names, if its pid runs an agent on that terminal; held messages in memory. Node: the session the vault binds to the lead role, live in the host's list, on the board's terminal (`Delivery.target`, EN-D14); held messages at rest with action ids, vouched after a restart. **Owed to the Mac:** the target check (`v2-mac-tasks.md`) | none |
| Wake, flush, typing | 1415-1532, 1546-1551; ~125 | `Wake.swift` 302 | same algorithm (both drive `LeadWake`); the node re-checks the lead against the vault before typing (`notTheLead`) and waits for the unit's confirmation; the app skips a session where a dictation runs (`ClaudeVoiceRun`) and records rotation input | none (the dictation check is a Mac-only input fact) |
| Replaced leads: input routing (`takeInput`, `route`, `markReplaced`) | 1337-1413; ~78 | `Refresh.swift` 87-97 (the mark only) | one side: routing typed input is the Mac's until a node client types | `replacedLeads` drives the window's banner |
| Refresh (`refresh`, `refreshed`) | 1553-1655; ~105 | `Refresh.swift` 178 | same skeleton. The app also fills view state (decisions, records, mail, usage waits, team rows), keep-awake, App Nap, sleep watch, all-done, pushes and notifications | about a third of `refreshed` is view state |
| Witness applied (`witness`, `witnessed`, `stopForBudget`, `forgetFinished`) | 1919-2112; ~195 | `Witness.swift` 254 | same algorithm. Node: `told`/`advanceSeen` kept at rest, disk watch on `reads`, members' keys forgotten. **Owed to the node:** `noteWorking` (`03d03896`, so `small_task_min` never drops a review there) | none |
| Role sweep | `RoleSweep.swift` 78 | `RoleSweep.swift` 83 | same (33 changed lines, all host type and queue) | none |
| Stuck prompt decline | `PromptDecline.swift` 55 | `PromptDecline.swift` 59 | same (30 changed lines, all `HostClient` → `HostLink` and the queue) | none |
| Room watch | 1792-1813; ~22 | `RoomWatch.swift` 43 | same | none |
| Telling a session (`tell`, `SessionDelivery`) | 2114-2153, 2448-2456; ~50 | `Tell.swift` 33, `Delivery.swift` 193-222 | same | none |
| Rotation and idle handover | 2214-2446, state 563-600; ~270 | `IdleHandover.swift` 221 | **rules.** Same commit protocol (spawn, then board, then `vault.rotateLead`, put back on failure). Node: only the cold idle path. App: scheduled rotations from Settings, asking a warm lead for its note (marker, one-minute deadline), buffering keystrokes during the commit (`RotationCommit`), `idleAttempts` reset by the user's typing. Ported in part on 2026-11-19 | `rotationNotices` for the window; the mode is a Setting |
| Other watches: power, toolchain, heavy slots and jobs, policy, account (`nudgeLeads`), app health, update | 129-241, 1677-1910; ~350 | none ("what waits") | one side | `toolchainNote`, banners via `tellUser` |
| Config holds, base moves | `ConfigHolds.swift` 167, `BaseMoves.swift` 264 | `Stores/ConfigHoldStore.swift` 253, `Stores/BaseMoveStore.swift` 321, `Stores/AcceptedSnapshot.swift` 158 | rules: the core is copied (`check`, `looked`, `accept`, `keepRefused`, `changedAt`); the node adds the first-look hold, the snapshot and cards; the app has the typed `!` lines and Run cards | `ObservableObject` for the cards |
| Pushes, all-done, keep-awake and sleep cost, restart card | `PushRequests.swift` 105, `AllDoneWatch.swift` 67, `KeepAwake.swift`, `RestartCard.swift` | none | one side ("after the bootstrap") | mostly cards and notifications |
| The session host's client | `HostClient.swift` 1,259 | `Host/HostLink.swift` 852 | different on purpose (the app starts, replaces and proves itself to the host; the node reaches it through the inherited connector). The engine uses a small common subset: state, sessions, spawn, kill, remove, screen, styled screen, input units with gates | attach, raw input, resize: a client's |
| Session scan | `SessionStore.swift` 523 | `Stores/NodeSessions.swift` 436 | rules (Terminal.app, Spaces, presence are the Mac's). The engine needs only: per hosted session its agent's pid, tty, status and since, transcript path, background jobs, and `agentQuit` | most of `SessionStore` is the sidebar's |

What is UI in `LeadController`: the six dialog functions (about 60 lines), `select`, `alert`/`tellUser`, the
`@Published` properties and their view-only members (`decisions`, `recordsDirs`, `mail`, `teamRows`, `summaries`,
`rowUsageWaits`, `questionCounts`, `replacedLeads`, `rotationNotices`, `toolchainNote`, `keptLeads`), the input gate,
and the `WindowRow` lookups (`lead(for:)`, `questions(for:)`, 806-862). Everything else (about 1,900 lines) is
decision logic that sits in a UI type.

## 2. What blocks moving the decision logic into `VibeCore`

| Dependency in the app | Where | What the node uses instead |
| --- | --- | --- |
| `import AppKit`, `Combine`; `ObservableObject`, `@Published` | the class itself; `ConfigHolds`, `BaseMoves` too | plain stores with change callbacks (`LeadStore`, `CardStore`, `Changes`) |
| Main thread as the engine's queue (`DispatchQueue.main.async` everywhere, `dispatchPrecondition(.onQueue(.main))` in `refreshed`/`witnessed`) | throughout | one serial queue, the link's (`LeadEngine.queue`, EN-D1), reads on `BoardReads` |
| A modal dialog asked from a background thread: `DispatchQueue.main.sync { askToTakeHead }` inside `prepareLead` | 1111 | a flag decided before the request (`--take-head`), a note when it's left out |
| Modal dialogs and alerts (`NSAlert`, `confirm`, `runAlert`, `ToolInstaller`) | 2155-2212, 913-930, 876-881 | refusals with a reason, flags, `status` notices |
| `HostClient` (concrete class; `ensureHost`, `restartHost`, `canHandOver`, `inputGate`) | `host` | `HostLink` |
| `SessionStore` (scan, `agentQuit`, `leadsAsking`) | `store` | `NodeSessions` |
| Timers: `Heartbeat.shared.every(3)` on the main run loop; `asyncAfter` for `.later` wakes | 699, 1448 | `NodeClock` (with `DrivenTime` in tests) |
| Settings: `UserDefaults`-backed `Preferences` (rotation mode, keep-awake, battery limit), the project's launch preset as `claudeCommand`, `MacLimits.load()`, `WorkingPolicy.load()` at default paths, `MacLimitsEditor.usageLimitsChanged` notification | `AppDelegate.swift` 179-201, init | `LeadEngine.Options`; files under the node's root (`policy.md`, `mac-limits.json`); the resolved `claude` path |
| Paths from this process: `Bundle.main` for the tool server, `VibePaths.root`/`home` defaults | 764-772, 663 | every root a parameter; the tool server from `--node-root` (S9) |
| Process-wide singletons: `ReportsWaiting.shared`, `ClaudeVoiceRun.busy`, `Breadcrumbs.shared` | 1436, 1456, many | per-engine `LeadStore` counts; a `note` closure |
| The vault | `LeadVault.standard` | `HostLink.vault` (the same `VibeCore` type, another transport) — **no blocker** |

The vault, the board store, the steer inbox and every rule function are already in `VibeCore` and build on Linux. The
blockers are all about where the glue runs and how it talks to the user, not about the rules.

## 3. The target shape

One engine, `LeadEngineCore`, in `Sources/VibeCore/Lead/` (a new folder on `main`). It owns the lifecycle state that
both sides keep today (pending and joined starts, held messages, wakes, `flushing`/`typedAt`, `told`,
`advanceSeen`, rebinding, the role sweep's times, the rotation's state) and runs on a queue it is given. The app gives
it `.main`, so the Mac's threading is exactly today's; the node gives it the link's queue.

Seven protocols, each small:

| Protocol | What it gives the engine | App's implementation | Node's implementation |
| --- | --- | --- | --- |
| `LeadClock` | `now()`, `every(period)`, `after(delay)` | `Heartbeat.shared` and `DispatchQueue.main.asyncAfter` | `NodeClock` (`DrivenTime` in tests) |
| `LeadSessionHost` | `state` (connecting, connected with capabilities, gone), `sessions`, a change callback, `spawn`, `kill`, `remove`, `screen`, `styledScreen`, `type(writes, into:, gate:, confirmed:)`, and `ensureRunning` (may refuse) | an extension on `HostClient` (`ensureRunning` = `ensureHost`) | `HostLink` (`ensureRunning` refuses: the host always runs, EN-D12) |
| `LeadSessionFacts` | per hosted session: agent pid, tty, status and since, transcript path, background jobs; `agentQuit`; `leadRuns(agent)`; `inputBusy(id)` | `SessionStore`; `ProcessTable`; `ClaudeVoiceRun.busy` | `NodeSessions`; `ProcessTable`; always false |
| `LeadAsk` (the decisions only the user makes) | async questions with typed answers: replace a running lead without its role, take a moved head, make a first commit, install what's missing, restart an outdated host | `NSAlert` dialogs, `ToolInstaller` | answered from the request's own flags (`--replace`, `--take-head`); the others are refusals |
| `LeadTell` (what the user is told) | `event(AlertRules.LeadEvent)`, `info(title, body)`, `notice(root, text)`, `show(session)`, `log(text)` | the notifier, `select`, `Breadcrumbs` | `status` notices, cards, the server's log |
| `LeadSettings` | per root: the lead's program and base command; rotation mode; usage-limit setting; policy and limits sources; tool server path; roots (inbox, home, state); switches (`sweepsRoles`, `answersTrust`, `seedsFloor`, delivery rule) | `Preferences`, presets, `Bundle`, `VibePaths` | `LeadEngine.Options` and the node's root |
| `LeadStateStore` | load and save what a restarted engine must not repeat or lose (held messages with provenance, `told`, `advanceSeen`, bound leads, last host start) | in memory, as today (a later choice may keep it at rest) | `engine.json` (`EngineState`) |

The engine never blocks on a question: where the app asks in the middle of a start today, the start is split in two
(look, then ask, then grant). It publishes changes through one callback; the app's `LeadController` turns them into
`@Published` properties on the main thread, and keeps the view state, the Mac-only watches and the dialogs.

**What must stay different on purpose**, and how the shape keeps it:

- **The user's voice and cards (node) versus dialogs and the window (app).** The engine takes every user action as a
  value with its provenance (`.user` from the window, or a node action id the vault vouches for). Which questions
  exist is a `QuestionSource` given by the driver: the board (app) or the lead's tool server's sealed post (node,
  EN-D10). The node's rule that nothing from `board.json` is shown as an approval stays in the node's driver.
- **Recording before acting (EN-D11)** is a hook the engine calls before delivering a user action; the app's is a
  no-op.
- **Plain mode** is the node's start sequence and status, not the engine's. Nothing in the engine reads it.
- **The seal** (`SteerSeal`, `ConfigSeal`, the vault's `.user` seal lifetime in `LeadVaultV2`) stays in the vault and
  the delivery code, which are already shared; the engine passes provenance through and never seals by itself.
- **Rules where the node is stricter** (the delivery target, the replaced-lead check, no floor seeded on Linux, the
  program by resolved path) are named switches in `LeadSettings` during the move. The recommendation is to make the
  first two the Mac's rules too, then delete the switches.

**An alternative shape** worth naming: make `VibeNode`'s engine the shared one, as milestone 5 intends (the Mac moves
onto `VibeNode`). It already has the queue, the clock and the host behind interfaces. Against it now: it lacks main's
newest features (above), it carries node-only security machinery (voice, cards, vouching) the Mac doesn't need, and
`main`'s maintainer would be editing code that lives on `v2`. The protocols above are the same either way, so the
choice can be made late.

## 4. Migration path

Each step lands on `main` alone, keeps the Mac's behaviour (unless it says otherwise) and its tests green, and lets
`v2`'s next merge delete a slice of `Sources/VibeNode`. Sizes: **S** about a day and under 300 lines moved; **M** two to
four days; **L** a week or more. Sizes and deleted-line counts are estimates (unverified).

| # | Step on `main` | Size | Mac behaviour | Tests that pin it first | Deleted on `v2` at the next merge |
| --- | --- | --- | --- | --- | --- |
| 1 | Move the copied pure helpers into `VibeCore`: `WitnessWork`; `TeamReading` (with `inbox:`, `lock:` and the usage reads as parameters defaulting to today's); `LeadFiles`/`LeadNames`/`LeadReads`; `StartPlan` and `plan` on a small `VibeCore` host-state enum; `SessionDelivery`; `sender(_:)` | S | unchanged (a move; the app's names become typealiases if wanted) | app: `LeadFilesTests`, `WitnessOffMainTests`, `MemberWatchReadTests`, `LeadRelaunchTests`; node: `BoardFilesTests`, `WitnessTests`, `WitnessOffEngineQueueTests`, `LeadStartTests` | `WitnessWork.swift`, `TeamReading.swift`, most of `Stores/BoardFiles.swift`, the `StartPlan` copy, `SessionDelivery`; about 350 lines; 6 of the port map's 13 rows touched these copies (the rest of those commits is step 5's) |
| 2 | Add `LeadSessionHost` in `VibeCore`, conform `HostClient` to it, and move `RoleSweep` and `PromptDecline` onto it, the queue a parameter | S | unchanged | app: `RoleSweepTests`, `StuckVerifierPromptTests`; node: `RoleSweepTests`, `StuckVerifierPromptTests` | node `RoleSweep.swift`, `PromptDecline.swift`; about 140 lines |
| 3 | The delivery target and the pre-typing check as one `VibeCore` function with a rule switch (`.boardNamed`, today's Mac; `.vaultBound`, the node's). Then **3b**, a separate commit: the Mac takes `.vaultBound` | M, then S | 3: unchanged. 3b: **changes** (closes `v2-mac-tasks.md`'s delivery item) | app: `ReplacedLeadRoutingTests`, `SteerInboxReadOffMainTests`, the wake cases of `ComposerDeliveryTests`; node: `DeliveryTests`, `WakeTests`; 3b adds the forged-board case the mac-tasks file describes | `Delivery.target`, `Wake.notTheLead`; about 60 lines |
| 4 | Start preparation as a `VibeCore` function (`LeadStartPrep`): workflow, branch, head-moved look, grant, handover, last turns, launch, with switches for the floor, the replaced-lead check and resume. The head-moved question moves out of the background thread: look, ask, then grant. Then **4b**: the Mac takes the replaced-lead check | M (4b S) | 4: unchanged, but the question is asked before the grant is issued rather than in the middle (**verify** no user-visible change). 4b: **changes** (closes the mac-tasks handover item) | app: `LeadRelaunchTests`, `LeadStartsHostTests`, `ProjectFolderStartTests`, `RestartOfferTests`; node: `LeadStartTests`, `RestartTests` | most of `LeadStart.prepare`; about 200 lines. The node gets `lead_model`/`lead_advisor` and the resume path for free (two owed rows) |
| 5 | The witness's applier (`witnessed`, `stopForBudget`, `forgetFinished`) as a `VibeCore` type that turns a `WitnessWork` into effects through the protocols, including `noteWorking` | M | unchanged | app: `WitnessOffMainTests`, `RoomWatchTests`, `MemberWatchReadTests`; node: `WitnessTests`, `WitnessOffEngineQueueTests`, `RefreshTests` | most of `Witness.swift`, `RoomWatch.swift`; about 250 lines; the node gets `noteWorking` (owed `03d03896`) |
| 6 | Rotation and idle handover: the commit protocol and the idle and scheduled rules into `VibeCore`; the warm lead's note asked through `LeadTell`/delivery; keystroke buffering stays the app's through a hook | L | unchanged | app: `LeadRotationTests`; node: `IdleHandoverTests` | `IdleHandover.swift`; about 220 lines; the node gets the warm path |
| 7 | `LeadEngineCore` with the seven protocols: the state, the refresh loop, rebinding, wake and flush, held messages. `LeadController` becomes the app's driver (view state, dialogs, Mac-only watches); the node's `LeadEngine` the node's | L | unchanged | everything above, plus app `ComposerDeliveryTests`, `KeepAwakeTests`; node `EngineEndToEndTests`, `RestartTests`, `TellTests` | most of `LeadEngine.swift`, `Wake.swift`, `Refresh.swift`, `Delivery.swift`, `Restarts.swift` (the rebind half); about 1,000 lines |
| 8 | Answers and holds: share timers, notices and outcome handling, keep `QuestionSource` per driver; move the cores of `ConfigHolds` and `BaseMoves` into `VibeCore` without `ObservableObject` (the app wraps them) | M | unchanged | app: `LeadApprovalAnswerTests`, `LeadChatQuestionTests`, `ConfigHoldsTests`, `BaseMovesTests`; node: `AnswerTests`, `ApprovalCardTests`, `QuestionCardTests`, `ConfigHoldStoreTests`, `BaseMoveStoreTests` | parts of `Answers.swift` and the two stores; about 400 lines |

What stays on the node after all eight (about 1,200 lines, estimated): the card machinery and voice (`CardStore`,
`Answers`' card half), vouching held messages (`EngineState`), the host-restart half of `Restarts`, `NodePreflight`,
the first-look and snapshot code. That is the node's on purpose.

Each step moves tests too: a case that tests moved code moves to `VibeCoreTests`, where it runs on Linux and the Mac.
The app's own case stays where it tests the driver (the dialog, the `@Published` state).

## 5. Costs and risks

- **It reverses a decision.** The design's "strict isolation" (2026-11-12: main not touched, not even to prepare it;
  the logic exists twice until milestone 5) is the user's call. This proposal needs the user to lift it for this
  slice before anything starts.
- **Churn on `main` while its lead develops there.** `LeadController.swift` had 31 commits on `main` since
  2026-11-05, and `VibeCore` 236. Each step conflicts with whatever lead work is in flight in that file. Ways to soften
  it: pure moves first (steps 1, 2), each landed in one sitting, on a day `main`'s lead is told; no step mixed with a
  behaviour change (3b and 4b are their own commits).
- **Merge conflicts on `v2`.** `v2` doesn't edit `Sources/VibeSwitcher`, so the app side merges cleanly. The work at
  the merge is deleting `VibeNode`'s copy and pointing the node at the shared type, which is `v2`'s own code. `v2`'s
  few seam edits in `VibeCore` (the port map's "Non-seam edits", for example `LeadVault`'s hooks) are outside the code
  being moved (unverified for steps 6-8).
- **Mac-only tests.** `VibeSwitcherTests` run only on a Mac (on `v2`, only on the macOS runner). Each step needs a Mac
  run of the app's suites before it lands. In exchange, moved cases start running on Linux too.
- **Threading.** The app's engine assumes the main thread; the hang history (`hang-20261027-…`, `hang-20261028-…`) is
  why every read is off it. The shared engine keeps the app on `.main` and keeps the off-main tests, so this is
  guarded, but a move that accidentally does a read on the engine's queue would hang the window. The off-main suites
  are the guard.
- **Rule soup.** Switches for each difference can grow into an engine nobody can reason about. Keep them few and
  named, and delete each one when one side adopts the other's rule (3b, 4b).
- **Security.** Sharing must not weaken the node's rules. Each step that touches delivery, start or answers needs a
  review against the engine plan's Review Focus (`docs/superpowers/plans/2026-11-13-v2-engine.md`), items 2, 3 and 5.
- **What could go wrong.** The head-moved question moved earlier in step 4 is the one ordering change and needs a Mac
  check. `ObservableObject` isn't available on Linux, so nothing moved may keep it. Toolchain differences between the
  Mac's Swift and Linux's Swift 6.4.2 may surface `Sendable` warnings in moved code (unverified).

**A cheaper interim.** If the full move is judged too expensive now:

1. Do steps 1 and 2 only (two S steps, pure moves). They end the verbatim copies, which are where most accidental
   drift has come from.
2. Add a **contract table**: one file in `VibeCore`'s test support listing the lifecycle rules as rows (given a board,
   a vault binding and the host's sessions; when an event comes; then these effects: delivered to whom, held, typed,
   asked, refused). Each engine has a small adapter that runs every row: the app's in `VibeSwitcherTests` (on the Mac),
   the node's in `VibeNodeTests`. Rows that differ on purpose carry the two expected outcomes. A main commit that
   changes a rule edits its row, and `v2`'s merge fails until the node passes it. Size: M (the two adapters are the
   work). It replaces "gaps found by accident" with "gaps found at the merge", without moving code.

## 6. Recommendation

Ask the user to lift strict isolation for the lead engine only, then do steps 1 and 2 on `main` now. They are small,
pure moves that end the word-for-word copies. Do step 5 (the witness, where half the hand ports have been) and step 4
(start, which brings the node `lead_model` and resume) next. Take 3b and 4b as their own changes: they give the Mac
the node's two security checks that `v2-mac-tasks.md` lists as owed, after which the rule switches go. Leave step 7,
the engine core with all seven protocols, for milestone 5, when the Mac moves onto version 2 anyway. By then steps 1
to 6 will have made it a wiring change rather than a rewrite. If the user keeps strict isolation, build the contract
table on `v2` alone (the node's adapter, and the table seeded from the port map) and hand the app's adapter to
`main` when it can take it.
