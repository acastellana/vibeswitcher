# VibeSwitcher 2: feature plugins

The definition of the plugin system the V2 design names (its "Feature plugins" section and rule 7: "Optional features
are plugins: wallet is on for the user, absent for everyone else"). Until now nothing implemented it: shell requests
went in on 2026-11-21 as a card kind wired by hand into about ten places, and the wallet isn't on the node at all.

These are **feature plugins**: things one person wants and another doesn't (shell requests, wallet signing; later
deploy, migration, secret access, "open a PR" asks). They are not Claude Code's plugins (the team's plugins the lead
lists), which keep their name and code.

## What a plugin is

A plugin declares, in one place, everything its feature adds. It comes in two forms with the same shapes:

- **Built in**: one folder under `Sources/VibeNode/Plugins/<Name>/`, compiled into this repository. Shell requests
  are this, on by default.
- **External** (the user's decision of 2026-11-22: "the wallet plugin as an actually separate plugin and
  repository"): a program in a repository of its own, which the person adds to a node and which speaks the plugin
  protocol over its standard input and output. No plugin code is ever loaded into the node's process. The wallet is
  this, and the pattern for anyone's own.

Every value that crosses a plugin's edge is plain data (`Codable`, no closures in the shapes), the same for both
forms.

A plugin declares:

| Part | What it is |
|---|---|
| `id`, `title`, `summary` | `shell`, "Shell requests", one line a person reads in `plugin list` |
| `defaultOn` | shell: on. wallet: off |
| `availability` | where it can run: nil, or the reason it can't on this node (system, a missing tool) |
| agent commands | the commands sessions get (`vs-shell`, `vs-wallet`), the MCP tools behind them, the hook handling |
| request | how a host-stamped request is read from where the command files it, and its validation |
| card | the request as a **card of data** (below) |
| actions | the answer words (`run`, `decline`, `sign`), which of them act, and what acting does |
| outcome | what the asking session is told, and what the card says once settled |
| settings | its entries in the settings catalog (its own section) |
| brief | the lines it adds to an agent's brief and to `vibeswitcher brief` |

A registry (`PluginRegistry`) lists the plugins. Everything else in the node asks the registry; nothing else names a
plugin's id. A lint keeps it so: outside `Plugins/<Name>/` and the registry's list, no source names `shell` or
`wallet` as a card kind, an answer word or a view.

## Off leaves no trace

A plugin that is off adds nothing: its agent command answers "this node doesn't have NAME on" and files nothing, no
MCP tool is listed, a request found on disk is dropped unread, no card is drawn, its settings section and brief
lines are absent, the page's hello doesn't list it and the page draws nothing for it. Turning one off while a card
of its is open closes that card as withdrawn, telling the asker.

## The card is data

One card shape for every plugin, and one renderer per client (the command line's `CardText`, the page's card view,
the Mac's approval dialog text, `approve`'s own-decision list, the brief):

- `plugin`, `title`;
- `facts`: label and value pairs the **host or the server** derived, never the agent (the asking session, the
  folder, the chain or site);
- `body`: the decisive content, as lines of inert text shown whole (a shell command's every line, a transaction's
  recipient, amount and data), with its size (lines and bytes);
- `context`: the agent's own words, marked as the agent's, cut if long, never before the decisive part;
- `severity`; `expiresAt`;
- `actions`: each a word, a label, whether it acts, and a one-line statement of what acting does;
- `state` and `outcome` once settled.

The wire carries it as `card.plugin` (a generic shape in `WireSchema`), replacing `card.shell`. (No old `shell` card
needs loading: cards live in the server's memory only (S3), and the page is served by its own server's build and
reloads on a new one.) The renderers mark the agent's words as the agent's (the context, quoted, in `CardText`, the
page and the notice), never among the facts; the Mac's dialog shows every fact the plugin marks decisive, or asks
nothing.

## What stays the core's, whatever a plugin says

A plugin can't relax any of these, because it never holds them:

1. **Requests are host-stamped.** A plugin reads only requests the session host stamped for a live session the user
   opened, through the one reader the registry gives it. Outcomes live in the engine's memory or the node's state,
   never in a file an agent can write (the shell review's finding). The desk holds this itself, before any plugin's
   decoder runs: it reads each request's bytes and its stamp (no link followed, bounded), checks the stamp's digest is
   of those bytes and its session the request's, asks the vault whether the stamp is the host's, and gives nothing from
   a session that isn't live and the user's (a team's worker or verifier is the lead's tool server's). A request once
   settled (answered, withdrawn, expired, gone) is never drawn again: the vault keeps the settled ids.
2. **Acting is the user's voice.** Every acting answer goes through `Requests.voiced`: the terminal check, the
   card's typed code, the vault's record, replay by action id. A plugin's `perform` runs only after it. A page
   never acts; it shows the card and the line to run.
3. **Text is inert, and the decisive part is whole.** The renderers print through `ConfigSeal.inert`; blank-looking
   characters are refused at validation (the shell review's rule, now the registry's for every plugin); a decisive
   value that doesn't fit is refused, never cut.
4. **One at a time, expiring.** A card expires (a plugin sets how long, at most 30 minutes unless it says why);
   an action runs once (the card is marked inside the same turn).
5. **On and off are the user's, and an agent's write doesn't count.** `vibeswitcher plugin on|off NAME` is a voiced,
   recorded action. The state is kept where the vault vouches for it, so a session that rewrites a settings file
   turns nothing on. Decisions are never part of `vibeswitcher approve`'s batch. The limit: on Linux the vault lives
   in the host's memory, so a host restart starts it over, and each plugin is back at its default (the wallet, off by
   default, comes back off). The restart's notice names the plugins among what it reset, and `plugin list` says
   "at its default since the session host's restart" until the user sets it again.
6. **A plugin's page content never shares the node page's origin when it can move money or run code.** A page a
   plugin serves for a person's browser to act in (the wallet's signing page) is on an origin of its own (its own
   loopback port, held by the host as the web's is), serves one request, and is gone.

## Commands

```
vibeswitcher plugin list                 # each plugin: on or off, why it can't run here, what it adds
vibeswitcher plugin on NAME | off NAME   # the user's voice
vibeswitcher answer CARD WORD            # unchanged: a plugin's action words are its card's
```

`status` and the page's This node list the plugins that are on.

## The build, in four steps (each merged on its own)

1. **The registry and the generic card.** `Plugins/Plugin.swift` (the shapes above), `PluginRegistry`, the on/off
   state and its two commands, the one reader of stamped requests, `card.plugin` on the wire, the generic renderers
   (command line, page, approval dialog text, brief, `approve`'s list), the lint. No behaviour changes yet.
2. **Shell requests move onto it**, with nothing a user sees changing: `vs-shell`, the card, `answer CARD
   run|decline`, expiry, what the asker is told. `ShellCards.swift` becomes `Plugins/Shell/`. Every existing shell
   test and acceptance case passes unchanged in what it asserts; the hand-wired `shell` cases in `CardStore`,
   `CardRequests`, `Answers`, `CardText`, `ApprovalCard`, `ApproveRequest`, `BriefRequest`, the page's `cards.js`
   and `shellcard.js` go. Then: off leaves no trace, tested.
3. **External plugins** (below): a plugin as a separate program in its own repository, speaking a protocol.
4. **The wallet, as the first external plugin, in its own repository.** Nothing of the wallet is compiled into
   this repository.

The Mac app keeps its present wiring (milestone 5 changes it on a Mac): nothing under `Sources/VibeSwitcher` is
edited, and `VibeCore`'s `ShellAsk` and `Wallet*` are used as they are (a needed change there is minimal, with a
port-map row).

## External plugins

### Adding one

A plugin's folder holds a manifest, `vibeswitcher-plugin.json`: the protocol version, `id`, `title`, `summary`, the
program to run (a path inside the folder), `defaultOn` (ignored: an added plugin starts off), the commands it gives
agents, its settings, its brief lines, a card's life, and what it asks of the core (`page`, when it serves a
one-request page).

```
vibeswitcher plugin add FOLDER      # the user's voice: shows the manifest, the program's path and SHA-256, what it asks for
vibeswitcher plugin remove ID       # the user's voice: its cards withdrawn, its record, data and unsettled requests gone
vibeswitcher plugin on ID | off ID
```

`add` records, in the vault, the folder's resolved path and the SHA-256 of the manifest and of the program. The
node runs the program only from a copy it made and checked against that record (as the host runs its server child
from a sealed copy): a program changed since the add is not run, its plugin is held, and `plugin list` says so
until the person adds it again. A plugin whose id is a built-in's is refused.

### The process

The server starts an on plugin's program as a child: no terminal, its own session and process group, standard input
and output as the protocol's two pipes, standard error to the node's log (inert, capped). It is ended when the plugin
goes off, on `stop`, and when it breaks the protocol. It runs in a box when the sandbox gives the node one for
programs of this kind (the sandbox plan's later slice); until then it runs as the person, which is what installing a
program means.

**One self-contained program.** The SHA-256 the user saw covers the program's bytes, so nothing else it reads at start
may be writable by anyone but root (the review of step C, H1). It is run from a sealed copy and cannot see its folder.
Its environment is PATH (root's folders), `HOME=/nonexistent`, LANG, and `PYTHONNOUSERSITE=1`, `PYTHONSAFEPATH=1`,
`PYTHONDONTWRITEBYTECODE=1`, and nothing else of any runtime's; it works in `/`. A plugin that keeps data says
`data: true` in its manifest and gets `VIBESWITCHER_PLUGIN_DATA`, a private folder of its own under the node's root,
which any session of the person's can write: it reads what is there as untrusted input. At `plugin add` and at every
start the core refuses, with the reason shown, an ELF program whose interpreter, RUNPATH or RPATH entry, or library
named by a path isn't an absolute path that is root's all the way (every folder and the file owned by root, not
writable by a group or others), or that names `$ORIGIN`; a script whose `#!` interpreter isn't such a path, `env`
included; and anything that is neither. The check reads at most the program's first 64 MiB, its fields as untrusted
(every offset and size checked against what is read, 256 program headers, 4096 dynamic entries, 4 KiB a string):
anything out of range refuses the program, never stops the server.

**Its end reaches what it started.** The program is started from a thread that lives as long as the server, through
setpriv with the parent-death signal (KILL), so the server's end ends it. Where the server's cgroup is writable (the
node's systemd unit, under the user's manager) it gets a cgroup of its own, entered before it runs, which its end
empties whatever sessions it made, and which the next server empties if this one died. The limits: without that
cgroup, a child of the program that starts a session of its own escapes the group's kill and doesn't inherit the
parent-death signal; a server that ends in the instant between the spawn and setpriv's setting the signal leaves the
program running; and on a system without setpriv only the group is ended.

### The protocol

JSON, one object a line, each line at most 256 KiB; the node asks and the plugin answers (every message has the
asker's `id`; a plugin never speaks first); a call unanswered for 10 s, a line too long, or an answer that doesn't
fit its shape ends the program, withdraws its open cards and says why in `plugin list`. Version 1:

| The node asks | With | The plugin answers |
|---|---|---|
| `hello` | the protocol version, the node's build | its `id` and version (must equal the manifest's) |
| `file` | an agent's command words and working folder | the request's `payload` (bytes, base64) and its expiry, or `refuse` with why (told to the agent at once) |
| `card` | a verified request: its id, payload, the plugin's settings | a card of data (below), or `refuse` |
| `perform` | the request, the action word, after the user's voice | an `outcome`; or `page` (the page to serve once) |
| `page.answer` | what the page sent back | an `outcome`, or `refuse` (a garbled answer) |
| `settings.check` | a key and a value | ok, or `refuse` |
| `withdrawn` | a request id | ok |

An **outcome** is a state word for the card, a line for the person and a line for the asking agent.

### What the core does that an external plugin can't

Everything in "What stays the core's" holds, and the core does more of the work itself:

- **Filing.** One command of the core's files for any plugin: `vs-ask ID -- WORDS` (through the node's tool server).
  The core asks the plugin's `file` for the payload, and the **session host stamps it**; the plugin never writes a
  request. Only a session the user opened files, and only from inside it (the host's list of live sessions names the
  caller's process tree); whichever check fails, the refusal is the same words. At most 4 filing calls wait on a
  program; the rest are told it is busy. A protocol line nested over 32 deep is a breach, found before it is parsed.
  A plugin's own command names (`vs-wallet`) are thin wrappers the node generates beside its own commands
  while the plugin is on.
- **The card's facts are split.** The asking session and its folder are the host's, drawn by the core. What the
  plugin says (the chain, the decoded call) is shown as the plugin's, named in the core's words by its id ("the wallet
  plugin says"), never by the title it chose (a title naming VibeSwitcher, the node or the session host is refused).
  What the agent is told is one line under the core's prefix (`[the wallet plugin, through VibeSwitcher]`), never
  starting with "[". Every answer of an external plugin that reaches its program is acting (expiry, a live asker, the
  settle first), whatever its card says, and a page for a word that doesn't act is a breach. A plugin's command is
  never one the node ships (`vs-ask`, `vs-shell`, `vs-heavy`); the Linux install doesn't ship the Mac app's
  `vs-wallet` filer, so the wallet plugin's own is the one a session finds. The node's folders for its plugins are
  never followed through a link. The body,
  the context's marking, inert text, whole-or-refused, expiry and once-only are the core's checks on the plugin's
  data, exactly as for a built-in plugin.
- **The page is the core's.** A plugin that asks for `page` gives the page as data: its HTML, the scripts' and
  styles' hashes for the content security policy, and how long it may live (at most 15 minutes). The core serves it
  once on an origin of its own (a loopback port the session host holds), with its own one-time token in the address,
  printed only in the answering terminal; checks Host, Origin and token; takes one answer of bounded size; and hands
  it to `page.answer`. The plugin never listens on a port and never sees the token.
  The page is served once: that one load gets a second secret (an HttpOnly, SameSite=Strict cookie) the answer
  needs, so a process that learns the address later can't answer; one answer socket at a time, one answer in flight;
  a refused upgrade costs the person no try, an answer over the size does. The address is printed by the core in the
  answering terminal's reply only (a retry of the same action is told where it went, not given it); only an acting
  answer opens a page; a plugin turned off or removed takes its page with it; the node's one page slot is freed only
  once the host has let the port go, a failed start included.
  Its limits, accepted: after a server death the host holds the page's port until the next page or a release; any
  local process can fill the page's connection slots (16) while it lives, which keeps the person from answering
  until it ends (a denial among the person's own processes, which can already end the server).
- **Settings** are kept in the vault and set by the user's voice; the plugin only checks a value.
- **Nothing else.** A plugin has no way to ask the core to act: it can't start a session, type into one, read the
  vault or other sessions, answer a card, or reach the node's socket (its program is refused there as any other
  process of the person's that isn't in a terminal).

### The wallet's repository

`vibeswitcher-wallet` (a repository of its own; nothing of the node's code in it, and it needs none: it speaks the
protocol). It holds the wallet's logic that this repository's `VibeCore/Wallet*` holds for the Mac app (the
request's shape and validation, the call decoding, the chain table, the signing page), a manifest, its tests against
a recorded protocol transcript, and a short guide: `git clone`, build, `vibeswitcher plugin add`, `plugin on
wallet`, `set wallet_chains …`. The author's chains (GenLayer) are its settings' example, not its code. This
repository keeps a test plugin (`Tests/Fixtures/plugin-probe/`) that speaks the protocol, so the node's tests need
no wallet.
