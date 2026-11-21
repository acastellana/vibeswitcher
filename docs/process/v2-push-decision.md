# Phone push notifications on a node: what has to be decided first

2026-11-21, `v2-small-rows`. The parity table's "Phone push notifications" row (the app's `Sources/VibeCore/WebPush.swift`
and `Web/sw.js`). Nothing is built: each piece below waits on a decision that is the user's.

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
   decision 1 (A or B), still open.
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
2. **Push services**: allow the node to post to the browser vendors' push services (the app's allow-list), or not.
3. **The VAPID key's home**: the node's root (0600, sealed) or the host's vault.
4. **The lock screen's words**: none (the default proposed), the card's kind only, or its first line as the page shows.

Once 1 to 4 are answered, the build is: the subscription kept per device token (subscribe and unsubscribe as page
requests in the draft class, never the user's voice), `WebPush` (VibeCore, shared) used for the encryption and the
signature, a service worker that shows only what the push carries, and the same triggers as the page's notifications
(`WebApp/js/notify.js`: a card, a prompt waiting, a lead that stopped, a freeze), sent from the server.
