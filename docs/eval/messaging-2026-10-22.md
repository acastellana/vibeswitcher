# Messaging audit, 2026-10-22

This audit covers how VibeSwitcher moves messages, checked at project-lead **fa9131e**. It covers:

- the chat composer and its outbox;
- typing, pasting and steering into Claude and Codex sessions;
- the lead's tools, its reports, its wake-ups and the witness;
- messages from workers and verifiers;
- questions and timers;
- the phone (replies, taps, state, push, briefing) and notifications;
- what survives a host handover, an app relaunch or a dead session.

It looks for messages that are lost, duplicated, reordered, misattributed or sent to the wrong place, and for failures nobody is told about.

**How it was checked.**

- Every finding comes from reading today's code. Where a pure function could be lifted out, it was also reproduced: verbatim copies of the source were compiled with `swiftc` in the session's scratch folder and run on made-up input.
- Nothing ran against the real app, the session host, a real session, the phone or `~/.vibeswitcher`. No build or `swift test` was run.
- Items already in `docs/eval/open-2026-10-19.md` are not reported again: E-05, E-06, E-07, E-09, E-14, the F-L2 residual, PH-1, F-P1, F-P2, WC-1 and R11.
- **Severity.** P0 means data loss or harm with no user action. P1 means a message lands somewhere it does real harm (a shell, a different prompt) or gets merged. P2 means a message is lost, duplicated or wrongly reported in a common flow. P3 means a narrow window or noise.

## The user's case: a second message right after the first

Yesterday the user reported that a second message sent right after a first sometimes seemed not to go through. Here is what happens, by target:

