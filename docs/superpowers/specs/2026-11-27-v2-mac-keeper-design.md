# The Mac node's keeper: a root-owned anchor for the node's record

Status: **design, its review's fix round, nothing built** (2026-11-27, branch `v2-mac-keeper-design-fix` off
`v2-mac-keeper-design` `cf7f8738`, itself off `v2-mac-journal-design` `2c10b90c`). The independent security review of
`cf7f8738` (`REVIEW-keeper-design.md`, 2026-11-27: "sound with changes", conditional; 4 Important, 8 Doubt, 6 Nit,
F1 to F18, and 10 added paths) is answered here, with the lead's rulings of 2026-11-27 (every Important change
adopted; the keeper's program built as root from verified source, its step triggered by the commit's keeper sources;
the node doesn't start while its keeper isn't answering) and the user's acceptance of F3's limit (8B298106,
2026-11-27). [Review of 2026-11-27: the answers](#review-of-2026-11-27-the-answers), at the end, lists each finding
and each added path and where it is answered, for the short re-check that follows. No code, no install, no `sudo`,
no Keychain call, no refusal constant touched (`approvalMeasured`, `isCheckedMacNode`, `macUnbuilt` stay as they
are). The user chose this keeper on 2026-11-27 (question 9CDB5A99): one more `sudo` line at setup, and while the keeper
is down the node refuses the changes that ask for Touch ID. The user then took the journal design's three smaller
recommendations (90BBAD80); this document says which of them the keeper makes moot and which remain.

**Two things called "keeper".** In this document **the keeper** is the new root-owned process,
`vibeswitcher-keeper`. The process a switch already parks its state with (`MacHandoverKeeper`,
`--handover-keeper`, the Mac spec's "A switch") is always called **the handover keeper** here. They share a proof
pattern (a fresh socket pair, below) and nothing else.

Read with the [journal design](2026-11-27-v2-mac-journal-design.md) (its threat table, "One writer", "Fail closed",
P30 to P42, "For the reviewer: the keeper", the build order J0a to J11), [the node on macOS](2026-11-19-v2-node-on-macos.md)
("The anchor: a root-owned record of the builds", "The checked node start", "Rows 7 and 10") and the measurement
record ([v2-mac-measurements](../../process/v2-mac-measurements.md), newest copy on `v2-mac-runbook`; M7, M13, rows 4,
5, 7, 10, 12). Code is read at this branch's base (`v2-mac-anchored-cli` `b15e0052`): `NodePins.swift`,
`RootRecord.swift`, `CodeIdentity+Darwin.swift`, `Sockets+Darwin.swift`, `SocketMaking+Darwin.swift`,
`Spawn+Darwin.swift`, `MacHandoverKeeper.swift`, `VaultStorage.swift`, `scripts/node-pins-mac.sh`,
`scripts/install-node-mac.sh`; main's `5e98c1fc` (the started-over vault). Each statement about macOS is **measured**
(with its M- or K- source, or the Mac spec's sentence where only that is kept: F6), **read** (with the file), or **not measured** (with its K-M number in
[Measurements owed](#measurements-owed)); the design fails closed either way each K-M falls, and says what changes
where one would change it.

## For you, in one page

**What it is.** A small program that runs as the system (root), started by macOS at boot. It holds three things for
your node: the key your node's record is sealed with, the record's check (which entry is the newest), and your
devices' check. It gives them only to your node's real host program, which it recognises by the code fingerprint your
install writes where only an administrator can (the same record your command line's check uses). Day to day, nothing
else running as you can read the key or move the checks: not an agent session, not a script it wrote, not a program
signed with your signing identity. The one exception is an update you run while a program of yours rewrites your
node's build: see "What it doesn't" below.

**What it changes for you.**

- **Setup:** the install asks your password once more, to put the keeper in place. The system builds the keeper's
  program itself, from the commit's own source checked piece by piece, so nothing of yours can rewrite that program on
  the way (what a program of yours can still choose is below, in "What it doesn't"). Updates ask once, as today; a second time only in an update that changes the keeper's own source.
- **Day to day:** nothing. Locking your login keychain no longer pauses anything of the node, and nothing of the node
  is in your login keychain any more.
- **If the keeper isn't answering** (it is being updated, it broke, or a program of yours keeps it busy, as one could
  keep your keychain locked before): changes that ask for Touch ID are refused until it answers again, with words that
  say so. If it isn't answering when your node starts, the node waits a minute, then doesn't start, and says why. That
  is stricter than what you chose (that the node refuse the changes that ask for Touch ID): it was chosen so that no
  half-working node is ever left running, and you were told (the lead, 2026-11-27). The words send you to your
  password only for something nothing of yours can cause: the keeper not installed at all, or its own store damaged
  (both the system's files); when it is installed but busy or not running, they never do, since a program of yours
  could cause those to lead you there.
- **If its store is ever lost** (a disk fault, a new Mac without it): your node's record begins again with a notice,
  and each setting the node checks waits for your accept once, as after any record that begins again.

**What it closes** (each was a stated limit of the journal design; outside the update below): a program of yours
putting an older record back with the check set to match, replacing the node's key and whole record with its own,
putting your whole keychain file back, signing itself as the node to read the record's secrets, or timing two copies
of the node to undo a change of yours.

**What it doesn't:**

- **An update during which a program of yours rewrote your node's build.** Your node's programs are still built
  under your account, as before the keeper. If a program of yours rewrites the node's host program while you install
  or update, the install records that program as your node's real host, and the keeper then gives it the key and both
  checks: it can read every secret in your node's record and rewrite the record without a notice. The key never
  changes, so a key read once keeps opening your node's record until you make a new one. **You accepted this limit on
  2026-11-27 (question 8B298106).** Closing it would need every program of the node built by the system, which isn't
  proposed. If you ever suspect it happened: install afresh, run `node-pins-mac.sh --keep 1` so only that fresh build
  is served, then run the keeper's `--remove --forget-store` and its setup line again for a new key; your node's record
  then begins again with a notice.
- **The keeper's own program has a smaller window.** A program of yours that rewrites the build or your checkout can't
  change it, since the system builds it from the commit's checked source. What a program of yours can still do is
  choose what you install: rewrite the install script itself, so that the password you type runs what it wants (as it
  could by faking any password prompt: root is one password away), and so hand the system a commit of its own making;
  without rewriting the script, it can only choose among commits that are on v2 and passed both CI runners.
- A program of yours can still kill the node, delete or put back its record file (each shows as a notice and holds the
  devices, as today), keep the keeper busy so that your node can't start or make guarded changes, and run your node's
  own genuine program; the keeper can't tell that program's modes apart, and the node's own code is what keeps its
  other modes away from the keeper.

## What the keeper anchors, and how

The journal design's goal sentence lists the journal's counter and head, the device list, review floors and checked
settings. The keeper stores only the first and a check of the second; the rest is anchored through them, because
everything else lives in the node's sealed vault (`~/.vibeswitcher/v2/node/lead/vault.sealed`), sealed under a key
only the keeper and the checked host's memory hold, and every guarded change of it is a counted journal entry
(journal, "What the counter covers").

| What | Where it lives | What anchors it with the keeper | What a vault file put back at the same seq still loses |
| --- | --- | --- | --- |
| The journal's counter and head (`{record, seq, bind}`, journal "One writer" 3) | the keeper's `journal` slot | the slot itself: root's file, moved only by the keeper's atomic swap for a proven pinned host | nothing: it is the anchor |
| The journal's entries | the sealed vault | ChaChaPoly under the keeper's key (nothing of yours can seal), the last entry bound by the slot's `bind` | an uncounted `ack` (it only reopens what it covered: journal) |
| The device list | the sealed vault | the key; an add is a `guarded` entry, a removal a `revoked` entry, both counted; slice 20's device epoch in the keeper's `devices` slot (its encoding and what raises it are device keys', **not read here**) | nothing counted; an uncounted revocation (journal P36, unchanged) |
| Review floors, the 13 settings, rails, hooks, plugins | the sealed vault | the key; each change a `guarded` entry, acting only once counted | nothing |
| First-look baselines (the checked settings' seals) | the sealed vault | the key; held on every record that begins again (journal I3) | nothing |
| The vault's secrets | the sealed vault | the key never leaves the keeper and the memory of a checked host the pins record pins: confidentiality closes (P30's reading), except for a host pinned through an update a session rewrote (KP6a, accepted by the user) | — |
| A request's record (rule 8), a page's draft | the sealed vault | the key (unforgeable), not the counter | yes, as today (journal P28) |

**Not taken:** a keeper that holds a hash of the whole vault (the journal's form (ii)): every seal would be a keeper
call, and P30's reading of secrets would stay open. A keeper that holds the key alone, the counter left in the login
Keychain: leaves P35 open. Both were set aside in the journal design; this is its form (i).

## The threat, in the journal design's terms

The journal's threat table names a process of your account (an agent session, a script it wrote) that **edits
files**, **rewrites Keychain items**, **kills or copies the node**, or **signs itself with the local identity**. For
each, with the keeper:

| What the process does | Prevented | Only detected | Stated limit |
| --- | --- | --- | --- |
| **Edits files** under the node's root: deletes, truncates, rewrites or puts back `vault.sealed`; deletes or replaces `host.lock`; edits the plist or `bin/` | rewriting or forging the vault's contents (no key); putting an older vault back with a matching check (the slot is root's): P13, P29, P34's rollback form | a deleted, truncated, older or ahead file (journal "Fail closed" rows 2 to 7a: open, first looks and devices held); a replaced lock (`lock.lost`); a plist or `bin/` change (rows 7 and 10, the checked start) | devices held at will by putting an older copy back (90BBAD80 (2), below); `lock.lost` at will by replacing the lock (same); uncounted vault changes lost to a same-seq put-back (P28) |
| **Rewrites Keychain items**, deletes and plants them, locks the login keychain, puts `login.keychain-db` back | everything it did to the node: the node keeps **no** Keychain item (the key and checks are the keeper's), so P34, P35 and the planted item of the journal's Open for the user 4 no longer reach the record; locking the keychain refuses nothing | — | the Mac app's own vault (`lead-vault`, main's) is still in the login Keychain: the app's concern, not this design's |
| **Kills the node** (the host, its server child), or keeps killing it | — | each end is an open entry (journal P6, P11); a kill between a raise and its seal reads as `older` (P18) | a denial (journal P32, accepted) |
| **Copies the node**: copies its files, or runs its genuine pinned host beside it (a second checked start, journal P40), or in another mode (the deputy, P33), or an older pinned build (P41) | a copied vault file is ciphertext under a key it can't get; two checked hosts can't both continue the record: the keeper's swap is one atomic compare-and-set, so the loser's raise fails and it writes nothing (P40, its residue included) | the second host's start (open), the loser's `lock.lost`; an older pinned build's start (the unswitched-build rule, P41) | the keeper can't tell the genuine host's modes apart: only J0a's rule 2 (only the checked start calls the keeper) keeps the other modes away, as it keeps them from the Keychain today; every pinned build is served (the `--keep 1` lever, the Mac spec's F8) |
| **Signs itself with the local identity** (holder (4) of the journal's table), or is a program you once clicked Always Allow for (holder (5)) | P30 for the node's record: the keeper serves by the cdhash of the code running, pinned by the install's administrator step, never by a signing identity, team or designated requirement; a program of its own code has another cdhash. The genuine host signed again is either other code, with another cdhash (refused), or the same cdhash, which is the genuine code (served, harmlessly). Which of the two it is (the code directory carries the requirements' hash) is K-M11, kept as information: it gates nothing | — | none for the record |
| **Talks to the keeper** itself: connects, sends requests, sends a pair it made, sends an end of a connection that isn't a pair, writes a request then execs the pinned host, points the host's `--handover-keeper-channel` at the keeper, or holds an end of a pair the genuine host made (by replacing the host's parser launcher, the review's F1) | getting the key or moving a slot: only an end of a socket pair (unnamed on both sides) made by a pinned, hardened host of your uid, which also sent the proof, is served; the maker is proven by the pair's token, fixed when the pair was made (the Mac spec's result, kept there only as a sentence: K-M1 reruns it in KP10's order and keeps the probe, F6; telling a pair's end from a connection's: K-M1 (d)); and the host gives no end of a pair it writes on to code that hasn't proven itself, in any mode (KP20, K4a) | — | **keeping the keeper busy** (a flood of connections) is a denial your account can cause at will, as it could lock the login keychain before: guarded changes refused, a node that doesn't start while it lasts, and the journal's at-will levers through a failed raise (P36's uncounted revocation, P42's file ahead) reachable through it as they were through the locked keychain ([While the keeper is down](#while-the-node-is-down-and-while-the-keeper-is-down)) |
| **Impersonates the keeper** (a socket of its own, a listener elsewhere) | the keeper's folder is root's (the host walks it as `readRootRecord` walks the pins'), and the host requires the listener at its socket to be root (K-M2) | — | — |
| **Edits the build during an install or update you run** (the node's programs are built and signed under your account; the keeper's program is built by root) | for **the keeper's program**: any rewrite of the build, the checkout or the build's output, since root builds the keeper alone from the commit's objects, every hash recomputed in a root-owned folder, with root's toolchain and nothing of your account's (KP21); and forcing the keeper step at a node update by rewriting the build, since the step runs only when the commit's keeper source tree differs from the one root recorded (KP23a) | — | **for the node's programs (KP6a, the review's F3): an update during which a session rewrote the host's build pins that host, and the keeper then serves it the key and both slots**: it reads every secret of the vault and can seal any vault and swap either slot, for as long as its row stays (`--keep 1` keeps only the build just installed, which is this one); the key never rotates, so one success lasts until a new key (F17). The install's window (the Mac spec's S9) gave a session nothing P34 didn't before the keeper; with it, this is the route to everything the keeper closes, at every update. **Accepted by the user, 2026-11-27 (8B298106)**, stated, not closed (closing it would need every program built as root). The remedy after a suspected compromise: a fresh install, `node-pins-mac.sh --keep 1`, then the keeper step's `--remove --forget-store` and `--install` for a new key; the record begins again. **For the keeper's program, what remains:** the choice of commit (bounded by the install's provenance check: on v2, both runners passed), and a session that rewrites the install script itself, which can then hand root a self-consistent commit of its own making (root checks the objects' hashes, not who wrote them): S1's class ("root is one password away"), as a faked `sudo` prompt is |
| **Another uid's process** | getting anything: the keeper closes any connection whose `getpeereid` isn't its uid before reading a byte | — | it can keep the keeper busy too (a denial, fail closed), unless K-M6 shows an access entry for your account alone on the socket is honoured by `connect` |
| **Root**, or a program that takes the host's task port (the Developer Tools dialog first) | out of scope (S1), as today; and S11 item 3 (becoming the host), accepted | — | a Time Machine restore of the keeper's store (an administrator's act) rolls it back: [Open questions](#open-questions-for-the-lead-or-the-user) 2 |

## The keeper, as small as it holds

### What it stores, and where

Everything of one account's keeper is in one folder only root can change, beside the pins record the install
already writes:

```
/Library/Application Support/VibeSwitcher/                       root:wheel 0755  (the pins step makes it, today)
    node-<uid>.pins                                              root:wheel 0644  (the pins step, today)
    keeper-<uid>/                                                root:wheel 0755  (the keeper step)
        vibeswitcher-keeper                                      root:wheel 0755  (the program, built and signed by root)
        installed                                                root:wheel 0644  (the keeper step: source tree id, cdhash)
        keeper.sock                                              root:wheel 0666  (made by the keeper at each start)
        build/                                                   root:wheel 0700  (the keeper step's root build, while it runs)
        store/                                                   root:wheel 0700  (the keeper step)
            node.keep                                            root:wheel 0600  (written by the keeper alone)
            lock                                                 root:wheel 0600  (the keeper's lock, held for its life)
/Library/LaunchDaemons/dev.vibeswitcher.keeper.<uid>.plist       root:wheel 0644  (the keeper step)
```

`installed` is two lines, `tree <40 lowercase hex>` (the keeper's source tree id at the commit root built it from,
`git rev-parse <commit>:Keeper`) and `cdhash <40 lowercase hex>` (the program root built and signed from it). Any
account can read it; only the keeper step writes it. **One keeper process per store:** at its start the keeper opens
`store/lock` (`O_CREAT|O_NOFOLLOW`, `0600`) and takes an exclusive `flock` on it without waiting, held for its life;
a lock already held and it exits, having served nothing (the review's F8: two keepers on one store would each read a
slot as X and each answer `ok` to a swap from X, P40's residue back). No process of your account can open that file.

One keeper per account that runs a node (label `dev.vibeswitcher.keeper.<uid>`), so one account's keeper serves one
uid's store and record, and a removal is one account's alone. The socket's path is 64 bytes for a three-digit uid
(the Mac's limit is 104). The socket is **root's**, `0666`, so any process may connect and none of your account's can
`chmod` it shut (a socket of your account's, `0600`, would let a program of yours make it `000` until the next boot);
the keeper closes any connection whose `getpeereid` isn't its uid before reading a byte. Every check below is by the
caller's code, not by the file's mode. Whether an access entry for your account alone (`chmod +a` by the keeper
step) is honoured by `connect`, which would keep other accounts out too: **not measured**, K-M6; without it, another
account can only keep the keeper busy, as yours can.

**The store** is text, parsed whole and refused whole on anything unusual (the pins record's rules, `NodePins.parse`):

```
# VibeSwitcher keeper store: written by vibeswitcher-keeper alone; read by it alone
format 1
uid 501
key <64 lowercase hex>                (absent until the first open)
slot journal <128 lowercase hex>      (absent until its first swap)
slot devices <128 lowercase hex>      (absent until its first swap)
```

Lines in that order, each at most once, at most 1 KiB, printable ASCII and `\n` only; `uid` the keeper's own. The
keeper reads it through the same walk as `readRootRecord` (from `/`, `O_NOFOLLOW` at each step, root's alone, no ACL),
and also requires `store/` and `node.keep` to be readable by root alone (`0700`, `0600`). **Each write** is a new file
`store/.node.keep.<random>` (`O_CREAT|O_EXCL|O_NOFOLLOW`, `0600`), written, `fsync`ed, renamed over `node.keep`, and
the folder `fsync`ed, before the answer is written (whether APFS needs `F_FULLFSYNC` for this: K-M4). A crash leaves
the old store or the new, never a mix. Slots are 64 opaque bytes: the keeper never parses a journal, a record id or an
epoch. The host writes `{record, seq, bind}` (16 + 8 + 32 bytes, 8 zero bytes after) in `journal`; slice 20 decides
what goes in `devices`, and **it must be a value your account can't compute**, bound to the sealed vault as `bind` is
(the review's F12): a `swap` needs only the slot's present value, so a plain counter there could be guessed, and any
path that let a request through would move it at will (the vault's epoch then mismatched, your devices held). That is
handed to slice 20's reviewer with K4's seam; until it is settled, this design cites `expected`'s secrecy for the
`journal` slot alone.

**A store it can't read** (it doesn't parse, its folder or file isn't root's alone, its uid isn't the keeper's): the
keeper answers `damaged` to every request and changes nothing, never making a new key over it. Only the keeper step's
`--start-over` (your `sudo`) moves it aside, renamed `node.keep.set-aside-<date>`, never deleted, and the next open
makes a new key. **A store that isn't there** (only root can delete one): the next open makes a key, and the node's
file then doesn't open (`unreadable`, open, first looks and devices held).

### What it does, and what it never does

Two requests, one per connection, served one at a time by the one keeper process that holds the store's lock (so each
swap is atomic without another lock):

- **`open`**: the account's key (32 bytes from `SecRandomCopyBytes`, made and written to the store at the first
  `open`, never taken from a caller) and both slots as they are (present or absent). The host's start, and the
  read-back below. **The key never rotates** (the review's F17): a key read once (through KP6a, through a bug in a
  pinned build fixed later, or from a backup: [Open questions](#open-questions-for-the-lead-or-the-user) 2) opens and
  forges every later vault file until the record begins again under a new key. The remedy, beside the Mac spec's F8
  lever (`--keep 1`, which drops older builds from the keeper's service): `node-pins-mac.sh --keep 1`, then the keeper
  step's `--remove --forget-store` and `--install` again; the next `open` makes a new key, and the node's file then
  doesn't open (`unreadable`, open, first looks and devices held), so its record begins again.
- **`swap(slot, expected, new)`**: if the slot holds `expected` (absent counts as a value), it becomes `new`, written
  to the store before the answer, and the answer is `ok`; else nothing changes and the answer is `moved`. No delete,
  no read of one slot alone, no "set whatever".

It never: reads anything under a user's home, takes a value from its environment, runs a program, opens a network
socket, watches the node, keeps state between connections, logs a secret, or answers on any connection but a proven
pair. It takes exactly one argument, `--uid <decimal>`, from its plist (root's); any other argument, or none, and it
exits. **Its folder is its own executable's** (the review's F16): as root it reads its own path (`proc_pidpath` of its
own pid), which must be exactly `/Library/Application Support/VibeSwitcher/keeper-<uid>/vibeswitcher-keeper` or the
trial's `/Library/Application Support/VibeSwitcher-trial/keeper-<uid>/vibeswitcher-keeper` for its `--uid`, walked
from `/` as `readRootRecord` walks (root's alone, no link, no ACL); its socket, store and lock are in that folder, and
the pins record it reads is that folder's sibling `node-<uid>.pins` (the pins step's own two paths, node and trial,
`node-pins-mac.sh`'s `--record`). Any other path, and it exits having opened nothing. So a trial keeper never opens
the real store or the real pins record, and the program takes no path from anyone
(`KeeperTests.theTrialKeeperNeverOpensTheRealStore`). Its diagnosis goes to the unified log under
`dev.vibeswitcher.keeper` (refusals, with the caller's pid and the reason), which nothing reads.

**Its program** is built by root from the commit's source ([Install, update and removal](#install-update-and-removal)),
so it is **a package of its own with no dependency**, decided before K0 (the lead, 2026-11-27, Open questions 7): the
folder `Keeper/` at the repository's top, one tree object at any commit (`<commit>:Keeper`, whose id is what root
records), holding its own `Package.swift` that names no package, the library target `VibeKeep`, the executable target
`vibeswitcher-keeper` (linking `VibeKeep` alone) and their tests (`Keeper/Tests/VibeKeepTests`). Its sources import
only `Foundation`, `Security` and the C library. The repository's own package names it by path (`.package(path:
"Keeper")`, in the Mac's half and the Linux half of `Package.swift`), and `VibePlatform` and `VibeCore` depend on
`VibeKeep`, so each moved part has one implementation. **What moves into `VibeKeep`, unchanged**, each old name kept
as a one-line call into it, so no caller changes:

- from `VibeCore`: `Sources/VibeCore/V2/NodePins.swift`, whole (one parser for the record), with the pins record's
  path (`Service+Darwin.swift`'s `nodePinsRecord`, which `NodePins.installedPath` calls; `Platform.Service` keeps the
  name);
- from `VibePlatform`: `RootRecord.swift` (`readRootRecord`, `RootRecordRefusal`) with `RootRecord+Darwin.swift` and
  `RootRecord+Linux.swift` (`hasExtendedACL`); from `CodeIdentity+Darwin.swift`, the dynamic check by audit token
  (`System.guest`, `System.runs(_:cdhash:)`, `System.isHardened(_:)` and `isHardened(status:)`; the rest of
  `CodeIdentity`, a file's cdhash, its own, architectures, stays); from `Sockets+Darwin.swift`, `peerUID`, `peerToken`
  and `audit_token_t`'s `pid`, `pidVersion` and `sameImage` (`Platform.PeerToken` stays the alias).

Read at `b15e0052`, these use nothing else of `VibePlatform` or `VibeCore` but each other (`NodePins` refers, beyond
Foundation and itself, only to `Platform.Files.readRootRecord` and `Platform.Service.nodePinsRecord`; the walk calls
`hasExtendedACL`; the rest calls the C library and Security), so as far as reading shows the list is closed; K0
proves it by building `VibeKeep` with no import of either module, and any helper that build finds is moved or written
again small in `VibeKeep`, listed in K0's commit. **New in `VibeKeep`:** the
store's format and its write, the wire's (hello, request, answer), and the keeper's own receive of one descriptor,
whose rules are the keeper's (exactly one, every other closed: F7), not `SocketDescriptors+Darwin.swift`'s. Two lints
(K0): `KeeperLintTests.theKeeperPackageNamesNoDependency` (its manifest names no package, its sources import only
`Foundation`, `Security` and the C library) and `KeeperLintTests.theKeeperLinksOnlyVibeKeep`. The less a root process
links, and the less root compiles, the less there is to review.

### The interface: how the keeper knows the caller is the genuine node

**Transport.** A Unix stream socket, `keeper-<uid>/keeper.sock`. The connection made to it carries one message, the
**proof**, the pattern the handover keeper already uses (`MacHandoverKeeper.swift`'s header: "each proof is a pair
made by the process proving itself, after its exec, one end sent over the channel it inherited; the inherited
channel's own token proves nothing"). The keeper asks the connection's token once, at the receipt, only as a second,
narrowing check (step 2: the sender is the pair's maker); alone it proves nothing:

1. **The host** (its client, `NodeAnchor`'s keeper store; [The host's side](#the-hosts-side)) walks the keeper's
   folder as `readRootRecord` walks (root's alone, no link), connects to `keeper.sock`, and requires the listener's
   `getpeereid` to be uid 0 (K-M2; anything else: it sends nothing and treats the keeper as down). It makes a fresh
   stream pair (`Platform.Sockets.pair`), and sends one end with the 23 bytes `vibeswitcher-keeper-v1\n` in **one**
   `sendmsg` carrying **one** descriptor. It then writes one request on its own end, shuts its write side, reads the
   answer to its end, and closes both ends: one pair per request.
2. **The keeper**, on the connection: `getpeereid` its uid (else close, nothing read); within 1 s, one `recvmsg`
   whose data is exactly those 23 bytes and whose control data is exactly one `SCM_RIGHTS` with exactly one descriptor,
   no truncation (neither `MSG_TRUNC` nor `MSG_CTRUNC`); else close. Its control buffer is sized for the most
   descriptors one message can carry, so every descriptor a hello brings lands in the buffer, and **every descriptor
   received is closed but the one taken, on a refusal too** (the review's F7: a hello carrying many descriptors must not
   leak them into the root process until its table fills, which `KeepAlive` wouldn't end; whether XNU installs
   descriptors that don't fit a smaller buffer, and the most one message carries: K-M10 (b)). It sets the one it takes
   close-on-exec, requires it to be an `AF_UNIX` `SOCK_STREAM`
   socket **and an end of a socket pair**: `getsockname` and `getpeername` both an `AF_UNIX` address with no path. An
   end of a connection made by `connect` to a bound listener has the listener's path on one side, which stays in the
   socket's address after the path is unlinked (**not measured**, K-M1 (d)), so it is refused. It takes the
   connection's own token at the receipt (the hello's sender) and requires its pid and pidversion to be the pair's
   token's (3): the process that sent the proof made the pair. It closes the connection having written nothing on it,
   and talks only over the received end.
3. **The pair's token** (`LOCAL_PEERTOKEN` on the received end) names the process that made the pair, its pid and
   pidversion, **fixed when the pair was made**: the Mac spec's result (`2026-11-19-v2-node-on-macos.md`, its "The
   fake host" paragraph: "fixed at creation: not 'the last sender'"), on which the handover keeper rests too, but kept
   there only as a sentence: neither `pair.c` nor its output is in the measurement record (the review's F6). K-M1
   runs it again in exactly KP10's order (the token asked after the maker's exec, and after a forked holder of the
   maker's end writes and reads) and keeps the probe and its output as a row of the record, which this design then
   cites in place of the sentence; K2 waits on that row. The keeper requires, from that token: its
   effective and real uid the keeper's uid; Security's dynamic check (`SecCodeCopyGuestWithAttributes` with the audit
   token, then `SecCodeCheckValidity` against `cdhash H"…"`, `CodeIdentity+Darwin.swift`'s `runs`) passing for the
   **host** cdhash of a row of the account's pins record, read afresh for this request (`NodePins.read`, the walk from
   `/`); and the Hardened Runtime (valid, `CS_RUNTIME`, no `get-task-allow`, not debugged: `isHardened`). A server's or
   a command line's cdhash is refused, though the record pins them: only a host asks.
4. **The request**, read on the pair to its end of file within 2 s: the 8 bytes `vskeep1\n`, one verb byte and the
   verb's fixed length (`open`: 9 bytes in all; `swap`: 139: slot, expected's presence, expected, new). Anything else
   (another length, another prefix, an unknown verb or slot, control data, more than one request): close, nothing
   answered. The prefix keeps another protocol's bytes on a pair from reading as a request.
5. **The token is read again from the received end** after the request is read (the review's F5): `LOCAL_PEERTOKEN`
   on that end a second time, never the first token re-validated; it must equal the first (pid and pidversion), and
   Security's check and the hardened check run on it again (Security refuses a token whose process exec'd since:
   measured for a connected socket's token in M7; for a pair's, K-M1). **A pair whose other end is closed is
   refused**: the host's client half-closes (`shutdown(SHUT_WR)`) and keeps its end open for the answer, so a closed
   other end is never the genuine client's, and a genuine end whose holder only ever closes (as the parser link does)
   can't carry a request. What the second read returns once the other end is closed, and once it is only half-closed,
   is K-M1 (e); if a closed end's token still reads, the keeper tells it otherwise (a `POLLHUP` on the received end is
   the candidate, measured in the same probe), and K2 waits on that answer. Then the keeper acts and answers on the
   pair:
   `open`: status, the key, each slot's presence and value (163 bytes); `swap`: status. Statuses: `ok`, `moved`,
   `damaged`, `unwritable` (the store's write failed), and the refusals `noRecord` (the pins record refused, with its
   reason's code), `notPinned`, `notHardened`, `wrongUid`, so the host's words can say why. A refusal carries nothing of
   the store.

**Why a pair and not the connection's own token.** The connection's token isn't fixed: on the Mac it is "whichever
process last sent or received on the peer's socket, so it moves to a forked child that writes, and names the new image
after the connector's exec" (`Sockets+Darwin.swift`, `peerToken`'s comment; read, not measured; the comment speaks of
every socket, and for a pair it disagrees with the Mac spec's result, so K-M1's row settles each and K2 corrects the
comment to it). So a process could
connect, write a request, and exec the pinned host while a sibling holding a copy of the descriptor waits to read the
answer: the token read after the request would name genuine code. The same holds for **any end that isn't a pair's**
handed to the keeper: a session that connects to a listener of its own, gives the accepted end to a pinned image
(inherited, in a mode that reads or writes it) and sends the connecting end to the keeper would have a token naming
genuine code while its sibling reads the answer; so the keeper takes only a pair's end (step 2). A pair's token names
its maker as it was when it made the pair (the Mac spec's result, pending K-M1's row: F6); a maker that execs
afterwards is refused by Security; a maker that is a pinned host is genuine code. **Where the answer goes:** the
keeper writes on the end it received, so its answer is read on the pair's other end, which the maker holds unless it
gave it away; and the request it reads is what that end's holder wrote. So the host keeps both ends of every keeper
pair, and gives no end of a pair it writes on to a process that hasn't proven it runs the image's code
([The host's side](#the-hosts-side)).
**If K-M1 finds a pair's token moves too** (to a process that later sends or receives on the maker's end), the pair
proves nothing and K2 isn't built: the transport becomes an XPC service checking each message's sender against the
pinned cdhashes (`xpc_connection_set_peer_code_signing_requirement`, public since macOS 12), with a measurement of its
own. The design waits on K-M1 rather than handling either case.

**How this relates to rows 7 and 10's record.** The keeper adds no fingerprint list of its own. It reads the same
`node-<uid>.pins` (BCECD1F3) through the same reader, `NodePins.read` and `readRootRecord`'s walk, that the checked
start (rows 4, 5), the server's anchor for the command line (row 7) and the host check across a switch (row 10) read;
it takes only the `host` column. So the install's one administrator step stays the only writer of code fingerprints:
an update's pins step is all the keeper needs to serve the new build, a rollback's build is served while the record
keeps it, and `node-pins-mac.sh --keep 1` drops older builds from the keeper's service at their next request (the Mac
spec's F8 lever reaches the record too). The signing identity plays no part: the record pins cdhashes, and unsigned
(ad hoc) builds work, since a build's key no longer follows its signature.

### The host's side

The node's host reaches the keeper only through one seam, `NodeAnchor` (J0a's `NodeKeychain`, renamed: [What changes
in the journal design](#what-changes-in-the-journal-design)), with two stores: in memory (tests) and the keeper's
client. There is no Keychain store and no fallback to one. The client's rules, each a test in K4:

- **Only the checked node start calls it** (J0a's rule 2, `HostJournalTests.noOtherModeTouchesTheNodesItems`, its
  keeper arm). The keeper can't tell the genuine host's modes apart; this code is what keeps the deputy away.
- **It makes its own connection and pair, for one request, and keeps neither**: no keeper descriptor outlives its
  request, so none can be in a handover parcel, inherited, or reached later. It never takes a descriptor from its
  arguments, its environment or a parcel.
- **Every spawn sets `POSIX_SPAWN_CLOEXEC_DEFAULT`, in every mode of the image** (the review's F1 (b); KP20b).
  `Platform.Sockets.pair` sets close-on-exec after `socketpair` (`SocketMaking+Darwin.swift`: macOS has no flag for it
  at creation), so a spawn on another thread in between inherits whatever isn't close-on-exec yet, **both ends** of a
  pair being made included; and a holder of both ends of a genuine pair writes the request and reads the answer
  itself, which no rule on the keeper's side can stop. `Spawn+Darwin.swift:36` sets the flag only when a spawn names
  what it keeps, so every `Platform.Spawn` in the image names `keep` (empty when it keeps nothing), its in-place form
  too (`replaceProcess`: `HostHandover.swift:292`, `HandoverMemory.swift:183` and `:202`); `PipeCommand+Darwin.swift:42`'s
  own `posix_spawn` of `/bin/sh` sets it, or the lint shows the image never calls it; and the launcher's `execv` of a
  session's program (`PTYSpawn.swift:25`) runs in a process that holds only what its own spawn named. The lint,
  `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName`, finds every `Platform.Spawn`, `posix_spawn`, `execv`,
  `execve`, `fork`, `forkpty` and Foundation `Process` in the sources of every target the image links (`VibeHost`,
  `vibeswitcher-host`, `VibeCore`, `VibePlatform`), and fails on one it can't classify. Read at `b15e0052`, besides
  those above: `VibeCore`'s `Worktrees.swift:203` (`execve`) and `MCPServer.swift:349` (`replaceProcess`), which the
  lint classifies as the rest (named descriptors, or a path the image never takes); no `fork` and no Foundation
  `Process`. SwiftTerm, which `VibeHost` links for its headless terminal, has process-starting code of its own
  (`LocalProcess`); the image uses none of it (read: no `LocalProcess` or `forkpty` in those targets), and the lint
  fails on a use of it. **The rule reaches every program the host gives an end of its pairs to**, not only the host
  image: the server child receives an end of each app connection, a pair the host makes and writes answers on
  (`HostConnector.connect`, `VibeCore/V2/HostConnector.swift:69`, marking it close-on-exec only after it arrives), and
  at `b15e0052` it spawns with no `keep`, so without `CLOEXEC_DEFAULT`: `codex app-server`
  (`VibeNode/Server/NodeCodexTrust.swift:221`) and `git` (`VibeNode/Start/LeadInit.swift:124`). A `codex` your account
  rewrote, or a program git runs, would then inherit a genuine host's pair end (the blind check of this fix round). So
  K4a makes every spawn of `vibeswitcher-server` name what it keeps too, and the lint's scope adds the server's targets
  (`vibeswitcher-server`, `VibeNode`); the class of a pair end given to the server is **given only to proven code
  whose own spawns close what they don't name**. Not "or the client's lock around its spawn": that lock covers only
  `NodeAnchor`'s own pairs, and a spawn racing any other pair's making inherits both of its ends.
- **No end of a pair the host writes on reaches code that hasn't proven it runs the image's code, in any mode** (KP20;
  the review's F1 (a)). The keeper sees the image, not its mode (KP12), and reads as a request whatever the holder of
  a pair's other end writes; so a process a session chose, holding one end while the host writes bytes the session
  chooses on the other, could ask the keeper in the host's name. **At `b15e0052` this doesn't hold, the checked node
  included** (KP20a): on the Mac every host's parser launcher, the checked node's too, is a copy of the image at
  `<VIBESWITCHER_HOME>/host/launcher-<build>` (`main.swift:95-114`; `images.own` is nil on the Mac,
  `HostImages.swift:696`), so `~/.vibeswitcher/v2/node/host/` for the node, checked only by its modification time
  (`HostProtocol.swift:497-500`). A process of yours can put its own program there (`touch -r`, or a rename after the
  host started), and the host then starts it at every session start and history read (`HostedSession.swift:257`,
  `HistoryRead.swift:24`) with the parser link's end as its descriptor 0, while writing the session's terminal output
  in frames on the other end (`SessionParser.swift:262-275`, `:143-148`). The same launcher starts every session's
  program (`PTYSpawn`); a session's program is your account's code anyway, and holds no pair end, so only the parser
  matters here. **The change, slice K4a, the handover keeper's way:**
  1. **A child the image gives a pair end to is spawned holding no end of a pair the host writes data on.** It
     inherits one descriptor for its proof, its **channel**: an end of a fresh stream pair on which the host writes
     nothing but the handshake's one fixed byte (`holding`, `0x67`, once it holds the child's pair), exactly as
     `MacHandoverKeeper.start` does with its keeper (`MacHandoverKeeper.swift:96-125`). A channel in the hands of code
     that isn't the image's carries no request: the keeper would read at most that byte, never its `vskeep1\n` prefix
     (`0x76` first), and the hello's sender isn't the pair's maker.
  2. After its exec the child makes **a fresh pair of its own** and sends one end over the channel. The host requires
     that pair's token to be **the spawned pid, running the code it started for that child, with the Hardened
     Runtime** (`MacHandoverKeeper.refusal`'s three checks): for a parser, the pinned host's cdhash, which on a checked
     node is the image's own (`Platform.CodeIdentity.ownCdhash`), and in every other mode the image's own; for the
     server child, the cdhash the host read from its `--server` file (on a checked node, the pinned server's). Anything
     else: the child is ended and reaped, nothing is written, and what needed it is refused with words (below).
  3. **Only then does the host give it the link**: a pair the host makes after the proof, one end sent over the proven
     pair (whose other end the proven child made and holds) and the other kept. The child, in any mode, writes on its
     channel and its own proof pair nothing but the handshake's fixed bytes (the descriptor message's one byte, `d`,
     `0x64`; `holding`, `0x67`), so its proof pair's other end, wherever a session that started it sent it, carries no
     request either.
  
  **The image's pairs, every call site at `b15e0052`, and their class after K4a** (K4's lint,
  `KeeperLintTests.everyPairTheHostImageMakesIsClassified`, holds this list, so a new call fails until it is
  classified; the classes are the review's three, **kept**, **given only to proven code** and **seqpacket**, with a
  fourth added here, **a channel or a proof pair**, on which the image writes only the handshake's fixed bytes):

  | Call site | The pair | Where its ends go | Class |
  | --- | --- | --- | --- |
  | `SessionParser.swift:262` | the parser link (stream) | today the launcher's descriptor 0, unproven (KP20a) | after K4a: a channel, then the link given only to the proven parser |
  | `AppConnector.swift:123` | the server child's connector (`connectorType`, a **stream** on the Mac: `SocketDescriptors+Darwin.swift:11`) | today kept across the server child's spawn from its `--server` path, checked by cdhash before the spawn and named after it (`ServerChild.swift:549-582`), so a file swapped between the check and the spawn holds it unproven | after K4a: a channel, then the connector given only to the proven server child |
  | `AppConnector.swift:286` | one per app connection (stream) | one end sent over the connector, in answer to a request whose sender Security checked (`setAppConnectorChild`) | given only to proven code whose own spawns close what they don't name, once the connector is proven and the server's spawns name what they keep (K4a) |
  | `HostHandover.swift:315` | the secrets' channel (stream; the host writes the secrets, then closes its writer) | the reading end parked with the proven handover keeper (`MacHandoverSwitch.swift:91`), which gives it only to the new image it proved | given only to proven code |
  | `MacHandoverKeeper.swift:96` | the handover keeper's channel | the keeper child's descriptor before its proof | a channel |
  | `MacHandoverKeeper.swift:141` | the parcel's pair (`park`) | one end sent over the proven keeper's pair | given only to proven code |
  | `MacHandoverKeeper.swift:200` | the keeper mode's proof pair | one end sent over its inherited channel | a proof pair |
  | `MacHandoverKeeper.swift:227` | the keeper mode's pair to the new image | one end sent over the new image's proven pair | given only to proven code |
  | `MacHandoverKeeper.swift:276` | the new image's proof pair (`take`) | one end sent over its inherited channel | a proof pair |
  | `EgressChild.swift:95` | the egress proxy's control pair (`seqpacket`) | the proxy child | seqpacket: on the Mac `pair` of that type fails (`EPROTONOSUPPORT`, `SocketMaking.swift:3-5`), so it is never made there, and the keeper takes only `SOCK_STREAM` ends anyway |
  | `NodeAnchor` (new, K4) | one per keeper request | both ends kept, closed after the request | kept |

  **A parser or server child that fails its proof** is a refusal the user can meet: the session doesn't start, or its
  history isn't read, or the server isn't started, with words in `status` and the session's own line: "Your node
  didn't start a helper program it needs, because the file in that helper's place isn't your node's own code:
  something on your Mac replaced it. Restart your node (`vibeswitcher stop`, then `vibeswitcher start`), which puts
  its own copy back. If it happens again, a program running as you is doing it." A program of yours can cause this at
  will, so the words never send you to a password or an install (the rule of [While the keeper is
  down](#while-the-node-is-down-and-while-the-keeper-is-down)); for the restart to put the copy back, K4a has the host
  write its launcher afresh at each start (a new file renamed over the old), never keeping one it finds because its
  modification time matches. K4a's tests:
  `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`,
  `.aChannelCarriesOnlyTheHandshakesBytes`, `.aProofPairsOtherEndCarriesNoRequest` (the keeper's own reader run on it).
  F1's (c), the request's own half-close as a second barrier (step 5 refusing a closed other end, with a lint that
  nothing else in the image half-closes a Unix stream end: `EgressProxy.swift:418` half-closes the sockets it relays
  and would need classifying), is **a candidate, not a closing**: it rests on K-M1 (e), and doesn't help against a
  holder of both ends, so (b) is needed either way.
- **Its connect has its own deadline** (the review's F9): a non-blocking `connect` waited on with `poll` against the
  request's own limit, a pause of 250 ms between tries (never a loop that spins), and the start's 60 s counted on the
  steady clock across tries, so a full backlog that makes `connect` wait, or one that refuses it at once (which of the
  two: K-M10 (c)), costs the host at most its limit and no core. K6's look at the socket uses the same call with a
  limit of 2 s. Tests: `NodeAnchorTests.aFullBacklogCostsTheStartItsLimitOnly`, `.aRefusedConnectIsTriedAgainAfterAPause`
  (an injected clock and socket).
- **The answer's read-back.** A swap whose connection dropped before its answer was read is read back with `open`: the
  slot equal to `new` is a raise that succeeded; equal to `expected`, one that failed (tried again at the next append);
  anything else, `moved` (journal "One writer" 4: the host writes nothing more, `lock.lost`).
- **The order at the host's start**: the lock (journal "One writer" 1), then `open` (the key and both slots), then the
  file, open, parse, then the counter compared with the `journal` slot. A host that holds the lock but can't get the
  key reads no file, sets nothing aside and exits (K8's set-aside runs only once a key was obtained from the keeper
  and the file failed to open with it: otherwise a flood at a restart would make the node set its own record aside).

## While the node is down, and while the keeper is down

**While the node is down** the keeper does nothing: it holds its store and answers only proven pairs. It doesn't
notice the node's absence, restart it or record it. (A count of key fetches in the keeper would show a host that ran
and sealed nothing between your stop and your start, the journal's P39; not taken: [Doubts](#open-doubts) 9.)

**While the keeper is down** (not installed, being updated, crashed and held back by launchd's throttle, removed,
switched off in Login Items if K-M12 shows your account can do that, or kept busy by a program of yours: below), the
node fails closed in two ways, by when.

**Decided (the lead, 2026-11-27; Open questions 1): while the keeper isn't answering at a start, the node waits a
minute and doesn't start.** This is **stricter than the property needs**: the property ("every guarded change is
counted in the keeper or refused, and nothing of yours reads the key or moves a slot") holds under the other answer
too, since a host without its key refuses every guarded change for its life and seals nothing (the review's "Open
question 1"). It was chosen because the other answer brings back exactly what it removes: P39's "one started without
its key" (a session keeps the keeper busy between your typed stop and start, starts a keyless host whose
`record.begins noKeeper` and `page.held` vanish with it), a crippled node that runs until you restart it even after
the keeper answers (no page, no devices, every guarded change refused, holding the node's lock and the page's
address), and one more arm to build and review (a keyless start that must also leave the file untouched: no read, no
K8 set-aside). Its cost is a node that doesn't run at all while a flood lasts, which a program of yours could get
anyway by killing the node (P32). It is stricter than the user's words in 9CDB5A99 ("while the keeper is down the node
refuses the changes that ask for Touch ID"), and the user has been told.

**What the words may say** (the review's F4): only a fact your account can't cause sends you to your password. The
keeper's plist and program are root's files in root's folders (KP7a), so their **absence**, found by the root walk, is
such a fact, and so is a **`damaged`** store (root's file in root's `0700` folder, which nothing of yours can write):
these two alone point to the keeper's setup line (`--install`, or `--start-over` for `damaged`). A keeper **installed but busy** (a root
listener at the socket that doesn't answer the proof's first step within the limit) or **installed but not running**
(no root listener there) can be a program of yours at work (a flood, KP19; Login Items, K-M12), so their words never
mention the password, the setup line or an install: a session would otherwise choose the moment you type your
password. K6's `start` and `status` look themselves, in that order: the plist and the program (walked from `/`, root's
alone), then a root listener at the socket (`getpeereid` 0: K-M2), then whether it answers within 2 s (F9's
deadline): the command line connects and sends nothing, and a keeper that serves the connection closes it within its
1 s limit for the proof's message, which the command line sees as the end of file; no end of file within 2 s is
"busy". **If K-M10 (c) shows that a full backlog refuses `connect` at once** (`ECONNREFUSED`, as when nothing listens:
read in XNU's source, not measured), a refused connect can't tell busy from not running, and the host and K6 then use
one state for both, **"installed, not answering"**, worded "Your node's keeper isn't answering, so your node can't
start: either a program on your Mac keeps it busy, or it stopped. Installing the keeper again won't help. Try
`vibeswitcher start` in a minute; if it goes on, restart your Mac; if it goes on after a restart, something that
starts when you log in is doing it." (still no password); the two rows below stay as two only if K-M10 (c) shows a
full backlog makes `connect` wait instead.

| When | What the node does | Its words | The way out |
| --- | --- | --- | --- |
| **At the host's start, the keeper not installed** (no plist or no program in root's folders) | the host exits 78 (`notStarted`) at once, having read no secret and written nothing; no host runs without its record, so the journal's start-time `noKeychain` reason doesn't arise | "Your node's keeper isn't installed, so your node can't start. Run the keeper's setup line (it asks your password)." | the keeper step's `--install` |
| **At the host's start, the keeper installed but busy** (a root listener that doesn't answer within the limit) | the host holds its lock, reads no file and asks again as F9's loop allows, up to 60 s (the start's limit, on the steady clock; a test's injected one); then exits 78 | "Your node's keeper is running, but a program on your Mac keeps it busy, so your node can't start. Installing the keeper again won't help. Try `vibeswitcher start` in a minute; if it goes on, restart your Mac; if it starts again after a restart, something that starts when you log in is doing it." | the flood ending, then `vibeswitcher start` |
| **At the host's start, the keeper installed but not running** (no root listener at its socket: crashed and throttled, being updated, or switched off) | as for busy: up to 60 s, then exit 78 | "Your node's keeper is installed but isn't running, so your node can't start. Try `vibeswitcher start` in a minute; if it still doesn't start, restart your Mac, which starts the keeper." Once K-M12 shows your account can switch the keeper off in Login Items: "…if it still doesn't start after a restart, see whether VibeSwitcher's keeper was turned off in System Settings › General › Login Items." | macOS starting it (at boot, or launchd's restart after a crash), then `vibeswitcher start` |
| **At the host's start, the keeper refused or damaged** (`noRecord`, `notPinned`, `notHardened`, `wrongUid`, `damaged`) | the same exit, at once: waiting changes nothing | for `damaged` (root's store, which nothing of yours can damage): "Your node's keeper can't read its store. Run the keeper's setup line with --start-over (it asks your password); your node's record then begins again." For the others, the checked start's own words (the record names no such build: the Mac spec's remedy, an install of a newer commit, through root's own pins record, which nothing of yours can change) | `damaged`: your `sudo` line; nothing deletes the store by itself (the decided (3)'s principle, below) |
| **While the host runs, no answer** (busy, not running, or `unwritable`) | the journal's failed-raise rule (its "When a raise fails", I2), keyed on the keeper instead of the keychain: a guarded act acts only once its entry is counted (`recordUncounted` otherwise); the raise tried again at each later append and at the host's end; one open `record.begins` with `reason: noKeeper` per run of failed raises; revocations and the acknowledgement still taken; a device's removal refused and retried by itself; the file sealed meanwhile runs ahead (`ahead` at a restart before a raise succeeds) | "Your node can't keep its record right now: its keeper isn't answering. Try again in a minute; if it goes on, restart your Mac." For a removal: "Your node can't remove a device while its keeper isn't answering. Lock the device now, which always works and ends what it can do; it will be removed once the keeper answers." Never the password | the keeper back (launchd restarts it; an update takes seconds) |
| **While the host runs, a refusal** (`notPinned`: a pinned older build running when you ran `--keep 1`, P41; `noRecord`; `damaged`; `notHardened`; `wrongUid`) | the same failed-raise rule (nothing guarded acts uncounted) | **the start's words for that status** (the review's F14), never "isn't answering": e.g. `notPinned`, "Your node is running a build its install no longer lists, so it can't keep its record. Stop it and start your node again (`vibeswitcher stop`, then `start`), which starts the build your install lists." | as at the start, for that status |

A process of your account **can't stop the keeper** (only root can stop, unload or signal a root daemon: K-M9; and
whether macOS's Login Items list lets your account switch a LaunchDaemon off, the review's F10, is K-M12: if it does,
that is one more at-will denial, KP18a, with the words above), and can't shut its socket (root's), **but it can keep
it busy**, which is the same to the node as the keeper being down:
each connection may hold the serial keeper for at most 1 s (the proof's message) and a proven pair for at most 2 s
more, and a flood of connections fills the listen backlog. So, at will and for as long as it keeps at it, a program
of yours can:

- **keep the node from starting** (the host waits a minute, then exits 78): no more than it gets by killing the node
  (P32);
- **refuse your guarded changes** while the node runs (`recordUncounted`): the journal's P31 denial, its lever the
  keeper's socket instead of a locked keychain;
- **make a revocation go uncounted** ("Lock now", `phone.off`, `dropUnlocks`, `web.revoke` are never refused), which
  an older vault put back after a restart then undoes: the journal's P36, unchanged, its lever this flood;
- **make the file run ahead of its counter** (seal while raises fail, then kill the host): the next start is `ahead`,
  open, devices held: the journal's P42 and row 7a, unchanged, its lever this flood;
- **deny the read-back and the removal's retry** (the review's "Denial" list): a swap whose answer was lost stays
  unread back while the flood lasts (the host writes nothing guarded meanwhile, and a raise that did succeed is found
  at the next `open`), and a waiting removal waits.

What a flood costs the keeper: one `getpeereid`, one `recvmsg` and, for a hello carrying a session's own pair,
Security's dynamic check and a walk of the pins record, per connection (CPU, measured in K-M10); its descriptors stay
bounded since every received descriptor but the one taken is closed (F7). The node's own words never route you to
the install's window from a flood (F4, above).

Each fails closed and shows (a refusal with its words, an open entry); none is a change taken unseen. These are the
journal design's stated limits as they were with the locked keychain: the keeper doesn't close them, it changes
their lever. A keeper that serves connections side by side (`kqueue`, a deadline each, a bounded table) would make
a flood cost more without ending it (a program of yours can always open connections faster than one keeper serves
them): not taken, [Doubts](#open-doubts) 5. The keeper's memory and descriptors stay bounded under a flood (nothing is
kept per connection beyond the one being served, a fixed listen backlog): **not measured**, K-M10.

## Install, update and removal

**The keeper step**, `scripts/node-keeper-mac.sh`, has the pins step's shape (`node-pins-mac.sh`, reviewed): run as
you, from the commit's checked blob under `/usr/bin/env -i /bin/bash -p`, every imported function dropped, `PATH` and
`LC_ALL` fixed; it prints exactly what it will do and where, then runs **one** `sudo` whose script is text inside it,
not a file, and whose root half checks again, as root, every value it is handed: the uid (`SUDO_UID`), the paths (the
node's `keeper-<uid>` or a trial's `VibeSwitcher-trial/keeper-<uid>`, nothing else), each folder from `/` down root's
alone, no link, no ACL. `--dry-run` prints and writes nothing. Its forms:

- **`--install COMMIT --objects STAGED`** (install and update; decided: the lead, 2026-11-27, Open questions 7 and the
  review's F2). `STAGED` is a file the user half writes from your repository: the commit's objects, at least the
  commit object, its top tree, and the `Keeper` tree with every tree and blob under it (as one pack, or the commit's
  whole history as a bundle if root's check needs every link present: K-M13); it is the only thing root takes from
  your account besides `COMMIT` and your uid. **Root builds the keeper alone, from those objects, under the review's five
  conditions:**
  1. **Source from the commit's objects, every hash recomputed in a root-owned folder, never the checkout's files.**
     Root copies `STAGED` into a fresh `keeper-<uid>/build/` (`0700`, root's, made new each time), indexes it there into
     a bare repository of root's own making, which recomputes every object's hash from its bytes, requires the commit
     object's id to be `COMMIT`, walks the commit's tree to `Keeper`, requires that tree and everything under it to be
     present and to hold only regular files (`100644`, `100755`) and folders (no link, no submodule: anything else is
     refused), and writes those files out into `build/src/`. The candidate tool is root's own `git` (`index-pack
     --strict`, then `archive`), run only in that repository, with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`
     and no template's hooks; the other candidate, should that `git` refuse a pack whose commit's parents and top
     tree's other entries are absent and a whole bundle be unwanted, is a small reader in the root half's text that
     recomputes each object's hash itself. Which one, and whether it detects a SHA-1 collision attack (git's
     `sha1dc`), is K-M13 and K5's review, since the objects' hashes are all that ties them to `COMMIT`
     ([Doubts](#open-doubts) 14).
  2. **Root never runs `git`, `swift` or anything else in your repository or under its configuration** (a repository's
     config names programs git runs: `core.fsmonitor`, filters, hooks). The user half alone runs `git` in your
     repository, to write `STAGED`; nothing it writes is run as root.
  3. **Root's toolchain**, the Xcode the install already checks is root's, run as `/usr/bin/env -i` with `HOME=/var/root`,
     `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `TMPDIR` and every SwiftPM and clang cache (`--cache-path`,
     `--scratch-path`, the module cache) inside `build/`, offline (`--disable-automatic-resolution`; the package names
     nothing to resolve), and nothing in your home or your `TMPDIR`.
  4. **The output in a root-owned folder**: `build/out/`; root signs it there ad hoc with the Hardened Runtime
     (`codesign -s - -o runtime`, as `mac_sign_hardened` does), reads its cdhash for this Mac's slice
     (`codesign -d -a <arch>`: K-M7) and requires it hardened.
  5. **The keeper is a package with no dependency** (`Keeper/`, [Its program](#what-it-does-and-what-it-never-does);
     `KeeperLintTests.theKeeperPackageNamesNoDependency`), so the build resolves and fetches nothing.

  **What triggers it, and the refusal.** `installed` records the tree id root built from and the cdhash it got. The
  root half reads the commit's `Keeper` tree id from the verified objects, never from what it was told:
  - a tree id **other than the recorded one** (or none recorded, at setup): root builds as above, then
    `launchctl bootout system/dev.vibeswitcher.keeper.<uid>` if loaded (waiting until the old process has exited:
    K-M9), renames the new program over the old (`root:wheel 0755`), writes `installed` and the plist from fixed text
    (label, the program's path, `--uid <uid>`, `RunAtLoad` and `KeepAlive` true, no environment, `ProcessType`
    `Background`), each to a new file renamed over the old, `launchctl bootstrap system` it, and checks, as root, that
    the socket appears and its listener answers the proof's first step;
  - **the recorded tree id**: root builds as above and compares: the same cdhash as the installed program, and it
    installs nothing ("Your node's keeper is already this build. Nothing was installed."); **another cdhash, and it
    refuses**, installing nothing: **"Your node's keeper was built differently although its source didn't change, so
    something changed the build. Nothing was installed; your keeper runs as before."** (the review's words; only root's
    toolchain and root's folders made that build, so a change there, an Xcode update included, is what it says).
    Whether two root builds of one tree give one cdhash is K-M13; if they don't, every such run is refused, which
    installs nothing and is fail closed.

  The store is never touched by an install or update, and `build/` is removed when the step ends.

  **What the root half trusts, stated:** the commit's objects, by their hashes, and `COMMIT` as the user half named
  it. So a rewrite of your checkout, the build's output or the staged objects is refused or doesn't matter (root's
  hashes, root's build), and a session that rewrites only the build can no longer force the keeper step at a node
  update (the trigger is root's recorded tree, KP23a). **What remains** (KP21): **the choice of commit**, bounded by the
  install's provenance check (on v2, both CI runners passed) while the install script is the commit's own (its step 5
  checks itself against the commit, byte for byte); and **a session that rewrites the install script itself**, which
  can then name any `COMMIT` and hand root a self-consistent set of objects of its own making (root checks the hashes,
  not who wrote them): S1's class, "root is one password away", the same moment as a faked `sudo` prompt, an argument
  stated and accepted, not a closing. The pins step's own hardening (its text run from memory, `env -i`, `bash -p`) is
  kept for the same reason.
- **`--remove`**: bootout (waiting for the process to exit), then remove the plist, the program, `installed` and the
  socket; **the store stays** (root's, `0600`), so a later install finds the same key and your node's record opens
  again. **`--remove --forget-store`** also deletes the store, said before the password: "This deletes your node's
  record key: its record can never be opened again."
- **`--start-over`**: for a `damaged` store only (refused otherwise): moves it aside, renamed, never deleted.

**The install** (`install-node-mac.sh`) builds and signs the node's five programs under your account as today, runs
the pins step, then **runs the keeper step only when the commit's `Keeper` tree id differs from the one in `installed`**
(any account can read it; the user half reads the commit's tree id from your repository, and root checks it again from
the objects, above): at setup, and in an update that changed the keeper's source. So: **setup asks your password
twice** (the pins, then the keeper: the one more `sudo` line you accepted), **an update once** as today, and an update
that changes the keeper's source twice. sudo's own five-minute timestamp may spare the second password; nothing relies
on it. A rewritten install that runs the step anyway gets root's own trigger above. Folding the keeper into the pins
step's one `sudo` (one password at setup) is [Open questions](#open-questions-for-the-lead-or-the-user) 3.

**The node's removal runs the keeper's** (the review's F18). At `b15e0052` there is no node removal
(`install-node-mac.sh` has no remove form); whichever slice adds one runs the keeper step's `--remove` (the store kept,
said: a later install opens the record again) or, when you ask the removal to forget the node's record, its
`--remove --forget-store`, said before the password. Without it, a removed node would leave a root daemon serving
every build still pinned, with the key to a vault file that may still be in your home. K5's test
`KeeperStepTests.theNodesRemovalRemovesTheKeeper` holds it once the removal exists.

**Order at setup.** The keeper is installed before any node host can start (the node is refused today by
`macUnbuilt` and `isCheckedMacNode`), so no record ever begins under the login Keychain: there is nothing to migrate,
and the journal's Keychain arm is never built ([What changes in the journal design](#what-changes-in-the-journal-design)).

**A Mac restart.** The keeper is a LaunchDaemon, started at boot from its root-owned plist; the node is a LaunchAgent,
started at your login (or by your `start`). That the daemon is listening before a login's agents start, and how
launchd throttles and gives up on a daemon that keeps crashing: **not measured**, K-M3. Either way the host's start
waits up to 60 s, then fails closed.

## Every path to the property

The property, with the keeper: **no process of your account can read the node's record key, move the record's check
or the devices' check, or seal a vault; so every rollback, replacement or forgery of the record is an open journal
entry, and every guarded change is either counted in the keeper or refused**, except a host pinned through an update
a session rewrote (KP6a: a stated limit, accepted by the user on 2026-11-27, 8B298106). Each path to it, the check that guards
it, and the test that proves it (planned names: `Tests/VibePlatformTests/KeeperProofTests.swift`,
`Tests/VibePlatformTests/KeeperStoreTests.swift`, `Tests/VibeHostTests/KeeperTests.swift`,
`Tests/VibeHostTests/NodeAnchorTests.swift`, `Tests/VibeNodeTests/KeeperStepTests.swift`, and the journal's own).
Anything unusual on any of them is a refusal, never a case to handle.

| # | Path | Check | Test |
| --- | --- | --- | --- |
| **Writers of the record** | | | |
| KP1 | The checked host seals `vault.sealed` | raise first, then seal (journal I6 order), under the keeper's key; only the checked start holds that key | the journal's J3a tests, on `NodeAnchor`'s in-memory store and then the keeper's |
| KP2 | A process of yours deletes, truncates, rewrites or puts back `vault.sealed` | can't seal (no key); the `journal` slot: "Fail closed" rows 2 to 7a, open, first looks and devices held | the journal's P4, P12, P13, P42 tests |
| KP3 | The keeper's swap moves a slot | only on a proven pair (KP8 to KP15), atomic by the serial loop of the one keeper that holds `store/lock`, on disk before the answer | `KeeperTests.aSwapIsAnAtomicCompareAndSet`, `KeeperTests.twoHostsRacingASwapLeaveOneValue`, `KeeperStoreTests.aSwapIsOnDiskBeforeItIsAnswered` |
| KP3a | **A second keeper process on the same store** (an update whose `bootout` returned before the old process exited; a trial keeper on the real paths): both read X, both answer `ok` to swaps from X (the review's F8) | the store's `flock`, taken at the start and held for life: a second keeper exits having served nothing; `bootout` waited on until the process exits (K-M9); a trial keeper's paths are its own folder's (F16). Not reachable by your account (it needs root's acts) | `KeeperStoreTests.aSecondKeeperOnOneStoreExits`, `KeeperTests.theTrialKeeperNeverOpensTheRealStore` |
| KP4 | The key is made | by the keeper at its store's first `open`, from `SecRandomCopyBytes`; never taken from a caller, never remade over a store it can't read | `KeeperStoreTests.theKeyIsMadeOnceAndNeverTakenFromACaller`, `KeeperStoreTests.anUnusualStoreIsDamagedAndNeverReplaced` |
| KP5 | The store started over or forgotten | only the keeper step's `--start-over` or `--remove --forget-store`, under your `sudo` (root: S1) | `KeeperStepTests.startOverIsRefusedForAStoreThatParses` |
| KP6 | Which hosts are served | the pins record, written only by the pins step (root); read afresh per request | `KeeperProofTests.anUnpinnedOrDroppedBuildIsRefused` |
| KP6a | **The pins' host rows at every node update** (writer, trust on first use; the review's F3): a session rewrites the host's build or source before the install signs it and reads its cdhash (the Mac spec's S9); the pins step writes that cdhash as the new build's host row; the node switches to it; it passes the keeper's proof and gets the key and both slots, for as long as its row stays; the key never rotates (F17), so one success lasts | **none at your account's level: a stated limit, accepted by the user on 2026-11-27 (8B298106)**. Closing it would need every program built as root, not proposed. The remedy after a suspected compromise: a fresh install, `node-pins-mac.sh --keep 1`, the keeper step's `--remove --forget-store` and `--install` for a new key; the record begins again (`unreadable`, open, first looks and devices held) | `KeeperStepTests.forgettingTheStoreThenInstallingMakesANewKey` (the remedy works); the limit itself has no test |
| **Channels to the keeper** | | | |
| KP7 | Another uid's process connects | `getpeereid` checked before a byte is read; an access entry for your account alone if K-M6 says `connect` honours it; else its flood is a denial (KP19) | `KeeperProofTests.anotherUidIsClosedAtAccept` (uid injected) |
| KP7a | A process of yours `chmod`s or removes the socket | root's file in root's folder: it can't | `KeeperTests.theSocketIsRootsAndNotTheAccounts` |
| KP8 | A process of yours connects and writes a request on the connection | nothing is read on the connection but the proof's one message; nothing is ever written on it | `KeeperProofTests.aRequestOnTheConnectionGetsNothing` |
| KP9 | It sends a pair it made itself | the pair's token is its own code: no pinned host | `KeeperProofTests.aSessionsPairIsRefused` |
| KP9a | **An end that isn't a pair's:** it connects to a listener of its own, gives the accepted end to a pinned image (inherited, in a mode that reads or writes it) so that image is the last to use it, and sends the connecting end, whose token then names genuine code, while a sibling holding the accepted end reads the answer | only an end unnamed on both sides (a pair's) is taken (K-M1 (d)), and the hello's sender must be the pair's maker | `KeeperProofTests.aConnectedEndThatIsntAPairIsRefused`, `KeeperProofTests.aHelloWhoseSenderIsntThePairsMakerIsRefused`; K-M1 (d) |
| KP10 | **Write then exec:** it makes a pair, writes a request, execs the pinned host, a sibling holding a copy of its end waits for the answer | the token is the pair's maker as it was at the making (the Mac spec's result, kept there only as a sentence: K-M1 reruns it in exactly this order and keeps the probe and its output, the review's F6): Security refuses it after the exec, at the first check and again on the token read afresh after the request (F5) | `KeeperProofTests.aPairWhoseMakerExecdIsRefused`; K-M1's row |
| KP11 | **Cross-protocol:** it starts the genuine pinned host as a switch's new image with `--handover-keeper-channel FD`, FD a connection to the keeper, so the host sends a pair of its own making there | the handover handshake's data is one byte (`SocketDescriptors+Darwin.swift`'s `sendDescriptors`), not the proof's 23 (closed at step 2); were it, the genuine host would write no request on that pair (its handover code writes none) and the 2 s limit closes it; nothing is answered | `KeeperProofTests.aHandoverHandshakeSentToTheKeeperGetsNothing` |
| KP12 | **The deputy:** the genuine pinned host in another mode (a scratch home, a test host, `--handover`, `--test-checked-shape`) | the keeper can't tell modes; J0a's rule 2: no other mode's code calls `NodeAnchor` | `HostJournalTests.noOtherModeTouchesTheNodesItems` (its keeper arm) |
| KP13 | **A second checked host** beside the node (journal P40), its timing driven, its lock swapped | the swap is atomic: one raise from each value succeeds; the loser writes nothing more (`lock.lost`) | `HostJournalTests.aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet` on the keeper's seam, `KeeperTests.twoHostsRacingASwapLeaveOneValue` |
| KP14 | **A pinned older build** started by a session (journal P41) | served (it is pinned); its `host.start` is open by the unswitched-build rule; `--keep 1` drops it | `HostJournalTests.anUnswitchedBuildChangeIsOpen` |
| KP15 | A pinned server's or command line's code, or a host that isn't hardened | host rows only; `isHardened` | `KeeperProofTests.aServerOrCommandLineRowIsRefused`, `KeeperProofTests.anUnhardenedHostIsRefused` |
| KP16 | A malformed proof or request (other data, two descriptors, none, a non-socket, a datagram socket, control data on the pair, another length, an unknown verb or slot, a second request) | exact forms; close, nothing answered | `KeeperProofTests.aHelloWithoutExactlyOneEndIsClosed`, `KeeperTests.anUnknownVerbOrLengthClosesThePair` |
| KP16a | **A hello carrying many descriptors**, or more than the control buffer holds (the review's F7): leaked into the root process until its table fills, which `KeepAlive` wouldn't end | the control buffer sized for the most one message carries; `MSG_CTRUNC` refused; every received descriptor closed but the one taken, on a refusal too; K-M10 (b) | `KeeperProofTests.everyDescriptorAHelloBringsIsClosed` (2, 64 and the most possible); K-M10 (b) |
| KP17 | A fake keeper: a listener of your account's, a socket elsewhere | the host walks the keeper's folder (root's alone) and requires the listener's uid 0 (K-M2) | `NodeAnchorTests.aListenerThatIsntRootIsRefused` (the expected uid injected) |
| KP18 | The keeper's own inputs: arguments, environment, working folder, signals, `launchctl` on its job | its plist is root's; one argument, no variable read; its paths from its own executable's folder (F16); stopping or signalling it is root's (K-M9) | `KeeperTests.theKeeperTakesOneArgumentAndNoVariable`, `KeeperTests.theTrialKeeperNeverOpensTheRealStore` |
| KP18a | **The keeper switched off in Login Items** (System Settings › General › Login Items › Allow in the Background, since macOS 13; the review's F10): if your account can do it, or script the window to, the keeper stays down at will, past reboots | **not measured**, K-M12 (trial): whether an ad hoc LaunchDaemon runs at boot without your approval, how the list names it, whether turning it off needs an administrator, whether macOS shows a notice naming it. If your account can turn it off, it is one more at-will denial, stated as KP19's, and the "installed but not running" words name the list (above); fail closed either way (no start, guarded changes refused) | K-M12 |
| KP19 | A flood of connections, idle ones, or a proven host stopped mid-request (`SIGSTOP`) | 1 s for the proof's message, 2 s for the request; serial; nothing kept per connection; the host's connect with its own deadline and a pause between tries (F9). **A stated limit:** a denial your account can cause at will, through which the journal's P31, P36 and P42 stay reachable as they were through the locked keychain (each fails closed and shows), and the read-back and a removal's retry wait | `KeeperTests.anIdleConnectionDelaysOthersByItsLimitOnly`, `NodeAnchorTests.aFullBacklogCostsTheStartItsLimitOnly`; K-M10 |
| KP19a | **The busy keeper's words leading you to the install's window** (the review's F4): a flood, restarted after each login, makes the start's words send you to the setup line and your password at a moment a session chose | only facts your account can't cause mention the password or the setup line: "not installed" (root's plist or program absent) and `damaged` (root's store); "installed but busy", "installed but not running" and the merged "installed, not answering" never do; the running host's words alike | `KeeperStatusTests.startSaysTheKeeperIsntInstalled`, `.startSaysTheKeeperIsBusyAndNeverMentionsThePassword`, `.startSaysTheKeeperIsntRunningAndNeverMentionsThePassword` |
| KP20 | The host's end of a pair reaching another process, or a session holding an end of a pair the host writes on | one keeper pair per request, both ends kept, no descriptor kept after; nothing from arguments or parcels; every spawn in the image `CLOEXEC_DEFAULT` (KP20b); a child given a pair end proves its code first (KP20a); every pair call site classified | `NodeAnchorTests.noKeeperEndOutlivesItsRequest`, `NodeAnchorTests.aSpawnDuringARequestInheritsNoEnd`, `NodeAnchorTests.theAnchorTakesNoDescriptorFromItsArguments`, `KeeperLintTests.everyPairTheHostImageMakesIsClassified` |
| KP20a | **The checked node's own parser launcher** (the review's F1): `<node root>/host/launcher-<build>`, in your folder, checked only by its modification time; a program of yours put there holds the parser link's end while the host writes a session's terminal output on the other; likewise the server child's connector across a `--server` file swapped between its check and its spawn | K4a: the child is spawned with only a channel (the host writes nothing on it but the handshake's fixed byte), proves its code with a fresh pair of its own (the spawned pid, the expected cdhash: the pinned host's for a parser, hardened), and only then gets the link, a pair the host makes after the proof; the host writes its launcher afresh at each start | `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`, `.aChannelCarriesOnlyTheHandshakesBytes`, `.aProofPairsOtherEndCarriesNoRequest` |
| KP20b | **A spawn without `CLOEXEC_DEFAULT` racing a pair's making** inherits both its ends, so the child writes the request and reads the answer itself (the review's F1 (b)); likewise a spawn of the server child's while it takes an app connection's end (`NodeCodexTrust.swift:221`, `LeadInit.swift:124`) | every spawn in the image, and in the server it gives ends to, names what it keeps (`CLOEXEC_DEFAULT`), its in-place form too; the client's lock is no substitute | `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName`, `NodeAnchorTests.aSpawnDuringARequestInheritsNoEnd` |
| KP20c | **A genuine end whose holder closes after writing** (the parser link's `end()`), the request served on a token only re-validated (the review's F5) | step 5 reads the token afresh from the received end, requires it equal to the first, and refuses a pair whose other end is closed (how it is told: K-M1 (e)) | `KeeperProofTests.aPairWhoseOtherEndClosedIsRefused`; K-M1 (e) |
| **Trust on first use, and the other moments** | | | |
| KP21 | **Install** | the key made by the keeper, nothing of the store taken from your account; the node's first record `begins`, open, first looks held. **The program is root's build** from the commit's objects, every hash recomputed in root's folder, root's toolchain, no dependency (the five conditions); what remains is the choice of commit (bounded by the provenance check) and a session that rewrites the install script itself, which can hand root a self-consistent commit of its own (S1's class): stated, accepted | `KeeperStepTests.theRootHalfRefusesObjectsThatDontHashToTheCommit`, `.theRootHalfRefusesALinkOrSubmoduleInTheTree`, `.theRootBuildReadsNothingOfTheAccount` (its environment and paths, against a scratch tree); K-M13; `HostJournalTests.noFileAndNoCounterIsOpenToo` |
| KP22 | **A node update** (or a rollback) | the pins step alone; the new host served at once; the vault carried by the handover keeper; the next swap from the value it carried. A host pinned through a rewritten build is KP6a | `HostJournalTests.aSwitchHoldsTheLockBeforeItReadsTheRecord`; K7 |
| KP23 | **A keeper update** | as KP21 for the program; the store kept; down for seconds (KP29); `bootout` waited on until the old process exits (KP3a) | `KeeperStepTests.anUpdateKeepsTheStore` |
| KP23a | **The keeper step forced at a node update** by a rewritten build (the review's F2) | the step runs only when the commit's `Keeper` tree id differs from the one root recorded in `installed`, read by root from the verified objects; for the recorded tree, a build with another cdhash is refused with the review's words, installing nothing; and root builds from the objects anyway, so a rewritten build has nothing to install | `KeeperStepTests.theInstallRunsTheStepOnlyWhenTheKeeperSourceChanged`, `.anUnchangedSourceBuiltDifferentlyIsRefused` |
| KP24 | **A record that begins again** | the host swaps from what it read (absent included) to the new record's value; the key unchanged; open `record.begins`, first looks and devices held; the file that didn't open set aside, never sealed over (K8) | `HostJournalTests.everyReasonHoldsItsFirstLooks`, `HostJournalTests.aStartedOverNodeVaultSavesAndSetsTheOldFileAside` |
| KP25 | **A keeper restart** | the store read again; `damaged` refuses every request; a missing store makes a new key (only root deletes it), so the node's file is `unreadable`, open | `KeeperStoreTests.aMissingStoreGetsANewKey`, `KeeperStoreTests.anUnusualStoreIsDamagedAndNeverReplaced` |
| KP26 | **A Mac restart** | the keeper at boot (K-M3), the node at login, open (the decided (1)); the host's start waits up to 60 s | `NodeAnchorTests.theStartWaitsForTheKeeperThenExitsHavingReadNothing` (an injected clock) |
| KP27 | **Removal** | bootout; program, plist and socket removed; the store kept unless `--forget-store`, said before the password | `KeeperStepTests.removeKeepsTheStore` |
| KP28 | The keeper down at the host's start | the host reads no file; exit 78 after 60 s (busy, or installed but not running), or at once (not installed, or a refusal); decided (Open questions 1) | `NodeAnchorTests.theStartWaitsForTheKeeperThenExitsHavingReadNothing` |
| KP29 | The keeper down while the host runs | the journal's failed-raise rule, `noKeeper` | the journal's `aFailedRaiseRefusesAGuardedActAndStillTakesAnAck`, on the keeper's seam |
| KP29a | **A refusal arriving on a running host** (`notPinned` after your `--keep 1` dropped its build, P41; `noRecord`; `damaged`; `notHardened`; `wrongUid`; the review's F14) | the failed-raise rule as KP29, with the start's words for that status, never "isn't answering" | `NodeAnchorTests.aRefusalOnARunningHostHasTheStartsWords` |
| KP30 | A swap whose answer was lost | read back with `open` (above) | `NodeAnchorTests.aDroppedSwapIsReadBack` |
| KP31 | A copy of the store elsewhere (Time Machine, Migration Assistant) | an administrator's restore is root's (S1); a backup holds the key: [Open questions](#open-questions-for-the-lead-or-the-user) 2 | K-M8 |

## What happens to the journal's choices and the switch-on list

**Question 90BBAD80, decided 2026-11-27 ("take all three recommendations"):**

1. **The start at login** (the journal's Open for the user 1): **holds unchanged.** The keeper sees no login and
   explains no start; `loginExplains` stays false until J-M1 and your decision, and each login leaves one notice.
2. **The fixes' costs** (the journal's Open for the user 3), bullet by bullet:
   - *While your login keychain is locked, Touch ID changes are refused (a device locked but not removed):* **moot for
     the keychain**: the node keeps nothing there. **Remains, keyed on the keeper**, as decided: while the keeper doesn't
     answer, the same refusals, the same removal that waits; at the node's start, no start at all (KP28; decided,
     Open questions 1, stricter than this bullet asked: [While the keeper is
     down](#while-the-node-is-down-and-while-the-keeper-is-down)). A keeper update or fault causes it for seconds, and **a program of yours can cause it at will by
     keeping the keeper busy** (KP19), as it could lock the keychain: the lever changes, the cost stays as decided.
   - *After the record begins again, each checked setting waits for one accept:* **remains as decided** (I3). Fewer
     causes: no `noKeychain`, no `noCounter` short of root.
   - *A program of yours can leave your page's devices held at will:* **remains as decided** through `older` (copy the
     file, cause one counted append, kill the host, put the copy back: still detected, not prevented, since the file is
     yours), and through `ahead` (keep the keeper busy while the server child is killed, then kill the host), whose
     lever was the locked keychain and is now the busy keeper (KP19).
   - *One case leaves no notice (a node copy that recorded nothing between your typed stop and start):* **narrows**: no
     host runs without its key any more, so "one started without its key" is gone; a host killed before its first raise,
     or whose lock was replaced before it wrote, remains (P39).
   - *A program of yours can make your node stop recording until you restart it (by replacing its lock):* **remains as
     decided**: the one-writer rule's lock check is kept. With the keeper it is no longer what holds the property (the
     atomic swap is), so dropping it would end this denial; that is [Open questions](#open-questions-for-the-lead-or-the-user) 4.
3. **A swapped Keychain item** (the journal's Open for the user 4): **no longer arises.** The node has no Keychain
   item; `keyReplaced` and its Terminal confirmation aren't built. **Its principle remains** for the keeper's store:
   one the keeper can't read is held and named, nothing deletes it by itself, and only your `sudo` line starts it over
   (set aside, never deleted).

**The Mac node's switch-on list** (the lead's decisions of 2026-11-26 and 2026-11-27):

| Item | With the keeper | What is left, and where |
| --- | --- | --- |
| **The handover's receiving side** (a process that execs the genuine host with `--handover` gets its own vault preferred and sealed under the Keychain key) | **changed: closed for the node's record.** The key it would seal under, for the node, is the keeper's, given only to the checked start (J0a's rule 2), which takes no state file (rule 3); the deputy's non-checked mode never calls the keeper (KP12) | **left for the app's vault on v2** (`lead-vault`, sealed by every non-checked mode): J0b, unchanged, once main's mechanism (`the-session-host-s`) is chosen |
| **The vault's Keychain key added with no access list** (P30) | **closed for the node's record**: no Keychain item; served by pinned cdhash, not by signing identity | the app's `lead-vault` is main's, unchanged |
| **A checked node whose sealed vault stops opening never saves again** (main's `5e98c1fc` holds a started-over vault's saves until the app's key is taught, and a node's host takes no app key) | **changed: the node gets its own confirmation path.** On a checked node (keyed on the checked start), a started-over vault doesn't wait for the app's key: the file that didn't open is set aside first (`5e98c1fc`'s own `setAside`, never sealed over), and the new vault is saved at once under the keeper's key, since nothing of your account can have replaced that key (the danger `5e98c1fc` answers). The confirmation is the journal's: an open `record.begins` acknowledged with Touch ID, every first look held until you accept it, devices held | **slice K8** with its test, after `5e98c1fc` is in v2 and J3b; non-node hosts keep `5e98c1fc`'s hold unchanged (`HostJournalTests.anAppHostsStartedOverVaultStillWaitsForTheAppsKey`) |

## What changes in the journal design

Amended in this branch (the journal design's "Amended by the keeper design" section lists every place; the build
order's rows say it inline):

- **J0a**: `NodeKeychain` becomes `NodeAnchor` (in-memory and keeper stores, no Keychain store); its two Keychain item
  names become the keeper's key and two slots; rules 2 and 3 and their tests unchanged (they are what keeps the deputy
  away from the keeper too, KP12); the node's own signing identifier (`-i`) no longer guards anything of the record
  ([Open questions](#open-questions-for-the-lead-or-the-user) 5). If J0a is built before K4, K4 renames; its rules and
  tests stand.
- **J3a**: the counter on `NodeAnchor`'s seam; its real store is the keeper's client (K4), not the Keychain, so it no
  longer waits on J-M2. The compare-and-set is the keeper's atomic swap: the two-call Keychain store isn't built, and
  `aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet` passes on the keeper's seam (P40's residue closes).
  The one-writer lock rule is kept as it is (an early stop; fewer `older`s from a losing host's uncounted seals).
  Fail closed's row 1 at the start becomes the host's exit 78 (KP28): no record begins `noKeychain`.
- **J3b**: the failed-raise rule keyed on the keeper, `noKeeper` for `noKeychain`, its words and its rank (the
  review's F13: the journal's words that still named the login keychain, row 7a's and the removal's included, are
  corrected there, and `noKeeper` ranks where `noKeychain` did); no keyless start arm; its real store after K4, not
  J-M2. K8 (the started-over vault) rides with it, its set-aside only once a key was obtained.
- **J4a, J4b**: unchanged in what they build; they wait on J3a's seam as before, and touch no Keychain. P39 narrows,
  since the node doesn't start without its keeper (decided, Open questions 1).
- **P30, P34, P35, P40's residue**: closed for the node's record by the keeper. **P31, P36, P42** (and row 7a's
  lever): unchanged as stated limits, their lever the busy keeper (KP19) instead of the locked keychain.
- **J-M2** gates nothing of the node any more (no Keychain arm). The node needs no Keychain probe at all.

## Build order

Each slice is under an hour, docs and tests included. "Review": its own independent security review before it is
offered. **No slice switches on `approvalMeasured`, `isCheckedMacNode`, `macUnbuilt`, `loginExplains`,
`holdsGuarded`, or lifts `pageAck`.** "Here" means proven on this Mac as the user, with no `sudo`: a scratch keeper run
in the test process or as a child of it on a scratch folder, a scratch pins record, the owner facts injected as
`NodePins.read`'s tests inject them, and this Mac's real signed hardened images and audit tokens (as
`MacKeeperHandoverTests` and `MacCheckedStartTests` use them). The program itself takes none of those parameters.

| # | Slice | Tests | Proven | After | Review |
| --- | --- | --- | --- | --- | --- |
| K0 | The `Keeper/` package (no dependency): `VibeKeep` with what moves into it unchanged (`NodePins` from `VibeCore`; the root walk, the dynamic code check by token, `peerUID` and `peerToken` from `VibePlatform`: [Its program](#what-it-does-and-what-it-never-does)), each old name a one-line call into it; the `vibeswitcher-keeper` target; the repository's package naming it by path in both halves | `NodePinsTests`, `RootRecordTests` and the code identity tests unchanged; `KeeperLintTests.theKeeperPackageNamesNoDependency`, `.theKeeperLinksOnlyVibeKeep` | here | this design's re-check (the layout is decided: Open questions 7) | no |
| K1 | The store: format, strict parse, root-only walk, the write discipline, `damaged`, the key's making, the store's `flock` (F8) | `KeeperStoreTests.aStoreParsesOnlyItsOwnForm`, `.anUnusualStoreIsDamagedAndNeverReplaced`, `.aSwapIsOnDiskBeforeItIsAnswered` (a crash injected between each step), `.theKeyIsMadeOnceAndNeverTakenFromACaller`, `.aMissingStoreGetsANewKey`, `.aSecondKeeperOnOneStoreExits` | here | K0 | with K2 |
| K-M1 | The measurement the proof rests on (below): (a) to (d) asked after the maker's exec (F6), (e) and (f), kept as a row with its probe and output | the probe's record | here (no dialog, no `sudo`) | none | no |
| K2 | The proof: the connection's one message, every received descriptor closed but one (F7), the pair, the token, uid, the host row, the Hardened Runtime, the token read afresh after the request and a closed other end refused (F5); the `peerToken` comment corrected to K-M1's row | `KeeperProofTests.aPinnedHardenedHostsPairIsTaken`, `.aPairWhoseMakerExecdIsRefused`, `.aSessionsPairIsRefused`, `.aServerOrCommandLineRowIsRefused`, `.anUnhardenedHostIsRefused`, `.anUnpinnedOrDroppedBuildIsRefused`, `.anotherUidIsClosedAtAccept`, `.aHelloWithoutExactlyOneEndIsClosed`, `.everyDescriptorAHelloBringsIsClosed`, `.aConnectedEndThatIsntAPairIsRefused`, `.aHelloWhoseSenderIsntThePairsMakerIsRefused`, `.aPairWhoseOtherEndClosedIsRefused`, `.aRequestOnTheConnectionGetsNothing`, `.aHandoverHandshakeSentToTheKeeperGetsNothing` | here | K1; K-M1 (a) to (f) as measured and kept as a row (else the XPC form is designed first); K-M10 (b) for F7's buffer | **yes** |
| K3 | The program: the serial loop, `open` and `swap`, the request's prefix, the limits, its one argument, its paths from its own executable's folder (F16), the socket made root's, `0666` | `KeeperTests.aSwapIsAnAtomicCompareAndSet`, `.twoHostsRacingASwapLeaveOneValue` (two real processes), `.anIdleConnectionDelaysOthersByItsLimitOnly`, `.anUnknownVerbOrLengthClosesThePair`, `.theKeeperTakesOneArgumentAndNoVariable`, `.theTrialKeeperNeverOpensTheRealStore`, `.aDamagedStoreRefusesEveryRequest`, `.theSocketIsRootsAndNotTheAccounts` (its mode and owner as made; root's part in K7) | here (as the user; root's part in K7) | K2; K-M10 (with (b) and (c)) and K-M5 before it is offered | **yes**, with K2 |
| K4a | **The host image's children prove themselves** (F1 (a)): the parser and the server child spawned with only a channel, proving their code with a fresh pair (the spawned pid, the expected cdhash, hardened) before the host gives them the link; the host's launcher written afresh at each start; the words for a child that fails its proof; every spawn in the image `CLOEXEC_DEFAULT` with its lint (F1 (b)). In every mode of the image, since the keeper can't tell them apart; it touches every session's start on the Mac | `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`, `.aChannelCarriesOnlyTheHandshakesBytes`, `.aProofPairsOtherEndCarriesNoRequest`; `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName`; the parser's and the server child's existing tests unchanged in what they see | here | K-M1 (the proof pair's token, as the handover keeper's) | **yes** |
| K4 | The host's client in `NodeAnchor`: the walk, the root listener, one pair per request with both ends kept, the connect's deadline and pause (F9), every pair the image makes classified (the four classes), the read-back, the start's three states (not installed: exit at once; busy or not running: 60 s, then exit 78), the running host's refusals with the start's words (F14), no Keychain store; J0a's test gains the keeper arm | `NodeAnchorTests.aListenerThatIsntRootIsRefused`, `.noKeeperEndOutlivesItsRequest`, `.aSpawnDuringARequestInheritsNoEnd`, `.theAnchorTakesNoDescriptorFromItsArguments`, `.aDroppedSwapIsReadBack`, `.theStartWaitsForTheKeeperThenExitsHavingReadNothing`, `.aFullBacklogCostsTheStartItsLimitOnly`, `.aRefusedConnectIsTriedAgainAfterAPause`, `.aRefusalOnARunningHostHasTheStartsWords`; `KeeperLintTests.everyPairTheHostImageMakesIsClassified`; `HostJournalTests.noOtherModeTouchesTheNodesItems` (keeper arm) | here | K3, K4a, J0a; K-M10 (c) for the retry loop | **yes**, with J3a's |
| K5 | The keeper step and the install's call: the root half as text; `--install COMMIT --objects STAGED` with the root build under the five conditions, the trigger by the recorded `Keeper` tree id and the refusal for an unchanged source built differently (F2); `--remove [--forget-store]` with `bootout` waited on (F8), `--start-over`, `--dry-run`, the trial paths, the plist as fixed text; the install's user half (the objects staged, the step run only when the keeper's source changed); the node's removal running the keeper's once that removal exists (F18) | `KeeperStepTests.theDryRunPrintsExactlyWhatItWouldDo`, `.theRootHalfRefusesEveryValueOutOfPattern`, `.theRootHalfRefusesObjectsThatDontHashToTheCommit`, `.theRootHalfRefusesALinkOrSubmoduleInTheTree`, `.theRootBuildReadsNothingOfTheAccount`, `.anUnchangedSourceBuiltDifferentlyIsRefused` (the root half's text run as the user against a scratch tree, its root-only checks given the scratch owner, as the pins step's root half can be), `.anUpdateKeepsTheStore`, `.removeKeepsTheStore`, `.forgettingTheStoreThenInstallingMakesANewKey`, `.startOverIsRefusedForAStoreThatParses`, `.theInstallRunsTheStepOnlyWhenTheKeeperSourceChanged`, `.theNodesRemovalRemovesTheKeeper` (once it exists) | here, but the real write | K3; K-M13 here (the build as the user under `env -i`: that it builds offline and reproducibly) before it is offered | **yes** (the Mac's S9, and the root build) |
| K6 | `vibeswitcher start` and `status` tell the keeper not installed (root's plist or program absent), installed but busy (a root listener that doesn't answer within 2 s), and installed but not running (no root listener), or the two as one if K-M10 (c) says a full backlog refuses at once, with the words above: only "not installed" and `damaged`, which your account can't cause, mention the password or the setup line (F4) | `KeeperStatusTests.startSaysTheKeeperIsntInstalled`, `.startSaysTheKeeperIsBusyAndNeverMentionsThePassword`, `.startSaysTheKeeperIsntRunningAndNeverMentionsThePassword` | here | K4; K-M10 (c) for its deadline | no |
| K7 | **The trial, at your keyboard**: the keeper step with the trial paths and label (`dev.vibeswitcher.keeper-trial.<uid>`), the root build included; K-M2, K-M3, K-M6, K-M7, K-M8, K-M9 (with `bootout`'s timing), K-M12 and K-M13 (as root) against it; a scratch pinned host's `open` and `swap` against the real root keeper; then `--remove --forget-store` | the trial's record | **your `sudo` line** (and another account for K-M6) | K5 | no |
| K8 | A checked node's started-over vault (the switch-on list's third item): no wait for the app's key on a checked start; the file that didn't open set aside before the first save under the keeper's key, **only once a key was obtained from the keeper and the file failed to open with it** (a host with no key exits before) | `HostJournalTests.aStartedOverNodeVaultSavesAndSetsTheOldFileAside`, `HostJournalTests.anAppHostsStartedOverVaultStillWaitsForTheAppsKey`, `HostJournalTests.aHostWithNoKeySetsNothingAside` | here | `5e98c1fc` in v2; J3b | with J3b |

**What each slice waits on, in short** (the review's "What must be measured", row by row): K0 on this design's
re-check alone (Open questions 7's layout is decided); K1 on K0, and K-M4 before it is offered; K2 on K1 and K-M1 (a)
to (f) kept as a row (F5, F6; (f) says how far the hello's sender check narrows, and the design states that before
K2's review), and F7's buffer from K-M10 (b); K3 on K2, then K-M10 (with (b), (c) and CPU per hello) and K-M5 before
it is offered; K4a on K-M1; K4 on K3, K4a and J0a, with K-M5 and K-M10 (c) for its retry loop; K5 on K3 and
K-M13's here part, and its real use on K7's K-M7, K-M9 (`bootout`'s timing), K-M12 and K-M13's root part; K6 on K4
and K-M10 (c), its Login Items sentence on K-M12; K7 on K5, at your keyboard, with K-M2, K-M3, K-M6, K-M8, K-M9,
K-M12 and K-M13; K8 on `5e98c1fc` in v2 and J3b. **The switch-on review** (row 15, the lead) waits on every slice
here, K4a included, and on K7's trial with every K-M row it owes. K-M11 gates nothing (F15).

**The journal's slices with the keeper:** J0a, J1, J2, J6, J9a and J11 may still be built now (the lead's decision of
2026-11-27). **J3a** after J0a, J2 and this design's re-check, on the in-memory seam; its keeper arm after K4 (no
J-M2). **J3b** after J3a, its words corrected for the keeper (F13); its keeper arm after K4. **J4a** and **J4b**
after J3a's seam, as before. The rest as the journal's build order says. **Nothing switches on** until the switch-on
review (the measurement table's row 15), by the lead.

## Measurements owed

None was run for this design (documents only). "Here" needs no `sudo` and no dialog; "trial" is K7, your `sudo` line.

| # | What | Why it matters | Where |
| --- | --- | --- | --- |
| K-M1 | A received pair end's `LOCAL_PEERTOKEN`: that it names the pair's maker as it was at the making after (a) a forked child of the maker writes and reads on the maker's end, (b) the keeper itself reads and writes on its end, (c) a third process holding a copy of the maker's end reads, **each with the token asked after the maker's exec** (KP10's exact order: the review's F6, since the Mac spec's result is kept only as a sentence); and that Security refuses it (`SecCodeCopyGuestWithAttributes`) once the maker exec'd, also into a pinned hardened image. (d): that `getsockname` and `getpeername` give no path on both ends of a `socketpair`, and the listener's path on one side of a connection made by `connect` and `accept`, also after the listener's path is unlinked; and that nothing else makes two connected stream ends unnamed on both sides. **(e)** (F5, F1 (c)): what `LOCAL_PEERTOKEN` read again on the received end returns after the other end's `close`, after its `shutdown(SHUT_WR)`, and after a former holder's `shutdown(SHUT_RD)`; and whether `POLLHUP` tells a closed other end from a half-closed one. **(f)**: a connection's token after a process holding a copy of the connecting socket writes last (how far the hello's sender check narrows: Doubts 12). **Kept:** the probes and their output as a row of the measurement record, which this design and the Mac spec then cite | the proof (KP9a, KP10, KP11, KP20c) and K4a's child proof: if the token moves, or a pair's end can't be told from a connection's, the pair proves nothing and the transport becomes XPC's peer requirement, designed and measured first; (e) decides how step 5 tells a closed other end | here: probes beside `scripts/mac-measure/probes` (`token-exec`'s shape, M7), with the handover keeper's own pairs as the positive control |
| K-M2 | `getpeereid` on a client's connected socket gives the listener's uid (0 for the root keeper) | the host's check that the keeper is root (KP17) | trial (or any root-owned stream listener the Mac already has) |
| K-M3 | That a LaunchDaemon with `RunAtLoad` listens before a login's LaunchAgents start, how long after boot, and how launchd throttles and gives up on a daemon that keeps exiting | the start's 60 s wait (KP26); the words of KP28 | trial, with a restart |
| K-M4 | The time of one durable store write on APFS (`fsync` and `F_FULLFSYNC`), and whether `rename` then the folder's `fsync` survives a power loss as assumed | KP3's "on disk before the answer" | here, on a scratch folder |
| K-M5 | One request end to end (pair, proof, Security's check, the store's write) on this Mac, calm and under `scripts/test-under-load.sh` | raises are rare, but the start and each guarded change wait on it | here; again in the trial |
| K-M6 | On a root-owned `0600` socket with an access entry (`chmod +a "user:<name> allow write"`) for the account alone: whether `connect` honours it (the account's allowed, another uid's refused), and that the account can't change the root-owned socket's mode or entries | KP7, KP7a | trial, with another account (keyboard) |
| K-M7 | `codesign -d -a <arch>` run as root on the root-owned copy gives the install's cdhash | the root half's check (KP21) | trial |
| K-M8 | Whether Time Machine copies `store/node.keep` by default, and whether a sticky exclusion set by root holds | Open questions 2 | trial |
| K-M9 | That your account can't `launchctl bootout`, `disable` or `kill` the keeper's daemon, nor `kickstart -k` it; and whether root's `launchctl bootout` returns only after the job's process has exited (F8: else the step waits for the pid itself) | KP18, KP3a | trial |
| K-M10 | The keeper's memory, descriptors and CPU under a flood of idle and malformed connections, and of hellos each carrying a session-made pair (Security's check and a pins walk each); **(b)** (F7) its descriptor count after hellos carrying 2, 64 and the most descriptors one message can carry, and with a control buffer smaller than what was sent (whether XNU installs what didn't fit); **(c)** (F9) a full backlog: whether the client's `connect` is refused at once or waits, and for how long | KP16a, KP19, the connect's deadline (F9), K6's limit | here, under `scripts/test-under-load.sh` |
| K-M11 | Whether signing the genuine host's file again (ad hoc, or with the local identity) gives another cdhash | **information, gating nothing** (F15): either it is other code, refused, or the same cdhash, the genuine code | here, on a scratch copy, nothing installed |
| K-M12 | Login Items (F10): whether an ad hoc LaunchDaemon runs at boot without your approval, how System Settings › General › Login Items names it, whether turning it off there needs an administrator (and whether a program of yours can script that), and whether macOS shows a notice naming it when it is installed | KP18a; K6's "installed but not running" words (their Login Items sentence); K5's real use and the switch-on | trial |
| K-M13 | The keeper's root build (F2): that `swift build` of `Keeper/` under `env -i` with its caches in the build folder builds offline and touches nothing outside it (here, as the user, on a scratch folder; then in the trial as root); that two builds of one tree give one cdhash (whether the unchanged-source check can ever answer "already this build"); how long it takes as root; and that the hash check root runs (root's own `git`, `index-pack --strict`) refuses a changed object and detects a SHA-1 collision attack (`sha1dc`) | KP21, KP23a, Doubts 14 | here, then trial |

## Open doubts

1. **The proof's primitive** rests on a pair's token being fixed at the making. The Mac spec records it (its reviewer's
   `pair.c`) and the handover keeper relies on it, but only a sentence of it is kept, not the probe or its output, and
   not KP10's order (the review's F6); `Sockets+Darwin.swift`'s comment says a socket's token moves with whoever last
   used it, which is why the keeper never takes the connection's token as proof (it asks it once, as the narrowing
   check of doubt 12). K-M1 reruns it in KP10's order and keeps it as a row; K2 and K4a wait on that row.
2. **The key travels in clear over the pair** to whoever holds the maker's end. That rests on the host-side rules
   (one pair per request, no descriptor kept, spawns that inherit no end, none taken from arguments or parcels): a
   future host bug that leaks an end mid-request gives the key away. Sealing the answer to a fresh key the host makes
   after the proof would cover that bug at about fifteen lines in the keeper; not taken, for the smallest keeper. The
   reviewer's call.
3. **The keeper can't tell the genuine host's modes apart**, and serves every pinned build. J0a's rule 2 and the
   unswitched-build rule carry it, as they carry the Keychain today; a mode added later that calls `NodeAnchor` breaks
   it, and only J0a's test would catch it.
4. **It runs as root, unsandboxed.** A sandbox profile, or a dedicated system user owning `store/`, would narrow what a
   bug in it reaches; not taken (more install, more to measure). Its input from your account is one `recvmsg` and a
   Security check before anything else is read.
5. **Denial by your own account** against the serial keeper (KP19): a flood keeps the node from starting, refuses
   guarded changes, and through them keeps the journal's P36 (an uncounted revocation undone by a put-back) and P42
   (a file ahead, devices held) reachable at will, as the locked keychain did. Accepted as the journal's stated limits
   were; a keeper serving connections side by side would raise the flood's cost, not end it. Bounded resources are
   claimed, not measured (K-M10).
6. **`noCounter`** stays a "Fail closed" row though only root can reach it (a key without a `journal` slot while a
   file exists): kept, since a fail-closed row costs nothing.
7. **Security's dynamic check from a root process** of a guest of another uid (the caller) is assumed to behave as it
   does between processes of one account (M7, `MacCheckedStartTests`): **not measured**, covered by K2's tests run as
   the user and by K7 as root.
8. **The store is plaintext at rest** under root's `0600`, protected beyond that by FileVault only.
9. **P39's remaining no-notice case** (a host killed before its first raise between your stop and your start) could be
   closed by a fetch count in the keeper, compared at each start; not taken (a write per start, more to review), P39
   being accepted under 90BBAD80 (2).
10. **One keeper per account** costs a daemon per node account on a shared Mac; it keeps one account's store and
    record apart from another's. Another account can still keep it busy unless K-M6's access entry holds.
11. **The install's window for the keeper's program** (KP21, KP23): closed for a rewrite of the build, the checkout
    or the staged objects by root's own build (decided, Open questions 7); what remains is the choice of commit and a
    session that rewrites the install script itself (S1's class), stated on the first page. The node's own programs
    are still built under your account, so for them the window stays, and through the pins it now reaches the
    keeper's service (KP6a, accepted by the user).
12. **Telling a pair's end from a connection's** rests on the socket's addresses (step 2), not measured (K-M1 (d)); the
    hello's sender being the pair's maker is a second check, itself resting on the connection's token at the receipt,
    which moves with the last process to use it (so it narrows, it doesn't prove; how far: K-M1 (f)).
13. **A pair end the pinned image hands to code that hasn't proven itself** (KP20a, the review's F1): at `b15e0052`
    the gap is in the checked node itself, not only in a mode a session starts, since every host's parser launcher is a
    copy in your folder checked by its modification time; the server child's connector has the same shape across a
    swapped `--server` file. K4a closes it the handover keeper's way (a channel, a proof by a fresh pair, then the
    link), its proof resting on K-M1 alone, and every spawn naming what it keeps closes the race that hands a child
    both ends (KP20b). It also rests on the image writing nothing on a channel or a proof pair but the handshake's fixed
    bytes, which K4's lint holds (the fourth class). Reading the maker's command line as root
    (`KERN_PROCARGS2`) is not taken (Open questions 8; F11 measured only if it is ever revisited).
14. **The root build's tie to the commit is git's object hashes** (SHA-1 in this repository): root recomputes each and
    requires them to lead to `COMMIT`, but a chosen-prefix collision would let objects of a session's making hash as a
    commit that passed CI. Root's check must detect a collision attack (git's `sha1dc`) or refuse; whether the `git`
    root runs does is K-M13, and K5 waits on it.

## Open questions for the lead or the user

1. **Decided (the lead, 2026-11-27): the keeper down when your node starts.** The node waits up to a minute, then
   doesn't start and says why (the recommendation), not the other answer (it starts without its record, as the journal
   designed for a locked keychain). Stricter than the property needs and than 9CDB5A99's words; why it was chosen is
   in [While the keeper is down](#while-the-node-is-down-and-while-the-keeper-is-down); the user has been told. J3a,
   J3b and K4 are written to it; no no-key arm is built.
2. **(You) Backups:** Time Machine is expected to copy the keeper's store with your backups, as it copies your login
   keychain (K-M8). **Recommended:** exclude it (a Mac restored from a backup then begins your node's record again with
   a notice); or keep it (a backup disk then holds the record's key).
3. **(Lead) One `sudo` or two at setup:** a separate keeper step (**recommended**: the reviewed pins step unchanged, each
   root half reviewed alone; two passwords at setup, one per update) or the keeper folded into the pins step's one
   `sudo` (one password; the reviewed step grows).
4. **(Lead) J3a's lock check before each write:** keep it (**recommended**, as decided in 90BBAD80 (2)), or drop it now
   that the keeper's swap holds the property (ends the at-will `lock.lost` denial; a losing host's uncounted seals then
   make the next start `older` more often).
5. **(Lead) J0a's `-i`** (the node's own signing identifier): drop it (**recommended**: nothing of the record rests on it
   with the keeper), or keep it for something else that asks for it.
6. **(Lead) Device keys' Mac arm:** slice 20's epoch goes in the keeper's `devices` slot, and its reviewer reads K4's
   seam. Whether the Mac also needs Linux's root-owned phone pin (A64D1FC7) once the device list is sealed under a key
   no process of yours holds is device keys' question; this design doesn't decide it.
7. **Decided (the lead, 2026-11-27): the keeper's program at install** is built as root, the keeper alone, from the
   commit's verified objects in a root-owned folder with root's toolchain and no dependency, under the review's five
   conditions; its step is triggered by the commit's keeper source tree that root records, and an unchanged source
   built differently is refused with words ([Install, update and removal](#install-update-and-removal)). So K0's layout
   is the `Keeper/` package ([Its program](#what-it-does-and-what-it-never-does)). What remains: the choice of commit,
   and a session that rewrites the install script itself (S1's class).
8. **Decided (the lead, 2026-11-27): a pair end the image hands a child** (Doubts 13). The review found the gap in the
   checked node too (F1), so reading the maker's command line as root (`KERN_PROCARGS2`, the earlier recommendation)
   wouldn't close it: the checked node's own parser maker has the checked grammar. Taken instead: the image's
   children prove their code with a fresh pair before they get a link, and every spawn sets `CLOEXEC_DEFAULT`, with a
   lint (K4a, [The host's side](#the-hosts-side)). The command line read as root is not taken; were the lead ever to
   want the keeper itself to refuse the image's other modes (KP12), it would come back as the review's F1 (d) says,
   after F11's measurement. Fixing the parser's launcher to the image's own file is no better (the builds folder is
   yours, and macOS has no exec from a descriptor).

## Sources

- The user's answers: 9CDB5A99 (the keeper, 2026-11-27), 90BBAD80 (the journal's three choices, 2026-11-27),
  8B298106 (F3's limit accepted, 2026-11-27); the precedents BCECD1F3 (the root-owned pins record) and A64D1FC7
  (Linux's root-owned phone pin); the lead's switch-on list (2026-11-26 21:31, 2026-11-27 00:51); the lead's rulings
  on this design's review (2026-11-27 08:59, "v2 keeper design, after its independent review") and on F3's acceptance
  (2026-11-27 09:02).
- The review: `REVIEW-keeper-design.md` (2026-11-27, of `cf7f8738`): its findings F1 to F18, "The paths KP1 to KP31:
  what is missing", "Open question 7", "Open question 1", "What must be measured".
- The journal design at `2c10b90c`: the threat table, "What a holder of the vault's key reaches", "One writer", "When a
  raise fails", "Fail closed", P30 to P42, Open for the user 1 to 4, "For the reviewer: the keeper", the build order.
- The Mac spec at `b15e0052`: "The anchor", "The fake host" (pair.c), "The checked node start", "A switch", "What it
  doesn't cover" (F6, F8, S9), "Rows 7 and 10".
- The measurement record: M7 (the connect-write-exec race), M13, rows 4, 5, 7, 10, 12, 15.
- Code at `b15e0052`: `NodePins.swift`, `RootRecord.swift`, `Service+Darwin.swift` (`nodePinsRecord`),
  `CodeIdentity+Darwin.swift` (`runs`, `isHardened`, `guest`), `Sockets+Darwin.swift` (`peerToken`, `peerUID`),
  `SocketMaking+Darwin.swift` (`pair`), `Spawn+Darwin.swift` (`POSIX_SPAWN_CLOEXEC_DEFAULT`), `MacHandoverKeeper.swift`,
  `VaultStorage.swift`, `node-pins-mac.sh`, `install-node-mac.sh` (the signing, the cdhash read, the pins step's call,
  its provenance steps 5 and 6); for F1, `SessionParser.swift`, `HostedSession.swift`, `HistoryRead.swift`,
  `vibeswitcher-host/main.swift` (the launcher), `HostImages.swift`, `HostProtocol.swift` (`HostBuild.id`),
  `AppConnector.swift`, `ServerChild.swift`, `EgressChild.swift`, `EgressProxy.swift`, `HostHandover.swift`,
  `MacHandoverSwitch.swift`, `PTYSpawn.swift`, `PipeCommand+Darwin.swift`, `HandoverMemory.swift`,
  `SocketMaking.swift`, `SocketDescriptors+Darwin.swift`; for K0, `Package.swift`, `Service+Darwin.swift`,
  `RootRecord+Darwin.swift`, `RootRecord+Linux.swift`, `CodeIdentity.swift`; main's `5e98c1fc` (`setAside`,
  `awaitsAppKey`).

## Review of 2026-11-27: the answers

The review of `cf7f8738` (`REVIEW-keeper-design.md`), each finding and each of its ten added paths, with what this
branch did: **adopted** (where), or **answered otherwise** (why). The lead's rulings of 2026-11-27 decided F1, F2, F3,
F4 and Open questions 1, 7 and 8; the user accepted F3's limit (8B298106).

| Finding | Answer | Where |
| --- | --- | --- |
| **F1** (Important) Open question 8's gap is in the checked node too | **adopted**: (a) the image's children (the parser, the server child) spawned with only a channel, proving their code with a fresh pair (the spawned pid, the pinned host's cdhash for a parser, hardened) before they get the link; (b) every spawn `CLOEXEC_DEFAULT` with a lint, "or the client's lock" dropped; (c) recorded as a candidate waiting on K-M1 (e); (d) Open question 8's recommendation removed, kept only as (d) says; K4's lint classifies every pair. **Added:** a fourth class, "a channel or a proof pair", since the child's proof itself needs an inherited channel and makes a pair whose other end a session may hold; the image writes only the handshake's fixed bytes on them. The server child's connector (a stream on the Mac, kept across a spawn from a path) is one of the children. The launcher is written afresh at each start, so the words for a failed proof can say "restart your node" | The host's side (the change, slice K4a, the call-site table); KP20, KP20a, KP20b; Doubts 13; Open questions 8; build order K4a, K4 |
| **F2** (Important) any update can force the install window | **adopted, the stricter answer** (the lead): the keeper built as root under the review's five conditions; its step triggered by the commit's `Keeper` tree id root records in `installed`; an unchanged source built differently refused with the review's words (root rebuilds to compare, reproducibility owed: K-M13). The first page and the threat row state what remains: the choice of commit, and a session that rewrites the install script itself (handing root a self-consistent commit of its own) | For you ("Setup", "What it doesn't"); the threat table's "Edits the build" row; Install, update and removal (`--install`, the install's trigger); KP21, KP23, KP23a; Open questions 7; K0, K5, K-M13 |
| **F3** (Important) every update can pin a session's host, which the keeper serves | **adopted, accepted by the user (8B298106, 2026-11-27)**: stated plainly on the first page ("What it doesn't"), in the threat table's "Edits the build" row and as KP6a, with the key never rotating (F17) and the remedy (a fresh install, `--keep 1`, `--remove --forget-store` and an install for a new key, the record beginning again). The false sentence ("Nothing running as you can read the key") corrected to "Day to day … The one exception is an update" | For you; the anchors table's secrets row; the threat table; KP6a; What it does (`open`) |
| **F4** (Important) the busy keeper's words send you to the password step | **adopted, with stricter words**: K6 tells three states (not installed; installed but busy; installed but not running; the last two merged as "installed, not answering" if K-M10 (c) shows a full backlog refuses `connect` at once); only facts your account can't cause ("not installed", and a `damaged` root store) mention the password or the setup line; the busy words are the review's, with what to do added; the running host's words follow the rule | While the keeper is down (the rule, the table); KP19a; K6 |
| **F5** (Doubt) step 5's token | **adopted**: the token read afresh from the received end, equal to the first, a closed other end refused; K-M1 (e) | The interface, step 5; KP20c; K-M1; K2 |
| **F6** (Doubt) the pair result kept only as a sentence | **adopted**: K-M1 reruns (a) to (c) with the token asked after the maker's exec and keeps the probe and output as a row; the design cites the row; the `peerToken` comment to be corrected in K2 | The interface, step 3, "Why a pair"; KP10; Doubts 1; K-M1; K2 |
| **F7** (Doubt) descriptors passed with the hello | **adopted**: the control buffer sized for the most one message carries, `MSG_CTRUNC` refused, every received descriptor but the one taken closed, on a refusal too; K-M10 (b) | The interface, step 2; KP16a; K-M10 (b); K2 |
| **F8** (Doubt) two keepers on one store | **adopted**: `flock` on `store/lock` at the start, held for life, a second keeper exits; K-M9 measures `bootout`'s timing, and the step waits for the old process | What it stores; KP3, KP3a; K-M9; K1, K5 |
| **F9** (Doubt) a full backlog | **adopted**: K-M10 (c); the host's connect non-blocking with its own deadline and a 250 ms pause between tries; K6 the same with 2 s | The host's side (its connect); KP19; K-M10 (c); K4, K6 |
| **F10** (Doubt) Login Items may switch the keeper off | **adopted**: K-M12 (trial); KP18a; the "installed but not running" words name the list once K-M12 shows the account can | While the keeper is down; KP18a; K-M12; K7 |
| **F11** (Doubt) `KERN_PROCARGS2` reads the target's own memory | **answered otherwise**: moot, since Open question 8's recommendation (the command line read as root) is not taken (the lead's ruling); were it revisited, F11's measurement and its lint come first | Open questions 8; Doubts 13 |
| **F12** (Doubt) `devices` must be a value your account can't compute | **adopted**: one sentence (bound to the sealed vault like `bind`), handed to slice 20's reviewer with K4's seam; `expected`'s secrecy cited for `journal` alone until then | What it stores |
| **F13** (Nit) the journal's leftover Keychain wording | **adopted**: corrected inline in the journal (its first page, row 7a, the removal's refusal and status line, the seriousness rank with `noKeeper`, "Across a host end", "What the node refuses", the engineering call, P4, P14, P15), each listed in its "Amended by the keeper design" table | the journal design; What changes in the journal design (J3b) |
| **F14** (Nit) refusals on a running host get "isn't answering" | **adopted**: the running host shows the start's words for `notPinned`, `noRecord`, `damaged`, `notHardened`, `wrongUid` | While the keeper is down (the last row); KP29a; K4 |
| **F15** (Nit) the "signs itself" row claims an outcome | **adopted**: the row reworded (other code, refused, or the same cdhash, the genuine code); K-M11 information, gating nothing | the threat table; K-M11 |
| **F16** (Nit) the trial keeper's paths | **adopted**: the program's folder is its own executable's (`proc_pidpath`), one of two fixed paths, walked from `/`; the pins record its sibling; a test that the trial keeper never opens the real store | What it does; KP18, KP3a; K3 |
| **F17** (Nit) the key never rotates | **adopted**: stated, with the remedy beside the Mac spec's F8 lever | What it does (`open`); the first page; KP6a |
| **F18** (Nit) removing the node leaves the keeper | **adopted**: the node's removal (none exists at `b15e0052`) runs the keeper step's `--remove`, or `--remove --forget-store` when it forgets the record, with a test once it exists | Install, update and removal; K5 |

| Added path (the review's) | Answer | Where |
| --- | --- | --- |
| KP6a (the pins' host rows at every update) | adopted: a stated limit, accepted by the user, with its remedy | the paths table, KP6a |
| KP20a (the checked node's parser launcher) | adopted: K4a | KP20a |
| KP20b (a spawn without `CLOEXEC_DEFAULT` racing a pair's making) | adopted: every spawn names what it keeps, with its lint | KP20b |
| KP20c (a genuine end whose holder closes after writing) | adopted: the token read afresh, a closed other end refused (K-M1 (e)) | KP20c |
| KP16a (a hello carrying many descriptors) | adopted: the buffer sized, every extra closed | KP16a |
| KP3a (a second keeper on one store) | adopted: the store's `flock` | KP3a |
| KP23a (the keeper step forced by a rewritten build) | adopted: the trigger is root's recorded source tree; an unchanged source built differently refused | KP23a |
| KP19a (the busy keeper's words leading to the install's window) | adopted: only "not installed" and a `damaged` root store, which your account can't cause, mention the password | KP19a |
| KP18a (the keeper switched off in Login Items) | adopted: K-M12, a row, words once measured | KP18a |
| KP29a (a refusal arriving on a running host) | adopted: the start's words | KP29a |

**Also from the review's prose, adopted:** K8's set-aside only once a key was obtained ("A started-over record");
the flood's denial of the read-back and the removal's retry, and its CPU per hello ("Denial by your account"); K-M1 (f)
and `bootout`'s timing in K-M9 ("What must be measured"); Open question 1 closed as only stricter, with why ("Open
question 1"). **Added here, not the review's:** K-M13 (the root build: offline, reproducible, its hash check) and
Doubts 14 (the commit's tie is SHA-1), both consequences of the root build the lead chose; K4a as a slice of its own.
**From this fix round's own blind check:** the `CLOEXEC_DEFAULT` rule and its lint reach the server child's spawns
(`NodeCodexTrust.swift:221`, `LeadInit.swift:124`), since it holds host-made pair ends (KP20b, the call-site table);
the property's statement and the journal's P30/P34/P35 row carry KP6a's exception; the password rule names a
`damaged` root store beside "not installed" (both facts your account can't cause); a merged "installed, not answering"
state if K-M10 (c) shows a full backlog refuses `connect` at once; the journal's `noKeeper` and row 7a words under 120
characters.
