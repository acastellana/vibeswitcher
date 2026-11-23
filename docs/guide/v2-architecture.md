# VibeSwitcher 2: how it works

One current page for V2, the Linux node (branch `v2`). It describes the code as it is. The kinds table at the end is
generated from the code, and a lint fails when it goes stale. For why each rule exists, see the
[security architecture](../superpowers/specs/2026-11-13-v2-security-architecture.md) (its S-numbers are cited below).
For what is wrong today and the order of work, see the [architecture review](../process/v2-architecture-review.md).
To try the node, see [Try it](v2-try-it.md).

## The processes, and who starts whom

| Process | Started by | What it does |
| --- | --- | --- |
| `vibeswitcher` (the command line) | the user, in a terminal | Reads (`status`, `board`, `questions`), and state changes after a typed code. One connection to the server per command. |
| `vibeswitcher-host` (the session host) | `vibeswitcher start`: a systemd user unit, or, with no systemd, a detached host with a record and a lock (`StartSequence`, `NodeStarter`) | Holds every session's pseudo-terminal and scrollback, and the vault. Answers on its own socket, and authorizes each request by the caller it sees (`HostServer.authorized`). Updates itself in place (`HostHandover`): the sessions survive. |
| `vibeswitcher-server` (the server) | the host, from a sealed copy of the build's server, through an inherited connector (`ServerChild`). When it ends, the host starts it again after 1 s, doubling up to 30 s. | Runs the engine (leads, cards, boards, the live streams) on one serial queue. Answers on `~/.vibeswitcher/v2/server.sock` and on the web listener. Through its connector it is "the app" to the host. |
| Sessions (Claude Code, Codex, a shell) | the host, at the server's request (`session.new`, a lead's start) or a lead's (its workers and verifiers) | Your agents. Each is a process of your uid on a host pty. |
| `vibeswitcher-mcp` (a lead's tool server) | the lead's Claude Code, from `<build>/bin/vibeswitcher-mcp` named in the config the engine writes (`LeadStart`) | The lead's tools: workers, merges, questions to you. The host seals what it posts as the lead's (EN-D10). |
| `vibeswitcher-hook` | Claude Code and Codex, from the hooks `vibeswitcher hooks install` writes | Tells the node a session's status (working, needs you, done). |
| The page (`WebApp/`) | a browser, at the address `vibeswitcher web` prints (loopback; `--tailnet` for the phone, port 47830) | Shows the node live and leaves drafts. The server holds the page's files (`WebAssets.generated.swift`). |

Dependencies go one way: `VibeNode` (the server's and the command line's code) never imports `VibeHost`. It reaches
the host only through `HostLink`. Every system call goes through `VibePlatform` (`Platform.X`), and PlatformLint
enforces that.

## The principals, and what each may do

| Principal | Known by | May |
| --- | --- | --- |
| The user's terminal | A peer of the uid that passes `Voice.judge`: its cgroup in one of the login's terminal scopes (systemd rule), no live session's program in its ancestry, a controlling terminal that is no session's, no `VIBESWITCHER_SESSION`, not under a branch runner. Under the weaker rule (no systemd) it also needs a controlling terminal. | Every kind. A state change also needs the code typed on `/dev/tty`. The vault records it first, and it leaves a journal entry. |
| A session (any process of the uid that isn't the user's) | Everything else on the Unix socket | The reads the table marks "anyone of the uid". With the host: its own children; a lead also its team. |
| A lead's tool server | The host's seal on its post, bound to the lead's role in the vault | `question.post`, `question.revise`, `question.withdraw`: questions on cards, never answers. |
| A page | A token from `vibeswitcher web`'s pairing, with rights `read`, `draft` and, on the user's node, a terminal to watch | Reads, and drafts (an answer, a message). Never the user's voice: the user acts on a draft with the line the page shows, in a terminal (S7). |
| The host | Its own socket; the server is "the app" through its connector | Sessions, the vault, handover. Only the app may shut the host down, hand over, or use the server's vault record. |

A kind missing from `NodeWire.kinds` needs the user's voice and counts as a state change, so a kind added later fails
closed. Under the Mac's rule (`VoiceRule.Mode.approval`), Touch ID or the login password takes the typed code's
place. Under the closed rule (the server couldn't read its own cgroup), no peer is the user's.

## A request's path

On the command line, `TypedWord.said` shows what the request will do and asks for its code. Only that prompt makes
the `Typed` token. `NodeClient.change`, the one way the command line sends a state change, takes the token, sends the
request with a new action id, and writes the journal entry once the server has accepted it. `NodeClient.request`
refuses a state-changing kind (CLIChangeLint).

On the server:

1. **Envelope** (`NodeWire.unwrap`, the same on both transports). The message must be a JSON object, a request
   (`v`, `id`, `kind`), at no newer a version. Otherwise the connection gets a `bye` with its code. A kind the server
   doesn't take is answered `unknown-kind`; with `must`, the connection ends.
2. **Transport**. On the Unix socket, `LiveHub.kinds` go to the hub; the rest go to `Requests.handle` with the
   peer's facts (`PeerFacts`, read from the kernel). On a WebSocket, the token's rights are checked first
   (`WebRequestScreen`). Drafts go to `draft`, private reads to `webRead`, anything else to `Requests.handle` as
   `webPeer`, which is never the user's.
3. **Voice** (`Requests.handle`). The kind's voice decides: the tool server's posts go to `questionPost` (host-sealed);
   the user's kinds pass `Voice.judge`, then, for a state change, the hands check (`Voice.handsRefusal`).
4. **Checks** (`Requests.voiced`). A recorded kind needs an action id (a UUID). Every argument must be one the kind
   takes (`RequestArguments`). The node must not be stopping, and the host link must be welcomed. A card's kind needs
   its code; `approve` needs its batch.
5. **Vault record** (`LeadVaultV2.recordUserAction`, in the host). If the vault doesn't take it, the action isn't done.
   An action it holds already (a retry, `Requests.retry`) gets the reply this server kept; else, asked with the
   arguments it was recorded with, its record's outcome (done: the recorded result when its kind keeps one, a kind's
   `Requests.retryRules` saying whether its result holds no secret; failed: why, and whether running the command again
   can do it); a record begun with no outcome (the server ended in between) is done again only for a kind whose rule
   says a second act leaves things as one does, and only when nothing recorded since names the same subject; otherwise
   it is told it began, that its outcome isn't known, and what to look at.
6. **Act** (`Requests.act` and the feature's file). Its outcome goes on the vault's record (`finishUserAction`, through
   the host) before the reply, which is also kept for retries.

RequestKindsLint holds the lists a kind appears in to one another: `NodeWire.kinds`, `changesNothing`, `taken`,
`Requests.recorded`, `carded`, `RequestArguments`, the `act` switch and the hub's kinds.

## What is kept where, and what survives a restart

| Store | Holds | Survives |
| --- | --- | --- |
| The host's memory | Sessions (ptys, scrollback, input not yet written); the vault (roles, seals, the record of the user's actions). The vault has a sealed copy on disk only the host reads. | A server restart. A host handover: the host re-executes itself in place, with a state file and a secret channel. A host stop or crash ends the sessions. |
| The server's memory | Cards (never read back from a file the team can write), the live streams, the chat store, leads' state | Nothing: a restarted server rebuilds them from the host, the vault and the projects. |
| `~/.vibeswitcher/v2/` | `server.sock`; `engine.json` (held messages, the witness's keys, the last host start); `held-sends.json`; `accepted.json`; `builds/<commit>` and `builds/current`; `host.log`, `node.pid` (a detached host) | Everything, but a worker of your uid can write these files. A held `.user` message goes out as yours after a restart only if the vault vouches for its action and digest. |
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
| CI | `v2 linux` (Ubuntu: the platform, core and node, and host suites); `v2 macos` and `v2 macos install` (Xcode) | On push; `scripts/ci/check-workflows.sh` checks the workflows |

## The request kinds

Generated from the code (`KindsTable`). After changing a kind, run
`.build/debug/vibeswitcher-cli kinds-doc --write docs/guide/v2-architecture.md`. "Recorded first" means the vault
records the action before it is done. "Card code" means the card's code is checked. A kind marked "a page only" isn't
taken on the Unix socket.

<!-- kinds-table: generated by `vibeswitcher kinds-doc --write docs/guide/v2-architecture.md`; don't edit -->
| Kind | Who may send it | Changes state | Recorded first | Card code | Handled by | Arguments (state changes) | Typed | A retry | In approve's batch |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `answer` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code`, `text`, `version` | `WireKinds.Answer` | done, no result |  |
| `approve` | the user's terminal | yes | yes |  | `Requests.act` | `batch`, `code` | `WireKinds.Approve` | done, no result |  |
| `approve.list` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.ApproveList` |  |  |
| `base.accept` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.BaseAccept` | done, no result | yes |
| `base.keep` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.BaseKeep` | done, no result |  |
| `base.show` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.BaseShow` |  |  |
| `board` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Board` |  |  |
| `board.image` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `board.task` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `brief` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | `WireKinds.Brief` |  |  |
| `build.switch` | the user's terminal | yes | yes |  | `Requests.act` | `commit` | `WireKinds.BuildSwitch` | done, no result |  |
| `chat.image` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |
| `chat.page` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |
| `config.accept` | the user's terminal | yes | yes | yes | `Requests.act` | `batch`, `card`, `code` | `WireKinds.ConfigAccept` | done, no result | yes |
| `config.held` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.ConfigHeld` |  |  |
| `draft` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |
| `draft.clear` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |
| `hold` | the user's terminal | yes | yes | yes | `Requests.act` | `card`, `code` | `WireKinds.Hold` | done, no result |  |
| `hooks.install` | the user's terminal | yes | yes |  | `Requests.act` | `agents` | `WireKinds.HooksInstall` | its result; done again | yes |
| `hooks.remove` | the user's terminal | yes | yes |  | `Requests.act` | `agents` | `WireKinds.HooksRemove` | its result; done again |  |
| `lead` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `goal`, `initialized`, `replace`, `resume`, `takeHead` | `WireKinds.Lead` | its result |  |
| `mail` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | `WireKinds.Mail` |  |  |
| `plugin.add` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `manifest`, `program` | not yet | done, no result |  |
| `plugin.file` | anyone of the uid |  |  |  | `Requests.act` |  | not yet |  |  |
| `plugin.inspect` | the user's terminal |  |  |  | `Requests.act` |  | not yet |  |  |
| `plugin.list` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.PluginList` |  |  |
| `plugin.off` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | `WireKinds.PluginOff` | done, no result; done again |  |
| `plugin.on` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | `WireKinds.PluginOn` | done, no result; done again |  |
| `plugin.remove` | the user's terminal | yes | yes |  | `Requests.act` | `plugin` | not yet | done, no result; done again |  |
| `presets.edit` | the user's terminal | yes | yes |  | `Requests.act` | `args`, `default`, `digest`, `env`, `folder`, `keepShell`, `kind`, `name`, `op`, `rename`, `unset` | `WireKinds.PresetsEdit` | done, no result |  |
| `prompt-audit` | the user's terminal | yes | yes |  | `Requests.act` | `do`, `folder` | `WireKinds.PromptAudit` | its result; done again |  |
| `push` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `request` | `WireKinds.Push` | done, no result |  |
| `push.decline` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `request` | `WireKinds.PushDecline` | done, no result; done again |  |
| `question.post` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |
| `question.revise` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |
| `question.withdraw` | a lead's tool server |  |  |  | `questionPost` |  | the page's (WireSchema) |  |  |
| `questions` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Questions` |  |  |
| `recent` | the user's terminal, or a page that reads |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `seen` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `send` | the user's terminal | yes | yes |  | `Requests.act` | `images`, `now`, `session`, `text` | `WireKinds.Send` | done, no result |  |
| `session.attach` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |
| `session.close-shells` | the user's terminal | yes | yes |  | `Requests.act` | `sessions` | `WireKinds.CloseShells` | done, no result; done again |  |
| `session.complete` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `session.draft` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |
| `session.draft.clear` | a page that drafts | yes |  |  | `draft` |  | the page's (WireSchema) |  |  |
| `session.end` | the user's terminal | yes | yes |  | `Requests.act` | `session` | `WireKinds.SessionEnd` | done, no result; done again |  |
| `session.new` | the user's terminal | yes | yes |  | `Requests.act` | `agent`, `digest`, `folder`, `model`, `preset` | `WireKinds.SessionNew` | done, no result |  |
| `session.pause` | the user's terminal | yes | yes |  | `Requests.act` | `for`, `hours`, `session` | `WireKinds.SessionPause` | its result; done again |  |
| `session.ports` | anyone of the uid |  |  |  | `Requests.act` |  | the page's (WireSchema) |  |  |
| `session.presets` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Presets` |  |  |
| `session.rename` | the user's terminal | yes | yes |  | `Requests.act` | `name`, `session` | `WireKinds.SessionRename` | its result; done again |  |
| `session.reopen` | the user's terminal | yes | yes |  | `Requests.act` | `all`, `forget`, `sessions` | `WireKinds.SessionReopen` | done, no result |  |
| `session.reply` | the user's terminal | yes | yes |  | `Requests.act` | `choice`, `options`, `question`, `session`, `text` | `WireKinds.SessionReply` | done, no result |  |
| `session.resume` | the user's terminal | yes | yes |  | `Requests.act` | `session` | `WireKinds.SessionResume` | its result; done again |  |
| `session.usage` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |
| `set` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `key`, `value` | `WireKinds.SetSetting` | done, no result; done again |  |
| `settings` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Settings` |  |  |
| `shells` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.Shells` |  |  |
| `start` | the user's terminal |  | yes |  | `Requests.act` | none | `WireKinds.Start` | its result; done again |  |
| `stats` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Stats` |  |  |
| `status` | anyone of the uid |  |  |  | `Requests.act` |  | `WireKinds.Status` |  |  |
| `stop` | the user's terminal | yes | yes |  | `Requests.act` | none | `WireKinds.Stop` | its result |  |
| `subscribe` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |
| `tell` | the user's terminal | yes | yes |  | `Requests.act` | `folder`, `text` | `WireKinds.Tell` | done, no result |  |
| `term.close` | a page's terminal (a page only) | yes |  |  | the terminal relay |  | the page's (WireSchema) |  |  |
| `term.open` | a page's terminal (a page only) | yes |  |  | the terminal relay |  | the page's (WireSchema) |  |  |
| `unsubscribe` | anyone of the uid |  |  |  | the live hub |  | the page's (WireSchema) |  |  |
| `update.check` | the user's terminal |  |  |  | `Requests.act` |  | `WireKinds.UpdateCheck` |  |  |
| `web.open` | the user's terminal | yes | yes |  | `Requests.act` | `tailnet` | `WireKinds.WebOpen` | done, no result |  |
| `web.revoke` | the user's terminal | yes | yes |  | `Requests.act` | none | `WireKinds.WebRevoke` | done, no result; done again |  |
<!-- kinds-table end -->
