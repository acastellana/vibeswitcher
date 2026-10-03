# Session history, briefings and decisions on the phone — design

## Goal

Three additions to Phone Access, built in this order:

- **A. Full history:** see much more of a session than its visible screen: the terminal's whole scrollback,
  and a clean conversation timeline.
- **C. Better decisions:** when a session asks something, the phone shows the real options as buttons,
  with optional context and a recommendation.
- **B. Briefing:** one tap gets a short Claude-written summary of the session, what's waiting on you and a
  proposal, readable and playable as natural speech (ElevenLabs).

The user chose:
- both a Terminal tab and a Conversation tab;
- tappable choices plus context and a recommendation;
- ElevenLabs for the voice;
- Claude runs **only when the user taps**: nothing is generated in the background.

Everything runs on the Mac through the existing Phone Access server, with its existing security: loopback
listener behind `tailscale serve`, own Tailscale account only, and a paired-device token.

Out of scope:
- answering from notifications;
- automatic or background briefings;
- a decision inbox across sessions;
- suggesting permission rules;
- Codex parity where Codex doesn't expose the same data. It degrades to the Terminal tab and screen-based
  options.

## A. Full history

### Terminal tab
- `GET /api/history?tty=…&before=<line>&limit=<n>` returns lines from Terminal's `history of tab`, the
  whole scrollback, as `{lines, start, total}`.
  - The Mac keeps at most the last **5,000 lines** of a tab, and returns pages of up to **500 lines**,
    newest last.
  - Credentials are masked with `Redaction.secrets`, like the screen.
- The phone opens the tab scrolled to the bottom: the existing live screen, refreshed as now. Scrolling up
  fetches older pages and adds them above, without jumping.
- **Cost:** one AppleScript read per page request, cached for 2 s per tty, so paging quickly reuses one read.

### Conversation tab
- The hook records `transcript_path` from every Claude Code hook payload into `HookState` (new field
  `transcriptPath`). It's stored only if it's an existing regular file under `~/.claude/projects/`, or
  under `~/.codex/sessions/` for Codex if Codex provides it.
- `GET /api/conversation?tty=…&after=<cursor>` reads that JSONL file and returns typed entries:
  - `prompt`: user text;
  - `reply`: assistant text;
  - `tool`: name, one-line summary (as in `ToolActivity`), duration, ok/failed, and output truncated to
    4 KB, fetched in full on expand up to 64 KB;
  - Thinking blocks, system/meta lines and sidechains are skipped. Everything is masked with
    `Redaction.secrets`.
  - `cursor` is a byte offset, so polling only reads what's new.
- **Pure parsing in VibeCore:** `TranscriptReader.entries(fromJSONL:)`, tested with fixture lines in both
  Claude Code's and Codex's formats.
- **Phone:**
  - Prompts and replies are bubbles. Tool rows are one line, with a tap to expand.
  - It refreshes when the session's status or `lastEventAt` changes (from `/api/state`), not on a timer.
- **No transcript known** (old session, no hooks, or Codex without a path): the tab says so and points to
  the Terminal tab.

## C. Better decisions

### Capture
`HookState` gains `decision: Decision?`, set with `request` and cleared when the session moves on. Its
`kind` is one of:
- **`question`:** from `AskUserQuestion` / `request_user_input` tool input. Holds `questions[]`, each with
  `question`, `header`, `multiSelect` and `options[]` (`label`, `description`).
- **`permission`:** from PermissionRequest. Holds the tool and its one-line description (as `request` today).
- **`plan`:** from ExitPlanMode. Holds the plan text, capped at 8 KB.

**The menu's numbered choices** for permissions and plans are read from the **visible screen** when the
phone asks: lines like `❯ 1. Yes`, `  2. Yes, and don't ask again for …`. The parser
`DecisionMenu.parse(screen:)` lives in VibeCore and is tested on real screen captures (fixtures).

### Conversation tab
An AskUserQuestion shows as its own row (the question, with the chosen answer when known) instead of a
generic tool row. This needs the structured decision captured below, so it's built here, not in part A.

### Phone
- The `ask` card becomes a **decision card**: the question, then one large button per option, label in
  bold with the description underneath.
- **"Type an answer"** focuses the reply box.
- `multiSelect`: checkboxes plus **Submit**.
- Several questions: shown one at a time ("1 of 2").
- **Permission and plan:** buttons for the parsed menu choices. The plan text is collapsible.

### Answering
`POST /api/answer {tty, decisionId, choice: [indices], questionIndex}`:
- **When:** only when **Allow replies** is on, with the same locking, focus and audit rules as `/api/input`.
- **Freshness check:** `decisionId` is a hash of the decision. The Mac re-reads the screen and checks the
  same question or menu is still shown.
  - If not, nothing is typed and the response is `409 "That question changed. Refreshing…"`.
- **Keys:** the option's **number** is typed (absolute choice, never arrows).
  - `multiSelect`: each chosen number toggles its option, then the submit sequence is typed.
  - **The exact keys are confirmed by the plan's first task**, a spike on a scratch session, before
    anything is built on them.
