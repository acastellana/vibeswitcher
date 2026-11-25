# H1: the host owns the web listener

**Built 2026-11-21 (`v2-usage-summaries`), shape (a), the tailnet as recommended.** The server asks over its connector
(`web listen PLACE ADDRESS PORT`, `web release PLACE`: `HostWebListen` in VibeCore, `HostConnector.web`); the host
checks the place and address itself (127.0.0.1; 100.64.0.0/10; the user's host only port 47830), binds, holds and
sends a duplicate (`HostWebListeners`, `AppConnector.answerWeb`, only to the server child's connector); a handover
carries the sockets (`State.webListeners`); the server binds nothing itself (`WebBind.host`, `ServerLintTests`). Rather
than `--web-listener FD` at each spawn, a restarted server asks again at its start, as it bound again before, and the
host hands it the socket it still holds. Tests: `WebHeldByHostTests` (a restart, a handover, a revoke, on a scratch
node), `HostWebListenersTests`, `HostWebListenTests`, `NodeWebListenerTests`'s host refusal. Page input stays out:
decisions 1, 2 and 4 below still wait on the user. The text below is the plan as written.

**2026-11-25: the user answered decisions 1, 2 and 4** (each "Decided" below, beside its question), and
[what can now be built, in order](#what-can-now-be-built-in-order) follows from the answers.

**The review's fixes (2026-11-21):** the host lets a socket go only on the user's `web --revoke` (or its own end), never
because a restarted server found no token alive; each answer repeats its request and the server checks where the
socket listens; a handover's sockets are held again on the host's queue before its server child is taken again; the web
ask's 5 s bound covers the connector's lock; a state carrying the sockets is handover format 2 (a build before H1
refuses it at its probe; one without stays 1, so switches with the web off are as before); the Mac's server binds its
own until its H1 step (`WebBind.forServer`).

2026-11-21, `v2-usage-summaries`. H1 is the gate before any input from a page reaches a real session: typing into a
terminal, a one-click answer, a reply from a phone (the live plan's LW-D1 and LW-D12 as amended on 2026-11-20, the
live-wire contract's "Rights", the remote access note's "Does H1 come first?", the security architecture's S11 item
32). This note says what H1 is, how big it is, and what waits on the user. Nothing here is built.

## What H1 closes, and what it doesn't

**Closes:** the web port squatted while the server is down. Today `vibeswitcher-server` binds `127.0.0.1:47830` itself
(`Sources/VibeNode/Web/NodeWebListener.swift` `start()`; the tailnet page binds the Tailscale address the same way,
`Server/TailnetWeb.swift`). Between two servers (a crash, a restart, a `switch`) nothing holds the port, so any local
process can bind it. A page that reconnects then sends its token to that process, and a bookmark opens that process's
page (S11 item 32). Today a token only reads and drafts, so a squatter gets a screen it can lie on and nothing more. Once a
page can type into a session, a squatter could take the page's input, or put words in the user's mouth on a screen that
looks like the node's. So the port must never be unheld.

**Doesn't close** (and isn't H1's to close): a token's hash file that the user's processes can write (S11 item 33, why a
token never acts), every Windows process reaching the port under mirrored networking (item 34), and the browser's
storage on `/mnt/c` (item 31). Those are the reasons page input also needs the decisions below, not just H1.

## What H1 is

The host holds the listening sockets for its whole life, and hands each server child a descriptor it can only accept on:

1. **The host binds, the server accepts.** `ServerChild` (`Sources/VibeHost/V2/ServerChild.swift`) gets each listener
   from the host: loopback `127.0.0.1:47830`, and the tailnet address when that page is on. Each start of the child
   passes them as inherited descriptors (`--web-listener FD`, `--tailnet-listener FD`), as it passes the app connector
   today. The server's `WebListener` takes an already listening descriptor instead of binding (a new init beside
   `start()`; `Platform.TCP` already has the socket code). The child's end is close-on-exec in the host until the spawn.
2. **When the host binds.** LW-D3 keeps the listener off until `vibeswitcher web`. Two shapes:
   - (a) *On demand:* `web.open` makes the server ask the host to bind (a new host request kind, the user's voice
     checked by the server as today). The host binds, keeps the socket, sends a duplicate to the child over its
     connector (`SCM_RIGHTS`), and closes it again when the server says the web went off (no token alive, `web
     --revoke`). The port is held between two servers whenever the web is on, and free when it's off.
   - (b) *Always:* the host binds loopback at its start and holds it. The server accepts and closes at once while the
     web is off. Simpler (no new host request, no descriptor passing after start), but the port is always held, and a
     closed web answers as a refusal, not "nothing there".
   Recommended: (a). It keeps LW-D3's "off means no listener", and a squatter can't take a port the host holds.
3. **Across a handover** (`Sources/VibeHost/HostHandover.swift`): `State` gains the listeners' descriptors (beside
   `listenFD`, the host's Unix socket), so `descriptors` carries them across the exec and the new image passes them to
   the server it keeps or starts. A fallback keeps them too.
4. **The tailnet listener** needs the host to bind a Tailscale address. Today only the server runs the root-only
   `tailscale` and checks the address (`Web/Tailnet.swift`). Either the host learns that check (more code in the host),
   or the server checks the address and asks the host to bind exactly it, and the host binds only an address in
   `100.64.0.0/10` on a local interface (its own small check). Recommended: the second.
5. **The server refuses to bind** once H1 is in: `NodeWebListener.start()` stays for a scratch node's tests only
   (`--test-web-port`), and the user's node's server takes only what the host gives.

## How big

About **M** (3 to 5 days for a builder, plus review): shared files in `VibeHost` (the server child's launch, the
handover's state, a request kind and its `SCM_RIGHTS` reply), each a port-map row because main shares them;
`VibePlatform` (receiving a descriptor, a listening socket from one); `VibeNode` (`WebListener` from a descriptor, both
listeners, `status`'s web lines); and tests:

- the port stays held across a server restart and a `switch`: a test process can't bind it between two servers;
- a handover carries the listeners;
- a server that gets no descriptor never binds on the user's node;
- an address outside the tailnet range is refused by the host;
- `web --revoke` frees the port, and the next `web` binds it again.

The Mac's node (step 3) has the same shape with its own listener code. It isn't needed for Linux's gate.

## What H1 alone doesn't decide (the user's decisions)

H1 makes the port trustworthy. **Which input a page may send, and into which sessions**, is the user's to decide
(LW-D12: "decided with the user after the spike's numbers"). These wait on the user:

1. **Into which sessions.** The design and decision 20 (D20) say *reply rights type only into confined sessions*. On a
   node only team sessions are boxed (S12), and the user's own sessions aren't. So either page input reaches only
   confined sessions (a worker's or verifier's in its box, not the user's own Claude or shell), or the user accepts page
   input into their own unconfined sessions and the design's line is amended. Recommended: confined only at first, plus
   one-click answers to the engine's cards (which never type into a terminal: the engine acts on a card it built).

   **Decided, 2026-11-25 (the user's answer):** page input reaches every session, the user's own unconfined Claude and
   shell sessions included, as V1 does, on condition that each device holds its own key made at pairing (Touch ID /
   passkey, WebAuthn) and every input message is checked against it. This amends the design's line and D20 ("reply
   rights type only into confined sessions"): [the design's Security](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md#security),
   [the bootstrap path's D20](../superpowers/plans/2026-11-13-v2-bootstrap-path.md#trade-offs-to-accept) and
   [the security architecture's S12 item 16](../superpowers/specs/2026-11-13-v2-security-architecture.md#s12-after-the-bootstrap)
   carry the amendment, their old text kept as superseded. The recommendation above (confined only at first) is not
   what was chosen.
2. **What right a page needs to send input.** A `read`/`draft` token is a bearer secret, and its hash file is writable
   by the user's processes (item 33). Input needs a stronger right, for example a device key made at pairing with
   WebAuthn (the person present, item 31's answer), checked per message. That is stage 4's signed approvals in small. Or
   the user accepts a token with a third right (`type`), with a short life and only on loopback. Recommended: device
   keys, as stage 4 plans.

   **Decided, 2026-11-25 (the user's answer):** device keys, as stage 4 plans, not a bearer token with a third right.
3. **Shape (a) or (b) above**, the host's listener on demand or always. Recommended: (a).
4. **The tailnet page's input**, as the remote access note's decision 1 (plain HTTP on the Tailscale address, or
   `tailscale serve` with HTTPS). Input from a phone over plain HTTP rides on WireGuard alone.

   **Decided, 2026-11-25 (the user's answer):** the phone's page moves to HTTPS through `tailscale serve` (way B), as
   the [remote access note's decision 1](../superpowers/specs/2026-11-20-v2-remote-access.md#decisions-for-the-user)
   and the [push note's decision 1](v2-push-decision.md#decisions-for-the-user) record too. The user accepted that the
   machine's and the tailnet's names go into public certificate logs.

**Order:** H1 itself waits on nothing but decision 3, and can be built first: it removes the squatter for reading
pages too. Page input waits on decisions 1 and 2. A phone's input also waits on decision 4.

**2026-11-25:** H1 is built (shape (a), above), and decisions 1, 2 and 4 are answered. The order that follows is next.

## What can now be built, in order

From the user's answers of 2026-11-25 (decisions 1, 2 and 4 here, and [the push note's](v2-push-decision.md#decisions-for-the-user)).
Each says what it still waits on; none is designed here.

1. **HTTPS on the tailnet page**, through `tailscale serve` (way B). Waits on: HTTPS certificates turned on for the
   tailnet and the machine's `tailscale serve` configuration (the user's Tailscale settings, which the node doesn't
   change today); a slice that replaces way A's bind of the Tailscale address (built 2026-11-20, and held by the host
   since H1).
2. **Device keys at pairing, and every input message checked against its device's key** (Touch ID / passkey,
   WebAuthn). Waits on: a secure context (on the phone, item 1); stage 4's design of the keys, which checks the
   browser's storage first (the security architecture's S11 item 31).
3. **Page input into sessions**, every session, the user's own unconfined ones included: typing into a terminal,
   one-click answers, replies. Waits on: item 2 (H1 is built); from a phone, item 1 too.
4. **Push with the page closed**: the subscription, the VAPID key in the host's vault, the service worker, the
   triggers (as the [push note](v2-push-decision.md#decisions-for-the-user) lists them). Waits on: item 1 (a service
   worker needs HTTPS).

On the Mac, the acting page on loopback opens with one Touch ID for 12 hours (the user's choice of 2026-11-25, in the
Mac lead's record of 2026-11-25 16:27:52; see [the Mac node's spec: the user's voice on the Mac](../superpowers/specs/2026-11-19-v2-node-on-macos.md#the-users-voice-on-the-mac)).

**Still open for the user:** the [remote access note's](../superpowers/specs/2026-11-20-v2-remote-access.md#decisions-for-the-user)
decisions 2 to 5: the remote token's life (8 hours built, or another); masking credentials on remote pages; a second
lock on who is asking (`tailscale whois`, B's login header, or the tailnet ACL alone); getting the address to the phone
(a QR code in the terminal, or typing it). Its decisions 6 (a watched terminal on the remote page) and 7 (the port) weren't
asked either, so a terminal on the phone (item 3 above) still meets decision 6.

### Where the answers meet what v2 already decided or built

Noted for the lead that builds v2, not settled here:

- **The loopback page already acts at `web_acts trust`** ([the web UI design's "Acting from the page"](../superpowers/specs/2026-11-23-v2-web-ui-design.md#acting-from-the-page-a-change-to-the-users-voice-rule),
  the user's choice of 2026-11-23, "for now trust the page completely"): it sends text into any session with no device
  key. The answer above makes a device key checked per message the condition for page input. Its `confirm` level (a
  passkey per request, not built) is the nearest built seam (`PageVoice`).
- **The tailnet page never acts, by rule** (`Web/WebAccess.swift`; the remote access note's "Rights as loopback's:
  `read` and `draft`, never more (LW-D6)"; the web UI design's "keeps today's rule … until the user decides
  otherwise"). The answers open the phone's input over way B with device keys; the built rule stands until that is
  built.
- **Way B and the host's listener as built**: the host binds only `127.0.0.1` and an address in 100.64.0.0/10 on
  port 47830 (H1); the remote access note's B forwards from `tailscaled` to a Unix socket or loopback, and that note
  says the node changes nothing on the network, while B uses the machine's `tailscale serve` configuration.
- **WebAuthn on loopback**: a relying party is a domain name, and the loopback page's one name is `127.0.0.1`
  (LW-D5, any other Host refused); whether browsers take a device key there is to be checked.
- **The Mac's acting page**: the 12-hour Touch ID above isn't in the Mac node's spec on this branch, which records the
  2026-11-20 choice (Touch ID for each state change).
