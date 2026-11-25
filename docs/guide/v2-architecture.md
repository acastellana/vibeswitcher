# VibeSwitcher 2: how it works

One current page for V2, the Linux node (branch `v2`), describing the code as it is; the kinds table at the end is
generated from the code (a lint fails when it goes stale). Why each rule exists: the [security architecture](../superpowers/specs/2026-11-13-v2-security-architecture.md)
(its S-numbers below); what is wrong and the order of work: the [architecture review](../process/v2-architecture-review.md); [Try it](v2-try-it.md).

## The processes, and who starts whom

| Process | Started by | What it does |
| --- | --- | --- |
| `vibeswitcher` (the command line) | the user, in a terminal | Reads (`status`, `board`, `questions`), and state changes after a typed code. One connection to the server per command. |
| `vibeswitcher-host` (the session host) | `vibeswitcher start`: a systemd user unit, or, with no systemd, a detached host with a record and a lock (`StartSequence`, `NodeStarter`) | Holds every session's pseudo-terminal and scrollback, and the vault. Answers on its own socket, and authorizes each request by the caller it sees (`HostServer.authorized`). Updates itself in place (`HostHandover`): the sessions survive. |
| `vibeswitcher-server` (the server) | the host, from a sealed copy of the build's server, through an inherited connector (`ServerChild`). When it ends, the host starts it again after 1 s, doubling up to 30 s. | Runs the engine (leads, cards, boards, the live streams) on one serial queue. Answers on `~/.vibeswitcher/v2/server.sock` and on the web listener. Through its connector it is "the app" to the host. A watchdog thread ends it when the engine's queue hasn't answered for 120 s awake, and the host starts it again with the sessions kept. |
| Sessions (Claude Code, Codex, a shell) | the host, at the server's request (`session.new`, a lead's start) or a lead's (its workers and verifiers) | Your agents. Each is a process of your uid on a host pty. |
| `vibeswitcher-mcp` (a lead's tool server) | the lead's Claude Code, from `<build>/bin/vibeswitcher-mcp` named in the config the engine writes (`LeadStart`) | The lead's tools: workers, merges, questions to you. The host seals what it posts as the lead's (EN-D10). |
| A plugin's program | the server, for an external plugin that is on, from a sealed copy (`PluginProcess`) | Answers the node's calls (protocol v1). It acts on nothing itself. |
| `vibeswitcher-hook` | Claude Code and Codex, from the hooks `vibeswitcher hooks install` writes | Tells the node a session's status (working, needs you, done). |
| The page (`WebApp/`) | a browser, at the address `vibeswitcher web` prints (loopback; `--tailnet` for the phone, port 47830) | Shows the node live and leaves drafts. The server holds the page's files (`WebAssets.generated.swift`). |

Dependencies go one way: `VibeNode` (the server's and the command line's code) never imports `VibeHost`. It reaches the
host only through `HostLink`. Every system call goes through `VibePlatform` (`Platform.X`), as PlatformLint enforces.

## The principals, and what each may do

| Principal | Known by | May |
| --- | --- | --- |
| The user's terminal | A peer of the uid that passes `Voice.judge`: its cgroup in one of the login's terminal scopes (systemd rule), no live session's program in its ancestry, a controlling terminal that is no session's, no `VIBESWITCHER_SESSION`, not under a branch runner. Under the weaker rule (no systemd) it also needs a controlling terminal. | Every kind. A state change also needs the code typed on `/dev/tty`. The vault records it first, and it leaves a journal entry. |
| A session (any process of the uid that isn't the user's) | Everything else on the Unix socket | The reads the table marks "anyone of the uid". With the host: its own children; a lead also its team. |
| A lead's tool server | The host's seal on its post, bound to the lead's role in the vault | `question.post`, `question.revise`, `question.withdraw`: questions on cards, never answers. |
| A page | A token the host's vault knows, from `vibeswitcher web`'s pairing; on loopback, its pairing confirmed in that terminal by its phrase, and a pairing secret held in the page's memory (12 hours at most) | Reads and drafts. Confirmed: watches the terminals, and, as `web_acts` allows (`off`, `confirm`, `trust`), sends the user's kinds the table marks for a page, recorded as the user's and marked as the page's (`pageVoiced`). A tailnet page only reads and drafts. |
| The host | Its own socket; the server is "the app" through its connector | Sessions, the vault, handover. Only the app may shut the host down, hand over, or use the server's vault record. |

A kind missing from the table needs the user's voice and counts as a state change: a later kind fails closed. Under the
Mac's rule Touch ID or the login password stands for the typed code; under the closed rule, no peer is the user's.

## A request's path

On the command line, `TypedWord.said` shows what the request will do and asks for its code. Only that prompt makes
the `Typed` token. `NodeClient.change`, the one way the command line sends a state change, takes the token, sends the
request with a new action id, and writes the journal entry once the server has accepted it. `NodeClient.request`
refuses a state-changing kind (CLIChangeLint).

On the server:

1. **Envelope** (`NodeWire.unwrap`, the same on both transports). The message must be a JSON object, a request
   (`v`, `id`, `kind`), at no newer a version. Otherwise the connection gets a `bye` with its code. A kind the server
   doesn't take is answered `unknown-kind`; with `must`, the connection ends.
2. **Transport** (`Principal.route`). On the Unix socket, the hub's kinds go to the hub, the rest to `Requests.handle`
   with the peer's facts. On a WebSocket (`WebRequestScreen`): drafts to `draft`, private reads to `webRead`, an acting
   page's user's kinds to `pageVoiced`, anything else to `Requests.handle` as `webPeer`, which is never the user's.
3. **Voice** (`Requests.handle`). The kind's voice decides: the tool server's posts go to `questionPost` (host-sealed);
   the user's kinds pass `Voice.judge`, then, for a state change, the hands check (`Voice.handsRefusal`).
4. **Checks** (`Requests.voiced`). An action this server has answered, or is doing now, is answered so first (its
   kept reply, or `beingDoneNow`). A recorded kind needs an action id (a UUID). Every argument must be one the kind
   takes (`RequestArguments`). The node must not be stopping, and the host link must be welcomed. A card's kind needs
   its code; `approve` needs its batch.
5. **Vault record** (`LeadVaultV2.recordUserAction`, in the host). If the vault doesn't take it, the action isn't done.
   An action it holds already from an earlier server (a retry, `Requests.retry`), asked with the arguments it was
   recorded with (other arguments get nothing), is answered from its record's outcome (done: the recorded result when its kind keeps one, a kind's
   `Requests.retryRules` saying whether its result holds no secret; failed: why, and whether running the command again
   can do it); a record begun with no outcome (the server ended in between) is done again only for a kind whose rule
   says a second act leaves things as one does, and only when nothing recorded since names the same subject; otherwise
   it is told it began, that its outcome isn't known, and what to look at.
