# WebApp: VibeSwitcher's web client

The client for a VibeSwitcher 2 node (`docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`, "The web client"
and "Stage 5"). This is its first slice: the frame, the session list, a session's chat, a lead's team and questions,
and the node's status, on invented data. It needs no server.

```sh
WebApp/serve.sh                     # http://127.0.0.1:8765/
bash scripts/test.sh --web WebApp/tests
```

| Address | Shows |
| --- | --- |
| `/` | The mock node: a lead's team moves tasks across its board, a question arrives, sessions finish. |
| `/?still` | The same snapshot with nothing happening after it (for screenshots). |
| `/?empty` | A node with no sessions. |
| `/?rows=10000` | One session ("Add dark mode…") with a 10,000-row chat. |
| `/?theme=dark`, `/?theme=light` | The other look, whatever the system says. |

Screenshots of each screen, light and dark, desktop and phone, are in `shots/`.

## Rules

- **No build step, no npm, no dependency.** Plain ES modules and one stylesheet. The design's candidates for later
  (Preact, xterm.js) aren't here; nothing is vendored.
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
| `js/mock.js` | Stands in for the node. **The WebSocket feed replaces this file and nothing else.** |
| `js/ui.js` | What this window shows: the route (`#/s/<id>`, `#/node`), grouping, filter, panes; the list's arrangement. |
| `js/words.js` | The vocabulary: state words, durations, a task's words (from `VibeCore`). |
| `js/dom.js`, `js/marks.js`, `js/text.js` | Building nodes; status marks, agent badges, icons; markdown and diffs as nodes. |
| `js/views/` | `sidebar`, `session` (header and panes), `chat`, `cards`, `lead` (strip and Team pane), `node`, `start`, `palette`. |

## Keys

| Key | Does |
| --- | --- |
| ⌘K / Ctrl+K | Go to a session or run a command |
| ⌘J / Ctrl+J, ⌥J / Alt+J | Next session needing you |
| ⌥1–9 / Alt+1–9 (⌘1–9 where the browser gives it up) | Go to the nth session in the list |
| ⌥↓ ⌥↑ / Alt+↓ Alt+↑ | Next, previous session |
| ⌥F / Alt+F | Filter the list |
| ⌥⌘1 2 3 / Ctrl+Alt+1 2 3 | Terminal, Chat, Team |
| ↑ in an empty message box | Into the last open card |
| In a card: 1–9, ↑ ↓, ↩, H | Answer with that option; move; answer with the focused one; hold the timer |

## The feed

`store.connect(feed)` takes anything with these four, which is all `mock.js` is:

```js
feed.start()                  // sends store.apply(snapshot), then deltas
feed.resync()                 // the store saw a gap: send a snapshot again
feed.subscribeChat(sessionId) // send that chat's rows, then its deltas
feed.request(message)         // → Promise of { ok: true, result } or { ok: false, error: { code, message } }
```

Messages are the design's live protocol ("State as snapshot and deltas"), in `NodeWire`'s envelope (`v`, `kind`):

```js
{ v: 1, kind: 'snapshot', epoch, seq, state: { node, sessions: [], leads: [], cards: [], boards: [] } }
{ v: 1, kind: 'delta', seq, changes: [change, …] }       // seq is the last one + 1; anything else is a gap
{ v: 1, kind: 'chat', session, items: [item, …] }        // a chat subscription's first answer

// A change is a store's `Changes<T>.Delta` (id, and the value now or null for gone), with the store it's in:
{ in: 'sessions' | 'leads' | 'cards' | 'boards', id, value }   // value null: removed
{ in: 'node', id: 'local', value }
{ in: 'chat', session, id, value }                             // a new or replaced row; null: removed
{ in: 'chat', session, id, append: { text: ' more words' } }   // a streaming row's text grows

// A request, as NodeWire.Request: `action` is a new UUID, sent again on a retry so it's done once.
{ v: 1, id, kind: 'answer' | 'hold' | 'send' | 'ask.answer' | 'seen', args, action }
```

A snapshot with another `epoch` (the server restarted) replaces everything and the open chats are asked for again. A
reader ignores collections and fields it doesn't know (rule 3).

## Shapes

Field names are the node's own where it has them. **In the node today** means `vibeswitcher status --json` or
`questions --json` already emits it (`Sources/VibeNode/Server/Requests.swift`, `CardRequests.swift`,
`Stores/LeadStore.swift`). **Asked of the node** means the client needs it and the server doesn't send it yet.

### Session

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

### Board (asked of the node; the fields are `LeadTask`'s, `Sources/VibeCore/LeadBoard.swift`)

```js
{ project: 'local:project:Zx3k…', baseBranch: 'landing-base',
  tasks: [{
    id, slug: 'sync-landing-base', title, status: 'running',   // planned, running, review, done, failed, blocked,
                                                               // kept, folded, abandoned, reverted
    since, worker: 'local:1b8e…', verifier: null,              // session ids
    branch: 'agent/sync-landing-base', after: [],              // slugs it waits on
    checkpoints: [{ text, at }], blocker: null,
    merged: null,                                              // { commit, at, tested }
  }] }
```

### Chat item (asked of the node; the kinds are `ChatEntry.Kind`'s, `Sources/VibeCore/ChatTranscript.swift`)

```js
{ id, kind: 'prompt', text, at, action }        // action: the id of the request that sent it, when this client did
{ id, kind: 'reply', text, at, streaming }      // markdown; grows by `append` while streaming
{ id, kind: 'tool', name: 'Bash', title, at,    // title as ToolActivity.describe writes it
  detail: { type: 'command', command }          // or { type: 'read', path }, { type: 'edit', path, changes: [{ old, new }] }
  result: { output, failed, at } }              // null while it runs
{ id, kind: 'team', from: 'worker', title, text, at }           // a TeamMessage
{ id, kind: 'ask', title, text, options: [], answer, at }       // the agent's own prompt on its screen
```

The client folds a run of `tool` items into one line ("Ran 2 commands · edited 1 file"), as `ChatTimeline` does.

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

The terminal (a placeholder pane), starting and ending sessions, Settings, held-config and base-move cards, the
scorecard, notifications, the manifest and service worker, and the device key: an approval here is a click, where the
design signs the card's facts (security rule 1).
