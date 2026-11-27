# V2 without a terminal: every step that sends you to one, and the click that replaces it

**The bar.** V2's page should feel like a well-made native app: no terminal day to day, biometrics instead of typed
codes, no commands, hashes or internal names where a person reads, safe defaults that need no setup, and every action
says what happened. (The lead's statement of the user's aim, 2026-11-25: "this needs to feel like a good Apple app".)

Checked 2026-11-25 by reading the code, not the plans: the node and the command line at `v2-user-decisions`
(`9016b19b`, the same node code as both web branches), the page as it will be on `v2-web-ux-d` (`256bb89a`) and its
Settings on `v2-web-ux-c` (`fe4a93fd`). Nothing was run: there is no node on this Mac. Each row says **code** (read in
the code) or **docs** (read from the docs only). The flows these steps sit in are in [the user flows](v2-user-flows.md);
the features in [V1 and V2: what each one does](v2-parity.md#summary).

## For you, in one page

**Today there are 42 terminal steps:** 2 on every action, 4 daily, 13 weekly (4 of them come back after every
reboot), 14 rarely, 9 once at setup. V1 has none.

**The ten that hurt most day to day:**

1. **A page that doesn't act turns every click into a line to paste** (A0): every answer, message, reply, start and
   setting. The phone is always such a page; so is a desktop page after a reload.
2. **The desktop page has to be paired again** (A1, A2): after every reload, every 12 hours and every restart, with
   `vibeswitcher web`, three words typed back and a code.
3. **The phone re-pairs every 8 hours and can never act** (A4): reads and drafts only, by rule.
4. **Every change from the command line asks for a typed code** (D8).
5. **No typing into a session's terminal** from any page (C6): Ctrl-C, Esc, arrows, a menu.
6. **After a reboot, four terminal chores** (D7, A3, D4, C3): start the node, turn acting back on, accept every
   project's config again, reopen your sessions.
7. **Updating is terminal only** (D1): install and switch lines on the page, no button.
8. **A new project is made only in a terminal** (C1).
9. **A session's multiple-choice question** is answered only in its own terminal (C5).
10. **Five lines the page still shows although the node would take the click** (B1 to B5): close finished shells,
    restart a recent project, resume an ended session, check for updates, send an image by its path.

**What the proposed work leaves:** day to day, **nothing**, once device keys are built (decided 2026-11-25) and you
decide that guarded changes (updates, hooks, first config accepts, review floors, plugins) may be approved with Touch ID
or Face ID on the page (decision N1 below); if you keep them in a terminal, those stay, each a few times a month. At
setup on Linux: the prerequisites that need `sudo`, one install line, and confirming your first browser in that same
terminal; the security design keeps that first step typed ([why](#the-bootstrap)). On the Mac: none at all with an app
or installer package, which needs a build that is distributed and signed (decision N4); without one, an install script
and its `launchctl` lines.

**Order:** 11 page-only fixes first (each under 30 minutes), then 7 node changes, then the device-key track already
decided, then what waits on your decisions N1 to N8 ([build order](#build-order)).

## How to read the table

- **How often**: *every time* (each action), *daily*, *weekly* (after each reboot counts as weekly), *rarely* (less
  than weekly), *once* (setup).
- **Authorised by**: what proves it is you without a shell: *the page's trust* (`web_acts trust`, built, loopback
  only), *the device key* (a passkey made at pairing, checked per message: decided 2026-11-25, not built), *Touch ID*
  (on the Mac, asked by the node's server: built, off until measured), or *a terminal* (and why it must stay one).
- **Who builds**: *page* (the node already lists the kind as a page's: `KindSpec`'s `page` column is `.acts`, the page
  sees it in `hello.kinds` through `store.can`), *node* (a new kind or a rule change, named), or *decision* (yours
  first, named in [the decisions](#decisions-it-waits-on)).
- **Size**: S a day, M a few days, L a week or more.
- **Where the page acts today**: only a loopback page (127.0.0.1) whose pairing was confirmed in a terminal while
  `web_acts` is `trust` (`WebAccess.acting`, `ActingPages.acts`). A tailnet page never acts (`WebAccess.acting` is nil
  there; the remote access note's LW-D6). Everywhere else each control below is a line to copy.

## The full table

### A. Opening, pairing and trusting the page

| # | Today (the exact line) | How often | The click instead (desktop; phone) | Authorised by | Who builds | Size | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A0 | Every action from a page that doesn't act: the page drafts and shows `vibeswitcher answer CARD`, `send ID`, `reply ID N`, `tell FOLDER "…"`, `push FOLDER`, `new FOLDER`, `lead FOLDER`, `set KEY VALUE`, `plugin on NAME`, `approve`, … with Copy (`copyLine`, 31 call sites in `WebApp/js`, beside a few lines shown as bare `code`), to run with a typed code | every time | the button the acting page already shows (`doButton`), on every page that holds a device key; the phone included | the device key | node: device keys (A1, A4); the buttons exist | L (in A1, A4) | code |
| A1 | `vibeswitcher web`, then open the printed address within 120 s; again after each reload (the pairing secret lives in the page's memory only), every 12 h (`ActingPages.life`), every 24 h (`WebTokens.life`) and every host restart (the vault starts over) | daily | open the bookmark; Touch ID on the Mac (one, for 12 h, the user's choice of 2026-11-25) or the device's passkey on Linux | the device key; Touch ID | node: device keys (the H1 plan's item 2), kinds to add, unlock and remove a device, and `web.open` and `web.confirm` taken from a page (both `terminalOnly` today) | L | code |
| A2 | Confirm the pairing: type the three words the page shows where `vibeswitcher web` asks, then the code (`web.confirm`) | daily | none: the device key replaces the phrase | the device key | node: with A1 | (A1) | code |
| A3 | `vibeswitcher set web_acts trust`, with a code: after every host restart (the level starts `off`, `LeadVaultV2.PageActs`) and after `off` | weekly | none: acting comes with the device key (the lead's call: the same-machine page acts as today until device keys exist, then needs the key) | the device key | node: `web_acts` (`lowersOnly`, raised from a terminal only) gives way to the device key | S (after A1) | code; the vault in memory: docs (S7) |
| A4 | `vibeswitcher web --tailnet` (Tailscale and MagicDNS on), open the address on the phone within 120 s; it reads and drafts for 8 h (`WebTokens.tailnetLife`), never acts | daily | This node › Devices › Add a phone: a QR code on the unlocked desktop page; the phone keeps its own key and Face ID unlocks it for 12 h | the desktop page's device key, then the phone's own | node: HTTPS through `tailscale serve` (the H1 plan's item 1), device keys, acting on the tailnet (`WebAccess.acting` nil there by rule), a device added from a page (collides with `web.open`'s reason, below) | L | code |
| A5 | `vibeswitcher web --revoke`, with a code: drops every page, here and on the phone | rarely | This node › Devices: Remove beside each device, and Remove all | the page's trust (`web.revoke` is already a page's kind); per device, the device key | page: Remove all; node: per device, with A1 | S | code |

The page is ahead of the node in one place: at the `confirm` level it says "Add a passkey (asked from your terminal)"
and names `vibeswitcher web --localhost` (`WebApp/js/acting.js`, `i18n.js`'s `pk…` words), but the node has neither:
`ActingPages.confirmBuilt` is false and `web` takes only `--tailnet` and `--revoke` (`Web.swift`). Those words go when
A1 is built.

### B. Lines the acting page still shows, although the node takes the click

| # | Today (the exact line) | How often | The click instead (desktop; phone) | Authorised by | Who builds | Size | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | A session's sheet › Shells shows `vibeswitcher close-shells FOLDER` only: the sheet's `line()` gets no kind, though `session.close-shells` is a page's | weekly | Close N finished shells, the list shown first, a second click to confirm | the page's trust, later the device key | page | S | code |
| B2 | Your own sessions › Recent projects: `vibeswitcher new FOLDER` and `vibeswitcher lead FOLDER` lines only (`own.js`), though `session.new` and `lead` are a page's | weekly | New session and Start lead | as B1 | page | S | code |
| B3 | An ended session's own view: `vibeswitcher resume ID` only (`session.js`, `drawGone`), though `session.resume` is a page's (the Recent list has the button) | weekly | Resume | as B1 | page | S | code |
| B4 | This node › Updates: `vibeswitcher status --check-updates` only (`updates.js`), though `update.check` is a page's | weekly | Check now | as B1 | page | S | code |
| B5 | Chat › an image on the node: `vibeswitcher send ID "…" --image PATH` only (`chat.js`, `drawNodeLine`), though `send` takes `images` from a page | weekly | Send | as B1 | page | S | code |
| B6 | Launch presets: `vibeswitcher preset add`, `edit` or `remove NAME …` only (`drive.js`), though `presets.edit` is a page's | rarely | Save and Remove | as B1 | page | S | code |
| B7 | Between leads, every message: `vibeswitcher mail ROOT --all` (`mail.js`); the `mail` read takes `all` from a page | rarely | Show all | a read (any page, the phone too) | page | S | code |
| B8 | A held config or a moved base, to see it whole first: `vibeswitcher config held ROOT` or `vibeswitcher base show ROOT` beside Accept (`project.js`, `otherCard`); `config.held` and `base.show` are a page's | weekly | Show it whole: a side sheet with what changed | as B1 | page | S | code |
| B9 | A lead that won't start because its base moved or one runs without its role: `vibeswitcher lead FOLDER --take-head` or `--replace`; the page sends only `folder`, `goal` and `resume`, though `lead` takes `takeHead` and `replace` | rarely | the refusal offers Take the base as it is, or Replace it, in place | as B1 | page | S | code |
| B10 | Settings › Set for `lead_mail`, `verifier_model`, `security_audit_model`, `max_workers` and every plugin setting: the page offers Set (`pageMaySet` refuses only `policy`, `floor_*` and raising `web_acts`), the node refuses it (`terminalOnly`), and the page then says to run it in a terminal | rarely | the page shows these as the terminal's from the start (until N1) | none: a page may not set them | page (`pageMaySet`), or node: `settings` gives each setting's page rule (its `Setting` has no `page` field) | S | code |

### C. Needs the node: a new kind or a value the page can read

| # | Today (the exact line) | How often | The click instead (desktop; phone) | Authorised by | Who builds | Size | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | New project: `vibeswitcher new-project NAME --in LOCATION --goal "…"`; no node kind makes the folder (the command line makes it in its own process; the page says so) | weekly | New project › Create | the page's trust, later the device key | node: a new kind (`project.new`, what `NewProject.swift` does, in the server) | M | code |
| C2 | A lead in a folder with no repository: `vibeswitcher lead FOLDER --init` (the command line makes the repository and first commit, `LeadInit`; the kind carries only `initialized`) | rarely | Make it a repository and start, every name to commit shown first | as C1 | node: with C1 | (C1) | code |
| C3 | After a restart: `vibeswitcher reopen`, `reopen all` or `reopen --forget`; the offer reaches the page only as a notice's text (`statusNotices` are strings), and the page has no control for `session.reopen`, a page's kind | weekly | a card on This node and Your own sessions: N sessions ended with the restart › Reopen all, Reopen, Not now | as C1 | node: the offer as a value (sessions, folders, conversations); page: the card | S | code |
| C4 | The prompt audit reminder: `vibeswitcher prompt-audit FOLDER snooze`, `off` or `on`; `prompt-audit` is a page's kind, the reminder only a notice's text | rarely | Remind me in a week, and Not for this project, on the notice | as C1 | node: the notice as a value; page: its buttons | S | code |
| C5 | A session's multiple-choice question: "It takes several ticks: answer it in the session's own terminal" (`drive.js`); `session.reply` takes one `choice` | weekly | ticks and Submit | the device key (it types into the session) | node: `session.reply` with several choices | M | code |
| C6 | Typing into a session's terminal: the watched terminal says to use `vibeswitcher send` in a terminal (`terminal.js`); `TerminalRelay` types only on a scratch node (LW-D12) | daily | type in the watched terminal, keys included; the phone once HTTPS and device keys exist (the lead's decision 6) | the device key, per message | node: LW-D12's rule changed for the user's node (the H1 plan's item 3) | L | code |
| C7 | A card too large for the page: `vibeswitcher questions` (`cards.js`, `tooLarge`) | rarely | the card opens whole in a sheet | a read | node: the card given in parts | S | code (the page); the node's limit not read |
| C8 | `vibeswitcher logs --lines 50` and `logs --sessions`: the command line's own read, no kind | rarely | This node › Logs, masked as `logs` masks them | a read of the user's (the page's trust, not the phone) | node: a read kind | M | code |
| C9 | `vibeswitcher status --ack`: acknowledges starts and stops nothing explains, as a journal entry the command line writes | rarely | Acknowledge on the notice | a terminal today: the ack is the journal entry of the installed command line | decision N6; node: `journal.ack` built (G3, `JournalAckRequest.swift`), the terminal's alone; its record is the vault's record of the action, and the server writes no journal entry: one from the node's unit never counts and `NodeJournal.marks` would flag it on every `status` as not a terminal's. Owed to slices 14–15: the reader (`NodeJournal.acknowledged`, `status`) counting the vault's record of a device-key ack, with its security review; until then the marks stay, so C9 isn't done | M | code (`Status.swift`'s header); the ack rule: docs |

### D. What the node keeps in a terminal on purpose

| # | Today (the exact line) | How often | The click instead (desktop; phone) | Authorised by | Who builds | Size | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | `vibeswitcher update` (install, switch and accepts, one code), or the page's two lines: the install line and `vibeswitcher switch COMMIT` (`updates.js`); `build.switch` and `build.seal` are `terminalOnly` | weekly | This node › Update to X: from, to and what it runs, then Touch ID or Face ID | a terminal today, by rule (quoted below); the device key with presence if N1 allows | decision N1; node: the `update` kind built (G3, `UpdateRequest.swift`: plan, install through the command line's `UpdateInstall.run`, then `build.switch`), the terminal's alone. Owed as kinds to slices 14–15: the follow-up (the unit's `ExecStart`, `current`) and `build.seal`, hard because they run while the server that took the request is replaced | L | code |
| D2 | `vibeswitcher rollback` | rarely | This node › Roll back to X | as D1 | as D1 | (D1) | code |
| D3 | `vibeswitcher hooks install`: at setup, and whenever a build changes the hooks (the page's Approve says "1 more needs the terminal": `vibeswitcher approve`) | rarely | in Approve all, with what it writes shown | as D1 (`hooks.install` is `terminalOnly`) | decision N1; node: the rule | S (after A1) | code |
| D4 | A project's first config accept, or one whose guard rails or floor changed: `vibeswitcher config held FOLDER`, then `config accept CARD`; a page is refused ("no accept is recorded yet (a first accept)", `ConfigHoldStore.pageNotSame`). On Linux after every host restart, since a fresh vault holds every record's first look (S7) | weekly | Accept on the card, every rail shown, then Touch ID or Face ID | as D1 | decision N1; node: `pageNotSame`'s rule | M | code; after a restart: docs (S7) |
| D5 | The guarded settings: `vibeswitcher set policy …`, the eight `floor_*`, `verifier_model`, `security_audit_model`, `max_workers`, `lead_mail` (`terminalOnly` in `NodeSettings`) | rarely | Settings › Set, then Touch ID or Face ID | as D1 | decision N1; node: the settings' page column | S (after A1) | code |
| D6 | `vibeswitcher plugin add FOLDER` (check the SHA-256, type the code), and after every plugin rebuild `plugin remove NAME` and `add` again; `plugin.add` and `plugin.inspect` are `terminalOnly` | rarely | This node › Plugins › Add, the program's SHA-256 shown, then Touch ID | as D1 | decision N1 | M | code |
| D7 | `vibeswitcher start --interop-is-on` after every reboot (two codes the first time: S11's acknowledgment); `start` is `terminalOnly` (no server is there to ask) | weekly | none: the node starts at login (`start --at-login` exists; on the Mac the LaunchAgent's `RunAtLoad`) | a terminal, once (choosing at login) | decision N3 | S | code |
| D8 | The typed code itself, on every change from the command line (`TypedWord`); on the Mac Touch ID asked by the server instead | every time | the page's click (A0) | the device key; on the Mac Touch ID | none beyond A1: the command line keeps it on Linux by S3's rule | (A1) | code; the Mac's state: docs |

### E. Setup and upkeep

| # | Today (the exact line) | How often | The click instead (desktop; phone) | Authorised by | Who builds | Size | Checked |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | `vibeswitcher doctor`'s fixes: `sudo apt-get install -y git`, Claude Code's install command, Swift 6.4.2 extracted by root into `/opt`, nvm then `nvm install --lts`, `sudo apt-get install -y gh && gh auth login`, Tailscale, `loginctl enable-linger $USER`, `/etc/wsl.conf` | once | a package that depends on them, or a release that needs no toolchain or `gh` | root and other vendors' installers: a terminal or the system's software tool | decision N4 | L | code (`NodeDoctor.swift`) |
| E2 | In a checkout: `/usr/bin/env -i HOME=… PATH=/usr/bin:/bin /bin/bash "$PWD/scripts/install-node.sh" COMMIT` | once | one install line that ends by opening the paired page | a terminal (the install's own) | decision N4 | L | code |
| E3 | The `vs` alias for `~/.vibeswitcher/v2/builds/current/bin/vibeswitcher` ("never a `vibeswitcher` found on PATH") | once | none needed once the page does it all | a terminal | none | S | docs |
| E4 | Codex's link: `ln -s ~/.bun/bin/codex ~/.local/bin/codex` | once | none: the node finds Codex where its installer puts it | none | node: where the node looks (a security call on which folders it trusts) | S | docs |
| E5 | The first pairing on a clean machine: A1 and A2, then A3 | once | the bootstrap below | a terminal on Linux; Touch ID on the Mac | node: with A1 | (A1) | code |
| E6 | The phone's HTTPS: HTTPS certificates turned on in the tailnet's admin console (a web page), then the machine's `tailscale serve` configuration (a command on the machine) | once | a button that sets `tailscale serve`, or one line once | Tailscale's own rights (the operator or root) | decision N5 | M | docs |
| E7 | The Mac: `/usr/bin/env -i HOME=… PATH=/usr/bin:/bin /bin/bash …/install-node-mac.sh COMMIT`, then the `launchctl` lines it prints (it never runs them), the signing identity from `scripts/setup-signing.sh`; `start` is refused on the Mac today (`NodeSystem.macUnbuilt`) | once | an app or installer package that installs, loads the agent and opens the page with Touch ID | Touch ID | decision N4; node: the Mac node's steps | L | code (the script's header); the rest: docs |
| E8 | `DISABLE_AUTOUPDATER=1` in Claude Code's settings, to stop the holds its self-updates cause | once | a switch in Settings | as D3 (it writes an agent's own settings) | decision N8; node: `claude.autoupdate` built (G3), the terminal's alone; the page's switch is slices 14–15's | S | docs |
| E9 | The wallet plugin: `bash scripts/build.sh` in its repository, `vibeswitcher plugin add …`, `plugin on wallet`, `set wallet_chains "…"` | once | D6, then the plugin's settings | as D6 | as D6 | (D6) | docs |

### Every command and whether a page can do it today

"Acting page": a loopback page under trust, with its control. "Phone": a tailnet page. A read is open to any page.

| Command | Kind | Acting page | Phone | Row |
| --- | --- | --- | --- | --- |
| `status`, `status --health` | `status` (a read) | reads it (This node) | reads it | none |
| `status --probe` | none (stage 1's local read) | no | no | none needed |
| `status --check-updates` | `update.check` (a page's) | a line only | a line | B4 |
| `status --ack` | none (the journal) | no | no | C9 |
| `doctor`, `logs` | none (the command line's reads) | no | no | E1, C8 |
| `start` | `start` (`terminalOnly`) | no | no | D7 |
| `stop` | `stop` (a page's) | Stop the node | a line | A0 |
| `switch`, `rollback`, `update` | `build.switch`, `build.seal` (`terminalOnly`) | lines | lines | D1, D2 |
| `lead` | `lead` (a page's) | Start lead, Resume, Fresh; not `--take-head`, `--replace`, `--init` | a line | B9, C2 |
| `questions`, `board`, `stats`, `brief`, `presets`, `settings`, `plugin list` | reads | reads them | reads them | none |
| `answer`, `hold` | `answer`, `answer.replace`, `hold` (a page's) | buttons | a draft and a line | A0 |
| `tell` | `tell`, `tell.retract` (a page's) | Send to the lead, Take back | a line | A0 |
| `push`, `decline-push` | `push`, `push.decline` (a page's) | Push, Decline | lines | A0 |
| `send` | `send` (a page's) | Send, with drafted images; not an image by its path | a line | B5 |
| `reply` | `session.reply` (a page's) | buttons, one choice | a line | C5 |
| `new`, `end`, `rename`, `pause`, `resume` | `session.new`, `.end`, `.rename`, `.pause`, `.resume` (a page's) | buttons (not from Recent projects or an ended session's view) | lines | B2, B3 |
| `preset add`, `edit`, `remove` | `presets.edit` (a page's) | lines | lines | B6 |
| `close-shells` | `shells`, `session.close-shells` (a page's) | a line | a line | B1 |
| `reopen` | `session.reopen` (a page's) | nothing shown but a notice | nothing | C3 |
| `new-project` | none | a line | a line | C1 |
| `mail` | `mail` (a read) | reads it; `--all` a line | as the acting page | B7 |
| `prompt-audit` | `prompt-audit` (a page's) | a notice's text | a notice's text | C4 |
| `approve` | `approve.list`, `approve` (a page's) | Approve all, without the hooks and first accepts | a line | D3, D4 |
| `plugin on`, `off`, `remove` | `plugin.on`, `.off`, `.remove` (a page's) | buttons | lines | A0 |
| `plugin add` | `plugin.add`, `plugin.inspect` (`terminalOnly`) | no | no | D6 |
| `config held`, `config accept` | `config.held`, `config.accept` (a page's) | Accept, unless a first accept or changed rails; whole only as a line | lines | B8, D4 |
| `config startup` | none (the Windows Startup shortcuts, a read) | no | no | none (WSL only, rare) |
| `base show`, `base accept`, `base keep` | `base.show`, `.accept`, `.keep` (a page's) | Accept the move, Keep; whole only as a line | lines | B8 |
| `set` | `set` (a page's) | Set, except the guarded settings and raising `web_acts` | a line | B10, D5, A3 |
| `hooks install` | `hooks.install` (`terminalOnly`) | no | no | D3 |
| `hooks remove` | `hooks.remove` (a page's) | no control (rare) | no | none |
| `web`, `web --tailnet` | `web.open`, `web.pairing`, `web.confirm` (`terminalOnly`) | no | no | A1, A2, A4 |
| `web --revoke` | `web.revoke` (a page's) | no control | no | A5 |

## The bootstrap

**Today, from a clean machine to a page that acts.** On Linux (code: `NodeDoctor.swift`, `install-node.sh`, the
commands; docs: [the try-it guide](../guide/v2-try-it.md)): the prerequisites with `sudo` and `gh auth login` (E1); the
install in a checkout (E2); the alias (E3); `vs start --interop-is-on` with two codes (D7); `vs hooks install` (D3);
`vs web`, the phrase and a code (A1, A2); `vs set web_acts trust` (A3); then each project's first `config accept` (D4).
About ten terminal steps, then one per project. On the Mac (code: `install-node-mac.sh`'s header and
`NodeSystem.macUnbuilt`): the install script, its `launchctl` lines and the signing identity (E7), and then nothing
starts: the Mac node is refused until its voice is measured on a real Mac.

**The least a terminal is needed for, after the proposed work:**

| Step | Linux | The Mac | Without a shell at all? |
| --- | --- | --- | --- |
| Install | the prerequisites that need root (git, and Claude Code's own installer), then one install line | an app or installer package | Linux: no, root installs need a terminal or the system's software tool. Mac: yes, with a distributed build (decision N4; the Mac spec rules it out today, quoted below) |
| First start | the install line starts the node and sets it to start at login | the app loads its LaunchAgent | yes, folded into the install (decision N3) |
| First pairing | the install line ends by opening the page and asks you, in the same terminal, to confirm it (the phrase, then the code) | the page opens and the node's server asks Touch ID | Linux: no, this is the root of trust (below). Mac: yes, Touch ID is the voice there (`web.open`'s rule changed) |
| First device key | made on the page just paired: a passkey (WebAuthn) | Touch ID on the page | yes, on the page |
| The phone | This node › Devices › Add a phone: a QR code on the unlocked page | the same | yes, once HTTPS through `tailscale serve` exists; that needs the tailnet's HTTPS certificates (the admin console, a web page) and the `tailscale serve` line or a node that sets it (decision N5) |

**What the security architecture keeps typed, in its words.** On Linux the terminal is the user's voice:
[S3](../superpowers/specs/2026-11-13-v2-security-architecture.md#s3-the-users-voice-before-signed-approvals) says "**A
state-changing request asks for the user's hands.** The command line shows what the request will do (S7's lists, the
answer's card) and asks for a word typed on its controlling terminal", and
[the Mac and Linux table](../superpowers/specs/2026-11-13-v2-security-architecture.md#the-mac-and-linux) gives Linux's
answers as "the command line, by the user's-voice rule with the cgroup check and a typed word". A page can't vouch for
its own pairing: `web.confirm` is `terminalOnly` because "it pairs a page: a page would pair itself", and `web.open`
because "it pairs a page or opens the tailnet's: a page would widen its own reach" (`KindSpec`). A token can't be the
voice: "That is why a token reads and drafts and never changes anything (the live plan's LW-D6)" (S11 item 33). What
stage 4 rests on instead: "Approvals that need the person's presence (a security key or the platform authenticator,
WebAuthn) don't have this hole" (S11 item 31), and [S12 item 11](../superpowers/specs/2026-11-13-v2-security-architecture.md#s12-after-the-bootstrap):
"**Signed approvals** (stage 4), with the person's presence for pairing, Push, wallet and guarded settings (item 31)."
So on Linux the first device needs one terminal confirmation; every later device and every approval can be the device
key with your presence. On the Mac the voice is Touch ID asked by the server
([the Mac spec](../superpowers/specs/2026-11-19-v2-node-on-macos.md#the-users-voice-on-the-mac): "Until it is built and
measured on a real Mac, the user's server there is on the closed rule, and the user's node isn't started at all."), so
nothing needs a shell once that is measured. A one-line install or an installer package needs a distributed build,
which S12 item 12 plans as "**Signed releases** (stage 8)" and
[the Mac spec's install](../superpowers/specs/2026-11-19-v2-node-on-macos.md#install-built-from-a-v2-commit-with-xcodes-toolchain)
rules out today: "Notarisation isn't needed: a build made on the Mac carries no quarantine, and nothing is distributed."

## Where the target meets what v2 built

Written down for the lead, not settled here (the lead's calls of 2026-11-25 at the user's word, recorded in
[the remote access note](../superpowers/specs/2026-11-20-v2-remote-access.md#decisions-for-the-user)):

- **"Paired once, until removed"** meets the pairing's 12 hours (`ActingPages.life`), the tokens' 24 and 8 hours
  (`WebTokens.life`, `tailnetLife`) and Linux's vault in memory (S7: "memory only; lost"), which makes every host restart
  drop every pairing. A device list that survives a restart needs the devices' public keys kept where a worker can't add
  its own: the token file is writable by the user's processes (S11 item 33).
- **"Add a phone from the unlocked page"** meets `web.open`'s and `web.confirm`'s `terminalOnly` reasons (quoted above).
  S12 item 11's "the person's presence for pairing" fits it; the built rule has to be amended.
- **Face ID for 12 hours on the phone** replaces the remote token's 8 hours; the tailnet page never acts by rule
  (`WebAccess.acting` nil, LW-D6) until device keys and HTTPS exist.
- **The phone typing into a terminal** (decision 6) meets LW-D12: `TerminalRelay` types only on a scratch node.
- **Passkeys on the desktop**: a relying party is a domain name, and the loopback page answers only on `127.0.0.1`
  (LW-D5, any other Host refused); the page already names a `localhost` address the node doesn't serve (A1's note).
- **Trust ends with device keys** (the lead's call): `web_acts trust` and its `lowersOnly` rule go, and so does the
  `confirm` level as built (a passkey per request, never built).
- **The Mac's single Touch ID for 12 hours** isn't in the Mac node's spec, which records Touch ID per state change (the
  H1 plan says so too).

## Decisions it waits on

- **N1. Guarded changes from the page** (D1 to D6: update, rollback, hooks, first config accepts and changed rails,
  policy, floors and models, plugin add): stay in a terminal; or from a device-key page with Touch ID or Face ID on each,
  the change shown (S12 item 11); or that on the desktop only, never the phone.
- **N2. Linux's first device**: confirmed in the install line's own terminal, or by `vibeswitcher web` once after it.
  Either way typed (above).
- **N3. Start at login by default** (D7): yes, or `start` after each reboot.
- **N4. A distributed, signed build** (E1, E2, E7): signed releases for a one-line Linux install and a Mac app or
  installer, or keep building each commit on the machine.
- **N5. Who sets `tailscale serve`** (E6): the node (it changes the user's Tailscale configuration; the remote access
  note says the node "changes nothing on the network"), or the user, one line once.
- **N6. The journal's acknowledgment** (C9): from a device-key page, recorded in the vault as the user's, or it stays
  `status --ack`.
- **N7. The desktop's passkey name**: let the loopback page answer on `localhost` too (LW-D5 refuses it), or no passkey
  on the desktop's loopback (Touch ID on the Mac; Linux's desktop then keeps the terminal's pairing).
- **N8. Claude Code's self-update switch from the page** (E8): it writes an agent's own settings, as `hooks.install`
  does: with N1's answer, or never.

## Build order

Each item is one task; the page-only ones are under 30 minutes each. Files are on `v2-web-ux-d` unless named.

**1. Page only** (the node already lists the kind):

1. B1: the Shells tab gets Close N shells: `WebApp/js/views/drive.js` (the `shells` tab's `line(…)` given
   `'session.close-shells'` and the folder; the `shells` read first, to list them).
2. B2: Recent projects get New session and Start lead: `WebApp/js/views/own.js` (`startOrLine` from `drive.js`).
3. B3: an ended session's view gets Resume: `WebApp/js/views/session.js` (`drawGone`, `doButton` with
   `session.resume`).
4. B4: Check now: `WebApp/js/updates.js`, `WebApp/js/views/node.js` (`updatesGroup`, `update.check`).
5. B5: Send for an image by its path: `WebApp/js/views/chat.js` (`drawNodeLine`, `send` with `images`).
6. B6: Save and Remove for presets: `WebApp/js/views/drive.js` (the preset form, `presets.edit`).
7. B7: Show all between leads: `WebApp/js/views/mail.js` (`mail` with `all`).
8. B8: Show it whole: `WebApp/js/views/project.js` (`otherCard`), `WebApp/js/views/sheet.js` (`config.held`,
   `base.show`).
9. B9: Take the base as it is, and Replace it: `WebApp/js/views/drive.js`, `WebApp/js/views/project.js` (`lead` with
   `takeHead`, `replace`).
10. B10: no Set for the settings the node keeps: `WebApp/js/acting.js` (`pageMaySet`: `lead_mail`,
    `verifier_model`, `security_audit_model`, `max_workers`, and plugin settings).
11. A5: Remove all on This node: `WebApp/js/views/node.js` (`web.revoke`, a second click to confirm).

**2. Node kinds and values** (no decision needed):

1. C3: the restart's reopen offer as a value in `node`: `Sources/VibeNode/Server/Requests.swift` (beside
   `restartNotices`), then the card in `WebApp/js/views/node.js` and `own.js`.
2. C4: the prompt audit's reminder as a value: `Requests.swift` (`promptAuditNotices`), then its two buttons.
3. B10, the node's half: each setting's page rule in `settings` (`Sources/VibeNode/Live/Wire/ReadKinds.swift`'s
   `Setting`, from `NodeSettings`' `page`), and `acting.js` reads it instead of guessing.
4. C1 and C2: a `project.new` kind doing `NewProject.swift`'s and `LeadInit`'s work in the server:
   `Sources/VibeNode/Server/KindSpec.swift`, a request file beside `Requests.swift`, `drive.js`'s New project form (M:
   three slices: the kind, `--init`'s repository, the page).
5. C5: `session.reply` with several choices: `Sources/VibeNode/Live/Wire/ChangeKinds.swift`'s `SessionReply`, the
   reply's keys, `drive.js`'s `multiSelect` branch (M).
6. C7: a card too large for a frame, in parts: the card read, `cards.js` (`tooLarge`).
7. C8: a `logs` read kind, masked as `Logs.swift` masks: `KindSpec.swift`, a request file, a Logs group on This node (M).

**3. The device-key track** (decided 2026-11-25; [the H1 plan's order](v2-h1-plan.md#what-can-now-be-built-in-order);
designed 2026-11-26 in [device keys](../superpowers/specs/2026-11-26-v2-device-keys-design.md), whose
[build order](../superpowers/specs/2026-11-26-v2-device-keys-design.md#build-order) splits the five items below into
slices, for review before any is built):

1. HTTPS through `tailscale serve` (the H1 plan's item 1; E6, with N5).
2. Device keys at pairing, every message checked (item 2): A1, A2, A0; the Devices list (A5 per device); A3's trust
   retired; the page's terminal-led passkey words removed.
3. Add a phone from the unlocked page by a QR code (A4), with `web.open`'s rule amended.
4. Page input into terminals (item 3): C6, LW-D12 amended; the phone after item 1.
5. On the Mac: one Touch ID opens the acting page for 12 hours (the Mac node's step 4, measured).

**4. Waits on your decision:**

- N1: D1 and D2 (an `update` kind in the server, L), D3 and D5 (the rules, S each), D4 (`pageNotSame`, M), D6 (M).
- N3: D7, the install's default. N4: E1, E2, E7 (signed releases; the Mac app). N5: E6. N6: C9. N7: the desktop's
  device key on Linux. N8: E8.
- E4 (where the node looks for Codex) is a small node change once the lead says which folders the node trusts.
