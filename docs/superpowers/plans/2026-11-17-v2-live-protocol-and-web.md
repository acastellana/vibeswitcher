# VibeSwitcher 2, the Live Protocol and the Web Client (stage 3's protocol, stage 5's first slices) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The user opens a page in a browser and sees their node live: its status, every session with its status as it
changes, each lead's questions and cards. Then a session's chat as it grows, then answers drafted in the page and
confirmed on the command line, then a terminal, measured against the design's budgets. Each slice ends in something
the user can see. The work is cut so that seven agents in seven worktrees build at once and share no file.

**Architecture:** One hub in `VibeNode` (`Sources/VibeNode/Live/`) turns the stores' existing change streams
(`NodeSessions.changes`, `LeadStore.changes`, `CardStore.changes`) into numbered streams and serves subscriptions to
any connection that can carry a line of JSON: the server's Unix socket today, a WebSocket beside it. The WebSocket is
a small HTTP/1.1 and RFC 6455 listener on plain sockets (`Sources/VibeNode/Web/`), bound to `127.0.0.1`, off until
the user runs `vibeswitcher web`, which hands the page a one-time code for a token that reads and drafts and is never
the user's voice. The page's files are `WebApp/`, ES modules with no build step, embedded in the server's binary as a
generated Swift file. The page keeps a `store.js` fed by `socket.js` where the mock fed it from `mock.js`.
Everything the two sides exchange is in
[the wire contract](../specs/2026-11-17-v2-live-wire-contract.md); the JavaScript validators and vectors are
generated from `VibeNode`'s own encoders.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM `--build-system native`, `VibeNode`, `VibeCore`,
`VibePlatform`, Dispatch sources on plain sockets; swift-crypto (already pinned) for SHA-1 in the handshake and
SHA-256 of tokens. JavaScript as ES modules, no npm, no bundler, no type checker. Headless Chrome over its DevTools
protocol, driven by Node 22's built-in WebSocket, for the bench. **No new dependency in slices 1 to 3.**

**Spec:**
- The wire contract, `docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md` (written with this plan).
- The design, `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md`: "Rules from the first line", "VibeNode:
  stores, not view models", "The live protocol", "Real-time and slick", "The web client", "Security", "Stage 3",
  "Stage 5", "Verification".
