# VibeSwitcher 2: feature plugins

The definition of the plugin system the V2 design names (its "Feature plugins" section and rule 7: "Optional features
are plugins: wallet is on for the user, absent for everyone else"). Until now nothing implemented it: shell requests
went in on 2026-11-21 as a card kind wired by hand into about ten places, and the wallet isn't on the node at all.

These are **feature plugins**: things one person wants and another doesn't (shell requests, wallet signing; later
deploy, migration, secret access, "open a PR" asks). They are not Claude Code's plugins (the team's plugins the lead
lists), which keep their name and code.

## What a plugin is

A plugin is one folder under `Sources/VibeNode/Plugins/<Name>/` that declares, in one place, everything its feature
adds. It is compiled into this repository: no third-party code is loaded (the design's line on that stands). Every
value that crosses the plugin's edge is plain data (`Codable`, no closures in the shapes), so that a later plugin can
be a separate process speaking the same shapes; that process form is not built now.

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

The wire carries it as `card.plugin` (a generic shape in `WireSchema`), replacing `card.shell`. A stored card of the
old `shell` kind still loads, as the shell plugin's.

## What stays the core's, whatever a plugin says

A plugin can't relax any of these, because it never holds them:

1. **Requests are host-stamped.** A plugin reads only requests the session host stamped for a live session the user
   opened, through the one reader the registry gives it. Outcomes live in the engine's memory or the node's state,
   never in a file an agent can write (the shell review's finding).
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
   turns nothing on. Decisions are never part of `vibeswitcher approve`'s batch.
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

## The build, in three steps (each merged on its own)

1. **The registry and the generic card.** `Plugins/Plugin.swift` (the shapes above), `PluginRegistry`, the on/off
   state and its two commands, the one reader of stamped requests, `card.plugin` on the wire, the generic renderers
   (command line, page, approval dialog text, brief, `approve`'s list), the lint. No behaviour changes yet.
2. **Shell requests move onto it**, with nothing a user sees changing: `vs-shell`, the card, `answer CARD
   run|decline`, expiry, what the asker is told. `ShellCards.swift` becomes `Plugins/Shell/`. Every existing shell
   test and acceptance case passes unchanged in what it asserts; the hand-wired `shell` cases in `CardStore`,
   `CardRequests`, `Answers`, `CardText`, `ApprovalCard`, `ApproveRequest`, `BriefRequest`, the page's `cards.js`
   and `shellcard.js` go. Then: off leaves no trace, tested.
3. **The wallet plugin**, off by default, Linux's slice: signing in the browser's wallet. An agent's `vs-wallet`
   request (`WalletAsk`, host-stamped) becomes a card whose facts are the chain and the asking session and whose
   body is the transaction whole (to, value, data, as `WalletRequestFormat` words them). `answer CARD sign` (the
   user's voice) opens a one-request signing page on its own origin for the person's browser wallet; the signed
   result or the refusal is recorded and told to the agent. `decline` declines. The author's chains (GenLayer) are
   its configuration, not its code. This step stops for an independent security review before it merges.

The Mac app keeps its present wiring (milestone 5 changes it on a Mac): nothing under `Sources/VibeSwitcher` is
edited, and `VibeCore`'s `ShellAsk` and `Wallet*` are used as they are (a needed change there is minimal, with a
port-map row).
