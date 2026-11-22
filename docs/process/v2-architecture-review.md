# VibeSwitcher 2: architecture review (2026-11-22)

Three independent reviewers read branch v2 without each other's conclusions, each through one lens: structure;
runtime behaviour; interfaces, trust boundaries and verification. Each verified its claims in the code. This is their
combined result, ranked, with what is done about each. The Mac app (`Sources/VibeSwitcher`) was out of scope.

## Verdict

The design between processes is sound: host, server, command line and page depend in one direction, the platform
layer is enforced by a lint, the engine runs on one serial queue with no nested locks, output has back-pressure end
to end, and the security rules are mostly built as written. No reviewer found a design error or a way past a rule.

The weaknesses are inside the server module and at the edges a long-running daemon reaches:

1. What a request kind needs is spread over parallel hand-kept lists, two of which fail open.
2. Two objects (`LeadEngine`, `Requests`) hold every feature's state, so every feature edits the same files.
3. Several runtime edges can end or freeze the node: a failed log write, a hang nothing acts on, an unbounded socket.
4. The branch is rarely green, and parts of the product have no test in CI.

## What to keep

- The target graph: `VibeNode` never imports `VibeHost`; it reaches the host only through the link.
- The platform facade (`Platform.X`, one file per system) and its lint.
- One composition root (`ServerStart`), one serial queue per process, blocking work on named side queues.
- The live pipeline: changes folded per subscriber, a slow client costs nothing.
- The host's authorization: a typed request, a typed caller, one exhaustive switch.
- Fail-closed defaults: an unknown kind needs the user's voice and counts as state-changing.
- The vault record before every act, with idempotent retries.
- Lints as architecture tests, each with a fixture proving it fires.
- The install gate, the pinned workflow actions, the scratch-home test runner.

## Findings, ranked

Size: S under a day, M a few days, L more. "Both" marks a finding two reviewers reached independently.

