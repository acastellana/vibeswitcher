# WebApp: VibeSwitcher's web client

The client for a VibeSwitcher 2 node (`docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`, "The web client"
and "Stage 5"). Served by the node itself (embedded in its server, `scripts/webapp-embed.sh`), it follows the node live
over its WebSocket (`js/socket.js`, the wire contract `docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md`):
the node's status, the sessions as their status changes, the leads' questions, and a session's conversation as it
grows. It reads, and drafts: a pick on a card leaves a draft there, told to nobody, and the card shows the line that
sends it from a terminal (`vibeswitcher answer CARD`, a click to copy), where the card's code is typed. No click here
is the user's answer. With `?mock` it runs on invented data instead and needs no server.

```sh
bash scripts/sandbox-server.sh run && bash scripts/sandbox-server.sh url   # a scratch node, and the page's address
WebApp/serve.sh                     # the mock, no node: http://127.0.0.1:8765/?mock
bash scripts/test.sh --web WebApp/tests
```

| Address | Shows |
| --- | --- |
| `/#pair=CODE` | The node, live: what `vibeswitcher web` prints. The code is taken off the address bar and exchanged for a token this tab keeps. |
| `/` | The node again in this tab (its token), or "Not paired" with what to run. |
| `/?mock` | The mock node: a lead's team moves tasks across its board, a question arrives, sessions finish. |
| `/?still` | The mock's snapshot with nothing happening after it (for screenshots). |
| `/?empty` | A mock node with no sessions. |
| `/?rows=10000` | One mock session ("Add dark mode…") with a 10,000-row chat: its newest 200 first, the rest paged in as you scroll up. |
| `/#/settings`, `/#/settings/<project id>` | Settings: the node's and a project's, each change drafted as the `vibeswitcher set` line to run in a terminal (`js/views/settings.js`). |
| `/?theme=dark`, `/?theme=light` | The other look, whatever the system says. |

Screenshots of each screen, light and dark, desktop and phone, are in `shots/`.

## Rules

- **No build step, no npm.** Plain ES modules and one stylesheet. One thing is vendored: xterm.js and its fit add-on
  for the terminal (`vendor/`, at exact versions with their hashes, `vendor/README.md`), loaded only where the node
  opens terminals. Nothing is installed.
- **What an agent wrote is never markup.** Every node is made by `js/dom.js` from elements and text. Nothing parses
  a string as HTML. `index.html`'s content policy allows the page's own scripts and styles only, with Trusted Types and
  no policy, so the browser refuses it too. `tests/lint.test.mjs` holds the source and the policy to this.
- **Nothing remote.** No image, font or script from another origin; the icons are drawn in `js/marks.js`. A link in
  an agent's text is shown as text.
- **The Mac app is the reference** for words, status colours and layout. Where they pull apart, this leans calmer.

## Files

