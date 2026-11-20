# Remote access: the node's page on the user's phone, over Tailscale

Stage 7's first slice. Written 2026-11-20 from `b335a731`. Read with [the design](2026-11-12-vibeswitcher-2-design.md)
(requirement 4, "Stage 7"), [the security architecture](2026-11-13-v2-security-architecture.md) (S3, S11, "A web
client"), [the live wire contract](2026-11-17-v2-live-wire-contract.md) §2, [the live plan](../plans/2026-11-17-v2-live-protocol-and-web.md)
(LW-D1, LW-D3 to LW-D6, H1) and [the Mac app's phone access](../../guide/phone-access.md).

## What this slice is

The node's page as it is today on `http://127.0.0.1:47830` (read, and draft from slice 3), reached from a phone on the
user's tailnet, **off unless the user runs `vibeswitcher web --tailnet`** in a terminal. Nothing a remote page sends
acts in the user's voice: it reads, and leaves drafts the user confirms on the command line (LW-D6), exactly as the
loopback page does. Reply rights, push notifications, the phone layout and device keys are later slices.

## How the page is reached

Two ways were weighed.

| | A: bind the tailnet address (built here) | B: `tailscale serve` to a socket (the design's requirement 4) |
| --- | --- | --- |
| The listener | a second listener of the server, on this machine's Tailscale IPv4 address and port 47830; never `0.0.0.0` | a Unix socket (or loopback) that `tailscaled` forwards to |
| Transport | HTTP and `ws:` inside WireGuard (encrypted between the two devices; the browser doesn't know that) | HTTPS and `wss:` with a certificate for the machine's `ts.net` name |
| Secure context | no: no service worker, WebCrypto, WebAuthn or push | yes |
| What it changes on the machine | nothing: it reads `tailscale status --json` | the user's `tailscale serve` configuration; HTTPS certificates turned on in the admin console, which puts the machine's and the tailnet's names in public Certificate Transparency logs |
| Who is asking | the peer's address, in Tailscale's ranges; no person | `Tailscale-User-Login` headers, a second lock (the design: "never the only one") |

**This slice builds A**, as the brief asks: it needs no change to the user's network or Tailscale configuration, and
the read-and-draft page uses nothing a secure context gives. **A deviates from the design's requirement 4** ("the
remote one is a Unix socket that `tailscale serve` forwards to … a bind to any other address is refused"), so it is the
user's decision (below). B is what stage 4's signed approvals need anyway (WebAuthn and WebCrypto want a secure
context), so A is a step, not the end: B replaces it before any page holds a key.

### The name: the MagicDNS name, never the IP

The page's one origin on the tailnet is `http://<machine>.<tailnet>.ts.net:47830`, the name `tailscale status` gives
for this machine. The address `http://100.x.y.z:47830` is refused as a name, for one reason: **a phone whose Tailscale
is off still routes 100.64.0.0/10 to its carrier**, whose own CGNAT hosts live there. A page bookmarked by IP would
then send its token, in clear, in its first frame to whatever host has that address on the carrier's network. A
`ts.net` name of a tailnet resolves only through Tailscale's own resolver: with Tailscale off it doesn't resolve, and
nothing is sent. So MagicDNS must be on; when it is off, `web --tailnet` refuses and says so.

### Host and Origin

As LW-D5 on loopback, one exact string each, compared byte for byte:

- **Host** is exactly `<name>:47830` on the tailnet listener (`127.0.0.1:47830` stays the loopback one's): any other
  Host, the IP's included, is 421 with no body. DNS rebinding fails here: a page of `evil.example` made to resolve to
  the tailnet address sends `Host: evil.example:47830`.
- **Origin** on the upgrade is exactly `http://<name>:47830` and `Sec-Fetch-Site`, when sent, `same-origin`: else 403.
  Cross-site WebSocket hijacking fails here.
- The page's **CSP** names its own socket: `connect-src 'self' ws://<name>:47830`.

The two listeners are two origins: a token in one origin's `sessionStorage` is never sent to the other.

### What binds, and where

- The server finds the address and name by running `tailscale status --json` itself, **only a `tailscale` that only
  root can change** (`/usr/bin/tailscale` and the other fixed places, checked as `trustedGit` checks git): a worker's
  `~/.local/bin/tailscale` could otherwise name an address on another network. It runs with a fixed `PATH` and no
  inherited environment, under 5 s.
- It takes the first IPv4 address of `Self.TailscaleIPs` only when it is in 100.64.0.0/10 **and** on one of this
  machine's interfaces (`getifaddrs`), `BackendState` is `Running`, and MagicDNS is on.
- Not found, not running, MagicDNS off, or the address on no interface: refused, with a line saying which. VibeSwitcher
  installs nothing and changes nothing on the network. Under WSL the Linux `tailscale` is the one asked; the Windows
  node's address (mirrored into Linux as another interface) is never used.
- **The peer's address is checked at accept**: only 100.64.0.0/10 and `fd7a:115c:a1e0::/48`, Tailscale's ranges.
  Linux's weak host model accepts a packet for any local address on any interface, so a LAN device that routes
  `100.x.y.z` to this machine's LAN address would otherwise reach the listener; its own source address fails here.

## Pairing over the tailnet

Unchanged in kind from LW-D4, separate in record:

- `vibeswitcher web --tailnet` is the user's voice behind the typed code (S3), recorded in the vault like `web`. It
  prints `http://<name>:47830/#pair=<code>`: the code in the fragment, 16 random bytes, 120 s, once. **The code is
  only ever printed in the user's terminal.** The user carries it to the phone (typing, or a QR code: below).
- A scratch server never opens the tailnet: `--test-web-pair`'s open form (any process of the uid) is refused for it.
- The tailnet's codes and tokens are **another gate**: `<root>/v2/web-tokens-tailnet.json` beside `web-tokens.json`.
  A loopback code or token is never taken on the tailnet listener, nor a tailnet one on loopback.

## Tokens on a remote device

- **8 hours** (loopback: 24 h), at most **4** alive (loopback: 8). A phone pairs again each working day.
- Rights as loopback's: `read` and `draft`, never more (LW-D6). A token at rest is a hash in a file the user's
  processes can write (S11 item 33): a worker can mint itself a tailnet token as it can a loopback one, and gains
  what it already reads. It never gains reach: the tailnet listener binds only when the user opened it, or after a
  restart when a token the user's pairing issued is still alive.
- **`vibeswitcher web --revoke`** drops both gates' codes and tokens and closes every page, local and remote, with
  `revoked` (4403). After it, nothing is bound until `web` or `web --tailnet` again.
- A page whose token ran out is closed at the next sweep (30 s), as on loopback.

## What a remote page may do

What the loopback page may do, less the terminal: read the streams, `chat.page`, `draft` and `draft.clear`. **No
terminal**, watched or typed, on the tailnet listener in this slice (its `hello` lists no `term.*`; the screen refuses
them). Nothing in the user's voice: every such kind is refused `voice` before any handler, as on loopback.

## Does H1 come first?

**No, for this slice.** H1 (the host owns the listener) closes the port squatted while the server is down (LW-D1). On
the tailnet a squatter is a process on this machine: it can bind the address while the server is down, serve its own
page, and read a reconnecting page's token. That token reads what that process already reads, and drafts what the user
confirms in the terminal: the same answer as LW-D1's. H1 stays **required before any input from a page reaches a
session** (the supervisor's decision of 2026-11-20) and before signed approvals, remote ones included.

## Threats

| Threat | Answer |
| --- | --- |
| Another device on the tailnet (a shared node, a family member's phone, a work tailnet) | It reaches the port and the page's public files (no secret in them). It needs a code (128 bits, 120 s, once, printed only in the user's terminal) or a token (256 bits). It can hold connection slots (32): a nuisance, not a reading. Recommended: a tailnet ACL that lets only the user's own devices reach port 47830 (the user's to set); later, B's login header or `tailscale whois` as the second lock. |
| A stolen phone | The phone's lock first. The token lives 8 h, in `sessionStorage`. `vibeswitcher web --revoke` ends every page at once; removing the device in the Tailscale admin console ends its reach entirely. A thief reads what the page shows (sessions, cards, chats) for that time: chats can hold secrets (below). Nothing the page sends answers anything. |
| DNS rebinding | The exact Host (a name, not the IP) and Origin checks. |
| Tailscale off on the phone (the carrier's 100.64/10) | The page's name doesn't resolve without Tailscale: nothing is sent. Why the IP is refused as a name. |
| A LAN device routing to the tailnet address | The peer check at accept: its source isn't in Tailscale's ranges. |
| A fake `tailscale` on `PATH` naming another network's address | Only a root-only `tailscale` is run; the address must be in 100.64/10 and on a local interface. |
| The port squatted while the server is down | LW-D1's answer (above). Closed by H1. |
| A page left open after the user meant to stop | `web --revoke`; the 8 h life; the sweep. |
| Plain HTTP on the tailnet | WireGuard encrypts between the devices; no hop sees the frames. The browser treats it as insecure, which only costs the features B brings. |

## Built in this slice (part 2)

- `vibeswitcher web --tailnet`: the user's voice; the tailnet's own gate, listener and token file; the root-only
  `tailscale` lookup; MagicDNS name only; Host, Origin and CSP for that name; the peer check; 8 h and 4 tokens;
  `web --revoke` over both; no terminal; refused on a scratch server's open form. Tests with a fake lookup and a
  scratch root; nothing runs the real `tailscale`.

## Decisions for the user

1. **A or B** for this step: accept the direct bind to the tailnet address (a deviation from requirement 4, built
   here, off by default), or wait for `tailscale serve` (HTTPS, which turns on HTTPS certificates for the tailnet and
   puts the machine's name in public certificate logs).
2. **The remote token's life**: 8 hours (built), or another.
3. **Masking credentials on remote pages**: the Mac's phone masks tokens, keys and passwords in what it sends; the
   node's chats scrub only URL credentials. Port the Mac's masking for remote pages before the user leaves a phone
   paired, or accept that a stolen phone reads what the transcripts hold for up to 8 h.
4. **A second lock on who is asking**: `tailscale whois` on each peer (its login must be the machine's own), or B's
   login header, or the user's tailnet ACL alone.
5. **Getting the address to the phone**: a QR code drawn in the terminal (a small encoder, no dependency), or typing
   it. The code lasts 120 s either way.
6. **A watched terminal on the remote page**: none in this slice. The loopback page may watch (LW-D12's amendment);
   whether a phone may too.
7. **`status` showing the tailnet listener**: it needs a field in the wire's `node.web` shape, so the integrator's
   regeneration of the page's vectors and embedded files. Until then `web --tailnet` prints its state when run.
