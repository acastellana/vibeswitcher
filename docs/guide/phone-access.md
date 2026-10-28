# Phone access

See your sessions on your phone, over Tailscale: the list with live status, each session's screen and conversation,
the Today summary, your leads' questions and boards, and notifications when a session needs you or finishes. If you
allow it, reply, press keys and answer a lead's questions from the phone.

It's off by default.

## Set it up

1. Install Tailscale on the Mac and the phone, logged in to the same account. In the Tailscale admin console › DNS,
   turn on HTTPS certificates for your tailnet. VibeSwitcher looks for the `tailscale` command in the app
   (`/Applications/Tailscale.app`), `/opt/homebrew/bin` and `/usr/local/bin`.
2. Settings (⌘,) › **Phone** › turn on **Phone access over Tailscale**. VibeSwitcher runs
   `tailscale serve --bg --https=8443` for its local server, and removes that mapping when you turn it off or quit.
3. **Pair a Phone…** shows a QR code and a code. Scan the QR code with the phone (Tailscale on), or open the address
   shown and type the code. The code has 8 characters, works for 10 minutes and allows 5 tries.
4. On the phone, add the page to your home screen, then tap **Turn on notifications**.

Remove a phone in Settings › Phone, or unpair it from the phone; its access stops at once.

## What the phone shows

- **The list**, with each session's status, and Today.
- **A session**, in two tabs. **Terminal** is the live screen; scroll up for earlier output (up to the last 5,000
  lines). **Conversation** is the session as a timeline from Claude Code's (or Codex's) transcript: your prompts, the
  agent's replies and one row per tool call.
- **Leads**: each lead's open questions (with a proposal's timer, or held), its all-done card, its tasks and its
  scorecard. Paths and transcript text aren't shown, and credentials are masked.
- **Brief me**: the Mac writes the same briefing as its own Brief me button and makes the audio; the phone plays it
  and shows its text. It works while the Mac is locked, since it types nothing. Each source (one phone, say) can start 6
  every 10 minutes.
- **Notifications** (Web Push, encrypted end to end) when a session needs you or finishes. By default they come only
  while you're away from the Mac.

## Replies, key presses and answers

Typing from the phone is a separate switch: **Allow replies and key presses from the phone**, off by default.

- The session view has quick replies (✎ edits the list, kept on that phone) and keys: Esc, 1–3, ↑↓, ⏎, ⌃C.
- While a session shows a question or a menu, a quick reply goes into the box instead of being sent: text doesn't
  answer a menu (use 1–3 or ↑↓ ⏎).
- **Answering a lead.** A lead's question shows its options and a text field; your answer goes through the same path
  as the Mac's question cards.
  It needs replies on, the Mac unlocked and the question still open; an answer is at most 2,000 characters. With
  replies off, the phone says "Replying from the phone is off. Turn it on in VibeSwitcher › Settings… › Phone."
- Nothing is typed while the Mac is locked: the lock is checked again before every batch of keys. Typing into a
  Terminal session needs Accessibility.
- Pausing a session from the phone works even with replies off.

## Dev pages

Turn on **Allow opening dev pages** to open, on the phone, the localhost pages open in Chrome on your Mac
(`http://localhost:5173/…`, `127.0.0.1`, `[::1]`, `*.localhost`). They're live: taps, typing and hot reload work. The
first time, macOS asks whether VibeSwitcher may control Google Chrome.

- Only pages open in Chrome right now can be opened, not incognito ones; your other local servers can't be reached.
- Each page gets its own HTTPS port on your tailnet (8444–8447) through a proxy in VibeSwitcher: 4 pages at most. A
  fifth takes over the least recently used page's port.
- The phone gets each page's cookie from a link that works once, for a minute. A page left unused for 12 hours, or
  opened more than 24 hours ago, has to be opened again from the list.
- Links hard-coded to `http://localhost:…` inside the app won't work on the phone, and dev servers that only serve
  HTTPS aren't supported.

## How it's kept safe

- **Tailnet only.** The server listens on `127.0.0.1:47823`. `tailscale serve` (never Funnel) is the only way in, over
  HTTPS. A request must name this Mac's tailnet address and come from this Mac's own Tailscale account.
- **Paired devices only.** Every request needs a device token, handed out once per pairing. Only a hash of each token
  is kept (`~/.vibeswitcher/remote/devices.json`). Wrong tokens are throttled per source (20 a minute), and a valid
  token is never turned away.
- **Replies are remote control.** Your sessions can run commands, so typing is its own switch. Every pairing and input
  is written to `~/.vibeswitcher/remote/audit.log` and announced on the Mac; Settings › Phone shows its last lines.
- **Minimal data.** Credentials are masked in everything sent to the phone: tokens of common services, webhook URLs,
  private keys, cookies, bearer tokens and passwords in commands. Google's push service relays notifications but
  can't read them. No page content is cached on the phone.
- **The ElevenLabs key stays on the Mac.** A phone's briefing is made on the Mac; the phone gets the text and the
  audio, never the key.

The code: `Sources/VibeSwitcher/PhoneAccess.swift`, `PhoneLeads.swift`, `Tailscale.swift`,
`Sources/VibeCore/RemoteAccess.swift`, `PhonePorts.swift`, `PreviewSlots.swift`, and the web app in `Web/`.
