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
2. **What right a page needs to send input.** A `read`/`draft` token is a bearer secret, and its hash file is writable
   by the user's processes (item 33). Input needs a stronger right, for example a device key made at pairing with
   WebAuthn (the person present, item 31's answer), checked per message. That is stage 4's signed approvals in small. Or
   the user accepts a token with a third right (`type`), with a short life and only on loopback. Recommended: device
   keys, as stage 4 plans.
3. **Shape (a) or (b) above**, the host's listener on demand or always. Recommended: (a).
4. **The tailnet page's input**, as the remote access note's decision 1 (plain HTTP on the Tailscale address, or
   `tailscale serve` with HTTPS). Input from a phone over plain HTTP rides on WireGuard alone.

**Order:** H1 itself waits on nothing but decision 3, and can be built first: it removes the squatter for reading
pages too. Page input waits on decisions 1 and 2. A phone's input also waits on decision 4.