6. **Act** (`Requests.act` and the feature's file). Its outcome goes on the vault's record (`finishUserAction`, through
   the host) before the reply, which is also kept for retries.

RequestKindsLint holds the lists a kind appears in to one another: `NodeWire.kinds`, `changesNothing`, `taken`,
`Requests.recorded`, `carded`, `RequestArguments`, `Requests.retryRules`, the `act` switch and the hub's kinds.

**Typed kinds.** Every kind the command line sends is a `WireKind` (`Live/Wire/`): its `Args` and `Result`, Codable,
shared by both sides. The server decodes the arguments (`Request.typedArgs`: a wrong form is `bad-args` naming the
field) and replies with the typed result, read by `NodeClient.read` and `change`. The command line says once when the
server is another build; the previous build's vectors stay in `Tests/Fixtures/wire/`. Snapshots' entities aren't typed.

**The command line's resend** (`NodeClient.send`). A request the server didn't take (its idle bye,
`NodeServer.tookNoRequest`, or a failed write) goes again on a fresh connection, up to 3 times. One lost after it went
goes once more with its action id, for a recorded kind or a read, only when the fresh hello names the same session host
(`sameHost`: its start and pid, kept by a build switch's handover): another host has no record and would act twice.
Otherwise its outcome isn't known, said and journaled `unanswered`. A lost one-time link or page address is cancelled.

## The server's socket and its limits

`NodeServer` bounds the Unix socket: 64 connections, 8 of them kept for a peer that may be the user's voice; 8 a
process; 16 a share that isn't the user's (a session by ancestry, else a systemd cgroup, else a pid). A newcomer past
one gets a `busy` bye saying why; nothing open is closed for it. No request 30 s after the hello, or no request and no
subscription for 10 minutes, closes a connection with a `busy` bye (`Idle`). 8 MiB may wait to be written to one; a
turn of the queue takes 32 requests and 16 reads a connection and 64 accepts; an accept short of descriptors pauses 1 s.

## The live streams and the chat window

Each collection (sessions, cards, leads, the node, boards, chats) is a `LiveStream` on the engine's queue; the hub
folds changes per subscriber. A snapshot fits a line by construction: closed cards pruned by count and by bytes
(384 KiB), and one still past `NodeWire.maxLine` leaves entries out and says `truncated` (`LiveHub.fitted`). A client
that subscribes with `parts: true`, as the page does, gets snapshots in parts of at most 256 KiB (`LiveHub.parted`),
written back to back, `final` on the last; the page reconciles once, on `final`. An entry larger than a part is
withheld whole, named in `withheld` with a stub where it has one (a card's says `vibeswitcher questions`). Only boards'
notes are cut. The chat store (`ChatStore`, `TranscriptFollow`) keeps a tail window of each followed chat, 600 items or
24 MB of lines; an append is a change at the tail; older pages are read from the file (`chat.page`).

## The engine and its watches

The engine's leaf features are watches, each a final class that owns its state on the engine's queue and is given its
queue, files, notes and clock, never the engine: ToolchainWatch, PromptAuditWatch, PushWatch, PopupWatch,
AllDoneWatch, OpenSessionsWatch, ShellTidyWatch, BoostWatch, RoomWatch, `PluginRuntime`. One that calls back holds a
narrow protocol weakly (`PushLeads`, `RoomLeads`, `PluginHost`, ...); `EngineWatch.assertOn(queue)` checks the queue in
debug builds. The cards and answers core, the vault link, restart and resume, and `Requests` stay the engine's.

**File watches.** On Linux each process's `FolderWatch`es and `FileWatch`es share one inotify instance (`InotifyHub`;
a user has 128), one kernel watch an inode; an overflow makes each client read again. A watch the system can't give is
counted (`Platform.Watches`), logged once, shown by `status --health`, and its owner looks at housekeeping instead.

## Feature plugins

A feature's card is a plugin's (`Plugins/`, the [definition](../superpowers/specs/2026-11-22-v2-feature-plugins.md)).
Which are on is in the vault, mirrored in `<root>/plugins.json` for agents' commands; `plugin on|off` replies once the
mirror and wrappers are written. Off leaves no trace: the folder emptied unread, open cards withdrawn, askers told. A
card is data (`PluginCard`), drawn after the core's checks by generic renderers. A plugin reaches the engine only
through its `PluginDesk`: requests the host stamped for a live session the user opened, its cards, sessions, telling an
asker, the clock. Shell requests (`vs-shell`) are the one built-in plugin.

An external plugin is a program with a manifest (`vibeswitcher-plugin.json`) in its own repository, the wallet first.
`plugin add FOLDER` shows what the server read and, after the typed code, records the manifest's and program's SHA-256
and the program's size; it starts off. `plugin remove` withdraws its cards, stops it and drops the record.
- **Process** (`PluginProcess`): a sealed copy checked against the record, spawned through `setpriv --pdeathsig KILL`
  by a long-lived thread, in its own cgroup when the server's is writable; no terminal, in `/`, `HOME=/nonexistent`, an
  environment built from nothing, `VIBESWITCHER_PLUGIN_DATA` only with `data: true`.
- **Checks** (`PluginFiles`, at the add and every start): 64 MiB at most; an ELF's interpreter, RUNPATH, RPATH and
  path-named libraries root's all the way, no `$ORIGIN`, audit library, filter or loader config; a script's `#!` one
  of a few root-owned interpreters, at most one flag token.
- **Protocol v1**: a JSON object a line, 256 KiB at most; the node asks (`hello`, `file`, `card`, `perform`,
  `page.answer`, `settings.check`, `withdrawn`), the plugin answers. 10 s unanswered or an answer out of shape ends the
  program and withdraws its cards; `plugin list` says why.
- **Filing**: `vs-<name>` (a wrapper in `<root>/plugins/bin`, last on Linux sessions' PATH) runs `vs-ask <id> --`,
  which sends `plugin.file`: only from a live session the user opened, 4 waiting at most, then busy.
- **Page** (`PluginPage`): `perform` may answer a page, served once by the core on 127.0.0.1 with an HttpOnly
  SameSite=Strict cookie, one answer at a time, its address only in the answering terminal's reply.

## What is kept where, and what survives a restart

| Store | Holds | Survives |
| --- | --- | --- |
| The host's memory | Sessions (ptys, scrollback, input not yet written); the vault (roles, seals, the record of the user's actions with their outcomes, the plugins on and added). The vault has a sealed copy on disk only the host reads. | A server restart. A host handover: the host re-executes itself in place, with a state file and a secret channel. A host stop or crash ends the sessions. |
| The server's memory | Cards (never read back from a file the team can write), the live streams, the chat store, leads' state | Nothing: a restarted server rebuilds them from the host, the vault and the projects. |
| `~/.vibeswitcher/v2/` | `server.sock`; `engine.json` (held messages, the witness's keys, the last host start); `held-sends.json`; `accepted.json`; `builds/<commit>` and `builds/current`; `plugins.json`, `plugins/bin`, `plugins/<id>/data`, `shell-requests/`, `plugin-requests/<id>/`; `host.log`, `node.pid` (a detached host) | Everything, but a worker of your uid can write these files. A held `.user` message goes out as yours after a restart only if the vault vouches for its action and digest. |
| `~/.vibeswitcher/` | Small records: settings, session marks, health, account usage, the update check, presets | Everything. |
| Each project | `.vibeswitcher/board.json`, `workflow.md`, the lead's records (`docs/lead/`) | Everything. The team writes them, so nothing there counts as yours: guard rails go through the vault. |
| The journal (systemd) | The command line's entries: start, stop, each accepted request, acknowledgements (`NodeJournal`) | Everything. `status` marks a start or stop that no entry explains. |

## The tests, and how to run each

| Tier | What | Run |
| --- | --- | --- |
| Lints | Architecture as tests (each `…LintTests`, each with a fixture that proves it fires) | `bash scripts/test.sh --filter 'LintTests/'` (seconds; before reporting done) |
| Focused | One suite on a scratch home. In-process: `NodeTestHost`, `CardWorld`. Process-started: `ScratchNode` (the built host, server and command line), with `FakeClaude`'s fake agents on fake ttys | `bash scripts/test.sh --filter SuiteName` |
| Web | The page's Node tests (`WebApp/tests/*.test.mjs`) and the phone's (`Tests/Web`); `scripts/test.sh` runs them after Swift | `node --test WebApp/tests/*.test.mjs` |
| Under load | New or changed tests, three runs at twice the cores | `Resources/bin/vs-heavy scripts/test-under-load.sh --load 24 -r 3 -f 'Suites'` |
| Full suite | Everything (only when asked) | `vs-heavy bash scripts/test.sh` |
| Benches | Speed and memory, `.perf` tests | `bash scripts/test.sh --perf` (a calm machine) |
| Real agents | `RealClaude*Tests`: spends Claude usage | Set `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`, then a focused run |
| End to end | A real node's acceptance, the page in a real browser, the wallet passage | `scripts/e2e/node-acceptance.sh`, `real-page-check.sh`, `wallet-e2e.sh` |
| CI | `v2 linux` (Ubuntu: the platform, core and node, and host suites, the page in headless Chrome); `v2 macos` and `v2 macos install` (Xcode); nightly, `v2 tsan` (the thread sanitizer) and `v2 host probe` (fresh scratch nodes, the parsers fuzzed long) | On push, and nightly; `scripts/ci/check-workflows.sh` checks the workflows; `bash scripts/test.sh --tsan` runs the sanitizer here |

## The request kinds

Generated from the code (`KindsTable`). After changing a kind, run
`.build/debug/vibeswitcher-cli kinds-doc --write docs/guide/v2-architecture.md`. "Recorded first" means the vault
records the action before it is done. "Card code" means the card's code is checked. A kind marked "a page only" isn't
taken on the Unix socket.

<!-- kinds-table: generated by `vibeswitcher kinds-doc --write docs/guide/v2-architecture.md`; don't edit -->
| Kind | Who may send it | Changes state | Recorded first | Card code | Handled by | Arguments (state changes) | Typed | A retry | In approve's batch | From an acting page |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `answer` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code`, `text`, `version` | `WireKinds.Answer` | its result |  | yes |
| `answer.replace` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code`, `text`, `version` | `WireKinds.AnswerReplace` | its result |  | yes |
| `approve` | the user's terminal | yes | yes |  | `Requests.act` | `batch`, `code` | `WireKinds.Approve` | its result |  | yes |
| `approve.list` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.ApproveList` |  |  | yes |
| `base.accept` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.BaseAccept` | its result | yes | yes |
| `base.keep` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.BaseKeep` | its result |  | yes |
| `base.show` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.BaseShow` |  |  | yes |
| `board` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Board` |  |  |  |
| `board.image` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `board.task` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `brief` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | `WireKinds.Brief` |  |  |  |
| `build.seal` | the user's terminal | yes | yes |  | `Requests.act` | `commit`, `from`, `switchAction` | `WireKinds.BuildSeal` | its result |  | the terminal's alone |
| `build.switch` | the user's terminal | yes | yes |  | `Requests.act` | `buildsAfter`, `buildsBeforeListing`, `commit` | `WireKinds.BuildSwitch` | its result |  | the terminal's alone |
| `chat.image` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |  |
| `chat.page` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |  |
| `config.accept` | the user's terminal | yes | yes | yes | `Requests.act` | `batch`, `card`, `code` | `WireKinds.ConfigAccept` | its result | yes | yes |
| `config.held` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.ConfigHeld` |  |  | yes |
| `draft` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |  |
| `draft.clear` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |  |
| `hold` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.Hold` | its result |  | yes |
| `hooks.install` | the user's terminal | yes | yes |  | `Requests.act` | `agents`, `codex` | `WireKinds.HooksInstall` | its result; done again | yes | the terminal's alone |
| `hooks.remove` | the user's terminal | yes | yes |  | `Requests.act` | `agents` | `WireKinds.HooksRemove` | its result; done again |  | yes |
| `lead` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `goal`, `initialized`, `replace`, `resume`, `takeHead` | `WireKinds.Lead` | its result |  | yes |
| `mail` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | `WireKinds.Mail` |  |  |  |
| `plugin.add` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `manifest`, `program` | not yet | its result |  | the terminal's alone |
| `plugin.file` | anyone of the uid |  |  |  | `Requests.act` |  | not yet |  |  |  |
| `plugin.inspect` | the user's terminal |  |  |  | `Requests.act` |  | not yet |  |  | the terminal's alone |
| `plugin.list` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.PluginList` |  |  |  |
| `plugin.off` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | `WireKinds.PluginOff` | its result; done again |  | yes |
| `plugin.on` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | `WireKinds.PluginOn` | its result; done again |  | yes |
| `plugin.remove` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | not yet | its result; done again |  | yes |
| `presets.edit` | the user's terminal | yes | yes |  | `Requests.act` | `args`, `default`, `digest`, `env`, `folder`, `keepShell`, `kind`, `name`, `op`, `rename`, `unset` | `WireKinds.PresetsEdit` | its result |  | yes |
| `prompt-audit` | the user's terminal | yes | yes |  | `Requests.act` | `do`, `folder` | `WireKinds.PromptAudit` | its result; done again |  | yes |
| `push` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `request` | `WireKinds.Push` | its result |  | yes |
| `push.decline` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `request` | `WireKinds.PushDecline` | its result; done again |  | yes |
| `question.post` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |  |
| `question.revise` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |  |
| `question.withdraw` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |  |
| `questions` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Questions` |  |  |  |
| `recent` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `seen` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `send` | the user's terminal | yes | yes |  | `Requests.act` | `images`, `now`, `session`, `text`, `when` | `WireKinds.Send` | its result |  | yes |
| `session.attach` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |  |
| `session.close-shells` | the user's terminal | yes | yes |  | `Requests.act` | `sessions` | `WireKinds.CloseShells` | its result; done again |  | yes |
| `session.complete` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `session.draft` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |  |
| `session.draft.clear` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |  |
| `session.end` | the user's terminal | yes | yes |  | `Requests.act` | `session` | `WireKinds.SessionEnd` | its result; done again |  | yes |
| `session.new` | the user's terminal | yes | yes |  | `Requests.act` | `agent`, `digest`, `folder`, `model`, `preset` | `WireKinds.SessionNew` | its result |  | yes |
| `session.pause` | the user's terminal | yes | yes |  | `Requests.act` | `for`, `hours`, `session` | `WireKinds.SessionPause` | its result; done again |  | yes |
| `session.ports` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |  |
| `session.presets` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Presets` |  |  |  |
| `session.rename` | the user's terminal | yes | yes |  | `Requests.act` | `name`, `session` | `WireKinds.SessionRename` | its result; done again |  | yes |
| `session.reopen` | the user's terminal | yes | yes |  | `Requests.act` | `all`, `forget`, `sessions` | `WireKinds.SessionReopen` | its result |  | yes |
| `session.reply` | the user's terminal | yes | yes |  | `Requests.act` | `choice`, `options`, `question`, `session`, `text` | `WireKinds.SessionReply` | its result |  | yes |
| `session.resume` | the user's terminal | yes | yes |  | `Requests.act` | `session` | `WireKinds.SessionResume` | its result; done again |  | yes |
| `session.usage` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |  |
| `set` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `key`, `value` | `WireKinds.SetSetting` | its result; done again |  | yes |
| `settings` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Settings` |  |  |  |
| `shells` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.Shells` |  |  | yes |
| `start` | the user's terminal |  | yes |  | `Requests.act` | none | `WireKinds.Start` | its result; done again |  | the terminal's alone |
| `stats` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Stats` |  |  |  |
| `status` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Status` |  |  |  |
| `stop` | the user's terminal | yes | yes |  | `Requests.act` | none | `WireKinds.Stop` | its result |  | yes |
| `subscribe` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |  |
| `tell` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `text` | `WireKinds.Tell` | its result |  | yes |
| `tell.retract` | the user's terminal | yes | yes |  | `Requests.act` | `action` | `WireKinds.TellRetract` | its result |  | yes |
| `term.close` | a page's terminal (a page only) | yes |  |  | the terminal relay |  | the page's (WireSchema) |  |  |  |
| `term.open` | a page's terminal (a page only) | yes |  |  | the terminal relay |  | the page's (WireSchema) |  |  |  |
| `unsubscribe` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |  |
| `update.check` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.UpdateCheck` |  |  | yes |
| `web.confirm` | the user's terminal | yes | yes |  | `Requests.act` | `code`, `phrase` | `WireKinds.WebConfirm` | its result |  | the terminal's alone |
| `web.open` | the user's terminal | yes | yes |  | `Requests.act` | `tailnet` | `WireKinds.WebOpen` | done, no result |  | the terminal's alone |
| `web.pairing` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.WebPairing` |  |  | the terminal's alone |
| `web.revoke` | the user's terminal | yes | yes |  | `Requests.act` | none | `WireKinds.WebRevoke` | its result; done again |  | yes |
<!-- kinds-table end -->
