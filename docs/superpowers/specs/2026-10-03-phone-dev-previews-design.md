# Phone dev-page previews — design

## Goal

From the phone app, open the pages your agents are building (`http://localhost:5173/…` and the like) as
live, interactive pages: tap, scroll, type, hot reload. The list of what can be opened is the
localhost tabs currently open in Chrome on the Mac: if you opened it there, you can open it on the phone.

Out of scope: mirroring or controlling Chrome itself, non-local sites, LAN hosts, other browsers,
servers that only speak HTTPS, Tailscale Funnel (public internet). Nothing changes for people who don't
turn the feature on.

## How it fits together

```
phone ──https──▶ tailscale serve :8444 ──▶ 127.0.0.1:47824  PreviewProxy (slot 1) ──▶ localhost:5173
                 tailscale serve :8445 ──▶ 127.0.0.1:47825  PreviewProxy (slot 2) ──▶ localhost:3000
                 … 4 slots (8444–8447)
phone ──https──▶ tailscale serve :8443 ──▶ 127.0.0.1:47823  existing API: GET /api/devpages, POST /api/preview
```

Each preview gets a whole origin (`https://<mac>.ts.net:8444/`), so a dev server's absolute paths
(`/assets/…`, `/_next/…`, `/@vite/client`) and its hot-reload websocket work unchanged. Path-prefix
proxying (`:8443/preview/5173/…`) was rejected: it needs HTML rewriting and breaks most dev servers.
Pointing Tailscale straight at the dev server was rejected: it skips VibeSwitcher's identity checks and
Vite refuses the `*.ts.net` host name.

### Units

- **`DevPages` (VibeCore, pure):** which URLs qualify. Scheme `http`; host `localhost`, `127.0.0.1`,
  `[::1]` or `*.localhost`; port 1024–65535 and not one of VibeSwitcher's own (47823–47827). Dedupes by
  origin and path, keeps the Chrome tab title.
- **`ChromeTabs` (app):** asks Chrome for its tabs' URLs and titles with AppleScript, only while Chrome is
  running (never launches it). Results are cached for 5 s. The first use shows macOS's one-time
  "VibeSwitcher wants to control Google Chrome" prompt. The Info.plist usage text is updated to say so.
- **`PreviewSlots` (VibeCore, pure):** 4 slots. Each slot has a target (`localhost:5173`), a session token,
  and one-time tickets that remember the path to open. Opening a target that already has a slot reuses it; otherwise the least recently
  used slot is taken, and reassigning a slot invalidates its session token. Tickets are 32 random bytes,
  single use, and expire after 60 s.
- **`PreviewProxy` (app):** one loopback listener per slot. Per request it:
  1. Reads the request head (up to 64 KB).
  2. Requires `Tailscale-User-Login` to be this Mac's own login, like the API does.
  3. Authenticates by either `GET /__vibeswitcher/enter?t=<ticket>`, which sets the slot's cookie and
     redirects to the page's path, or the slot cookie `vs_preview_<port>`. Cookies ignore ports, so each
     slot has its own name. The cookie is `HttpOnly; Secure; SameSite=Strict; Path=/`.
  4. Rejects requests whose `Origin` is a different VibeSwitcher origin (another slot or the app), so one
     dev page can't use your session on another.
  5. Rewrites the request:
     - `Host`, and `Origin`/`Referer` when they're this slot's origin, become `localhost:<port>`, so
       Vite's host check passes.
     - Strips our cookie and all `Tailscale-*` headers.
     - Forces `Connection: close`, so every request is authenticated, at the cost of keep-alive.
  6. Streams the response back, rewriting a `Location: http://localhost:<port>/x` header to `/x`.
     `Upgrade: websocket` requests are piped both ways until either side closes.
  7. Connects to the target the way the browser did: `localhost` tries `::1` then `127.0.0.1`, since Vite
     often listens on `::1` only.
- **API (existing server):**
  - `GET /api/devpages` returns `[{id, title, label, open}]`. Titles and labels are masked like everything
    else sent to the phone.
  - `POST /api/preview {id}` re-reads Chrome's tabs, finds the page with that opaque id (so only a page
    open *right now* qualifies), assigns a slot, and returns `{open: "https://<mac>:<slotPort>/__vibeswitcher/enter?t=…"}`.
    The path travels inside the ticket, not the URL, so the enter link can't be turned into an open
    redirect. The phone never sends a URL.
  - Both use the existing device-token auth, and both refuse unless the new **Allow dev pages** toggle is on.
- **Tailscale:** turning the toggle on maps 8444–8447 with the same `startServing` logic (refusing a port
  that's already serving something else). Turning it, or Phone Access, off removes them. The health check
  covers them too.

### Phone UI

The list view gets a **Dev pages** section under the sessions: the page title, `localhost:5173/path`, and
a dot when a slot is already open. Tapping a row calls `/api/preview` and opens the returned URL with
`window.open`, which opens a browser tab (Android: a Chrome Custom Tab) outside the app. Back returns to
VibeSwitcher. The section is hidden when the toggle is off. When Chrome isn't running it shows "Open the
page in Chrome on your Mac first".

### Mac UI

The Phone Access window gets a toggle, **Allow opening dev pages** (off by default), with one line:
"Localhost pages open in Chrome on this Mac can be opened from your paired phone." The activity log
records `Android phone opened localhost:5173/settings`.

## Errors

| Situation | Result |
| --- | --- |
| Chrome not running | Empty list with a hint. |
| Automation denied | The list says how to allow it (System Settings › Privacy & Security › Automation). |
| Dev server down | The proxy returns a small 502 page: "localhost:5173 isn't answering". |
| Ticket expired or reused | A 403 page: "Open it again from VibeSwitcher". |
| Slot taken over by another page | The old tab gets a 403 page with the same text on its next request. |
| Tailscale port already in use | That slot is skipped, leaving one fewer slot. If no slot can be mapped, the toggle shows the reason. |

## Testing

- **Unit tests (VibeCore):**
  - `DevPages` URL filter: hosts, ports, own ports excluded.
  - `PreviewSlots`: reuse, LRU takeover, token invalidation, ticket single use and expiry.
  - Header rewriting: Host/Origin/Referer, cookie and Tailscale header stripping, `Location` rewrite,
    cross-slot `Origin` rejection.
- **Integration on loopback** (no phone, no real projects):
  - A scratch HTTP and websocket server on a free port, opened in a scratch Chrome tab.
  - Then `curl` against the slot listener with the Tailscale header, through the enter → cookie →
    page → websocket flow, plus every 403/502 path.
- **End to end:** the same scratch server through Tailscale from the Mac's Chrome, then you on the phone.
  A real Vite app, opened read-only, confirms hot reload.

## Limits, stated in the README

- At most 4 previews at once.
- Links in the page hard-coded to `http://localhost:…` won't work on the phone.
- Cookies a dev app sets are shared between slots, because browsers scope cookies by host, not port.
- Dev servers serving HTTPS only aren't supported.
