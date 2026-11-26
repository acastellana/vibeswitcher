# Device keys, the Devices list, QR pairing, the 12-hour unlock and per-change biometrics

Status: **design, for an independent security review before anything is built** (2026-11-26, branch
`v2-device-keys-design` on `v2-no-terminal` `1cbcf3b6`). Nothing here is built. Code is quoted as it is at `1cbcf3b6`.

It turns the user's answers of 2026-11-25 and the lead's calls N1 to N8 into one buildable design: each device holds
its own key made at pairing; every message that acts is checked against it; devices stay paired until removed from a
Devices list; a phone is added by a QR code from an unlocked page; an unlock by Face ID or Touch ID lasts up to 12
hours; each guarded change needs a biometric of its own with the change shown; and the phone reaches the node over
HTTPS through `tailscale serve`. The decisions it builds on are in [the H1 plan](../../process/v2-h1-plan.md#what-h1-alone-doesnt-decide-the-users-decisions),
[the remote access note](2026-11-20-v2-remote-access.md#decisions-for-the-user) (decisions 1 to 7),
[V2 without a terminal](../../process/v2-no-terminal.md#decisions-it-waits-on) (N1 to N8), [the push note](../../process/v2-push-decision.md#decisions-for-the-user)
and the Mac lead's record of 2026-11-25 16:27:52 (541E258F: "one Touch ID … after which the page acts with no prompt
for up to 12 hours on loopback"; BCECD1F3: a root-owned record written at install).

Two readers: you (the first page) and the Linux-side lead and reviewers (the rest, exact). Facts about other people's
software (browsers, Tailscale) are marked **verified** with a source, or **to be measured** with the slice that
measures them and what this design does if the answer goes the other way.

## For you, in one page

**What changes for you.**

- **Each browser you use becomes a device**, listed in This node › Devices with its name and when you added it. It
  stays there until you remove it. No more pairing again after a reload, after 12 or 24 hours, or after every restart.
- **Opening the page after a while asks for Face ID or Touch ID once.** That unlock lasts up to 12 hours on that
  device. Then every click acts at once: answers, approvals, messages, starting and ending sessions, and typing into a
  session's terminal, on the desktop and on the phone.
- **A few changes always ask again**, each with what it will do shown first: updating or rolling back the node,
  installing the agents' hooks, a project's first config accept or changed guard rails, the working policy, review
  floors and models, adding a plugin, adding a device, turning phone access on, and Claude Code's self-update switch.
  On the Mac the Touch ID window itself names the change.
- **Adding your phone:** This node › Devices › Add a phone shows a QR code. Scan it, use Face ID on the phone, check
  that the three words on the phone are the ones your computer shows, and approve with Touch ID on the computer.
- **Phone access** is one button (Turn on phone access) that sets up `tailscale serve` for you, and Turn off undoes it.
- **Setup on Linux** still ends with one confirmation in the install's own terminal (your first browser). On the Mac
  it is Touch ID.

**What you are protected from.** A program running on your computer as you (an agent session, a script it wrote) can
no longer act through the page: it holds no device key, it can't add a device of its own without your biometric on a
device you hold, and it can't approve a guarded change. Another person on your tailnet, another user of your
computer, and anyone watching the network can't act either. A lost phone is locked by Face ID, and removing it from
the Devices list ends its access at once.

**What you still carry (you accepted the first on 2026-11-25).**

1. **While a device is unlocked (up to 12 hours), anything that can read that open page's memory, or drive that
   browser, can act as that device** for everything except the guarded changes. On a phone that is very hard. On a
   desktop it depends on the system: on Linux without its debugging lock (your WSL machine has none) a program running
   as you can read a browser's memory; on the Mac it can't.
2. **Someone who holds your phone while its page is unlocked** acts as you until you remove the phone or the unlock
   ends; Face ID (or the phone's passcode) is still asked for each guarded change.
3. **On Linux, the device list can't be kept anywhere a program running as you can't write.** After the node's host
   restarts (a reboot, a crash), your devices are let back in when your phone next unlocks and agrees the list is the
   one it last saw; with no phone, or if the list changed, one confirmation in a terminal ([for you to decide](#for-the-user-to-decide), 2).
4. **A program that takes over the node itself** (S11 item 3: it restarts the node from files it changed) owns
   everything, as today.

**Five questions for you** are at the end ([For the user to decide](#for-the-user-to-decide)): whether a desktop
unlock should survive closing the last tab; how Linux lets devices back in after a restart; whether guarded changes on
a Linux desktop should be approved on your phone; where the push key lives on Linux; and one about the Mac's unlock
dialog.

## What is protected, and from whom

**The property protected:** nothing acts as the user from a page (a request the command line would take only in the
user's voice, S3; a byte typed into a session; a change to the device list) unless it carries a signature of a key
that a device the user paired holds now, inside an unlock the user gave on that device with a biometric; and nothing
guarded acts without a fresh biometric for that change on such a device.

| Who | Stopped, limited or accepted | How |
| --- | --- | --- |
| **A team session, or any process of the user's uid that is not the user**, that holds no device's unlock key | **Stopped** from acting through the page, adding its own device and approving a guarded change | no bearer token acts any more; every client frame is signed by an unlock key the vault certified; the device list is written only by the server, app-only in the vault (`VaultV2Handler.answer`'s `caller == .app`); an add needs an existing device's biometric over the new key |
| the same, that can **read the open page's memory or drive its browser** during an unlock | **Accepted** (the user, 2026-11-25), **limited**: up to 12 h, that device's acts only, never a guarded change, every act recorded with the device's id, ended by removal | the unlock key is in the page's memory (desktop) or the browser's storage (phone); see [Open to attack](#open-to-attack) 1 |
| the same, that **writes the user's files** | **Limited** on Linux, **stopped** on the Mac | Linux: the vault is memory only (S7), so the device list's copy on disk is a hint a worker can rewrite; after a host end it is re-admitted only on a witness or a terminal confirmation ([where the node keeps the devices](#where-the-node-keeps-the-devices)). Mac: the vault is sealed under a Keychain key (`VaultStorage`) |
| the same, that **becomes the host** (S11 item 3, T3) or replaces the command line (T12) | **Accepted**, as S11 says today | not this design's to close; signed releases (S12 item 12) |
| **A process of another uid** | **Stopped** | the loopback port needs a device's signature; the serve backend takes only tailscaled's connections; Unix sockets check the uid (S1's principals). Under WSL's mirrored networking, every Windows process (S11 item 34) is in this row |
| **Another tailnet device** | **Stopped** | the peer's Tailscale login must be the machine's own (decision 4); then it still needs a device key, and a new device needs an existing one's biometric |
| another device **of the same Tailscale login** | **Limited** | it passes the login check; it can reach the page's public files and hold connection slots; it can't act or enrol without the user's approval |
| **Someone holding the locked phone** | **Stopped** | the phone's lock; the page's unlock needs Face ID; a push shows the first line of a card, masked (the user accepted the first line) |
| **Someone holding the unlocked phone** | **Accepted** while its page is unlocked; **stopped** for guarded changes (unless they know the passcode, which WebAuthn's user verification takes in place of Face ID) | removal from another device ends it at once |
| **A network observer** | **Stopped** | loopback stays on the machine; the tailnet is WireGuard plus TLS from `tailscale serve`; push payloads are encrypted for the browser (RFC 8291). **Accepted:** the machine's and the tailnet's names in Certificate Transparency logs; the push vendor sees that a push was sent |
| **A stolen backup of the state folder** | **Stopped** | no key that acts rests on disk: passkeys are in the authenticators, unlock keys in browsers; the folder holds public keys only. A backup put back (an old `devices.json`) is a rollback, held as any rewrite is |

**What this design does not protect:** anything against root or what is one step from it (S1, S11 item 1: WSL
interop on voids every lock); the command line's own path (S3 is unchanged and keeps its "Doesn't promise"); the text
the lead and workers write (S11 items 12, 17); the user approving a biometric prompt they didn't expect (prompt
fatigue); a device's own authenticator being taken (an Apple account whose iCloud Keychain syncs the passkey).

**S11 items it closes for the page** (S12 item 11 says signed approvals "close 13 to 15 and 17 for approvals"): for a
request made **from a device**, item 13 (driving the user's shell gains nothing on the page path), 14 (PATH and
aliases) and 15 (the command line's binary) no longer apply, since the page path never runs the command line; item
33 (the token file) closes, since no token is taken. Item 17 (text the user reads) is narrowed only for guarded
changes on the Mac, where the system dialog shows the server's own text. Items 13 to 15 stay open for the command
line, which stays the second way in.

## Every path to acting as you

Each row: the path, the check that guards it, and the test that will prove it (planned names; each moves to a `Held
by:` line in the security architecture when its slice lands). **Writers of the device list come first: with
`attestation: 'none'` (as `WebApp/js/passkey.js` already registers) the node can't tell a real authenticator from a
software one, so every guarantee rests on who can write the list.**

| # | Path | Check | Test |
| --- | --- | --- | --- |
| **Writers of the device list** | | | |
| W1 | The first device on Linux: `web.open`, then `web.confirm` in the install's own terminal (N2) | S3's voice rule and typed code; the words of the page's enrolment, derived from a nonce the server picks after the key arrives; one window, at most 4 knocks; a wrong word ends the window | `FirstDeviceTests.onlyTheConfirmedEnrolmentIsAdded`, `FirstDeviceTests.wordsCantBeGround`, `FirstDeviceTests.aSessionsProcessCantConfirm` |
| W2 | A device again on Linux after every device was removed or lost | as W1 (the same kinds) | as W1 |
| W3 | The first device on the Mac: the server's Touch ID naming the page's words | `ApprovalVoice` (LocalAuthentication, the server's own text), off while `MacPageUnlock.measured` is false | `MacDeviceTests.theDialogNamesTheWordsTheServerDerived`, `MacDeviceTests.offUntilMeasured` |
| W4 | A phone added by QR (`device.add.open`, `device.enroll`, `device.add.approve`) | an unlocked device's signed request opens a 120 s window; the enrolment only on the serve gate, from a remote peer of the machine's login; the approval a guarded change by the opening device's biometric over the new key and its words; the vault checks that proof itself | `AddPhoneTests.anEnrolmentOnLoopbackIsRefused`, `AddPhoneTests.theApprovalBindsTheNewKey`, `AddPhoneTests.anApprovalForOtherWordsIsRefused`, `VaultDeviceTests.anAddWithoutAValidProofIsRefused` |
| W5 | Removal (`device.remove`, or Remove all) | an unlocked device's signed request, any device; or `web.revoke` (the command line's or a page's) | `DeviceRemovalTests.aRemovedDevicesConnectionsCloseAtOnce` |
| W6 | Rename (`device.rename`) | an unlocked device's signed request; a name is shown inert and never alone in a prompt (the words and the date go with it) | `DeviceListTests.aNameIsShownInert` |
| W7 | The vault itself | app-only: `VaultV2Handler.answer` (`caller == .app`, through the connector) | `VaultDeviceTests.onlyTheAppWritesDevices` |
| W8 | A handover (`switch`) | the vault crosses in sealed memory (S8); no file | `VaultDeviceTests.devicesAndUnlocksSurviveAHandover` |
| W9 | A host end on Linux: the devices' hint file `<root>/v2/devices.json` read back | never authority: held until a witness or a terminal confirmation (below) | `DeviceRestoreTests.aPlantedDeviceIsHeld`, `DeviceRestoreTests.aRolledBackFileIsHeld`, `DeviceRestoreTests.noWitnessMeansTheTerminal` |
| W10 | A same-uid process writing `devices.json` while the host runs | the server never reads it while the host runs; written only from the vault | `DeviceRestoreTests.theFileIsNeverReadWhileTheVaultHoldsTheList` |
| W11 | The upgrade from today's tokens and `web_acts` | no device is made from a token, a level or a confirmed pairing; every page starts locked | `DeviceMigrationTests.noDeviceIsMadeFromAnOldToken` |
| W12 | The scratch server's flags (`--test-web-pair`'s open form, `--test-web-terminal`, `--test-web-terminal-watch`) | refused with `--node` (`ServerArguments`); the device kinds' test forms (an enrolment without a terminal) are scratch-only flags of the same rule | `DeviceKeysTests.theUsersNodeRefusesTheTestEnrolment` |
| **Channels a message can arrive on** | | | |
| C1 | The loopback WebSocket, `127.0.0.1:47830` and (N7) `localhost:47830` | Host and Origin exact, the same name in both (`NodeWebListener`); every client frame signed (below) | `DeviceFrameTests.anUnsignedFrameClosesTheConnection`, `LocalhostTests.hostAndOriginMustNameTheSameName` |
| C2 | `[::1]:47830` | held by the host, accepting nothing (S11 item 32 noted it was free) | `HostWebListenTests.theHostHoldsIPv6LoopbackToo` |
| C3 | The serve backend (a Unix socket under the node root, or loopback TCP) | the peer must be tailscaled (to be measured: root on Linux); `Tailscale-User-Login` the machine's own; the peer address not this machine's; Host and Origin the `ts.net` name; every frame signed | `ServeGateTests.aPeerThatIsntTailscaledIsClosed`, `ServeGateTests.anotherLoginIsRefused`, `ServeGateTests.thisMachineAsAPeerIsRefused` |
| C4 | Way A's tailnet listener (the Tailscale address, `TailnetWeb`) | retired once C3 exists; the host refuses the `tailnet` place from then on | `HostWebListenTests.theTailnetPlaceIsRefusedOnceServeIsOn` |
| C5 | Terminal binary frames (input, resize) | each frame signed in the connection's one sequence; refused on a locked connection | `DeviceFrameTests.aTerminalFrameOutOfSequenceClosesTheConnection` |
| C6 | The command line on the server's socket | unchanged: S3's rule and typed code (Mac: Touch ID per state change) | (S3's) |
| C7 | The host's socket | unchanged (S2, S4): takes no page kind | (S2's) |
| C8 | A lead's tool server's posts | unchanged: the `.lead` seal (EN-D10); never the user's | (S3's) |
| C9 | A plugin's page (its own port, `HostWebListen.Place.page`) | another origin: the exact Origin refuses it; it can't reach the page's storage | `LocalhostTests.aPluginPagesOriginIsRefused` |
| C10 | Another tab of the same origin (`BroadcastChannel`) | same origin only; the unlock key passes as a non-extractable `CryptoKey`, never as bytes | `devicekey.test.js` (`shares only a non-extractable key`) |
| C11 | A dev server on `localhost:<port>` asking a passkey for rpId `localhost` | the node checks `clientDataJSON.origin` exactly `http://localhost:47830` | `WebAuthnTests.anAssertionFromAnotherPortIsRefused` |
| C12 | Push (outbound only) | nothing comes in; the payload is the masked first line | `PushPayloadTests.theFirstLineIsMasked` |
| **Trust on first use** | | | |
| T1 | The first device (W1, W3) | the terminal's voice, or Touch ID asked by the server | (W1, W3) |
| T2 | A new device's passkey, `attestation: 'none'` | an existing device's biometric over the new key and its words (W4) | (W4) |
| T3 | The machine's Tailscale login and name | read by the root-only `tailscale` (`Tailnet.find`'s rule) | `ServeGateTests.theLoginComesFromTheRootOnlyTailscale` |
| T4 | The phone page's TLS certificate | the browser's own check of the `ts.net` certificate (no TOFU) | none needed |
| T5 | The page's own code | the node serves only embedded files (`WebAssets`); the page is as trustworthy as the node | (LW-D9's) |
| **Where a key or a token rests** | | | |
| K1 | A passkey's private key | in the authenticator (Secure Enclave, Windows Hello, a security key; synced by the platform where it syncs) | none (the platform's) |
| K2 | Devices' public keys and records | Linux: the vault (memory) and the hint file; Mac: the vault (Keychain-sealed) | (W7 to W10) |
| K3 | An unlock's private key | the page's memory on a desktop; the browser's storage, non-extractable, on a phone ([for you to decide](#for-the-user-to-decide), 1) | `devicekey.test.js` (`never exports the key`) |
| K4 | An unlock's public key | the vault only, never a file | `VaultDeviceTests.unlocksAreNeverWritten` |
| K5 | Challenges, windows, words' nonces | the server's memory, once, 120 s | `UnlockTests.aChallengeIsTakenOnce` |
| K6 | The first-device address and the QR's address | no secret in either: a plain address | `AddPhoneTests.theQRCarriesNoSecret` |
| K7 | The VAPID push key | the host's vault (the push note's decision 3; on Linux memory only: [for you to decide](#for-the-user-to-decide), 4) | (the push track's) |
| K8 | Push subscriptions | the vault, per device, dropped with it | `DeviceRemovalTests.aRemovedDevicesSubscriptionIsDropped` |
| K9 | The serve configuration | tailscaled's (root's); the vault records the one entry the node set | `PhoneAccessTests.offRemovesOnlyTheNodesOwnEntry` |
| K10 | Today's `web-tokens.json`, `web-tokens-tailnet.json` | deleted at the upgrade, never read | `DeviceMigrationTests.theTokenFilesAreRemovedAndNeverRead` |

That is 39 rows: 12 writers of the list, 12 channels, 5 trusts on first use and 10 resting places. Two rules run
through every row: each client frame is signed ([The key](#the-key)), and the guarded kinds always ask again
([The unlock](#the-unlock-and-what-it-never-covers)).

## The key

### The three kinds compared

| | **A. A passkey asserted per message** | **B. A passkey for the unlock, then a non-extractable WebCrypto key per unlock signs each message** (chosen) | **C. A bearer token bound to the device** |
| --- | --- | --- | --- |
| What a message carries | a WebAuthn assertion | an ECDSA P-256 signature | the token |
| Person present per message | yes | at the unlock, and at each guarded change | no |
| UX | a Face ID or Touch ID sheet per click and per keystroke; WebAuthn needs a user gesture per call, so terminal typing can't be built | one biometric per 12 hours; guarded changes ask again | none |
| Replay, reorder, move | each assertion is bound to its own server challenge (a round trip per message) | bound by the signed bytes (below) | a token is replayable anywhere it is taken |
| What reading the page gives | nothing beyond what the user approves next | the unlock key: acts as that device until the unlock ends (accepted) | the token: acts until it ends, from anywhere; and today's file of hashes is writable by the uid (S11 item 33) |
| Cost per message, phone | a system sheet (about a second of the person's time) | one ECDSA sign, sub-millisecond (to be measured, slice 5) | none |
| Fits the decisions | no (it breaks "acts with no prompt for up to 12 hours", 541E258F) | yes | no: the user chose device keys over "a token with a third right" (the H1 plan's decision 2) |

**Chosen: B**, with A kept for exactly the guarded changes. The passkey is the device's key made at pairing; it never
leaves the authenticator and proves the person at each unlock and each guarded change. The unlock key is made fresh at
each unlock in the page, non-extractable (`crypto.subtle.generateKey({name: 'ECDSA', namedCurve: 'P-256'}, false,
['sign'])`), and certified by that unlock's passkey assertion; every frame is checked against it. So every message is
checked against a key the device's pairing key vouched for within 12 hours.

On the Mac's desktop page the person is proved by the server's own Touch ID (LocalAuthentication, `ApprovalVoice`),
not a browser passkey ([The Mac](#the-mac)); the unlock key is the same.

### The handshake

1. **The server speaks first** on a WebSocket (this amends the live wire contract's §1, "the server says nothing
   before it"): `{"v":1,"kind":"challenge","conn":"<32 random bytes, base64url>"}`. `conn` names this connection
   alone; the server forgets it when the connection closes.
2. **A page with a live unlock** answers `{"v":1,"id":"0","kind":"auth","args":{"device":"<id>","unlock":"<key id>",
   "client":"webapp","assets":"…","sig":"<b64url>"}}`, `sig` over `"vibeswitcher-auth-v1\n" + origin + "\n" + conn`.
   The server looks the unlock up in the vault's record it caches (as `ActingPages` caches today), checks its device is
   listed, its origin is this listener's, it hasn't ended, and the signature. Admitted, `hello` as today with `auth`
   `{device, rights, until}`. This replaces the contract's `pair` and `token` (§2's "When device keys come, `auth`
   gains `device` and `sig`"; `pair` and `token` go, not stay: a reading token is still a bearer secret in storage).
3. **A page without one** answers `auth` with no credential and is a **locked connection**: its `hello.kinds` are
   `unlock.begin`, `unlock`, `device.enroll` (during a window), and nothing else; no stream, no read. A locked page
   shows the lock screen only.

### The unlock

1. `unlock.begin` `{device}` → `{challenge}`: 32 random bytes, 120 s, once, for this connection.
2. The page makes a fresh unlock key and asks `navigator.credentials.get` with `rpId` the listener's name,
   `allowCredentials` the device's credential, `userVerification: 'required'`, and as challenge
   `SHA-256("vibeswitcher-unlock-v1\n" + origin + "\n" + conn + "\n" + challenge + "\n" + SPKI(unlock key))`.
3. `unlock` `{device, spki, credential, authenticatorData, clientDataJSON, signature}`. The server, then the vault
   again before it records (VibeCore's verifier, so the host checks it too), checks, failing closed on anything else:
   the challenge is live, this connection's and unused; `clientDataJSON` parses as exactly one JSON object whose `type`
   is `webauthn.get`, `challenge` the recomputed bytes, `origin` exactly this listener's origin, and `crossOrigin`
   absent or false; `rpIdHash` is SHA-256 of this listener's rpId; the flags have UP and UV; the signature checks
   under the device's stored key over `authenticatorData || SHA-256(clientDataJSON)`; a non-zero sign count must
   exceed the stored one. The vault records `{device, keyId: SHA-256(spki), spki, origin, since, until: since + 12 h}`,
   at most 3 live per device (a phone's home-screen app and its browser tab keep separate storage), the oldest dropped.
4. The connection is then the device's, as in the handshake's step 2.

### What is signed, so a message can't be replayed, reordered, or moved

Every client text frame after `auth` is an envelope, and **the server parses the request only from the signed
bytes** (no canonical form to get wrong):

```json
{"v":1,"kind":"signed","body":"{\"v\":1,\"seq\":7,\"id\":\"12\",\"kind\":\"send\",\"action\":\"6f1d…\",\"args\":{…}}","sig":"<b64url r||s>"}
```

`sig` is ECDSA P-256 with SHA-256 over `"vibeswitcher-frame-v1\n" + origin + "\n" + conn + "\n" + body`.

- **Replay** on another connection fails: `conn` is new per connection. On the same connection it fails: `seq` must
  be exactly one more than the last (it starts at 1 after `auth`).
- **Reorder** fails on the same rule; a gap, a repeat or a bad signature closes the connection (4401), and the page
  reconnects and signs again. A retry after a reconnect is a new frame with the same `action`: `Requests` answers a
  repeated action as before (rule 8), so nothing is done twice.
- **Another session or card** fails: the session, the card and its `seen` are in `args`, inside `body`.
- **Another node or origin** fails: `origin` is signed, and the unlock is bound to one origin at the unlock (a node
  never certified another node's unlock key; a phone paired to two nodes unlocks each).
- **Anything unparseable** (two `body` fields, a body that isn't one JSON object, a `seq` that isn't an integer, a
  frame that isn't `signed`) closes the connection.

Terminal input and resize become one binary type (6), so they share the sequence: `[6][stream: 4][seq: 8][sig: 64]
[type: 1, the old 1 or 3][payload]`, signed over `"vibeswitcher-term-v1\n" + origin + "\n" + conn + "\n"` then the
stream, `seq`, type and payload bytes. Types 1 and 3 from a page are refused as today (`TerminalRelay.binary`'s watch
rule) and close the connection on the user's node.

This amends the contract's §8 "When signed approvals exist": `proof {device, nonce, sig}` on a request becomes the
envelope on every frame, and "checked by the host (rule 7)" becomes **checked by the server** for each frame (the
server holds the connection and is the app, S2), with the presence proofs (unlocks, guarded changes, device adds)
checked **again by the host's vault** before it records anything.

### What it costs on a phone

One `crypto.subtle.sign` per frame (P-256), 64 bytes of signature (88 characters in a text frame); the server's verify
is one P-256 check (swift-crypto, already a dependency: `WebTokens` uses its `SHA256`). The page batches keystrokes
into one frame per 8 ms at most. The cost on a real phone and the effect on the terminal's echo budget (16 ms median,
33 ms p95, the contract's G3) are **to be measured** in slice 5; if a sign costs more than 4 ms at p95, the page
batches per 16 ms.

## Where the node keeps the devices

This is the spine: a device in the list can act after one biometric, and the node can't tell a real authenticator
from a worker's.

**What is kept.** Per device: `id` (16 random bytes), `name`, `place` (`loopback` or `tailnet`), `origin`, `rpId`,
`presence` (`passkey`, `macTouchID`, or `terminal`: [the desktop page](#the-desktop-page-and-passkeys)'s fallback),
the credential's id and P-256 key (COSE EC2, `alg` -7 only), its sign count, its backup flags, `addedAt`, `addedBy`
(a device id, `terminal` or `touchid`), and for a phone its Tailscale login and node name. Per unlock: as above. And
`epoch`, a number raised by every add or removal, and `digest`, SHA-256 of the list's canonical bytes at that epoch.

**Who writes it.** Only the server, through `LeadVaultV2` requests the vault answers for the app alone
(`VaultV2Handler.answer`: `caller == .app`, through the connector), as `addPageToken` and `addActingToken` are today.
New requests: `addDevice` (with the proof: the terminal's recorded action for W1, the server's Touch ID record for W3,
or the approving device's assertion for W4, which the vault verifies itself), `removeDevice`, `renameDevice`,
`addUnlock` (with its assertion, verified), `dropUnlocks`, `devices`.

**The Mac:** the vault is sealed on disk under a Keychain key only the host's binary gets without asking
(`VaultStorage`); the list lives there and survives restarts. No file.

**Linux:** the vault is memory only (S7, "memory only; lost"). Nowhere on Linux before strong mode can the node keep
something that survives a host end and that a process of the uid can't write: a key file is no secret (S7's "Why"),
systemd's user credentials and a TPM answer any process of the uid, and the user keyring is possessed by every process
of the uid. So:

- **While the host runs**, the vault is the authority. A handover (`switch`) carries it in sealed memory (S8).
- **The hint file** `<root>/v2/devices.json` (0600, written from the vault after each change, never read while the
  host runs) holds the public records, `epoch` and `digest`. Never an unlock.
- **After a host end** the server reads the hint file and holds every device: shown on the lock screen as "held after
  the restart", none may unlock. It lets them back in on one of:
  1. **A witness**: every device keeps the `{epoch, digest}` it last saw (the page stores it with its unlock key, and
     refreshes it at each change it sees). A device on the **serve gate** (C3: a remote peer through tailscaled, its
     storage on another machine) that unlocks puts its `{epoch, digest}` into the unlock's challenge. When they equal
     the file's, the file's list is admitted whole; when they don't, only that device is admitted, and every device
     shows "Your device list on the node changed while it restarted" with what differs, each to Keep or Remove.
  2. **The terminal**: `vibeswitcher web` lists the held devices (each name, date, place and words) and the user types
     the code to admit them (S3's voice).

  A loopback device is never a witness on Linux: its browser's storage is the uid's to write.

What it does and doesn't hold, honestly:

- **Planted device** (a worker adds its key to the file and restarts the host): held; the witness's digest differs.
  Stopped while the witness check is sound ([Open to attack](#open-to-attack) 2, 3).
- **Rollback** (a worker puts back an older file): stopped when the witness saw the later epoch; **not stopped** when
  the witness was offline for the change that is rolled back (a device removed while the phone was away comes back).
  Limited: a removed phone should also be removed from the tailnet (the Devices list says so and links the admin
  console), and then it reaches nothing.
- **Deletion** of the file: every device is gone after the next host end; the user pairs again (W2). A denial.
- **Forced restarts** (S7: a worker restarts the host at will): each one locks every device until the phone unlocks or
  the terminal confirms. A denial, shown in `status` as today's restart notices.
- **No phone paired**: every host end needs the terminal (a weekly line). The choices are [for you to decide](#for-the-user-to-decide), 2,
  with the root-owned record of BCECD1F3 as the precedent for another way.

Strong mode (S12 item 5, the vault's key file outside every sandbox) later keeps the list across a restart against
confined sessions; the witness stays for unconfined processes.

## The first device, and adding a phone

### The first device

**On Linux (N2):** the install line ends by running `vibeswitcher web` in its own terminal. Amended `web.open`
(`KindSpec`, still `.terminalOnly`, its reason now "it opens a first-device window: a page would enrol itself"; the
user's voice behind the code from the action id, recorded) opens a **first-device window**: 10 minutes
(`PagePairing.waits`), at most 4 pages may knock, and prints a plain address (`http://localhost:47830/`, or
`http://127.0.0.1:47830/` if N7's review says no). **No code in the address**: the fragment code goes (the rule:
nothing secret in a URL).

1. The page that opens it, locked and with a window open, offers "Set up this browser". It makes its unlock key and a
   passkey (`navigator.credentials.create`, `userVerification: 'required'`, `attestation: 'none'`, ES256 only, as
   `passkey.js`'s `createOptions`), its challenge `SHA-256("vibeswitcher-enrol-v1\n" + origin + "\n" + conn + "\n" +
   window + "\n" + SPKI(unlock key))`, and sends `device.enroll` `{window, spki, attestationObject, clientDataJSON,
   name}`.
2. The server checks the registration as the unlock's assertion (type `webauthn.create`, origin, rpIdHash, UP and UV,
   the COSE key P-256 and nothing else, attestation format `none`), then **picks a fresh nonce for that enrolment and
   only then derives its words**: three words of `PagePairing.words` from `SHA-256(nonce || credential key || spki)`.
   A worker can't grind keys for chosen words: each try is a knock, and the words are fixed by a nonce that comes
   after the key (24 bits, at most 4 knocks a window). The page shows its words.
3. `web.pairing` (still `.terminalOnly`) lists each knock's words; amended `web.confirm` `{window, words}` (still
   `.terminalOnly`, reason unchanged: "it pairs a page: a page would pair itself") adds the device whose words were
   typed, and records its unlock: the page acts at once. A wrong word or a second confirmation ends the window, as
   `webConfirm` does today; two knocks with the same words get a new nonce each.

**On the Mac (541E258F):** no terminal. A locked page on loopback with no device offers "Set up this Mac's browser";
`device.enroll` `{spki, name}` makes the server ask Touch ID (LocalAuthentication, the server's text: "let the
browser page showing *amber river kite* act as you on this Mac for 12 hours, and remember it"). Off until measured
([The Mac](#the-mac)).

### Adding a phone (decision 5)

1. On an unlocked device: This node › Devices › Add a phone. The page sends `device.add.open` (signed; an unlock may:
   it adds nothing). Refused while phone access is off. The server opens an **add window**: 120 s, at most 4
   enrolments, one window at a time, closed by the opening device's connection closing.
2. The page shows a QR code of `https://<machine>.<tailnet>.ts.net:47830/#add`: the address and nothing secret.
3. The phone opens it over the serve gate (C3: the peer is tailscaled, the login is the machine's own, the peer
   address isn't this machine's), makes its unlock key and passkey (Face ID), and sends `device.enroll` `{window:
   "add", …}` as above. `device.enroll` for an add window is taken **only on the serve gate**; on loopback it is
   refused. The phone shows its words and "Approve on your computer".
4. The opening device sees each enrolment: its words, the name the phone gave, its Tailscale login and node name (the
   server's `tailscale whois` of the peer address, by the root-only binary). "Approve with Touch ID" is a guarded
   change: `device.add.approve` `{window, enrolment, words}`, its digest over the new credential key, the new unlock
   key and the words. The vault verifies the approving device's assertion over that digest before it adds the phone
   and records its unlock. The phone is unlocked at once.

**What stops a session from showing or scanning its own QR.** Showing: opening a window needs a signed frame of an
unlocked device; and a window gives nothing by itself. Scanning: the enrolment is taken only from a remote peer
through tailscaled, so a process on this machine can't enrol (C3's checks); one on another machine of the user's login
can enrol, and is then one more line the user is shown with words that aren't the phone's. Approving: a fresh
biometric on the opening device over that exact key; a session holding the unlock key (the accepted risk) still can't
make it, and on the Mac the system dialog shows the words the server derived, not the page's.

### `web.open` and `web.confirm`, amended (to implement)

- `web.open`: `.terminalOnly("it opens a first-device window: a page would enrol itself")`; args none (no `tailnet`:
  the phone is `device.add`'s); result `{url, window, expiresIn}`, the url without a fragment. `keepsResult` stays
  false.
- `web.pairing`: `.terminalOnly` as today; result `{state, knocks: [{words, at, name}]}`.
- `web.confirm`: `.terminalOnly` as today; args `{window, words}`; adds the knocking device whose words equal the
  typed ones (normalised as `webConfirm` does), records its unlock, closes the window; refuses, closing the window, on
  a word that matches no knock.
- New, `.acts` (an unlocked device's signed frame): `devices`, `device.add.open`, `device.rename`, `device.remove`,
  `device.lock`, `phone.off`, `guard.begin`. New, `.guarded` (below): `device.add.approve`, `phone.on`. New, a locked
  connection's (a new sender, `webLocked`, taken only before `auth` succeeds): `unlock.begin`, `unlock`,
  `device.enroll`.

## The unlock, and what it never covers

**Twelve hours on every device**, from the biometric, at most. What the unlock **releases**: the device's connections
are admitted (reads, drafts, watching terminals); its signed frames of every `.acts` kind are taken as the user's,
recorded with `via` naming the device (today's `ActingPages.via` gives the token's id; it gives the device's id and
name); typing into terminals once [the phone's path](#the-phones-path) slices land; and asking `guard.begin`.

**What ends it early:** the device removed (anyone's), Lock now on the device (`device.lock`), Remove all or
`vibeswitcher web --revoke`; the page losing its key (on a desktop, its last tab closed or reloaded:
[for you to decide](#for-the-user-to-decide), 1; on a phone, the browser clearing its storage, which Safari does after
7 days without a visit: to be measured, slice 2); a host end on Linux (unlocks are never written down); a bad
signature or a sequence gap (the connection closes; the unlock stands, since only the key's holder can sign).

**Never covered by it: the guarded kinds.** Each needs a biometric of its own, the change shown before the prompt, on
the desktop and on the phone (N1, N8):

| Guarded kind | Today | Source |
| --- | --- | --- |
| `build.switch`, `build.seal`, and the `update` kind D1 adds (update, rollback) | `.terminalOnly` | N1; `KindSpec` |
| `hooks.install` (alone, or as an item of `approve`) | `.terminalOnly` | N1; `PageRequests.pageMayApprove` |
| `config.accept` when `ConfigHoldStore.pageNotSame(card)` isn't empty (a first accept, changed rails or floor, a snapshot this vault didn't seal), alone or in `approve` | refused from a page | N1 |
| `set` of the 13 settings whose `page` is `.terminalOnly` (`lead_mail`, `policy`, `verifier_model`, `security_audit_model`, `max_workers`, `floor_sensitive_paths`, `floor_strict_paths`, `floor_audit_finders`, `floor_merge_policy`, `floor_risk_lines`, `floor_risk_model`, `floor_audit_sample_percent`, `floor_verifier_different`), and every plugin setting (`PluginSettings`) | `pageSetRefusal` | N1; `NodeSettings` |
| `plugin.add` (`plugin.inspect` becomes a read an unlock may ask) | `.terminalOnly` | N1 |
| Claude Code's self-update switch (the E8 kind to be added) | not built | N8 |
| `device.add.approve`, `phone.on` | new | **the design's call**: each widens the node's reach, as `web.open`'s reason says ("a page would widen its own reach") |
| the journal's acknowledgment (the N6 kind to be added) | `status --ack` | **the design's call**, stricter than N6's words: it clears marks that say a start or a request nobody explained |

Still the terminal's: `start` (no server is there to ask), `web.open`, `web.pairing`, `web.confirm`.

**How a guarded change is asked.** `guard.begin` `{request}` (signed): the server builds the change's text itself
(as `ApprovalVoice.reason` builds the Mac's dialog from the card, never the board) and its digest, SHA-256 over the
kind, the arguments, each card's `seen` and each batch item's; it answers `{text, digest, challenge}` (120 s, once).
The page shows the text whole and inert, then asks the passkey with challenge `SHA-256("vibeswitcher-guard-v1\n" +
origin + "\n" + conn + "\n" + challenge + "\n" + digest)`, and sends the request with the assertion. At the act, on
the server's queue, the digest is built again from what is there now: different, refused `changed`, as
`seenStands` does. The vault checks the assertion before it records the action. **On the Mac** the server asks Touch
ID with that text instead, so the system dialog shows the change (`KindSpec.Recorded.phrase` and the card's text).

## The desktop page and passkeys

**N7: the loopback page answers on `localhost:47830` as well as `127.0.0.1:47830`.** A passkey's rpId must be a
domain, and `localhost` is the one browsers take on plain HTTP (**verified** for Chromium, ["Origins that support
WebAuthn"](https://chromium.googlesource.com/chromium/src/+/main/content/browser/webauth/origins.md): "HTTP pages
served from localhost"; Firefox treats `localhost` as a secure context; **Safari on `http://localhost` to be
measured**, slice 13). What must go with it:

- **Host** exactly `localhost:47830` or `127.0.0.1:47830`; **Origin** on the upgrade exactly `http://localhost:47830`
  or `http://127.0.0.1:47830`, **and naming the same host as Host**; `Sec-Fetch-Site`, when sent, `same-origin`. Any
  other name, a missing or repeated header: 421 or 403 as today (`NodeWebListener`, `WebRequest`).
- **DNS rebinding** fails as before: a page of `evil.example` resolved to 127.0.0.1 sends its own name as Host.
  `localhost` itself: Chromium and Firefox answer it on loopback without asking DNS; Safari asks the system, where
  `/etc/hosts` is root's (to be measured).
- **IPv6.** `localhost` may resolve to `::1` first, and `[::1]:47830` isn't held today (S11 item 32): any process of
  the uid could bind it and take the page. So `HostWebListen` gains the `loopback6` place (`::1`, port 47830 only,
  held from the first `web` with the IPv4 one, accepting and closing; `HostWebListen.refusal` today allows only
  `127.0.0.1` for loopback). A host that can't bind `::1` (no IPv6) holds nothing there, and then nothing else can
  either.
- **Other ports of `localhost`.** rpId `localhost` covers every port, so a session's dev server on
  `http://localhost:3000` (the pages `session.ports` links) can ask for an assertion; it gets one with its own origin,
  which the node refuses (C11). It can still put an unexpected Touch ID or Windows Hello sheet on the screen
  ([Open to attack](#open-to-attack) 4). Same-site but not same-origin: no storage or `BroadcastChannel` is shared.
- **The CSP** names the socket of the name the page was served under (`WebSecurityHeaders.policy(host:)`).
- **Which page is canonical.** Devices with a passkey live on `localhost`; `127.0.0.1` keeps serving a page that
  reads and says "Open this page at localhost" (its bookmarks keep working).

**What a Linux desktop has as an authenticator.** On this Linux machine (WSL2, mirrored networking) the browser is a
Windows one, and Windows Hello is its platform authenticator; a native Linux Chrome has none of its own but takes a
phone (the cross-device flow) or a security key, and synced passkeys from a password manager. To be measured, slice
13; the design needs only a UV-capable ES256 credential.

**If the reviewer says no** (N7's fallback): the loopback page stays on `127.0.0.1` alone. On Linux the desktop device
has `presence: terminal`: each unlock is `vibeswitcher web` and the typed code (today's daily A1/A2), its guarded
changes stay the terminal's; the phone is unaffected. On the Mac nothing changes: its presence is the server's Touch
ID either way.

## The phone's path

**HTTPS through `tailscale serve`, set by the node (N5).** Turn on phone access is `phone.on`, a guarded change whose
text says what it changes ("Tailscale will serve this page at https://<name>:47830 to your tailnet's devices; HTTPS
certificates put the machine's name in public logs"). The server runs only the root-only `tailscale` (`Tailnet.find`'s
rule: fixed path, fixed `PATH`, no inherited environment, 5 s), reads `tailscale serve status --json` first, and
refuses (saying why) when port 47830 is already served by anything it didn't set, when the output doesn't parse, or
when HTTPS certificates or MagicDNS are off. It then sets one entry, HTTPS on 47830 to the node's backend, records
that entry in the vault, and reads the status back to see exactly it. `phone.off` (an unlock may: it narrows) removes
that one entry only and drops the tailnet's devices' connections. To be measured, slice 17: that `tailscale serve`
takes HTTPS on 47830 (**verified** that Serve, unlike Funnel, no longer limits its ports in the current CLI,
[Tailscale's Funnel docs](https://tailscale.com/kb/1311/funnel-cli) and [Serve docs](https://tailscale.com/kb/1312/serve),
to check against the installed version), and which operator rights a user's process needs (on Linux, `tailscale set
--operator=$USER` once, with `sudo`: then a setup line, E6).

**The backend, and who can reach it.** Way A's bind of the Tailscale address (`TailnetWeb`, the host's `tailnet`
place) is retired. The backend is a socket the host holds (H1's rule: the host binds, the server accepts):

- **Preferred: a Unix socket** under the node root, whose peer must be tailscaled: on Linux `SO_PEERCRED` uid 0, so no
  process of the user's uid connects (**to be measured**: Serve's `unix:` targets appear in Tailscale's sources but
  are to be checked in a release; and the Mac's Tailscale variants may not run tailscaled as root).
- **Otherwise loopback TCP** on a port the host holds, the peer's socket owner read from the kernel's table
  (`/proc/net/tcp`'s uid column on Linux) and required to be tailscaled's. If neither can be told, **the phone path
  doesn't open**: a backend any process of the uid can reach is a forged-header channel.

**The tailnet-login check (decision 4).** Serve adds identity headers and strips incoming ones of the same names
(**verified**, [Serve docs](https://tailscale.com/kb/1312/serve); the exact header names to be measured, slice 18).
The gate requires `Tailscale-User-Login` (or the name measured) to equal the machine's own owner's login from the
root-only `tailscale status --json`; a missing header (a tagged device: Serve sends none) is refused. The forwarded
peer address must not be one of this machine's own Tailscale addresses, so a process on this machine reaching its own
`ts.net` name through Serve is refused. Host is exactly `<name>:47830`, Origin exactly `https://<name>:47830`, the CSP
`connect-src 'self' wss://<name>:47830`.

**Credentials masked on every remote page** (decision 3), before any phone stays paired: every string the serve gate
sends (chat items, cards, sessions' commands and prompts, board records, notices, settings' values) through
`Redaction.secrets(in:)` (VibeCore, the Mac app's masking), and the terminal's bytes through a `TerminalMask` that
also applies it on what the screen shows. Slice 16 lands before slice 19 offers Add a phone.

**Typing into terminals, only once keys and HTTPS exist** (LW-D12 amended; the remote access note's decision 6):
`TerminalRelay.Mode` gains `type` for the user's node: a connection of an unlocked device types through the host's
`input` as the app's composer does, each frame signed (type 6); the host's parser keeps answering the program's
queries (`TerminalReplies.strip` unchanged); a locked or watch-only connection stays `watch`. On loopback first; on
the serve gate after slices 16 to 19. LW-D12's sentence "Typing stays the user's voice: `vibeswitcher send`" is amended
to "typing is an unlocked device's signed frame, or `vibeswitcher send`".

**Push** (the push note's decisions): one subscription per device, made after its unlock, kept in the vault with the
device, dropped with it; the payload the card's or prompt's first line through `Redaction.secrets(in:)`, never a code,
an address with a secret, or a token.

## The Devices list and removing a device

This node › Devices: each device's name (editable), kind, where (this computer, or the phone's Tailscale name),
added when and by which device, last unlocked, unlocked now or not, and Remove. "This device" is marked. Add a phone;
Remove all (today's `web.revoke`, a second click to confirm).

**Removing a device, at once**, in the server's turn that takes `device.remove`, before it replies:

1. The cache drops the device and its unlocks (as `ActingPages.set` lowers at once, before the vault answers), so no
   later frame of it is taken; the vault's write follows in order (`ActingPages.change`'s shape).
2. Every connection admitted as the device is marked (no act, no watch), its terminal streams dropped
   (`LiveHub.endTerminals`, as `WebRequestScreen.end` does), then closed with 4403 `removed`.
3. **In-flight messages:** a request of the device not yet done is checked again on the queue right before `voiced`
   (today's re-check of `acts` after `PageVoice.confirm`, generalised): refused `actsEnded`. A request already recorded
   in the vault and being done (text being typed) finishes: it can't be untyped. A guarded change waiting for its
   biometric is refused when the assertion comes.
4. **Pushes:** its subscription is dropped from the vault and any push queued for it is dropped; one the vendor has
   already taken may still arrive (said in the confirmation).
5. A removed phone: the page says "Also remove it from your tailnet" with a link to the admin console.

Removing the device you are on signs you out. Removing the last device is allowed; then W2 or W3 again.

## What is retired, and how an install moves over

| Retired | Where it is built | What replaces it |
| --- | --- | --- |
| `web_acts` (`off`, `confirm`, `trust`) and its `lowersOnly` rule | `NodeSettings` (`web_acts`, `page: .lowersOnly`), `LeadVaultV2.PageActs.level`, `setPageActs`, `Requests.pageSetRefusal`'s `.lowersOnly` case | the device key: acting needs an unlocked device (the lead's call: "the page on the same machine keeps acting as today until device keys are built, then requires the device's key") |
| the `confirm` level and its seam as built | `ActingPages.confirmBuilt`, `PasskeyNotBuilt`, `NoPageVoice`, `PageVoice` | `guard.begin` and the assertion on guarded kinds; every other act needs no seam |
| page tokens, 24 h and 8 h, and their files | `WebTokens` (`life`, `tailnetLife`, `web-tokens.json`, `web-tokens-tailnet.json`), `ActingPages.admits`/`issued`, `LeadVaultV2.addPageToken` | the handshake's signed `auth` |
| the pairing secret and confirmed pairings, 12 h | `ActingPages.confirmed`/`watches`/`acts`, `PagePairing`'s token phrase, `LeadVaultV2.addActingToken` | the unlock |
| the fragment code | `WebAccess.openCode`, `url(port:code:)`, `#pair=` | a plain address; `PairingMask` and `TerminalMask` keep masking `pair=` for old transcripts |
| way A's tailnet listener and gate | `TailnetWeb`, `Tailnet.find`'s bind, `HostWebListen.Place.tailnet` | the serve backend |
| the terminal-led passkey words | `WebApp/js/acting.js` (`acPasskeyOrigin`, `vibeswitcher web --localhost`), `i18n.js` and `i18n-es.js` `pk…` words ("Añadir una llave de acceso (pedida desde tu terminal)"), `passkey.js`'s header ("when the terminal asks (`vibeswitcher web --passkey`)") | Set up this browser, Unlock, Add a phone |
| "a web client is never the user's voice" | the security architecture's principals, S3's table rows for `draft` and `web.*`, LW-D6 | a device's signed frame is the user's for `.acts` kinds, as recorded with its id |

**An existing install moves over** in the cut-over slice (20): the new build deletes both token files unread; the
vault's `PageActs` keys are dropped at its first start; every open page is closed with 4403 and reopens locked;
`web_acts`, if set, is ignored and `status` says once "acting from the page now needs a device: run `vibeswitcher web`
once" (Linux) or "open the page and use Touch ID" (Mac). No device is made from anything the old build left (W11). A
build before the cut-over taking a handover from after it refuses the vault's format at its probe (as H1's format 2
does), so a rollback can't run the old trust with the new record.

## The Mac

**The amendment to the Mac node's spec** ([the user's voice on the Mac](2026-11-19-v2-node-on-macos.md#the-users-voice-on-the-mac),
"LocalAuthentication, asked by the server per state change"), as 541E258F decided: *for a request that comes from an
unlocked device's page on loopback, the user's voice is that device's unlock, which the server asked Touch ID for once
(its text naming the page's words) and which lasts up to 12 hours; per-request Touch ID stays for every state change
from the command line, and for every guarded kind from any page, its text the change.*

- The Mac's desktop device has `presence: macTouchID`: its unlock is `unlock` `{device, spki}` with no assertion, and
  the server asks LocalAuthentication (`ApprovalVoice`'s authenticator) with the text "let the page showing *amber
  river kite* act as you for 12 hours" (the words from a nonce the server picks after the key, as above). One dialog
  at a time: a second `unlock` while one is asked refuses both and says "two pages asked at once" (today's
  `contested`).
- Guarded kinds from a Mac page: the server's Touch ID with the change's text, never the browser's passkey, so the
  dialog shows the change (stronger than the passkey path: a page's script can't change it).
- A phone paired to a Mac node uses its passkey as on Linux.
- **Refusal constants stay off until measured; no build task of this track switches one on:**
  `NodeSystem.approvalMeasured`, `HostImages.isCheckedMacNode` and the `NodeSystem.macUnbuilt` refusal (the 16:27:18
  decision), and the new `MacPageUnlock.measured`. So the Mac's slices build and test the code with a fake
  authenticator (`ApprovalLintTests` forbids the real dialog in tests) and change nothing a user runs.
- The Mac node's vault survives restarts (Keychain), so the Mac needs no hint file or witness.

## Build order

Each slice is about 30 minutes to 2 hours, in dependency order. "Here": what this Mac proves by tests (shared code and
the Mac's arm, in a scratch clone). "Linux, read only": what can only be read here. **Review**: needs its own
independent security review before it is offered. "Beside": may run at the same time as the slices named, touching no
function they touch. New gate constants (`DeviceKeys.usersNode`, `PhoneAccess.usersNode`, `TerminalTyping.usersNode`,
`MacPageUnlock.measured`) are made false and switched on only by their own one-line slice, after the reviews, by the
lead.

| # | Slice | Files | Here | Linux, read only | Review | Beside |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | The frame envelope and P-256 verify: signed bytes, `seq`, `conn`, the binary type 6, fail-closed parsing | `Sources/VibeCore/V2/DeviceProof.swift`, tests | all | none | yes (with 2, 3) | 2, 3, 4, 5 |
| 2 | The WebAuthn assertion check: `clientDataJSON` exact, `authenticatorData`, flags, sign count; vectors recorded from real browsers | `Sources/VibeCore/V2/WebAuthn.swift`, fixtures | all; measures Safari's 7-day storage rule on a phone | none | yes | 1, 3, 4, 5 |
| 3 | The registration check: `attestation: 'none'`, a CBOR subset for COSE EC2 P-256 only | `WebAuthn.swift` (its own type), tests | all | none | yes | 1, 2, 4, 5 |
| 4 | The vault's devices and unlocks: the requests, app-only, the handover's format, the vault verifying proofs with 2 and 3 | `Sources/VibeCore/V2/LeadVaultV2.swift` (new requests beside `PageActs`), `Sources/VibeHost/V2/VaultV2Handler.swift` | all | none | yes | 1, 2, 3, 5 |
| 5 | The page's key module: unlock key, envelope, `BroadcastChannel`, witness storage; the phone signing bench | `WebApp/js/devicekey.js`, its node tests | the module; the bench on a real phone | none | with 1 | 1 to 4 |
| 6 | The handshake: `challenge` first, `auth` by unlock, locked connections, behind `DeviceKeys.usersNode` | `Sources/VibeNode/Web/WebAccess.swift` (`admit`), `WebSocketConnection.swift` | on a scratch server | none | yes | 13, 16 |
| 7 | Signed frames in `WebRequestScreen.text` before `Principal.route`; `Principal.page` with a device | `WebAccess.swift` (`WebRequestScreen`), `Server/Principal.swift` | on a scratch server | none | yes | 13, 16 |
| 8 | Signed terminal frames (type 6) in `TerminalRelay.binary`, still watch-only on the user's node | `Sources/VibeNode/Live/TerminalRelay.swift` | on a scratch server | none | with 7 | 11, 13, 16 |
| 9 | The unlock kinds: `unlock.begin`, `unlock`, `device.lock`; `KindSpec` gains `.guarded` and the `webLocked` sender | `Server/KindSpec.swift`, `Server/PageRequests.swift`, a new `Server/DeviceRequests.swift` | on a scratch server | none | yes | 13, 16, 17 |
| 10 | The first device: amended `web.open`, `web.pairing`, `web.confirm`, `device.enroll` in a window | `Server/PageRequests.swift` (`webPairing`, `webConfirm`), `Server/WebRequests.swift`, `Web/PagePairing.swift`, the command line's `web` | the logic on a scratch server | S3's voice rule on the user's node (the cgroup), the install line's ending | yes | 13, 16, 17 |
| 11 | The Devices list: `devices`, `device.rename`, `device.remove`, Remove all; the page's This node › Devices | `DeviceRequests.swift`, `WebApp/js/views/node.js` | all | none | with 12 | 8, 13, 16 |
| 12 | Removal's effects: connections, streams, in-flight, push subscriptions | `WebAccess.swift` (`WebRequestScreen.end`), `Server/NodeLive.swift` | all | none | yes | 13, 16 |
| 13 | N7: `localhost` beside `127.0.0.1`, the `loopback6` place, CSP per name; measures each browser's passkeys on `http://localhost` and the desktop's authenticators | `Web/NodeWebListener.swift`, `Sources/VibeCore/V2/HostWebListen.swift`, `Sources/VibeHost/V2/HostWebListeners.swift`, `Web/WebSecurityHeaders.swift` | all | the host's `::1` bind on Linux | **yes, the N7 review** | 6 to 12 |
| 14 | Guarded changes: `guard.begin`, the digest again at the act, the vault's check; the guarded table in `KindSpec` and `NodeSettings` | `KindSpec.swift`, `PageRequests.swift` (`pageChecks`, `pageSetRefusal`), `Settings/NodeSettings.swift` | all | none | yes | 16, 17 |
| 15 | Each guarded kind wired, one slice each: `hooks.install`, the 13 settings and plugin settings, `config.accept` and `approve` past `pageNotSame`, `plugin.add`, `build.switch`/`build.seal` (the `update` kind and N8's and N6's kinds are their own tasks first) | each kind's request file | all | `build.switch`'s handover on Linux | with 14, once | one another |
| 16 | Credential masking on the serve gate (`Redaction.secrets`, terminal screen masking) | `Web/WebAccess.swift` or a new `Web/RemoteMask.swift`, `Live/TerminalRelay.swift` (the mask), `Web/PagePairing.swift` (`TerminalMask`) | all | none | yes | 6 to 15 |
| 17 | Phone access on and off: `phone.on`, `phone.off`, the serve status parse; measures `tailscale serve`'s ports, `unix:` targets and operator rights | `Server/PhoneAccess.swift`, `Web/Tailnet.swift` | with a fake `tailscale` | the real `tailscale` on Linux | yes | 9 to 16 |
| 18 | The serve gate: the host's backend socket, the peer check, the login and peer-address checks, Host and Origin for `https://<name>:47830`; retires way A | `HostWebListen.swift` (a `serve` place), `HostWebListeners.swift`, `Server/TailnetWeb.swift` (becomes the serve gate), `NodeWebListener.swift` | the gate's checks with injected peers | `SO_PEERCRED` and `/proc/net/tcp` on Linux | yes | 14, 15 |
| 19 | Add a phone: `device.add.open`, enrolment on the serve gate only, `device.add.approve` | `DeviceRequests.swift`, `WebApp/js/views/node.js`, the QR encoder in `WebApp/js` | all | the serve gate on Linux | yes | 22 |
| 20 | **The cut-over: the first slice that acts differently for a user.** On the user's node acting needs an unlocked device; tokens, `web_acts` and confirmed pairings retired; the migration; the lock screen | `WebAccess.swift`, `ActingPages.swift` (removed), `WebTokens.swift` (removed), `NodeSettings.swift`, `LeadVaultV2.swift`, `WebApp/js/acting.js`, `i18n*.js` | all but the user's node | the user's node's first start after it on Linux | yes | none (it lands alone) |
| 21 | The Linux restart: the hint file, the witness, the terminal re-admission | `DeviceRequests.swift`, `Server/ServerStart.swift`, the command line's `web` | the logic with a scratch vault | the host end and the real restart on Linux | yes | 22, 23 |
| 22 | Typing into terminals on the user's node (LW-D12 amended): loopback first, then the serve gate after 16 to 19 | `TerminalRelay.swift` (`Mode.type`), `Server/NodeLive.swift`, `WebApp/js/terminal.js` | on a scratch server, a fake tty | the user's node on Linux | yes | 21 |
| 23 | The Mac: the unlock and guarded changes by the server's Touch ID, `MacPageUnlock.measured` false | `Server/ApprovalVoice.swift`, `DeviceRequests.swift` | with a fake authenticator | none (the Mac arm) | yes | 21, 22 |
| 24 | The leftovers: the page's words, `passkey.js`'s header, the docs' rules (S3's table, the principals, LW-D6, LW-D12, the contract's §1, §2, §8, §9) | `WebApp/js/*`, the docs | all | none | no | any |

Slice 21 lands before slice 19 is offered to a user, so a phone's pairing survives a restart from its first day.

## Open to attack

1. **The desktop browser shows one change and signs another.** On a desktop, a process of the uid that drives the
   browser (an extension written into the profile, a debugging port, ptrace where there is no Yama, as on this WSL
   machine) can run script on the page's origin: use the unlock key (accepted) and also show an innocent text while
   the passkey's sheet (which shows only the site's name) approves the guarded change the server described. The node
   can't tell. The Mac closes it with the server's own dialog; Linux desktops don't ([for you to decide](#for-the-user-to-decide), 3).
2. **The witness after a Linux host end.** It rests on three things not proven on paper: that only tailscaled reaches
   the backend (3); that a removed device's comeback by rollback is rare enough (a phone offline when the removal
   happened); and that a worker can't make the phone's page store a digest it chose (it would have to send the phone
   a page: the page's code is the node's own embedded files, so only a worker that became the host, S11 item 3).
3. **The serve backend as a channel.** If any same-uid process can connect to the backend, it can forge the login
   header and the peer address, then enrol during an add window, or be the witness. The design refuses to open the
   phone path unless the peer is told to be tailscaled; whether that can be told on each platform and Tailscale
   variant (root on Linux; the Mac's App Store and standalone variants) is unmeasured.
4. **rpId `localhost`.** Every dev server a session runs shares the rpId: it can't use an assertion (the origin is
   checked), but it can put Touch ID or Windows Hello sheets on the screen at will and train the user to approve them;
   and a browser that answers `localhost` from DNS, or a `::1` the host can't hold, would hand the page to a squatter.
5. **The Mac's unlock dialog.** A process of the uid can ask for an unlock whenever it likes; the dialog names three
   words the user must compare with their page. A user who approves without comparing unlocks the process's key for
   12 hours. One dialog at a time stops a race, not the habit.
6. **Synced passkeys.** A phone's passkey syncs (iCloud Keychain; the backup flags say so), so the device is "this
   passkey", on every device of that account. An account taken over carries the passkey, still needing the tailnet,
   the login check and the node's list to use it.

## For the user to decide

Only what the answers of 2026-11-25 and the lead's calls don't settle.

1. **Should a desktop unlock survive closing the last tab or a reload?** "Up to 12 hours" (541E258F) allows either.
   Keeping the key only in the open page's memory means a program running as you can't take it from disk; the cost is
   Touch ID again after the last tab closes, after a reload, and after the page reloads itself for a new build.
   Keeping it in the browser's storage (non-extractable) lets it survive; the cost is that, as far as is known,
   browsers keep such keys in the profile's files, which any program running as you reads (and on WSL any Windows
   program, S11 item 31), so for the rest of the 12 hours such a program could act as that browser. **Recommended:
   memory only on a desktop; the phone keeps its key in its storage** (its storage is out of other programs' reach).
2. **How Linux lets devices back in after the node's host ends** (a reboot, a crash: S7 keeps no list a program
   running as you can't write). **Recommended: the phone as witness, else one terminal confirmation** (above): no
   terminal when a phone is paired and the list didn't change; costs a weekly terminal line on a desktop-only setup,
   and a device you removed while your phone was away can come back after a rollback. Other ways: (b) a root-owned
   record written with `sudo`, as you chose for the Mac's fingerprints (BCECD1F3): it pins the first device, but each
   later change would need `sudo` to be safe against rollback, so it costs a password prompt per device added or
   removed; (c) pair every device again after each restart (a terminal line and a QR each time); (d) trust the file,
   **not recommended**: a program running as you could add its own device and restart the node.
3. **Guarded changes on a Linux desktop** (N1 says the desktop and the phone). On a Linux or WSL desktop a program
   running as you that drives the browser can show you one change while the passkey approves another (Open to attack
   1); the Mac's dialog and a phone don't have this. **Recommended: from a Linux desktop, a guarded change is approved
   on your phone** (the desktop asks, the phone shows the change and asks Face ID), **or in the terminal when no phone
   is paired.** Costs: a second device for those few monthly changes on Linux.
4. **The push key on Linux** (the push note's decision 3 put it in the host's vault, "open to the building lead's
   better reason"). Linux's vault is memory only, so every host end changes the key, every phone's subscription stops
   working, and pushes stop until each phone opens the page. **Recommended: on Linux, a 0600 file under the node's
   root until strong mode** (its vault key file, S12 item 5), the Mac's in its vault. Cost: a program running as you
   could send your phone notifications with words of its choosing; a notification only opens the page, which shows
   the real state and asks the unlock as always.
5. **The Mac's unlock dialog words.** Comparing three words in the Touch ID dialog with the page is what keeps another
   program from taking the unlock (Open to attack 5). **Recommended: keep the words** (the same three words the
   phone's pairing shows). Cost: one glance at each unlock; without them the dialog says only "this Mac's browser".
