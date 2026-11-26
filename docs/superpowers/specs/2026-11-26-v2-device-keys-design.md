# Device keys, the Devices list, QR pairing, the 12-hour unlock and per-change biometrics

Status: **design, reviewed** (2026-11-26, branch `v2-device-keys-design` on `v2-no-terminal` `1cbcf3b6`). An
independent review found it "sound with changes" (findings I1 to I6, notes N1 to N10, its rulings on the open items);
this revision applies them and the lead's calls on them. Nothing here is built. Code is quoted as it is at
`1cbcf3b6`.

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
measures them and what this design does if the answer goes the other way. The two questions the review left to the
user are answered (2026-11-26): **after a Linux host end, a pinned phone brings the devices back** (A64D1FC7), and
**`tailscale serve` is set by one `sudo` line at setup** (CB1AC032, superseding N5). Nothing is left for the user
([For the user to decide](#for-the-user-to-decide)).

## For you, in one page

**What changes for you.**

- **Each browser you use becomes a device**, listed in This node › Devices with its name and when you added it. It
  stays there until you remove it. No more pairing again after a reload, after 12 or 24 hours, or after every restart.
- **On your computer, the page opens without a prompt and shows everything.** The first time you act after a while
  (an answer, a message, typing into a session's terminal) it asks Touch ID or Windows Hello once; that unlock lasts
  up to 12 hours, or until you close the page's last tab. **On your phone**, opening the page after a while asks Face
  ID once, and that unlock lasts up to 12 hours.
- **A few changes always ask again**, each with what it will do shown first: updating or rolling back the node,
  installing the agents' hooks, a project's first config accept or changed guard rails, the working policy, review
  floors and models, adding a plugin, adding a device, turning phone access on, the journal's acknowledgment, and
  Claude Code's self-update switch. On the Mac the Touch ID window itself names the change. **From a Linux or Windows
  desktop these are approved on your phone** (it shows the change and asks Face ID), or in a terminal when you have no
  phone yet: the desktop's own fingerprint sheet can't show what it approves.
- **Adding your phone:** This node › Devices › Add a phone shows a QR code. Scan it, use Face ID on the phone, check
  that the three words on the phone are the ones your computer shows, and approve: on the Mac with Touch ID; on Linux
  on a phone you already added, or (your first phone) in a terminal. Only a phone or tablet can be added this way. On
  Linux the page then shows one `sudo` line to run, so this phone can vouch for your devices after a restart.
- **Phone access** needs one `sudo` line once per computer, which the page shows (it sets up Tailscale's serving so
  your account can't change it). After that, Turn on phone access just works, and Turn off closes it. On a Mac node
  phone access stays off until it is measured.
- **Setup on Linux** still ends with one confirmation in the install's own terminal (your first browser). On the Mac
  it is Touch ID.

**What you are protected from.** A program running on your computer as you (an agent session, a script it wrote) can
no longer act through the page, short of stopping the node and taking its address (2, below): it holds no device key, it can't approve a guarded change, and it can't add a device
of its own without your Touch ID on the Mac, Face ID on a phone you added, or a terminal confirmation on Linux. Another
person on your tailnet, another user of your computer and anyone watching the network can't act either. A lost phone
is locked by Face ID, and removing it from the Devices list ends its access at once.

**What you still carry (you accepted the first on 2026-11-25).**

1. **While a device is unlocked (up to 12 hours), anything that can drive that browser or read its memory can act as
   that device** for everything except the guarded changes. On a phone that is very hard. On a desktop it depends on
   the system: on WSL the Windows programs of your own Windows account can (a Linux program reaches the Windows
   browser only through interop or `/mnt/c`, which decision 2 turns off); on the Mac a program can't read a browser's
   memory, but one that drives it (an extension, a debugging port) can.
2. **A program that stops the node and takes the desktop page's address** can show its own page at your bookmark
   until the node is back, and the next unlock you give that page is its own. On Linux this costs it about what
   taking over the node costs (4); on the Mac it stays a limit. The phone's address is held by the root-owned service
   your one `sudo` line installs. The node's own service-worker rule bounds how long such a page lingers (about a day);
   it doesn't close it.
3. **Someone who holds your phone while its page is unlocked** acts as you until you remove the phone or the unlock
   ends; Face ID (or the phone's passcode) is still asked for each guarded change.
4. **A program that takes over the node itself** (S11 item 3: it restarts the node from files it changed) owns
   everything, as today.
5. **On Linux, the device list can't be kept anywhere a program running as you can't write.** So each phone's key is
   pinned in a record only an administrator can change (one `sudo` line per phone added or removed), and after the
   node's host ends (a reboot, a crash) your pinned phone's Face ID brings every device back. Until a phone is pinned,
   each device comes back by a confirmation in a terminal.

## What is protected, and from whom

**The property protected:** nothing acts as the user from a page (a request the command line would take only in the
user's voice, S3; a byte typed into a session; a change to the device list) unless it carries a signature of a key
that a device the user paired holds now, inside an unlock the user gave on that device with a biometric; and nothing
guarded acts without a fresh biometric for that change on a device that can show it (the Mac's own dialog, or a
phone).

| Who | Stopped, limited or accepted | How |
| --- | --- | --- |
| **A team session, or any process of the user's uid that is not the user**, that holds no device's unlock key and has not taken the page's address | **Stopped** from acting through the page and approving a guarded change; from adding its own device, stopped while the host runs (see the next rows for host ends) | no bearer token acts any more; every client frame is signed by an unlock key the vault certified; the device list is written only by the server, app-only in the vault (`VaultV2Handler.answer`'s `caller == .app`); an add needs a biometric on the Mac's dialog or a phone, or the terminal (S3) |
| the same, that can **drive the open page's browser or read its memory** during an unlock | **Accepted** (the user, 2026-11-25), **limited**: up to 12 h, that device's acts only, never a guarded change (those go to the Mac's dialog or a phone), every act recorded with the device's id, ended by removal | [Open to attack](#open-to-attack) 1 |
| the same, that **ends the host and binds its addresses** | the serve backend: **stopped** where the setup line's root-owned socket unit holds it (slice 18's spike), else **accepted** at S11 item 3's level; the desktop page's loopback port: Linux plain mode **accepted** at S11 item 3's level (both need a host start the journal records), the Mac and strong mode a **stated limit** | the host holds the loopback addresses for its whole life; the backend is never let go while a serve entry names it; the service-worker rule bounds a squatter's page to the browser's update interval ([The phone's path](#the-phones-path), [Open to attack](#open-to-attack) 3, 4) |
| the same, that **writes the user's files** | **Limited** | Linux: the vault is memory only (S7), so the device list's copy on disk is a hint a worker can rewrite; after a host end it comes back only on a phone whose key is in the root-owned pin ([where the node keeps the devices](#where-the-node-keeps-the-devices)). Mac: the vault is sealed under a Keychain key (`VaultStorage`) and its epoch kept in the Keychain against a copy put back |
| the same, that **becomes the host** (S11 item 3, T3) or replaces the command line (T12) | **Accepted**, as S11 says today | not this design's to close; signed releases (S12 item 12) |
| **A process of another uid** | Linux: **stopped**; the Mac: **stopped** once the daily unlock is a passkey (slices 13, 23) or, in the `macTouchID` fallback, once the browser-peer check is built, **except** the first enrolment while no device exists (a stated limit, [Open to attack](#open-to-attack) 5) | the loopback port needs a device's signature; on the Mac no Touch ID dialog is put up for a loopback peer except the first enrolment's ([The Mac](#the-mac)); the serve backend takes only tailscaled's connections; Unix sockets check the uid (S1's principals). Under WSL's mirrored networking, the Windows processes of **other** Windows users (S11 item 34) are in this row |
| **A Windows process of the user's own Windows account** (WSL, where the desktop browser is a Windows one) | **Accepted**, as the uid's processes are | it can read the Windows browser's memory (the unlock key), and it can ask Windows Hello for an assertion with rpId `localhost` and a `clientDataJSON` of its own naming `http://localhost:47830`: after one Windows Hello sheet the user approves, it holds a valid unlock ([Open to attack](#open-to-attack) 1). Guarded changes don't take a desktop's assertion on Linux, so not those |
| **Another tailnet device** | **Stopped** | the peer's Tailscale login must be the machine's own (decision 4); then it still needs a device key |
| another device **of the same Tailscale login** | a phone or tablet: **limited**; a computer (the WSL machine's own Windows node included): **stopped** from enrolling and witnessing | it passes the login check and can reach the page's public files and hold connection slots; enrolments and witnesses are taken only from peers whose Tailscale OS is iOS or Android (I3), and a phone's enrolment still needs the user's approval with its words |
| **Someone holding the locked phone** | **Stopped** | the phone's lock; the page's unlock needs Face ID; reads need the unlock on a phone; a push shows the first line of a card, masked (the user accepted the first line) |
| **Someone holding the unlocked phone** | **Accepted** while its page is unlocked; **stopped** for guarded changes (unless they know the passcode, which WebAuthn's user verification takes in place of Face ID) | removal from another device ends it at once |
| **A network observer** | **Stopped** | loopback stays on the machine; the tailnet is WireGuard plus TLS from `tailscale serve`; push payloads are encrypted for the browser (RFC 8291). **Accepted:** the machine's and the tailnet's names in Certificate Transparency logs; the push vendor sees that a push was sent |
| **A stolen backup of the state folder** | **Stopped** | no key that acts rests on disk: passkeys are in the authenticators, unlock keys in browsers; the folder holds public keys (and, on Linux, the push file: a push sent with it opens only the node's own page). A backup put back is a rollback, held as any rewrite is |

**What this design does not protect:** anything against root or what is one step from it (S1, S11 item 1: WSL
interop on voids every lock); the command line's own path (S3 is unchanged and keeps its "Doesn't promise"); the text
the lead and workers write (S11 items 12, 17); the user approving a biometric prompt they didn't expect (prompt
fatigue); a device's own authenticator being taken (an Apple account whose iCloud Keychain syncs the passkey).

**S11 items it closes for the page** (S12 item 11 says signed approvals "close 13 to 15 and 17 for approvals"): for a
request made **from a device**, item 13 (driving the user's shell gains nothing on the page path), 14 (PATH and
aliases) and 15 (the command line's binary) no longer apply, since the page path never runs the command line; item
33 (the token file) closes, since no token is taken. Item 17 (text the user reads) is narrowed for guarded changes,
which are shown by the Mac's system dialog or a phone's page. Items 13 to 15 stay open for the command line, which
stays the second way in.

## Every path to acting as you

Each row: the path, the check that guards it, and the test that will prove it (planned names; each moves to a `Held
by:` line in the security architecture when its slice lands). **Writers of the device list come first: with
`attestation: 'none'` (as `WebApp/js/passkey.js` already registers) the node can't tell a real authenticator from a
software one, so every guarantee rests on who can write the list.**

| # | Path | Check | Test |
| --- | --- | --- | --- |
| **Writers of the device list** | | | |
| W1 | The first device on Linux: `web.open`, then `web.confirm` in the install's own terminal (N2) | S3's voice rule and typed code; the words of the page's enrolment, derived from a nonce the server picks after the key arrives; one window, at most 4 knocks; a wrong word ends the window. Any loopback client (any uid, any Windows process under mirrored networking) can use up the 4 knocks: a denial only, the user runs `web` again | `FirstDeviceTests.onlyTheConfirmedEnrolmentIsAdded`, `FirstDeviceTests.wordsCantBeGround`, `FirstDeviceTests.aSessionsProcessCantConfirm` |
| W2 | A device again on Linux after every device was removed or lost | as W1 (the same kinds) | as W1 |
| W3 | The first device on the Mac: the page's passkey, then the server's Touch ID naming the page's words | `ApprovalVoice` (LocalAuthentication, the server's own text), off while `MacPageUnlock.measured` is false; one dialog at a time | `MacDeviceTests.theDialogNamesTheWordsTheServerDerived`, `MacDeviceTests.offUntilMeasured`, `MacDeviceTests.anotherUidCantAskTouchID` (beyond W3), `MacDeviceTests.anUnlockFromANonBrowserPeerIsRefused` (the fallback), `WebAuthnTests.theMacDesktopUnlocksByPasskey` |
| W4 | A phone added by QR (`device.add.open`, `device.enroll`, `device.add.approve`) | an unlocked device's signed request opens a 120 s window; the enrolment only on the serve gate, from a remote peer of the machine's login **whose Tailscale OS is iOS or Android** (a computer refused); the approval a guarded change: on a Mac node the server's Touch ID dialog with the words; on a Linux node a phone's passkey, or the terminal when no phone exists (the first phone); the vault checks that proof itself (new code, slice 4) | `AddPhoneTests.anEnrolmentOnLoopbackIsRefused`, `AddPhoneTests.aComputerOfTheLoginCantEnrol`, `AddPhoneTests.theApprovalBindsTheNewKey`, `AddPhoneTests.anApprovalForOtherWordsIsRefused`, `AddPhoneTests.aLinuxDesktopCantApproveAnAdd`, `VaultDeviceTests.anAddWithoutAValidProofIsRefused` |
| W5 | Removal (`device.remove`, Remove all, `device.lock`, `dropUnlocks`), or `web.revoke` (the command line's or a page's) | an unlocked device's signed request, any device; **fail closed**: a tombstone no refresh overrides until the vault confirms (I5), today's `revoked()` and `dropPages` included | `DeviceRemovalTests.aRemovedDevicesConnectionsCloseAtOnce`, `DeviceRemovalTests.aFailedVaultWriteKeepsTheDeviceRemoved` |
| W6 | Rename (`device.rename`) | an unlocked device's signed request; a name is shown inert and never alone in a prompt (the words and the date go with it) | `DeviceListTests.aNameIsShownInert` |
| W7 | The vault itself | app-only: `VaultV2Handler.answer` (`caller == .app`, through the connector). Today the vault records a user's action on the server's word alone (`recordUserAction` takes no proof): its checking of a device's proof is new code (slice 4) | `VaultDeviceTests.onlyTheAppWritesDevices` |
| W8 | A handover (`switch`) | the vault crosses in sealed memory (S8); no file | `VaultDeviceTests.devicesAndUnlocksSurviveAHandover` |
| W9 | A host end on Linux (or an unsigned Mac node): the devices' hint file `<root>/v2/devices.json` read back | never authority: the digest recomputed from the records; the list admitted whole only on a witness whose key the root-owned pin holds; with no phone pinned, each device by its own knock and the terminal | `DeviceRestoreTests.aPlantedDeviceIsHeld`, `DeviceRestoreTests.aStoredDigestIsNeverTrusted`, `DeviceRestoreTests.aRolledBackFileIsHeld`, `DeviceRestoreTests.aPlantedRemoteWitnessIsHeld`, `DeviceRestoreTests.aHeldDeviceIsReadmittedOnlyByItsOwnKnock`, `DeviceRestoreTests.noPinnedPhoneMeansTheTerminal` |
| W10 | A same-uid process writing `devices.json` while the host runs | the server never reads it while the host runs; written only from the vault | `DeviceRestoreTests.theFileIsNeverReadWhileTheVaultHoldsTheList` |
| W11 | The upgrade from today's tokens and `web_acts` | no device is made from a token, a level or a confirmed pairing; every page starts locked | `DeviceMigrationTests.noDeviceIsMadeFromAnOldToken` |
| W12 | The scratch server's flags (`--test-web-pair`'s open form, `--test-web-terminal`, `--test-web-terminal-watch`) | refused with `--node` (`ServerArguments`); the device kinds' test forms (an enrolment without a terminal) are scratch-only flags of the same rule | `DeviceKeysTests.theUsersNodeRefusesTheTestEnrolment` |
| W13 | The root-owned pin of the phones' keys (`/etc/vibeswitcher/<uid>/phones`, root `0644`; A64D1FC7) | written only by the user's pin line, in which root runs `/usr/bin/install` alone, from what `vibeswitcher pin-phones` prints (the admitted phones only, refused while any device is held); read by the server, never written by it; owner, mode and every parent folder checked, the format parsed exactly, anything else no pin | `PhonePinTests.onlyARootOwnedPinIsRead`, `PhonePinTests.anUnpinnedPhoneIsNoWitness`, `PhonePinTests.aHeldDeviceIsNeverPinned` |
| **Channels a message can arrive on** | | | |
| C1 | The loopback WebSocket, `localhost:47830` (and `127.0.0.1:47830`, static files only: N7) | Host and Origin exact, the same name in both (`NodeWebListener`); every client frame signed by the unlock key, or by the desktop's read key for reads only (below) | `DeviceFrameTests.anUnsignedFrameClosesTheConnection`, `LocalhostTests.hostAndOriginMustNameTheSameName`, `ReadKeyTests.aReadKeyNeverActs` |
| C2 | `[::1]:47830` | held by the host for its whole life, accepting nothing (S11 item 32 noted it was free); at a host end, as C1 | `HostWebListenTests.theHostHoldsIPv6LoopbackToo` |
| C3 | The serve backend: a loopback TCP port held by the setup line's root-owned socket unit and passed to the host (or, if slice 18's spike finds that can't be done, held by the host for its whole life), never a socket in a folder the uid can write | the peer must be tailscaled (its socket's owner read from `/proc/net/tcp`: uid 0); never released while a serve entry names it; `Tailscale-User-Login` the machine's own; the peer address not this machine's; enrolments and witnesses only from iOS or Android peers; Host and Origin the `ts.net` name; every frame signed by an unlock key | `ServeGateTests.aPeerThatIsntTailscaledIsClosed`, `ServeGateTests.anotherLoginIsRefused`, `ServeGateTests.thisMachineAsAPeerIsRefused`, `ServeGateTests.aWitnessFromAComputerOfTheLoginIsRefused`, `HostWebListenTests.theBackendIsHeldWhileAServeEntryNamesIt` |
| C4 | Way A's tailnet listener (the Tailscale address, `TailnetWeb.bind`) | kept on the user's node until `PhoneAccess.usersNode` is switched, then the host refuses the `tailnet` place | `HostWebListenTests.theTailnetPlaceIsRefusedOnceServeIsOn` |
| C5 | Terminal binary frames (input, resize) | each frame signed in the connection's one sequence, checked in `WebRequestScreen.binary` (unscreened today) before the relay's mode check; refused on a locked or read-key connection | `DeviceFrameTests.aTerminalFrameOutOfSequenceClosesTheConnection` |
| C6 | The command line on the server's socket | unchanged: S3's rule and typed code (Mac: Touch ID per state change) | (S3's) |
| C7 | The host's socket | unchanged (S2, S4): takes no page kind | (S2's) |
| C8 | A lead's tool server's posts | unchanged: the `.lead` seal (EN-D10); never the user's | (S3's) |
| C9 | A plugin's page (its own port, `HostWebListen.Place.page`) | another origin: the exact Origin refuses it; it can't reach the page's storage | `LocalhostTests.aPluginPagesOriginIsRefused` |
| C10 | Another tab of the same origin (`BroadcastChannel`) | same origin only; the unlock key passes as a non-extractable `CryptoKey`, never as bytes (today the token and act secret pass as strings, `socket.js`) | `devicekey.test.js` (`shares only a non-extractable key`) |
| C11 | A dev server on `localhost:<port>` asking a passkey for rpId `localhost` | the node checks `clientDataJSON.origin` exactly `http://localhost:47830`, and the device record's enrolled origin and place equal the listener's (N5) | `WebAuthnTests.anAssertionFromAnotherPortIsRefused` |
| C12 | Push (outbound only) | nothing comes in; the payload is the masked first line; the service worker opens only the node's own paths on a click | `PushPayloadTests.theFirstLineIsMasked` |
| C13 | The `tailscale serve` configuration: what the phone's address serves | set only by the setup line (CB1AC032); phone access refused while the uid can change serve (Linux: `OperatorUser` set, or unreadable, or absent before slice 17 confirms an absent field means unset; the Mac: any LocalAPI call succeeding as the uid); the configuration read at each serve-gate connection and every 30 s, any entry not exactly the node's closing the gate and locking the tailnet's devices | `PhoneAccessTests.anOperatorUidRefusesPhoneAccess`, `PhoneAccessTests.aMacLocalAPIWriteRefusesPhoneAccess`, `PhoneAccessTests.aForeignServeEntryLocksTheTailnetDevices` |
| C14 | **The Mac app's Phone Access** (v1: `Sources/VibeSwitcher/PhoneAccess.swift`, port 47823, token hashes in a uid-writable `~/.vibeswitcher/remote/devices.json`, `Tailscale-User-Login` taken from any loopback peer, `/api/input`) | a v1 path, not this design's: **off on a Mac node** (the lead's rule; whether the app's code is gated on a node is not checked here); tracked by the lead separately (the review's N10) | (the lead's) |
| C15 | A service worker on either origin | the node serves exactly one, at a fixed path; a request with `Service-Worker: script` for any other path, and the update fetch of any other registration, gets a script that unregisters itself, with `Clear-Site-Data: "storage"` | `ServiceWorkerTests.aForeignWorkerIsUnregistered` |
| **Trust on first use** | | | |
| T1 | The first device (W1, W3) | the terminal's voice, or Touch ID asked by the server | (W1, W3) |
| T2 | A new device's passkey, `attestation: 'none'` | an approval over the new key and its words by the Mac's dialog, a phone, or the terminal (W4) | (W4) |
| T3 | The machine's Tailscale login, name, and a peer's OS | read by the root-only `tailscale` (`Tailnet.find`'s rule). `Tailnet.find` reads no login or OS today: that reading is new code (slice 18) | `ServeGateTests.theLoginComesFromTheRootOnlyTailscale` |
| T4 | The phone page's TLS certificate | the browser's own check of the `ts.net` certificate (no TOFU) | none needed |
| T5 | The page's own code | the node serves only embedded files (`WebAssets`); the page is as trustworthy as the node, on the phone as what `tailscale serve` serves at its name (C13), and as the address's holder at a host end (C3, C15) | (LW-D9's), (C13's), (C15's) |
| **Where a key or a token rests** | | | |
| K1 | A passkey's private key | in the authenticator (Secure Enclave, Windows Hello, a security key; synced by the platform where it syncs) | none (the platform's) |
| K2 | Devices' public keys and records | Linux: the vault (memory), the hint file and, for phones, the pin (W13); Mac: the vault (Keychain-sealed), its epoch in a Keychain item | (W7 to W10), `MacVaultTests.aSealedVaultPutBackHoldsEveryDevice`, `MacVaultTests.aFailedEpochRaiseRefusesTheChange`, `MacVaultTests.aMissingEpochItemHoldsEveryDevice` |
| K3 | An unlock's private key | the page's memory on a desktop; the browser's storage, non-extractable, on a phone | `devicekey.test.js` (`never exports the key`) |
| K4 | An unlock's public key | the vault only: never a plain file (on the Mac inside the sealed vault file; never in Linux's hint file) | `VaultDeviceTests.unlocksAreNeverInTheHintFile` |
| K5 | Challenges, windows, words' nonces | the server's memory, once, 120 s | `UnlockTests.aChallengeIsTakenOnce` |
| K6 | The first-device address and the QR's address | no secret in either: a plain address | `AddPhoneTests.theQRCarriesNoSecret` |
| K7 | The VAPID push key | the Mac: the host's vault (the push note's decision 3); Linux: one owner-only file with the subscriptions (the lead's call) | (the push track's) |
| K8 | Push subscriptions | with the VAPID key, per device, dropped with it | `DeviceRemovalTests.aRemovedDevicesSubscriptionIsDropped` |
| K9 | The serve configuration | tailscaled's (root's), set by the setup line; the uid's too where it can change serve, which C13 refuses; the vault records the one entry expected | `PhoneAccessTests.offNeverLeavesAnEntryOnAFreeAddress` |
| K10 | Today's `web-tokens.json`, `web-tokens-tailnet.json` | deleted at the upgrade, never read | `DeviceMigrationTests.theTokenFilesAreRemovedAndNeverRead` |
| K11 | A desktop's read key (loopback only) | the browser's storage, non-extractable; its public key in the device record; admits reads and watching, never a draft, an act or a guarded change; never taken on the serve gate | `ReadKeyTests.aReadKeyIsRefusedOnTheServeGate` |

That is 44 rows: 13 writers of the list, 15 channels, 5 trusts on first use and 11 resting places. Two rules run
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
checked against a key the device's pairing key vouched for within 12 hours. This holds on every device, the Mac's
desktop included: its daily unlock is a browser passkey on `localhost` whose authenticator is Touch ID; the server's
own Touch ID dialog is kept for the Mac's first enrolment and its guarded kinds ([The Mac](#the-mac)).

**The desktop's read key** (the lead's call). A desktop on loopback also makes, at its enrolment, a second
non-extractable P-256 key, kept in the browser's storage, its public key in the device record. It admits a connection
for **reads and watching only**: never a draft, an act, a guarded change, an enrolment or a witness; never on the
serve gate. So a reload or a new build shows the page at once, and Touch ID is asked only to act. Reads still need the
unlock on a phone and on the serve gate, where a stolen locked phone must read nothing. A read key taken from the
profile's files gives a process of the uid what it reads already (`status`, the transcripts); it stops other uids and
other Windows users' processes as the unlock does.

### The handshake

1. **The server speaks first** on a WebSocket (this amends the live wire contract's §1, "the server says nothing
   before it"): `{"v":1,"kind":"challenge","conn":"<32 random bytes, base64url>"}`. `conn` names this connection
   alone; the server forgets it when the connection closes.
2. **A page with a live unlock** answers `{"v":1,"id":"0","kind":"auth","args":{"device":"<id>","unlock":"<key id>",
   "client":"webapp","assets":"…","sig":"<b64url>"}}`, `sig` over `"vibeswitcher-auth-v1\n" + origin + "\n" + conn`.
   The server looks the unlock up in the vault's record it caches (as `ActingPages` caches today), checks its device is
   listed and not tombstoned, that the device's enrolled origin and place are this listener's (N5), that the unlock's
   origin is too, that it hasn't ended, and the signature. Admitted, `hello` as today with `auth` `{device, rights,
   until}`. This replaces the contract's `pair` and `token` (§2's "When device keys come, `auth` gains `device` and
   `sig`"; `pair` and `token` go, not stay: a reading token is still a bearer secret in storage).
3. **A desktop page with its read key** (loopback only) answers the same with `"read":"<key id>"` in place of
   `unlock`, and is a **reading connection**: reads and watching, its `hello.kinds` those and `unlock.begin`,
   `unlock`.
4. **A page with neither** answers `auth` with no credential and is a **locked connection**: its `hello.kinds` are
   `unlock.begin`, `unlock`, `device.enroll` (during a window), and nothing else; no stream, no read. A locked page
   shows the lock screen only.

### The unlock

1. `unlock.begin` `{device?}` → `{challenge}`: 32 random bytes, 120 s, once, for this connection. Passkeys are made
   **discoverable** (`residentKey: 'required'`, amending `passkey.js`'s `'discouraged'`), so a page that lost its
   storage (Safari clears a site's script storage after 7 days without a visit; to be measured, slice 2) still
   unlocks as its device: with no `device`, `allowCredentials` is empty, the person picks the passkey, and the server
   finds the device by the assertion's credential id. Losing its storage costs the page its unlock key, its read key
   and its stored list, never its place in the list.
2. The page makes a fresh unlock key and asks `navigator.credentials.get` with `rpId` the listener's name,
   `allowCredentials` the device's credential (or none, above), `userVerification: 'required'`, and as challenge
   `SHA-256("vibeswitcher-unlock-v1\n" + origin + "\n" + conn + "\n" + challenge + "\n" + SPKI(unlock key))`, with
   `"\n" + witnessDigest` added while devices are held and this phone is pinned ([below](#where-the-node-keeps-the-devices)).
3. `unlock` `{spki, credential, authenticatorData, clientDataJSON, signature, witness?}` (the device is the one whose
   credential id the assertion names). The server, then the vault again before it records (VibeCore's verifier, so
   the host checks it too), checks, failing closed on anything else: the challenge is live, this connection's and
   unused; the device is listed, not tombstoned, and **enrolled on this listener's origin and place** (N5: a loopback
   device never unlocks on the serve gate nor a phone on loopback, and a software credential that can assert for any
   rpId gains nothing); `clientDataJSON` parses as exactly one JSON object whose `type` is `webauthn.get`, `challenge`
   the recomputed bytes, `origin` exactly this listener's origin, and `crossOrigin` absent or false; `rpIdHash` is
   SHA-256 of this listener's rpId; the flags have UP and UV; the signature checks under the device's stored key over
   `authenticatorData || SHA-256(clientDataJSON)`; a non-zero sign count must exceed the stored one. The vault records
   `{device, keyId: SHA-256(spki), spki, origin, since, until: since + 12 h}`, at most 3 live per device (a phone's
   home-screen app and its browser tab keep separate storage), the oldest dropped.
4. The connection is then the device's, as in the handshake's step 2.

### What is signed, so a message can't be replayed, reordered, or moved

Every client text frame after `auth` is an envelope, and **the server parses the request only from the signed
bytes** (no canonical form to get wrong):

```json
{"v":1,"kind":"signed","body":"{\"v\":1,\"seq\":7,\"id\":\"12\",\"kind\":\"send\",\"action\":\"6f1d…\",\"args\":{…}}","sig":"<b64url r||s>"}
```

`sig` is ECDSA P-256 with SHA-256 over `"vibeswitcher-frame-v1\n" + origin + "\n" + conn + "\n" + body`, by the
unlock key (or, on a reading connection, the read key, whose frames may be only reads).

- **Replay** on another connection fails: `conn` is new per connection. On the same connection it fails: `seq` must
  be exactly one more than the last (it starts at 1 after `auth`).
- **Reorder** fails on the same rule; a gap, a repeat or a bad signature closes the connection (4401), and the page
  reconnects and signs again. `crypto.subtle.sign` resolves in no guaranteed order, so the page signs and sends
  through **one ordered queue**: frame *n* + 1 is signed only after frame *n* was handed to the socket (N4; without
  it, fast typing would close the connection).
- **A retry** after a reconnect is a new frame with the same `action`: `Requests` answers a repeated action as before
  (rule 8), so nothing is done twice. **For a guarded kind the guard comes first** (N6): its fresh assertion is checked
  before `Requests.voiced`'s `kept` answer and its 15-minute `retry` of a begun action, so a known action id gains
  nothing without a new biometric. And `status`'s `accepted` list (action ids, pids, command lines) is no longer sent
  to web connections.
- **Another session or card** fails: the session, the card and its `seen` are in `args`, inside `body`.
- **Another node or origin** fails: `origin` is signed, the unlock is bound to one origin at the unlock, and the device
  to the origin and place it enrolled on (a node never certified another node's unlock key; a phone paired to two
  nodes unlocks each).
- **Anything unparseable** (two `body` fields, a body that isn't one JSON object, a `seq` that isn't an integer, a
  frame that isn't `signed`, text `NodeWire` can't decode) closes the connection, **before** `WebRequestScreen.text`'s
  fall-through to the hub, which today passes undecodable text on.

Terminal input and resize become one binary type (6), so they share the sequence: `[6][stream: 4][seq: 8][sig: 64]
[type: 1, the old 1 or 3][payload]`, signed over `"vibeswitcher-term-v1\n" + origin + "\n" + conn + "\n"` then the
stream, `seq`, type and payload bytes, checked in `WebRequestScreen.binary` before the relay's mode check. Types 1 and
3 from a page are refused as today (`TerminalRelay.binary`'s watch rule) and close the connection on the user's node.

**The bytes, exactly** (slice 1, `Sources/VibeCore/V2/DeviceProof.swift`; where the lines above left a byte open, the
strictest choice, each one encoding per value):

| Frame | Bytes | Signed over |
| --- | --- | --- |
| text | `{"v":1,"kind":"signed","body":"` BODY `","sig":"` SIG `"}`, nothing before or after | `"vibeswitcher-frame-v1\n"` + origin + `"\n"` + conn + `"\n"` + body |
| terminal | `[6][stream: 4][seq: 8][sig: 64][type: 1][payload]`, integers big-endian | `"vibeswitcher-term-v1\n"` + origin + `"\n"` + conn + `"\n"` + stream (4) + seq (8) + type (1) + payload |

- **The text envelope is those exact bytes**, not JSON read loosely: the four fields in that order, no space, `v` 1,
  `kind` `signed`. BODY is the body with each `"` and `\` escaped by one `\` and no other escape (a body holds no byte
  under 0x20, as compact JSON never does): what `JSON.stringify({v: 1, kind: "signed", body, sig})` makes.
- **`sig`** is the 64 bytes `r || s` (WebCrypto's form) in unpadded base64url, 86 characters, the last one's 4 spare
  bits zero. `s` is **not** required low: WebCrypto doesn't make it so, and the other signature of a frame, (r, n − s),
  signs the same bytes, which the sequence takes once.
- **`conn`** in the signed bytes is the challenge's text, unpadded base64url of its 32 bytes (43 characters); **origin**
  the listener's, printable ASCII without a space.
- **The body** is one JSON object in RFC 8259's grammar **with no whitespace** outside strings, at most 32 deep (the
  body's object is 1), **no name twice in any object**, names with no escape and two the same when canonically
  equivalent (as a Swift `String` key compares them: `K` and the Kelvin sign are one name), valid UTF-8, a `\u` escape of a surrogate only as a high one then a low one. It begins
  `{"v":1,"seq":N,` with N in plain decimal (no sign, no leading zero): the only place `seq` is read.
- **`seq`** runs from 1 to 2^53 − 1 (JavaScript's largest exact integer), text and terminal frames counting in the one
  sequence; lower than expected is a repeat, higher a skip.
- **A terminal frame's type** is 1 (input, at least one byte) or 3 (a resize, exactly 4 bytes); a stream of the
  connection's, and the resize's columns and rows, stay `TerminalRelay`'s to check.
- **Size:** a frame of either kind is at most 64 KiB (the contract's client frame).
- **Order:** size, the layout, the signature, and only then the signed bytes' content (the body's grammar, `seq`).
  Each refusal has its own name (`DeviceProof.Refusal`) and closes the connection.
- **Vectors** the page's module (slice 5) must reproduce byte for byte: `DeviceProofTests.textVectors` and
  `terminalVectors` (hex), with the key they verify under, in `Tests/VibeCoreTests/DeviceProofTests.swift`.

This amends the contract's §8 "When signed approvals exist": `proof {device, nonce, sig}` on a request becomes the
envelope on every frame, and "checked by the host (rule 7)" becomes **checked by the server** for each frame (the
server holds the connection and is the app, S2), with the presence proofs (unlocks, guarded changes, device adds)
checked **again by the host's vault** before it records anything.

### What it costs on a phone

One `crypto.subtle.sign` per frame (P-256), 64 bytes of signature (88 characters in a text frame); the server's verify
is one P-256 check (swift-crypto, already a dependency: `WebTokens` uses its `SHA256`). The page batches keystrokes
into one frame per 8 ms at most, through the ordered queue. The cost on a real phone and the effect on the terminal's
echo budget (16 ms median, 33 ms p95, the contract's G3) are **to be measured** in slice 5; if a sign costs more than
4 ms at p95, the page batches per 16 ms.

## Where the node keeps the devices

This is the spine: a device in the list can act after one biometric, and the node can't tell a real authenticator
from a worker's.

**What is kept.** Per device: `id` (16 random bytes), `name`, `place` (`loopback` or `tailnet`), `origin`, `rpId`
(the device is bound to them: N5), `presence` (`passkey`, `macTouchID` or `terminal`: the fallbacks of
[the desktop page](#the-desktop-page-and-passkeys)), the credential's id and P-256 key (COSE EC2, `alg` -7 only), its
sign count, its backup flags, a desktop's read key, `addedAt`, `addedBy` (a device id, `terminal` or `touchid`), and
for a phone its Tailscale login, node name and OS. Per unlock: as above. And `epoch`, a number raised by every add or
removal, and `digest`, SHA-256 of the list's canonical bytes at that epoch.

**Who writes it.** Only the server, through `LeadVaultV2` requests the vault answers for the app alone
(`VaultV2Handler.answer`: `caller == .app`, through the connector), as `addPageToken` and `addActingToken` are today.
New requests: `addDevice` (with the proof: the terminal's recorded action for W1, the server's Touch ID record for W3,
or the approving device's assertion for W4, which the vault verifies itself: new code, slice 4), `removeDevice`,
`renameDevice`, `addUnlock` (with its assertion, verified), `dropUnlocks`, `devices`.

**Removal is fail-closed** (I5). Today `ActingPages.change` applies a write to the cache, and on a failed vault write
bumps `generation`, calls `refreshLater()` and `lost()`; the refresh then loads the vault's answer, which still holds
what was dropped, and `dropPages` and `revoked()` pass `lost: {}`. So a revoke whose write fails is undone by the next
refresh: a pre-existing bug, fixed with this track. The server keeps a **tombstone** of each removed device, dropped
unlock and revoked token that no refresh overrides until the vault confirms it; while unconfirmed it retries, refuses
every frame and connection of what it names, and `status` says the removal isn't kept yet. The same rule for
`device.remove`, Remove all, `device.lock`, `dropUnlocks`, `web.revoke`, and today's `revoked()` and `dropPages`.

**The Mac:** the vault is sealed on disk under a Keychain key only the host's binary gets without asking
(`VaultStorage`, `keychainKey`); the list lives there and survives restarts. Two gaps, closed in slice 20's Mac arm:

- **Rollback.** `VaultStorage` seals the whole vault with ChaChaPoly and no counter: a worker that copied
  `vault.sealed` before the user removed a lost phone can put it back and kill the host (a launchd agent of the uid).
  So the host also keeps the device list's `epoch` in a Keychain item of its own (the same access rule as the key), in
  this order (I6): **raise the Keychain epoch first, then seal the vault**; a failed raise refuses the change (the
  device stays listed, the user is told, nothing is half-done); **a missing epoch item while the sealed vault lists any
  device holds every device**; a vault epoch lower than the item's holds every device; a vault epoch **higher** than
  the item's (the seal succeeded, the raise was lost: impossible in this order but checked) re-raises the item and is
  never a reason to trust an older file. Held devices come back as Linux's do (below).
- **No key.** `keychainKey` gives nil to a host not signed with `setup-signing.sh`'s identity (the Mac spec leaves
  signing "for the user"), and then the vault is memory only. Such a Mac node takes Linux's path, and `status` says
  so.

Unlocks ride in the sealed vault on the Mac (`Book.onChange` saves it whole): sealed, never a plain file; a rolled-back
unlock has ended within 12 hours anyway.

**Linux:** the vault is memory only (S7, "memory only; lost"). Nowhere on Linux before strong mode can the node keep
something that survives a host end and that a process of the uid can't write: a key file is no secret (S7's "Why");
systemd's user credentials and a TPM are expected to answer any process of the uid, and the user keyring to be
possessed by every process of the uid (from memory: **to be measured**, slice 20; if one of them does keep a record
out of the uid's reach across a host end, it could replace the hint file). So:

- **While the host runs**, the vault is the authority. A handover (`switch`) carries it in sealed memory (S8).
- **The hint file** `<root>/v2/devices.json` (0600, written from the vault after each change, never read while the
  host runs) holds the public records, `epoch` and `digest`. Never an unlock.
- **After a host end** the server reads the hint file and holds every device ("held after the restart"): a held
  device may prove its key (an unlock attempt, which is how it knocks or witnesses) and may not act or read until it
  is let back in. **The file's `digest` field is never trusted**: the server computes the digest again from the
  records it read, and the file's `epoch` is only a claim. What lets devices back in is **a pinned phone** (the user's
  answer, 2026-11-26, A64D1FC7):

**The pin.** `/etc/vibeswitcher/<uid>/phones`, owned by root, mode `0644`, in folders owned by root and writable by no
one else. Its format, one line each, fail closed on anything else (a line it doesn't know, a second header, trailing
bytes, more than 16 phones):

```text
vibeswitcher-phones 1
epoch 14
phone 3f9c…<device id, base64url> 9d41…<SHA-256 of the credential's COSE key, hex> amber river kite
```

- **Who writes it:** only root, by the user's **pin line**, which the page shows after each phone is added or removed:
  `vibeswitcher pin-phones | sudo /usr/bin/install -D -m 0644 -o root -g root /dev/stdin /etc/vibeswitcher/<uid>/phones`.
  Root runs only `/usr/bin/install`, a root-owned program: never a program from the user's folders, which a worker
  could replace to get root. `vibeswitcher pin-phones` (the user's voice, S3, no typed code: it changes nothing)
  prints the record from the vault's **admitted** serve-gate devices only, and refuses while any device is held, so a
  planted phone held after a restart is never pinned; it also prints, to the terminal, each phone's name and words for
  the user to compare with the phone.
- **What the node checks:** at each restore, the file's owner (root), mode (no group or other write), every parent
  folder's owner and mode, and the exact format; a phone witnesses only if its device id and credential key hash are
  in the pin, and the restored list's epoch is not below the pin's. Anything unusual is no pin.
- **Adding a phone:** after the approval, the phone works at once while the host runs; This node › Devices shows "Pin
  this phone so it can bring your devices back after a restart" with the line and a Copy button, and the phone's row
  says "not pinned yet" until the server reads a pin naming it.
- **Removing a phone:** the removal works at once (tombstoned, then the vault); the row stays as "removed, still
  pinned: run this line" with the line, until a pin without it is read. Until then a rollback could let that phone
  witness for an older list: said in the row.
- **No phone pinned yet** (no phone, or none pinned): after a host end each device comes back only by the terminal's
  confirmation of its own knock (step 2's terminal half, below), and `status` and the lock screen say so.

1. **A witness that agrees.** Every phone keeps, in its own storage, the canonical list it last saw (each device's id,
   credential key hash, name and place: a few hundred bytes) and its `epoch`, refreshed at each change it is shown (the
   `devices` stream). A phone on the serve gate whose **credential key is in the pin** and whose peer is iOS or Android
   (C3) adds that witness to its unlock (the challenge's `witnessDigest`, SHA-256 of the canonical list and epoch the
   page sends beside it, so the passkey vouches for exactly that witness). When the witness's list is byte for byte the
   list the server recomputed from the file, and its epoch the file's (and not below the pin's), the list is admitted
   whole. This is sound because the phone's page can't be re-pointed: `tailscale serve` is root's (CB1AC032, C13), so
   the page that computes `witnessDigest` is the node's own.
2. **Otherwise one device at a time, each as a new knock.** A witness that doesn't agree admits only its own device;
   its page shows what differs **from the phone's own copy** (a device the file has and the phone doesn't is "not known
   to your phone", the file's name shown as not vouched for). Every other held device stays held until it knocks (it
   tries to unlock: its passkey assertion proves it holds that key) and an admitted phone approves that knock as a
   guarded change (`device.readmit`: its words from a nonce the server picks after the knock, the biometric over the
   knocking key and the words), or the terminal confirms it (`vibeswitcher web` lists the knocks' words; the user types
   the words their own device shows, and the code, S3's voice). Nothing is re-admitted from a name or a date the file
   gives.

*Not chosen:* no witness and the terminal after every host end (the review's option (b)); it remains only as the
path while no phone is pinned.

A loopback device is never a witness, judged on the connection and the record together (N5): its
browser's storage is the uid's to write.

What it does and doesn't hold, honestly:

- **Planted device** (a worker adds its key to the file and restarts the host): **held**. The witness's key must be in
  a file only root writes, so a worker's software "phone" can't witness, wherever it connects from (I3's attack, from
  another node of the login or the WSL machine's Windows side, fails at the pin). Without the pin, a witness whose key
  comes from the same file it vouches for proves nothing: that is why the earlier draft's phone-as-witness without a
  pin is withdrawn. What still pins a worker's key: replacing the user's command line, so `pin-phones` prints its key
  (S11 item 15, T12, accepted), or driving the user's terminal (S3's "Doesn't promise"); the names and words it prints
  are there for the user to compare.
- **Rollback** (a worker puts back an older file): stopped when the witness saw the later epoch, and by the pin's
  epoch; **not stopped** for a device removed while every pinned phone was away and before the pin line was run
  again. Limited: a removed phone should also be removed from the tailnet (the Devices list says so and links the
  admin console).
- **Deletion** of the file: every device is gone after the next host end; the user pairs again (W2). A denial.
- **Forced restarts** (S7: a worker restarts the host at will): each one holds every device until a pinned phone
  witnesses or the terminal confirms. A denial, shown in `status` as today's restart notices.

Strong mode (S12 item 5, the vault's key file outside every sandbox) later keeps the list across a restart against
confined sessions; the pin stays for unconfined processes.

## The first device, and adding a phone

### The first device

**On Linux (N2):** the install line ends by running `vibeswitcher web` in its own terminal. Amended `web.open`
(`KindSpec`, still `.terminalOnly`, its reason now "it opens a first-device window: a page would enrol itself"; the
user's voice behind the code from the action id, recorded) opens a **first-device window**: 10 minutes
(`PagePairing.waits`), at most 4 pages may knock, and prints a plain address (`http://localhost:47830/`, or
`http://127.0.0.1:47830/` under N7's terminal fallback). **No code in the address**: the fragment code goes (the rule:
nothing secret in a URL).

1. The page that opens it, locked and with a window open, offers "Set up this browser". It makes its unlock key, its
   read key and a passkey (`navigator.credentials.create`, `userVerification: 'required'`, `residentKey: 'required'`,
   `attestation: 'none'`, ES256 only, as `passkey.js`'s `createOptions` amended), its challenge
   `SHA-256("vibeswitcher-enrol-v1\n" + origin + "\n" + conn + "\n" + window + "\n" + SPKI(unlock key) + "\n" +
   SPKI(read key))`, and sends `device.enroll` `{window, spki, readSpki, attestationObject, clientDataJSON, name}`.
2. The server checks the registration as the unlock's assertion (type `webauthn.create`, origin, rpIdHash, UP and UV,
   the COSE key P-256 and nothing else, attestation format `none`), then **picks a fresh nonce for that enrolment and
   only then derives its words**: three words of `PagePairing.words` from `SHA-256(nonce || credential key || spki)`.
   A worker can't grind keys for chosen words: each try is a knock, and the words are fixed by a nonce that comes
   after the key (24 bits, at most 4 knocks a window). The page shows its words.
3. `web.pairing` (still `.terminalOnly`) lists each knock's words; amended `web.confirm` `{window, words}` (still
   `.terminalOnly`, reason unchanged: "it pairs a page: a page would pair itself") adds the device whose words were
   typed, and records its unlock: the page acts at once. A wrong word or a second confirmation ends the window, as
   `webConfirm` does today; two knocks with the same words get a new nonce each. Knocks can be used up by any loopback
   client: a denial only (W1).

**On the Mac (541E258F):** no terminal. A locked page on `localhost` with no device offers "Set up this Mac's
browser": it makes its passkey (Touch ID, the platform authenticator) and keys as above and sends `device.enroll`, and
the server asks its own Touch ID (LocalAuthentication, the server's text: "add the browser page showing *amber river
kite* as a device of this Mac"). The Mac's unlock has no dialog any more, so its words go (the lead's call: words
only for the first enrolment); the dialogs that still carry words are this first enrolment's and an add's approval
(the new phone's words, below), and the `macTouchID` fallback's if slice 13 forces it. So setup asks Touch ID twice
(the passkey, then the dialog); every later unlock is the passkey's one. While no device exists, any loopback client
can raise this dialog with words of its own: the user approves only words their own open page shows (a stated limit,
[Open to attack](#open-to-attack) 5). Off until measured ([The Mac](#the-mac)).

### Adding a phone (decision 5)

1. On an unlocked device: This node › Devices › Add a phone. The page sends `device.add.open` (signed; an unlock may:
   it adds nothing). Refused while phone access is off. The server opens an **add window**: 120 s, at most 4
   enrolments, one window at a time, closed by the opening device's connection closing.
2. The page shows a QR code of `https://<machine>.<tailnet>.ts.net:47830/#add`: the address and nothing secret.
3. The phone opens it over the serve gate (C3: the peer is tailscaled, the login is the machine's own, the peer
   address isn't this machine's, **and the peer's Tailscale OS is iOS or Android**, from the root-only `tailscale
   whois`; a computer of the login is refused, the WSL machine's own Windows node included). It makes its unlock key
   and passkey (Face ID) and sends `device.enroll` `{window: "add", …}` as above. `device.enroll` for an add window is
   taken **only on the serve gate**; on loopback it is refused. The phone shows its words and "Approve on your
   computer" (or "on your other phone", or "in your terminal").
4. The approval is a guarded change, `device.add.approve` `{window, enrolment, words}`, its digest over the new
   credential key, the new unlock key and the words; the vault verifies the approving proof before it adds the phone
   and records its unlock. The phone is unlocked at once. Who approves:
   - **a Mac node:** the server's Touch ID dialog, its text naming the phone's words, name, Tailscale login and node
     name;
   - **a Linux node:** a phone already added (its page shows the same, Face ID), or, **for the first phone**, the
     terminal (`vibeswitcher web` lists the add window's enrolments with their words; the user types the phone's
     words and the code). A Linux desktop's passkey never approves an add (N1): its sheet shows only "localhost".

**What stops a session from showing or scanning its own QR.** Showing: opening a window needs a signed frame of an
unlocked device; and a window gives nothing by itself. Scanning: the enrolment is taken only from a remote iOS or
Android peer of the login through tailscaled, so a process on this machine or another computer of the login can't
enrol (C3's checks); one on another phone of the login can, and is then one more line the user is shown with words
that aren't the phone's. Approving: a fresh biometric over that exact key, on the Mac's own dialog or a phone (both
show the words the server derived, not a desktop page's), or the terminal.

### `web.open` and `web.confirm`, amended (to implement)

- `web.open`: `.terminalOnly("it opens a first-device window: a page would enrol itself")`; args none (no `tailnet`:
  the phone is `device.add`'s); result `{url, window, expiresIn}`, the url without a fragment. `keepsResult` stays
  false.
- `web.pairing`: `.terminalOnly` as today; result `{state, knocks: [{words, at, name}]}`, the knocks of a first-device
  window, of an add window (a Linux node's first phone) or of held devices (after a host end).
- `web.confirm`: `.terminalOnly` as today; args `{window, words}`; adds (or re-admits, or approves the add of) the
  knocking device whose words equal the typed ones (normalised as `webConfirm` does), records its unlock, closes the
  window; refuses, closing the window, on a word that matches no knock.
- New, `.acts` (an unlocked device's signed frame): `devices`, `device.add.open`, `device.rename`, `device.remove`,
  `device.lock`, `phone.off`, `guard.begin`. New, `.guarded` (below): `device.add.approve`, `device.readmit`,
  `phone.on`. New, a locked connection's (a new sender, `webLocked`, taken only before `auth` succeeds):
  `unlock.begin`, `unlock`, `device.enroll`.

## The unlock, and what it never covers

**Twelve hours on every device**, from the biometric, at most. What the unlock **releases**: the device's connections
are admitted (reads, drafts, watching terminals); its signed frames of every `.acts` kind are taken as the user's,
recorded with `via` naming the device (today's `ActingPages.via` gives the token's id; it gives the device's id and
name); typing into terminals once [the phone's path](#the-phones-path) slices land; and asking `guard.begin`. A
desktop's read key releases only the reads and watching.

**What ends it early:** the device removed (anyone's), Lock now on the device (`device.lock`), Remove all or
`vibeswitcher web --revoke`; the page losing its key (on a desktop, its last tab closed or reloaded, since the desktop's
unlock key is in memory only: the lead's call; the read key keeps the page showing; on a phone, the browser clearing
its storage, which Safari does after 7 days without a visit: to be measured, slice 2); a host end on Linux (unlocks are
never written down); a bad signature or a sequence gap (the connection closes; the unlock stands, since only the key's
holder can sign).

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
| `device.add.approve`, `device.readmit`, `phone.on` | new | **the design's call** (the review: right): each widens the node's reach, as `web.open`'s reason says ("a page would widen its own reach") |
| the journal's acknowledgment (the N6 kind to be added) | `status --ack` | **the design's call** (the review: right), stricter than N6's words: it clears marks that say a start or a request nobody explained |

Still the terminal's: `start` (no server is there to ask), `web.open`, `web.pairing`, `web.confirm`; and, as the
terminal's form of a guarded kind for a Linux node with no phone, `vibeswitcher phone on` and each guarded kind's own
command.

**How a guarded change is asked.** `guard.begin` `{request}` (signed): the server builds the change's text itself
(as `ApprovalVoice.reason` builds the Mac's dialog from the card, never the board) and its digest, SHA-256 over the
kind, the arguments, each card's `seen` and each batch item's (an `approve` batch's digest covers every item); it
answers `{text, digest, challenge}` (120 s, once). Then, by where the request came from:

- **A Mac node's page:** the server asks its own Touch ID with that text, so the system dialog shows the change.
- **A phone:** the page shows the text whole and inert, then asks the passkey with challenge
  `SHA-256("vibeswitcher-guard-v1\n" + origin + "\n" + conn + "\n" + challenge + "\n" + digest)`, and sends the
  request with the assertion.
- **A Linux node's desktop page** (the lead's call; the desktop's sheet shows only "localhost", so its approval would
  be blind): the server holds the desktop's signed request as a **pending approval** `{id, text, digest, from device,
  at, expires (10 min)}`, sent to each unlocked phone on a new stream, `approvals`, and as a push. On the phone,
  `approval.begin` `{approval}` (signed, the phone's own connection) answers a challenge bound to **the phone's**
  connection, and `approval.give` `{approval, assertion}` carries Face ID's assertion over
  `SHA-256("vibeswitcher-guard-v1\n" + the phone's origin + "\n" + the phone's conn + "\n" + challenge + "\n" +
  digest)`; the server then acts the desktop's request (recorded as the desktop's, approved by the phone) and the
  desktop sees the outcome. A pending approval is dropped when it expires, the desktop's connection closes, or either
  device is removed. With no phone paired, the desktop shows the change's terminal line instead: today's command for
  that kind, and for `phone.on` the new terminal form `vibeswitcher phone on` (S3's voice, a typed code), since no
  phone can exist before phone access is on.

At the act, on the server's queue, the guard's assertion is checked **before** `kept` and `retry` (N6), and the
digest is built again from what is there now: different, refused `changed`, as `seenStands` does. The vault checks the
assertion before it records the action.

## The desktop page and passkeys

**N7: the loopback page answers on `localhost:47830`.** A passkey's rpId must be a domain, and `localhost` is the one
browsers take on plain HTTP (**verified** for Chromium, ["Origins that support
WebAuthn"](https://chromium.googlesource.com/chromium/src/+/main/content/browser/webauth/origins.md): "HTTP pages
served from localhost"; Firefox treats `localhost` as a secure context; **Safari on `http://localhost` to be
measured**, slice 13). What must go with it:

- **Host** exactly `localhost:47830` or `127.0.0.1:47830`; **Origin** on the upgrade exactly `http://localhost:47830`
  or `http://127.0.0.1:47830`, **and naming the same host as Host**; `Sec-Fetch-Site`, when sent, `same-origin`. Any
  other name, a missing or repeated header: 421 or 403 as today (`NodeWebListener`, `WebRequest`).
- **DNS rebinding** fails as before: a page of `evil.example` resolved to 127.0.0.1 sends its own name as Host.
  `localhost` itself: Chromium and Firefox are expected to answer it on loopback without asking DNS, Safari to ask the
  system, where `/etc/hosts` is root's (all **to be measured**, slice 13; a browser that asks a resolver a process of
  the uid can change gets the terminal fallback below, without a passkey).
- **IPv6.** `localhost` may resolve to `::1` first, and `[::1]:47830` isn't held today (S11 item 32): any process of
  the uid could bind it and take the page. So `HostWebListen` gains the `loopback6` place (`::1`, port 47830 only,
  held for the host's whole life with the IPv4 one, accepting and closing; `HostWebListen.refusal` today allows only
  `127.0.0.1` for loopback). A host that can't bind `::1` (no IPv6) holds nothing there, and then nothing else can
  either.
- **A host end frees both** (I1): `HostWebListeners` holds the sockets for the host's life, not across its end. On
  Linux plain mode a process that can end the host can also become it (S11 item 3), so this is accepted there at that
  level (the journal records the start). On the Mac and in strong mode it is a stated limit
  ([Open to attack](#open-to-attack) 4): the setup line's root-owned unit holds only the phone's backend, and holding
  the desktop page's addresses the same way (a launchd daemon's `Sockets` written by the BCECD1F3 install step; a
  system socket unit on Linux) is left for later, not built by this track. The service-worker rule (C15) bounds how
  long a squatter's page outlives the squat.
- **Other ports of `localhost`.** rpId `localhost` covers every port, so a session's dev server on
  `http://localhost:3000` (the pages `session.ports` links) can ask for an assertion; it gets one with its own origin,
  which the node refuses (C11). It can still put an unexpected Touch ID or Windows Hello sheet on the screen
  ([Open to attack](#open-to-attack) 4). Same-site but not same-origin: no storage or `BroadcastChannel` is shared.
- **The CSP** names the socket of the name the page was served under (`WebSecurityHeaders.policy(port:host:)`).
- **The `127.0.0.1` page** (N7 of the review) can't unlock: an IP address is no rpId. It serves the static files and
  an "Open this page at localhost" link only, never a read, unless N7's terminal fallback below is in force, where it
  is the page.

**What a desktop has as an authenticator.** On this Linux machine (WSL2, mirrored networking) the browser is a Windows
one, and Windows Hello is its platform authenticator; a native Linux Chrome has none of its own but takes a phone (the
cross-device flow) or a security key, and synced passkeys from a password manager. A Mac browser has Touch ID. To be
measured, slice 13; the design needs only a UV-capable ES256 credential.

**If the reviewer of slice 13 says no, or a browser can't hold a passkey on `http://localhost`** (N7's fallback): the
loopback page stays on `127.0.0.1`. On Linux the desktop device has `presence: terminal`: each unlock is `vibeswitcher
web` and the typed code (today's daily A1/A2), its guarded changes the phone's or the terminal's as above; the phone is
unaffected. On the Mac the desktop device has `presence: macTouchID`, with the browser-peer check of
[The Mac](#the-mac).

## The phone's path

**HTTPS through `tailscale serve`, set by one `sudo` line once per machine** (the user's answer, 2026-11-26,
CB1AC032, superseding N5's "the node sets it on the user's click"). Turn on phone access is then `phone.on`, a guarded
change whose text says what it changes ("Tailscale will serve this page at https://<name>:47830 to your
tailnet's devices; HTTPS certificates put the machine's name in public logs"). The server runs only the root-only
`tailscale` (`Tailnet.find`'s rule: fixed path, fixed `PATH`, no inherited environment, 5 s), reads `tailscale serve
status --json` first (that the uid may read it is **verified** on this Mac's standalone client by the review; on Linux
**to be measured**, slice 17; if not, phone access can't be checked and stays off), and refuses (saying why) when port
47830 is already served by anything but the node's one expected entry, when the output doesn't parse, or when HTTPS
certificates or MagicDNS are off. That `tailscale serve` takes HTTPS on 47830 is **verified** for the current CLI
(Serve, unlike Funnel, no longer limits its ports: [Tailscale's Funnel docs](https://tailscale.com/kb/1311/funnel-cli),
[Serve docs](https://tailscale.com/kb/1312/serve)), to check against the installed version in slice 17.

**Who can re-point the phone's page.** On Linux, Tailscale's operator "can manage Serve and Funnel port targets, but
serving a file, directory, or Unix socket still requires root" (**verified**, Tailscale's CLI docs, kb/1080, `set
--operator`). An operator is a uid, so if the user's uid is the operator, every process of it can change `tailscale
serve`: a worker keeps `/ws` pointed at the node's backend and serves `/` from its own server under the same name, so
the phone runs the worker's script on the real origin. That script uses the phone's stored unlock key, shows false
text while Face ID approves a guarded change, and registers a service worker. The serve gate sees nothing wrong. On
the Mac (the review, read-only on Tailscale 1.104.7, `io.tailscale.ipn.macsys`): `debug prefs` has no `OperatorUser`
key at all, and the LocalAPI's proof file is `root:admin 0640`, readable by any process of an admin uid, whose
credential is expected to grant writes, serve included.

**The setup line's job.** Run once per machine, by the user, in a terminal:

1. it sets the serve entry, HTTPS on 47830 to the backend port, with `/usr/bin/tailscale serve --bg`;
2. it installs a root-owned system socket unit that holds the backend port (on `127.0.0.1`) across host ends and
   passes it to the host (I1), its text **fixed** (the same in the user guide), written by the line itself, never
   generated by a program of the user's: a unit's text can run commands as root, so a worker that replaced the user's
   command line must not get to write it;
3. it leaves the user's account **not** Tailscale's operator, so no process of the uid can change serve.

The line runs only root-owned programs (`/usr/bin/tailscale`, `/usr/bin/install`, `/usr/bin/systemctl`); the only value
in it from the user's side is the uid number. Whether a system unit can pass a socket to the user's host is a design
spike before slice 18; if it can't, the host holds the backend port for its whole life instead (S11 item 3's level at a
host end, said in `status`).

**What the page shows.** Before the line has run, This node › Phone access shows: "Phone access needs a one-time setup
on this computer. It lets Tailscale serve this page to your own phones over HTTPS, and keeps that setting out of reach
of programs running as you. Run this line in a terminal (it asks your password):" then the line with a Copy button,
what each part does, and "HTTPS certificates must be on in your Tailscale admin console" with a link. After it, the
node checks the result (the serve entry exactly its own, the unit holding the port, the uid not the operator) and
shows Turn on phone access; Turn on and Turn off then need no root: Turn off closes the serve gate (the backend held,
answering 503) and Turn on opens it again. **Turn off never leaves an entry naming a free address**, since the unit
holds the address for as long as the entry exists; removing phone access entirely is the setup line's `--remove` form,
which removes the entry first and the unit after.

**The refusal.** The node **refuses phone access while the uid can change serve**: on Linux while `tailscale debug
prefs`' `OperatorUser` names the uid, or is unreadable, or is absent before slice 17 has confirmed that the field
appears when it is set (it may be left out when empty); on the Mac whenever any `tailscale` LocalAPI call succeeds as
the uid, so **phone access on a Mac node stays off** until slice 17 finds, on each Mac variant (App Store,
standalone), a way to deny the uid writes. The words: on Linux, "Phone access is off: your account can change what
Tailscale serves (it is Tailscale's operator), so a program running as you could replace your phone's page. Clear it
with `sudo tailscale set --operator=` and try again." On the Mac, "Phone access isn't available on a Mac node yet:
VibeSwitcher can't yet stop programs running as you from changing what Tailscale serves."

**Watched anyway:** the node reads the serve configuration at every serve-gate connection and every 30 s; any entry
for the machine's name on 47830 other than exactly its own (a path handler included) closes the serve gate and locks
every tailnet device until the configuration is its own again.

*Not chosen:* the node setting serve itself (N5 as worded), which needs the uid to be Tailscale's operator, so that
every process of the uid could re-point the phone's page.

**The backend, and who can reach it.** Way A's bind of the Tailscale address (`TailnetWeb.bind`, the host's `tailnet`
place) is retired when `PhoneAccess.usersNode` is switched. The backend is **a loopback TCP port the host holds for its
whole life** (H1's rule: the host binds, the server accepts; a new `HostWebListen` place, `serve`, `127.0.0.1` and one
fixed port of its own), **never a socket in a folder the uid can write**, which any uid process could rename and
replace with its own (and Serve's `unix:` targets need root anyway, kb/1080). The setup line's root-owned socket unit
holds it and pid 1 hands it to the host, so it stays held while the host is down (the spike above). The host **never
releases it while a serve entry names it.** The peer must be tailscaled: its socket's owner read from the kernel's table (`/proc/net/tcp`'s uid
column on Linux) and required to be 0 (that tailscaled connects as uid 0, and that a connection mirrored in from
Windows under WSL fails the lookup: **to be measured**, slice 18). If the peer can't be told, **the phone path doesn't
open**: a backend any process of the uid can reach is a forged-header channel.

**The tailnet-login check (decision 4).** Serve adds `Tailscale-User-Login`, `-Name` and `-Profile-Pic`, strips
incoming ones "to avoid header spoofing", and sends none "for traffic originating from tagged devices" (**verified**,
[Serve docs](https://tailscale.com/kb/1312/serve)). The gate requires `Tailscale-User-Login` to equal the machine's own
owner's login from the root-only `tailscale status --json` (new code: `Tailnet.find` reads no login today); a missing
header is refused. The forwarded peer address (Serve is expected to send it as `X-Forwarded-For`, not documented:
**to be measured**, slice 18; without it this check can't be made and the phone path doesn't open) must not be one of
this machine's own Tailscale addresses. **Enrolments and witnesses** are taken only from a peer whose Tailscale OS
(the root-only `tailscale whois`) is iOS or Android, refusing the WSL machine's own Windows node and every computer of
the login (I3; the OS is reported by the peer's own tailscaled, so a computer is expected not to forge it without a
tailscaled of its own under that login: **to be measured**, slice 18). Host is exactly `<name>:47830`, Origin exactly
`https://<name>:47830`, the CSP `connect-src 'self' wss://<name>:47830`.

**The service-worker rule (C15), both origins** (I1's defence in depth, and the push track's own need). The node
serves exactly one service worker at a fixed path. Any request with `Service-Worker: script` for any other path, and
the update fetch of any other registration, gets a script that unregisters itself, sent with `Clear-Site-Data: "storage"`,
which wipes a poisoned stored unlock key and witness list. The node's worker opens only the node's own paths on a
notification click, never a URL from the payload. This **bounds** a squatter's page to the browser's update interval
(about 24 hours) and does not close it; whether browsers keep a registration whose update fetch fails, and honour
`Clear-Site-Data` on a worker script's response, in Safari on iOS and Chrome on Android, is **to be measured** in its
slice (25), which has its own security review.

**Credentials masked on every remote page** (decision 3), before any phone stays paired: every string the serve gate
sends (chat items, cards, sessions' commands and prompts, board records, notices, settings' values) through
`Redaction.secrets(in:)` (VibeCore, the Mac app's masking), and the terminal's bytes through a `TerminalMask` that
also applies it on what the screen shows. Slice 16 lands before slice 19 offers Add a phone.

**Typing into terminals, only once keys and HTTPS exist** (LW-D12 amended; the remote access note's decision 6):
`TerminalRelay.Mode` gains `type` for the user's node: a connection of an unlocked device types through the host's
`input` as the app's composer does, each frame signed (type 6); the host's parser keeps answering the program's
queries (`TerminalReplies.strip` unchanged); a locked, read-key or watch-only connection stays `watch`. On loopback
first; on the serve gate after slices 16 to 19. LW-D12's sentence "Typing stays the user's voice: `vibeswitcher send`"
is amended to "typing is an unlocked device's signed frame, or `vibeswitcher send`".

**Push** (the push note's decisions): one subscription per device, made after its unlock, dropped with it; the payload
the card's or prompt's first line through `Redaction.secrets(in:)`, never a code, an address with a secret, or a token.
**Where the key rests (the lead's call):** on the Mac, the VAPID key and the subscriptions in the host's vault; **on
Linux, both in one owner-only (`0600`) file under the node's root** until strong mode (its vault key file, S12 item 5),
since Linux's vault loses both at every host end and a file holding the key alone saves nothing. The cost, stated: a
program running as the user could send their phone notifications with words of its choosing; a click opens only the
node's own paths (C15), whose page shows the real state and asks the unlock as always.

## The Devices list and removing a device

This node › Devices: each device's name (editable), kind, where (this computer, or the phone's Tailscale name),
added when and by which device, last unlocked, unlocked now or not, "synced with your Apple account" where the backup
flag says so, and Remove. "This device" is marked. Add a phone; Remove all (today's `web.revoke`, a second click to
confirm).

**Removing a device, at once**, in the server's turn that takes `device.remove`, before it replies:

1. The device and its unlocks are tombstoned in the cache (as `ActingPages.set` lowers at once, before the vault
   answers), so no later frame of it is taken; the vault's write follows in order, and until the vault confirms it
   the tombstone stands against every refresh (fail-closed, [above](#where-the-node-keeps-the-devices)).
2. Every connection admitted as the device is marked (no act, no watch), its terminal streams dropped
   (`LiveHub.endTerminals`, as `WebRequestScreen.end` does), then closed with 4403 `removed`.
3. **In-flight messages:** a request of the device not yet done is checked again on the queue right before `voiced`
   (today's re-check of `acts` after `PageVoice.confirm`, generalised): refused `actsEnded`. A request already recorded
   in the vault and being done (text being typed) finishes: it can't be untyped. A guarded change waiting for its
   biometric is refused when the assertion comes.
4. **Pushes:** its subscription is dropped and any push queued for it is dropped; one the vendor has already taken may
   still arrive (said in the confirmation).
5. A removed phone: the page says "Also remove it from your tailnet" with a link to the admin console, and shows the
   pin line to take it out of the pin.

Removing the device you are on signs you out. Removing the last device is allowed; then W2 or W3 again.

## What is retired, and how an install moves over

| Retired | Where it is built | What replaces it |
| --- | --- | --- |
| `web_acts` (`off`, `confirm`, `trust`) and its `lowersOnly` rule | `NodeSettings` (`web_acts`, `page: .lowersOnly`), `LeadVaultV2.PageActs.level`, `setPageActs`, `Requests.pageSetRefusal`'s `.lowersOnly` case | the device key: acting needs an unlocked device (the lead's call: "the page on the same machine keeps acting as today until device keys are built, then requires the device's key") |
| the `confirm` level and its seam as built | `ActingPages.confirmBuilt`, `PasskeyNotBuilt`, `NoPageVoice`, `PageVoice` | `guard.begin` and the assertion on guarded kinds; every other act needs no seam |
| page tokens, 24 h and 8 h, and their files | `WebTokens` (`life`, `tailnetLife`, `web-tokens.json`, `web-tokens-tailnet.json`), `ActingPages.admits`/`issued`, `LeadVaultV2.addPageToken` | the handshake's signed `auth` |
| the pairing secret and confirmed pairings, 12 h | `ActingPages.confirmed`/`watches`/`acts`, `PagePairing`'s token phrase, `LeadVaultV2.addActingToken` | the unlock |
| the fragment code | `WebAccess.openCode`, `url(port:code:)`, `#pair=` | a plain address; `PairingMask` and `TerminalMask` keep masking `pair=` for old transcripts |
| way A's tailnet listener and gate | `TailnetWeb` (`TailnetWeb.bind`, the address `Tailnet.find` finds), `HostWebListen.Place.tailnet` | the serve backend (when `PhoneAccess.usersNode` is switched) |
| the terminal-led passkey words | `WebApp/js/acting.js` (`acPasskeyOrigin`, `vibeswitcher web --localhost`), `i18n.js` and `i18n-es.js` `pk…` words ("Añadir una llave de acceso (pedida desde tu terminal)"), `passkey.js`'s header ("when the terminal asks (`vibeswitcher web --passkey`)") | Set up this browser, Unlock, Add a phone |
| `status`'s `accepted` list on web connections | `Requests` (the status read a page gets) | left out for web connections (N6) |
| "a web client is never the user's voice" | the security architecture's principals, S3's table rows for `draft` and `web.*`, LW-D6 | a device's signed frame is the user's for `.acts` kinds, as recorded with its id |

**An existing install moves over** in the cut-over slice (21): the new build deletes both token files unread; the
vault's `PageActs` keys are dropped at its first start; every open page is closed with 4403 and reopens locked;
`web_acts`, if set, is ignored and `status` says once "acting from the page now needs a device: run `vibeswitcher web`
once" (Linux) or "open the page and use Touch ID" (Mac). No device is made from anything the old build left (W11).
**The handover's format is raised in slice 21**, not before (N2): from then a build before the cut-over refuses the
vault's format at its probe (as H1's format 2 does), so a rollback can't run the old trust with the new record; slice
4 adds the vault's new records without raising it, and they stay empty on the user's node until 21.

## The Mac

**The amendment to the Mac node's spec** ([the user's voice on the Mac](2026-11-19-v2-node-on-macos.md#the-users-voice-on-the-mac),
"LocalAuthentication, asked by the server per state change"), as 541E258F decided: *for a request that comes from an
unlocked device's page on loopback, the user's voice is that device's unlock, one Touch ID through the browser's
passkey (rpId `localhost`), lasting up to 12 hours; the server's own Touch ID dialog is asked for the device's first
enrolment (naming the page's words) and for every guarded kind from any page (its text the change); per-request Touch
ID stays for every state change from the command line.*

- **The daily unlock is a browser passkey** (I2), the unlock of [The key](#the-unlock), Touch ID its platform
  authenticator. So no Touch ID dialog is put up for a loopback peer's unlock: a native process of any uid that forges
  `Host` and `Origin` (they stop browsers only) can't make the server ask, and the words aren't needed at each unlock.
- **The server's dialog** is kept for the first enrolment (W3, with words), for an add's approval (the new phone's
  words) and for every guarded kind (the change's text), where a page's script can't change what the dialog shows.
  **A stated limit:** while no device exists (first setup, or after the last device is removed) any loopback client
  of any uid can send an enrolment and raise this dialog with **its own** words; approving a dialog whose words aren't
  the ones the user's own open page shows adds that client's key. The words are the only guard; the browser-peer
  check of the fallback below is not applied to it in this track.
- **The `macTouchID` fallback** for the daily unlock stays only if slice 13 finds that Safari or Chrome can't hold a
  passkey on `http://localhost`. Then the server takes a `macTouchID` unlock or enrolment only from a loopback peer it
  resolves to a known browser: the same-uid process that owns the peer socket in libproc's socket table, its code
  identity Apple-anchored Safari or one of the listed Team IDs; it refuses when the peer can't be resolved, which covers
  every other uid. The dialog then carries the words (`unlock` `{device, spki}`, no assertion, the words from a nonce
  the server picks after the key; one dialog at a time).
- **A phone paired to a Mac node** uses its passkey as on Linux; **phone access on a Mac node stays off** until slice
  17 has measured each Tailscale variant (I4).
- **The page's address at a host end** (I1): a uid process can `launchctl kill` the node's agent and bind
  `localhost:47830`; the bookmark is then its page, and the next unlock the user gives that page certifies its key. A
  limit until a root launchd daemon's `Sockets` (the BCECD1F3 install step) holds the addresses ([Open to attack](#open-to-attack) 4).
- **Refusal constants stay off until measured; no build task of this track switches one on:**
  `NodeSystem.approvalMeasured`, `HostImages.isCheckedMacNode` and the `NodeSystem.macUnbuilt` refusal (the 16:27:18
  decision), and the new `MacPageUnlock.measured`. So the Mac's slices build and test the code with a fake
  authenticator (`ApprovalVoice`'s, as `Tests/VibeNodeTests/ApprovalVoiceTests.swift` and
  `Tests/VibePlatformTests/ApprovalTests.swift` do; no test puts the real dialog up) and change nothing a user runs.
- The Mac node's vault survives restarts (Keychain) when the host is signed; its epoch is kept in the Keychain too,
  in I6's order. An unsigned Mac node (no Keychain key) takes Linux's path.

## Build order

Each slice is about 30 minutes to 2 hours, in dependency order. "Here": what this Mac proves by tests (shared code and
the Mac's arm, in a scratch clone; **"in-process" means VibeNode's in-process tests on this Mac**: the scratch-node
harness is Linux-only). "Linux, read only": what can only be read here, the Linux-only tests included. **Review**:
needs its own independent security review before it is offered. "After": the slices it must follow, because it builds
on them or touches the same function (N3: 2 and 3 share `WebAuthn.swift`, 4 needs both, 8 and 16 share
`TerminalRelay.swift`, 16 takes a file of its own rather than `WebAccess.swift`, and 19, 20 and 23 share `DeviceRequests.swift`'s
dispatch). Two slices neither of whose "After" chains reaches the other may run side by side: for example 1, 2 and 5;
13 beside 6 to 12; 16 beside 9 to 15; 17 beside 15 and 16.

**The gates.** `DeviceKeys.usersNode`, `PhoneAccess.usersNode` and `TerminalTyping.usersNode` live **in VibeCore**
(`Sources/VibeCore/V2/DeviceGates.swift`), so the server and the host (`HostWebListen.refusal`, `HostWebListeners`)
read the same constant (N2); `MacPageUnlock.measured` beside them. Each is made false and switched on only by its own
one-line slice, after the reviews, by the lead. Slices 6, 9, 10, 13 and 14 each carry a test that, with the gate false,
`hello.kinds`, the refusal set and the host's places are **byte-identical** to before. After slice 21,
`DeviceKeys.usersNode` gates nothing on the user's node; slice 24 deletes it.

| # | Slice | Files | Here | Linux, read only | Review | After |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | The frame envelope and P-256 verify: signed bytes, `seq`, `conn`, the binary type 6, fail-closed parsing | `Sources/VibeCore/V2/DeviceProof.swift`, tests | all | none | yes (with 2, 3) | none |
| 2 | The WebAuthn assertion check: `clientDataJSON` exact, `authenticatorData`, flags, sign count, the enrolled origin and place (N5); vectors recorded from real browsers | `Sources/VibeCore/V2/WebAuthn.swift`, fixtures | all; measures Safari's 7-day storage rule on a phone | none | yes | none |
| 3 | The registration check: `attestation: 'none'`, a CBOR subset for COSE EC2 P-256 only | `WebAuthn.swift` (its own type), tests | all | none | yes | 2 (same file) |
| 4 | The vault's devices and unlocks (tombstones are the server's, slice 12, since a vault write can fail): the requests, app-only, the vault verifying proofs with 2 and 3; **the handover format unchanged** (raised in 21) | `Sources/VibeCore/V2/LeadVaultV2.swift` (new requests beside `PageActs`), `Sources/VibeHost/V2/VaultV2Handler.swift`, `Sources/VibeCore/V2/DeviceGates.swift` | all | none | yes | 2, 3 |
| 5 | The page's key module: unlock key, read key, the envelope through **one ordered sign-and-send queue** (N4), `BroadcastChannel`, the stored list; the phone signing bench | `WebApp/js/devicekey.js`, its node tests (`frames leave in seq order under concurrent signs`) | the module; the bench on a real phone | none | with 1 | none |
| 6 | The handshake: `challenge` first, `auth` by unlock or read key, locked and reading connections, behind `DeviceKeys.usersNode`; the byte-identical-when-off test | `Sources/VibeNode/Web/WebAccess.swift` (`admit`), `WebSocketConnection.swift` | in-process | none | yes | 1, 4 |
| 7 | Signed frames in `WebRequestScreen.text` before `Principal.route`, closing on any unsigned or undecodable frame **before** today's fall-through to the hub; `Principal.page` with a device | `WebAccess.swift` (`WebRequestScreen.text`), `Server/Principal.swift` | in-process | none | yes | 6 |
| 8 | Signed terminal frames (type 6), screened in `WebRequestScreen.binary` before the relay's mode check, still watch-only on the user's node | `WebAccess.swift` (`WebRequestScreen.binary`), `Sources/VibeNode/Live/TerminalRelay.swift` | in-process | none | with 7 | 7 |
| 9 | The unlock kinds: `unlock.begin`, `unlock`, `device.lock`; `KindSpec` gains `.guarded` and the `webLocked` sender; the byte-identical-when-off test | `Server/KindSpec.swift`, `Server/PageRequests.swift`, a new `Server/DeviceRequests.swift` | in-process | none | yes | 6 |
| 10 | The first device: amended `web.open`, `web.pairing`, `web.confirm`, `device.enroll` in a window, behind `DeviceKeys.usersNode` (today's `web.open` with its fragment code stays as built on the user's node until slice 21); the byte-identical-when-off test | `Server/PageRequests.swift` (`webPairing`, `webConfirm`), `Server/WebRequests.swift`, `Web/PagePairing.swift`, the command line's `web` | the logic in-process | S3's voice rule on the user's node (the cgroup), the install line's ending | yes | 9 |
| 11 | The Devices list: `devices`, `device.rename`, `device.remove`, Remove all; the page's This node › Devices | `DeviceRequests.swift`, `WebApp/js/views/node.js` | all | none | with 12 | 10 |
| 12 | Removal's effects and **fail-closed tombstones** (I5): connections, streams, in-flight, push subscriptions; the fix to today's `ActingPages.revoked()` and `dropPages` | `WebAccess.swift` (`WebRequestScreen.end`), `Server/NodeLive.swift`, `Web/ActingPages.swift` | all | none | yes, covering I5 | 7, 11 |
| 13 | N7: `localhost` beside `127.0.0.1` (the latter static only), the `loopback6` place, CSP per name, behind `DeviceKeys.usersNode`; the byte-identical-when-off test; measures each browser's passkeys and service workers on `http://localhost`, `localhost`'s resolution, and the desktops' authenticators (a Mac browser's Touch ID passkey, I2) | `Web/NodeWebListener.swift`, `Sources/VibeCore/V2/HostWebListen.swift`, `Sources/VibeHost/V2/HostWebListeners.swift`, `Web/WebSecurityHeaders.swift` | all | the host's `::1` bind on Linux | **yes, the N7 review** | 4 (the gate) |
| 14 | Guarded changes: `guard.begin`, the route by device (the Mac's dialog, a phone's passkey, a Linux desktop's change sent to a phone or its terminal line), the guard before `kept` and `retry` (N6), the digest again at the act, the vault's check; `status.accepted` left out for web connections; the guarded table in `KindSpec` and `NodeSettings`; the byte-identical-when-off test | `KindSpec.swift`, `PageRequests.swift` (`pageChecks`, `pageSetRefusal`), `Server/Requests.swift` (the status read), `Settings/NodeSettings.swift` | all | none | yes | 9 |
| 15 | Each guarded kind wired, one slice each: `hooks.install`, the 13 settings and plugin settings, `config.accept` and `approve` past `pageNotSame`, `plugin.add`, `build.switch`/`build.seal` (the `update` kind and N8's and N6's kinds are their own tasks first) | each kind's request file | all | `build.switch`'s handover on Linux | **yes, each kind's digest** (`approve`'s batch digest above all) | 14 |
| 16 | Credential masking on the serve gate (`Redaction.secrets`, terminal screen masking) | a new `Web/RemoteMask.swift`, `Live/TerminalRelay.swift` (the mask's one hook), `Web/PagePairing.swift` (`TerminalMask`) | all | none | yes | 8 |
| 17 | Phone access on and off (`phone.on`, `phone.off`, the serve status parse, Turn off never leaving an entry on a free address, the setup line's check and the refusal with its words); measures `tailscale serve`'s ports, `OperatorUser`'s presence on Linux, and each Mac variant's LocalAPI writes | `Server/PhoneAccess.swift`, `Web/Tailnet.swift` | with a fake `tailscale`; the Mac variants by hand, read-only | the real `tailscale` on Linux | yes | 14 |
| 18 | The serve gate: the backend port held by the setup line's root socket unit (after its spike; else the host), the peer check, the login, peer-address and peer-OS checks, Host and Origin for `https://<name>:47830`, behind `PhoneAccess.usersNode`; way A (`TailnetWeb.bind`) stays on the user's node until that gate is switched (slice 26) | `HostWebListen.swift` (a `serve` place), `HostWebListeners.swift`, `Server/TailnetWeb.swift` (becomes the serve gate), `NodeWebListener.swift`, `Web/Tailnet.swift` (the login and whois reads) | the gate's checks with injected peers | `/proc/net/tcp`, tailscaled's uid, a WSL connection mirrored from Windows, `ServeGateTests.aWitnessFromAComputerOfTheLoginIsRefused` with the WSL Windows node as the peer, `HostWebListenTests.theBackendIsHeldWhileAServeEntryNamesIt` with a killed host | yes | 13, 17 |
| 19 | Add a phone: `device.add.open`, enrolment on the serve gate only from iOS and Android peers, `device.add.approve` by the Mac's dialog, a phone, or the terminal for a Linux node's first phone | `DeviceRequests.swift`, `WebApp/js/views/node.js`, the QR encoder in `WebApp/js` | all | the serve gate on Linux | yes | 11, 18 |
| 20 | The restart: the hint file, the recomputed digest, `device.readmit`; `pin-phones`, the pin's checks and the witness; the terminal re-admission while no phone is pinned; the Mac's Keychain epoch in I6's order | `DeviceRequests.swift`, `Server/ServerStart.swift`, the command line's `web` (and `pin-phones`), `Sources/VibeHost/VaultStorage.swift` (the epoch) | the logic with a scratch vault; the Mac arm's epoch | the host end and the real restart on Linux; `DeviceRestoreTests.aPlantedRemoteWitnessIsHeld` with a second node of the login | yes | 19 |
| 21 | **The cut-over: the first slice that acts differently for a user.** It switches `DeviceKeys.usersNode` on and raises the handover format: on the user's node acting needs an unlocked device; tokens, `web_acts` and confirmed pairings retired; the migration; the lock screen and the read key; `localhost` and `::1` held | `WebAccess.swift`, `ActingPages.swift` (removed), `WebTokens.swift` (removed), `NodeSettings.swift`, `LeadVaultV2.swift`, `WebApp/js/acting.js`, `i18n*.js` | all but the user's node | the user's node's first start after it on Linux | yes | every slice 1 to 20, and 25 (it lands alone) |
| 22 | Typing into terminals on the user's node (LW-D12 amended): loopback first, then the serve gate after 16 to 19 | `TerminalRelay.swift` (`Mode.type`), `Server/NodeLive.swift`, `WebApp/js/terminal.js` | in-process, a fake tty | the user's node on Linux | yes | 16, 21 |
| 23 | The Mac: the daily unlock by the browser's passkey, the server's dialog for the first enrolment and guarded kinds, the `macTouchID` fallback with the browser-peer check only if slice 13 forces it; `MacPageUnlock.measured` false | `Server/ApprovalVoice.swift`, `DeviceRequests.swift` | with a fake authenticator | none (the Mac arm) | yes | 20 |
| 24 | The leftovers: the page's words, `passkey.js`'s header, `DeviceKeys.usersNode` deleted, the docs' rules (S3's table, the principals, LW-D6, LW-D12, the contract's §1, §2, §8, §9) | `WebApp/js/*`, `DeviceGates.swift`, the docs | all | none | **a doc review by slice 21's reviewer** | 21 |
| 25 | The service-worker rule (C15): one worker at a fixed path, the self-unregistering answer with `Clear-Site-Data`, a click opening only the node's own paths; the push track's worker builds on it | `Web/WebAssets.swift` (the worker's path and answers), `WebApp/sw.js` | in-process; the browsers' keeping of registrations measured on an iPhone and an Android phone | none | **yes, its own** | 13 |

Then: **26**, the one-line switch of `PhoneAccess.usersNode` (after 16 to 21 and 25 and their reviews, never on a
Mac node before slice 17's measurement; it retires way A's listener on the user's node); **27**, the switch of
`TerminalTyping.usersNode` (after 22); **28**, `MacPageUnlock.measured`, only after the Mac's measurements, as
`approvalMeasured`.

**What reaches the user's node before 21.** Every slice before 21 is behind a gate that is false on the user's node
(the byte-identical tests show it), with two exceptions that only take away and land ungated on purpose: slice 12's
fail-closed fix of today's `revoked()` and `dropPages` (a revoke whose vault write fails stays a revoke), and slice
14's leaving `accepted` out of what web connections read. So slice 21 is the first that lets anyone act differently
(the cut-over); 12 and 14 are the first changes a user could notice. Slice 20 lands before 21, so no Linux host end
after the cut-over loses the devices for good.

## Open to attack

With the review's rulings: what each change closed, and what stays a stated limit.

1. **A desktop browser driven by a process of the uid.** *A stated limit* for the 12-hour unlock (accepted
   2026-11-25): a process that drives the browser (an extension written into the profile, a debugging port; on WSL a
   Windows process of the user's own account, which can also call Windows Hello with rpId `localhost` and its own
   `clientDataJSON`, expected from the API's shape, **to be measured** in slice 13) uses the unlock key. *Closed* for
   guarded changes and adds: a Linux node never takes a desktop's assertion for them (the phone, or the terminal), and a
   Mac node shows them in its own dialog. On the Mac the daily unlock is the browser's passkey, so a driver of the Mac's
   browser uses the unlock as on Linux; it can't approve a guarded change.
2. **The device list after a Linux host end.** *Closed* for a planted device, wherever its software "phone" connects
   from: a witness's key must be in the root-owned pin, and the phone's page can't be re-pointed (serve is root's).
   *A stated limit:* a rollback past a removal no pinned phone saw before the pin line was run again; a worker that
   replaced the user's command line making `pin-phones` print its key (T12, accepted; the printed names and words are
   the user's check); and the peer-OS rule, which rests on the peer's tailscaled reporting its OS honestly (to be
   measured, slice 18). What I3 showed, kept here: a witness whose key comes from the same file it vouches for is
   passable by any other node of the login (the WSL machine's own Windows side included), which is why only a pinned
   key witnesses.
3. **The serve backend and the serve configuration.** *Closed* on Linux: the backend is a TCP port (no socket a uid
   process can rename) held by the setup line's root socket unit across host ends, never released while a serve entry
   names it, so Turn off never leaves an entry on a free address; and the uid can't change serve (phone access refuses
   while it can). If slice 18's spike finds a system unit can't pass the socket, the host holds it and a host end is
   at S11 item 3's level. *Phone access on a Mac node stays off* until slice 17 finds a way to deny the uid's LocalAPI
   writes (I4). The 30-second look and the service-worker rule stay as defence in depth.
4. **The page's address: rpId `localhost`, and a host end.** *A stated limit*: every dev server a session runs shares
   the rpId (it can't use an assertion, the origin is checked, but it can put Touch ID or Windows Hello sheets up and
   train the user to approve them). *A stated limit* on the Mac and in strong mode: a process that ends the host can
   bind `localhost:47830` and `[::1]:47830` (C2 holds `::1` only while the host runs), and the bookmark is its page
   until the host is back, its next unlock certifying the squatter's key; the service-worker rule bounds it to about a
   day. On Linux plain mode it is at S11 item 3's level. Closed only when a root-owned service holds the desktop page's
   addresses too, which this track doesn't build (the setup line's unit holds the phone's backend only).
5. **Prompt fatigue on the Mac.** *Closed* for the daily unlock: it is a passkey, so no process can make the server
   put an unlock dialog up. The guarded kinds' dialogs (with the change's text) need the user's unlocked page to be
   asked. *A stated limit:* the first enrolment's dialog, which any loopback client of any uid can raise **with its own
   words** while no device exists; the user must approve only words their own open page shows.
6. **Synced passkeys.** *A stated limit*: a phone's passkey syncs (iCloud Keychain), so the device is "this passkey",
   on every device of that account; an account taken over carries it, still needing the tailnet, the login check and
   the node's list. The Devices list shows "synced with your Apple account" from the backup flag.

## For the user to decide

**Nothing.** The review left two questions to the user, and both were answered on 2026-11-26:

- **Linux after a host end** (A64D1FC7): each phone's key pinned in a root-owned record, one `sudo` line per phone
  added or removed; after a restart the pinned phone's Face ID brings the list back, with no terminal confirmation per
  restart ([the pin](#where-the-node-keeps-the-devices)). Not chosen: no witness and the terminal after every host end.
- **Who sets `tailscale serve`** (CB1AC032, superseding N5): one `sudo` line once per machine at setup, which sets
  serve and its backend so the user's account can't change them; Turn on phone access then just works; the node
  refuses phone access where the uid could change serve; on a Mac node phone access stays off until slice 17
  measures the variants ([the phone's path](#the-phones-path)). Not chosen: the node setting serve itself.