| File | What |
| --- | --- |
| `index.html`, `style.css`, `app.js` | The page, its one stylesheet, and the entry: mounts the views, the keys, the clock. |
| `js/store.js` | The state: a snapshot, then deltas. Knows nothing of the page or of where messages come from. |
| `js/socket.js` | The node's live feed: pairing, the token, the four subscriptions and each shown chat's, the contract's order rules, reconnecting. |
| `js/chatops.js` | A chat's ops (`add`, `text`, `set`, `remove`), applied all or none; the mock makes them as the node does. |
| `js/wire.js` | The node's values in the shapes the views read, inventing nothing (a field the node doesn't send stays empty). |
| `js/mock.js` | Stands in for the node with `?mock`. |
| `wire/` | The validators and vectors, generated from the node's encoders (`vibeswitcher wire-vectors`): don't edit them. |
| `js/ui.js` | What this window shows: the route (`#/s/<id>`, `#/node`), grouping, filter, panes, the inspector; the list's arrangement. |
| `js/words.js` | The vocabulary: state words, durations, a task's words (from `VibeCore`). |
| `js/dom.js`, `js/marks.js`, `js/text.js` | Building nodes; status marks, agent badges, icons; markdown and diffs as nodes. |
| `js/terminal.js` | A session's terminal over the socket (the contract's §9): the binary frames, and the stream's life (open, the replay drawn whole, live, resync, reconnect, close). |
| `vendor/` | xterm.js and its fit add-on, at the versions and hashes `vendor/README.md` records; nothing else is vendored. |
| `js/notify.js` | The browser's notifications while the page is open (a card opens, a session's prompt waits, a lead stops), asked once and toggled on This node; the title bar's count of what needs you. |
| `js/images.js` | A chat's pictures: their bytes asked of the node (`chat.image`) a part at a time, shown as object URLs, the newest 60 kept. |
| `js/composing.js` | The composer's word at the caret (`/` and `@`, as the app's composer finds it) and an image's parts for `session.attach`. In the box, `/` and `@` complete from the node (`session.complete`); a pasted or dropped image goes to the node and the draft names it; the messages the node holds behind a question show over the box. |
| `js/settings.js` | The settings' parts with no page in them: grouped by section, a change's `vibeswitcher set` line quoted as the shell needs, what a draft is checked against. |
| `js/push.js` | The push a lead asks for (the lead's `push`), in words: what goes where, its commits, and the two lines that settle it in a terminal; the card heads the lead's question stack. Nothing on the page pushes. |
| `js/activity.js` | The inspector's Activity, made from a chat's items: files changed with their line counts, commands run. |
| `js/views/` | `sidebar`, `session` (header and panes), `terminal` (the session's screen in xterm.js, where the node opens one), `chat`, `cards`, `inspector` (Team, Overview, Activity), `lead` (strip and the Team tab's tasks), `records` (under the tasks, on the Team tab and the board page: the scorecard, decisions, answered and withdrawn questions, files), `board`, `stats` (Statistics, `#/stats`: the node's `stats`, the Mac's window's words), `node`, `settings`, `start`, `palette`. |

## Keys

| Key | Does |
| --- | --- |
| ⌘K / Ctrl+K | Go to a session or run a command |
| ⌘J / Ctrl+J, ⌥J / Alt+J | Next session needing you |
| ⌥1–9 / Alt+1–9 (⌘1–9 where the browser gives it up) | Go to the nth session in the list |
| ⌥↓ ⌥↑ / Alt+↓ Alt+↑ | Next, previous session |
| ⌥F / Alt+F | Filter the list |
| ⌥⌘1 2 / Ctrl+Alt+1 2 | Terminal, Chat |
| ⌥⌘0 / Ctrl+Alt+0, ⌥0 / Alt+0 | Toggle Inspector (the Mac's View › Toggle Inspector) |
| ⌥⌘3 / Ctrl+Alt+3 | The inspector's Team tab, for a lead or a session of its team |
| Esc | Closes the inspector where it is a sheet |
| ↑ in an empty message box | Into the last open card |
| In a card: 1–9, ↑ ↓, ↩, H | Answer with that option; move; answer with the focused one; hold the timer |

## The inspector

The Mac's right pane (`InspectorView`), with its tabs and its names: **Team** (for a lead, and for a worker or a
verifier whose lead the node says), **Overview** (Status, Place, Time, Agent, and Team for a session with a role) and
**Activity** (the files a session changed with `+added −removed`, and the commands it ran). The button at the header's
end and ⌥⌘0 open and close it.

- **A column** from 1180px of window up: the session's own column gives it 320px in one step, what's centred there
  glides over (a transform), and the inspector fades in (opacity and transform, 160 ms; nothing with reduced motion).
  **A sheet** under that width, so the chat is never cramped: from the right over the chat on a narrow desktop, from the
  foot of the screen on a phone. Esc, its ×, or a touch beside it closes it.
- **Remembered in this browser** (`localStorage`, which may refuse: then for this page only): `vs.inspector` (`open` or
  `closed`, the column's; a sheet always starts closed) and `vs.inspector.tab`. Team remembered on a session with no
  team shows Overview there, and Team again back on a lead.
- **It shows what the node sent.** A fact the node doesn't send has no row; a tab it sends nothing for says so in one
  line. A value that comes and goes while you watch (the tool call running, what the session says) keeps its row, so
  nothing under it moves. Nothing is drawn while it is closed.

| Shows | From |
| --- | --- |
| Overview › Status: State, Since, Running, and what it says | `shownStatus`, `since`, `activity`, `detail` |
| Overview › Place: Folder, Runs in | `cwd` (as `~/…` with the node's `home`), `hosted` |
| Overview › Time: Started, Running for | `startedAt` |
| Overview › Place: Branch | `branch` (the node reads `GitBranch.current` at the session's changes) |
| Overview › Agent: Agent, Session, Process, Command, Size | `agent`, `agentSession`, `pid` and `terminal`, the host's `command` (credentials masked) and `size: { cols, rows }` |
| Overview › Usage: Tokens, Cost, Turns | `session.usage`, asked as the tab shows and every 15 s while it does: the transcript's last 2 MB read by the Mac's `ActivityFeed` (`partial` when the conversation began before them; `costPartial` when some turns carried no cost) |
| Overview › Team: Role, Lead, Task | `role`; `lead` (the project's id) and `boardTask` (a worker's or verifier's task slug on the board; the wire's `task` is what it works on, in words) |
| Team: the board's tasks; Lead: Questions, Held, Reports, its notice | the `boards` stream's board for the session's `lead`; the lead's `questions`, `held`, `reportsWaiting`, `notice` |
| Activity: files changed, commands run | the session's chat (the contract's §6): a tool's `detail` of type `edit`, `write` or `command`, and its `result` |
| Folders as `~/…` | the node's `home` |

How a session ended (the Mac's Exit) is on the ended session's own view: `status`'s `ended` entry's `exit`, its
status, the host's words for it (`exited 0`, `killed by SIGTERM`) and when; the node lists no ended session, so there
is no inspector for one.

The Mac's inspector also shows what no client field carries yet: a command's exit code, a file created or deleted (as
against written), and the Team tab's decisions, scorecard, answered questions and files.

## The chat's extras

- **Images.** A prompt's or a tool result's image is drawn from its bytes: `chat.image { session, id, offset }`, a read,
  answers a part (`{ mediaType, bytes, offset, data }`, base64, 192 KB of bytes at most) of an image the session's own
  chat holds, found by its id; never a path, only a PNG, JPEG, GIF or WebP its bytes agree with, at most 8 MB.
  `js/images.js` asks two images at a time, joins the parts into a `Blob` and shows its object URL (the CSP's
  `img-src 'self' blob:`, nothing else), and keeps the newest 60. Tapped, a picture opens wide. Where the node takes no
  `chat.image`, the row says the image's type and size.
- **A row's actions** (over it on hover, beside it on a touch screen): a prompt's Copy, Edit in Composer (the box holds
  the text; nothing is sent) and Send Again (a `session.draft`, as every message this page leaves); a reply's Copy as
  Markdown.
- **The whole chat**, from the palette: Copy Chat as Markdown and Export Chat… (a `.md` download), in the Mac's
  Export Chat words (`chatMarkdown`); Find in Chat (⌘F / Ctrl+F while the chat shows; ↩ next, ⇧↩ previous, Esc
  closes), over every item the page holds, the rows not drawn too (the browser's own find sees only those), the found
  row marked and its words highlighted (CSS Custom Highlights, where the browser has them). Each is of what the page
  has paged in, and says so while older items exist.

## The feed

`store.connect(feed)` takes anything with these four: `socket.js` (the node) and `mock.js` (`?mock`).

`socket.js` feeds the store per collection, as the wire carries it: `store.reconcile(name, values)` for a snapshot (by
id, in one notification: a list is never emptied first) and `store.change(name, [{ id, value }])` for a delta, after
it has run every frame through `wire/validators.js` and judged each subscription's order (`prev` and `seq`). Until
`hello` says otherwise (`store.can(kind)`, from `hello.kinds`; `store.follows(collection)`), the views offer only what
the connection may do: the node's page reads and drafts (`draft`, not `answer`), so a card's options leave a draft
(`store.draft`, an overlay kept until the cards stream reaches the ack's `applied`: `feed.reached`) and the card shows
the line that confirms it; a page that only reads shows `vibeswitcher answer …` with the options as text; the
terminal says it comes in a later build where `term.open` isn't among the kinds, as a lead's board does, and the chat says so where `chat.page` isn't among the kinds. `mock.js` keeps the older whole-state messages below for the keyed collections, which the store still takes:

```js
feed.start()                    // sends store.apply(snapshot), then deltas
feed.resync()                   // the store saw a gap: send a snapshot again
feed.subscribeChat(sessionId)   // follow a chat: store.chatSnapshot(id, { items, after, more }), then store.chatOps(id, ops)
feed.unsubscribeChat(sessionId) // no longer shown: its items stay, and it resumes from them when shown again
feed.pageChat(sessionId, before)  // → Promise of chat.page's reply: the items just before `before`
feed.request(message)           // → Promise of { ok: true, result } or { ok: false, error: { code, message } }
// socket.js only (the mock has no terminal, and its pane says so):
feed.sendBinary(bytes)          // a terminal's frame; false when the socket isn't up
feed.onBinary(fn)               // the node's frames, as ArrayBuffers, once authenticated; returns a function that stops them
feed.onLink(fn)                 // 'up' after each hello, 'down' when the connection dropped (a terminal's stream goes with it)
```

The terminal (`js/terminal.js`, `js/views/terminal.js`; the contract's §9) opens `term.open {session, cols, rows}` where
`hello.kinds` has it, holds the replay until its type 2 and draws it whole over a reset emulator (a resync or a
reconnect leaves the old screen up, dimmed, until the new one is whole), writes live bytes as they come, sends keys as
type 1 and the pane's fitted size as type 3, and closes with `term.close` when the pane is left. On the user's own node the reply says `readOnly`
(with the session's `cols` and `rows`, and each replay's type 5 says them again): the pane watches, drawn at the
session's size (scrolled when wider than the pane), with no cursor and no keyboard, nothing sent up, and a line saying
to type with `vibeswitcher send` in a terminal (the live plan's LW-D12, 2026-11-20). In a typed terminal the
keyboard is the program's (Ctrl+K, Ctrl+J and the rest), but for a Mac's ⌘ keys. The program can't reach past the
pane: OSC 52 (clipboard), OSC 8 (links) and the titles are swallowed, no link add-on is loaded, and the bell is
silent.

A chat is the wire's (the contract §6), in both feeds: items of `type` `prompt`, `reply`, `tools` (a run of tool calls,
with the node's `summary`) and `team`, and deltas of ops. A `text` op whose `at` isn't the length the page holds is a
gap: nothing of its delta is applied, and the chat asks for a tail from that item. The chat view draws only the rows
near what you see (two spacers stand in for the rest, at their measured heights), pages older items in as you scroll
up to them, keeps the row under your eyes where it is, and stays at the end only when it was there.

Messages are the design's live protocol ("State as snapshot and deltas"), in `NodeWire`'s envelope (`v`, `kind`):

```js
{ v: 1, kind: 'snapshot', epoch, seq, state: { node, sessions: [], leads: [], cards: [], boards: [] } }
{ v: 1, kind: 'delta', seq, changes: [change, …] }       // seq is the last one + 1; anything else is a gap

// A change is a store's `Changes<T>.Delta` (id, and the value now or null for gone), with the store it's in:
{ in: 'sessions' | 'leads' | 'cards' | 'boards', id, value }   // value null: removed
{ in: 'node', id: 'local', value }

// A request, as NodeWire.Request: `action` is a new UUID, sent again on a retry so it's done once.
{ v: 1, id, kind: 'draft' | 'draft.clear' | 'session.draft' | 'session.draft.clear' | 'session.attach' | 'seen' | …, args, action }

// A read (no action: nothing is sent again after a reconnect), e.g. what a session's / and @ complete to.
{ v: 1, id, kind: 'chat.page' | 'session.complete' | 'session.presets' | …, args }
```

A snapshot with another `epoch` (the server restarted) replaces everything and the open chats are asked for again. A
reader ignores collections and fields it doesn't know (rule 3).

## Shapes

Field names are the node's own where it has them. **In the node today** means `vibeswitcher status --json` or
`questions --json` already emits it (`Sources/VibeNode/Server/Requests.swift`, `CardRequests.swift`,
`Stores/LeadStore.swift`). **Asked of the node** means the client needs it and the server doesn't send it yet.

### Session

From the node, `js/wire.js` maps the contract's session (§5) to this: `status` is its `shownStatus`, `title` its
`name` (yours, `vibeswitcher rename`) else its `task`, `detail` its `activity` (else `detail`), `paused` whether it has
a `pausedUntil` (`vibeswitcher pause`), and `lead` the project of the lead whose `session` it is. A worker's or
verifier's `lead` isn't on the wire yet, so it is listed on its own.

```js
{
  // In the node today (Requests.value(_: Session)):
  id: 'local:7d3c9a10-…',     // NodeIds.session: host id, or 'local:pts/9' for one the host doesn't run
  terminal: 'pts/3',
  agent: 'claude',            // or 'codex'
  cwd: '/home/dev/projects/example-site',   // null when unknown
  status: 'needs-you',        // needs-you, working, background, done, idle, unknown (Requests.statusWord)
  since: '2026-11-17T09:02:11.000Z',
  hosted: true,               // false: it runs in another terminal; listed and readable, never typed into
  role: 'lead',               // lead, worker, verifier, or null
  // Asked of the node:
  title: 'Sync the landing pages…',   // your name for it, else what it's working on (the Mac row's title)
  detail: 'Resolving the hero’s conflicts',   // what it's doing or asking (Session.detail)
  paused: false,
  lead: 'local:project:Zx3k…',        // for a lead, worker or verifier: the project's id (NodeIds.project)
  task: 'sync-landing-base',          // a worker's or verifier's task slug
  // For the inspector's Overview (the node sends `startedAt`, `activity` and `activitySince` today):
  startedAt: '2026-11-17T08:40:02.000Z',
  activity: 'Run unit tests',         // the tool call it runs right now, null between two
  branch: 'landing-base',             // its folder's git branch
  agentSession: '01a9c3d7-…',         // the agent's own session id
  pid: 51022,
  command: 'claude',                  // what the host started in its terminal; null for one the host doesn't run
  size: { cols: 132, rows: 38 },      // its terminal's; null for one the host doesn't run
}
```

### Lead (in the node today: `LeadStore.Lead.value` and `Requests.leadValue`)

```js
{ project: 'local:project:Zx3k…', root: '/home/dev/projects/example-site', session: 'local:7d3c…', named, bound,
  replaced: [], held: 0, reportsWaiting: 0, notice: null, starting: false, lastStart, lastStartAt,
  looks: 14, questions: { open: 1, blocking: 1 }, cards: ['local:card:…'] }
```

### Card (in the node today: `CardStore.Card.value`)

```js
{
  id: 'local:card:5b1f…', kind: 'question',   // question, approval, config, base
  project, root, open: true, closed: null, notice: null, at, blocking: true,
  question: {                                 // on a question and on an approval
    id, short, text, options: ['Thursday', 'Wait for the fixes'],
    priority: 'blocking',                     // blocking, important, whenever
    whyNow, version: 2, revisionNote, proposal: null,
    decideBy: null,                           // a date only while the timer counts
    state: 'open',                            // open, answered, withdrawn, autoDecided
    answer: null, answeredVersion: null, withdrawReason: null, task: null,
  },
  approval: {                                 // on an approval: git's and the vault's facts, never the lead's words
    commit, tasks: [], base, files: [], diffstat, subject, verdicts: { task: 'complete, clean at …' },
    sensitive: [],                            // null: couldn't be vouched for
    problems: [],
  },
  // config: { items, guarded, lastAccept, floor, baseBranch } and base: { branch, from, fromIs, to, reason, commits }
  // are the node's too; this slice draws neither.
}
```

A question with a `proposal`, no `decideBy` and still open is read as **held**. Asked of the node: `heldAt`, so that
isn't an inference.

### Board (in the node: `BoardValue`, the `boards` collection by project; `vibeswitcher board --json` gives the same)

```js
{ project: 'local:project:Zx3k…', root: '/home/dev/projects/example-site', baseBranch: 'landing-base',
  counts: { attention: 1, running: 2, waiting: 1, done: 1 }, more: 0,   // more: tasks past the 150 sent
  unreadable: null,                                          // why the board can't be shown (too large, not a board)
  tasks: [{
    id, slug: 'sync-landing-base', title, status: 'running',   // LeadTask.Status: planned, running, review, done, failed,
                                                               // blocked, kept, folded, abandoned, reverted
    group: 'running',                                          // attention, running, waiting, done (BoardValue.groups)
    state: 'Rework 1', line: 'Rebased onto main…',             // the Mac's Team words, and the dim line under it
    blocker: null,                                             // a blocked task's blocker, its lines kept (at most 40)
    worker: 'local:1b8e…', verifier: null,                     // session ids (only a host's UUID), for its chat
    review: 'audit', position: 0, createdAt, since, startedAt, attempts: 2, budgetMin: 60, overBudget: false,
    branch: 'agent/sync-landing-base', after: [],              // slugs it waits on
    checkpoint: { text, at }, audit: { verdict, open, findings, rounds }, merged: { commit, at, tested },
  }] }
```

Every string in it is the sessions' writing made inert by the node (controls replaced, each capped). A finished task is
sent for a day after it finished; the page shows those of today.

### Chat item (in the node: `ChatValue`, the contract §6)

```js
{ id, type: 'prompt', at, text, steered, fromLead, images: [{ id, mediaType, bytes }] }   // an image: no bytes (`chat.image` asks them)
{ id, type: 'reply', at, text }                    // markdown, drawn to nodes by text.js
{ id: 'tools:<first tool id>', type: 'tools', at, summary: 'Ran 3 commands · edited 2 files',
  tools: [{ id, name, title, at, detail: { type: 'command', command } /* read, edit, write, thought, todos, … */,
            result: { output, truncated, failed, at, images } /* null while it runs */ }] }
{ id, type: 'team', at, text, title, sender: { kind, name, task }, message: 'report', task, part }   // a TeamMessage
```

The mock adds `{ type: 'ask', title, text, options, answer }` (the agent's own prompt on its screen), `streaming` on a
reply, and `action` on a prompt this page sent.

### The node (in the node today: `status`'s result and what `status --json` adds)

```js
{ node: 'local', epoch, root: '/home/dev/.vibeswitcher',
  server: { pid, startedAt, commit },
  host: { pid, startedAt, state: 'connected', liveSessions,
          notes: { startedAt, serverRestarts, replacedPaths: [], refusedAppConnections, lockHeldElsewhere, build, at } },
  rule: { mode, says, scopes: [] },
  cards: { questions, approvals, config, base },
  accepted: [{ kind, action, at, pid, cgroup, commandLine: [] }],
  notices: ['…'], restart: null,
  builds: { installRoot, installed: [], rollback: { commit, line } },
  facts: ['plain mode: …'], journal: ['journal: …'],          // the command line's own reads, under --json
  home: '/home/dev' }                                         // asked of the node: to write folders as ~/…
```

## What isn't here yet

The terminal on the user's own node (a scratch node's only, LW-D12), starting and ending sessions, Settings, held-config and base-move cards, the
scorecard and the rest of the Mac's Team tab (decisions, answered questions, files), notifications, the manifest and service worker, and the device key: an approval here is a click, where the
design signs the card's facts (security rule 1).