- **After typing:**
  - If the hook state still shows the same `decisionId` 4 s later, the phone shows "Didn't go through:
    use the keys below, or answer on the Mac."
  - Every answer is written to the audit log ("Android phone answered genswap: B").

### Recommendation
- A **Recommend** button on the card runs the briefing engine (see B) with:
  - the decision;
  - the last ~20k characters of conversation;
  - the project name.
- It returns `{perOption: [{label, meaning}], suggested: <index>, why, spoken}`. The phone shows the
  meaning under each option and a **Suggested** badge on one, plus ▶ Listen.
- It never answers on its own.

## B. Briefing

- `POST /api/brief {tty}` → `{id, status: "running"}`, then `GET /api/brief?id=` polls until
  `{summary, waitingOn?, proposal, spoken}` or `{error}`.
- **Input**, built in VibeCore by `BriefingInput.make(…)`:
  - the conversation entries (A), condensed to the most recent ~40k characters. Tool output is cut to
    300 characters per call, and older turns are summarized as "(N earlier turns)";
  - plus status, the pending decision and the project name.
  - All of it masked.
- **Engine** (`BriefingEngine`, app target): runs the user's `claude` CLI, without a shell, as:
  ```
  claude -p --model <model> --output-format json --tools "" --no-session-persistence
         --strict-mcp-config --setting-sources "" --system-prompt <fixed prompt>
  ```
  - The input goes on stdin. The environment includes `VIBESWITCHER_INTERNAL=1`; the hook exits at once
    when it sees that. The working directory is an empty temp dir.
  - The fixed prompt asks for JSON with exactly these keys and a `spoken` version of 60–90 words written
    for listening.
  - The output is checked against the expected keys. Anything else is an error.
- **Finding `claude`:** a path set in Phone Access, else the first of `~/.local/bin/claude`,
  `~/.claude/local/claude`, `/opt/homebrew/bin/claude` and `/usr/local/bin/claude`, else a one-time
  `zsh -lc 'command -v claude'`.
- **Limits:**
  - One run per tty at a time, with a 90 s timeout.
  - Results are cached by (tty, transcript size, decisionId), so tapping again on an unchanged session
    reuses them.
  - Model setting: Sonnet by default.
- **Voice:** `POST /api/brief/audio {id}`.
  - The Mac sends only `spoken` to ElevenLabs. The key and voice come from `~/.config/elevenlabs/key.env`
    (`ELEVENLABS_API_KEY`, optional `ELEVENLABS_VOICE_ID`, default Rachel) and are never sent to the phone.
  - The MP3 is cached and served at `GET /api/brief/audio?id=`, and the phone plays it in an `<audio>`
    element. Our CSP already allows same-origin media.
  - If there's no key, ▶ is hidden. ElevenLabs errors (quota, bad key) show on the card.
- **Phone:**
  - A **Brief me** button in the session view.
  - A card showing *What happened / Waiting on you / Proposal*, plus ▶ Listen, "Updated 2 min ago" and
    Refresh.
- **Audit:** "Android phone asked for a briefing of genswap".

## Errors

| Situation | What the user sees |
| --- | --- |
| Transcript missing or unreadable | Conversation tab: "No transcript for this session. See the Terminal tab." |
| `claude` not found | Card: "Couldn't find Claude Code on the Mac. Set its path in Phone Access." |
| `claude` not logged in, or other exit ≠ 0 | Card: the first line of its error output (masked) |
| Briefing over 90 s | Card: "Claude took too long. Try again." |
| ElevenLabs 401/402/429 | Card: "ElevenLabs: <message>". The text stays. |
| Decision changed before the tap | Card refreshes: "That question changed." |
| Replies off | Option buttons disabled: "Turn on Allow replies on the Mac to answer from here." |

## Testing

- **Unit tests (VibeCore):**
  - `TranscriptReader`, with Claude Code and Codex fixture lines including tool_use/tool_result pairs,
    thinking, sidechains and malformed lines.
  - `DecisionMenu.parse`, with real captured screens: permission, plan, AskUserQuestion, multi-select.
  - `Decision` capture in `HookState.reduce`.
  - `BriefingInput.make`: condensing, masking, size cap.
  - Briefing output validation.
  - The history paging maths.
- **Spike, first task of plan C:** on a scratch Claude session in a scratch folder, trigger an
  AskUserQuestion, a permission and a plan prompt. Confirm which keystrokes select and submit each kind,
  then record them as fixtures.
- **Integration:**
  - curl with a temporary paired device against a scratch session, for history pages, conversation
    cursors, and answers (including the 409 path).
  - A briefing on the scratch session, with ElevenLabs audio fetched once.
- **Never against the user's real sessions** (memory rule).

## Delivery

Three plans, each shippable on its own: A (history), then C (decisions), then B (briefing). C's
Recommend button and B share `BriefingEngine`. Whichever of them is built first introduces it, so with
the order above C builds it and B reuses it.