| Second message goes to… | What the code does | Can it look lost? |
|---|---|---|
| **An idle session, within ~1 s of the first** | The first prompt starts a turn. The composer only learns this when the hook's state file is written, plus the store's 0.4 s coalescing (`SessionStore.swift:469`). Until then it still thinks the session is idle, so it **types** the second message with `expectsSoon: true`. Claude queues it, and it shows in the transcript only at the next tool step or at the turn's end. | **Yes.** After 15 s it is flagged "Not in the conversation yet. It may not have reached Claude", with "Put back in the box". Sending it again makes a duplicate. See **#5**. |
| **A busy session** | It is steered into the inbox and arrives at the next `PostToolUse` or `Stop`. The strip says "steering… arrives at its next step". | Only by design, during a long tool call or subagent. If the turn ended in the moment between the composer's state read and the post, it reads "Not delivered … Send now". That is correct. |
| **A session with a question or picker open** | The message is **held**. When the question closes, every held message is typed **at the same instant**. | **Yes.** Two or more held messages **merge into one prompt** (reproduced), and the outbox never matches them. See **#2**. |
| **The lead** | The same as above. In addition, the app types its own wake-ups and flushes into the lead's box. | **Yes.** If a composer send and a wake-up or flush land within 60 ms, they merge (**#2**). A user's answer can wait indefinitely behind a lost wake-up (**#6**). |

All three "yes" rows have one root cause. A sent message is two writes, "text" then "Enter 60 ms later", and nothing orders these pairs per session. The other cause is that the composer's idea of "working" lags the session itself.

---

## Findings, ranked

### 1 · P1 · The composer types into the shell after the agent exits, and the message runs as a command

**What and when.** A window session can outlive its agent. This happens with the built-in **Shell** preset when you ran `claude` in it (`LaunchPresets.swift:98`), and with any preset set to "Keep a shell open after it exits" (`SettingsWindow.swift:398`, `HostedSession.swift:96`). After `/exit`, a crash or a double ^C, the chat keeps showing the last conversation with an active composer. Sending types the message into zsh, and zsh runs it.

**Sequence.**
1. The agent exits and the shell prompt comes back.
2. `row.session` becomes nil, but the chat is still shown. `chatPath` falls back to the remembered transcript for as long as the host lists the session (`WindowModel.swift:112-113`, `:124-128`).
3. The composer is shown whenever the host session is live, whatever the agent (`ChatView.swift:49`). `isLive` is the host PTY's state, not the agent's (`AppDelegate.swift:40-42`). The placeholder still says "Message Claude…" (`agent: row.session?.agent ?? .claude`).
4. ↩ goes to `sendToSelected`, then `ChatSync.type`. `Target` takes `agent: nil` without complaint (`MainWindowController.swift:374-376`).
5. `ComposerText.writes` sends a bracketed paste and then Enter (`ChatTimeline.swift:135-149`). zsh runs the line.

**Evidence.** A precise code reading; the path has no agent check anywhere. Run on code blocks *is* guarded by `session?.agent == .claude` (`MainWindowController.swift:394`). The composer has no such guard, and no test covers an agentless target.

**Impact.** The user's natural language reaches a shell, with no confirmation. "rm -rf build and run the tests again" runs `rm -rf build`. This is the worst kind of misroute: right session, wrong program.

**Fix sketch.** Show the composer only while the row has an agent (`row.session != nil`). Otherwise show "Claude has exited. Resume it or use the terminal", next to the existing Resume. `ChatSync.type` should also refuse a `Target` with no agent, as a second guard for the phone and other callers.
**Check.** A ChatSync test with a hosted shell session whose agent quit: `type("hello")` returns false and the session receives no bytes. A view test: the composer is not shown for a live row with no agent.

### 2 · P1 · Messages typed at once merge into one prompt (held messages always, other writers by timing)

**What and when.** Every typed message is two scheduled writes: the text at once, and Enter 60 ms later (`ChatTimeline.swift:148`; HostInput's phone writes use the same 60 ms gap, `HostInput.swift:37`). `HostClient.send(_:writes:confirmed:)` schedules each write with its own `asyncAfter`, and nothing makes one message's pair finish before the next message's text (`HostClient.swift:764-781`).

**Sequence (reproduced).**
1. A picker or question is open, and you send two or three messages. They are held (`ChatSync.swift:535-562`).
2. The question closes. `releaseHeld` calls `typeIn` for each entry in one loop (`ChatSync.swift:583-592`).
3. The wire then reads `text1 text2 text3`, and 60 ms later `CR CR CR`.
4. Claude Code receives **one** prompt, `text1text2text3`, with no separator. The extra Enters land on an empty box.

**Other writers that collide the same way** when they land within ~60 ms of a composer send to the same session:
- the lead's wake-up and flush (`LeadController.swift:801-809`, typed after a box check that cannot see a composer send already in flight);
- the MCP server's `type` (`vibeswitcher-mcp/main.swift:134-142`; this is a separate client, so app-side ordering would not help);
- the phone's window replies (`PhoneAccess.swift:853-863`).

When a wake-up comes first, the merged prompt starts with `[VibeSwitcher · reports, not the user]`, so `TypedText.agentMessage` labels **the user's words too** as "not the user" (`TypedText.swift:16-20`).

**Evidence.** The repro uses a verbatim copy of `ComposerText.writes`, the scheduling of `HostClient.send(writes:)`, and `HostInput.Line` (the app's own line model). Bytes go to a fake sink:
```
mode=release bracketed=true   host confirmed: [first message: true, second message: true, third: true]
                              prompts submitted (1): [«first messagesecond messagethird»]
mode=human (0.5 s apart)      prompts submitted (3): [«first message», «second message», «third»]
```
The only test of held messages sends one message (`PickerCardTests.aMessageWhileThePickerIsOpenWaitsAndEscClosesIt`, `.aHeldMessageStaysHeldAcrossSwitchingAwayAndBack`).

**Impact.**
- Messages are merged, and the host confirms each one, so every entry turns `typed`.
- The merged prompt matches no outbox entry (`Outbox.delivered`, `ComposerOutbox.swift:222-237`). The entries stay "typed" until the 15 s "late" flag, or until a relaunch restores them as "Typed in before VibeSwitcher restarted".
- Either path invites "Send now" or "Put back", which **duplicates** them.
- With a wake-up, the user's words are misattributed.

**Fix sketch.** Make "text, then Enter" one unit per session, in the **host**. Add a `type(id, text, submit)` request that the host writes as text, waits, writes Enter, and serializes per session across all clients (app, MCP, phone). Until then, the app can keep a per-session FIFO of message units, where the next text waits for the previous Enter.
**Check.**
- PickerCardTests: two messages held while `/mcp` is open, then Esc. Keys equal `…\u{1b}first\rsecond\r`, and both outbox entries leave as delivered.
- A host test: two clients send `type` to one session at the same moment, and two prompts come out.

### 3 · P1 · A phone tap meant for one permission prompt approves the next one, because their fingerprints are equal

**What and when.** The phone's tap guard is a menu fingerprint (`PhoneMenu.fingerprint`, `PhoneMenu.swift:25-31`). It hashes the question text, options, descriptions, tabs and submit row. `ScreenMenu.parse` builds the question from at most 6 non-empty lines above the options and stops at the first rule line (`ScreenMenu.swift:116-127`).
- An **Edit** prompt's diff sits above a rule, so it is never part of the question. Every edit prompt for the same file has the same fingerprint.
- A **Bash** prompt keeps only the command's last lines, so two long commands that differ near the top also collide.

**Sequence.**
1. The phone shows "Do you want to make this edit to Foo.swift?" for diff A.
2. A is answered on the Mac (or by another phone), and Claude proposes diff B to the same file.
3. The phone's tap on "Yes" arrives. `decide` reads the screen again, and `PhoneMenu.answer` recomputes the same fingerprint, so the tap is accepted (`PhoneAccess.swift:917-929`). **B is approved.**
4. The pre-Enter re-check in the Terminal path compares the same fingerprint, so it is blind too (`PhoneAccess.swift:993-1000`). It also only runs when `position > 0`, so tapping the option that is already highlighted is just Enter with no last-moment check. The window path has no pre-Enter check at all (`:946-965`).

**Evidence.** A scratch `swiftc` run against a verbatim `ScreenMenu.swift` (identical by `diff`):
```
A question: "Do you want to make this edit to Foo.swift?"   (diff "let x = 1" → "let x = 2")
B question: "Do you want to make this edit to Foo.swift?"   (diff "try deleteAll()" → "// removed")
A/B same question+options+descriptions: true
C/D same: true   (Bash: "make clean …" vs "git push --force …", same last 5 lines)
```
Related: the phone's 1/2/3 key buttons send raw digits with no fingerprint (`Web/app.js:1139-1142`). A stale "1" approves whatever prompt is up.

**Impact.** An edit or command the user never saw is approved from the phone. This defeats the one guard against "answered on the Mac meanwhile".

**Fix sketch.** Include the content above the rule in the fingerprint: hash the bottom ~40 masked screen lines with the cursor marks and checkboxes removed. Alternatively, have the phone echo a hash of the exact screen it showed. Re-check before every Enter, including the highlighted option and the window path. Send the digit keys as `choose` while a menu is shown.
**Check.** A PhoneMenu test: two edit screens that differ only in the diff have different fingerprints, and `answer` returns `.stale` for the old one.

### 4 · P2 · Phone replies can be typed twice, and the phone's ✓ and ✗ don't match what happened

**What and when.** There are three independent ways for the phone to be wrong about a reply:
1. **Double submit.** Enter in the reply box calls `requestSubmit()` (`Web/app.js:1150`). `send()` only disables the button (`:843-866`), and a disabled submit button does not block `requestSubmit()`. A second Enter or Send while the first POST is still typing posts the same text again.
   - In the Terminal path, the serial `work` queue types it twice.
   - In the window path, two text+Enter pairs ~ms apart **merge into "hellohello"** (#2).
2. **A false "not running".** The phone server cancels every connection 15 s after accept, whatever the handler is still doing (`RemoteServer.swift:114-115`; the timeout is cancelled only when the response is sent). A Terminal reply queued behind a jump or another reply keeps typing after the cut.
   - Tailscale returns a bare 502, and the phone reads that as "VibeSwitcher isn't running on your Mac, or Phone Access is off" (`Web/app.js:57-61`).
   - Its careful 30 s message ("Check the screen before sending again") never shows.
   - The text stays in the box, so the user sends it again.
3. **"Sent ✓" before anything is written.** A window-session reply answers `ok` as soon as the writes are scheduled (`PhoneAccess.swift:853-863`; a choice does the same at `:954-965`). If the host isn't connected, the gate stops between the text and Enter, or `hostClient` is nil, the phone still says sent. The failure shows only as an alert or an audit line on the Mac.

**Evidence.** A precise code reading of all three paths.

**Impact.** Duplicate prompts are the common case: a phone on a slow link plus an impatient second tap. A "sent" that never went in leaves the user waiting on an agent that never got the message.

**Fix sketch.**
- Add an in-flight guard in `send()`, and a client request id that the server deduplicates within a short window.
- Make the server's 15 s timeout cover only receiving the request, and map 502 or 504 on `/api/input` to "unknown, check the screen".
- Answer window replies from `HostClient.send(_:writes:confirmed:)`, with the gate checked per write.

**Check.** A node test of app.js: two submits produce one POST. A PhoneAccess test: a window reply while the host is disconnected answers an error, not `ok`.

### 5 · P2 · A message typed into a turn that just started is flagged "may not have reached Claude", and putting it back duplicates it

**What and when.** This is the user's case. The composer decides `working` from `row.session?.status` (`ChatView.swift:51`). That status changes only after the `UserPromptSubmit` hook writes its state file, and the store coalesces watcher events by 0.4 s (`SessionStore.swift:466-471`).
- A second message sent in that window is typed with `expectsSoon: true` (`ComposerView.swift:132`, `ChatModel.swift:517`).
- Claude queues it. The transcript shows it only when Claude takes it, as a `queued_command` attachment at the next tool step, or as a prompt after the turn (`ChatTranscript.swift:323-336`).
- If that takes longer than 15 s (a long think before the first tool call), `PendingMessage.late` fires (`ChatExtras.swift:55-57`). The chat says "Not in the conversation yet. It may not have reached Claude." and offers "Put back in the box" (`ChatView.swift:190-195`).

**Sequence.**
1. Send "fix the login bug" to an idle session.
2. Within ~1 s, send "and add a test".
3. Claude thinks for 20 s. The second message is flagged late.
4. The user puts it back and sends it again (now steered).
5. Claude gets "and add a test" twice: once queued and once steered.

**Evidence.** A precise code reading. `expectsSoon` is the composer's stale `working`. Nothing re-evaluates it when the hook later reports working: `updateLate` only uses `sentAt`.

**Impact.** A false alarm on exactly the message the user worries about, and its remedy creates a duplicate.

**Fix sketch.** Decide `expectsSoon` when the late check runs, not at send time. The check is late only if the session has been **idle since `sentAt`**: no hook `UserPromptSubmit` or working program status after `sentAt` - 1 s. Otherwise show it as "queued". Alternatively, read the hook state file fresh in `submit` (as `steerSelected` does) and steer when it says working.
**Check.** A ChatModel test: send while the status is idle, the hook state flips to working 0.3 s later, and the transcript shows nothing for 20 s. The note is `.queued`, never `.late`.

### 6 · P2 · A user's answer to a lead question waits indefinitely behind a wake-up that didn't go in

**What and when.** `LeadWake` types one "N new reports… Call status." prompt and then waits until the lead takes a turn. It tells this by one of `typedFor`'s reports leaving the inbox (`LeadDelivery.swift:272-277`); nothing expires `typedFor`. The test `noSecondWakeUpUntilTheLeadTookATurn` documents the case where the prompt didn't go in: its Enter was lost, the box was cleared, or it merged (#2). In that case no further wake-up is typed, by design (`Tests/VibeCoreTests/LeadWakeTests.swift:138-151`).

**Sequence.**
1. A report waits for an idle lead.
2. The wake-up is typed and doesn't submit.
3. The user answers a question card. `LeadController.answer` → `deliver(.user)` → post to the inbox → `wake(root:)`.
4. `wake` hands over to `flush` (which types the user's words) only when the **first** pending message is the user's (`LeadController.swift:717`). The stale report is first, so `LeadWake.step` runs and returns `.none` from then on.
5. The answer waits until the lead happens to take a turn. The "reports waiting" strip counts only non-user messages (`LeadDelivery.swift:266-268`, `:301-304`), and the card already reads as answered.

**Evidence.** A verbatim copy of `step` plus the `wake` branch, run in the scratch folder, gives `t=10: ready`, then `t=40/100/600/3600: none`. The user's answer is never typed. No test posts a user message after a lost wake-up.

**Impact.** The user answers, believes the lead has it, and the lead sits idle.

**Fix sketch.** In `wake`, flush when **any** pending message is the user's, not only the first. Also re-arm `typedFor` once the lead has been between turns with an empty box for ~60 s after `typedAt`.
**Check.** A LeadWake/LeadController test: a lost wake-up, then a user answer. The answer is typed within one refresh.

### 7 · P2 · Messages held for a lead that isn't running live only in memory, and a relaunch loses them

**What and when.** `LeadController.held` (`LeadController.swift:206`) is in memory only. It receives:
- what waited in the replaced lead's inbox at a handover. `LeadHandover.takeWaiting` **withdraws** these from disk (`LeadHandover.swift:50-52`), and they land in `held` (`LeadController.swift:503`);
- anything delivered while no lead runs (`:629-634`): the user's answers and holds, timer notices, witness events and "New goal: …" (`:386`);
- text typed into a replaced lead (`route`, `:659-667`), whose notice tells the user it waits.

They drain only when a lead runs again (`:1009-1012`). The same is true when a lead start fails (the alert path, `:505-507`).

**Sequence.**
1. Restart the lead (a handover). Its inbox is moved into memory.
2. The new lead is slow to start (the trust prompt, a keychain dialog) or fails.
3. The app relaunches (every `--install` does). The held messages are gone.

**Evidence.** A precise code reading. Worker reports and answers are also on the board, so the new lead can find them through `status`. The user's composer messages to the old lead, routed text and "New goal" have no other copy.

**Impact.** The user's words are lost silently across the most common maintenance action (install, then restart the lead).

**Fix sketch.** Keep held messages on disk: a per-root "for the next lead" inbox file, written under the inbox lock and drained on the first refresh where a lead runs. Better still, have `takeWaiting` move them into that file instead of into memory.
**Check.** A test that makes a controller, starts a handover, makes a new controller over the same files, then introduces a lead. The withdrawn messages are delivered once.

### 8 · P3 · Every relaunch re-tells the lead every standing witness event

**What and when.** The witness's "already told" set is in memory (`LeadController.swift:176`). `LeadWitness.messages` is computed from the current board and sessions only (`LeadWitness.swift:134-148`). After a relaunch, every condition that still holds is sent again and wakes the lead:
- `|ended` for a worker the lead chose not to restart ("N sessions ended without reporting … start_worker …");
- `|input-<since>`, `|stalled-…` and `|held-…`.

**Evidence.** A code reading. The policy notices are already persisted (`PolicyWatch`); these are not.

**Impact.** Duplicate reports and wake-ups after every install. A lead may restart a worker it had deliberately left ended.

**Fix sketch.** Persist the told keys per root, pruned to live sessions and open tasks, or record them on the board.
**Check.** A new controller over the same board and sessions tells nothing new.

### 9 · P3 · A steered message vanishes when its agent ends before its next step

**What and when.** A user's steer waits in the per-terminal inbox for its agent's pid. The agent can end before its next step: `/exit`, a crash, Move to Window (which SIGTERMs the Terminal agent and resumes in a new session, `AppDelegate.swift:633-680`), or a host restart. When it does, `watchSteering` gets `tty: nil` and clears the strip (`ChatModel.swift:453-458`). The message stays in the file until the next agent on that terminal drops it as "an earlier agent's" (`Steer.swift:120`, `:147`). It is never offered back.

**Evidence.** A code reading. `LeadHandover.takeWaiting` handles this case for the lead only.

**Impact.** The user's words disappear without a trace. This is the dead-session row of the audit's scope.

**Fix sketch.** When a session's agent ends, withdraw its pending `.user` messages and put them in that row's outbox as "not delivered: Claude exited" (Send again / Put back / Discard). Move to Window should carry them to the new session.
**Check.** A ChatModel test: steer, the agent ends, and the message is in `needsYou` with its text.

### 10 · P3 · Lead flushes and wake-ups count as delivered before their keys go out

**What and when.** In `LeadController.type(waiting:)`, the `typeInto` closure calls `type(_:into:)`. That schedules `host.send(..., reply: false)` with no completion and returns `true` at once (`LeadController.swift:779-784`, `:801-809`). `SteerInbox.deliver` then marks the message delivered and removes it from the inbox (`Steer.swift:132-152`).
- If the connection drops, the host refuses, or the input gate takes it, `inputCut` raises a generic "bytes cut" alert (`HostClient.swift:621-633`), and the message itself is gone.
- This breaks the contract in `Steer.swift:87-90` ("counts as delivered only once it's in the agent's context").
- It hits user answers typed into an idle lead and lead→worker messages typed into idle workers.

By contrast, the MCP server's `type` is synchronous and returns false on failure (`vibeswitcher-mcp/main.swift:134-142`).

**Fix sketch.** Type through `HostClient.send(_:writes:confirmed:)` (`HostClient.swift:764`). On `confirmed(false)`, post the message again at the head of the inbox.
**Check.** A test with a host that refuses input: the message is still pending afterwards.

### 11 · P3 · A worker's report reads "can't tell" as "no lead running"

**What and when.** `tellLead` asks the vault for the lead's holder with `try?`, so any transport failure becomes nil (`LeadToolset.swift:2081-2090`, via `LeadVault.swift:312-314`). `isRunning` is false when the process's argv can't be read (`vibeswitcher-mcp/main.swift:226-228`). When the host misses one call, for example during an install handover:
- the report goes on the board but not into the lead's inbox, so an idle lead is never woken;
- the worker is told "There's no lead running right now" (`:2093`);
- `ask_lead` throws "There's no lead running to ask. Decide what you can…" (`:2165`), steering the worker to decide on its own.

**Fix sketch.** Make `current` throw on transport errors and have the tool return an error the worker can retry, instead of "no lead".
**Check.** A toolset test with a vault that fails once: `report` errors and does not say "no lead".

### 12 · P3 · Push and Mac notifications open a session by terminal, so a reused tty opens the wrong one

**What and when.**
- A push carries only `tty` (`PhoneAccess.swift:1133-1138`, `Web/sw.js:14-26`). `openSession(tty)` opens whatever session holds that tty now (`Web/app.js:336-339`).
- Mac banners also open by tty (`Preferences.swift:260`, `:289`, `:315-320`).
- If the session in the notification ended and a new one took its tty (common), the tap opens the new session, presented as the one that needed you. A user can then answer the wrong session's question.

**Fix sketch.** Put the session identity (`sid`) in the push data and in `userInfo`. When it no longer matches, show the existing "Session ended / another session is running" view (`Web/app.js:366-381`).
**Check.** A node test of sw.js and app.js, plus a Notifier test with a reused tty.

---

## Looked at, fine

- **Outbox before sending.** An entry is saved before anything goes out, and the box is emptied on disk (`ComposerView.swift:126-140`). A refusal puts it back (`ChatModel.swift:506-519`). A relaunch restores entries as "needs you" and never resends them by itself (`Sources/VibeCore/ComposerOutbox.swift:124-138`). The strip is hidden while the chat loads, so delivered ones are dropped first (`ComposerView.swift:54`).
- **Matching one prompt to one entry.** Identical consecutive texts each take their own prompt (`ComposerOutbox.swift:222-237`, `ChatExtras.swift:60-72`). Host confirmations go to the oldest `sending` entry of that text (`:152-168`).
- **Unsent messages after host replacement.** These are dropped only once the host's welcome list is in, never on a stale one: `sessions` is set before `state` (`HostClient.swift:343-352`, `MainWindowController.swift:194-200`).
- **Steer posting.** It runs off the main thread and in order. An inbox that stays locked puts the message back in the box (`ChatModel.swift:411-442`). An idle agent gets the message typed instead of steered (`MainWindowController.swift:436-439`). A replaced lead's steer goes to the live lead (`:432-433`).
- **Steer delivery.** Order, parts, a full disk, seals that can't be checked and a hook killed mid-delivery are all handled (`Steer.swift:110-155`, `:210-214`). Subagents' hooks don't take messages (`Steer.swift:333-340`). Dropping other pids' messages only hits an earlier agent on the same tty, which is intended (see #9 for its cost).
- **Two quick steers to a busy session.** They queue in the inbox and arrive together, in order, at the next step. A stranded one shows "Not delivered … Send now" / "Put back", and withdraw-versus-flush is settled under the inbox lock (`ChatView.swift:156-170`, `Steer.swift:177-194`).
- **The free-text answer path.** A composer message sent while a question that takes free text is open becomes the answer and leaves the outbox (`ChatSync.swift:541-548`).
- **Lead handover ordering.** The role moves first, then the board, then the inbox, and the app re-checks the named lead before typing (`LeadController.swift:461-466`, `:629`, `:710`, `:740`; `LeadHandover.swift:36-39`). Text sent to a replaced lead is routed, not typed (`MainWindowController.swift:415-418`, `LeadController.swift:645-667`).
- **Question timers.** Each fires once, under the board lock, and survives a relaunch. Answer versus timer and answer versus revision are settled by id and version (`LeadBoard.swift:981-989`, `:1007-1022`, `:769-797`).
- **Double wake-ups.** These are prevented by the 10 s `typedAt` gate, `flushing` and `typedFor` (`LeadController.swift:734`). See #6 for the opposite failure.
- **The phone's session identity.** Every input, pause and read checks `sid` (tty + pid + start), including after waiting on the focus lock (`PhoneAccess.swift:816`, `:870-875`; `RemoteInput.swift:85-90`). Guarded typing stops when focus moves and re-checks the tab before Enter (`GuardedTyping.swift:43-59`).
- **The phone's double tap on an option.** It is refused by `answered`/`busy()` (`PhoneAccess.swift:909-929`; but see #3 when the next prompt shares the fingerprint).
- **Pairing.** A code is single use with 5 tries, re-pairing retires the old token, and a reply after unpairing gets a 401 (`PhoneAccess.swift:410-469`).
- **Briefings.** A superseded run is dropped by run id, and the client checks its own generation (`PhoneAccess.swift:1083-1094`, `Web/app.js:1031-1048`). A dropped briefing still moves its "since" time on (`PhoneBriefing.swift:99`). This only matters for events more than 3 h old.

## Not verified

- **Codex and the 60 ms Enter.** With bracketed paste on, Codex should take the Enter. Without it, Codex's own paste-burst heuristic may treat an Enter within its window as a newline. This needs a scratch Codex in a scratch host, which this audit did not run.
- **Phone presence.** Synthetic key events from phone replies to Terminal.app may reset the idle timer that `UserPresence.isPresent` reads. If so, "only when away" pushes would pause for 5 min after each reply. Not checked at runtime.