- The security document, `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`: S3 (the user's voice), the
  principals ("An unknown local process", "Another user"), S11 items 22 and 31, T9.

**Code references** are at `v2` `f62aef61`. Two branches are in flight and are consumed here: `v2-ws` (an RFC 6455
codec under `Sources/VibeNode/Web/`) and `v2-web-ui` (a static mock under `WebApp/`, a `store.js` fed by `mock.js`).
Neither had a commit when this was written, so the names this plan gives their parts are what it needs from them;
Task W0 reconciles the names with what they made. **At W0 (2026-11-17) neither had a commit yet** (both at `f62aef61`),
so this plan's names stand; the lane that lands each branch renames to them, or asks the lead.

## What exists, and what this plan builds

| Piece | Today | This plan |
| --- | --- | --- |
| The protocol | request and reply on the Unix socket; no subscription, no event but `bye` (`NodeWire.swift:3-6`) | `subscribe`, `snapshot`, `delta`, resume, on both carriers (B1, B3, I1) |
| The change stream | `Changes<Value>`: folded per id, a queue per subscriber (`Changes.swift`) | consumed as it is; the hub numbers what it carries (B1) |
| Stores | `NodeSessions`, `LeadStore`, `CardStore`, each with `changes`; the node's status is computed per `status` request (`Requests.statusValue`) | a node-status stream (B2); a chat store (B4) |
| Wire values | hand-written `.value` encoders (`CardStore.Card.value`, `LeadStore.Lead.value`, `Requests.value(_:)`) | kept; a session's value grows (B2); a schema and vectors generated from them (E1) |
| A TCP listener | none anywhere on the node | a loopback HTTP and WebSocket listener, off until asked (A1, A2) |
| Web files | `Web/` is the Mac's phone app, untouched | `WebApp/`, embedded (C1), fed by the socket (D1, D2) |
| Answering | `vibeswitcher answer CARD "text"`, the user's voice | the same, plus a draft left by the page (B5, F3, D4) |
| The terminal in a browser | nothing; `HostLink` has no `attach` | a spike on a scratch node, measured (B6, D5, G3) |

## Slices

Each ends in something the user sees in a browser. A slice's tasks are under [Tasks](#tasks).

| Slice | The user sees | Tasks | Posture |
| --- | --- | --- | --- |
| **1. The live page** | the node's status, the session list with statuses changing as they happen, each lead's questions and cards; read-only | W0, A1, A2, B1, B2, B3, C1, D1, D2, E1, F1, F2, G1, I1 | a first TCP listener, a token at rest (LW-D1, 3, 4, 5) |
| **2. The chat** | a session's conversation, growing as the agent writes, 10,000 rows without a stutter | B4, D3, E2, G2 | none new |
| **3. Answering** | pick an option on a card in the page, confirm with one command in a terminal, watch the card close | B5, F3, D4 | a draft right (LW-D6); S3 unchanged |
| **4. The terminal** | a scratch session's terminal in the page, typed into, with its measured latency | B6, D5, G3 | on a scratch node only (LW-D12) |
| **5. The rest of stage 5** | starting a lead, the Team tab and strip (boards), Settings and launch presets, ⌘K, notifications, the start page, onboarding, the phone layout, agent files from their own origin | planned after slice 2 lands, one plan per slice | decided there |

Slices 2, 3 and 4 don't depend on each other: once I1 is merged, their lanes run at once.

## Global Constraints

- **All work on `v2`, never `main`.** Each lane works in its own worktree on its own branch from `v2` (the lane table
  below names them). Nothing under `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests` or `Web/` is edited.
- **A lane edits only the files it owns** ([Lanes](#lanes-and-who-owns-what)). A change needed in another lane's file
  is asked of the lead, never made. The files several lanes would touch (`NodeWire.swift`, `NodeServer.swift`,
  `Requests.swift`, `ServerStart.swift`, `ServerArguments.swift`, `vibeswitcher-cli/main.swift`) are the
  integrator's: W0 before the lanes start, I1 to I4 after.
- **Shared files.** This plan edits no existing file under `Sources/VibeCore`, `Sources/VibeHost` or the executables
  shared with main, except B6's one hook in `HostLink`'s consumer (`VibeNode`, not shared). A task that finds it needs
  one stops and asks; the edit must be one of stage 2's kinds (1 to 8) with a row in the port map's Non-seam edits.
- **No `#if os` outside `VibePlatform`** (`PlatformLint`). Every system call the listener makes (`socket`, `bind`,
  `listen`, `accept4`, `setsockopt`, `getsockname`) is a `Platform.Sockets` function, added by lane A alone.
- **No new dependency** in slices 1 to 3: no swift-nio, no npm package, nothing vendored. Slice 4's emulator is the
  first vendored file and needs the user's go-ahead (LW-D13). Agents install nothing.
- **Tests only through `scripts/test.sh`**, never a bare `swift test`. Lints before a task is reported done. New or
  changed tests also run under `scripts/test-under-load.sh --load 24 -r 3`. The bench and any full suite run under
  `vs-heavy`.
- **A test waits on the event it checks** (a frame, a reply, a semaphore, an injected clock), never on a fixed sleep.
  A latency budget is a bench (`scripts/test.sh --perf`, the web bench), never an assertion on wall time in a test:
  the tests hold the mechanism (no timer on the path), the bench holds the number.
- **Tests never reach the user's node.** Every listener a test starts is on a `ScratchNode` or in process, on port 0
  (the kernel's pick). No test binds `NodeWeb.port`. No test opens the user's browser. `--test-web-port=`,
  `--test-web-root=` and `--test-web-pair=` are test flags: the user's server (`--node`) refuses them as it refuses
  the others (`ServerArguments.refused`).
- **Agents never run `vibeswitcher web` on the user's node**, nor open a page against it: that is the user's.
  What an agent shows is a scratch node (`scripts/sandbox-server.sh`, G1).
- **Nothing an agent wrote is markup.** `WebApp/` uses no `innerHTML`, `outerHTML`, `insertAdjacentHTML`,
  `document.write`, `eval`, `new Function`, inline script or inline event handler (`WebAppLintTests`, F2).
- **No token, pairing code or terminal text in a log line** (`WebSecurityTests`, F2).
- **A fix's test is shown failing** without the fix; a new feature's tests fail first for the right reason.
- **Every job is green before a lane's branch is merged**: the `v2 linux` and `v2 macos` jobs on one commit. The Mac
  builds `VibeNode` too: `Platform.Sockets`' new functions have a Darwin form, and the listener's tests run on both.
- Commit messages end with the attribution line the session gives.

## Decisions this plan makes

Numbered LW-D1 and up. Each is the author's recommendation, recorded as **the lead's call**. Those marked
**posture** change what the node exposes or trusts and are the lead's to confirm with the user before the task that
needs them starts. The lead accepted LW-D1, D3, D4, D5, D6 and D12 as recommended on 2026-11-17, before W0.

1. **LW-D1 (posture): the server binds the loopback listener in slices 1 to 3; the host owns it before anything a
   token can write, and before stage 6.** **Accepted by the lead, 2026-11-17.**
   - The design's requirement 4 says the host owns the listeners. Today the server binds its own Unix socket, a
     recorded deviation. This extends it to the TCP port: the listener is `vibeswitcher-server`'s.
   - What it costs: while the server is down, nothing holds the port, and any local process can bind it (T9, on TCP).
     A page reconnecting then sends its token to that process, and a user opening a bookmark sees that process's page.
   - Why that is acceptable now: the token reads what a process of the user already reads and drafts what the user
     must confirm on the command line, where the engine's own card is shown (LW-D6). A squatter gains a display it
     can lie on, and nothing else. The server that finds its port taken refuses the web and says so in `status`.
   - What ends it: the host binds the port and passes the descriptor to each server it starts, through handovers too
     (shared-file edits in `VibeHost`, kinds 4 and 6). That is Task H1, **not in this plan's slices**; it is required
     before LW-D12's terminal on the user's node and before signed approvals.
   - Rejected: the host's listener first. It is right, and it puts three shared-file edits and the handover in front
     of the first visible page.
2. **LW-D2: plain sockets and the project's own RFC 6455, no swift-nio.** The server already runs its Unix socket on
   Dispatch sources (`NodeServer`); the listener is the same shape. The design leaves the choice to the builder and
   asks for "pinned exact and few": none is fewer.
3. **LW-D3 (posture): the listener is off until `vibeswitcher web`, on one fixed port, and fails closed.**
   **Accepted by the lead, 2026-11-17.**
   - It is bound when the first pairing code is made, stays while a token or a code is alive, and is closed when the
     last is gone. After a server restart it is bound again only if `web-tokens.json` holds a live token.
   - The port is `NodeWeb.port` (47830; the Mac's phone server is 47823), one origin for bookmarks and storage. It
     is a constant until stage 5's Settings store makes it a node's setting (rule 9).
   - Taken: the web is refused, `status` says by whom when it can tell, and `vibeswitcher web` prints that. Never
     another port.
   - Under WSL's mirrored networking the port is reachable from every Windows process of every Windows user (the
     security document's S1 table and S11 item 22). The token is the only lock against them; the page's files are
     public and hold no secret.
4. **LW-D4 (posture): a one-time pairing code in the URL's fragment, exchanged in the first frame for a token.**
   **Accepted by the lead, 2026-11-17.**
   - As [the contract's §2](../specs/2026-11-17-v2-live-wire-contract.md#2-authentication): `web.open` in the user's
     voice behind the typed code; a code of 16 random bytes, 120 s, once; a token of 32 random bytes kept in the
     page's `sessionStorage`; its SHA-256 in `<root>/v2/web-tokens.json` (0600, format 1); 24 h; at most 8;
     `web.revoke`.
   - The code, not the token, is what the terminal prints, so nothing in the scrollback or the browser's history
     opens anything after first use.
   - The hashes are at rest so that a page reconnects by itself across a server restart (the 2 s budget). A file the
     user's processes can write is no record: a worker can add a hash of its own, and gains the reading it has.
     **That is why a token must never be given a right that changes anything.**
   - No cookie: cookies on `127.0.0.1` are shared across ports.
   - Deferred: device keys, signatures in the first frame, per-device rights and revocation (the design's order).
5. **LW-D5 (posture, small): one origin, `http://127.0.0.1:<port>`; `Host` and `Origin` matched exactly.** **Accepted by
   the lead, 2026-11-17.** No `localhost`, no other name: one string to check, and DNS rebinding and cross-site
   WebSocket hijacking both fail on it. `http://127.0.0.1` is a secure context in Chrome and Firefox, which the service
   worker and WebCrypto need. **Open for stage 4:** WebAuthn takes `localhost` as a relying party id and refuses an IP
   address, so signed approvals with a platform authenticator will move the origin to `http://localhost:<port>`.
6. **LW-D6 (posture): no browser action is the user's voice until signed approvals; the page drafts, the command
   line confirms.** **Accepted by the lead, 2026-11-17.**
   - S3's rule needs a terminal in the user's scope and a typed code. A browser has neither, and a token sits in the
     browser's storage, which on WSL is a file under `/mnt/c` (S11 item 31).
   - Slices 1 and 2 are read-only. Slice 3 adds `draft`: an answer kept on the card in the server's memory, told to
     nobody. `vibeswitcher answer CARD` with no text shows the engine's card and the draft, whole and inert, asks the
     card's code and sends today's `answer`.
   - A draft a thief plants is shown to the user in full before the code is typed. It is a guard rail of the same
     strength as the typed word, and it is said so.
   - Rejected: a token that answers. It would let whoever reads the browser's storage approve a merge as the user.
   - What makes a click an answer: `proof`, a device's signature the host checks (rule 7), designed in stage 4.
7. **LW-D7: a sequence number per stream, deltas as ranges.** `seq` belongs to the stream, so a resume means the same
   to every connection. A delta says `prev` and `seq`, so a folded delta is still in order, and the client's rule is
   one table. The server keeps, per stream, each entry's last-changed `seq` and the last 256 removals (chat: the last
   512 ops), which answers a resume with one delta and no journal.
8. **LW-D8: the same messages on the Unix socket now.** `subscribe` is a request kind there as on the WebSocket, for
   anyone of the uid, as `status` and `questions` are. It costs one hook in `NodeServer` and gives every hub test a
   carrier that needs no listener, so lanes A and B never wait on each other. A `chat` subscription there reads what
   the uid's processes already read (the transcripts are the user's files).
9. **LW-D9: the web files are embedded as a generated, checked-in Swift file.**
   `Sources/VibeNode/Web/WebAssets.generated.swift` holds each file of `WebApp/` as base64 text with its SHA-256, made
   by `scripts/webapp-embed.sh`; `WebAssetsTests` fails when it is stale. A scratch server takes `--test-web-root=DIR`
   and serves the folder instead, so the web lane iterates without regenerating. **Only the integrator regenerates
   it**, at each merge of `WebApp/`; no lane commits it, so no two lanes ever conflict in it.
   Rejected: SwiftPM's `.embedInCode` (a `Package.swift` edit in both halves, per file, untried with the static
   build) and reading files from disk on the user's node (rule 10).
10. **LW-D10: validators and vectors come from the encoders, through a hidden subcommand.** `WireSchema` (a table of
    each entity's fields and types in `VibeNode`) is checked against what the real encoders write; `vibeswitcher
    wire-vectors --out DIR` writes `WebApp/wire/validators.js` and `vectors.json` from it; `WireVectorsTests` fails
    when the checked-in files differ. The contract's examples are the first vectors.
11. **LW-D11: no image bytes in slices 1 to 4.** A chat's images are their type and size. What an agent produced is
    served only from the separate origin the design asks for, which stage 5 builds.
12. **LW-D12 (posture): the terminal spike runs on a scratch node only.** **Accepted by the lead, 2026-11-17.** A
    session's screen is more than a process of the user's uid gets from the host today, and input types into a session
    (AGENTS.md's first hard rule, and the design's "reply rights type only into confined sessions; view rights get
    masked screens"). On the user's node a token opens no terminal. What does (a right on a device key, after H1) is
    decided with the user after the spike's numbers.
13. **LW-D13: slices 1 to 3 are plain ES modules; nothing is vendored before the user says so.** The design asks for
    a spike of Preact with signals and of xterm.js before anything is built on them, and vendoring is the first thing
    this work would bring in from outside. The lists and cards of slices 1 to 3 need no library; `store.js` and
    keyed DOM updates are enough, and the bench says whether they hold the budgets. Slice 4 needs xterm.js: the
    user's go-ahead, an exact version, its hash recorded and checked against upstream's in CI. **The lead, 2026-11-17:**
    xterm.js for slice 4 is vendored at an exact version with its hash, as the design says: a file in the repo, not an
    install. Slices 1 to 3 still vendor nothing.
14. **LW-D14: the hub adds no delay; what precedes the store is the engine's.** The 100 ms budget is measured from
    the store's change (`Changes.send`) to the frame and to the paint. Before that, `NodeSessions` coalesces the
    hooks' writes for 0.4 s and scans every 2 s. A status change is therefore live from the store on, and up to
    0.4 s late from the agent's hook. Task B7 measures that and proposes the cut; it is the engine's file, so it is
    the lead's to schedule. **The lead, 2026-11-17:** the 100 ms budget counts from the store's change; cutting
    `NodeSessions`' 0.4 s coalescing is a later engine task.

## Seamless

The user asked for an interface that is slick, calm, clean and real-time. These are the guarantees that make it so,
each with what holds it. The first column is the contract's; a slice isn't done while one of its rows fails.

| Guarantee | The mechanism | Held by |
| --- | --- | --- |
| **A status change reaches the browser in under 100 ms at p95** | the hub subscribes to the stores on the engine's queue and writes the frame on the next turn: no timer, no batch window, no polling | test `LiveHubTests.aChangeIsWrittenWithNoTimerBetween` (the clock injected and never advanced: the frame still comes); bench `LiveLatencyBench.aStatusChangeToItsFrame` (500 changes, a real WebSocket, p50 and p95 from `Changes.send` to the frame read; G1); the web bench's `status-to-paint` (G1) |
| **Deltas are strictly ordered and idempotent** | `prev` and `seq` on every delta; the client's four-row table | `LiveHubTests.everyDeltasPrevIsTheLastSeqSent`, `aFoldedDeltaCoversItsRange`; `socket.test.mjs`: `aDuplicateDeltaIsDropped`, `aDeltaOutOfOrderIsNeverApplied`, `aGapSubscribesAgainWithSince` |
| **A slow client is late, never wrong** | folding only while the socket can't take bytes; one folded delta with each entry's value now | `LiveHubTests.aConnectionThatCantWriteGetsOneFoldedDelta`, `nothingIsDroppedForASlowClient` |
| **A reconnect is invisible** | the client keeps its rows; `subscribe` with `since`; `mode: resume` and one catch-up delta when the stream remembers | `LiveResumeTests.aResumeInTheSameEpochSendsNoSnapshot`, `aResumeGetsExactlyWhatChangedSince`, `aResumeOlderThanTheStreamRemembersGetsASnapshot`; `socket.test.mjs`: `noRowIsRemovedWhileReconnecting` |
| **A server restart is invisible: under 2 s, no lost or duplicate row, no empty state** | the token's hash at rest; retries at 100, 200, 400 ms then 1 s; a snapshot reconciled by id in one render; a chat resumed by `after` | `WebTokensTests.aTokenIsTakenAfterTheServerRestarts`; `LiveResumeTests.aNewEpochGetsASnapshotNotAResume`, `aChatResumesByItsLastItemAcrossARestart`; `socket.test.mjs`: `aSnapshotIsReconciledByIdInOneRender`, `aChatTailReplacesFromItsItemOn`; the web bench's `restart` (the list never empty in any frame, every subscription current inside 2 s; G1) |
| **An action shows at once and is reconciled once** | the echo as an overlay keyed by the action id; the ack's `applied` `seq`; the refusal takes it back; the same action id on a retry | `DraftTests.theAckSaysTheSeqItsEffectIsAt`, `aRepeatedActionIsAnsweredAsBefore`; `socket.test.mjs`: `theOverlayStaysUntilTheStreamReachesApplied`, `aRefusalTakesTheOverlayBack`, `aPendingActionIsSentAgainWithTheSameId`; the web bench's `click-to-response` under 50 ms (G1) |
| **A growing message is appended, not resent** | the `text` op with the length before it | `ChatStoreTests.aGrowingReplyIsSentAsAppendedText`, `anAppendNeverCutsASurrogatePair`, `aChangeThatIsntAnAppendIsASet`; `socket.test.mjs`: `aTextOpWhoseOffsetIsntMineIsAGap` |
| **Nothing flashes** | rows keyed by id and updated in place; no list is emptied; a card keeps its place across a restart by project and question | `socket.test.mjs`: `aCardKeepsItsPlaceAcrossANewCardId`; the web bench counts layout shifts during `restart` and `status-to-paint`: none |
| **A long chat scrolls and opens fast** | the newest 200 items first, older ones paged; only what is near the viewport is in the DOM | the web bench's `chat-10k-first-paint` under 150 ms and `scroll` with no frame over 33 ms (G2) |

`socket.test.mjs` is the web lane's own test of `socket.js` and `store.js`, run by Node 22's test runner against the
vectors and a scripted fake socket (`node --test WebApp/test/`, through `scripts/test.sh --web`, which I1 adds).

## Security

What the listener adds to the attack surface, each with the test that holds it. `WebSecurityTests` and
`WebListenerTests` drive a real listener on a scratch port with a raw socket client, so headers a browser would never
send can be sent.

| What is added | The rule | Test |
| --- | --- | --- |
| A TCP listener on the machine | bound to `127.0.0.1` and nothing else; off until `web.open`; closed with the last token | `WebListenerTests.theListenerIsBoundToLoopbackOnly` (`getsockname`), `noListenerBeforeTheUserAsks`, `theListenerClosesWithTheLastToken` |
| DNS rebinding (a page on another name resolving to 127.0.0.1) | `Host` must be exactly `127.0.0.1:<port>`; anything else is 421 with no body | `WebSecurityTests.aRequestUnderAnotherHostNameIsRefused` (`evil.example:47830`, `localhost:47830`, no `Host`, two `Host`s) |
| Cross-site WebSocket hijacking (another origin's page opening `/ws`) | `Origin` must be exactly `http://127.0.0.1:<port>`; missing is refused; `Sec-Fetch-Site` other than `same-origin` is refused | `WebSecurityTests.anUpgradeFromAnotherOriginIsRefused`, `anUpgradeWithNoOriginIsRefused`, `anUpgradeFromAnotherPortIsRefused` |
| An unauthenticated socket | the server sends nothing before a valid `auth`; 5 s to send it; then `bye` and 4401 | `WebSecurityTests.nothingIsSentBeforeAuth`, `aSocketThatNeverAuthenticatesIsClosed` |
| The pairing code | 16 random bytes; 120 s; once; the refusal never says which of wrong, used or late | `WebTokensTests.aCodeIsTakenOnce`, `aLateCodeIsRefused`, `theRefusalDoesntSayWhy` |
| The token | 32 random bytes; only its SHA-256 at rest, in a 0600 file in the 0700 folder; 24 h; at most 8; compared in constant time | `WebTokensTests.onlyTheHashIsAtRest`, `theTokensFileIsOwnerOnly`, `aTokenRunsOut`, `theNinthTokenDropsTheOldest` |
| Revocation | `web.revoke` drops every token and closes their connections with 4403 | `WebTokensTests.revokingClosesTheConnections` |
| What a token may do | `read` and `draft` only: every other kind on a WebSocket is `voice`; `answer`, `hold`, `stop`, `lead` among them | `WebSecurityTests.aWebConnectionChangesNothing` (every kind of `NodeWire.kinds` but the read and draft ones, each refused and nothing acted on) |
| Who may mint a code | `web.open` and `web.revoke` need the user's voice and the typed code, are recorded in the vault, and are refused on a WebSocket | `WebTokensTests.openingTheWebNeedsTheUsersVoice`, `aSessionsProcessCantOpenTheWeb` |
| The page running hostile text | CSP: `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self' ws://127.0.0.1:<port>; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; require-trusted-types-for 'script'; trusted-types 'none'` on every response | `WebAssetsTests.everyResponseCarriesThePolicy`; the web bench's `hostile-text` page (a session, a card and a chat full of markup: no script runs, no element is made from it) |
| Markup in the client | no `innerHTML` and its relatives, no `eval`, no inline script or handler, in any file of `WebApp/` | `WebAppLintTests.noFileBuildsMarkupFromText`, `theRuleFindsEachForm` |
| Sniffing, framing, leaking | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Resource-Policy: same-origin`, an `ETag`, and `Cache-Control: no-cache` but on a build's files under `/_/<build>/` (`public, max-age=31536000, immutable`; the page names its files by them) | `WebAssetsTests.everyResponseCarriesTheHeaders`, `theIndexIsRevalidatedAndTheBuildsFilesAreKept` |
| What is served | only files in the embedded list, by exact match; content types from a fixed table; no SVG, no HTML but `index.html` and `bench.html`; the generator refuses anything else | `WebAssetsTests.aPathOutsideTheListIs404` (`/../`, `%2e%2e`, a double slash, a NUL), `theGeneratorRefusesAnSVG` |
| Files an agent produced | none served in these slices (LW-D11); later from a separate origin, never as SVG or HTML | `ChatStoreTests.anImageCarriesNoBytes` |
| Resource exhaustion | 8 KiB of head, 64 KiB a client frame, 32 connections, the handshake's and `auth`'s 5 s, two missed pings | `WebListenerTests.aHeadOver8KIsRefused`, `aFrameOver64KClosesTheConnection`, `theThirtyThirdConnectionIsRefused`, `aStalledHandshakeIsClosed` |
| Frames a browser never sends | an unmasked client frame, a reserved bit, a bad UTF-8 text, a control frame over 125 bytes: each closes | `WebSocketTests` (lane A's codec cases) |
| Logs | no token, code or chat text in a log line | `WebSecurityTests.noSecretReachesTheLog` (the server's `note` recorded through a whole session) |
| The port, taken by another process | the web is refused, said in `status`; never another port | `WebListenerTests.aTakenPortRefusesTheWebAndSaysSo` |
| The port, taken while the server is down (LW-D1) | not closed in these slices; a token read by a squatter reads what its uid reads, and a draft is confirmed on the command line | written in the security document's S11 by I1; closed by H1 |

## Lanes, and who owns what

Seven lanes, each a worktree and a branch from `v2` after W0. **No file is in two rows.** A lane's tests are in the
files it owns.

| Lane | Branch | Owns (creates, and alone edits) |
| --- | --- | --- |
| **A** the listener | `v2-ws` (in flight) | `Sources/VibeNode/Web/WebSocketFrame.swift`, `WebSocketHandshake.swift`, `HTTPHead.swift`, `WebListener.swift`, `WebConnection.swift`; `Sources/VibePlatform/Sockets.swift`, `Sockets+Linux.swift`, `Sockets+Darwin.swift` (the TCP functions); `Tests/VibeNodeTests/WebSocketTests.swift`, `WebListenerTests.swift`; `Tests/VibePlatformTests/TCPSocketsTests.swift` |
| **B** the hub and the stores | `v2-live` | `Sources/VibeNode/Live/LiveStream.swift`, `LiveHub.swift`, `LiveRequests.swift`, `SessionValue.swift`, `NodeStatusStore.swift`, `ChatStore.swift`, `ChatValue.swift`, `TerminalRelay.swift`; `Sources/VibeNode/Stores/CardStore.swift` and `Sources/VibeNode/Server/CardRequests.swift` (slice 3 only: the draft); `Sources/VibeNode/Host/HostLink.swift` (slice 4 only: `attach`); `Tests/VibeNodeTests/LiveHubTests.swift`, `LiveResumeTests.swift`, `NodeStatusStoreTests.swift`, `ChatStoreTests.swift`, `DraftTests.swift`, `TerminalRelayTests.swift` |
| **C** the static files | `v2-static` | `Sources/VibeNode/Web/WebAssets.swift`, `WebSecurityHeaders.swift` (C1: renamed from `WebHeaders.swift`, lane A's request headers' type); `scripts/webapp-embed.sh`; `Tests/VibeNodeTests/WebAssetsTests.swift`. (`WebAssets.generated.swift` is made by C1 once and by the integrator after) |
| **D** the web client | `v2-web-ui` (in flight) | everything under `WebApp/` except `WebApp/wire/` and `WebApp/bench/` |
| **E** validators and vectors | `v2-wire` | `Sources/VibeNode/Live/Wire/WireSchema.swift`, `WireVectors.swift`; `Sources/vibeswitcher-cli/WireCommand.swift`; `WebApp/wire/validators.js`, `WebApp/wire/vectors.json`; `Tests/VibeNodeTests/WireVectorsTests.swift` |
| **F** `vibeswitcher web` and the security tests | `v2-webcmd` | `Sources/VibeNode/Web/WebTokens.swift`, `WebAccess.swift`; `Sources/VibeNode/Server/WebRequests.swift`; `Sources/vibeswitcher-cli/Web.swift`, `Answer.swift` (slice 3 only: the draft); `Tests/VibeNodeTests/WebTokensTests.swift`, `WebSecurityTests.swift`, `WebAppLintTests.swift` |
| **G** the bench and the sandbox | `v2-webbench` | `scripts/web-bench.sh`, `scripts/web-bench/` (the driver, `*.mjs`), `scripts/sandbox-server.sh`; `WebApp/bench/`; `Tests/VibeNodeTests/LiveLatencyBench.swift` |
| **The integrator** (the lead, or one agent at a time) | `v2` | `Sources/VibeNode/Server/NodeWire.swift`, `NodeServer.swift`, `Requests.swift`, `ServerStart.swift`, `ServerArguments.swift`; `Sources/VibeNode/Web/WebSeams.swift`, `Sources/VibeNode/Live/LiveSeams.swift`; `Sources/vibeswitcher-cli/main.swift`, `Status.swift`; `Sources/VibeNode/Web/WebAssets.generated.swift`; `scripts/test.sh`; the two specs; the port map |

`Package.swift` doesn't change: every new file is in a target that exists, and no resource is declared.

## The seams (W0 writes them; every lane builds against them)

```swift
// Sources/VibeNode/Live/LiveSeams.swift
/// What the hub writes to: one connection, whatever carries it. `send` takes one message as compact JSON (no
/// newline); `writable` is false while the carrier's buffer is full, and `onWritable` is called when it drains.
public protocol LiveTransport: AnyObject, Sendable {
    func send(_ message: Data)
    var writable: Bool { get }
    var onWritable: (() -> Void)? { get set }
    /// `bye` with `code` and `reason`, then the close.
    func close(code: String, reason: String)
}
/// What a connection may ask of the hub.
public struct LiveRights: OptionSet, Sendable { public static let read, draft: LiveRights }

// Sources/VibeNode/Web/WebSeams.swift
/// The listener's one port (LW-D3); the origin is `http://127.0.0.1:<port>` (LW-D5).
public enum NodeWeb { public static let port: UInt16 = 47830 }
/// One file the listener may serve, with its headers ready (lane C makes them; lane A writes them).
public struct WebAsset: Sendable { public var body: Data; public var headers: [(String, String)] }
public protocol WebAssetSource: Sendable { func asset(path: String) -> WebAsset? }
/// Who may connect (lane F): a first frame's `args` judged, and the `hello` additions for it.
public protocol WebGate: AnyObject, Sendable {
    func admit(_ args: [String: NodeWire.Value]) -> WebAdmission?   // nil: refused
    var wanted: Bool { get }                                         // a code or a token is alive: the listener stays up
}
public struct WebAdmission: Sendable { public var rights: LiveRights; public var auth: NodeWire.Value; public var token: String }
/// What the listener hands an authenticated socket to (lane B's hub, wired by I1).
public protocol WebSocketHandler: AnyObject, Sendable {
    func opened(_ transport: LiveTransport, rights: LiveRights)
    func text(_ message: Data, on transport: LiveTransport)
    func binary(_ message: Data, on transport: LiveTransport)
    func closed(_ transport: LiveTransport)
}
```

`NodeWire` (W0): `kinds` gains `subscribe`, `unsubscribe`, `chat.page` (`.anyone`), `draft`, `draft.clear` (a new
`Voice.webDraft`), `web.open`, `web.revoke` (`.user`), `term.open`, `term.close` (a new `Voice.webTerminal`); none is
in `taken` until its integration task. `changesState` is true for both web voices (a draft and a terminal change
state) and false for `.anyone` and `.leadToolServer`, as before. `Bye` gains `code: String?` (`init(reason:code:)`,
`code` defaulting to nil). `Hello` gains `auth: Value?` and `assets: String?` (both defaulting to nil in its `init`).
A nil field is not written, so the Unix socket's lines are as before. `NodeWire.Snapshot`, `Delta` and their encoders
are lane B's, in `LiveStream.swift`.

## Tasks

A task's steps are checkboxes. "Failing tests" names every test the task must add; each is seen failing for the
right reason before the code that passes it.

### Task W0: The seams, the kinds and the stubs (the integrator)

**Needs:** this plan's decisions accepted; `v2-ws` and `v2-web-ui` read once, for their names.

**Files:**
- Create: `Sources/VibeNode/Live/LiveSeams.swift`, `Sources/VibeNode/Web/WebSeams.swift`; stubs
  `Sources/vibeswitcher-cli/Web.swift` and `WireCommand.swift` (each a `run` that says "not built yet", exit 69)
- Modify: `Sources/VibeNode/Server/NodeWire.swift`, `Sources/vibeswitcher-cli/main.swift` (two dispatch lines),
  `Tests/VibeNodeTests/NodeWireTests.swift`

**Interfaces:**
- Consumes: what `v2-ws` named its codec and what `v2-web-ui` named `store.js`'s feed. Where they differ from this
  plan, the plan's names here and in lanes A and D are changed to theirs, in this task's commit.
- Produces: [the seams](#the-seams-w0-writes-them-every-lane-builds-against-them) above, the new kinds, `Bye.code`,
  `Hello.auth`, `Hello.assets`.

- [x] **Step 1: Failing tests** (`NodeWireTests`):
  - `theLiveKindsAreNamedAndNotYetTaken`: each new kind is in `kinds` with its voice and not in `taken`.
  - `anOlderHelloStillDecodes`: a `hello` without `auth` and `assets`, and a `bye` without `code`, decode.
  - `aKindNobodyTakesStillChangesState`: `changesState("draft")` and `changesState("web.open")` are true.
- [x] **Step 2:** the seams, the kinds, the fields, the stubs. The server answers each new kind `unknown-kind`, as
  today (`ServerTests.anUnlistedRequestIsRefused` asks each; `RequestsTests.everyKindIsClassifiedAsAReadOrAStateChange`
  and `VoiceRuleTests` classify them).
- [ ] **Step 3:** lints; push; both jobs green. The lanes branch from this commit. (Lints done in W0's commit; the
  push and the jobs are the lead's.)

### Task A1: The RFC 6455 codec lands (lane A)

**Needs:** W0. **Files:** `WebSocketFrame.swift`, `WebSocketHandshake.swift`, `HTTPHead.swift`,
`Tests/VibeNodeTests/WebSocketTests.swift`.

**Interfaces:**
- Consumes: swift-crypto's `Insecure.SHA1` (through `VibeCore`'s export).
- Produces:
  - `enum WebSocketFrame { static func parse(_ buffer: inout Data, maxPayload: Int) -> Result<Parsed?, Violation>;
    static func text(_:) -> Data; static func binary(_:) -> Data; static func ping(_:), pong(_:), close(code:reason:) }`
    with `Parsed { opcode, fin, payload }` and messages reassembled from fragments by `WebSocketAssembler`;
  - `enum WebSocketHandshake { static func accept(key: String) -> String; static func response(for: HTTPHead) ->
    Result<Data, Refusal> }`;
  - `struct HTTPHead { method, target, version, headers (case-insensitive, duplicates kept) }` with
    `static func parse(_ buffer: Data, limit: Int) -> Result<HTTPHead?, Refusal>`.

- [ ] **Step 1: Failing tests** (`WebSocketTests`, pure, both systems): `theAcceptKeyIsRFC6455s` (the RFC's own
  example), `anUnmaskedClientFrameIsAViolation`, `aReservedBitIsAViolation`, `aControlFrameOver125BytesIsAViolation`,
  `aFragmentedTextIsReassembled`, `aPingBetweenFragmentsIsAnswered`, `aTextThatIsntUTF8IsAViolation`,
  `aPayloadOverTheLimitIsAViolationBeforeItIsBuffered`, `aFrameSplitAtEveryByteParsesTheSame`,
  `aHeadWithTwoHostsKeepsBoth`, `aHeadOverTheLimitIsRefused`, `aRequestLineThatIsntGETIsRefused`.
- [ ] **Step 2:** the spike's code made to pass them. **Step 3:** lints, under load, commit.

### Task A2: The loopback listener (lane A)

**Needs:** A1. **Files:** `WebListener.swift`, `WebConnection.swift`, `Sources/VibePlatform/Sockets*.swift`,
`WebListenerTests.swift`, `TCPSocketsTests.swift`.

**Interfaces:**
- Consumes: `WebAssetSource`, `WebGate`, `WebSocketHandler`, `LiveTransport` (the seams); A1.
- Produces:
  - `Platform.Sockets.listenLoopback(port: UInt16) -> Result<(fd: Int32, port: UInt16), Errno>` (`AF_INET`,
    `127.0.0.1`, `SO_REUSEADDR`, close-on-exec, non-blocking), `acceptStream(_:) -> Int32`, `boundAddress(_:)`;
  - `final class WebListener { init(port: UInt16, assets: WebAssetSource, gate: WebGate, handler: WebSocketHandler,
    queue: DispatchQueue, clock: NodeClock?, note:); func start() -> Result<UInt16, Refusal>; func stop(); var port:
    UInt16?; var connectionCount: Int; func closeAll(code:reason:) }`;
  - `WebConnection: LiveTransport`: the head, the `Host` and `Origin` checks, the upgrade, the `auth` frame handed
    to the gate, then messages to the handler; `writable` from its pending bytes; pings on the clock.

- [ ] **Step 1: Failing tests**: every `WebListenerTests` name in [Security](#security), and
  `aGetServesTheAssetWithItsHeaders`, `anUpgradeBecomesAHandlerConnection`, `aTextFrameReachesTheHandlerWhole`,
  `aConnectionWhoseBufferIsFullSaysNotWritableThenDrains`, `twoMissedPingsCloseIt` (the clock injected),
  `stoppingClosesEveryConnectionWith1001`. In `TCPSocketsTests`: `aLoopbackListenerIsBoundTo127001`,
  `port0GivesAPortTheKernelPicked`, `aTakenPortSaysAddressInUse`.
- [ ] **Step 2:** the listener, with stand-in assets, gate and handler in the tests. **Step 3:** lints, under load.

### Task B1: Streams and the hub (lane B)

**Needs:** W0. **Files:** `LiveStream.swift`, `LiveHub.swift`, `LiveRequests.swift`, `LiveHubTests.swift`.

**Interfaces:**
- Consumes: `NodeSessions.changes`, `LeadStore.changes`, `CardStore.changes` (`Changes<…>.subscribe(on:)` on the
  engine's queue), `CardStore.Card.value`, `LeadStore.Lead.value`, `LiveTransport`, `LiveRights`.
- Produces:
  - `final class LiveStream` (keyed): `seq`, `entries: [String: (value: NodeWire.Value, changed: Int)]`,
    `removed` (the last 256), `apply(id:value:)`, `snapshot() -> NodeWire.Value`, `changes(since:) -> (prev: Int,
    seq: Int, changes: [...])?` (nil: older than it remembers);
  - `final class LiveHub: WebSocketHandler`: `init(queue:epoch:now:)`, `add(collection:_ stream:)`,
    `func handle(_ request: NodeWire.Request, on: LiveTransport, rights: LiveRights) -> NodeWire.Reply?` for
    `subscribe` and `unsubscribe`, `seq(of collection: String) -> Int` (for `applied`), `closed(_:)`;
  - per connection and `sub`: the `seq` last sent; on a stream's change, to each subscriber that is `writable`, one
    delta from its last-sent `seq` to the stream's; to one that isn't, nothing until `onWritable`.

- [x] **Step 1: Failing tests** (`LiveHubTests`, on a recording `LiveTransport`): `subscribeGetsAReplyThenASnapshot`,
  `aChangeIsOneDeltaWithPrevAndSeq`, `everyDeltasPrevIsTheLastSeqSent`, `aRemovalIsAValueOfNull`,
  `anEqualValueSendsNothing`, `aChangeIsWrittenWithNoTimerBetween`, `aConnectionThatCantWriteGetsOneFoldedDelta`,
  `aFoldedDeltaCoversItsRange`, `nothingIsDroppedForASlowClient`, `twoClientsSeeTheSameSeq`,
  `subscribingAgainUnderALiveSubReplacesIt`, `unsubscribeStopsTheEvents`, `aClosedConnectionIsForgotten`,
  `aConnectionWithoutReadIsRefused`, `anUnknownCollectionIsBadArgs`, `theSessionsSnapshotIsEverySessionOnce`; and
  `aWebConnectionsTextIsARequest`, `aTextThatIsntARequestCloses` (the hub's `WebSocketHandler` side).
- [x] **Step 2:** the stream and the hub. **Step 3:** lints, under load.
- **As built (B1):** `handle(_:on:rights:) -> Bool`, not `-> Reply?`: the hub writes the reply itself, so the
  subscription's first event can't reach the transport before it; false means not the hub's kind, and the caller
  answers. `follow(_ changes:into:value:)` feeds a stream from a store (`value` nil: gone); `others` takes a
  WebSocket's requests of other kinds (I1 wires the rights and `Requests`; none: `unknown-kind`). A delta's `changes`
  are in the order of each id's latest change in its range, not its first (the stream keeps one `seq` an entry); the
  contract's "in the order the ids first changed" is the integrator's to reword.

### Task B2: The node's status as a stream, and a session's whole value (lane B)

**Needs:** B1. **Files:** `NodeStatusStore.swift`, `SessionValue.swift`, `NodeStatusStoreTests.swift`.

**Interfaces:**
- Consumes: `Requests.statusValue()` (public, read on the engine's queue), `HostLink.changes`, `LeadStore.changes`,
  `CardStore.changes`, the engine's refresh (`NodeClock`), `Session`.
- Produces:
  - `extension Session { var liveValue: NodeWire.Value }`: the eight fields `Requests.value(_:)` writes, by the same
    names, and the contract's twelve new ones;
  - `final class NodeStatusStore { let changes = Changes<NodeWire.Value>(); func look() }`: `statusValue()` without
    `sessions` and `leads`, with `web`, sent under the node's id; `look()` on each of those streams' changes and at
    each refresh (an equal value sends nothing, `Changes`' own rule).

- [x] **Step 1: Failing tests**: `aSessionsLiveValueHasStatussEightFieldsUnchanged`, `shownStatusIsTheLeadsAsk`,
  `aSessionWithNoTranscriptSaysSo`, `theNodesValueIsStatusWithoutSessionsAndLeads`, `aNewNoticeIsADelta`,
  `aLookThatFindsNothingNewSendsNothing`, `anAcceptedRequestIsADelta`; and `eachRefreshLooks`.
- [x] **Step 2:** both. **Step 3:** lints, under load.
- **As built (B2):** `NodeStatusStore(requests:web:)` (or `(queue:status:web:)`), `watch(_ changes:)` for each store
  whose change can move the value (I1: `HostLink.changes`, `LeadStore.changes`, `CardStore.changes`),
  `start(clock:)` (a look now and every `refreshEvery`, 3 s), `stop()`, `look()`. `Requests.accepted` has no change
  stream, so I1 calls `look()` where a request is accepted (`Requests.acting` is the place). `webOff` is `web` until
  the listener's state is wired. The hub follows it with
  `hub.follow(status.changes, into: LiveStream(collection: "node")) { $0 }`, and sessions with `{ $0.liveValue }`.

### Task B3: Resume (lane B)

**Needs:** B1. **Files:** `LiveStream.swift`, `LiveHub.swift`, `LiveResumeTests.swift`.

**Interfaces:** Consumes: B1. Produces: `subscribe`'s `since`, the reply's `mode`.

- [x] **Step 1: Failing tests** (`LiveResumeTests`): `aResumeInTheSameEpochSendsNoSnapshot`,
  `aResumeGetsExactlyWhatChangedSince` (entries changed after, ids removed after, nothing else),
  `aResumeThatIsCurrentSendsNothingUntilAChange`, `aResumeOlderThanTheStreamRemembersGetsASnapshot` (257 removals),
  `aSeqAheadOfTheStreamGetsASnapshot`, `aNewEpochGetsASnapshotNotAResume`. (The last two hold what B1 already did,
  a snapshot, so they passed before the resume; the other four failed on `mode`.)
- [x] **Step 2:** the resume. **Step 3:** lints, under load.
- **As built (B3):** a `since` out of form (not `{epoch: string, seq: int ≥ 0}`) is a snapshot, not `bad-args`. A
  one-off probe (not committed), in process on a recording transport, debug build, 8 subscribers, 40 entries: 500
  changes from `Changes.send` to the transport's `send`, p50 0.42 ms, p95 0.70 ms, max 1.1 ms (2026-11-17, load
  about 3). The budget's number over a real WebSocket is G1's `LiveLatencyBench`.

### Task C1: The embedded files and their headers (lane C)

**Needs:** W0. **Files:** `WebAssets.swift`, `WebSecurityHeaders.swift`, `scripts/webapp-embed.sh`,
`WebAssets.generated.swift` (first made here, from a three-file `WebApp/` placeholder if lane D hasn't merged),
`WebAssetsTests.swift`.

**C1, 2026-11-17, as built:** `WebHeaders` is `WebSecurityHeaders` (the lead's call: lane A's in-flight code defines
a public `struct WebHeaders` for a request's headers). The lead asked for a browser cache that keeps the page's
files and always asks again for the page, so a build's files are also served under `/_/<build>/<path>`,
`immutable` for a year, and `index.html` is served with its own `src` and `href` naming them there; a module's
relative imports follow. Everything else is `no-cache` with an `ETag`. The 304 is `WebAssets.response(to:ifNoneMatch:)`,
for the listener to call (the seam's `asset(path:)` doesn't see the request's headers). Embedded: all of `WebApp/`
but dotfiles, Markdown and shell scripts (the folder's notes and tools), `shots/`, `test/` and `tests/` (Node's tests of the page). The HTML allowed is `index.html` and
`bench/bench.html` exactly (lane G: the bench page at that path, or ask). A query (`?mock`) is left off before the
path is matched. Lane D's in-flight `icon.svg` is refused by the generator (the Security table's "no SVG"): lane D
gives a PNG.

**Interfaces:**
- Consumes: `WebAssetSource`, `WebAsset`; `WebApp/` in the source tree (the stale test reads it, as the lints read
  sources).
- Produces: `struct EmbeddedAssets: WebAssetSource` (`init(port:)`, the generated table; `/` is `index.html`;
  `/build.json` is `{"assets": "<the first 8 hex of the SHA-256 of the sorted list of paths and hashes>"}`),
  `static var build: String`; `struct FolderAssets: WebAssetSource` (`--test-web-root`: files read at each request,
  the same headers, refusing a path that leaves the folder, following no link); `WebSecurityHeaders.all(port:
  contentType:etag:caching:)` (the Security table's); `WebAssets.response(to:ifNoneMatch:)` (200 or 304);
  `scripts/webapp-embed.sh` (sorted, `LC_ALL=C`, base64 in 76-column chunks, reproducible; `--root`, `--out`).

- [x] **Step 1: Failing tests**: the `WebAssetsTests` names in [Security](#security), and
  `theEmbeddedFilesAreWebAppsToday` (stale: the generator's output over the tree equals the checked-in file, and
  every file's hash against the tree), `theGeneratorIsReproducible`, `rootServesIndex`, `anETagThatMatchesIs304`,
  `theBuildIsTheSameForTheSameFiles`, `aTestRootNeverLeavesItsFolder`, `theContentTypeComesFromTheTable`; added:
  `theIndexIsRevalidatedAndTheBuildsFilesAreKept`, `theEmbeddedFilesStaySmall` (256 KiB a file, 1 MiB in all).
- [x] **Step 2:** the generator, the table, the headers. **Step 3:** lints, under load.

### Task E1: The schema, the vectors and the validators (lane E)

**Needs:** W0; B2's `liveValue` for the session rows (until it lands, the session schema is the contract's table and
`theSchemaIsWhatTheEncodersWrite` covers leads and cards only).

**Files:** `WireSchema.swift`, `WireVectors.swift`, `WireCommand.swift`, `WebApp/wire/validators.js`,
`WebApp/wire/vectors.json`, `WireVectorsTests.swift`.

**Interfaces:**
- Consumes: `CardStore.Card.value`, `LeadStore.Lead.value`, `Session.liveValue`, `NodeWire`'s messages.
- Produces: `WireSchema.entities` and `.messages` (name, type, optional, per field); `WireVectors.files() ->
  [String: Data]`; `vibeswitcher wire-vectors --out DIR` (hidden, like `install-record`); `validators.js` exporting
  `validate(kind, value) -> string | null` (the first field that fails, or null) for every message and entity;
  `vectors.json`: `{name: frame}` for every vector of the contract.

- [ ] **Step 1: Failing tests**: `theSchemaIsWhatTheEncodersWrite` (samples with every optional set and unset: the
  keys and types the encoders write are the schema's, both ways), `theCheckedInFilesAreWhatTheGeneratorWrites`,
  `everyVectorPassesItsValidator` (run by Node 22 from the test, skipped with its reason where there is no `node`),
  `aVectorWithAWrongTypeFailsNamingTheField`, `anUnknownFieldPasses` (rule 3),
  `theContractsVectorsAreAllThere` (every name in the contract's §11 and §8).
- [ ] **Step 2:** the schema, the generator, the files. **Step 3:** lints, under load.

### Task F1: Tokens, and `vibeswitcher web` (lane F)

**Needs:** W0. **Files:** `WebTokens.swift`, `WebAccess.swift`, `WebRequests.swift`, `Web.swift`,
`WebTokensTests.swift`.

**Interfaces:**
- Consumes: `WebGate`, `WebAdmission`, `LiveRights`; `Requests`' voice path (its handler is called by I1's line in
  `Requests.act`); `TypedWord`, `NodeIds.code(action:)`, `NodeJournal` (the command line's journal entry).
- Produces:
  - `final class WebTokens` (`<root>/v2/web-tokens.json`, format 1, 0600, written the way `PrivateWriteLint`
    asks): `issue(now:) -> String`, `check(_ token: String, now:) -> Bool` (constant time over the hashes),
    `revokeAll()`, `live(now:) -> Int`; a newer format is refused, an unreadable file is no tokens;
  - `final class WebAccess: WebGate`: `openCode(now:) -> String`, `admit(_:)` (a `pair` taken once inside 120 s
    issues a token; a `token` is checked), `wanted`, `onChange` (the listener is started or stopped by I1's wiring);
  - `extension Requests { func webOpen(_:reply:); func webRevoke(_:reply:) }`: the result of `web.open` is
    `{"url": "http://127.0.0.1:<port>/#pair=<code>", "expiresIn": 120}`, or `refused` with why the port is taken;
  - `vibeswitcher web [--revoke]`: the server check, what it will do said, the typed code, the request, the URL
    printed on its own line, the journal entry.

- [ ] **Step 1: Failing tests**: the `WebTokensTests` names in [Security](#security) and [Seamless](#seamless), and
  `aNewerTokensFormatIsRefused`, `aTokensFileThatCantBeReadIsNoTokens`, `theUrlCarriesTheCodeInItsFragment`,
  `webWithNoTerminalRefusesBeforeAnyRequest`.
- [ ] **Step 2:** tokens, the gate, the requests, the command. **Step 3:** lints, under load.

### Task D1: The socket feed (lane D)

**Needs:** W0, and the contract; E1's `vectors.json` when it lands (until then the contract's §11, by hand).

**Files:** `WebApp/socket.js`, `WebApp/store.js`, `WebApp/mock.js`, `WebApp/test/socket.test.mjs`.

**Interfaces:**
- Consumes: the contract's §2 to §5, §8 and §10; `WebApp/wire/validators.js`.
- Produces: `socket.js`: `connect({url, storage, WebSocket, now, setTimeout})` (everything it touches is passed in,
  so the tests script it), which authenticates, subscribes for what `store.js` holds, follows the client's table,
  resumes as [the contract's resume logic](../specs/2026-11-17-v2-live-wire-contract.md#the-clients-resume-logic),
  and keeps pending actions. `store.js` keeps its shape for the views; `mock.js` stays as the feed for `?mock`, now
  replaying `vectors.json`.

- [ ] **Step 1: Failing tests** (`socket.test.mjs`): every `socket.test.mjs` name in [Seamless](#seamless), and
  `thePairCodeLeavesTheAddressBar`, `theTokenIsKeptForTheTabOnly`, `aByeOfAuthStopsRetrying`,
  `aNewerServersAssetsReloadWhenIdle`, `anUnknownEventIsSkipped`, `anUnknownEventMarkedMustReloads`,
  `everyFrameReceivedPassesItsValidator`.
- [ ] **Step 2:** `socket.js`, and `store.js` taking snapshots and deltas. **Step 3:** `?mock` still shows the mock.

### Task D2: The live page's views on the feed (lane D)

**Needs:** D1. **Files:** `WebApp/` views (the mock's).

- [ ] **Step 1:** the node strip (`node`: the build, the host's state, the rule, the notices), the session list
  (`sessions`, by `shownStatus`, with the Mac app's words and colours), the leads with their cards (`leads`, `cards`:
  a question with its options, an approval's facts in their own frame, never truncated), all keyed by id and updated
  in place.
- [ ] **Step 2:** the quiet states: reconnecting (a small mark, the rows stay), "run `vibeswitcher web` again" on
  `auth` and `revoked`, the node stopping.
- [ ] **Step 3:** shown light and dark through G1's sandbox, with shots.

### Task F2: The listener's security tests and the lints (lane F)

**Needs:** F1; A2 and C1 merged into the lane's branch (it tests them together). **Files:** `WebSecurityTests.swift`,
`WebAppLintTests.swift`.

- [ ] **Step 1: Failing tests**: every `WebSecurityTests` and `WebAppLintTests` name in [Security](#security). Each
  is shown failing on a mutant where it can be (the `Host` check removed, the `Origin` check loosened to a prefix,
  `auth` skipped, an `innerHTML` added to a scratch copy of a file).
- [ ] **Step 2:** whatever they find is fixed in its owner's lane, through the lead.

### Task G1: The sandbox, the latency bench and the web bench's first three measures (lane G)

**Needs:** W0 to write; I1 to pass. **Files:** `scripts/sandbox-server.sh`, `scripts/web-bench.sh`,
`scripts/web-bench/`, `WebApp/bench/`, `LiveLatencyBench.swift`.

**Interfaces:**
- Consumes: `ScratchNode`'s way of starting a scratch host and server (`Tests/VibeNodeTests/ScratchNode.swift`),
  `FakeClaude`, `--test-web-port=`, `--test-web-root=`, `--test-web-pair=`; the Chrome on this machine, headless,
  over its DevTools protocol, from Node 22.
- Produces: `scripts/sandbox-server.sh run | url | shot NAME | quit` (a scratch home, a scratch host, the built
  server, three fake sessions and a lead with a question; `url` prints the page's address with a pairing code;
  `shot` writes light and dark PNGs to `.build/sandbox-shots/`); `scripts/web-bench.sh` (under `vs-heavy`) with
  `status-to-paint`, `restart`, `click-to-response`, `first-load`, `hostile-text`, each printing p50 and p95 and
  failing over its budget; `LiveLatencyBench` (`--perf` only).

- [ ] **Step 1:** `LiveLatencyBench.aStatusChangeToItsFrame` and `aSubscribeToItsSnapshot`, failing over the
  contract's §7.
- [ ] **Step 2:** the sandbox script. **Step 3:** the bench's driver and its five measures. **Step 4:** the numbers
  recorded in this plan's [Measured](#measured).

### Task I1: Slice 1 wired (the integrator)

**Needs:** A2, B1, B2, B3, C1, E1, F1 merged; D1 and D2 merged or its `WebApp/` at the mock.

**Files:** `ServerStart.swift`, `ServerArguments.swift`, `NodeServer.swift`, `Requests.swift`, `NodeWire.swift`
(`taken`), `Status.swift`, `WebAssets.generated.swift` (regenerated), `scripts/test.sh` (`--web`), the security
document (S11: the port while the server is down; the principals: a web client), the design (the deviation, under
"The node's processes"), `Tests/VibeNodeTests/ServerTests.swift`, `ScratchNodeTests.swift`.

- [ ] **Step 1: Failing tests**: `ServerTests.subscribeOnTheUnixSocketGetsASnapshotThenDeltas`,
  `aLineClientGetsEventsBetweenReplies`; `ScratchNodeTests.aPageSessionFromPairToDelta` (a scratch node, `web.open`
  in the scratch form, a WebSocket client: `auth`, four subscriptions, a fake session's status change arriving as a
  delta), `theWebIsOffUntilAsked`, `aTestWebFlagIsRefusedOnTheUsersServer`, `statusSaysTheWebsState`.
- [ ] **Step 2:** the hub made at the server's start with the three stores and the node's; `NodeServer`'s
  connection as a `LiveTransport`; `Requests.act` handing `subscribe`, `unsubscribe`, `web.open` and `web.revoke`
  on; `Requests.value(_:)` calling `liveValue`; the listener started and stopped on the gate's `onChange`; the
  three test flags; `status`'s `web` line.
- [ ] **Step 3:** lints, the focused suites, both jobs green. **Step 4:** the user is shown slice 1 (below).

### Slice 2: the chat

- **Task B4 (lane B): `ChatStore`.** Per session with a subscriber: the transcript read by `ChatReader` into a
  `ChatLog`, its `ChatTimeline.items` as wire items (`ChatValue.swift`), the file's changes from
  `Platform.FolderWatch`, the ops by difference (`text` when only the text grew, else `set`, `add`), a chat stream
  with its 512 ops, `chat.page`, the `tail`. Tests (`ChatStoreTests`): the Seamless and Security names, and
  `aNewEntryIsAnAdd`, `aToolsResultIsASetOfItsRun`, `theSnapshotIsTheNewest200`, `aPageIsTheItemsJustBefore`,
  `aStreamNobodyFollowsIsDroppedAfter60s` (the clock injected), `aChatResumesByItsLastItemAcrossARestart`,
  `aSessionWithNoTranscriptIsGone`, `aTranscriptOutsideTheAgentsFoldersIsRefused` (`TranscriptReader.checkedURL`).
- **Task D3 (lane D): the chat view.** Items rendered to DOM nodes by the client's own markdown and diff code (no
  markup from text), a windowed list, `text` ops appended in place, paging upward on scroll, the scroll kept at the
  bottom only when it was there.
- **Task E2 (lane E):** the chat's schema and vectors, `TeamMessage`'s fields among them.
- **Task G2 (lane G):** `chat-10k-first-paint` and `scroll`, on the chat bench's made-up transcript.
- **Task I2 (the integrator):** `chat` and `chat.page` taken; the files regenerated.

### Slice 3: answering

- **Task B5 (lane B): the draft.** `CardStore.Card.draft`, in `value`; `draft` and `draft.clear` (the whole card id,
  the version checked against the card's, a closed card refused `gone`); cleared when the card closes; the reply's
  `applied`; the last 200 replies by action id. Tests (`DraftTests`): the Seamless names, and `aDraftTellsNobody`
  (nothing delivered, nothing recorded in the vault), `aDraftForAnOlderWordingIsRefused`,
  `aDraftOnTheUnixSocketIsRefused`, `anAnswerClearsTheDraft`.
- **Task F3 (lane F): `vibeswitcher answer CARD` with no text.** Takes the draft: the card and the draft printed,
  whole and inert (`CardText`), the code, `answer` with the draft's text and version. Tests
  (`AnswerVoiceTests`): `anAnswerWithNoTextTakesTheDraft`, `theDraftIsShownWholeBeforeTheCode`,
  `noDraftAndNoTextIsAUsageError`.
- **Task D4 (lane D):** the card's options and answer box, the echo, the line to run, the card closing on its delta.
- **Task I3 (the integrator):** `draft` and `draft.clear` taken; S3's table gains their rows.

### Slice 4: the terminal spike

- **Task B6 (lane B): `HostLink.attach` and `TerminalRelay`.** The host's `attach`, `input`, `resize` and `resync`
  through the link (the server is the app), relayed as the contract's binary frames; the host's replay on a client
  that falls behind. On a server that isn't a scratch one, `term.open` is `unknown-kind`. Tests
  (`TerminalRelayTests`, a `ScratchNode` and `FakeClaude`): `attachReplaysThenGoesLive`, `inputReachesTheProgram`,
  `aSlowClientIsResynced`, `aTerminalQuerysReplyFromTheClientIsDropped`, `theUsersServerOpensNoTerminal`.
- **Task D5 (lane D), after the user's go-ahead (LW-D13):** xterm.js vendored into `WebApp/vendor/` at an exact
  version with its hash; one page, the emulator and the stream; no clipboard writes (OSC 52), links confirmed, no
  image or link add-on.
- **Task G3 (lane G):** `key-to-echo` (under 16 ms at the median, 33 ms at p95, beyond the program's own time) and a
  busy terminal's frames. The numbers decide whether stage 5 builds on xterm.js; the task writes the contract's §9.
- **Task I4 (the integrator):** `term.open` and `term.close` taken on scratch servers.

### Tasks beside the slices

- **Task B7 (lane B, any time after B1): the hook-to-store latency, measured.** A bench from a hook's state file
  written to `NodeSessions.changes`' delta, and a written proposal (LW-D14). It edits no engine file.
- **Task H1 (not scheduled here): the host owns the listener** (LW-D1). Its own plan: `ServerChild` binds and
  passes the descriptor, the handover carries it, the server takes `--web-listener FD`.

## Showing slice 1 to the user

**The lead, 2026-11-17: the user first sees slice 1 in the sandbox, on a scratch node**, so they don't wait for an
install. The fastest way to see it is the sandbox: `bash scripts/sandbox-server.sh run`, then
`bash scripts/sandbox-server.sh url`, and the address opened in the user's browser. It is a scratch node with fake
sessions, and it is on a scratch port.

On the user's own node the page arrives as every build does: the commit pushed, both jobs green,
`scripts/install-node.sh COMMIT`, `vibeswitcher switch`, then `vibeswitcher web`. Those four are the user's.

## Order

| Task | Needs | Runs beside | The user |
| --- | --- | --- | --- |
| W0 | the decisions marked posture accepted | — | LW-D1, 3, 4, 5, 6 |
| A1 | W0 | B1, C1, D1, E1, F1, G1 | — |
| A2 | A1 | B1 to B3, C1, D1, D2, E1, F1, G1 | — |
| B1 | W0 | A1, A2, C1, D1, E1, F1, G1 | — |
| B2 | B1 | A2, B3, C1, D1, D2, E1, F1, G1 | — |
| B3 | B1 | A2, B2, C1, D1, D2, E1, F1, G1 | — |
| C1 | W0 | A1, A2, B1 to B3, D1, E1, F1, G1 | — |
| D1 | W0 | every backend task | — |
| D2 | D1 | every backend task | — |
| E1 | W0 (B2 for the session rows) | A1, A2, B1, B3, C1, D1, F1, G1 | — |
| F1 | W0 | A1, A2, B1 to B3, C1, D1, E1, G1 | — |
| F2 | F1, A2, C1 | B2, B3, D2, E1, G1 | — |
| G1 | W0 (I1 to pass) | every task | — |
| I1 | A2, B1 to B3, C1, E1, F1 | D2, F2, G1 | sees slice 1 in the sandbox; installs and switches for the real node |
| B4, D3, E2, G2 | I1 | each other; slice 3; slice 4 | — |
| I2 | B4, E2 (D3 or the mock) | slice 3, slice 4 | sees the chat |
| B5, F3, D4 | I1 | each other; slice 2; slice 4 | — |
| I3 | B5, F3 (D4 or the mock) | slice 2, slice 4 | answers a scratch lead's question |
| B6 | I1 | slice 2, slice 3 | — |
| D5 | B6 | G3 | the go-ahead to vendor xterm.js (LW-D13): given by the lead, 2026-11-17 |
| G3, I4 | B6, D5 | slice 2, slice 3 | reads the numbers; LW-D12 |
| B7 | B1 | everything | — |

- At most one integration task is open at a time, and nothing else is merged into `v2` while it is.
- A lane rebases on `v2` after each integration task and before its next task.
- Lanes B, D and F each have a task in slices 2 to 4, so those three lanes carry on; A, C, E and G are free after
  slice 1 and take the next slice's tasks in the same files they own.

## Measured

Filled by G1, G2, G3 and B7, each with the date, the commit and the machine's load.

| Measure | Budget | p50 | p95 | Date, commit |
| --- | --- | --- | --- | --- |
| a store's change to its frame | 100 ms at p95 | | | |
| a status change to the list's paint | 100 ms at p95 | | | |
| a click to the visible response | 50 ms | | | |
| first load to a usable list | 500 ms | | | |
| reconnect after a server restart | 2 s | | | |
| a chat of 10,000 rows to first paint | 150 ms | | | |
| a hook's write to the store's change (B7) | none yet | | | |
| a key to its echo | 16 ms median, 33 ms p95 | | | |

## Review Focus

1. **Nothing a token can do changes anything.** Every kind but the read ones and `draft` is refused on a WebSocket,
   before any handler. A draft reaches no lead and no vault. `answer` still needs the user's voice and the card's
   code, and shows the draft whole before the code is asked.
2. **The listener trusts one header value each, exactly.** `Host` and `Origin` are compared whole, never by prefix
   or suffix, never case-folded into a wider match. Nothing is sent before `auth`. The listener is bound to
   `127.0.0.1` and is off until asked.
3. **No test and no agent reaches the user's node.** Test flags are refused under `--node`; no test binds
   `NodeWeb.port`; no agent runs `vibeswitcher web` there.
4. **Order on the wire.** Every delta's `prev` is the `seq` last sent on its subscription; folding never loses an
   entry's latest value; a resume sends exactly what changed since; a new epoch never resumes.
5. **No timer on the path from a store to a frame**, and no fixed sleep in a test.
6. **Nothing an agent wrote is markup**, in the page or on the terminal: every field marked † in the contract is a
   text node in the page and inert on the command line.
7. **The lanes held.** No commit of a lane touches a file outside its row; `WebAssets.generated.swift` is only the
   integrator's.
8. **The Mac still builds and runs what it can.** `Platform.Sockets`' new functions have a Darwin form; the
   listener's and the hub's tests run on both.

## Open, for the lead before agents start

**Answered by the lead, 2026-11-17**, before W0: 1 (the posture decisions accepted as recommended), 3 (xterm.js
vendored for slice 4), 4 (the sandbox), 5 (the client matches on project and question id; the task that touches
`Restarts` checks whether open questions are re-posted), 6 (block by block for now; character streaming deferred) and 7
(the budget counts from the store's change; the cut is a later engine task). 2 was answered by W0: neither branch had a
commit, so this plan's names stand. Each answer is written under its item.

1. **The posture decisions**: LW-D1 (the server binds the port for now), LW-D3 (a first TCP listener, reachable from
   Windows under mirrored networking), LW-D4 (a token's hash at rest), LW-D6 (drafts; no browser answer until signed
   approvals), LW-D12 (the terminal on a scratch node only). **Accepted by the lead, 2026-11-17**, as recommended.
2. **The in-flight branches' names.** `v2-ws` and `v2-web-ui` had no commit when this was written. W0 reads them and
   changes this plan's names to theirs. **W0, 2026-11-17:** neither had a commit (both at `f62aef61`), so this plan's
   names stand.
3. **Vendoring** (LW-D13): slices 1 to 3 need none. Slice 4 needs xterm.js, and the design's Preact spike is not in
   this plan: whether it runs, and when, is the lead's. **The lead, 2026-11-17:** xterm.js is vendored for slice 4 at an
   exact version with its hash, as the design says; it is a file in the repo, not an install.
4. **How the user first sees it**: the sandbox (a scratch node, minutes after I1) or their own node (an install and a
   switch). **The lead, 2026-11-17:** the sandbox script on a scratch node, so the user doesn't wait for an install.
5. **Card ids don't survive a server restart** (the cards are memory, S3). The contract has the client match on the
   project and the question's id. If the lead's tool server doesn't post open questions again after a restart, a
   card vanishes from the page until it does; `Restarts` should be read for that before D2. **The lead, 2026-11-17:**
   the client matches on project and question id, as the contract says; the task that touches `Restarts` checks
   whether open questions are re-posted.
6. **A reply's text doesn't stream today.** The transcript gets a reply a block at a time, so the page shows blocks
   arriving, not letters. Letters need another source (the agent's stream output, or the host's parser), which no
   store has. The wire is ready for it. **The lead, 2026-11-17:** block by block for now; character streaming is
   deferred.
7. **The hook-to-store delay** (LW-D14): up to 0.4 s before the store's change. Cutting it is an engine edit. **The
   lead, 2026-11-17:** the 100 ms budget counts from the store's change; cutting `NodeSessions`' 0.4 s coalescing is a
   later engine task.
8. **WebAuthn and the origin** (LW-D5): signed approvals with a platform authenticator need `localhost`, not
   `127.0.0.1`. Stage 4's design should settle the origin before a user has bookmarked this one for long.
9. **The Chrome and Node 22 on this machine** are assumed by the design for the bench; G1's first step checks both
   and stops with what is missing, installing nothing.

## Changes to the spec

I1 writes these into the design and the security document:

- The server, not the host, binds the loopback port until H1 (the design's "The node's processes" deviation, and
  requirement 4).
- The first frame's authentication is a pairing code or a token, not yet a device key ("The live protocol").
- A web client is a principal of its own: it reads what the uid reads, drafts, and is never the user's voice (the
  security document's principals, and S3's table: `web.open`, `web.revoke`, `draft`, `draft.clear`).
- S11 gains: the port while the server is down; the token's hash in a file the user's processes can write; the page
  reachable from Windows under mirrored networking.
- "A slow client's deltas for one entry are folded into the latest" is kept, and the wire says the range a folded
  delta covers.

## Done when

- Slice 1: `scripts/sandbox-server.sh run` and `url` show the live page; a fake session's status change is on the
  page inside the budget; the server restarted under it, the page is current again inside 2 s with no empty frame;
  `LiveHubTests`, `LiveResumeTests`, `NodeStatusStoreTests`, `WebSocketTests`, `WebListenerTests`, `WebAssetsTests`,
  `WebTokensTests`, `WebSecurityTests`, `WebAppLintTests`, `WireVectorsTests` and `socket.test.mjs` pass, with the
  lints; both jobs green on one commit.
- Slice 2: a scratch session's chat grows on the page; 10,000 rows open and scroll inside their budgets.
- Slice 3: a scratch lead's question is drafted on the page, confirmed with `vibeswitcher answer`, and closes on
  the page.
- Slice 4: the spike's numbers are in [Measured](#measured), and the contract's §9 is final or the emulator is
  refused.
- Every row of [Seamless](#seamless) and [Security](#security) has its test passing or its bench inside its budget.