| # | Finding | Why it matters | Size | Plan |
|---|---|---|---|---|
| 1 | A request kind is declared in 8 to 12 places (`NodeWire.kinds`, `changesNothing`, `taken`, `Requests.recorded`, `carded`, the `act` switch, the approval tables, the hub's list, the CLI). `recorded` and `carded` are opt-in. (Both) | A new state-changing kind left out of `recorded` would act without the vault's record, and no test catches it. These are also the branch's most-edited files, so parallel work conflicts there. All 63 kinds are consistent today. | S then M | Now: a completeness test. Then one `KindSpec` table and a `Principal` value resolved once per connection, shared by both transports. |
| 2 | A failed log write traps the process (`FileHandle.standardError.write` on Linux; reproduced with `/dev/full`). The detached `host.log` is never rotated. | A full disk ends the server, then the host, then every session. | S | Now: a raw-write helper, a lint, rotation. |
| 3 | Hangs are measured, never acted on. The host restarts the server only when it exits. | A stuck server stays stuck until the user restarts the node, which ends every session though none was at risk. | S | Now: the watchdog exits the server after a long stall (the host restarts it in 1 s, sessions survive); the `reads` lane is watched too. |
| 4 | The server's Unix socket has no connection cap, pending cap or per-turn read cap; the host and web listeners have them. | Any process of the user can starve the engine queue or grow its memory. | S | Now. Done (runtime hardening, 2026-11-22): 8 connections a process, 16 a share (session, else systemd cgroup, else pid), 64 in all with 8 kept for a peer that may be the user's voice, every descriptor counted, a closing one closed within 2 s; a connection with no request 30 s after its hello, or no request and no subscription for 10 minutes, closed; 8 MiB pending, 32 requests and 16 reads a turn, the /proc reads capped, accepts paused on EMFILE. Accepted residual: outside sessions and systemd cgroups a share is one pid, so a forking process can take every slot not kept for the user and keep the leads' tool servers out (the user's 8 stay); a denial among the user's own processes, which can already end the server; eviction was tried and removed, as gameable. |
| 5 | The typed code and the journal entry are a per-command convention in the CLI (16 sites; the flow is copied 11 times). (Both) | A new command could send a state change with no prompt and no journal mark. The server still checks the terminal. | S | Now: one `NodeClient.change` that takes a token only the typed-word prompt can make, and writes the journal itself. |
| 6 | 46 elapsed-time guards use the wall clock. | This machine's clock steps by up to 7 s; a 10 s typing guard can shrink to 3 s. | S–M | Now: awake time for every interval, and a lint. |
| 7 | The branch is rarely green: 7 of the last 46 pushed commits passed both gating workflows; each push cancels the run before it. | Few commits are installable, and a run of cancelled commits hides which merge broke the branch. | S | Now: the lint suites and the workflow check run before every push; pushes are batched; runs are no longer cancelled. |
| 8 | `LeadEngine` holds about 150 stored properties for some 20 features across 23 extension files; `Requests` is the same shape with 25. (Both name the cost.) | Extensions separate files but hide nothing; invariants live in 208 "on the queue" comments. | M per batch | After the feature lanes land: extract the leaf watches (toolchain, prompt audit, push asks, popups, all-done, session reopen) into types that own their state. |
| 9 | A card kind is hand-wired like a request kind (shell touched 12 Swift files and 5 page files). | Every new ask repeats it. | M | Under way: the feature plugin registry (`2026-11-22-v2-feature-plugins.md`). |
| 10 | After a server crash mid-action the outcome is unknown, and a retry is told "done already" whether or not it was. | The user can't tell whether an answer reached the lead. | S then M | Now: the honest wording and the action id shown. Then: completion recorded in the vault. |
| 11 | The wire has a second schema: payloads are hand-built dictionaries (214 literals), the CLI reads replies by string key 301 times, and only 23 of 63 kinds have a schema. Nothing tests a new CLI against an older server. | A renamed field fails silently at runtime; right after a switch the CLI and server are different builds. | S then L | Now: unknown arguments refused on state-changing kinds, a build-mismatch warning, frozen previous-build vectors. Later: typed arguments and results per kind. |
| 12 | The page's DOM code (about 4,800 lines of views) has no test in CI. The mock ships in the production page and takes 67 KB of a 1 MiB budget that is 95% spent. | A view can break unseen; the budget blocks the next feature. | S, M | Now: the mock out of the embed. Then: the headless Chrome check in the Linux job. |
| 13 | The chat store reads a whole transcript into memory and does a full pass on the engine queue per appended line. | A long lead transcript with screenshots costs hundreds of MB and slows every request. Read from the code, not measured. | M | After the "now" batch: a tail window, older ranges on demand. |
| 14 | Snapshot size is bounded by count with headroom, not by construction (the 1.4 MB cards incident's class). | Three leads' boards can pass 1 MiB on the Unix socket. | S, M | Now: closed cards pruned by bytes. Then: snapshots in parts. |
| 15 | There is no current description of how V2 works; the truth is spread over a 2,500-line security spec, an 800-line design that names things never built, and the plans. | A new contributor, or a new session, can't trust one page. | S | Now: `docs/guide/v2-architecture.md`, with the kinds table generated from code. |
| 16 | VibeNode's folders aren't layers (cycles through misplaced base types: `NodeWire` lives in `Server/`). | Nothing stops reach-through. | S | After the feature lanes land (it moves files): a base folder and a folder-dependency lint. |
| 17 | Files copied from the Mac app are kept in step by hand; two `FakeClaude` copies drift; five `TestSupport` copies. | The fakes model the product's core dependency. | S, M | Now: a lint that diffs each verbatim copy against its original. Later: one test-support target. |
| 18 | Thread confinement is by comment; no sanitizer run. No race was found. | The "under load" flakes are the kind this hides. | S–M | A nightly thread-sanitizer run of the node's tests. |
| 19 | Smaller: disk reads on the engine queue in `status`; handover cost scales with total scrollback (about 160 MB for 20 busy sessions); the hand-rolled HTTP and WebSocket parsers have no fuzz tests; 13 `--test-*` flags ship in the release server (refused at runtime on the user's node); "Mac" names on Linux code. | | S each, one M | In the batches above where they fit. |

## Order of work

1. **Runtime hardening** (2, 3, 4, 6, 10's first part, 14's first part, 19's status cache): one lane, mostly its own files.
2. **One path for authority** (1's test, 5, 11's first part, 12's first part, 15, 17's lint): one lane.
3. **The plugin registry** (9), then the `KindSpec` table (1) on top of it, since a plugin's actions are kinds.
4. **The engine split and the folder layers** (8, 16), once the feature lanes have merged, because they move code
   everyone is editing.
5. **Typed wire, the chat store's window, snapshots in parts, the page in CI** (11, 13, 14, 12).
