# VibeSwitcher 2: the live wire contract (first slices)

**Status:** written 2026-11-17 against `v2` `f62aef61`. It is the contract the tasks of
[the live protocol and web plan](../plans/2026-11-17-v2-live-protocol-and-web.md) build against: a backend agent and a
frontend agent each need only this file. Where it and the code disagree after a task lands, the task's vectors
(`WebApp/wire/vectors.json`, generated from `VibeNode`'s types) win and this file is corrected in the same commit.

It specifies what [the design](2026-11-12-vibeswitcher-2-design.md#the-live-protocol) calls the live protocol, for the
first slices only: a read-only live page (node, sessions, leads, cards), then the chat, then drafted answers, then the
terminal's outline. Decisions are numbered LW-D1 and up in the plan; this file states their result.

**What "seamless" asks of the wire** (the user's words: slick, calm, clean, real-time):

| Guarantee | Where it is specified |
| --- | --- |
| A store's change is a frame on the socket with no timer between; under 100 ms at p95 from change to frame | [Deltas](#deltas), [Budgets on the wire](#7-budgets-on-the-wire) |
| Deltas of one subscription are strictly ordered and idempotent by sequence number | [Sequence numbers](#sequence-numbers-and-the-epoch) |
| A reconnect resumes without a snapshot when the server still can, and never shows an empty list | [Resume](#resume), [The client's resume logic](#the-clients-resume-logic) |
| A server restart is invisible: under 2 s, no lost row, no duplicate row | [Across a server restart](#across-a-server-restart) |
| An action shows at once, and its ack or refusal reconciles it exactly once | [Actions](#8-actions) |
| A growing message is sent as appended text, not as the whole row | [Chat ops](#chat-ops) |

## 1. Transport

The messages are `NodeWire`'s (`Sources/VibeNode/Server/NodeWire.swift`): JSON objects, compact, UTF-8, each with `v`.
Two carriers, the same objects on both:

| Carrier | Framing | Who | First message |
| --- | --- | --- | --- |
| The server's Unix socket, `<root>/v2/server.sock` (exists today) | JSON lines, at most `NodeWire.maxLine` (1 MiB) a line | the command line, the tests | the server's `hello`, unasked, as today |
| A WebSocket on `ws://127.0.0.1:<port>/ws` (new) | one JSON object per **text** frame; **binary** frames are the terminal's only ([§9](#9-the-terminal-slice-4)) | the web client | the client's `auth`; the server says nothing before it |

Three kinds of message:

- **A request** (`NodeWire.Request`): `{v, id, kind, args?, action?, must?}`, client to server. `id` is the client's
  own, unique on the connection.
- **A reply** (`NodeWire.Reply`): `{v, re, ok, result?, error?}`, exactly one per request.
- **An event**: `{v, kind, …}` with no `re`, server to client, unasked: `hello`, `bye`, `snapshot`, `delta`.

### The WebSocket listener

- Bound to `127.0.0.1` only (never `0.0.0.0`, never `::`), on one port (`NodeWeb.port`, 47830; a scratch server takes
  `--test-web-port=`, 0 for one the kernel picks). A port already taken refuses the web, said in `status`; it never
  falls back to another port.
- **Off until asked.** The listener exists only while a pairing code or a token is alive ([§2](#2-authentication)). A
  node whose user never ran `vibeswitcher web` has no TCP listener.
- HTTP/1.1, `GET` only. Every request is refused (421, no body) unless its `Host` is exactly `127.0.0.1:<port>`: the
  listener trusts no other header, and no name (not `localhost`, not a tailnet name).
- `GET /ws` with `Upgrade: websocket` is the only upgrade. It is refused (403) unless `Origin` is exactly
  `http://127.0.0.1:<port>`; a missing `Origin` is refused; a `Sec-Fetch-Site` that is present and not `same-origin`
  is refused. No subprotocol, no extension (`permessage-deflate` is not offered).
- Every other path serves one embedded file of `WebApp/` by exact match against the embedded list, or 404. There is
  no file-system read on the user's node. The response headers are in the plan's Security section.
- **No cookie is set or read.** Cookies on `127.0.0.1` are shared across ports, so another local server would be sent
  them.
- Limits: request head 8 KiB; 5 s to finish the handshake and 5 s more to send `auth`; a client text frame at most
  64 KiB; a server frame at most 1 MiB; at most 32 connections; a ping from the server every 15 s, and a connection
  that misses two is closed. A fragmented message is taken; a client frame that isn't masked closes the connection
  (RFC 6455 §5.1).

Close codes the server uses, each after a `bye` whose `code` says the same: 1001 (the node is stopping), 1009 (a frame
too long), 4400 (not a JSON object, or not a request), 4401 (`auth` refused, or no `auth` in time), 4403 (the token was
revoked or ran out), 4426 (a newer `v` than the server's).

## 2. Authentication

### Slice 1: a pairing code, then a token that reads

1. The user runs **`vibeswitcher web`** in a terminal. It is a user's-voice request (`web.open`, S3's rule: the
   cgroup, the ancestry, the terminal) behind the typed code from its action id, recorded in the vault like every
   state change. The server makes a **pairing code** (16 random bytes, base64url), valid 120 s, taken once, and starts
   the listener if it wasn't up. The command line prints `http://127.0.0.1:<port>/#pair=<code>`.
2. The page reads the code from the fragment (a fragment is never sent in a request nor in `Referer`), removes it
   from the address bar (`history.replaceState`) and sends it in `auth`.
3. The server answers `hello` with a **token** (32 random bytes, base64url). The page keeps it in `sessionStorage`
   (this origin's, this tab's) and sends it in `auth` on every later connection.
4. The server keeps each token's SHA-256, never the token, in `<root>/v2/web-tokens.json` (0600, format 1), so a page
   reconnects by itself after the server restarts. A token lives 24 h from its issue; at most 8 are alive, the oldest
   dropped. `vibeswitcher web --revoke` (`web.revoke`, the user's voice) drops them all and closes their connections
   with 4403; with none left and no code pending the listener closes.

**What a token is worth.** `read`: the node, the sessions, the leads, the cards and the chats, which is what any
process of the user's uid already reads (`status` and `questions` take anyone of the uid; transcripts are the user's
files). `draft`: it may leave a draft answer on a card ([§8](#8-actions)), which does nothing until the user confirms
it on the command line. It is **never the user's voice**: it answers no card, holds none, starts, stops or types
nothing. So a token stolen from the browser's storage, or a file the user's own processes can write, gives nothing a
process of the user didn't have. What the token adds is a lock where the Unix socket had the uid check: against other
users, against a page of another origin, and (mirrored networking) against Windows-side processes.

**Deferred**, in the order the design gives: device keys and first-frame signatures, rights per device, revoking one
device, signed approvals (rule 7), the host owning the listener (the design's requirement 4; LW-D1), the remote
listener. When device keys come, `auth` gains `device` and `sig`; `pair` and `token` stay for a loopback page that
only reads.

### The first frame

Client, first text frame (anything else first is `bye` and 4401):

```json
{"v":1,"id":"0","kind":"auth","args":{"pair":"k3J1mZ0vY8q2Xw5rT7uB9A","client":"webapp","assets":"9f2c61d0"}}
```

or, on every later connection: `"args":{"token":"…","client":"webapp","assets":"9f2c61d0"}`. `assets` is the page's
own build (`/build.json`'s `assets`).

Server, on success: `hello`, `NodeWire.Hello`'s fields as today plus `auth` and `assets`:

```json
{"v":1,"kind":"hello","node":"local","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10",
 "server":{"commit":"f62aef61","startedAt":"2026-11-17T09:12:44.031Z","pid":41822},
 "host":{"startedAt":"2026-11-17T08:01:10.555Z","pid":41790},
 "kinds":["status","questions","subscribe","unsubscribe","chat.page","draft","draft.clear"],
 "peer":{"voice":"other","why":"a web client: it reads and drafts, and is never the user's voice"},
 "rule":"systemd",
 "auth":{"rights":["read","draft"],"token":"Zb1…43 characters…","expiresAt":"2026-11-18T09:14:03.120Z"},
 "assets":"9f2c61d0"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `host.notes` | object, optional | the host's notes as last asked; left out (not `null`) when the server has none yet |
| `epoch` | string (UUID) | made at each server start (`Requests.epoch`). A different one than last time: the server restarted |
| `kinds` | [string] | the request kinds this connection may send. A web connection's list is the read and draft kinds only |
| `peer.voice` | `"user"` \| `"other"` | always `"other"` on a WebSocket |
| `auth.rights` | [string] | `read`, `draft`. A right the client doesn't know is ignored |
| `auth.token` | string, optional | only in answer to `pair`: the token to keep |
| `auth.expiresAt` | date | when the token stops being taken |
| `assets` | string | the build of the web files this server holds. Different from the page's own: the page reloads once it is idle (rule 3: "a client older than the server says so and reloads") |

On failure the server sends `{"v":1,"kind":"bye","code":"auth","reason":"…"}` and closes with 4401. The reason never
says whether a code was wrong, used or late.

On the Unix socket nothing changes: `hello` first, unasked, with no `auth`; the peer's uid and process are the
authentication, as S3 describes.

## 3. Subscribe

```json
{"v":1,"id":"7","kind":"subscribe","args":{"sub":"s1","collection":"sessions"}}
```

| Arg | Type | Meaning |
| --- | --- | --- |
| `sub` | string, 1 to 32 of `[A-Za-z0-9._-]` | the client's name for the subscription, unique on the connection. Subscribing again under a live `sub` replaces it |
| `collection` | `"node"` \| `"sessions"` \| `"leads"` \| `"cards"` \| `"chat"` | what to follow |
| `key` | string | `chat` only: the session's id |
| `since` | `{"epoch": string, "seq": int}`, optional | what the client already holds: [Resume](#resume) |
| `after` | string, optional | `chat` only: the id of the last item the client holds, for a resume across a restart (the server sends that item again, as it is now, and what followed) |
| `limit` | int, optional | `chat` only: how many of the newest items a snapshot carries (default 200, at most 500) |

Reply: `{"v":1,"re":"7","ok":true,"result":{"sub":"s1","mode":"snapshot"}}`. `mode` is `snapshot` (a `snapshot` event
follows), `resume` (no snapshot: deltas follow from the client's `seq`) or `tail` (`chat`: a snapshot of what came
after `after`). The first event of the subscription follows the reply at once.

`unsubscribe` with `{"sub":"s1"}` ends it; the reply is `{}`. Events already written may still arrive: the client
drops events of a `sub` it doesn't hold. A client subscribes to what it shows and to nothing else.

Who may subscribe: `node`, `sessions`, `leads`, `cards` and `chat` take anyone of the uid on the Unix socket and a
token with `read` on the WebSocket. Errors: `bad-args` (no such collection, a `sub` out of form, `chat` without
`key`), `gone` (`chat` for a session that isn't there or has no transcript).

## 4. Snapshots, deltas, order

### Sequence numbers and the epoch

- Every **stream** (one per collection; one per session for `chat`) has a sequence number, `seq`, kept by the server:
  it starts at 0 when the stream is made and goes up by one at each change of the stream. It belongs to the stream,
  not to a connection: two clients see the same numbers.
- `epoch` scopes every `seq`. A `seq` from another epoch means nothing.
- A `snapshot` says: this is the stream at `seq`. A `delta` says: applying me takes the stream from `prev` to `seq`
  (`prev` < `seq`). A delta may cover several changes (`seq` − `prev` > 1) when the server folded them: it then
  carries where each entry is now, never a backlog of where it was (`Changes`' rule, kept on the wire).

**The client's rule, the whole of it** (per subscription, `mine` = the `seq` it holds):

| The event | The client |
| --- | --- |
| `snapshot` | takes it: reconciles ([below](#snapshots)), `mine` = its `seq` |
| `delta` with `prev` = `mine` | applies it, `mine` = its `seq` |
| `delta` with `seq` ≤ `mine` | drops it (a duplicate): applying is idempotent because it is never done twice |
| any other `delta` (`prev` > `mine`: a gap; or `prev` < `mine` < `seq`) | applies nothing, and subscribes again under the same `sub` with `since` = `{epoch, mine}` |

The server never sends a subscription's events out of order, and never sends a delta whose `prev` isn't the `seq` of
the event it sent before on that subscription. So a client that follows the table never reorders, never applies twice
and never skips.

### Snapshots

Keyed collections (`node`, `sessions`, `leads`, `cards`):

```json
{"v":1,"kind":"snapshot","sub":"s1","collection":"sessions","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":41,
 "entries":[{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","value":{"…":"a session, §5"}}]}
```

`entries` is every entry of the stream at `seq`, each `{id, value}`; the order is the server's (sessions by terminal,
leads by root, cards by `at` then id) and a client may sort its own way. **A snapshot is reconciled, not painted
over:** the client keeps each row whose id is in `entries` (updating its value in place), adds the new ones, removes
the ones no longer there, all in one render. It never empties the list first.

### Deltas

```json
{"v":1,"kind":"delta","sub":"s1","prev":41,"seq":42,"at":"2026-11-17T09:14:05.482Z",
 "changes":[{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","value":{"…":"the session's whole new value"}}]}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `prev`, `seq` | int | as above |
| `at` | date | when the server took the newest change in it (for the bench and the page's lag reading; not for order) |
| `changes` | [{`id`, `value`}] | keyed collections: each entry's value now, whole; `value: null`: it is gone. One per id, in the order the ids first changed |
| `ops` | [op] | `chat` only, in place of `changes`: [Chat ops](#chat-ops) |

**No timer sits between a store's change and its frame.** The hub writes the delta on the turn of the engine's queue
that follows the change. Folding happens only while a connection's socket can't take bytes (its buffer is full): what
changed meanwhile goes as one folded delta when it can. Nothing is dropped; a slow client is late, never wrong.

### Resume

`subscribe` with `since: {epoch, seq}`:

- **The same epoch, and the stream still knows what changed after `seq`:** the reply's `mode` is `resume`, no snapshot
  is sent, and the next event is a delta with `prev` = the client's `seq` (or nothing, until something changes, when
  the client was already current).
- **Otherwise** (another epoch, a `seq` ahead of the stream's, or older than the stream remembers): `mode` is
  `snapshot`, or `tail` for a chat whose `after` item the server finds.

**What the server keeps to answer a resume** (in memory, per stream, nothing at rest):

| Stream | Kept | A resume is answered while |
| --- | --- | --- |
| keyed | each entry's value and the `seq` at which it last changed; the last 256 removed ids, each with the `seq` of its removal | `since.seq` ≥ the `seq` of the oldest removal forgotten. The catch-up is one delta: every entry changed after `since.seq`, every id removed after it |
| `chat` | the items, each with the `seq` of its last change, and the last 512 ops | `since.seq` ≥ the `seq` before the oldest op kept. The catch-up is those ops, as one delta |

A chat stream with no subscriber is dropped after 60 s; a resume after that is a `tail`.

### Across a server restart

A restart makes a new epoch and forgets every `seq`. The rule that keeps it invisible:

- Keyed collections are small (tens of entries): the client gets a snapshot and reconciles by id. Session ids and
  project ids are the same across a restart (`NodeIds`); a row doesn't move or blink.
- **Card ids are not** (the cards are the server's memory, S3): after a restart a lead's question comes back under a
  new card id. A client keeps a card's place and its unsent draft by matching `project` and `question.id` when the id
  is gone and a new card has the same pair.
- A chat resumes by content: the client sends `after` (its last item's id; item ids come from the transcript and
  survive). The server answers a `tail` snapshot: the client keeps every item before `after`, and replaces that item
  and what followed with the snapshot's `items`, whose first is that item as it is now (its text may have grown, a
  tool's result may have come). No item is lost, none shows twice. If the server doesn't find `after`, it sends a
  whole snapshot (`after: null`), reconciled by item id.

### The client's resume logic

```
on close or error:
    keep every row, every item and every pending action as they are   (no empty state, no spinner over the list)
    mark the connection "reconnecting" (a quiet mark; the rows stay usable to read)
    retry at 100 ms, 200 ms, 400 ms, then every 1 s                    (a restart is back inside 2 s)
on open:
    send auth {token}
on hello:
    if hello.assets ≠ mine: remember to reload when nothing is pending
    for each subscription the views still hold:
        subscribe {sub, collection, key, since: {epoch: the epoch its seq came from, seq: mine}, after (chat)}
    for each action still pending: send its request again, with the same action id
on snapshot / delta: the table above
```

## 5. Entities

Every value below is what the server's own encoder writes today (`Requests.statusValue`, `LeadStore.Lead.value`,
`CardStore.Card.value`), with the additions marked **new**. Dates are ISO 8601 with milliseconds, UTC
(`NodeWire.dateText`). `T?` is `T` or `null`; a field is always present unless marked optional. Rule 3: a reader
ignores a field it doesn't know.

**Text an agent or a lead wrote is data.** Fields marked † hold words of a lead, a worker, git or a path: the client
shows them as text nodes only, never as markup, and the command line prints them inert.

### `node`: one entry, id = the node's (`"local"`)

`status`'s result without `sessions` and `leads` (their own collections).

| Field | Type | Meaning |
| --- | --- | --- |
| `node` | string | the node's name in every id (`NodeIds.node`) |
| `epoch` | string | the server's epoch |
| `root` | string † | the node's root folder |
| `server` | `{pid: int, startedAt: date, commit: string}` | the server process and its build |
| `host` | object | the session host as the server sees it |
| `host.startedAt` | date? | when the host first started; null before its welcome |
| `host.pid` | int? | |
| `host.state` | string | `connecting`, `connected` or `gone: <why>` (`HostLink.State`) |
| `host.liveSessions` | int | the host's live sessions (what `stop` would end) |
| `host.notes` | object? | `HostNotes` as last asked: `startedAt` date, `serverRestarts` int, `replacedPaths` [string] †, `refusedAppConnections` int, `lockHeldElsewhere` string?, `build` string?, `at` date (when asked) |
| `rule` | `{mode: string, says: string, scopes: [string]}` | the voice rule: `mode` is `systemd`, `weaker` or `closed` |
| `cards` | `{questions: int, approvals: int, config: int, base: int}` | open cards counted by kind |
| `accepted` | [object] | the last 50 user's-voice requests taken: `kind` string, `action` string?, `subject` string? †, `at` date, `pid` int, `cgroup` string?, `commandLine` [string] † |
| `notices` | [string] † | what the node has to say, each a sentence the server built (the node stopping; a lead whose board names a session the vault doesn't bind; a base move that refused a merge; a host restart; a lead with no role). Shown as they are, in order |
| `restart` | object? | the last host restart while its notice stands: `at` date, `before` date, `gone` [string] † (roots), `reset` string, `sessions` int (the user's own sessions it ended, still offered; 2026-11-20) |
| `reopen` **new** (2026-11-20) | [object] | the user's own sessions the last host restart ended, offered to `vibeswitcher reopen`: `session` string (the id they had), `folder` string †, `name` string †, `conversation` string? † (Claude's id; null: unknown, so it can't be reopened) |
| `builds` | object? | the installed builds (`SwitchRequest.buildsValue`); null on a server with no install root |
| `web` **new** | `{state: string, port: int?, tokens: int, connections: int}` | the web listener: `state` is `off`, `listening` or `refused: <why>` |

### `sessions`: id = `NodeSessions.id(of:)`

`local:<host uuid, lower case>` for a session the host runs, else `local:<terminal>`.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | as above |
| `terminal` | string | the terminal's name (`Session.tty`) |
| `agent` | `"claude"` \| `"codex"` | |
| `cwd` | string? † | where the agent is now |
| `status` | string | `needs-you`, `working`, `background`, `done`, `idle`, `unknown` (`Requests.statusWord`). A word the client doesn't know shows as `unknown` |
| `since` | date | since when `status` holds (`statusSince`) |
| `hosted` | bool | the session host runs it (so it can be attached, later) |
| `role` | `"lead"` \| `"worker"` \| `"verifier"` \| null | its team role, from its label |
| `shownStatus` **new** | string | the status as the user reads it (`Session.shownStatus`): a lead with a question open is `needs-you`, a team member waiting on its lead is `working`. The list shows this one |
| `project` **new** | string † | the headline: the folder it was started in |
| `task` **new** | string? † | what it is working on, when known |
| `detail` **new** | string? † | |
| `activity` **new** | string? † | the tool call it runs right now ("Run unit tests") |
| `activitySince` **new** | date? | |
| `startedAt` **new** | date | |
| `hasHooks` **new** | bool | false: its status is read off its title alone |
| `leadAsks` **new** | bool | a lead with a question for the user open |
| `startFolder` **new** | string? † | the folder its hosted session was started in (a lead's board is found by it) |
| `backgroundJobs` **new** | int | shells still running under it |
| `hasTranscript` **new** | bool | `chat` can be subscribed for it |

### `leads`: id = the project's (`NodeIds.project(root:)`)

`LeadStore.Lead.value` with what `status` adds (`Requests.leadValue`).

| Field | Type | Meaning |
| --- | --- | --- |
| `project` | string | the id: `local:project:` and 12 characters of base64url, a hash of the root (`NodeIds.project(root:)`); no path in it |
| `root` | string † | the repository's top |
| `session` | string? | the live lead session's id (a `sessions` id), if one runs |
| `named` | string? | the session the board names as the lead |
| `bound` | string? | the session the vault binds the lead's role to |
| `replaced` | [string] | live lead sessions another replaced (session ids) |
| `held` | int | messages waiting for the lead |
| `reportsWaiting` | int | reports that have waited for it too long |
| `notice` | string? † | what is wrong with delivering to it, when something is |
| `starting` | bool | a start is under way |
| `lastStart` | string? | what the last start said: `started`, `shown`, `waiting`, or a refusal † |
| `lastStartAt` | date? | |
| `looks` | int | how many of the witness's looks the server applied for it |
| `questions` | `{open: int, blocking: int}` | its open question and approval cards |
| `cards` | [string] | its open cards' ids |

A lead's **board** is the `boards` collection, keyed by project (`BoardValue`, `Sources/VibeNode/Live/BoardValue.swift`;
the schema's `board` and `board.task`; the vectors `subscribe.boards`, `snapshot.boards`, `delta.board-task`, `board`):
one value per project with a lead, its tasks as a person reads them (`group`: attention, running, waiting, done;
`state` in the Mac's Team words; a dim `line`; a blocked task's `blocker`; its worker's session id; review, times,
attempts, budget, last checkpoint, audit, merge), at most 150 tasks (`more` counts the rest), a finished one for a day.
Not `LeadBoard` as it encodes itself: the board is the sessions' writing, so every string is inert and capped, no path
is sent, and a board that can't be read is `unreadable` with no tasks. A change of the board file is a delta carrying
the project's whole value. Read-only: no kind changes a board. `board` (anyone of the uid, args `folder?`) answers
`{boards: [value]}`, `gone` for a folder with no lead.

### `cards`: id = the card's (`local:card:<uuid>`)

`CardStore.Card.value`, every card the server holds, open and closed (a client filters on `open`). A card that closes
arrives as a delta with `open: false`; one the server forgets arrives as `value: null`.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | |
| `kind` | `"question"` \| `"approval"` \| `"config"` \| `"base"` | `CardStore.Kind` |
| `project` | string | the lead's project id |
| `root` | string † | |
| `open` | bool | |
| `closed` | string? | how it closed, when it did |
| `notice` | string? † | what became of an answer that wasn't simply taken |
| `at` | date | when the card was made |
| `blocking` | bool | it blocks the lead's work |
| `question` | object, optional | on `question` and `approval` cards, below |
| `approval` | object, optional | on `approval` cards, below |
| `config` | object, optional | on `config` cards: `items` [{`name` †, `changedAt` date?, `size` int?, `hash`, `change` string? †, `outside` bool, `files` [string] †, `sinceAccept` string?}], `guarded` [{`key`, `value` †, `sinceAccept` string?}], `lastAccept` date?, `floor` {`mergePolicy`, `auditFinders` int, `sensitivePaths` [string], `strictPaths` [string], `riskLines` int, `riskModel` bool, `verifierDifferent` bool, `auditSamplePercent` int}?, `baseBranch` string? |
| `base` | object, optional | on `base` cards: `branch` †, `from` string?, `fromIs` string, `to`, `reason` string? †, `commits` [{`sha`, `subject` †}] |
| `draft` **new** | `{text: string, version: int, at: date, action: string}`? | an answer drafted in a web client, waiting for the user's confirmation on the command line ([§8](#8-actions)). Shown as the user's own words |

`question` (the lead's question as its tool server posted it, never the board's):

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | the question's id on the lead's board |
| `short` | string | its short name |
| `text` | string † | |
| `options` | [string] † | |
| `priority` | `"blocking"` \| `"important"` \| `"whenever"` | |
| `whyNow` | string? † | |
| `version` | int | goes up when the lead revises it. An answer says which version it saw |
| `revisionNote` | string? † | the last revision's note |
| `proposal` | string? † | what the lead does when the timer runs out |
| `decideBy` | date? | when the timer runs out; null when none is counting |
| `state` | `"open"` \| `"answered"` \| `"withdrawn"` \| `"autoDecided"` | |
| `answer` | string? † | the user's answer once given |
| `answeredVersion` | int? | |
| `withdrawReason` | string? † | |
| `task` | string? | the task it is about |

`approval` (facts the engine derives from git and the vault, shown in a frame the lead's words can't imitate):

| Field | Type | Meaning |
| --- | --- | --- |
| `commit` | string | the commit the option approves, whole |
| `tasks` | [string] | the tasks whose branch points at it now |
| `base` | string? | what it would merge into |
| `files` | [string] † | the files of `<base>...<commit>` |
| `diffstat` | string † | |
| `subject` | string? † | the commit's subject, from git |
| `verdicts` | {task: string} | the vault's verdict per task, as a line |
| `sensitive` | [string]? † | the sensitive paths it touches; null: couldn't be vouched for (said on the card) |
| `problems` | [string] | why a fact is missing |

A card's four-letter code (`NodeIds.code(card:)`) is not a field: it is a function of the id, a check that the user's
hands typed something, not a secret.

### Notices

Notices are `node.notices`, strings. There is no notice entity and no severity in the first slices; a client shows
them in a quiet strip, newest state replacing the old (they are a list of what stands now, not a log).

## 6. Chat (slice 2)

One stream per session, `collection: "chat"`, `key`: the session's id. Built from the transcript by `VibeCore`'s
reader (`ChatReader`, `ChatLog`, `ChatTimeline.items`): the wire's items are `ChatItem`'s cases `prompt`, `reply`,
`tools` and `team`. `newMarker` is view state and is the client's; `allDone` and `question` are placed by stage 5's
Team slice.

```json
{"v":1,"kind":"snapshot","sub":"c1","collection":"chat","key":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f",
 "epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":318,"after":null,"more":true,
 "items":[{"id":"m_01","type":"prompt","at":"2026-11-17T09:10:00.000Z","text":"Fix the login test","steered":false,"fromLead":false,"images":[]},
          {"id":"m_02","type":"reply","at":"2026-11-17T09:10:04.210Z","text":"I'll start by reading the test."}]}
```

| Snapshot field | Meaning |
| --- | --- |
| `after` | null: `items` is the newest part of the chat, whole. An item id (a `tail`): keep every item before it, and replace it and what followed with `items`, whose first is that item as it is now |
| `more` | older items exist before `items[0]`: page them with `chat.page` |
| `items` | in order, oldest first |

`chat.page` with `{"session": id, "before": itemId, "limit": 200}` replies `{"items":[…], "more": bool}`: the items
just before `before`, oldest first. It is a read with no place in the stream's sequence.

### Items

Every item: `id` (string, the transcript entry's; `tools:<first tool id>` for a run of tools), `type`, `at` (date?).

| `type` | Fields | From |
| --- | --- | --- |
| `prompt` | `text` †, `steered` bool (sent into a working agent), `fromLead` bool, `images` [{`id`, `mediaType`, `bytes` int}] | `ChatEntry.Kind.prompt`, `.steered` |
| `reply` | `text` † (markdown source; the client renders it to DOM nodes itself) | `.reply` |
| `tools` | `summary` string ("Ran 3 commands · edited 2 files"), `tools` [tool] | `ChatItem.tools`, `ChatTimeline.summary` |
| `team` | `text` † (the sender's words), `title` † (the chat's heading for it), `sender` {`kind`: `"user"` \| `"lead"` \| `"vibeSwitcher"` \| `"teammate"`, `name` string? † (the lead's, what VibeSwitcher speaks of, the teammate's), `task` string? (a teammate's)}, `message` `"report"` \| `"audit"` \| `"witness"` \| `"userAnswer"` \| `"leadMessage"` \| `"notice"` \| `"teammatePost"`, `task` string? (the task it is about), `part` {`index`, `count`}? (of a message too long for one delivery) | `ChatItem.team`, `TeamMessage` (`ChatValue`, B4/E2) |

A tool (`ChatTool`): `id`, `name` †, `title` †, `at` date?, `detail`, `result`?

- `detail` is `{"type": …}` with: `thought` {`text`}, `todos` {`todos` [{`text`, `status`: `pending` \| `active` \|
  `done`}]}, `plan` {`text`}, `command` {`command`}, `edit` {`path`, `changes` [{`old`, `new`}]}, `write` {`path`,
  `content`}, `read` {`path`}, `patch` {`text`}, `questions` {`questions` [{`question`, `options`, `header`?,
  `descriptions` [string?], `multiSelect`}]}, `agent` {`description`, `prompt`}, `fields` {`fields` [{`name`, `value`}]}
  (`ToolDetail`). Every string in it is †.
- `result` (`ChatResult`): `output` †, `truncated` bool, `failed` bool, `at` date?, `images` as above.

Images carry no bytes in these slices: the client shows a placeholder with the type and size. Serving what an agent
produced needs the separate origin the design asks for, which is stage 5's.

### Chat ops

A chat delta carries `ops`, applied in order:

| Op | Meaning |
| --- | --- |
| `{"op":"add","item":{…}}` | a new item at the end |
| `{"op":"text","id":"m_02","at":31,"append":" It reads"}` | append to the item's `text`. `at` is the text's length before the append, in UTF-16 code units (JavaScript's `length`); the server never cuts inside a surrogate pair |
| `{"op":"set","item":{…}}` | the item with that id, replaced whole (a run of tools that gained a tool, a tool whose result came) |
| `{"op":"remove","id":"…"}` | the item is gone |

**A growing message is appended, not resent.** When an item's new value differs from the one the stream holds only in
`text`, and the old text is a prefix of the new, the server sends `text` with the difference. Anything else is `set`.
The client checks `at` against its own text's length: equal, it appends; anything else is a gap: it applies nothing of
that delta and subscribes again with `after` = that item and no `since` (a resume would send the same ops again), and
the `tail` replaces the item and what followed. A folded chat delta is the ops in order, with consecutive `text` ops of
one item joined. Each op is one `seq`.

```json
{"v":1,"kind":"delta","sub":"c1","prev":318,"seq":320,"at":"2026-11-17T09:14:06.004Z",
 "ops":[{"op":"text","id":"m_02","at":31,"append":" It reads the token from the wrong header."},
        {"op":"add","item":{"id":"tools:t_07","type":"tools","at":"2026-11-17T09:14:05.990Z","summary":"Read 1 file",
          "tools":[{"id":"t_07","name":"Read","title":"Read LoginTests.swift","at":"2026-11-17T09:14:05.990Z",
                    "detail":{"type":"read","path":"Tests/LoginTests.swift"},"result":null}]}}]}
```

Vectors: `snapshot.chat`, `delta.chat`, `delta.chat-set` (a `set`, a `remove`, a `team` item added), `chat.page` (the
request and its reply) and `resume.chat-tail`, all written by `ChatValue` from a transcript the reader read.

Today's reader yields a reply when the agent has written it to its transcript, which Claude Code does a block at a
time: appends are as fine as the source. A finer source (the agent's own stream) is a store's later work and changes
nothing here.

## 7. Budgets on the wire

| What | Budget | Measured |
| --- | --- | --- |
| A store's change (`Changes.send`) to its delta frame written to the socket | under 100 ms at p95, under 20 ms at the median | `LiveLatencyBench`, in process, 500 changes over a real WebSocket on loopback |
| The same, to the list showing it in the page | under 100 ms at p95 | the web bench, in headless Chrome |
| A reconnect after the server restarts, to every subscription current again | under 2 s | the web bench |
| `subscribe` to its snapshot written | under 50 ms for a keyed collection, under 150 ms for a chat of 10,000 rows (its newest 200) | `LiveLatencyBench` |

## 8. Actions

### The envelope

An action is a request with an `action` id: a UUID the client makes, lower case, **the same on every retry**, so it
is done once (rule 8). What the first write actions need:

| Kind | Args | On the Unix socket (today) | On a WebSocket |
| --- | --- | --- | --- |
| `answer` | `card` (id or a prefix), `code` (the card's four letters), `text`, `version`? (the wording the user saw) | the user's voice (S3), the card's code typed on a terminal, `action`; recorded in the vault before it is done | **refused, `voice`**, until signed approvals: then `proof` ([below](#when-signed-approvals-exist)) |
| `hold` | `card`, `code` | the same | **refused, `voice`**, the same |
| `draft` **new** | `card` (the whole id), `text`, `version` | refused, `voice`: a draft comes from a page | a token with `draft`, `action` |
| `draft.clear` **new** | `card` | refused, `voice` | a token with `draft`, `action` |
| `web.open`, `web.revoke` **new** | none | the user's voice, the typed code from the action id, `action`; recorded | refused, `voice` |
| `seen` **new** (2026-11-19) | `session` | anyone (it changes nothing but the session's seen mark: a finished turn reads `idle`, the app's rule) | a token with `read`; the page sends it after 1.5 s on a finished session (`views/session.js`) |
| `session.draft` **new** (2026-11-20) | `session` (the whole id), `text` | refused, `voice` | a token with `draft`, `action`: the message kept beside the session (its `draft`), told to nobody; the reply's `applied` is the `sessions` stream's seq. `vibeswitcher send SESSION` types it |
| `session.draft.clear` **new** (2026-11-20) | `session` | refused, `voice` | a token with `draft`, `action` |
| `send`, `session.new`, `session.end`, `session.reply` **new** (2026-11-20) | `session` and `text`; `folder`, `agent`, `model`; `session`; `session`, `choice`, `text`, `question`, `options` | the user's voice, the typed code from the action id, `action`; recorded | refused, `voice`: the page shows the line that runs each |
| `session.reopen` **new** (2026-11-20) | `all` bool, or `sessions` [string] (ids as `reopen` lists them, or prefixes of 4 or more), or `forget` bool | the user's voice, the typed code from the action id, `action`; recorded | refused, `voice`: `vibeswitcher reopen` |
| `mail` **new** (2026-11-20) | `folder` string? (absolute), `all` bool? | the user's voice, no typed code (a read of the projects' private record of their leads' `tell_lead` messages) | refused, `voice`: `vibeswitcher mail` |

A session (§5) carries two more fields since 2026-11-20, each null when there's none: `prompt` {`question` †,
`options` †, `descriptions` †, `text` (the options that take words, by index), `multiSelect`, `at`}, the question open
on its screen as the node read it (`SessionPrompt`), and `draft` {`text` †, `at`, `action`}, a page's message for it.

**The user's-voice rule is unchanged (S3).** A browser is not a terminal in the user's scope and types no code, and a
token is a secret in a file the user's processes can read (the security document's S11, item 31). So in the first
slices **no browser action is the user's voice.** What the browser does instead:

1. The user picks an option or writes an answer on the card. The page sends `draft`. The server keeps it on the card
   (`draft`, in memory, the last one wins) and tells nobody: the lead hears nothing, the vault records nothing.
2. The card shows the draft and the line to run: `vibeswitcher answer <the card's short id>`.
3. In a terminal, `vibeswitcher answer CARD` with no text takes the card's draft: it prints the card as the engine
   built it and the drafted answer, whole and inert, asks for the card's code, and sends `answer` with that text and
   version. That request is the user's voice, as every answer is today.
4. The card's delta (`question.state: "answered"`, `draft: null`) arrives on the page.

A hold needs no draft: the card shows `vibeswitcher hold <short id>`.

### When signed approvals exist

Named now so the envelope doesn't change: a request gains `proof`: `{"device": id, "nonce": string, "sig": string}`,
the device's signature over the action id, the kind, the card's id and version, the SHA-256 of `text`, and a nonce the
host gave, checked by the host (rule 7). `answer` and `hold` with a valid `proof` are taken on a WebSocket; the code
is not asked. Its design is stage 4's ("approvals as signed actions") and starts from S11's item 31.

### Optimistic actions

Every action, whatever its kind, follows one shape, so the page answers a click at once (the 50 ms budget) and never
shows a state the server didn't confirm for long:

1. **The echo.** The client makes the action id, shows the result locally at once as an overlay on the entity (the
   draft on its card, marked as sending), and sends the request. The overlay is keyed by the action id and is not part
   of the stream's state.
2. **The ack.** `ok: true`, with `applied`: the `seq` of each stream at which the action's effect is in that stream.

   ```json
   {"v":1,"re":"12","ok":true,"result":{"applied":{"cards":58},"card":"local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67"}}
   ```

   The client drops the overlay when its subscription to that stream has reached that `seq` (at once, if it already
   has). Until then the overlay stays over the stream's value, so there is no moment where the old value shows
   between the ack and the delta, whichever comes first.
3. **The refusal.** `ok: false` with `error`. The client takes the overlay back and shows `error.message` on the
   entity. Nothing else changes: the stream never held it.
4. **No answer** (the connection dropped): the overlay stays, marked as waiting, and the request is sent again with
   the same action id after the next `hello`. The server answers a repeated action as it answered the first (it keeps
   the last 200 replies by action id; a `draft` repeated after a restart is taken again, which changes nothing).

The stream stays the truth: the effect reaches every other client, and this one, as a delta. Chat keys in `applied`
are `chat:<session id>`.

### Vectors: a draft, acked (`draft.acked`)

```json
{"v":1,"id":"12","kind":"draft","action":"6f1d2a34-9b8c-4e7d-a1f0-3c5b7d9e2f46",
 "args":{"card":"local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67","text":"Yes, merge it","version":2}}
```
```json
{"v":1,"kind":"delta","sub":"s3","prev":57,"seq":58,"at":"2026-11-17T09:15:11.900Z",
 "changes":[{"id":"local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67","value":{"id":"local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67",
   "kind":"question","project":"local:project:NNIR0a8Cgphg","root":"/home/u/acme-site","open":true,"closed":null,"notice":null,
   "at":"2026-11-17T09:02:41.700Z","blocking":true,
   "question":{"id":"q-7","short":"q-7","text":"Merge the login fix now, or wait for the audit?","options":["Yes, merge it","Wait for the audit"],
     "priority":"blocking","whyNow":"Two tasks wait on it","version":2,"revisionNote":"Named the audit as the other choice","proposal":null,"decideBy":null,
     "state":"open","answer":null,"answeredVersion":null,"withdrawReason":null,"task":"login-fix"},
   "draft":{"text":"Yes, merge it","version":2,"at":"2026-11-17T09:15:11.898Z","action":"6f1d2a34-9b8c-4e7d-a1f0-3c5b7d9e2f46"}}}]}
```
```json
{"v":1,"re":"12","ok":true,"result":{"applied":{"cards":58},"card":"local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67"}}
```

### Vectors: refused (`draft.refused`, `answer.from-a-page`)

A draft for a wording the lead has since revised (`draft.refused`):

```json
{"v":1,"re":"13","ok":false,"error":{"code":"refused","message":"the lead revised question q-7 (version 3): read it again"}}
```

An `answer` sent from a page (`answer.from-a-page`):

```json
{"v":1,"re":"14","ok":false,"error":{"code":"voice","message":"not the user's voice: a web client drafts, and `vibeswitcher answer` confirms"}}
```

## 9. The terminal (slice 4)

The spike's form (B6, D5, G3), measured on a scratch node; on the user's node a terminal is watched only (the last
point).

- `term.open` `{session, cols, rows}` replies `{stream: int, readOnly: bool}`, and when `readOnly`, the session's own
  `cols` and `rows` too (the request's are checked and unused); `term.close` `{stream}`.
- Binary frames, both ways: one byte of type, four bytes of stream (big-endian), then the payload. Server to client:
  type 1, the session's bytes from the host's `attach` (replay first, then live); type 2, replay is over. Client to
  server: type 1, input; type 3, a resize (two 16-bit numbers). Watched only: type 5 to the client, the session's size
  (two 16-bit numbers), before each replay; a session resized elsewhere is replayed again (type 4, type 5, the replay).
- When the client falls behind, the server sends type 4 (`resync`) and starts the stream again from the host's
  replay, as the host does to its own clients.
- Only the host's parser answers a program's terminal queries: the client's emulator's replies are never sent.
- Sizes: columns 10 to 1,000, rows 5 to 300; a resize outside them is dropped. A client frame is at most 64 KiB, so the
  page cuts input (a paste) into frames of 16 KiB. No frame says a session ended: the sessions stream does.
- **The page** (`WebApp/js/terminal.js`, `js/views/terminal.js`): `term.open` only where `hello.kinds` has it, else
  the pane's words and no emulator loaded. The replay is held until type 2 and drawn whole over a reset emulator; a
  resync (type 4) or a reconnect keeps the old screen, dimmed, until the new replay is whole. After a reconnect the page
  opens the session again (a new stream). `term.close` when the pane is left. The emulator is xterm.js 6.0.0 with its
  DOM renderer (`WebApp/vendor/`, hashes in its README); the page swallows OSC 52, OSC 8 and the titles.
- **Measured (G3), 2026-11-19**, on the sandbox (`scripts/sandbox-server.sh`, `--web-root`), a scratch `bash -i` as the
  program (its echo is the line editor's: no program time to subtract), Chrome's headless shell 1228 on the same WSL2
  machine (24 cores, load average 6 to 18 from other work), branch `v2-web-term-page` on 5b6eccd9:

  | Measure | Budget | p50 | p95 | Notes |
  | --- | --- | --- | --- | --- |
  | a key to its echo in the page's screen (the `input` event's time to the echoed cell in the DOM, xterm.js's render frame) | 16 ms median, 33 ms p95 | 6.5 ms | 7.5 ms | 300 keys; an earlier run of 200, the first on a cold page: 6.3 ms, 52.6 ms (13 of them over 2 s and left out) |
  | the same to the frame after (an upper bound on the paint) | | 22.6 ms | 23.6 ms | max 27.4 ms |
  | a busy terminal: the page's frame interval while `yes` floods it for 5 s | | 16.7 ms | 16.8 ms | 300 frames (60 a second), longest 33.4 ms, no long task |

  Inside the budget at the median in both runs and at p95 in the warm one; whether stage 5 builds on xterm.js is the
  lead's call on these numbers. The cold run's tail is worth a look on the Mac and a phone first.
- **Rights.** On the user's node a token with `read` may **watch** a session's terminal (the supervisor's decision,
  2026-11-20; the plan's LW-D12 as amended): the host's `watch`, never its `attach`, so the page takes nothing over
  (the host's parser keeps answering the program's queries, the session keeps its size), and the client's types 1 and
  3 are refused, each with a log line. A watcher sees nothing a `read` token can't already see (the chat streams to
  it), so H1 (the host binds the web port) is waived for watching; it stays required before any page input reaches a
  real session. Typing stays the user's voice: `vibeswitcher send` on the user's terminal with the typed code
  (the security architecture's S3). `web --revoke` closes the streams with their connections. Only a scratch node's
  server types from a page (`--test-web-terminal`, the spike).

## 10. Errors and versions

**Errors** are `NodeWire.Failure`: `{code, message}`. `message` is a sentence for the user, built by the server; the
client shows it as text. The codes, `NodeWire.Code`'s:

| Code | Meaning | The client |
| --- | --- | --- |
| `unknown-kind` | this server doesn't take the kind | hides what needs it (`hello.kinds` says so beforehand) |
| `version` | a newer `v` than the server's; `bye` follows | reloads |
| `bad-args` | an argument is missing or out of form | a bug: logs it, takes the action back |
| `voice` | not the user's voice, a wrong code, or a right the token lacks | takes the action back, says why |
| `refused` | the engine's reason | takes the action back, shows the message |
| `stopping` | the node is stopping | takes the action back; shows the node as stopping |
| `not-yet` | the host link isn't welcomed | sends the request again after 500 ms, at most 10 times, the same action id |
| `gone` | the card or session is no longer there | takes the action back; the stream removes the entity |
| `internal` | not done, and why | takes the action back, shows the message |

`bye` is the last message before the server closes: `{v, kind: "bye", reason, code}`. `code` (**new**) is one of
`auth`, `revoked`, `version`, `too-long`, `not-object`, `not-request`, `must`, `stopping`. A client reconnects after
every `bye` but `auth` and `revoked` (it shows "run `vibeswitcher web` again") and `version` (it reloads).

**Versions** (rule 3):

- `v` is `NodeWire.version`, 1. Everything in this file is additive to it: new kinds, new fields, new events.
- A reader ignores a field it doesn't know. A client skips an event of a kind it doesn't know, unless the event has
  `"must": true`: then it closes and reloads. A server answers a request of a kind it doesn't take `unknown-kind`,
  and closes when the request has `must: true`.
- `hello.kinds` is what this connection may send; a client shows only what it can do.
- `hello.assets` against the page's own tells a page older than its server.
- The JavaScript validators and `WebApp/wire/vectors.json` are generated from `VibeNode`'s encoders and checked in; a
  test fails when they are stale, and every frame a test client receives goes through the validators.

## 11. Vectors: a first session

The frames of a page's first connection, in order. Each is in `WebApp/wire/vectors.json` under the name given.

`auth.pair` (client), then `hello.web` (server): [§2](#the-first-frame).

`subscribe.node`, `subscribe.sessions`, `subscribe.leads`, `subscribe.cards` (client):

```json
{"v":1,"id":"1","kind":"subscribe","args":{"sub":"s0","collection":"node"}}
{"v":1,"id":"2","kind":"subscribe","args":{"sub":"s1","collection":"sessions"}}
{"v":1,"id":"3","kind":"subscribe","args":{"sub":"s2","collection":"leads"}}
{"v":1,"id":"4","kind":"subscribe","args":{"sub":"s3","collection":"cards"}}
```

`reply.subscribe` and `snapshot.sessions` (server):

```json
{"v":1,"re":"2","ok":true,"result":{"sub":"s1","mode":"snapshot"}}
```
```json
{"v":1,"kind":"snapshot","sub":"s1","collection":"sessions","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":41,
 "entries":[
  {"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","value":{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f",
   "terminal":"pts/4","agent":"claude","cwd":"/home/u/acme-site","status":"working","since":"2026-11-17T09:13:20.000Z",
   "hosted":true,"role":"lead","shownStatus":"needs-you","project":"acme-site","task":"Login fix","detail":null,
   "activity":null,"activitySince":null,"startedAt":"2026-11-17T08:40:02.000Z","hasHooks":true,"leadAsks":true,
   "startFolder":"/home/u/acme-site","backgroundJobs":0,"hasTranscript":true}},
  {"id":"local:pts/9","value":{"id":"local:pts/9","terminal":"pts/9","agent":"codex","cwd":"/home/u/notes",
   "status":"idle","since":"2026-11-17T08:55:00.000Z","hosted":false,"role":null,"shownStatus":"idle","project":"notes",
   "task":null,"detail":null,"activity":null,"activitySince":null,"startedAt":"2026-11-17T08:54:10.000Z",
   "hasHooks":false,"leadAsks":false,"startFolder":null,"backgroundJobs":0,"hasTranscript":false}}]}
```

`snapshot.leads`:

```json
{"v":1,"kind":"snapshot","sub":"s2","collection":"leads","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":12,
 "entries":[{"id":"local:project:NNIR0a8Cgphg","value":{"project":"local:project:NNIR0a8Cgphg","root":"/home/u/acme-site",
   "session":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","named":"3F6C2C1E-8A5B-4C1D-9E0F-2B7A6D5C4E3F",
   "bound":"3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","replaced":[],"held":0,"reportsWaiting":0,"notice":null,
   "starting":false,"lastStart":"started","lastStartAt":"2026-11-17T08:40:02.410Z","looks":211,
   "questions":{"open":1,"blocking":1},"cards":["local:card:5b2e9c0a-7d41-4f6e-b3a8-1c9d0e2f4a67"]}}]}
```

`snapshot.node`:

```json
{"v":1,"kind":"snapshot","sub":"s0","collection":"node","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":3,
 "entries":[{"id":"local","value":{"node":"local","epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","root":"/home/u/.vibeswitcher",
   "server":{"pid":41822,"startedAt":"2026-11-17T09:12:44.031Z","commit":"f62aef61"},
   "host":{"startedAt":"2026-11-17T08:01:10.555Z","pid":41790,"state":"connected","liveSessions":3,
     "notes":{"startedAt":"2026-11-17T08:01:10.555Z","serverRestarts":1,"replacedPaths":[],"refusedAppConnections":0,
              "lockHeldElsewhere":null,"build":"f62aef61","at":"2026-11-17T09:13:59.020Z"}},
   "rule":{"mode":"systemd","says":"the user's voice is a terminal's process outside the node's unit","scopes":["/init.scope"]},
   "cards":{"questions":1,"approvals":0,"config":0,"base":0},"accepted":[],"notices":[],"restart":null,"builds":null,
   "web":{"state":"listening","port":47830,"tokens":1,"connections":1}}}]}
```

`delta.session-status` (the lead's turn ended; one change, `prev` + 1):

```json
{"v":1,"kind":"delta","sub":"s1","prev":41,"seq":42,"at":"2026-11-17T09:14:05.482Z",
 "changes":[{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","value":{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f",
   "terminal":"pts/4","agent":"claude","cwd":"/home/u/acme-site","status":"done","since":"2026-11-17T09:14:05.470Z",
   "hosted":true,"role":"lead","shownStatus":"needs-you","project":"acme-site","task":"Login fix","detail":null,
   "activity":null,"activitySince":null,"startedAt":"2026-11-17T08:40:02.000Z","hasHooks":true,"leadAsks":true,
   "startFolder":"/home/u/acme-site","backgroundJobs":0,"hasTranscript":true}}]}
```

`delta.session-gone` (a folded delta: three changes of the stream in one frame, one of them a removal):

```json
{"v":1,"kind":"delta","sub":"s1","prev":42,"seq":45,"at":"2026-11-17T09:20:11.019Z",
 "changes":[{"id":"local:pts/9","value":null}]}
```

`resume.same-epoch` (after a dropped connection; the client held `seq` 45, the stream is at 47):

```json
{"v":1,"id":"2","kind":"subscribe","args":{"sub":"s1","collection":"sessions","since":{"epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":45}}}
{"v":1,"re":"2","ok":true,"result":{"sub":"s1","mode":"resume"}}
{"v":1,"kind":"delta","sub":"s1","prev":45,"seq":47,"at":"2026-11-17T09:21:40.730Z","changes":[{"id":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f","value":{"…":"its value now"}}]}
```

`resume.new-epoch` (after a server restart: the same request gets `"mode":"snapshot"` and a snapshot with the new
epoch, `seq` small again; the client reconciles by id).

`resume.chat-tail` (after a server restart; the client's last item is `tools:t_07`, whose result came meanwhile):

```json
{"v":1,"id":"5","kind":"subscribe","args":{"sub":"c1","collection":"chat","key":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f",
  "since":{"epoch":"0b6c1a52-3f0e-4c58-9a57-2d1c8e4f7a10","seq":320},"after":"tools:t_07"}}
{"v":1,"re":"5","ok":true,"result":{"sub":"c1","mode":"tail"}}
{"v":1,"kind":"snapshot","sub":"c1","collection":"chat","key":"local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f",
 "epoch":"7e2a9d14-5c3b-4f80-8b61-0a9c4d2e6f35","seq":2,"after":"tools:t_07","more":false,
 "items":[{"id":"tools:t_07","type":"tools","at":"2026-11-17T09:14:05.990Z","summary":"Read 1 file",
           "tools":[{"id":"t_07","name":"Read","title":"Read LoginTests.swift","at":"2026-11-17T09:14:05.990Z",
                     "detail":{"type":"read","path":"Tests/LoginTests.swift"},
                     "result":{"output":"import Testing\n…","truncated":true,"failed":false,"at":"2026-11-17T09:14:06.300Z","images":[]}}]},
          {"id":"m_03","type":"reply","at":"2026-11-17T09:14:20.100Z","text":"The header name was wrong. Fixed, and the test passes."}]}
```

`bye.revoked`:

```json
{"v":1,"kind":"bye","code":"revoked","reason":"this page's access was revoked: run `vibeswitcher web` again"}
```
