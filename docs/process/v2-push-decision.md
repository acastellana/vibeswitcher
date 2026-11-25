# Phone push notifications on a node: what has to be decided first

2026-11-21, `v2-small-rows`. The parity table's "Phone push notifications" row (the app's `Sources/VibeCore/WebPush.swift`
and `Web/sw.js`). Nothing is built: each piece below waits on a decision that is the user's.

**2026-11-25: the user answered** decisions 1, 2 and 4, and decision 3 is the Mac lead's call (each "Decided" below,
beside its question). Push with the page closed is wanted. What it still waits on is in
[the H1 plan's build order](v2-h1-plan.md#what-can-now-be-built-in-order).

## What push needs

Web Push reaches a phone whose page is closed: the browser registers a service worker and a subscription with its
vendor's push service; the node encrypts each message for that browser (RFC 8291) and posts it, signed with its own
VAPID key (RFC 8292), to the subscription's endpoint on the vendor's servers, which wake the phone. The app does exactly
this (`WebPush`), to an allow-list of push hosts (`fcm.googleapis.com`, `push.services.mozilla.com`, `push.apple.com`,
`notify.windows.com`).

## Why it can't be built as things stand

1. **A secure context.** A service worker, and so push, needs HTTPS (or `localhost`). The node's tailnet page is plain
   HTTP on the Tailscale address (the remote access note's way A, built 2026-11-20): no service worker can register
   there. Push needs way B, `tailscale serve` with HTTPS, which turns on HTTPS certificates for the tailnet and puts the
   machine's and the tailnet's names in public Certificate Transparency logs. That is the remote access note's
   decision 1 (A or B), still open. *(Answered 2026-11-25: B, below.)*
2. **Outbound requests to a vendor.** The node would post to Google's, Mozilla's, Apple's or Microsoft's servers. The
   payload is encrypted for the browser, but the vendor sees that a message was sent, when, and to which phone. Today
   the node talks to nothing outside the machine but GitHub (`gh`, for the install and the update check).
3. **A VAPID key kept on the node.** A private P-256 key that signs every push. Where it lives (`~/.vibeswitcher`, sealed
   like the other secrets the node keeps, or in the host's vault) and what happens when it leaks (anyone holding it and
   a subscription can push to that phone) needs a decision.
4. **What a push says.** A notification on a phone's lock screen is read by whoever holds it. The page's notifications
   show the first line of a card or a prompt. For push the safe default is no content ("A card needs you on your node"),
   with the words only on the page after it opens.

## Decisions for the user

1. **Way B** (`tailscale serve`, HTTPS, the names in CT logs) for the phone's page: needed for push, and for stage 4's
   signed approvals anyway.

   **Decided, 2026-11-25 (the user's answer):** way B. The phone's page moves to HTTPS through `tailscale serve`; the
   user accepted that the machine's and the tailnet's names go into public certificate logs. The same answer is the
   [remote access note's decision 1](../superpowers/specs/2026-11-20-v2-remote-access.md#decisions-for-the-user) and
   [the H1 plan's decision 4](v2-h1-plan.md#what-h1-alone-doesnt-decide-the-users-decisions).
2. **Push services**: allow the node to post to the browser vendors' push services (the app's allow-list), or not.

   **Decided, 2026-11-25 (the user's answer):** phone push with the page closed is wanted: the node may post encrypted
   pushes to the browser vendors' push services (the app's allow-list).
3. **The VAPID key's home**: the node's root (0600, sealed) or the host's vault.

   **Decided, 2026-11-25:** the host's vault (the Mac lead's call, open to the building lead's better reason).
4. **The lock screen's words**: none (the default proposed), the card's kind only, or its first line as the page shows.

   **Decided, 2026-11-25 (the user's answer):** the first line of the card or prompt, as the open page's notification
   does. The user chose this over kind-only, accepting that whoever holds the phone reads that line. (The default
   proposed above, no words, is not what was chosen.)

Once 1 to 4 are answered (they are, 2026-11-25), the build is: the subscription kept per device token (subscribe and unsubscribe as page
requests in the draft class, never the user's voice), `WebPush` (VibeCore, shared) used for the encryption and the
signature, a service worker that shows only what the push carries, and the same triggers as the page's notifications
(`WebApp/js/notify.js`: a card, a prompt waiting, a lead that stopped, a freeze), sent from the server.
