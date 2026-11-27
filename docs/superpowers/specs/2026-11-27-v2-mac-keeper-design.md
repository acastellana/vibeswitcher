# The Mac node's keeper: a root-owned anchor for the node's record

Status: **design, its review's fix round, nothing built; its proof redesigned after K-M1 (the Mach form, [The
proof after K-M1](#the-interface-how-the-keeper-knows-the-caller-is-the-genuine-node)), for an independent security
review** (2026-11-27, branch `v2-mac-keeper-design-fix` off
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

**Second fix round** (2026-11-27, branch `v2-mac-keeper-design-fix2` off `v2-mac-keeper-design-fix` `8a2f13ea`): the
re-check of `8a2f13ea` (`RECHECK-keeper-design.md`: "ready with fixes"; F2, F3, F4 closed, F1 narrowed to N1 and N2;
2 Important, 2 Doubt, 4 Nit, N1 to N8, and answers to the design's four open questions) is answered here as the
lead's rulings of 2026-11-27 decided them. [Re-check of 2026-11-27: the answers](#re-check-of-2026-11-27-the-answers),
at the end, lists each and where the body now says it. Still documents only: no code, no measurement run, no
refusal constant touched.

**Third edit** (2026-11-27, branch `v2-mac-keeper-design-fix3` off `v2-mac-keeper-design-fix2` `654c241c`): the
narrow re-check of `654c241c` (`RECHECK2-keeper-design.md`: KP20e closed, KP20f and N4 (b) closed with changes, KP6b
not closed) is answered as the lead's ruling of 2026-11-27 ("v2 keeper design, after its narrow re-check") adopted its
changes, **except KP20f's**, which the lead withdrew the same day once K-M1 was measured (its ground, "the by-path end
is already dead after the in-place exec", rests on the refuted premise): KP20f's by-path point is written as **open**,
both facts side by side, for the proof's redesign to settle. KP6b's change and N4 (b)'s four sentences are in as
ruled; they don't rest on the token. [Narrow re-check of 2026-11-27: the answers](#narrow-re-check-of-2026-11-27-the-answers),
at the end, lists each and where it is. Still documents only; the redesign is another task, starting from this tip.

**The proof after K-M1** (2026-11-27, branch `v2-mac-keeper-proof`, on the third edit's tip `4b42a053`, in the clone of
`v2-mac-keeper-k0` that holds the probe and the record): K-M1's second part, (g) to (o), measured on this Mac; three
candidates compared against the whole attack in [the interface](#the-interface-how-the-keeper-knows-the-caller-is-the-genuine-node)
(a challenge on the maker's pair and a keeper-made end, both refuted by measurement; the Mach form, chosen); the chosen
proof restated for the keeper serving a host (K2, K4), a host proving its children (K4a-ii) and the handover keeper
(K4c, new); KP20f settled; [Every path to the property](#every-path-to-the-property) redone, the write-then-exec path
first; the build order and the waits-on paragraph rewritten; the lead's two rulings written in (K5 raises the floor to
K4b's commit; K4b lands only after the redesigned K4a-ii is on v2). [The proof after K-M1: what changed](#the-proof-after-k-m1-what-changed),
at the end, lists each place. Still documents and a measurement probe: no product code, no refusal constant touched.

**The proof review's answers** (2026-11-27, branch `v2-mac-keeper-proof2` on `v2-mac-keeper-proof` `7579879b`): the
review of `7579879b` (`REVIEW-keeper-proof.md`: "sound with changes"; I1 to I3 Important, D1 to D7 Doubt, N1 to N5 Nit)
is answered in the body and in the rows of the slices that build each answer, and **assumption A is measured as far as
it can be on the probe's own children** (K-M16's here part, [the record's row](../../process/v2-mac-measurements.md),
"K-M16, here"): what a hardened child finds on itself when its parent named exception ports and limits, the window
before its first statement, the one-call clear, and Security's check timed (D1). The active routes (a handler
receiving a fault, a state reply, a task port handed over before an exec, a traced exec) were not run from an agent's
session (the lead's ruling of 2026-11-27) and are owed to the keyboard trial, K7; until it shows each closed, the
design treats it as open. [Proof review of 2026-11-27: the answers](#proof-review-of-2026-11-27-the-answers), at the
end, lists each finding and where it is answered. Still documents and the probe: no product code, no refusal constant
touched.

**Two things called "keeper".** In this document **the keeper** is the new root-owned process,
`vibeswitcher-keeper`. The process a switch already parks its state with (`MacHandoverKeeper`,
`--handover-keeper`, the Mac spec's "A switch") is always called **the handover keeper** here. They share a proof
pattern (a Mach message judged by its audit trailer, below) and nothing else.

Read with the [journal design](2026-11-27-v2-mac-journal-design.md) (its threat table, "One writer", "Fail closed",
P30 to P42, "For the reviewer: the keeper", the build order J0a to J11), [the node on macOS](2026-11-19-v2-node-on-macos.md)
("The anchor: a root-owned record of the builds", "The checked node start", "Rows 7 and 10") and the measurement
record (v2-mac-measurements (`docs/process/v2-mac-measurements.md`, not on this branch), newest copy on `v2-mac-runbook`; M7, M13, rows 4,
5, 7, 10, 12). Code is read at this branch's base (`v2-mac-anchored-cli` `b15e0052`): `NodePins.swift`,
`RootRecord.swift`, `CodeIdentity+Darwin.swift`, `Sockets+Darwin.swift`, `SocketMaking+Darwin.swift`,
`Spawn+Darwin.swift`, `MacHandoverKeeper.swift`, `VaultStorage.swift`, `scripts/node-pins-mac.sh`,
`scripts/install-node-mac.sh`; main's `5e98c1fc` (the started-over vault). Each statement about macOS is **measured**
(with its M- or K- source, or the Mac spec's sentence where only that is kept: F6), **read** (with the file), or **not measured** (with its K-M number in
[Measurements owed](#measurements-owed)); the design fails closed either way each K-M falls, and says what changes
where one would change it.

## For you, in one page

**Notice (2026-11-27): the keeper's proof was redesigned after a measurement refuted it.** This design first assumed
that a socket pair's token (`LOCAL_PEERTOKEN`) names the process that made the pair, fixed when it was made. **K-M1,
measured on this Mac on 2026-11-27** ([the record's K-M1 row](../../process/v2-mac-measurements.md)), **refutes it**:
the token names whoever last sent, received or polled on the other end, as it runs now, so a program of yours could
write a request, then run your node's genuine program and have it accepted; and its second part showed that no
check over a socket repairs that (a failed write by the genuine program, made at a moment of the program's choosing,
leaves it named with no trace). **The keeper now takes requests only as Mach messages, each judged by who sent it, as
it was when it sent** (macOS fixes that in the message; measured). So nothing a program of yours holds, no socket and
no copy of anything, can carry a request in your node's name. **A second review (2026-11-27) found the proof also
needs your node's real program, once a program of yours has started it, to run only its own code.** Part of that is
measured on this Mac (a program of yours can start it with handlers and limits of its own, which your node's program
now removes as its very first step); the rest, what such a handler can do in the few milliseconds before that step, is
measured at your keyboard (the trial), and **the keeper isn't put in place for real before it**. Nothing on the rest of
this page changes for you.

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
  the way (what a program of yours can still choose is below, in "What it doesn't"). Older builds of your node are
  dropped at setup, so only the build you install is served, and builds older than the keeper's fixes can't be
  installed afterwards. Updates ask once, as today; a second time only in an update that changes the keeper's own
  source.
- **Day to day:** nothing. Locking your login keychain no longer pauses anything of the node, and nothing of the node
  is in your login keychain any more.
- **If the keeper isn't answering** (it is being updated, it broke, or a program of yours keeps it busy, as one could
  keep your keychain locked before): changes that ask for Touch ID are refused until it answers again, with words that
  say so. If it isn't answering when your node starts, the node waits a minute, then doesn't start, and says why. That
  is stricter than what you chose (that the node refuse the changes that ask for Touch ID): it was chosen so that no
  half-working node is ever left running, and you were told (the lead, 2026-11-27). The words send you to your
  password only for something nothing of yours can cause: the keeper not installed at all, its own store damaged, or
  your install's record of builds missing or refused (each a system file found missing, or read whole and refused;
  never a read that merely failed, which gets the same words as busy); when it is installed but busy or not running, they never do, since a program of yours
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
  proposed. If you ever suspect it happened: first stop your sessions and what they started (a session still
  running would rewrite the fresh install's build too, and the remedy would pin it again); then install afresh, run `node-pins-mac.sh --keep 1` so only that fresh build
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
  other modes from ever sending the keeper a request (only its checked start does); besides, an installed build of your node takes no test flag, starts no server but the one
  your install lists for it, and hands its connections to no program of yours, in any mode, not even in the moment
  before your install's password, when its new build isn't listed yet.

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
| **Copies the node**: copies its files, or runs its genuine pinned host beside it (a second checked start, journal P40), or in another mode (the deputy, P33), or an older pinned build (P41) | a copied vault file is ciphertext under a key it can't get; two checked hosts can't both continue the record: the keeper's swap is one atomic compare-and-set, so the loser's raise fails and it writes nothing (P40, its residue included) | the second host's start (open), the loser's `lock.lost`; an older pinned build's start (the unswitched-build rule, P41) | the keeper can't tell the genuine host's modes apart: only J0a's rule 2 (only the checked start calls the keeper) keeps the other modes away, as it keeps them from the Keychain today, and N1's rule keeps a pinned image's other modes from handing its pair ends to a session's code (KP20d); every pinned build is served (the `--keep 1` lever, the Mac spec's F8), and every pinned build is one at or after the floor (N2: the record's format 2, KP6b) |
| **Signs itself with the local identity** (holder (4) of the journal's table), or is a program you once clicked Always Allow for (holder (5)) | P30 for the node's record: the keeper serves by the cdhash of the code running, pinned by the install's administrator step, never by a signing identity, team or designated requirement; a program of its own code has another cdhash. The genuine host signed again is either other code, with another cdhash (refused), or the same cdhash, which is the genuine code (served, harmlessly). Which of the two it is (the code directory carries the requirements' hash) is K-M11, kept as information: it gates nothing | — | none for the record |
| **Talks to the keeper** itself: sends requests of its own, writes a request then execs the pinned host, holds a copy of a send right or of a descriptor and sends or acts while the genuine host talks, sends again a genuine request's bytes, sends ends of pairs or connections, or gives a host it starts a bootstrap port of its own | getting the key or moving a slot: **every request is a Mach message judged by the audit token the kernel put in it at its send** (the interface's candidate C, measured as K-M1 (n)): only a message sent by a pinned, hardened host image's own code, as it ran when it sent, is served; a message sent before an exec names the old image and is refused (n2), another task's names that task (n4), resent bytes name the resender; the reply goes only to the send-once right the request carried. **No socket end reaches the keeper**, so nothing done to a pair or a connection (write then exec, a silent holder, a nonce answered by another holder, a failed write that makes the genuine image the last to act: K-M1 (g) to (m)) can be a request. The host checks the keeper's port by its first reply (root, the installed cdhash) before it sends anything else to it (KP17), so a service of the same name in your domain gets at most an `open` | — | **keeping the keeper busy** (a flood of messages) is a denial your account can cause at will, as it could lock the login keychain before: guarded changes refused, a node that doesn't start while it lasts, and the journal's at-will levers through a failed raise (P36's uncounted revocation, P42's file ahead) reachable through it as they were through the locked keychain ([While the keeper is down](#while-the-node-is-down-and-while-the-keeper-is-down)) |
| **Impersonates the keeper** (a service of the same name in your own domain, a bootstrap port of its own given to a host it starts, a trial keeper's port) | the host checks the first reply from a port it looked up by the reply's trailer (root, the cdhash in the node's `installed`, read through the root walk, hardened) before it sends that port anything else, and every reply names the keeper's uid and store (`node`, never `trial`), which the host requires to be its own (the proof review's D4); a fake sees at most an `open`, which holds nothing | — | a denial: something of your account answering in the keeper's name keeps the node from starting, with words of its own (D5), never a password |
| **Edits the build during an install or update you run** (the node's programs are built and signed under your account; the keeper's program is built by root) | for **the keeper's program**: any rewrite of the build, the checkout or the build's output, since root builds the keeper alone from the commit's objects, every hash recomputed in a root-owned folder, with root's toolchain and nothing of your account's (KP21); and forcing the keeper step at a node update by rewriting the build, since the step runs only when the commit's keeper source tree differs from the one root recorded (KP23a) | — | **for the node's programs (KP6a, the review's F3): an update during which a session rewrote the host's build pins that host, and the keeper then serves it the key and both slots**: it reads every secret of the vault and can seal any vault and swap either slot, for as long as its row stays (`--keep 1` keeps only the build just installed, which is this one); the key never rotates, so one success lasts until a new key (F17). The install's window (the Mac spec's S9) gave a session nothing P34 didn't before the keeper; with it, this is the route to everything the keeper closes, at every update. **Accepted by the user, 2026-11-27 (8B298106)**, stated, not closed (closing it would need every program built as root). The remedy after a suspected compromise: first stop your sessions and what they started (the re-check's N8: one still running rewrites the fresh install's build too), then a fresh install, `node-pins-mac.sh --keep 1`, then the keeper step's `--remove --forget-store` and `--install` for a new key; the record begins again. **For the keeper's program, what remains:** the choice of commit (bounded by the install's provenance check: on v2, both runners passed), and a session that rewrites the install script itself, which can then hand root a self-consistent commit of its own making (root checks the objects' hashes, not who wrote them): S1's class ("root is one password away"), as a faked `sudo` prompt is |
| **Another uid's process** | getting anything: the keeper destroys, unanswered, any message whose trailer's effective or real uid isn't its uid | — | it can keep the keeper busy too (a denial, fail closed) |
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
        build/                                                   root:wheel 0700  (the keeper step's root build, while it runs)
        store/                                                   root:wheel 0700  (the keeper step)
            node.keep                                            root:wheel 0600  (written by the keeper alone)
            lock                                                 root:wheel 0600  (the keeper's lock, held for its life)
/Library/LaunchDaemons/dev.vibeswitcher.keeper.<uid>.plist       root:wheel 0644  (the keeper step)
```

`installed` is two lines, `tree <40 lowercase hex>` (the keeper's source tree id at the commit root built it from,
`git rev-parse <commit>:Keeper`) and `cdhash <40 lowercase hex>` (the program root built and signed from it). Any
account can read it; only the keeper step writes it. **One keeper process per store:** at its start, **before it touches anything else in its folder** (the re-check's
N5: no check-in for its port, no read of the store), the keeper opens `store/lock` (`O_CREAT|O_NOFOLLOW`,
`0600`) and takes an exclusive `flock` on it without waiting, held for its life; a lock already held and it exits,
having touched nothing else and served nothing, so a second keeper (root's acts: a `bootout` that returned early)
never orphans the first one's listener by binding the socket over it (the review's F8: two keepers on one store would each read a
slot as X and each answer `ok` to a swap from X, P40's residue back). No process of your account can open that file.

One keeper per account that runs a node (label `dev.vibeswitcher.keeper.<uid>`), so one account's keeper serves one
uid's store and record, and a removal is one account's alone. **Its way in is a Mach service, not a socket** (the
proof after K-M1): its plist (root's, fixed text) names `MachServices` `dev.vibeswitcher.keeper.<uid>`, the keeper checks
in for that port at its start, after its store's lock, and nothing of it is a file your account could `chmod`, remove
or bind over. Any process may send it a message; each is judged by its own audit trailer, and one from another uid is
destroyed unanswered. (The socket this design first had, `keeper.sock`, root's and `0666`, with `getpeereid` before a
byte was read, is gone with the pair proof; K-M6's access entry is no longer needed.)

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

**What a failed read of the store is** (the re-check's N3: `readRootRecord` returns one refusal for every errno,
`RootRecord.swift:29-50`, so a keeper built on it as it is would call `EMFILE`, `ENFILE`, `EIO` or `ENOMEM` damage).
K1 gives the walk's refusal a kind, its words unchanged, and the store, the pins record's read (`NodePins.read`) and
K6's look all classify by it, three ways and no other:

- **`damaged`: read whole, and refused.** The store was opened and read to its end, and it doesn't parse, or its
  folder or file isn't root's alone (owner, mode, an ACL, a link where the walk allows none), or its uid isn't the
  keeper's. The keeper answers `damaged` to every request and changes nothing, never making a new key over it. Only
  the keeper step's `--start-over` (your `sudo`) moves it aside, renamed `node.keep.set-aside-<date>`, never deleted,
  and the next open makes a new key.
- **Missing: `ENOENT` alone**, for `node.keep` in a `store/` folder that is there and root's alone. Only root can
  delete one: the next open makes a key, and the node's file then doesn't open (`unreadable`, open, first looks and
  devices held). For K6, `ENOENT` alone for the plist or the program is "not installed".
- **A read error: every other failure** (`EMFILE`, `ENFILE`, `EIO`, `ENOMEM`, `EINTR` past its retries, a short read,
  anything not above). It is neither `damaged` nor missing: the keeper answers `readError` to that request, changes
  nothing, **never makes a key**, and reads the store again at the next request. Its words are worded like "busy" and
  never mention a password, the setup line or an install, since whether a process of your account can make a root
  process's `open` fail (a full system file table, `ENFILE`) is not measured (K-M10 (d)) and the design assumes it
  can.

### What it does, and what it never does

Two requests, one per message, served one at a time by the one keeper process that holds the store's lock (so each
swap is atomic without another lock):

- **`open`**: the account's key (32 bytes from `SecRandomCopyBytes`, made and written to the store at the first
  `open`, never taken from a caller) and both slots as they are (present or absent). The host's start, and the
  read-back below. **The key never rotates** (the review's F17): a key read once (through KP6a, through a bug in a
  pinned build fixed later, or from a backup: [Open questions](#open-questions-for-the-lead-or-the-user) 2) opens and
  forges every later vault file until the record begins again under a new key. The remedy, beside the Mac spec's F8
  lever (`--keep 1`, which drops older builds from the keeper's service): first stop your sessions and what they
  started (N8), then `node-pins-mac.sh --keep 1`, then the keeper
  step's `--remove --forget-store` and `--install` again; the next `open` makes a new key, and the node's file then
  doesn't open (`unreadable`, open, first looks and devices held), so its record begins again.
- **`swap(slot, expected, new)`**: if the slot holds `expected` (absent counts as a value), it becomes `new`, written
  to the store before the answer, and the answer is `ok`; else nothing changes and the answer is `moved`. No delete,
  no read of one slot alone, no "set whatever".

It never: reads anything under a user's home, takes a value from its environment, runs a program, opens a network
socket, watches the node, keeps state between messages, logs a secret, or answers any message but one it accepted (on
that message's own send-once reply right; a message it refuses for its form or its uid is destroyed unanswered). (It
reads no file under a user's home itself; Security's `runs` would have, the sender's executable at its path, D1, so
the keeper doesn't call it: [the interface](#the-interface-how-the-keeper-knows-the-caller-is-the-genuine-node), step 4.) It takes exactly one argument, `--uid <decimal>`, from its plist (root's); any other argument, or none, and it
exits. **Its folder is its own executable's** (the review's F16): as root it reads its own path (`proc_pidpath` of its
own pid), which must be exactly `/Library/Application Support/VibeSwitcher/keeper-<uid>/vibeswitcher-keeper` or the
trial's `/Library/Application Support/VibeSwitcher-trial/keeper-<uid>/vibeswitcher-keeper` for its `--uid`, walked
from `/` as `readRootRecord` walks (root's alone, no link, no ACL); its store and lock are in that folder, and
the pins record it reads is that folder's sibling `node-<uid>.pins` (the pins step's own two paths, node and trial,
`node-pins-mac.sh`'s `--record`). Any other path, and it exits having opened nothing. So a trial keeper never opens
the real store or the real pins record, and the program takes no path from anyone
(`KeeperTests.theTrialKeeperNeverOpensTheRealStore`). Its diagnosis goes to the unified log under
`dev.vibeswitcher.keeper` (refusals, with the caller's pid and the reason), which nothing reads.

**Its program** is built by root from the commit's source ([Install, update and removal](#install-update-and-removal)),
so it is **a package of its own with no dependency**, decided before K0 (the lead, 2026-11-27, Open questions 7): the
folder `Keeper/` at the repository's top, one tree object at any commit (`<commit>:Keeper`, whose id is what root
records), holding its own `Package.swift` that names no package, the library target `VibeKeep`, the executable target
`vibeswitcher-keeper` (linking `VibeKeep` alone), and **no test target** (the re-check's N7: `swift test` runs only
the root package's test targets, so a test placed in `Keeper/Tests` would never run in `scripts/test.sh` and a
regression in the store's parse would merge green). The keeper's tests stay in the root package's test targets, as
[Every path to the property](#every-path-to-the-property) plans them (`Tests/VibePlatformTests/Keeper*Tests.swift` and
the rest, which import `VibeKeep` through the root package's dependency on it). Its sources import
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
(K0): `KeeperLintTests.theKeeperPackageNamesNoDependency` (its manifest names no package and no test target, its
sources import only `Foundation`, `Security` and the C library) and `KeeperLintTests.theKeeperLinksOnlyVibeKeep`. The less a root process
links, and the less root compiles, the less there is to review.

### The interface: how the keeper knows the caller is the genuine node

**The proof after K-M1** (2026-11-27, branch `v2-mac-keeper-proof`). The design first proved a caller by a socket pair
it made, on the premise that a pair's token names its maker as it was at the making. K-M1 refuted that, and its
second part ((g) to (o), [the record's K-M1 row](../../process/v2-mac-measurements.md), "K-M1, second part") measured
what a redesign over socket pairs would rest on. The facts, each measured on this Mac as the user:

- **A socket's token names whoever last sent, received or polled on the other end, as it runs now** ((a) to (c),
  (j)): a write, a zero-length send, a read or peek with or without a byte there, `poll`, and a read that waits (named
  while it waits) each move it; `getsockopt`, `setsockopt`, `getpeername`, `ioctl(FIONREAD)`, `fstat`, `dup` and close,
  and `shutdown` don't.
- **A failed act stamps as a successful one does, leaving no byte** ((j), (g4), (g5)): a write that fails with `EPIPE`
  once another holder shut the write side, a read that fails with `EAGAIN`, a read that returns the end of file.
- **After an exec, the token names the new image at the same pid**, accepted by Security ((b), (g1)); only a token
  kept from before the exec is refused (the controls); once the last to act has exited, the read is refused (`EINVAL`,
  (k)).
- **A silent copy-holder is invisible to every read until it acts, and can take the keeper's reply** ((c), (h)).
- **A Unix socket here carries no sender's credentials per message** (`SCM_CREDS` refused, (o)).
- **A Mach message carries its sender's audit token as it was at the send** ((n1) to (n6)): a message sent and then
  the sender's exec, read after the exec, names the sender's old pidversion and Security refuses it (`-67065`, (n2));
  a sender gone is refused ((n3)); a message from a forked child of the maker names that child ((n4)); the image a
  process exec'd, sending with its own code, is named at that pid with its new pidversion and accepted ((n5)); so is
  an image started by `posix_spawn` ((n6)). No later act of anyone changes a message's trailer.
- A socket in flight whose sender closed its copy before the receiver held it loses what was written on its peer:
  the receiver reads the end of file in 14 to 172 of 200 runs (K-M1's runs, the proof review's and this round's), and
  in none once the sender keeps its copy until the
  receiver says it holds it ((l)). A liveness fact for every handshake below, not a security one.

**What a proof must show.** That the request it acts on was made by a pinned, hardened host image as that image runs
its own code, not written by other code before an exec, not written by another holder of a descriptor, not replayed;
and that its reply reaches only that image. Three candidates were measured against the whole attack: a session of
your account that can spawn and exec anything your account can run (the genuine images included), hold copies of the
descriptors it made, stop and continue its own processes, and write your files.

**Candidate A, a challenge on the maker's pair** (rejected). *Order:* the host sends one end of a pair it made with the
hello, then the request on its end; the keeper reads the request, asks the pair's token (it must name a pinned
hardened host), keeps it, writes an 8-byte nonce; the host reads the nonce and writes it back, then half-closes; the
keeper reads the answer and the end of file, asks the token again (the same pid and pidversion, Security again), and
only then acts and replies. *What each check would prove:* the first read, that the last to act on the maker's end
before it runs the pinned image (so a maker that wrote and hasn't exec'd is refused there, (i)); the nonce, that
something acted after the keeper's challenge; the second read, that the last to act is still the pinned image.
*Measured:* (g2) a silent copy-holder S answers the nonce and is named, refused; but (g4) S writes the request and the
answer, shuts the write side, and the image, started by the maker with that end as its descriptor 2, fails one write:
every read names the image with the same pid and pidversion, no byte trails the answer, and the keeper then reads the
end of file. (g5) the same with one failed read of descriptor 0. *What a session can still do:* have any request
served. It needs the image to act once on a descriptor it was started with, after S's last write and before the
keeper's read; the host's image writes its diagnosis on descriptor 2 (`Platform.Stdio.error`), its parser reads descriptor 0, and
a session can stop and continue the process it started, so the timing is a race it can run as often as it likes. A
rule that every mode of every pinned build never acts on a descriptor it was started with isn't true today and can't
be shown by a lint. *Cost, had it held:* two round trips per request; in the root keeper, the pair's checks, a nonce and
two token reads; nothing at a session start.

**Candidate B, a keeper-made end handed to a checked peer** (rejected). *Order:* as A to the first token read; then the
keeper makes a pair of its own and sends one end over the maker's pair; the host takes it and writes its request on
it; the keeper reads the request there and asks that end's token, which must name the image the first read named.
*What each check would prove:* the end didn't exist before the image ran, so it can't be a descriptor the image was
started with. *Measured:* (m) any holder of the maker's end takes the keeper's end (S), and is named when it writes on
it; and when S passes that end to the image over a socket the image takes descriptors from, the image's one read
names the image. *What a session can still do:* have any request served by any pinned image that takes a descriptor
from a socket it didn't make and acts on it: the handover keeper's code does (`MacHandoverKeeper.take` takes the
keeper's pair over its inherited channel and reads it; `keepIfAsked` takes the host's pair and reads the parcel from it
before `parentRefusal` judges it), in a mode a session can start (`--handover-keeper-channel FD`, `--handover-keeper
FD`). *Cost, had it held:* three round trips; the keeper makes and passes a pair per request.

**Candidate C, the Mach form: each request a Mach message, judged by the audit token the kernel put in it at its send**
(**chosen**; the build order's XPC fallback, taken in its raw form). *Order:*

1. **The keeper's port.** The keeper's plist (root's, fixed text) names one Mach service,
   `dev.vibeswitcher.keeper.<uid>` (`MachServices`); the keeper checks in for its receive right at its start
   (`bootstrap_check_in`), after its store's lock (N5), and holds it for its life. No socket, no listener, no file in
   your reach.
2. **The host's lookup and its check of the keeper.** The host's client (`NodeAnchor`'s keeper store) looks the name up
   through its bootstrap port. A send right is only a way to reach a port, so before it sends anything else to a
   port it looked up, it sends `open` (nothing in it is secret) and requires the reply (step 5: of the exact form, naming
   this host's own pid and pidversion as the sender judged, **and the keeper's uid and store, which must be this host's
   uid and `node`**: the proof review's D4) and its trailer to name **root** (its effective uid 0) **running the cdhash
   root recorded in the node's `installed`** (read through the root walk, as the pins record is) with the Hardened
   Runtime, by the kernel's record of the trailer's token as the keeper reads a sender's (step 4: `csops_audittoken`,
   the cdhash the process started with and its status word, hardened as step 4 words it). Anything else (a fake service
   your account registered in its own domain under the name, a bootstrap port a session gave a host it started, the
   trial's keeper, which may run the same cdhash as root but names `trial`) is not the keeper: nothing more is sent to
   that port, and the start's words are D5's ([While the keeper is
   down](#while-the-node-is-down-and-while-the-keeper-is-down)). A port checked once stays root's while it lives (the
   proof review's N2: with `MachServices`, launchd holds the receive right while the keeper isn't running and hands it
   to the keeper at its check-in, so only root ever holds it: assumed, K-M15); a dead name is looked up and checked
   again. Every later reply is checked the same way, and a reply the host refuses is destroyed with what it brought
   (`mach_msg_destroy`: a fake's may be complex; N4).
3. **The request: one Mach message**, fixed size, not complex (no port or memory descriptor: `MACH_MSGH_BITS_COMPLEX`
   set is refused), its reply port a send-once right the host made for this request, its body the 8 bytes
   `vskeep1\n`, one verb byte and the verb's fixed fields (`open`: none; `swap`: slot, expected's presence, expected,
   new). The prefix keeps another protocol's message from reading as a request (KP11).
4. **The keeper's check**, on the message alone, received with its audit trailer
   (`MACH_RCV_TRAILER_AUDIT`) into a fixed buffer **without `MACH_RCV_LARGE`**, so a message larger than a request is
   destroyed by the kernel and never reaches the keeper's code (the proof review's N4): a message of another size, a
   complex one, one without a send-once reply port, or a body that isn't exactly a request is destroyed
   (`mach_msg_destroy`, so no right or memory a session sent stays in the root process: F7's rule in Mach's form) and
   nothing is answered. (A complex message's out-of-line ports are copied into the keeper before any check, every
   right it carries: K-M10 (b) counts them, and the destroy releases them.) From the **trailer's token**: its effective
   and real uid the keeper's; then **the kernel's own record of the process that token names**, by the token
   (`csops_audittoken` with `CS_OPS_CDHASH` and `CS_OPS_STATUS`, the call Security itself makes, declared in
   `VibeKeep` as the probe declares it): the cdhash the process was started with, which must be the **host** cdhash
   of a row of the account's pins record, read afresh for this message (`NodePins.read`, the walk from `/`), and its
   status word, which must be hardened as the genuine ad hoc host is (the proof review's D2, on M6's measured word
   `0x22011311` and K-M16's here part's, the same): `CS_VALID`, `CS_RUNTIME`, `CS_HARD`, `CS_KILL` and library
   validation in force (`CS_FORCED_LV`, which this Mac's ad hoc hardened image has, or `CS_REQUIRE_LV`, which it
   doesn't: requiring `CS_REQUIRE_LV` alone would refuse the genuine host), and none of `CS_GET_TASK_ALLOW`,
   `CS_DEBUGGED`, `CS_INVALID_ALLOWED`. **Not Security's `runs`** (`SecCodeCheckValidity` against `cdhash H"…"`), the
   proof review's D1, measured (K-M16 here, (d2)): it doesn't hash the file's pages (0.2 ms for a 256 MiB image), but
   it opens the sender's executable at its path, a file in a folder of your account's, so a file renamed over a running
   genuine host's path makes the check fail and one that can't be read in bounded time (a stalled volume) would hold
   the serial keeper; the kernel's record opens nothing, is unchanged by a rename, and is refused for a token whose
   process exec'd or exited since ((d1) to (d3)). A server's or a command line's cdhash is refused: only a host asks.
   The token is the sender's as it was at the send (n1 to n6): a message written by other code that then exec'd the
   pinned host names that code's old pidversion and is refused (n2; the kernel's record too, (d3)); a holder of a copy
   of the send right is named as itself (n4); a sender gone is refused (n3; (d2)'s last line).
5. **The reply**, on the send-once right the request carried: the task that holds that right's receive right reads
   it (a send-once right is used once, by the keeper). **Every reply names the sender the keeper judged**: the pid
   and pidversion of the request's trailer, first in its body, **then the keeper's uid and its store, `node` or
   `trial`** (the proof review's D4: the trial keeper, K7, runs the same program as root, possibly at the installed
   cdhash, K-M13; without the store's name a host pointed at the trial's port would take the trial store's key and the
   node's record would begin again twice). The host requires all of them to be its own (its own task's audit token,
   `TASK_AUDIT_TOKEN`; its own uid; `node`), beside the reply's own trailer (root, the cdhash in the node's
   `installed`, hardened):
   since the reply port travels in the request, a process that received the host's request (a service of the same
   name in your domain, step 2) can put the host's reply right in a request of its own to the real keeper; that
   request is judged as the forwarder's and its reply, a refusal, names the forwarder, so the host takes it for no
   answer, keeps nothing, and never takes that port for the keeper's
   (`NodeAnchorTests.aFakeThatForwardsTheHostsReplyPortGetsTheHostNothing`). A message whose effective or real uid
   isn't the keeper's, or that isn't of the exact form, is destroyed unanswered (so `wrongUid` is never sent). `open`: status, the
   key, each slot's presence and value; `swap`: status. Statuses as before: `ok`, `moved`, `damaged`, `readError`
   (N3's third kind, naming which), `unwritable`, and the refusals `noRecord` (the pins record missing, or read whole
   and refused; a read error is `readError`, never `noRecord`), `notPinned`, `notHardened`, `wrongUid`. A refusal
   carries nothing of the store.

*What each check proves, given the measured facts:* the trailer, that the message's bytes were sent by the task it
names, running the code Security finds at that token (n1, n5, n6), as it was when it sent (n2): so the request was
made by a pinned, hardened host image running its own code, and nothing that held a descriptor, a port or a pair end
before or after can have written it. The reply port, that the answer goes back to that task. Replay: a message is
received once, by the one task that holds the port's receive right; the same bytes sent again by anyone carry the
resender's token. *What a session of your account can still do:* run the genuine pinned image in any mode (the
deputy, KP12: only the checked start's code sends a keeper message, J0a's rule 2, unchanged); be pinned through an
update it rewrote (KP6a, accepted); send the keeper messages of its own, every one refused, and fill its port's queue
(a denial, KP19, as the socket's backlog was; senders give up at their own timeout); register a service of the same
name in its own domain, or give a host it starts a bootstrap port of its own, which the host's check of the reply
refuses (a denial at most: the host sends that port an `open`, which holds nothing); kill the keeper's clients. It
can no longer get a request served through anything it holds: no socket end, of any pair, reaches the keeper.

*What the proof assumes, stated* (the proof round's blind check named A to C; the proof review of 2026-11-27 found A's
test too narrow, I1 to I3, and A is now measured as far as it can be here: [the record's K-M16, here](../../process/v2-mac-measurements.md)):
**(A) The genuine hardened image, once a session of your account has started it, runs only its own code.** A session
can start the genuine host (or a child of it, or the handover's processes: I3) with exception handlers, limits,
environment, arguments and a bootstrap port of its own choosing. **Measured here** (K-M16's here part, on the probe's
own hardened children, as the user, no dialog): task-level exception ports a parent names (in `posix_spawn`'s
attributes, or on its own task just before the exec) cross into the hardened image with every behaviour
(`EXCEPTION_STATE` and `EXCEPTION_STATE_IDENTITY_PROTECTED` included) on every mask, `EXC_MASK_CRASH` and
`EXC_MASK_CORPSE_NOTIFY` included, which this SDK's `EXC_MASK_ALL` doesn't contain ((p1), (p2); the Hardened Runtime
strips none, (p4)); thread-level ports set on the exec'ing thread don't cross the exec ((p3)); a launcher's limits
cross it, and can end the image before its first statement, by a bad-access fault (a 16 KiB stack: `SIGSEGV`, the C
image and the Swift image with Foundation alike) or an abort (4 descriptors, none free: `SIGABRT`; with 5, one free, it runs) ((q2), (q3), (q4), (q6), each without the first statement's marker); the
window from the spawn to the image's first statement is dyld and the libraries' initializers, 1 to 6 ms warm ((w1),
(w2)); and the one-call clear below leaves no handler on any mask, task or main thread. **The rule (I2), built in K4a-ii and listed again in K4:
`main`'s first statement, in every mode of the image, before `argv` is read** (today `main.swift:9-19` dispatches five
modes on `argv` before the host's hardening at `:24`, which on the Mac does nothing, `HostHardening.swift:80-81`):
`task_set_exception_ports(mach_task_self(), EXC_MASK_ALL | EXC_MASK_CRASH | EXC_MASK_CORPSE_NOTIFY, MACH_PORT_NULL,
EXCEPTION_DEFAULT, THREAD_STATE_NONE)` and the same on the main thread (`thread_set_exception_ports` on
`mach_thread_self()`), every valid mask named (measured accepted, (p0) to (q8)'s clear lines); then D6's environment
rule. **It is necessary, not shown sufficient:** it closes every route **after** it (a fault, a crash or a corpse after
it goes to no handler of a session's) and **none before it**. A fault a session forces in the window goes to the
handler it named; whether that handler receives it, whether a reply that sets the thread's state moves the image's
thread, whether a crash or corpse message carries a port that reads memory, whether a task port the child handed over
before its exec still works, and whether a traced exec is refused or marked `CS_DEBUGGED` are the **active routes,
owed to the keyboard trial** (K-M16's trial part, **K7a**: a keyboard step of its own, on scratch hardened images, which
needs no installed keeper and waits on no slice; not run from an agent's session), and until it shows each closed
the design treats it as **open**. (The image holds nothing of the node before its first statement: the key comes from
`open`, long after. What a driven thread could do is run the image's own code at a session's choosing, which is why
the window matters, not what is in memory then.) **The rule in force until then:** nothing that gives a host the
node's key is offered (K4's client, K5's real install), so no key exists for a driven host to take. **The fallback, if
the trial leaves a route open:** the keeper serves a host only when **launchd itself started that process as the
node's own job from the host's own file**, so no code of a session's ran in it before the host image, and its
handlers and limits are launchd's (the job's plist is yours, but it names no exception port; a limit it sets crashes
the host into launchd's handler, not a session's); how the root keeper verifies that of a sender (launchd's record of
the job's process and the kernel's of the process, whose fork and which exec) is measured in the trial before it is
relied on, and **if no such check exists, the keeper isn't offered at all** (K4 and K5's real install stay unoffered,
and the node doesn't run on the Mac with its keeper) until one does. **The children and the handover processes**
(I3) aren't started by launchd, so the fallback doesn't reach them; if K7a leaves a route open for them: **K4c's
checked switch isn't offered** (its parcel carries the secrets channel and every session's terminal to a handover
keeper a session could drive), and the node updates by a stop and a start instead (each start a launchd job, under the
fallback, its sessions ended); **K4a-ii** (whose children hold a session's output and the server's connector, never
the node's key) is offered only if the lead accepts the open route as its stated limit, since it still closes what
today leaves open (a launcher that isn't the image's code gets nothing), and not otherwise. K4a-ii and K4c land on v2
either way (switched off), so K4b and K5 aren't held by this. K-M16's row in [Every path to the
property](#every-path-to-the-property) and the rows KA1 to KA12 give each route with the case or rule that closes it.
This is the threat table's "a program that takes the host's task port" (S1, S11) widened to what needs no task port:
the pair proof had it too.
**(B) Only the pinned code runs in the host: measured for this Mac's ad hoc hardened image** (M6: `DYLD_INSERT_LIBRARIES`
refused, `marker=absent`; its status word `0x22011311`, with `CS_FORCED_LV` and not `CS_REQUIRE_LV`; K-M16 here read
the same word for its own image; for the Swift host it follows), so **B's library half is not owed to K-M16** (the
proof review's D2). The keeper pins the main executable's cdhash; the entitlements are inside it, so the pins step and
K2 refuse a host whose signature carries `get-task-allow`, `disable-library-validation` or
`allow-dyld-environment-variables`, and K2's check of the status word is step 4's (library validation as
`CS_FORCED_LV` or `CS_REQUIRE_LV`). **Environment that steers system libraries without loading code** (malloc's
variables, the Swift runtime's backtracer, Foundation's) isn't code (the proof review's D6): **closed by a rule, not
measured** ([the host's side](#the-hosts-side), "The first statement"): the checked start, and the parser and the
handover keeper in a hardened image, refuse to go on with any variable outside a fixed list, right after the clear,
before `open`, a proof or anything else; what a library reads before the first statement is in A's window.
**(C) The checked start isn't a deputy** (KP12): what it sends the keeper is `open` and the journal's
next `{record, seq, bind}`, computed from the sealed vault under the key, never a value a caller or a file of yours
supplies; the command line's requests reach it only through the server's own rules and, for a guarded change, the
Touch ID dialog (the Mac spec: the dialog carries the guarantee). A socket's token, which a session can make name a
genuine command line (K-M1 (j), (g4)), is a guard rail there, never what the keeper's property rests on. And the
client accepts only a reply of the exact form on its reply port: a send-once notification (the kernel's, when the
keeper destroys a refused request) is "no answer"; every reply it refuses is destroyed with what it brought (N4).
*Cost:* one message and one reply per request (the pair's way was a connect, a `sendmsg`, a write and a read); in
the root keeper, a check-in, one receive loop with its trailer, the kernel's record by the token (two `csops_audittoken`
calls, under 0.01 ms: K-M16 here, (d1)), `mach_msg_destroy` for what it refuses, and none of
the socket's code (no `0666` socket, no `getpeereid`, no `SCM_RIGHTS`, no pair checks, no 1 s and 2 s limits per
connection: a message arrives whole or not at all); at a session start, nothing (the keeper is reached only by the
checked start and its guarded changes). **Not measured here** (the K-M row the XPC fallback said it would need, split):
the launchd half, which needs a LaunchDaemon: that a root daemon's `MachServices` name is found from your login
session's bootstrap, that a service of the same name registered in your account's own domain is found first (the
check in 2 assumes it can be), the port's queue limit under a flood, and the keeper's reply's trailer naming root:
**K-M15, in the trial (K7)**. The trailer itself, the part the proof rests on, is measured here (n).

**Not taken within C: XPC** (`xpc_connection_create_mach_service` with `XPC_CONNECTION_MACH_SERVICE_PRIVILEGED`, each
message checked by `SecCodeCreateWithXPCMessage`, public since macOS 11, or the connection's peer requirement). Its
gains: the privileged lookup, which a service in your own domain can't answer, and typed dictionaries. Not taken
because it puts libxpc's connection machinery in the root keeper and its per-message token is libxpc's word, not
measured here, where the raw trailer is the measured fact itself; it is the design's second choice if K-M15 shows
the client's lookup can't be checked as step 2 says.

**Why not the socket's own token, or a pair** (kept, now measured): see A and B. The connection's token, a pair's,
and a keeper-made end's are each "the last to act, as it runs now" ((a) to (c), (f), (j), (m)), and a failed act
leaves no byte ((g4), (g5)). The old interface's steps (the hello, the pair's token, the token read again, a closed
other end refused) and the old `peerToken` comment's "fixed at its making" are struck; K2 corrects that comment to
K-M1's words.

**How this relates to rows 7 and 10's record.** The keeper adds no fingerprint list of its own. It reads the same
`node-<uid>.pins` (BCECD1F3) through the same reader, `NodePins.read` and `readRootRecord`'s walk, that the checked
start (rows 4, 5), the server's anchor for the command line (row 7) and the host check across a switch (row 10) read;
it takes only the `host` column. So the install's one administrator step stays the only writer of code fingerprints:
an update's pins step is all the keeper needs to serve the new build, a rollback's build is served while the record
keeps it, and `node-pins-mac.sh --keep 1` drops older builds from the keeper's service at their next request (the Mac
spec's F8 lever reaches the record too). Beside that lever, the general rule (the re-check's N2, widened by the proof
review's D3): **a fix to any host-side rule the keeper's property rests on** (the image's pair rules, J0a's rule 2, the
first statement's clear and environment rule, the hardened parser's refusal of its test hooks, each proof's role, and
whatever the keyboard trial adds) reaches the keeper's service only once older rows are dropped, which for K4a the
setup's `--fresh`, the floor and the record's `format 2` do ([Install, update and removal](#install-update-and-removal)). The signing identity plays no part: the record pins cdhashes, and unsigned
(ad hoc) builds work, since a build's key no longer follows its signature.

### The host's side

The node's host reaches the keeper only through one seam, `NodeAnchor` (J0a's `NodeKeychain`, renamed: [What changes
in the journal design](#what-changes-in-the-journal-design)), with two stores: in memory (tests) and the keeper's
client. There is no Keychain store and no fallback to one. **Under the Mach form** ([the
interface](#the-interface-how-the-keeper-knows-the-caller-is-the-genuine-node), candidate C) the keeper takes no socket
end, so its property no longer depends on which process holds an end of a pair the host made: the rules below about
pair ends (K4a-i, K4a-ii, N1) are kept for **the host's own data** (a session's terminal output on the parser link, the
server child's connector and each app connection, the handover's state and secrets), which F1 showed a replaced
launcher could take, and none of them is a barrier between a session and the keeper any more. The client's rules,
each a test in K4:

- **Only the checked node start calls it** (J0a's rule 2, `HostJournalTests.noOtherModeTouchesTheNodesItems`, its
  keeper arm). The keeper can't tell the genuine host's modes apart; this code is what keeps the deputy away.
- **The first statement** (the proof review's I2, I3 and D6; assumption A of [the
  interface](#the-interface-how-the-keeper-knows-the-caller-is-the-genuine-node)). In `vibeswitcher-host`'s
  `main.swift`, **before `PTYSpawn.execIfLaunched` and every other line**, so in every mode of the image (the host, the
  checked start, the launcher, the parser, the handover's probe, the handover keeper, the new image after a switch,
  the egress proxy), and before `argv` or the environment is read: (1) **the clear**,
  `task_set_exception_ports(mach_task_self(), EXC_MASK_ALL | EXC_MASK_CRASH | EXC_MASK_CORPSE_NOTIFY, MACH_PORT_NULL,
  EXCEPTION_DEFAULT, THREAD_STATE_NONE)` and `thread_set_exception_ports` with the same on `mach_thread_self()`, a
  failure of either ending the process at once (`_exit(70)`, nothing read); every valid mask is named, since this
  SDK's `EXC_MASK_ALL` leaves out `EXC_MASK_CRASH` and `EXC_MASK_CORPSE_NOTIFY` (`exception_types.h:160-176`), and
  the main thread too, though thread-level ports set before an exec were measured not to cross it (K-M16 here, (p3)):
  a later image may differ, and the call is cheap. (2) **The environment rule** (D6), right after: if `--node` is
  among the arguments (a membership test, nothing parsed), any variable outside the checked start's fixed list ends
  the process with exit 78 and words, before the lock, `open` or anything else (refused: its plist is your file, so
  something chose that environment, and a reset can't undo what a library already read); in the parser's and the
  handover keeper's modes of a **hardened** image (its own code's flags, as N4 (a)), finding any variable outside their
  list (`PATH=/usr/bin:/bin`, `HOME`, `TMPDIR`, `LANG`: they need none of the account's), the process **execs itself
  again, once, with exactly that list** (its own executable, its own arguments; a second finding ends it, exit 64),
  before its proof, so the image whose proof counts started with nothing a session chose in its environment, and a
  parent of an older build that spawns them with its whole environment (a node's switch from a build before K4c) still
  gets a working child;
  **every host spawns them with exactly that list**, so the re-exec is for an older parent only. The checked start's
  list is what its plist (the install's fixed text) and launchd give an agent; which names launchd adds is read at K7,
  the checked start logging the names it refused or kept there, and until then the list is
  `checkedNodeEnvironment`'s own with launchd's documented names. **Not** the app's host itself (its `host` mode, and
  the new image of its by-path handover: hardened, never pinned, holding no node data, and using no handover keeper,
  since `keeperTarget` is nil for it): its sessions' environment
  is the one it was started with, unchanged. (3) Only then the mode's dispatch. Its lint,
  `KeeperLintTests.theClearIsMainsFirstStatementInEveryMode` (the first executable statement of `main.swift` is the
  clear, and no other file of the image's targets calls `task_set_exception_ports` or `thread_set_exception_ports`
  but to clear), **built in K4a-ii, the first slice to land that needs it** (its children prove themselves after it, and
  its commit is the floor K4b names, so every row of a format-2 record has it), **and listed again in K4's row**, which
  waits on K4a-ii and adds the checked start's environment rule; and its tests, `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask` (this Mac's real hardened
  copy of the image started with ports named at the task level through `posix_spawn`'s attributes, every behaviour,
  every mask, and at the thread level before an exec, as K-M16 here does: its own read back after the clear, task and
  main thread, all null), `.theCheckedStartRefusesAnEnvironmentOutsideItsList`,
  `.aHardenedParserStartsItselfAgainWithItsList`, `.everyHostSpawnsItsParserWithTheList`,
  `MacHandoverKeeperProofTests.aHandoverKeeperStartsItselfAgainWithItsList`. **Necessary, not
  shown sufficient**: it closes what comes after it and nothing in the window before it (A, K-M16's trial part).
  **Its cost, stated:** the host and everything it starts then run with no task-level handler, the system's pair every
  process here inherits included (`EXC_RESOURCE` and `EXC_CORPSE_NOTIFY`, K-M16 here (p0)), so their crashes and
  resource reports go to the system's host-level handler; K4's sandbox check confirms that a session program's crash
  still leaves its report.
- **It looks the keeper's port up and checks it before it sends anything else to it** (the interface's step 2: the
  reply's trailer names root running the cdhash in `installed`, hardened), **and makes one send-once reply port per
  request**; it takes no port and no descriptor from its arguments, its environment or a parcel, and a dead name is
  looked up and checked again.
- **Every spawn sets `POSIX_SPAWN_CLOEXEC_DEFAULT`, in every mode of the image** (the review's F1 (b); KP20b; slice
  K4a-i, safe to build now).
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
  K4a-i makes every spawn of `vibeswitcher-server` name what it keeps too, and the lint's scope adds the server's targets
  (`vibeswitcher-server`, `VibeNode`); the class of a pair end given to the server is **given only to proven code
  whose own spawns close what they don't name**. Not "or the client's lock around its spawn": that lock covers only
  `NodeAnchor`'s own pairs, and a spawn racing any other pair's making inherits both of its ends.
- **No end of a pair the host writes on reaches code that hasn't proven it runs the code the host expected, in any
  mode, and a pinned image expects only its own code, its row's pinned server, or, across the checked node's own
  switch, a host the same record pins** (KP20; the review's F1 (a); the second half is the re-check's N1, the next
  rule). The keeper sees the image, not its mode (KP12), and reads as a request whatever the holder of
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
  matters here. **The change, K4a**, in two slices (the re-check's answer to its question 3,
  both homed in the Mac node spec's order of work, steps 10 and 11, since they change every session's start on the
  Mac with or without the keeper, and K4 waits on both): **K4a-i** is the `CLOEXEC_DEFAULT` rule above with its lint,
  behaviour-preserving; **K4a-ii** is the child proof below (steps 1 to 3), with N4's three statements and N1's
  rule, **in the Mach form** (the pair form, the handover keeper's way, is refuted for a child as for the keeper: a
  launcher replaced by other code makes the pair, sends its end, forks a holder and execs the genuine image, and the
  pair's token then names the genuine image at the spawned pid, K-M1 (b) and (c); the link goes to the holder). Each
  gets its own review.
  1. **The child is spawned holding no end of a pair the host writes data on, and with a port of the host's as its
     bootstrap special port** (`posix_spawnattr_setspecialport_np(…, TASK_BOOTSTRAP_PORT)`: a send right to a receive
     port the host made for this child; measured, K-M1 (n6)); no channel descriptor. Code at the launcher path that
     isn't the image's holds only a way to send to a port that judges each message by its own trailer.
  2. **After its exec the child sends one proof message**, with its own code, after its first statement (the clear and
     the environment rule, above): fixed size, carrying a send right to a receive port it made then, and **naming the
     role it proves for** (the proof review's D7: one byte, `parser` or `server`, in the body after a fixed prefix
     other than the keeper's `vskeep1\n`); the host takes a proof only for the role of the child it spawned, and the
     child takes only the exact form of its own role's handout (a parser only a link, a server only a connector),
     destroying anything else. The host receives it with its audit trailer and requires the trailer's token to be
     **the spawned pid, running the code it started for that child, with the Hardened Runtime exactly when the image
     is** (`MacHandoverKeeper.refusal`'s three checks, on the **kernel's record by the trailer's token**,
     `csops_audittoken` as the keeper's step 4, never Security's `runs`, which reads the file at the launcher's path a
     session can rename over: KA11): for a parser, the pinned host's
     cdhash, which on a checked node is the image's own (`Platform.CodeIdentity.ownCdhash`), and in every other mode
     the image's own; for the server child, in a **pinned** image (N1's rule, below) the `server` of its own row, in
     every mode, whatever its `--server` file is, and only in an image that isn't pinned the cdhash the host read from
     its `--server` file. A message other code sent before it exec'd the image names that code's old pidversion and is
     refused (n2); one from a process it forked names that process (n4). Anything else: the child is ended and
     reaped, nothing is sent, and what needed it is refused with words (below).
  3. **Only then does the host give it the link**: one message to the port the proven message carried (its receive
     right made by the proven child after its exec, so only that task reads it), holding a send right to the child's
     real bootstrap port (which the child sets back as its own) and the link's end as a fileport (`fileport_makeport`;
     the child's `fileport_makefd`), the host keeping the other end of a pair it made after the proof. No socket end
     is in the child before its proof, so none can be in a session's hands; and a fileport in a Mach message isn't a
     socket in flight, so K-M1 (l)'s end of file doesn't arise. **The server's check of its host** (the Mac spec's
     `NodeCheck.macConnectorRefusal`, which judged the connector pair's token; the proof review's N3): in the Mach
     form the server child judges **the handout's own message**, the one that carries its connector: its trailer's
     token must be its parent's pid running a row's `host`, hardened as step 4 of the interface words it, by the
     kernel's record; a connector from any other sender is destroyed and the server doesn't start
     (`HostChildProofTests.theServerChecksItsHostByTheHandoutsOwnMessage`).

  **Not measured here, owed before K4a-ii is offered** (K-M14, extended again): that the host's own image (Swift and
  Foundation) started with a bootstrap port that isn't launchd's sends nothing to it before its proof (not shown by
  K-M1: the probe received one message per trial in (n5) and (n6) and stopped, so a second would have gone unseen; the
  proof review's N5: K-M14 drains the port until the child exits and counts what came), and how long the bootstrap
  port is the host's; a fileport carried in a Mach message and taken back as a descriptor. **And A for the child** (the
  proof review's I3): code at the launcher path can name handlers and limits for the genuine image it execs, exactly
  as a session can for the host; the child's first statement is the image's, so the clear and the environment rule
  run before its proof, and its offering waits on K-M16's trial part as K4's does.
  
  **Three things the child proof states before it is built** (the re-check's N4, the lead's ruling of 2026-11-27):
  - **(a) What "hardened" is keyed on: the code's own signature, never a flag the caller sets.** The child must be
    hardened exactly when the image itself is: the image reads its own code's flags (`CS_RUNTIME`, no
    `get-task-allow`: `isHardened` on its own token) and requires the same of the child's token. Never an argument
    (not `--parser-test-hooks`, nor any new one), never the environment, never a parcel: a flag is something a session
    passes to a pinned image, which would reopen F1. The same holds for the handover keeper's proof: it requires the
    keeper hardened exactly when the old image is (KP20f's cost). So the host suite's ordinary test hosts, the debug build signed
    without the runtime, keep passing their parsers' proofs (unhardened image, unhardened child), and the keeper
    refuses every pair such an image makes at step 3 anyway (the handover keeper's own `parentRefusal` follows the
    same rule: it requires its parent hardened exactly when it is itself, KP20f's cost); the Mac's own tests that re-sign a copy with `-o runtime`
    (`MacKeeperHandoverTests.swift:18-23`) prove the hardened arm. Test:
    `HostChildProofTests.aChildIsHardenedExactlyWhenTheImageIs` (both arms, no argument or variable read).
  - **(b) The proof's time limit, and the queue it waits off.** The host waits for a child's proof **off its queue**,
    then comes back on the host's queue with the result, as `handOverThroughKeeper` does for the handover keeper's,
    though without its blocking wait on a global-queue thread (sentence 3 below), and **at most 10 s** (`HostChildProof.limit`; the handover keeper's 180 s, `HostHandover.probeLimit`,
    is for a whole new build's start, not a parser's); K-M14 measures the proof's time, and a limit it shows too short
    under load is raised there, never removed. Meanwhile only what needs that child waits: the session start or the
    history read that asked for the parser, or the server child's start; every other session and connection of that
    host is served. At the limit the child is ended and reaped (sentence 2 below) and what needed it is refused with
    the timeout's words (sentence 4 below). So a
    program at the launcher path that never proves itself costs each session start or history read it holds 10 s,
    never the host's queue. Test: `HostChildProofTests.aProofThatNeverComesHoldsNothingElse` (an injected clock and a
    child that never proves: another session's input and a client's request are served meanwhile, and the refusal
    comes at the injected limit).

    **Four more sentences, the narrow re-check's (the lead's ruling of 2026-11-27),** since the wait is not the only
    part of a proof that can hold a queue:
    1. **The spawn runs off the host's queue too.** At `b15e0052` `ParserLink.start` calls `spawn.start()` on its
       caller's queue, the host's (`vibeswitcher.host`, `HostServer.swift:122`) for a session's parser start and for
       `longView` → `HistoryRead.init` (`HostedSession.swift:726`), and `posix_spawn` returns only once the exec's
       image is activated: it reads the file at the launcher path (a file in your folder) and waits for the system's
       look at a new file, which a launcher replaced by a quarantined copy, or by a link to a file on a volume a
       program of yours mounted and then stalled, can hold for a time nothing bounds. So **each spawn runs on a queue of
       its own**, made for that spawn: never the host's queue, never the queue the proof's wait and timer run on
       (sentence 3), never the history read's own queue, which only waits for the result. **The 10 s limit counts
       from the spawn's dispatch**, so a spawn that hasn't returned by the limit is a timeout like a proof that
       didn't come: what needed it is refused with sentence 4's words, and the spawn is left to return; a child it
       then yields is ended and reaped as sentence 2 says, never given anything. Only the result (the proven link, or
       the refusal) comes back to the host's queue. The ruling allows a bound on the spawn instead; `posix_spawn`'s
       own wait has no limit to set, so the bound is on what waits for it, not on the call. The server child's spawn
       runs the same way.
    2. **The reap at the limit is bounded.** A child ended at the limit is ended off the host's queue (`SIGKILL`) and
       reaped by a process-exit source on its pid, as `ServerChild` watches its child, never by a blocking `waitpid`
       with no limit (`MacHandoverKeeper.end`, `MacHandoverKeeper.swift:427-431`, is not the pattern here).
    3. **A proof holds no thread while it waits.** Not one blocking `poll` on `DispatchQueue.global()` per proof (the
       handover keeper's way, which a burst of history reads would multiply until GCD's bounded pool is full and every
       later proof, a switch's keeper start and the server child's restart proof wait for a thread before their own
       10 s begins): the proof's wait is a read source on the channel and a timer on the steady clock, on a queue of
       the proof's own (not the spawn's), holding no thread between events. A spawn blocked inside `posix_spawn`
       holds its thread whatever the design does, so **a host has at most 4 spawns in flight** (the re-check's other
       form, for the spawn alone; K-M14's burst run may raise the number, never remove the cap): past it, a session
       start or history read that needs a parser is refused at once with sentence 4's words, never queued, and a
       spawn left to return after a timeout counts until it returns.
    4. **A proof that only ran out of time accuses nothing.** A child that didn't prove itself within the limit (a
       loaded Mac, the system's first look at a new launcher, a stalled volume, or a program that never proves) gets
       words of its own, never the failed proof's "something on your Mac replaced it": "Your node didn't start a
       helper program it needs, because the helper didn't answer in time. Try again; if it keeps happening, your Mac
       may be very busy, or something is holding the helper's file." Like every refusal a program of yours can cause,
       it never sends you to a password or an install. A proof that came and named other code keeps the failed
       proof's words (below).

    Tests: `HostChildProofTests.aSpawnThatBlocksHoldsNotTheHostsQueue` (a spawn seam that blocks until released: a
    client's request and another session's input are served meanwhile), `.aSpawnThatNeverReturnsIsRefusedAtTheLimit`
    (the same seam never released: the refusal, with the timeout's words, at the injected limit; released later, its
    child is ended and reaped), `.spawnsInFlightAreCapped` (four blocked spawns: the fifth start is refused at once), `.theReapAtTheLimitNeverBlocksTheHost` (a
    child that ignores everything until `SIGKILL`, reaped by its exit source), `.proofsInFlightHoldNoThreadEach` (more
    proofs pending on an injected clock than GCD's pool has threads: a global-queue task still runs at once, and each
    proof is refused at its own limit), `.aProofThatOnlyTimedOutAccusesNothing` (the timeout's words, not the failed
    proof's).
  - **(c) Its cost per session start, measured before it is offered.** The proof adds the kernel's record by the
    token (KA11; Security's dynamic check before the proof review) to every session start and every history read on the Mac (the user's app host included), the launcher
    written afresh at each host start may take amfid's first look at its first exec, and N1's rule adds a read of the
    pins record before each app connection and each server child start in a pinned image. **Not measured: K-M14**,
    a session start, a history read and an app connection, calm and under `scripts/test-under-load.sh`, before and
    after K4a-ii; K4a-ii waits on it before it is offered.
  - **(d) The parser's test hooks** (the proof review's I3). At `7579879b` the parser takes `--parser-test-hooks` from
    its own `argv` in every image (`SessionParser.swift:67`), and the hook's `trap` is a `fatalError`
    (`SessionParser.swift:86`) that any process of your account reaches by writing `ESC ] 7599 ; trap BEL` into that
    session's tty (what is written there is output the host reads and feeds the parser). **The change:** a hardened
    image's parser (its own code's flags, as (a)) refuses `--parser-test-hooks` before its proof (exit 64, nothing
    registered), so the OSC handler for `SessionParser.testHookCode` is **never registered** in a hardened parser and
    those bytes are an OSC nobody handles (SwiftTerm ignores an unregistered code); an unhardened image (the suite's
    debug builds) keeps the hooks, reached only from a test's fake tty; and any other trap a parse of chosen bytes
    reaches goes, after the parser's first statement, to no handler of a session's (the clear): the parser ends and
    the host sees its link close. Tests: `HostChildProofTests.aHardenedParserRefusesItsTestHooks`,
    `.aTrapHookWrittenToTheTtyIsIgnoredInAHardenedParser` (the bytes written on a hardened scratch host's session tty:
    the parser keeps parsing, the session's next output still reaches the view).

  **The handover keeper (`MacHandoverKeeper`, built on the Mac line), under the Mach form.** Read at this branch's
  base (`Sources/VibeHost/V2/MacHandoverKeeper.swift`): each of its four proofs is a pair made by the process proving
  itself, judged by `peerToken` (the keeper in `start`, `:120`; the host in `keepIfAsked`, `:212`; the new image in
  `keepIfAsked`, `:221`; the keeper again in `take`, `:287`), and its header says the token is "fixed at its making". **Its keeper side is open today to K-M1 (b) with the
  pid matching:** code at the target build's path when `start` spawns it (a file in your builds folder) makes the pair,
  sends its end over the channel, forks a holder of its own end, and execs a copy of the genuine target; the host's
  `refusal` then finds the spawned pid running the target's cdhash, hardened, and `park` gives the holder the parcel's
  pair, then the state and every descriptor it names (the lock, the listener, the secrets channel's reading end, each
  session's terminal). The same order works on the new image's side: code exec'd in place at the host's pid proves to
  the keeper, then execs the genuine target, and its holder takes the parcel (`:221-236`). Its "What stays" sentence
  ("it gets nothing") doesn't hold. It is reached only by a checked node's switch and a scratch host's (the Mac app's
  host switches by path), and the checked node stays off (`isCheckedMacNode`). **What must change, slice K4c** (its own
  review; the brief's "later slice"; it changes no keeper code and waits on nothing but its own measurement):
  - `start`: the keeper spawned with the old host's port as its bootstrap special port (no `--handover-keeper FD`); its
    proof a Mach message from its own code carrying a port it made; `refusal` on that message's trailer (the spawned
    pid, the target's cdhash, hardened exactly when the old image is).
  - `park`: the state in a Mach message to the proven keeper's own port, its descriptors as fileports; the keeper's
    `parentRefusal` judges **that message's own trailer** (its parent's pid; for a checked node, a host the record
    pins; hardened exactly when the keeper is), so the parent is proven by the message that carries the parcel.
  - the in-place exec: the old host sets its bootstrap special port to a send right for the keeper's port just before
    it (special ports cross an exec, K-M1 (n5)), in place of `--handover-keeper-channel FD`; the new image's `take`
    sends one proof message with a port it made; the keeper requires its trailer to be the host's pid running its own
    code, hardened, and answers on that port with the state (fileports) and the real bootstrap port, which the new
    image sets back; the new image requires the answer's trailer to be the keeper's pid, its own code, hardened.
  - `peerToken` is never asked; `limitIO`'s socket limits become `mach_msg` timeouts; the `holding` byte, there for
    K-M1 (l)'s end of file, isn't needed for fileports; the header's token paragraph and "What stays" are struck.
  - **The proof review's I3 and D7:** the handover keeper and the new image run the image's first statement (the
    clear, then the environment rule: the keeper, finding a variable outside its list `PATH=/usr/bin:/bin`, `HOME`,
    `TMPDIR`, `LANG`, execs itself again once with exactly it, so a switch from an older build still works; the old
    host spawns its keeper with exactly the list; the new image is a checked start, under its own rule) before any
    proof; **each
    proof names its role** (`handoverKeeper` for the keeper's proof to `start`, `newImage` for `take`'s, beside K4a-ii's
    `parser` and `server`), and each receiver takes a proof only for its own role and only its own handout's exact
    form: `start` refuses a `parser` proof from the spawned pid (code at the target path that execs the genuine
    target as `--parse-session` proves itself as a parser, and gets no parcel), and a parser that receives a parcel
    destroys it, since it takes only a link. **Today's other modes have no other sink**, read at `7579879b`: the
    parser writes only to its link; a checked node's parcel is taken only by a checked start
    (`HostImages.mayTakeHandover`, `main.swift:233`, `:250`); K4c states it with a test. Offered after K-M16's trial
    part, as K4.
  - Tests: `MacKeeperHandoverTests` unchanged in what they see (unhardened scratch hosts, KP20f's cost);
    `MacHandoverKeeperProofTests.codeAtTheTargetPathThatExecsTheTargetGetsNoParcel` (a scratch program at the target
    path sends, forks a holder, execs the genuine target: nothing reaches the holder; the switch refuses or the
    target's own proof takes it), `.aNewImageProofSentBeforeAnExecIsRefused`,
    `.theParentIsProvenByTheParcelsOwnMessage`, `.aParserProofGetsNoParcel` (the genuine target exec'd as
    `--parse-session` by code at the target path: its proof is a parser's, `start` refuses it, nothing parked),
    `.aParserTakesNoParcel` (a parcel sent to a proven parser's port is destroyed, nothing written on any of its
    descriptors), `.onlyACheckedStartTakesACheckedNodesParcel`.

  **The pair call sites below, under the Mach form**, are the host's own table, not the keeper's: a class wrong here
  exposes the host's data, never a keeper request. Each proof becomes a Mach message and each handout a fileport to a
  proven port, so the fourth class ("a channel or a proof pair") and `HandshakeEnd` go with the socket proofs: the rows
  `SessionParser.swift:262` and `AppConnector.swift:123` read "after K4a-ii: the proof a Mach message, the link or the
  connector a fileport to the proven port", and `MacHandoverKeeper.swift:96`, `:141`, `:200`, `:227`, `:276` read
  "after K4c: no pair; Mach messages and fileports"; `KeeperLintTests.everyChannelAndProofPairIsAHandshakeEnd` is
  replaced by `KeeperLintTests.noProofAsksASocketsToken` (no `peerToken` or `LOCAL_PEERTOKEN` in the image's or the
  keeper's sources outside the corrected `Sockets+Darwin.swift`, whose comment says what K-M1 measured).

  **The image's pairs, every call site at `b15e0052`, and their class after K4a** (K4's lint,
  `KeeperLintTests.everyPairTheHostImageMakesIsClassified`, holds this list, so a new call fails until it is
  classified; the classes are the review's three, **kept**, **given only to proven code** and **seqpacket**, with a
  fourth added here, **a channel or a proof pair**, on which the image writes only the handshake's fixed bytes; in a
  pinned image, "proven code" is only what the next rule allows: its own, its row's server, or across the checked
  switch a target host the same record pins). **The fourth class's property is held by a type, not by the lint** (the
  re-check's answer to its question 4: a lint that classifies `pair` call sites can't show that nothing else ever
  writes on those descriptors): `HandshakeEnd`, which K4a-ii adds beside `MacHandoverKeeper`, owns each channel's and
  each proof pair's end and exposes it only through `sayHolding` (`holding`, `0x67`) and `sendDescriptor` (`d`,
  `0x64`, with its one `SCM_RIGHTS`), with the waits that read them, never as a raw descriptor; any other fixed byte a
  handshake needs is a method of the type too. The lint then checks that every channel and proof pair is made through
  `HandshakeEnd` (`KeeperLintTests.everyChannelAndProofPairIsAHandshakeEnd`). No alignment of `0x64` and `0x67` forms
  the 8-byte `vskeep1\n` prefix, and the `d` byte carries control data, which step 4 refuses on the pair anyway:

  | Call site | The pair | Where its ends go | Class |
  | --- | --- | --- | --- |
  | `SessionParser.swift:262` | the parser link (stream) | today the launcher's descriptor 0, unproven (KP20a) | after K4a: a channel, then the link given only to the proven parser |
  | `AppConnector.swift:123` | the server child's connector (`connectorType`, a **stream** on the Mac: `SocketDescriptors+Darwin.swift:11`) | today kept across the server child's spawn from its `--server` path, checked by cdhash before the spawn and named after it (`ServerChild.swift:549-582`), so a file swapped between the check and the spawn holds it unproven; and in a host a session starts, `--server` is the session's own file (the re-check's N1) | after K4a: a channel, then the connector given only to the proven server child, which in a pinned image must run its row's server (N1's rule) |
  | `AppConnector.swift:286` | one per app connection (stream) | one end sent over the connector, in answer to a request whose sender Security checked (`setAppConnectorChild`) | given only to proven code whose own spawns close what they don't name, once the connector is proven and the server's spawns name what they keep (K4a); in a pinned image only to a server child running its row's server, checked against the record read afresh at each connection (N1) |
  | `HostHandover.swift:315` | the secrets' channel (stream; the host writes the secrets, then closes its writer) | the reading end parked with the proven handover keeper (`MacHandoverSwitch.swift:91`), which gives it only to the new image it proved; in a host a session starts, `--handover-test-keeper` names that keeper's code and `--handover-test-secret` the bytes (the re-check's N1, its second leg) | given only to proven code; in a pinned image only across the checked node's own switch, to a target host the same record pins (N1's one extension); the test flags and the by-path handover refused in a pinned image; in a hardened image not pinned (the Mac app's own host) the by-path handover **kept** (KP20f, settled: the keeper takes no socket end, so this end carries no request); the handover keeper's parking in the Mach form (K4c) |
  | `MacHandoverKeeper.swift:96` | the handover keeper's channel | the keeper child's descriptor before its proof | a channel |
  | `MacHandoverKeeper.swift:141` | the parcel's pair (`park`) | one end sent over the proven keeper's pair | given only to proven code; in a pinned image, as the secrets' channel (N1's one extension) |
  | `MacHandoverKeeper.swift:200` | the keeper mode's proof pair | one end sent over its inherited channel | a proof pair |
  | `MacHandoverKeeper.swift:227` | the keeper mode's pair to the new image | one end sent over the new image's proven pair | given only to proven code |
  | `MacHandoverKeeper.swift:276` | the new image's proof pair (`take`) | one end sent over its inherited channel | a proof pair |
  | `EgressChild.swift:95` | the egress proxy's control pair (`seqpacket`) | the proxy child | seqpacket: on the Mac `pair` of that type fails (`EPROTONOSUPPORT`, `SocketMaking.swift:3-5`), so it is never made there, and the keeper takes only `SOCK_STREAM` ends anyway |
  | `NodeAnchor` (new, K4) | none: the keeper's client sends Mach messages and makes no pair | — | — |

  **A parser or server child that fails its proof** (its proof came and named other code; one that only ran out of
  time gets N4 (b)'s timeout words, sentence 4, which accuse nothing) is a refusal the user can meet: the session doesn't start, or its
  history isn't read, or the server isn't started, with words in `status` and the session's own line: "Your node
  didn't start a helper program it needs, because the file in that helper's place isn't your node's own code:
  something on your Mac replaced it. Restart your node (`vibeswitcher stop`, then `vibeswitcher start`), which puts
  its own copy back. If it happens again, a program running as you is doing it." A program of yours can cause this at
  will, so the words never send you to a password or an install (the rule of [While the keeper is
  down](#while-the-node-is-down-and-while-the-keeper-is-down)); for the restart to put the copy back, K4a has the host
  write its launcher afresh at each start (a new file renamed over the old), never keeping one it finds because its
  modification time matches. K4a's tests:
  `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`,
  `.aLauncherThatExecsTheImageAfterItsProofGetsNoLink`, `.aProofSentBeforeAnExecIsRefused` (K4a-ii's row).
  F1's (c), the request's own half-close as a second barrier, is **gone** with the socket proof: the keeper reads no
  socket end, and no token is read again.
- **A pinned host image never gives an end of a pair it writes on to code other than its own or its row's pinned
  server, in any mode; the one extension is the checked node's own switch; and a hardened image not yet pinned gives
  none outside its own code** (the re-check's N1, the lead's ruling of
  2026-11-27; KP20d, KP20e). K4a's proof shows that a child runs the code the host expected; this rule fixes what a
  pinned image may expect, since in a host a session starts the session chooses it. Read at `b15e0052`, two legs:
  - **The server child.** A session runs the pinned image from the node's builds folder (your files) as a scratch host,
    its own `--lock` and `--socket`, with `--server` naming a program of its own signed ad hoc with the Hardened
    Runtime. `HostImages.macServerRefusal` refuses a server child only on the account's own locks
    (`HostImages.swift:558-574`), so the scratch host starts that program (`ServerChild.swift:549-582`) and, with
    K4a alone, proves it against that same file's cdhash and gives it the connector; each request it sends then gets
    an app connection, a pair the genuine, pinned, hardened host made, the host serving its client protocol on the
    other end (`AppConnector.swift:286-305`), and it sends its end to the keeper.
  - **The test keeper.** On the Mac every host takes test flags (`HostHardening.takesTestFlags`,
    `HostHardening.swift:208`), so `--handover-test-keeper <a cdhash of the session's>` makes the session's program
    the switch's "proven" handover keeper (`main.swift:138-142`, `MacHandoverSwitch.swift:36-40`) and
    `--handover-test-secret <bytes>` makes the session's bytes the secret (`main.swift:299-301`); `park` sends that
    keeper the secrets channel's reading end (`MacHandoverKeeper.swift:148`, `HostHandover.swift:98`), half of a pair
    the genuine host made, holding exactly the session's bytes and then the end of file.

  What stood between either leg and a served request was only the host's bytes on its end and step 5's refusal of a
  closed other end (F1 (c), on K-M1 (e)), which this design doesn't count as a barrier. **The rule, part of K4a-ii:**
  1. **Pinned, read as the keeper reads it.** An image is pinned when it runs hardened (its own code's flags) and its
     own cdhash (`Platform.CodeIdentity.ownCdhash`) is the `host` of a row of the account's pins record, read through
     `NodePins.read` (the walk from `/`, the record's fixed path, `Platform.Service.nodePinsRecord`): nothing from its
     arguments, its environment or a parcel. It reads the record **afresh before each handout**: each server child
     start, each app connection, each switch, since an install can pin a running image's cdhash. No record
     (`ENOENT`) is "not pinned", and the keeper then serves nothing either; any other failure to read it (N3's split:
     a record read whole and refused, or a read error) refuses the handout, never reads as "not pinned".
  2. **What a pinned image gives ends to.** A parser: its own cdhash (K4a, in every image). The server child: its own
     row's `server`, in every mode; a `--server` file whose cdhash isn't that is refused before the spawn, and the
     proof requires the row's cdhash, not the file's. An app connection: only to a server child proven against its
     row's server at its start and found still its row's in the record read afresh; an image pinned since its server
     child started against another server ends that child and refuses the connection, with words.
  3. **The one extension: the checked node's own switch.** The parcel's pair and the secrets channel's reading end go
     to the handover keeper, which is started from the target build's path and proven by its token to run the
     target's cdhash; that cdhash is the `host` of a row of the same record, with that row's server checked
     (`keeperTarget`, `MacHandoverSwitch.swift:12-40`: a checked node host's alone). The handover keeper gives the
     secrets end only to the new image it proved, at that same cdhash. **Both rows' commits, this image's and the
     target's, contain K4a-ii** (N2 and the narrow re-check's KP6b: every row of a format-2 record does, [Install,
     update and removal](#install-update-and-removal), "Rows a format-2 record can hold"), and the target is itself a pinned image
     under this rule. Code the keeper would serve anyway gets nothing it couldn't ask the keeper for.
  4. **In the modes a session starts, a pinned image refuses:** a `--server` whose cdhash isn't its row's server;
     `--handover-test-keeper` and `--handover-test-secret` (at its start, exit 64 with words, and again at a switch,
     since it may be pinned since its start); and the Mac's by-path handover (`HostServer.swift:886-903`), which hands
     the secrets channel to an unproven target. So **in a pinned image's non-checked modes every switch form is
     refused**, and it switches only through the checked node's switch.
  5. **Images that aren't pinned:** an unhardened one (the test suite's debug builds) keeps its modes and flags, and
     the keeper refuses its every pair (step 3); **a hardened one** (a build before its pins step, a copy of one) **starts
     no server child and takes no test keeper or test secret**, as below (KP20f), and **keeps its by-path
     handover** (KP20f, settled under the Mach form, below). The keeper serves none of them (KP6: host rows only).

  **An image pinned while it runs, and why the rule is keyed on "hardened"** (this round's blind check; KP20f; the
  lead's choice (A), 2026-11-27). Keyed on "pinned" alone, the rule left one path: an end handed out before the image
  was pinned isn't revoked. During an install or update you run, the new build is signed in the builds folder (yours),
  its cdhashes read, and the pins step then waits for your password (`install-node-mac.sh:614-621`; the keeper's
  setup, whose `--fresh` pins the build being installed, alike). A session that ran that genuine build in the window as
  a scratch host, with `--server` naming a hardened program of its own, would get its server child proven against its
  own file, the connector and an app connection per request; once you typed the password, an end it already held
  would be a live, pinned, hardened maker's, its other end open (under the pair proof; under the Mach form that end
  carries nothing to the keeper, below). **So the rule is keyed on "hardened":** the keeper refuses every unhardened
  sender (step 4), so only hardened images matter, and **a hardened image that isn't pinned
  starts no server child and takes no `--handover-test-keeper` or `--handover-test-secret`** (exit 64 at its start,
  or a refusal at the act, with words), the record read as in 1 before each. Unhardened images (the test suite's debug
  builds) keep their modes and flags.

  **KP20f's by-path point, settled under the Mach form** (this task; the lead's constraint of 2026-11-27 kept). The
  keeper takes no socket end: it reads Mach messages alone, each judged by its own trailer (the interface's step 4).
  So no end a host hands out, before its pinning or after, by path or through a proven keeper, can carry a request in
  any image's name: **the by-path end is worthless to the keeper by the proof itself**, not by the exec in place that
  the narrow re-check leaned on (K-M1 refuted that ground: a pair's token read after the maker's exec names the exec'd
  image, (b), (c), (g1)). **The by-path handover of a hardened image that isn't pinned is kept**, and **the Mac app's own
  host (hardened, never pinned) keeps its handover at every app update**, with or without a node installed: its
  `vibeswitcher-host` is hardened (`scripts/build-app.sh:239`, `--options runtime`; entitlements `audio-input` alone,
  `Resources/VibeSwitcherHost.entitlements`) and no row of the node's record, `keeperTarget` is nil for it
  (`MacHandoverSwitch.swift:8-10`, `:36`), so `handOver(to:)` takes the by-path form (`HostServer.swift:862-905`), and
  nothing here refuses it. **Its test** (K4a-ii's): `HostChildProofTests.theAppsHostStillHandsOverByPathAtAnAppUpdate`
  (a hardened scratch copy that no record pins, started as the app starts its host, hands over by path to another
  hardened copy, and its sessions survive), with the app's update checked in the sandbox. What the by-path form still
  exposes is the app's own vault (main's `lead-vault`) to whatever runs at the path after the exec in place, as today:
  never the node's record, which an unpinned image never holds (the keeper serves host rows only, KP6). A pinned image
  still refuses the by-path form (rule 4). Kept from the re-check, neither resting on the token: **no exemption keyed
  on `ownsLaunchers`**, here or anywhere in this design (on the Mac it follows the lock's path against
  `VIBESWITCHER_HOME`, `main.swift:73-78`, which a session sets for a host it starts); and `parentRefusal`'s hardened
  check "exactly when" (next paragraph). **The lead's choice (A) stands as ruled** (a hardened image that isn't pinned
  starts no server child and takes no test keeper or secret); under the Mach form it no longer keeps a request from
  the keeper (an end handed out before a pinning carries none), and it still keeps such an image's connector and
  parcel from code a session named, the host's own data: for the lead to keep or revisit.

  **Its cost, stated:** the Mac app's own host keeps its sessions at every app update through the by-path handover,
  which stays (above). The Mac's own
  tests that re-sign a copy with `-o runtime` and start it as a scratch host with
  `--server` and `--handover-test-keeper` (`MacKeeperHandoverTests.swift:20`, `:93-133`) lose that hardened arm on this
  Mac without `sudo`. The switch's logic (the path check, the swaps after the check and before the exec, the keeper's
  limit, a server child ended and started again) is tested on **unhardened** scratch hosts, since N4 (a)'s "hardened
  exactly when the image is" extends to the handover keeper's proof, **in both of its hardened checks**:
  `MacHandoverKeeper.refusal`'s (the old image requires the keeper hardened exactly when the old image is) and
  `parentRefusal`'s (`MacHandoverKeeper.swift:173`: the keeper requires its parent hardened exactly when the keeper
  itself is, not always), so an unhardened old host's unhardened keeper takes it and those tests can run; a hardened
  keeper still requires a hardened parent, so this opens nothing (K4a-ii's test
  `HostChildProofTests.aHandoverKeeperRequiresItsParentHardenedExactlyWhenItIs`). The hardened arm moves **to function level**, with
  the record injected as `keeperTarget`'s tests inject it and this Mac's real hardened images and tokens, and **to
  K7**. **What this Mac no longer runs end to end until K7:** a hardened host's switch through a proven handover
  keeper to a hardened target, with a hardened server child ended and started again, under real tokens (the
  hardened half of `MacKeeperHandoverTests`), since only the real record can pin a build and the image takes no record
  path. K7's list carries it: the first update after the setup pins two real builds, and the switch between them is
  run and watched end to end at your keyboard.

  **Considered and rejected, (B): the keeper serves a maker only if its process started after its row was written**
  (each row carrying root's write time; the start from `proc_pidinfo` against the token's pidversion). Rejected
  because the checked node's switch execs the new image in place (`MacHandoverSwitch.swift:108`): the new image runs
  in a process that started before its row, so the keeper would refuse the node after every update. macOS gives a
  process's start, not its exec, so (B) would need the switch itself changed.

  The words, for a server child refused: "Your node didn't start its server, because the program named as its
  server isn't the one your install lists for this build." For a test flag: "This build of your node is installed,
  so it doesn't take test flags." For a switch: "This build of your node is installed, so it switches only as your
  node." A program of yours causes each at will, so none mentions a password or an install. Tests (K4a-ii), with the
  record injected at function level as `keeperTarget`'s tests inject it (`pins:`) and the image's own cdhash and
  hardened flags this Mac's real signed hardened images' (as `MacKeeperHandoverTests`); the program takes no record
  path, and the real record's arm is K7's: `HostChildProofTests.aPinnedImageGivesNoPairEndToCodeASessionNamed` (the
  server child leg: a scratch host of a pinned image with `--server` naming other code starts no server child and
  gives no connector and no app connection), `.aPinnedImageRefusesTheTestKeeperAndItsSecret` (the
  `--handover-test-keeper` leg: refused at the start and at a switch, nothing parked),
  `.aPinnedImageRefusesTheByPathHandover`, `.anImagePinnedWhileRunningGivesNoConnectionToAServerItsRowDoesntPin`,
  `.aPinsReadThatFailsRefusesTheHandout`, `.theCheckedSwitchGivesItsEndsOnlyToATargetTheRecordPins` (the extension: a
  target that is no row's host, or whose row's server isn't the build's, gets no parcel and no secrets end).
- **Its send has its own deadline** (the review's F9, in the Mach form): each request sent with a `mach_msg` timeout
  against the request's own limit and its reply awaited the same way, a pause of 250 ms between tries (never a loop
  that spins), and the start's 60 s counted on the steady clock across tries, so a full queue that makes a send wait,
  or one that fails it at once (which of the two: K-M10 (c) on the port), costs the host at most its limit and no
  core. K6's look uses the same send with a limit of 2 s. Tests: `NodeAnchorTests.aFullQueueCostsTheStartItsLimitOnly`,
  `.aRefusedSendIsTriedAgainAfterAPause` (an injected clock and port).
- **The answer's read-back.** A swap whose connection dropped before its answer was read is read back with `open`: the
  slot equal to `new` is a raise that succeeded; equal to `expected`, one that failed (tried again at the next append);
  anything else, `moved` (journal "One writer" 4: the host writes nothing more, `lock.lost`).
- **The order at the host's start**: the lock (journal "One writer" 1), then `open` (the key and both slots), then the
  file, open, parse, then the counter compared with the `journal` slot. A host that holds the lock but can't get the
  key reads no file, sets nothing aside and exits (K8's set-aside runs only once a key was obtained from the keeper
  and the file failed to open with it: otherwise a flood at a restart would make the node set its own record aside).

## While the node is down, and while the keeper is down

**While the node is down** the keeper does nothing: it holds its store and answers only accepted messages. It doesn't
notice the node's absence, restart it or record it. (A count of key fetches in the keeper would show a host that ran
and sealed nothing between your stop and your start, the journal's P39; not taken: [Doubts](#open-doubts) 9.)

**Under the Mach form** (the proof after K-M1; the proof review's D5), the states the host and K6 tell are these, and
the table below is written in them. There is no listener: the host looks the keeper's name up and sends `open` with
its own deadline, so what it can see is a reply or none. With `MachServices`, launchd keeps the keeper's port and
queues sends while the daemon is down or between its instances (assumed, K-M15), so **a keeper that is busy and one
that isn't running look the same** (no reply within the limit): they are **one state, "installed, not answering"**,
with the merged words below (the second fix round's, kept for this). The host can tell one more: **"something of your
account answers in the keeper's name"**, a reply that came and isn't from root running the cdhash in the node's
`installed`, naming this uid and `node` (step 2): a LaunchAgent declaring the service in your own domain, if K-M15
finds it answered before the daemon, would give it at every login, an at-will denial that survives restarts. Its words
are its own, never the password or an install. "The proof's 1 s and the request's 2 s" are the sender's own
`mach_msg` timeout, since a message arrives whole; what a flood costs the keeper is one receive and, for a message of
the exact form, the kernel's record by its token and a walk of the pins record (K-M10).

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
keeper's plist and program are root's files in root's folders (KP7a), so their **absence**, found by the root walk as
`ENOENT` alone, is such a fact, and so is a **`damaged`** store (root's file in root's `0700` folder, which nothing of
yours can write, read whole and refused); a walk or a read that fails any other way is neither (N3's split, [What it
stores](#what-it-stores-and-where)), and has words like "busy". These two alone point to the keeper's setup line
(`--install`, or `--start-over` for `damaged`); a `noRecord` that is the pins record missing or read whole and refused
keeps the checked start's words (an install of a newer commit), root's file too. A keeper **installed, not answering**
(busy or not running: one state under the Mach form, above) or **something of your account answering in its name** can
be a program of yours at work (a flood, KP19; Login Items, K-M12; a LaunchAgent of its own, K-M15), so their words
never mention the password, the setup line or an install: a session would otherwise choose the moment you type your
password. K6's `start` and `status` look themselves, in that order: the plist and the program (walked from `/`, root's
alone; `ENOENT` alone is "not installed", any other failure a read error, worded as in the table), then the keeper's
name looked up and an `open` sent with a 2 s deadline (F9's): the command line is no pinned host, so a keeper that
answers sends it a refusal (`notPinned`), and a refusal whose trailer names root running the cdhash in the node's
`installed`, naming this uid and `node`, is "running"; no reply within 2 s is "installed, not answering"; a reply from
anything else is "something answers in its name". The merged state's words: "Your node's keeper isn't answering, so
your node can't start: either a program on your Mac keeps it busy, or it keeps stopping. Installing the keeper again
won't help. Try `vibeswitcher start` in a minute; if it goes on, restart your Mac." (still no password, and no claim
about login items: a keeper that crashes at every start, a bug or launchd's throttle, gives this state after a restart
too: the re-check's N6).

| When | What the node does | Its words | The way out |
| --- | --- | --- | --- |
| **At the host's start, the keeper not installed** (no plist or no program in root's folders) | the host exits 78 (`notStarted`) at once, having read no secret and written nothing; no host runs without its record, so the journal's start-time `noKeychain` reason doesn't arise | "Your node's keeper isn't installed, so your node can't start. Run the keeper's setup line (it asks your password)." | the keeper step's `--install` |
| **At the host's start, the keeper installed, not answering** (busy or not running, one state under the Mach form: no reply within the limit; a flood, a crash and launchd's throttle, an update, or the keeper switched off) | the host holds its lock, reads no file and asks again as F9's loop allows, up to 60 s (the start's limit, on the steady clock; a test's injected one); then exits 78 | "Your node's keeper isn't answering, so your node can't start: either a program on your Mac keeps it busy, or it keeps stopping. Installing the keeper again won't help. Try `vibeswitcher start` in a minute; if it goes on, restart your Mac." No login-item sentence (the re-check's N6: a keeper that crashes at every start gives this state too); if K-M12 shows your account can switch the keeper off, K6's `status` lists Login Items among the places to look, as a possibility, never as the cause | the flood ending, or macOS starting it (at boot, or launchd's restart after a crash), then `vibeswitcher start` |
| **At the host's start, something of your account answers in the keeper's name** (a reply that isn't from root running the cdhash in the node's `installed`, or names another uid or store: a service of the same name in your own domain, D5) | the host sends that port nothing more, reads no file, asks again as F9's loop allows (a launchd lookup may find the daemon next), up to 60 s, then exits 78 | "Something running as you answers in your node's keeper's place, so your node can't start. Installing the keeper again won't help. Find what you didn't set up among the programs that start when you log in (System Settings › General › Login Items), stop it, then restart your Mac." Never the password | that program stopped, then a restart and `vibeswitcher start` |
| **At the host's start, a read error** (`readError`, from the store or the pins record; or K6's walk failing other than `ENOENT`) | as for busy: asked again as F9's loop allows, up to 60 s, then exit 78 | "Your node's keeper couldn't read its files just now, so your node can't start. Installing the keeper again won't help. Try `vibeswitcher start` in a minute; if it goes on, restart your Mac." Never the password, the setup line or an install | the read succeeding, then `vibeswitcher start` |
| **At the host's start, the keeper refused or damaged** (`noRecord`, `notPinned`, `notHardened`, `wrongUid`, `damaged`: each a file read whole and refused, or missing) | the same exit, at once: waiting changes nothing | for `damaged` (root's store, which nothing of yours can damage): "Your node's keeper can't read its store. Run the keeper's setup line with --start-over (it asks your password); your node's record then begins again." For the others, the checked start's own words (the record names no such build: the Mac spec's remedy, an install of a newer commit, through root's own pins record, which nothing of yours can change) | `damaged`: your `sudo` line; nothing deletes the store by itself (the decided (3)'s principle, below) |
| **While the host runs, no answer** (not answering, something answering in its name, `unwritable`, or `readError`) | the journal's failed-raise rule (its "When a raise fails", I2), keyed on the keeper instead of the keychain: a guarded act acts only once its entry is counted (`recordUncounted` otherwise); the raise tried again at each later append and at the host's end; one open `record.begins` with `reason: noKeeper` per run of failed raises; revocations and the acknowledgement still taken; a device's removal refused and retried by itself; the file sealed meanwhile runs ahead (`ahead` at a restart before a raise succeeds) | "Your node can't keep its record right now: its keeper isn't answering. Try again in a minute; if it goes on, restart your Mac." For a removal: "Your node can't remove a device while its keeper isn't answering. Lock the device now, which always works and ends what it can do; it will be removed once the keeper answers." Never the password | the keeper back (launchd restarts it; an update takes seconds) |
| **While the host runs, a refusal** (`notPinned`: a pinned older build running when you ran `--keep 1`, P41; `noRecord`; `damaged`; `notHardened`; `wrongUid`) | the same failed-raise rule (nothing guarded acts uncounted) | **the start's words for that status** (the review's F14), never "isn't answering": e.g. `notPinned`, "Your node is running a build its install no longer lists, so it can't keep its record. Stop it and start your node again (`vibeswitcher stop`, then `start`), which starts the build your install lists." | as at the start, for that status |

A process of your account **can't stop the keeper** (only root can stop, unload or signal a root daemon: K-M9; and
whether macOS's Login Items list lets your account switch a LaunchDaemon off, the review's F10, is K-M12: if it does,
that is one more at-will denial, KP18a, with the words above), and can't take its port (the system domain's, root's),
**but it can keep it busy**, which is the same to the node as the keeper being down: each message holds the serial
keeper for one receive and, for one of the exact form, the kernel's record and a pins walk (no file of the sender's
read: D1), and a flood fills the port's queue (whether a full queue makes a send wait or fail: K-M10 (c), K-M15). So,
at will and for as long as it keeps at it, a program of yours can:

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

What a flood costs the keeper: one receive and, for a message of the exact form, the kernel's record by its token
(two calls, no file opened: K-M16 here, (d1)) and a walk of the pins record, per message (CPU, measured in K-M10);
its ports and memory stay bounded since every message it refuses is destroyed with what it brought (F7's rule in
Mach's form; an oversize one by the kernel, N4). The node's own words never route you to the install's window from a
flood (F4, above).

Each fails closed and shows (a refusal with its words, an open entry); none is a change taken unseen. These are the
journal design's stated limits as they were with the locked keychain: the keeper doesn't close them, it changes
their lever. A keeper that serves messages side by side (threads, a bounded table) would make a flood cost more
without ending it (a program of yours can always send faster than one keeper serves): not taken,
[Doubts](#open-doubts) 5. The keeper's memory and ports stay bounded under a flood (nothing is kept per message
beyond the one being served, the port's fixed queue): **not measured**, K-M10.

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
     refused), and writes those files out into `build/src/`. The tool is root's own `git` (`index-pack --strict`, then
     `archive`), run only in that repository, with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null` and no
     template's hooks; if it refuses a pack whose commit's parents and top tree's other entries are absent, `STAGED`
     is the commit's whole history as a bundle (K-M13). **There is no other reader** (the re-check's answer to its
     question 1): a reader in the root half's text could only recompute hashes, never detect a collision attack. The
     objects' hashes are all that ties them to `COMMIT` ([Doubts](#open-doubts) 14), so root's `git` must detect a
     SHA-1 collision attack (git's `sha1dc`), which K-M13 measures with the exact `git` root runs under `env -i`: its
     `git version --build-options` names its SHA-1 backend, and its `index-pack --strict` refuses a published colliding
     pair. **If it doesn't detect, the step refuses**, installing nothing: "Your Mac's git can't detect a forged
     commit, so your node's keeper wasn't installed. Nothing was changed." K5's real use then waits; nothing falls
     back.
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

**Only builds at or after the floor are ever served** (the re-check's N2, the lead's ruling of 2026-11-27; KP6b). An
install at a commit before K4a writes the real record (`install-node-mac.sh` passes no `--record`, so
`node-pins-mac.sh` writes `/Library/Application Support/VibeSwitcher/node-<uid>.pins`: `install-node-mac.sh:619-621`,
`node-pins-mac.sh:80-82`) and carries every earlier row forward. Such a build still has the parser launcher checked by
its modification time, no child proof, spawns without `CLOEXEC_DEFAULT` and no N1 rule, so a session that starts it in
any mode holds the parser link's end: the review's F1, whole. The keeper serves every host row of the record, so three
rules keep those rows out of its service:

1. **The setup keeps only the build it installs.** The keeper's setup comes with an install of a commit at or after
   K5 (installing a commit already installed is refused, so it is the first such install, or a later one of a newer
   commit). The install that sets the keeper up (no `installed` yet) runs the
   pins step in its existing `--build COMMIT HOST SERVER CLI --fresh` form, within the pins step's own one `sudo`: the
   record it writes holds only this build's row, **the same record `--keep 1` leaves just after**, with no third
   password. Said before the password: "Older builds of your node are dropped, so only this build is served."
2. **The floor, in the install, from K4b's own commit on** (the narrow re-check of 2026-11-27, KP6b, the lead's
   ruling). **K4b's install script itself refuses, unconditionally** (a keeper installed or not, at any install or
   update), **a commit that doesn't contain K4a-ii's commit on v2**: `git merge-base --is-ancestor <K4a-ii's commit>
   <commit>` in its fresh fetch, beside step 6's check that the commit is on v2, with the words "This commit of your
   node is older than its keeper allows: it lacks a fix the keeper needs. Nothing was installed. Install a newer
   commit." **The floor is K4a-ii's commit**, an ancestor K4b can name (K4a-ii is on v2 before K4b is written; a
   commit can't name itself); **K5 raises it to K4b's commit** (the lead's ruling of 2026-11-27: a rollback to a commit between K4a-ii and K4b on a format-2 record leaves the node not starting). So **the floor check lands in the same commit
   as the format's bump** (rule 3): every install script whose pins step writes `format 2` refuses a commit without
   K4a-ii. Why it can't wait for K5, as the second fix round had it: an install runs the **installed build's** copy
   of the script and its pins step, for whatever commit it installs (`install-node-mac.sh` step 5:
   `expected=${current_commit:-$commit}`, `:362`; the pins step is `expected`'s blob, `:383-386`, run at `:621`), so a
   script from K4b's commit up to K5's, with a format-2 pins step and no floor check, installed after the keeper's
   setup (a rollback to K4b's commit is enough; or `current` pointed at a folder a program of yours made from such a
   commit's public files, which step 3 and step 5 accept, `:310-324`), would install a pre-floor commit into the
   format-2 record, and the keeper would serve its row (KP6c). With the check in K4b's commit, every update runs a
   script that checks the floor or a pins step that refuses the record (rule 3), an update to an older commit
   included.
3. **The record's format is 2 from K4b's commit on.** K4b's `NodePins` reads only `format 2`, and its pins step
   writes only `format 2`: a record it finds in format 1 isn't carried (its rows are builds from before K4b), so its
   first write keeps only the build it installs, said before the password as in rule 1. The keeper is built from a
   commit at or after K4b (K5 waits on K4b) and reads only `format 2`. A commit before K4b has a pins step that parses
   only `format 1`, so its `--build` form, the only form an install passes, refuses a format-2 record whole (exit 65,
   "a line this step doesn't write") and installs nothing; its `--fresh` form, run by hand with your password, would
   write a format-1 record, which the keeper refuses (below). **This closes what rule 2 alone
   can't:** a first-form install of a pre-floor commit (the builds folder's `current` deleted, which a program of
   yours can do, so the install runs that old commit's own script, which has no floor check) writes no row the keeper
   serves. Were the record gone (only root can remove it) and an old step wrote a format-1 record, the keeper and every
   build from K4b on refuse it (`noRecord`: the node doesn't start, fail closed). The record has one path per account
   (and the trial's, which only a trial keeper reads), so no old-format record can stand beside it.

**Rows a format-2 record can hold.** With rules 2 and 3 together, every install script whose pins step writes
`format 2` refuses a commit without K4a-ii, and every older script's pins step refuses a format-2 record, so **every
row of a format-2 record is a commit that contains K4a-ii**. A commit between K4a-ii and K4b can be one: its image
has K4a's proof and N1's rule, and its own `NodePins` reads only `format 1`, so it refuses every handout (N1's rule
1: a record read whole and refused refuses the handout) and can't start as your node; the keeper serves its row, and
nothing of its code hands a session an end. Wherever this design says a row is "at or after the floor", it means
this: its commit contains K4a-ii. **What that costs, stated** (this edit's blind check): an install of such a commit
once the record is format 2 (a rollback to a commit between K4a-ii and K4b is allowed: on v2, both runners, it
contains the floor) succeeds, and then the node doesn't start (its `NodePins` refuses the format-2 record: fail
closed, with the start's words for a record it refuses), and the next update runs that commit's script, whose pins
step refuses the format-2 record whole (rule 3: exit 65), so no update installs. **The way out:** an install of a
commit from K4b on in the install's first form (the builds folder's `current` removed, so that commit's own script
runs, with its format-2 pins step and its floor check); no administrator is needed. **K5 raising the floor to K4b's
commit closes this window** (the ruling's "may"; this design recommends that K5 does it, since K5's commit can name
K4b's).

**What it costs:** once the record is format 2, no build from before the floor can be installed or started as your
node, and none is a rollback; going back to one needs the record removed by an administrator, which is intended.
**What isn't closed, under "the choice of commit":** any commit at or after the floor that is on v2 and passed both
runners can be installed, and is then served (bounded as before); and a session that rewrites the install script
itself, or has you run a pins step of its own making with your password, can write any row (S1's class, as for the
keeper's program). **The general rule**, beside the `--keep 1` lever (the proof review's D3: for **every host-side
rule the keeper's property rests on**, not only the pair rules: J0a's rule 2, the first statement's clear and
environment rule, the hardened parser's refusal of its test hooks, each proof's role, and whatever K7 adds): a fix to
such a rule reaches the keeper's service only once older rows are dropped. The floor and the format do it for K4a; the
first statement lands in K4a-ii's commit (the floor), the roles in K4a-ii's and K4c's, all before K4's client, so
every build that can send the keeper a request has them (a build without K4 sends it nothing); a later fix of any such rule
needs a later floor and the format bumped again, **the format's bump and the install's floor check landing in one
commit, the floor naming an ancestor** (the narrow re-check's KP6b), so that no install script whose pins step writes
the new format lacks the check (or your `--keep 1` at once, which drops every older row but doesn't stop an older
commit's later install).

**The node's removal runs the keeper's** (the review's F18). At `b15e0052` there is no node removal
(`install-node-mac.sh` has no remove form). **The slice that adds it owns the call** (the re-check's answer to its
question 2): an `install-node-mac.sh` remove form, step 12 of the Mac node spec's order of work ([the node on
macOS](2026-11-19-v2-node-on-macos.md), "The order of work"), which stops the node's agent first, then runs the keeper
step's `--remove` (the store kept, said: a later install opens the record again) or, when you ask the removal to
forget the node's record, its `--remove --forget-store`, said before the password; its test,
`KeeperStepTests.theNodesRemovalRemovesTheKeeper`, is that slice's. **K5 owns `--remove` and its own tests**
(`removeKeepsTheStore`, `forgettingTheStoreThenInstallingMakesANewKey`), not the node's removal. **The switch-on
review checks that nothing removes the node without the keeper's removal.** Without it, a removed node would leave a
root daemon serving every build still pinned, with the key to a vault file that may still be in your home.

**Order at setup.** The install that sets the keeper up runs the pins step with `--fresh` first (rule 1 above: only
this build's row, at or after the floor), then the keeper step. The keeper is installed before any node host can start
(the node is refused today by `macUnbuilt` and `isCheckedMacNode`), so no record ever begins under the login Keychain: there is nothing to migrate,
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
| KP3 | The keeper's swap moves a slot | only on an accepted message (KP7 to KP15), atomic by the serial loop of the one keeper that holds `store/lock`, on disk before the answer | `KeeperTests.aSwapIsAnAtomicCompareAndSet`, `KeeperTests.twoHostsRacingASwapLeaveOneValue`, `KeeperStoreTests.aSwapIsOnDiskBeforeItIsAnswered` |
| KP3a | **A second keeper process on the same store** (an update whose `bootout` returned before the old process exited; a trial keeper on the real paths): both read X, both answer `ok` to swaps from X (the review's F8) | the store's `flock`, taken at the start and held for life: a second keeper exits having served nothing; `bootout` waited on until the process exits (K-M9); a trial keeper's paths are its own folder's (F16). Not reachable by your account (it needs root's acts) | `KeeperStoreTests.aSecondKeeperOnOneStoreExits`, `KeeperTests.aSecondKeeperChecksInForNothing`, `KeeperTests.theTrialKeeperNeverOpensTheRealStore` |
| KP4 | The key is made | by the keeper at its store's first `open`, from `SecRandomCopyBytes`; never taken from a caller, never remade over a store it can't read: only on `ENOENT` for `node.keep`, never on a read error (N3) | `KeeperStoreTests.theKeyIsMadeOnceAndNeverTakenFromACaller`, `KeeperStoreTests.anUnusualStoreIsDamagedAndNeverReplaced`, `KeeperStoreTests.aReadErrorMakesNoKey` |
| KP5 | The store started over or forgotten | only the keeper step's `--start-over` or `--remove --forget-store`, under your `sudo` (root: S1) | `KeeperStepTests.startOverIsRefusedForAStoreThatParses` |
| KP6 | Which hosts are served | the pins record, written only by the pins step (root); read afresh per request; `format 2` only (N2, KP6b) | `KeeperProofTests.anUnpinnedOrDroppedBuildIsRefused`, `KeeperProofTests.aFormat1RecordServesNothing` |
| KP6a | **The pins' host rows at every node update** (writer, trust on first use; the review's F3): a session rewrites the host's build or source before the install signs it and reads its cdhash (the Mac spec's S9); the pins step writes that cdhash as the new build's host row; the node switches to it; it passes the keeper's proof and gets the key and both slots, for as long as its row stays; the key never rotates (F17), so one success lasts | **none at your account's level: a stated limit, accepted by the user on 2026-11-27 (8B298106)**. Closing it would need every program built as root, not proposed. The remedy after a suspected compromise: first stop your sessions and what they started (the re-check's N8), then a fresh install, `node-pins-mac.sh --keep 1`, the keeper step's `--remove --forget-store` and `--install` for a new key; the record begins again (`unreadable`, open, first looks and devices held) | `KeeperStepTests.forgettingTheStoreThenInstallingMakesANewKey` (the remedy works); the limit itself has no test |
| KP6b | **Rows of builds from before K4a** (the re-check's N2): an install at an older commit wrote a host row whose code has no child proof, no `CLOEXEC_DEFAULT` and no N1 rule; the keeper serves every host row, so a session that starts that build in any mode holds the parser link's end (F1, whole); later, an install of an older commit, or a first-form one run by that commit's own script once `current` was deleted | the setup's pins step in its `--fresh` form (the same record `--keep 1` leaves), said before the password; the floor (K4a-ii's commit) refused, unconditionally, by K4b's own install script and every later one (the narrow re-check: KP6c); the record's `format 2` from K4b on, which older pins steps refuse whole and the keeper alone reads; so every row of a format-2 record contains K4a-ii. What remains: the choice among commits at or after the floor, and a rewritten install script (S1's class) | `KeeperStepTests.everyInstallThatWritesFormat2RefusesACommitWithoutK4a` (K4b's), `.theSetupKeepsOnlyTheBuildItInstalls`, `.theSetupSaysOlderBuildsAreDroppedBeforeThePassword`, `.anInstallRefusesACommitBeforeTheFloor` (at the setup and once a keeper is installed, an update to an older commit included), `NodePinsTests.onlyFormat2IsRead`, `.theFloorsPinsStepDoesntCarryAFormat1Record`, `.aPreFloorPinsStepRefusesAFormat2Record` (the older commit's step's text, run as the user against a scratch record as the pins step's root half can be), `KeeperProofTests.aFormat1RecordServesNothing`; K7's read-only look at this Mac's real record |
| KP6c | **An install script from K4b up to K5 installing a pre-floor commit** (the narrow re-check of 2026-11-27, KP6b not closed by the second fix round): (1) the keeper is set up, the record `format 2`; (2) you install a commit M from K4b's commit up to, not including, K5's (allowed: on v2, both runners, it contains the floor; a rollback to K4b's commit is enough), or a program of yours points `current` at a folder `$prefix/M/` it made from M's public files (`build-info`, `Resources/install-node-mac.sh`, `lib/*.sh`, `node-pins-mac.sh`), which step 3 and step 5 accept; (3) you install a pre-floor commit Y: M's script runs, with M's pins step, which reads the format-2 record, carries its rows, adds Y's and writes `format 2`; (4) the keeper serves Y's `host` row, Y having no child proof, no `CLOEXEC_DEFAULT` and no N1 rule: F1, whole | **K4b's own install script refuses, unconditionally, any commit that doesn't contain K4a-ii's commit** (`git merge-base --is-ancestor`, in its fresh fetch, beside step 6), so no install script whose pins step writes `format 2` lacks the floor check; M's script refuses Y before its pins step and nothing is written. K5 may raise the floor to K4b's commit later | `KeeperStepTests.aPreFloorCommitInstalledAfterAK4bToK5CommitWritesNoRow` (K4b's script text in its test form, as the installed build's copy, against a scratch format-2 record: an install of a commit without K4a-ii is refused before the pins step, the record byte for byte unchanged), `.currentPointedAtAFolderOfSuchACommitsPublicFilesChangesNothing` (`current` pointed at a folder made from a K4b-to-K5 commit's public files: the same install refused, nothing written), `.everyInstallThatWritesFormat2RefusesACommitWithoutK4a` (keeper installed or not) |
| **Channels to the keeper (the Mach form; redone after K-M1, the write-then-exec path first)** | | | |
| KP10 | **Write then exec:** a session sends a request message (or, the pair's form, makes a pair, writes a request on it) and then execs the pinned host, while something of its own waits for the answer | the trailer carries the sender's token as it was at the send: the old pidversion, which Security refuses after the exec (K-M1 (n2), `-67065`); a sender gone is refused ((n3)); the pair's form has nothing to reach, since the keeper takes no socket end (it would pass any check over a pair: (g1), (g4)) | `KeeperProofTests.aMessageSentBeforeAnExecIsRefused`, `.aMessageWhoseSenderExitedIsRefused`; K-M1 (n2), (n3) |
| KP10a | **A copy-holder:** a session holds a send right to the keeper's port (anyone may look it up) and sends while a genuine host sends; or, over a socket, writes the bytes and makes the genuine image the last to act on it (one failed write or read, (g4), (g5)) | each message is judged by its own trailer: another task's names that task ((n4)), refused; nothing done to a socket changes a message | `.aMessageFromAnotherTaskNamesThatTask`; K-M1 (n4) |
| KP10b | **A replay:** a session sends again the bytes of a genuine host's request | a message is received once, by the one task holding the port's receive right (the keeper); the same bytes sent again carry the resender's token | `.aResentRequestIsJudgedByItsResender` |
| KP10c | **The reply taken or forwarded:** a session reads what the keeper answers a genuine host; or a service of the same name in your domain receives the host's request and puts the host's reply right in a request of its own to the real keeper, so a refusal (`notPinned`, root's trailer) reaches the host at a moment the session chose (the diff review's finding) | the reply goes only to the send-once right the judged request carried; every reply names the sender judged (pid, pidversion) and the host requires its own, so a forwarded refusal names the forwarder and is no answer, and that port is never taken for the keeper's; a malformed or other-uid message gets no reply | `.theReplyGoesToTheRequestsOwnReplyPort`, `.everyReplyNamesTheSenderJudged`, `.aMalformedOrOtherUidMessageGetsNoReply`; `NodeAnchorTests.aFakeThatForwardsTheHostsReplyPortGetsTheHostNothing` |
| KP7 | Another uid's process sends | the trailer's effective and real uid must be the keeper's uid, else the message is destroyed unanswered (`wrongUid` is never sent) (K-M6's access entry no longer needed: there is no socket) | `KeeperProofTests.anotherUidsMessageIsDestroyed` (uid injected) |
| KP7a | A process of yours removes, `chmod`s or takes over the keeper's way in | no socket and no file of the keeper's in your reach: the port is the system domain's, named by root's plist; your account can't check in for a system daemon's name (K-M15) | K-M15 |
| K-M16 | **Assumption A, every route** (the proof review's I1; B's library half is measured, M6, not owed here: D2): a session starts the genuine image (the host, a child, a handover process) with exception ports of its own at the task level (`posix_spawn`'s attributes, or its own task's before the exec) or the thread level, any behaviour (`EXCEPTION_STATE` and `EXCEPTION_STATE_IDENTITY_PROTECTED`, which carry the thread's registers and let a reply set them), any mask (`EXC_MASK_CRASH`, `EXC_MASK_CORPSE_NOTIFY`); limits that force a fault before the image's first statement; a task port the child handed its parent before the exec; a traced exec (`PT_TRACE_ME`); environment | **here, measured** (K-M16 here, the record): task-level ports cross into the hardened image, every behaviour and mask (p1, p2, p4); thread-level ones don't cross an exec (p3); a launcher's limits force a bad-access fault (16 KiB stack) or an abort (4 descriptors, none free) before the first statement ((q2), (q3), (q4), (q6), each without the first statement's marker); the window is 1 to 6 ms of dyld and initializers (w1, w2); the one-call clear leaves no handler. **A rule at the first statement** closes every route after it (KA1 to KA3, KA7, KA9, KA10). **Owed to the keyboard trial (K7)**, open until then: a handler receiving a fault from the window, a state reply moving the thread, a crash or corpse message's port reading memory, a pre-exec task port after the exec, a traced exec (KA4 to KA6), because each acts on another process's exception, registers, task port or tracing, which an agent's session doesn't run. **In force until then:** nothing that gives a host the node's key is offered (K4, K5's real install). **If the trial leaves a route open:** the keeper serves only a host launchd itself started as the node's job from the host's own file (the interface's A, its check measured in the trial first); with no such check, the keeper isn't offered at all | the rows KA1 to KA12 below; K-M16's trial part at K7a |
| KP8 | A process of yours sends a message of another shape: another size, a complex one (ports or memory), no send-once reply port, another prefix, verb or slot, more than one request (the old KP8, KP16 and KP16a: a hello carrying many descriptors) | destroyed with `mach_msg_destroy` (every right and every memory region it brought released in the root process, F7's rule in Mach's form), nothing answered | `KeeperProofTests.aMessageWithoutTheExactFormIsDestroyed`, `.everyRightAComplexMessageBringsIsReleased` (2, 64 and the most a message carries) |
| KP9 | It sends a request of its own | its trailer names its own code: no pinned host row | `KeeperProofTests.aSessionsRequestIsRefused` |
| KP9a | **The socket forms** (a pair of its own, an end that isn't a pair's, a keeper-made end, a nonce round: candidates A and B) | none is taken: the keeper has no socket; K-M1 (g) to (m) are why | — |
| KP11 | **Cross-protocol:** a session gives a host it starts a bootstrap port that forwards the host's own messages of another protocol (a child's proof after K4a-ii, the handover keeper's after K4c) to the keeper's port | the request's exact size and `vskeep1\n` prefix; those proofs have another size and carry a port descriptor (complex), so they are destroyed (KP8) | `KeeperProofTests.anotherProtocolsMessageGetsNothing` |
| KP12 | **The deputy:** the genuine pinned host in another mode (a scratch home, a test host, `--handover`, `--test-checked-shape`) | the keeper can't tell modes; J0a's rule 2: no other mode's code sends a keeper message | `HostJournalTests.noOtherModeTouchesTheNodesItems` (its keeper arm) |
| KP13 | **A second checked host** beside the node (journal P40), its timing driven, its lock swapped | the swap is atomic: one raise from each value succeeds; the loser writes nothing more (`lock.lost`) | `HostJournalTests.aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet` on the keeper's seam, `KeeperTests.twoHostsRacingASwapLeaveOneValue` |
| KP14 | **A pinned older build** started by a session (journal P41) | served (it is pinned), and at or after the floor (KP6b); its `host.start` is open by the unswitched-build rule; `--keep 1` drops it; a build without the keeper's client (before K4) sends the keeper nothing at all | `HostJournalTests.anUnswitchedBuildChangeIsOpen` |
| KP15 | A pinned server's or command line's code, or a host that isn't hardened | host rows only; hardened as the genuine ad hoc host is (`CS_VALID`, `CS_RUNTIME`, `CS_HARD`, `CS_KILL`, `CS_FORCED_LV` or `CS_REQUIRE_LV`; no `CS_GET_TASK_ALLOW`, `CS_DEBUGGED`, `CS_INVALID_ALLOWED`: D2), both from the kernel's record by the trailer's token | `KeeperProofTests.aServerOrCommandLineRowIsRefused`, `.anUnhardenedHostIsRefused`, `.theGenuineAdHocHostsStatusWordIsHardened` (`0x22011311`, M6's and K-M16 here's) |
| KP17 | **A fake keeper:** a service of the same name your account registered in its own domain, a bootstrap port a session gives a host it starts, or **the trial keeper's port** (D4: root, possibly the installed cdhash) | the host checks the first reply from a port it looked up (root, the cdhash in the node's `installed`, hardened, by the kernel's record of the reply's trailer, and the reply naming this uid and `node`) before it sends that port anything else, keeps a checked port while it lives, and checks every reply; a fake sees at most an `open`, which holds nothing; the start's words are D5's ("something answers in its name") | `NodeAnchorTests.aKeeperThatIsntRootRunningTheInstalledCodeIsRefused`, `.aLookedUpPortIsCheckedBeforeAnythingElseIsSent`, `.aTrialKeepersReplyIsRefused`, `.somethingAnsweringInTheKeepersNameHasItsOwnWords`; K-M15 |
| KP18 | The keeper's own inputs: arguments, environment, working folder, signals, `launchctl` on its job | its plist is root's; one argument, no variable read; its paths from its own executable's folder (F16); stopping or signalling it is root's (K-M9) | `KeeperTests.theKeeperTakesOneArgumentAndNoVariable`, `KeeperTests.theTrialKeeperNeverOpensTheRealStore` |
| KP18a | **The keeper switched off in Login Items** (System Settings › General › Login Items › Allow in the Background, since macOS 13; the review's F10): if your account can do it, or script the window to, the keeper stays down at will, past reboots | **not measured**, K-M12 (trial); if your account can, one more at-will denial, stated as KP19's, its start's words the merged "installed, not answering" ones (no login-item sentence: N6, D5), and K6's `status` listing Login Items among the places to look, as a possibility; fail closed either way | K-M12 |
| KP19 | A flood of messages, or a proven host stopped mid-request (`SIGSTOP`) | serial; nothing kept per message; a full queue makes senders wait for their own `mach_msg` timeout; the host's send with its own deadline and a pause between tries (F9's rule). **A stated limit:** a denial your account can cause at will, through which the journal's P31, P36 and P42 stay reachable as they were through the locked keychain (each fails closed and shows) | `KeeperTests.aFloodDelaysOthersByTheirOwnTimeoutOnly`, `NodeAnchorTests.aFullQueueCostsTheStartItsLimitOnly`; K-M10, K-M15 |
| KP19a | **The busy keeper's words leading you to the install's window** (the review's F4) | only facts your account can't cause mention the password or the setup line: "not installed" (root's plist or program absent: `ENOENT` alone) and `damaged`; "installed, not answering" (busy or not running, one state under the Mach form: D5), "something answers in its name" and a read error never do; the running host's words alike | `KeeperStatusTests.startSaysTheKeeperIsntInstalled`, `.startSaysTheKeeperIsntAnsweringAndNeverMentionsThePassword`, `.startSaysSomethingAnswersInItsNameAndNeverMentionsThePassword`, `.theMergedStateNamesNoLoginItem`, `.aWalkThatFailsOtherThanENOENTIsntNotInstalled`; `KeeperStoreTests.aReadErrorIsNeitherDamagedNorMissing`; `NodeAnchorTests.aPinsReadErrorIsNotNoRecordAndNeverMentionsAnInstall` |
| **The host's own ends (no longer paths to the keeper: kept for the host's data)** | | | |
| KP20 | The host's end of a pair reaching another process, or a session holding an end of a pair the host writes on | **not a path to the keeper** (it takes no socket end); for the host's data: every spawn `CLOEXEC_DEFAULT` (K4a-i), a child given an end proves itself by a Mach message first and gets it as a fileport to its own port (K4a-ii), N1's rule | `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName`, `KeeperLintTests.noProofAsksASocketsToken`, `KeeperLintTests.everyPairTheHostImageMakesIsClassified` |
| KP20a | **The checked node's own parser launcher** (the review's F1): `<node root>/host/launcher-<build>`, in your folder; a program of yours there holds the parser link's end while the host writes a session's terminal output on the other; likewise the server child's connector | K4a-ii in the Mach form: the child spawned with the host's port as its bootstrap special port and no socket, proving its code by a message whose trailer must be the spawned pid running the expected cdhash, hardened exactly when the image is; the link a fileport to the port that message carried; code that sends and then execs the image is refused ((n2)); the launcher written afresh at each start | `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`, `.aLauncherThatExecsTheImageAfterItsProofGetsNoLink` (other code at the launcher path sends, forks a holder, execs the image: nothing reaches the holder) |
| KP20b | **A spawn without `CLOEXEC_DEFAULT` racing a pair's making** inherits both its ends (the review's F1 (b)) | every spawn in the image, and in the server it gives ends to, names what it keeps; now for the host's data alone | `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName` |
| KP20c | A genuine end whose holder closes after writing (the review's F5) | **gone**: no socket end reaches the keeper, and no token is read again | — |
| KP20d | **A host a session starts, of a pinned image** (the re-check's N1): `--server` naming a program of the session's, or `--handover-test-keeper` with `--handover-test-secret` | N1's rule, kept as ruled, for the host's data: a pinned image gives ends only to its own code or its row's server, its test flags and by-path handover refused, the record read afresh before each handout; not the keeper's barrier (the keeper takes no end) | `HostChildProofTests.aPinnedImageGivesNoPairEndToCodeASessionNamed`, `.aPinnedImageRefusesTheTestKeeperAndItsSecret`, `.aPinnedImageRefusesTheByPathHandover`, `.anImagePinnedWhileRunningGivesNoConnectionToAServerItsRowDoesntPin`, `.aPinsReadThatFailsRefusesTheHandout` |
| KP20e | **The checked node's own switch**: the parcel and the secrets go to a handover keeper and a new image of the target's code | K4c: each proof a Mach message judged by its trailer (the keeper: the spawned pid, the target's cdhash; the parent: the parcel's own message; the new image: the host's pid, the keeper's own code), each handout fileports to the proven task's own port; the target pinned by the same record (`keeperTarget`) | `MacHandoverKeeperProofTests.codeAtTheTargetPathThatExecsTheTargetGetsNoParcel`, `.aNewImageProofSentBeforeAnExecIsRefused`, `.theParentIsProvenByTheParcelsOwnMessage`; `HostChildProofTests.theCheckedSwitchGivesItsEndsOnlyToATargetTheRecordPins` |
| KP20f | **A hardened image not yet pinned, and its by-path handover** (the Mac app's own host at every app update) | **settled under the Mach form**: no end it hands out, before its pinning or after, by path or otherwise, carries a request to the keeper, so its by-path handover is kept and the app's host keeps its sessions at every app update; the lead's choice (A) stands as ruled for the host's data; no exemption keyed on `ownsLaunchers`; both of the handover keeper's hardened checks "exactly when" | `HostChildProofTests.theAppsHostStillHandsOverByPathAtAnAppUpdate` (with the app's update in the sandbox), `.aHardenedImageNotYetPinnedGivesNoPairEnd`, `.aHandoverKeeperRequiresItsParentHardenedExactlyWhenItIs`; K7's switch run |
| **Assumption A: the genuine image runs only its own code** (the proof review of 2026-11-27: I1 to I3, D1, D6, D7; each route with the measured case or the rule that closes it; K-M16). **This list is the review's and this round's; it isn't shown complete:** no adversarial check of its completeness was run (the one this round planned, a fresh reviewer given the measured facts and the rule, was stopped by the model's safeguards before it answered, and the lead ruled it not be run again in any form). The keyboard trial (K7), with you, is where the open routes and the list itself are examined; until then the rule in force stays: nothing that gives a host the node's key is offered | | | |
| KA1 | **Task-level exception ports a session names** for the genuine image it starts (`posix_spawn`'s attributes, or its own task's set just before an exec), any behaviour, any mask of `EXC_MASK_ALL` | **measured to cross** into the hardened image (K-M16 here (p1), (p2); hardening strips none, (p4)); **closed after the first statement by the rule**: `main`'s first statement clears every mask on the task, measured to leave none (the clear lines); before it, KA4 | `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask`; `KeeperLintTests.theClearIsMainsFirstStatementInEveryMode` |
| KA2 | **Thread-level exception ports** set on the thread that execs the genuine image | **closed by a measured fact**: they don't cross the exec (K-M16 here (p3), hardened and not); the first statement clears the main thread's anyway (cheap, and a later macOS may differ) | `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask` (its thread-level arm) |
| KA3 | **Crash and corpse ports** (`EXC_MASK_CRASH`, `EXC_MASK_CORPSE_NOTIFY`, which this SDK's `EXC_MASK_ALL` leaves out: the proof review's I2), then a crash forced once the host holds the key (`SIGABRT` sent to it) | **measured to cross** (p1, p2); **closed after the first statement by the rule**, which names both masks (measured accepted); before the first statement the image holds nothing of the node (the key comes from `open`, long after); whether such a message's port reads memory at all is the trial's (KA4) | `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask` (both masks named) |
| KA4 | **A fault forced before the first statement** (inherited limits: a 16 KiB stack, 4 descriptors), delivered to a handler the session named (KA1, which no clear can have removed yet), and a reply that sets the faulting thread's registers (`EXCEPTION_STATE`, or `EXCEPTION_STATE_IDENTITY_PROTECTED` with no control port), repeated to run the image's own code at the session's choosing | the fault: **measured possible** (K-M16 here (q2), (q3): `SIGSEGV`; (q4), (q6): `SIGABRT`; with 5 descriptors, (q5) and (q7), the image runs), in a window of 1 to 6 ms (w1, w2); the delivery and the reply: **owed to the keyboard trial** (K-M16's trial part, its (1) to (3)), **open until then**. In force meanwhile: nothing that gives a host the key is offered. If the trial finds it works: the fallback (the keeper serves only a host launchd started as the node's job from the host's own file), its check measured first; with none, the keeper isn't offered | K7's record |
| KA5 | **A task port the child hands its parent before it execs the genuine image**, used after the exec | **owed to the keyboard trial** (its (4)); open until then; the first statement can't close it (no call drops a port someone else holds); the fallback closes it (launchd's own spawn hands no session a task port) | K7's record |
| KA6 | **A traced exec** (`PT_TRACE_ME`, then the exec of the genuine image) | **owed to the keyboard trial** (its (5)); open until then; if the kernel marks the process `CS_DEBUGGED`, the keeper's hardened check refuses it (KP15, on the kernel's status word) | K7's record; `KeeperProofTests.theGenuineAdHocHostsStatusWordIsHardened` |
| KA7 | **Environment that steers system libraries** without loading code (malloc's, the Swift runtime's backtracer, Foundation's: the proof review's D6) | **closed by the rule** right after the clear: the checked start ends on any variable outside its fixed list, before `open`; a hardened image's parser and handover keeper exec themselves again once with exactly their list before their proof, so the image that proves itself started with nothing a session chose; every host spawns them with exactly the list; what a library reads before the first statement is in KA4's window | `HostFirstStatementTests.theCheckedStartRefusesAnEnvironmentOutsideItsList`, `.aHardenedParserStartsItselfAgainWithItsList`, `.everyHostSpawnsItsParserWithTheList`, `MacHandoverKeeperProofTests.aHandoverKeeperStartsItselfAgainWithItsList` |
| KA8 | **Code a session supplies** (`DYLD_INSERT_LIBRARIES`, a library of its own) | **closed by a measured fact**: M6 (`marker=absent`; `CS_FORCED_LV` in `0x22011311`, the same word K-M16 here read); the keeper requires library validation in force on the kernel's word (D2) | `KeeperProofTests.theGenuineAdHocHostsStatusWordIsHardened` |
| KA9 | **The parser's test hooks and trap** (the proof review's I3): `--parser-test-hooks` passed by code at the launcher path, then `ESC ] 7599 ; trap BEL` written into the session's tty | **closed by the rule**: a hardened image's parser refuses `--parser-test-hooks` (exit 64, the OSC handler never registered, so the bytes are ignored); any other trap after the parser's first statement goes to no handler of a session's | `HostChildProofTests.aHardenedParserRefusesItsTestHooks`, `.aTrapHookWrittenToTheTtyIsIgnoredInAHardenedParser` |
| KA10 | **The children and the handover processes** (the parser, the handover keeper, the new image; the server child is the server's own program) started with a session's ports, limits or environment (I3) | **the same first statement** (they are modes of the same `main`): after it, closed as KA1 to KA3 and KA7; before it, KA4 to KA6; so K4a-ii's and K4c's offering waits on K-M16's trial part (K7a), as K4's does; the launchd fallback doesn't reach them: if K7a leaves a route open, K4c's checked switch isn't offered (the node updates by stop and start) and K4a-ii is offered only with the route accepted by the lead as its stated limit (the interface's A) | as KA1, KA7, in each mode |
| KA11 | **The keeper's check reads a file a session controls** (the proof review's D1): Security's `runs` validates the sender's code on disk | **measured** (K-M16 here (d1) to (d3)): not the file's pages (0.2 ms for 256 MiB), but the file at the sender's path (a rename over it makes the check fail with `errSecCSStaticCodeChanged`); **closed by the rule**: the keeper judges by the kernel's record by the token (`csops_audittoken`: the cdhash at the start, the status word; no file opened, unchanged by a rename, refused for a stale or gone token) and never calls `runs`; the host's own proofs of its children (K4a-ii, K4c) take the same record for the same reason (a file renamed over the launcher's or the target's path would otherwise fail a genuine child's proof) | `KeeperProofTests.theCheckOpensNoFileOfTheSenders` (a sender's file renamed over after its start: still served if it is a pinned host's process, its check taking no longer), `.aStaleTokensRecordIsRefused` |
| KA12 | **A proof taken for another role** (the proof review's D7): code at the target path execs the genuine target as `--parse-session`; its parser proof reaches K4c's `start`, which would give it the parcel | **closed by the rule**: each proof names its role (`parser`, `server`, `handoverKeeper`, `newImage`), each receiver takes only its own role and its own handout's exact form; today's other modes have no other sink (`HostImages.mayTakeHandover`, `main.swift:233`, `:250`) | `HostChildProofTests.aProofForAnotherRoleGetsNothing`, `MacHandoverKeeperProofTests.aParserProofGetsNoParcel`, `.aParserTakesNoParcel`, `.onlyACheckedStartTakesACheckedNodesParcel` |
| **Trust on first use, and the other moments** | | | |
| KP21 | **Install** | the key made by the keeper, nothing of the store taken from your account; the node's first record `begins`, open, first looks held. **The program is root's build** from the commit's objects, every hash recomputed in root's folder, root's toolchain, no dependency (the five conditions); what remains is the choice of commit (bounded by the provenance check) and a session that rewrites the install script itself, which can hand root a self-consistent commit of its own (S1's class): stated, accepted | `KeeperStepTests.theRootHalfRefusesObjectsThatDontHashToTheCommit`, `.theRootHalfRefusesALinkOrSubmoduleInTheTree`, `.theRootBuildReadsNothingOfTheAccount` (its environment and paths, against a scratch tree); K-M13; `HostJournalTests.noFileAndNoCounterIsOpenToo` |
| KP22 | **A node update** (or a rollback) | the pins step alone, refusing a commit before the floor (KP6b); the new host served at once; the vault carried by the handover keeper; the next swap from the value it carried. A host pinned through a rewritten build is KP6a | `HostJournalTests.aSwitchHoldsTheLockBeforeItReadsTheRecord`; K7 |
| KP23 | **A keeper update** | as KP21 for the program; the store kept; down for seconds (KP29); `bootout` waited on until the old process exits (KP3a) | `KeeperStepTests.anUpdateKeepsTheStore` |
| KP23a | **The keeper step forced at a node update** by a rewritten build (the review's F2) | the step runs only when the commit's `Keeper` tree id differs from the one root recorded in `installed`, read by root from the verified objects; for the recorded tree, a build with another cdhash is refused with the review's words, installing nothing; and root builds from the objects anyway, so a rewritten build has nothing to install | `KeeperStepTests.theInstallRunsTheStepOnlyWhenTheKeeperSourceChanged`, `.anUnchangedSourceBuiltDifferentlyIsRefused` |
| KP24 | **A record that begins again** | the host swaps from what it read (absent included) to the new record's value; the key unchanged; open `record.begins`, first looks and devices held; the file that didn't open set aside, never sealed over (K8) | `HostJournalTests.everyReasonHoldsItsFirstLooks`, `HostJournalTests.aStartedOverNodeVaultSavesAndSetsTheOldFileAside` |
| KP25 | **A keeper restart** | the store read again; `damaged` (read whole and refused) refuses every request; a missing store (`ENOENT` alone) makes a new key (only root deletes it), so the node's file is `unreadable`, open; a read error makes no key and answers `readError` (N3) | `KeeperStoreTests.aMissingStoreGetsANewKey`, `KeeperStoreTests.anUnusualStoreIsDamagedAndNeverReplaced`, `KeeperStoreTests.aReadErrorMakesNoKey` |
| KP26 | **A Mac restart** | the keeper at boot (K-M3), the node at login, open (the decided (1)); the host's start waits up to 60 s | `NodeAnchorTests.theStartWaitsForTheKeeperThenExitsHavingReadNothing` (an injected clock) |
| KP27 | **Removal** | bootout; program and plist removed (the port goes with the job); the store kept unless `--forget-store`, said before the password; the node's removal (the Mac spec's step 12) stops the node's agent, then runs it | `KeeperStepTests.removeKeepsTheStore`, `KeeperStepTests.theNodesRemovalRemovesTheKeeper` (the removal slice's) |
| KP28 | The keeper down at the host's start | the host reads no file; exit 78 after 60 s (installed, not answering; or something answering in its name), or at once (not installed, or a refusal); decided (Open questions 1) | `NodeAnchorTests.theStartWaitsForTheKeeperThenExitsHavingReadNothing` |
| KP29 | The keeper down while the host runs | the journal's failed-raise rule, `noKeeper` | the journal's `aFailedRaiseRefusesAGuardedActAndStillTakesAnAck`, on the keeper's seam |
| KP29a | **A refusal arriving on a running host** (`notPinned` after your `--keep 1` dropped its build, P41; `noRecord`; `damaged`; `notHardened`; `wrongUid`; the review's F14) | the failed-raise rule as KP29, with the start's words for that status, never "isn't answering"; a `readError` is no refusal: it is KP29's "no answer", its words never naming an install (N3) | `NodeAnchorTests.aRefusalOnARunningHostHasTheStartsWords` |
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
| K0 | The `Keeper/` package (no dependency, no test target: N7): `VibeKeep` with what moves into it unchanged (`NodePins` from `VibeCore`; the root walk, the dynamic code check by token, `peerUID` and `peerToken` from `VibePlatform`: [Its program](#what-it-does-and-what-it-never-does)), each old name a one-line call into it; the `vibeswitcher-keeper` target; the repository's package naming it by path in both halves; the keeper's tests in the root package's test targets | `NodePinsTests`, `RootRecordTests` and the code identity tests unchanged; `KeeperLintTests.theKeeperPackageNamesNoDependency` (no package, no test target), `.theKeeperLinksOnlyVibeKeep` | here | none (the re-check of 2026-11-27 cleared it; N7's sentence is written here); **built**: `b4cf8ab2` on `v2-mac-keeper-k0`, under this branch | no |
| K1 | The store: format, strict parse, root-only walk, the write discipline, the three kinds of a failed read (N3: `damaged` only when read whole and refused, `ENOENT` alone missing, every other failure `readError`, which makes no key; the walk's refusal given a kind, its words unchanged), the key's making, the store's `flock` (F8) | `KeeperStoreTests.aStoreParsesOnlyItsOwnForm`, `.anUnusualStoreIsDamagedAndNeverReplaced`, `.aReadErrorIsNeitherDamagedNorMissing` (`EMFILE`, `ENFILE`, `EIO`, `ENOMEM` injected), `.aReadErrorMakesNoKey`, `.aSwapIsOnDiskBeforeItIsAnswered` (a crash injected between each step), `.theKeyIsMadeOnceAndNeverTakenFromACaller`, `.aMissingStoreGetsANewKey`, `.aSecondKeeperOnOneStoreExits` | here | K0; K-M4 before it is offered | with K2 |
| K-M1 | The measurement the proof rests on: (a) to (f) (the first part, which refuted the pair's fixed token) and (g) to (o) (the second, for the redesign: the whole write-then-exec, a silent holder, a nonce round, a keeper-made end, which acts move a socket's token, the end of file in flight, a Mach message's trailer, `SCM_CREDS`), kept as rows with the probe and its output: **done 2026-11-27** | the probe's record | here (no dialog, no `sudo`) | none | no |
| K2 | **The proof, the Mach form** (the interface's candidate C): the keeper's check-in for its `MachServices` name, its receive loop with the audit trailer into a fixed buffer **without `MACH_RCV_LARGE`** (N4), the message's exact form (fixed size, not complex, a send-once reply port, `vskeep1\n`, a verb, the verb's fields), every other message destroyed with what it brought (F7's rule in Mach's form), from the trailer's token the uid, then **the kernel's record by the token** (`csops_audittoken`, `CS_OPS_CDHASH` and `CS_OPS_STATUS`, declared in `VibeKeep`: the proof review's D1, measured in K-M16 here) compared with the host rows read afresh, and the status word **hardened as the genuine ad hoc host is** (`CS_VALID`, `CS_RUNTIME`, `CS_HARD`, `CS_KILL`, `CS_FORCED_LV` or `CS_REQUIRE_LV`; none of `CS_GET_TASK_ALLOW`, `CS_DEBUGGED`, `CS_INVALID_ALLOWED`: D2, on M6's `0x22011311`); **Security's `runs` is not called** (it opens the sender's file at its path, (d2)); the reply on the request's own send-once right, **naming the sender judged, the keeper's uid and its store** (`node` or `trial`: D4); the `peerToken` comment corrected to K-M1's words ("the last to send, receive or poll on the other end, as it runs now") | `KeeperProofTests.aPinnedHardenedHostsRequestIsServed`, `.aMessageSentBeforeAnExecIsRefused`, `.aMessageWhoseSenderExitedIsRefused`, `.aMessageFromAnotherTaskNamesThatTask`, `.aResentRequestIsJudgedByItsResender`, `.theReplyGoesToTheRequestsOwnReplyPort`, `.everyReplyNamesTheSenderJudged`, `.aMalformedOrOtherUidMessageGetsNoReply`, `.aSessionsRequestIsRefused`, `.aServerOrCommandLineRowIsRefused`, `.anUnhardenedHostIsRefused`, `.anUnpinnedOrDroppedBuildIsRefused`, `.anotherUidsMessageIsDestroyed`, `.aMessageWithoutTheExactFormIsDestroyed`, `.everyRightAComplexMessageBringsIsReleased`, `.anotherProtocolsMessageGetsNothing`, `.aFormat1RecordServesNothing`, `.theGenuineAdHocHostsStatusWordIsHardened`, `.theCheckOpensNoFileOfTheSenders`, `.aStaleTokensRecordIsRefused`, `.everyReplyNamesTheKeepersUidAndStore`, `.anOversizeMessageNeverReachesTheCheck`; the exec and fork cases with this Mac's real hardened images and a port given as the bootstrap special port, as K-M1 (n) and K-M16 here (d) | here (the receive loop and its checks on a port the test makes; the launchd name in K7) | K0 (done; its checks act on no store, so K1 is built beside it and K3 joins them); K-M1 (g) to (o) and K-M16 here (D1's timing, (d1) to (d3)) (done): **buildable now**; K-M15's launchd half before it is offered (trial, K7), and the keeper installed for real only after K-M16's trial part (K5) | **yes** |
| K3 | The program: the serial loop over its port (its receive without `MACH_RCV_LARGE`, N4), `open` and `swap`, the request's prefix, its one argument, its paths from its own executable's folder (F16), the store's lock taken before anything in its folder is touched (N5) and its check-in after it, no socket; `readError` answered (N3); every reply naming the keeper's uid and its store, `node` or `trial` by its own folder (D4) | `KeeperTests.aSwapIsAnAtomicCompareAndSet`, `.twoHostsRacingASwapLeaveOneValue` (two real processes), `.aFloodDelaysOthersByTheirOwnTimeoutOnly`, `.anUnknownVerbOrLengthIsDestroyed`, `.theKeeperTakesOneArgumentAndNoVariable`, `.theTrialKeeperNeverOpensTheRealStore`, `.aSecondKeeperChecksInForNothing`, `.aDamagedStoreRefusesEveryRequest` | here (as the user; root's part in K7) | K1 and K2 (**buildable once both are in**); K-M10 (on the port: a flood of messages, complex ones carrying many rights, (d), CPU per message), K-M5 and K-M15 before it is offered; installed for real only after K-M16's trial part (K5) | **yes**, with K2 |
| K4a-i | **Every spawn names what it keeps** (F1 (b), KP20b; the re-check's question 3): every `Platform.Spawn` in the image and in the server it gives ends to names `keep` (`POSIX_SPAWN_CLOEXEC_DEFAULT`), its in-place forms too, `PipeCommand+Darwin.swift`'s own spawn, with the lint over the image's and the server's targets. Behaviour-preserving. **Home: the Mac node spec's order of work, step 10**; listed here because K4 and K4b wait on it | `KeeperLintTests.everySpawnInTheImageClosesWhatItDoesntName`; the host's, server's and parser's existing tests unchanged | here | none | **yes**, its own |
| K4a-ii | **The image's children prove themselves** (F1 (a), KP20a), **with N1's rule and N4's three statements**: **in the Mach form**: the parser and the server child spawned with a port of the host's as their bootstrap special port and no socket, proving their code by one Mach message from their own code carrying a port they made (its trailer the spawned pid, the expected cdhash, hardened exactly when the image is: N4 (a), in the handover keeper's two hardened checks too, `refusal` and `parentRefusal`, so the switch's tests run on unhardened scratch hosts) before the host gives them the link, as a fileport to that port, with their real bootstrap port, which they set back; the proof waited off the host's queue for at most 10 s (N4 (b)); **N4 (b)'s four sentences** (the narrow re-check): the parser's spawn runs off the host's queue, each spawn on a queue of its own (never the proof timer's queue, never the history read's queue, which only waits; the server child's alike; only the result comes back), the 10 s limit counted from the spawn's dispatch so a spawn that never returns is a timeout, and at most 4 spawns in flight per host (past it refused at once; K-M14 may raise the number), the child ended at the limit off the queue and reaped by a process-exit source, never a blocking `waitpid`, each proof's wait a read source and a steady-clock timer on the proof's own queue holding no thread (not one global-queue thread per proof), and a proof that only timed out told "the helper didn't answer in time", never that something replaced it; the launcher written afresh at each start; the words for a child that fails its proof; a pinned image's pair ends only to its own code, its row's server, or across the checked node's own switch a target the record pins, the record read afresh before each handout, its test flags and by-path handover refused (N1: KP20d, KP20e); a hardened image that isn't pinned starts no server child and takes no test keeper or secret (the lead's choice (A), as ruled), and **keeps its by-path handover** (KP20f, settled: the keeper takes no socket end, so no end it hands out carries a request), so **the Mac app's own host (hardened, never pinned) keeps its handover at every app update**; no exemption keyed on `ownsLaunchers`. **The proof review's findings, written in:** **this slice adds the image's first statement** ([The host's side](#the-hosts-side), "The first statement": the clear as `main`'s first statement in every mode, before `argv` is read, every mask, task and main thread, with `KeeperLintTests.theClearIsMainsFirstStatementInEveryMode` and `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask`, which K4's row lists again), and each child proves itself only after it (I2, I3); the parser's environment rule (D6): a hardened parser finding any variable outside its list (`PATH=/usr/bin:/bin`, `HOME`, `TMPDIR`, `LANG`) execs itself again, once, with exactly that list, and every host, the app's included, spawns its parser with exactly it, so the re-exec is for an older host only; a hardened image's parser refuses `--parser-test-hooks`, so its trap hook is never registered (I3, [The host's side](#the-hosts-side) N4 (d)); each proof names its role (`parser`, `server`) and each child takes only its own handout's exact form (D7); the server judges its host by the handout's own message, the Mach form of `NodeCheck.macConnectorRefusal` (N3); K-M14 drains the child's bootstrap port until the child exits (N5). In every mode of the image; it touches every session's start on the Mac, the app's host included, so it is checked in the sandbox too. **Home: the Mac node spec's order of work, step 11** | `HostChildProofTests.aParserThatIsntTheImagesCodeGetsNoLink`, `.aServerChildThatIsntItsCodeGetsNoConnector`, `.aLauncherThatExecsTheImageAfterItsProofGetsNoLink` (other code at the launcher path sends a proof, forks a holder, execs the image: nothing reaches the holder), `.aProofSentBeforeAnExecIsRefused`, `.aChildIsHardenedExactlyWhenTheImageIs`, `.aProofThatNeverComesHoldsNothingElse`; N4 (b)'s: `.aSpawnThatBlocksHoldsNotTheHostsQueue`, `.aSpawnThatNeverReturnsIsRefusedAtTheLimit`, `.spawnsInFlightAreCapped`, `.theReapAtTheLimitNeverBlocksTheHost`, `.proofsInFlightHoldNoThreadEach`, `.aProofThatOnlyTimedOutAccusesNothing`; N1's: `.aPinnedImageGivesNoPairEndToCodeASessionNamed` (the server child), `.aPinnedImageRefusesTheTestKeeperAndItsSecret` (the `--handover-test-keeper` keeper), `.aPinnedImageRefusesTheByPathHandover`, `.anImagePinnedWhileRunningGivesNoConnectionToAServerItsRowDoesntPin`, `.aPinsReadThatFailsRefusesTheHandout`, `.theCheckedSwitchGivesItsEndsOnlyToATargetTheRecordPins`, `.aHardenedImageNotYetPinnedGivesNoPairEnd`, `.aHandoverKeeperRequiresItsParentHardenedExactlyWhenItIs` (KP20f); KP20f's: `.theAppsHostStillHandsOverByPathAtAnAppUpdate` (the app's host, hardened and unpinned, hands over by path and its sessions survive; with the app's update in the sandbox); `MacKeeperHandoverTests` on unhardened scratch hosts, its hardened arm at function level (KP20f's cost); `KeeperLintTests.noProofAsksASocketsToken`; the proof review's: `HostChildProofTests.aHardenedParserRefusesItsTestHooks`, `HostChildProofTests.aTrapHookWrittenToTheTtyIsIgnoredInAHardenedParser`, `HostChildProofTests.aProofForAnotherRoleGetsNothing`, `HostChildProofTests.theServerChecksItsHostByTheHandoutsOwnMessage`, `HostFirstStatementTests.aHardenedParserStartsItselfAgainWithItsList`, `HostFirstStatementTests.everyHostSpawnsItsParserWithTheList`, `KeeperLintTests.theClearIsMainsFirstStatementInEveryMode`, `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask`; the parser's and the server child's existing tests unchanged in what they see | here | K4a-i, then **buildable** with these findings written in; K-M1 (n) (done: a message sent before an exec refused, the bootstrap special port crossing `posix_spawn` and an exec); offered only after K-M14, extended (the spawn's own time, a quarantined or stalled launcher, a burst of never-proving reads, the host's own Swift image started with a bootstrap port that isn't launchd's sending nothing to it before its proof, its port drained until the child exits (N5), a fileport across a message) **and K-M16's trial part** (A for the child: I3) | **yes**, its own (its review checks the proof's waits) |
| K4c | **The handover keeper's proofs in the Mach form** (`MacHandoverKeeper`, built on the Mac line and open today to K-M1 (b) with the pid matching: [The host's side](#the-hosts-side), "The handover keeper … under the Mach form"): the keeper spawned with the old host's port as its bootstrap special port, its proof a message judged by its trailer (the spawned pid, the target's cdhash, hardened exactly when the old image is); the parcel in a message whose own trailer `parentRefusal` judges, its descriptors as fileports to the keeper's own port; the in-place exec with the keeper's port as the bootstrap special port; the new image's proof a message (the host's pid, the keeper's own code, hardened), the parcel and the real bootstrap port back as fileports and a send right; `peerToken` never asked, `holding` dropped, the header's token paragraph and "What stays" struck. **The proof review's findings, written in:** the keeper and the new image prove themselves only after the image's first statement (the clear and the environment rule: the keeper, finding a variable outside its list `PATH=/usr/bin:/bin`, `HOME`, `TMPDIR`, `LANG`, execs itself again once with exactly it, and the old host spawns it with exactly that list; the new image is a checked start: I3, D6); each proof names its role (`handoverKeeper`, `newImage`), `start` refuses a `parser` proof from the spawned pid and a parser destroys a parcel; today's other modes have no other sink, stated with a test (D7). Changes no keeper code; **home: the Mac node spec's order of work, step 11 (beside K4a-ii)** | `MacHandoverKeeperProofTests.codeAtTheTargetPathThatExecsTheTargetGetsNoParcel`, `.aNewImageProofSentBeforeAnExecIsRefused`, `.theParentIsProvenByTheParcelsOwnMessage`, `.aParserProofGetsNoParcel`, `.aParserTakesNoParcel`, `.onlyACheckedStartTakesACheckedNodesParcel`, `.aHandoverKeeperStartsItselfAgainWithItsList` (spawned with a whole environment by an older-style parent: it re-execs once with its list, then proves itself, and the switch completes); `MacKeeperHandoverTests` unchanged in what they see (unhardened scratch hosts) | here | K4a-i, then **buildable** with these findings written in; K-M1 (n) (done); offered only after K-M14's "a Swift image with a non-launchd bootstrap port" part **and K-M16's trial part** (I3) | **yes**, its own |
| K4b | **The format and the floor, in one commit** (N2, KP6b, the narrow re-check's KP6c): the pins record's `format 2`; K4b's `NodePins` reads only it, its pins step writes only it and carries no row of a format-1 record (said before the password: "Older builds of your node are dropped, so only this build is served"); and **K4b's own install script refuses, unconditionally** (a keeper installed or not, any install or update), **any commit that doesn't contain K4a-ii's commit on v2**: `git merge-base --is-ancestor <K4a-ii's commit> <commit>` in its fresh fetch, beside step 6's on-v2 check, before the pins step, with the floor's words ("This commit of your node is older than its keeper allows: it lacks a fix the keeper needs. Nothing was installed. Install a newer commit."). The floor is K4a-ii's commit, written in by K4b (an ancestor it can name); **K5 raises it to K4b's commit** (the lead's ruling of 2026-11-27: a rollback to a commit between K4a-ii and K4b on a format-2 record leaves the node not starting). So no install script whose pins step writes `format 2` lacks the floor check | `NodePinsTests.onlyFormat2IsRead`, `.theFloorsPinsStepDoesntCarryAFormat1Record`, `.aPreFloorPinsStepRefusesAFormat2Record` (the older commit's step's text, as the user, against a scratch record), `KeeperProofTests.aFormat1RecordServesNothing`; the floor's: `KeeperStepTests.everyInstallThatWritesFormat2RefusesACommitWithoutK4a` (K4b's script text in its test form, against a pre-K4a-ii commit: refused before the pins step, keeper installed or not), `.aPreFloorCommitInstalledAfterAK4bToK5CommitWritesNoRow` (the re-check's sequence: a scratch format-2 record, K4b's script as the installed build's copy, an install of a pre-floor commit: no row written), `.currentPointedAtAFolderOfSuchACommitsPublicFilesChangesNothing` (`current` pointed at a folder made from a K4b-to-K5 commit's public files: the same install refused, the record unchanged) | here | K0, K4a-i, K4a-ii **on v2** (its commit is the floor K4b names). **K4b lands only after the redesigned K4a-ii (the Mach form) is on v2** (the lead's ruling of 2026-11-27). Under the Mach form the floor is no longer what keeps a session's bytes from the keeper (no socket end reaches it, and a build without the keeper's client sends it nothing); it keeps every served build one whose children prove themselves, the host's own data, as ruled | **yes** (the pins step's root half, and the install's floor check) |
| K4 | The host's client in `NodeAnchor`, **the Mach form**: the walk of the node's `installed` (the keeper's cdhash), the lookup and the check of a looked-up port by its first reply (root, that cdhash, hardened, by the kernel's record of the reply's trailer; the reply naming this uid and `node`: D4) before anything else is sent to it, a send-once reply port per request, every reply's trailer checked, every refused reply destroyed with what it brought (N4), a dead name looked up and checked again, the send's deadline and a pause between tries (F9), every pair the image makes classified (now the host's own table), the read-back, the start's states (not installed: exit at once; installed, not answering, something answering in its name, or a read error: 60 s, then exit 78, each with its words: D5), a pins read error `readError`, never `noRecord` (N3 (b)), the running host's refusals with the start's words (F14), no Keychain store; J0a's test gains the keeper arm. **And the image's first statement** (the proof review's I2, D6: [The host's side](#the-hosts-side), "The first statement"): the clear as `main`'s first statement in every mode, before `argv` is read, every mask (`EXC_MASK_ALL \| EXC_MASK_CRASH \| EXC_MASK_CORPSE_NOTIFY`), task and main thread, with its lint and test; the checked start's environment refused outside its fixed list, right after; its cost checked in the sandbox (a session program's crash still leaves a report) | `NodeAnchorTests.aKeeperThatIsntRootRunningTheInstalledCodeIsRefused`, `.aLookedUpPortIsCheckedBeforeAnythingElseIsSent`, `.aFakeThatForwardsTheHostsReplyPortGetsTheHostNothing`, `.aDeadNameIsLookedUpAndCheckedAgain`, `.theAnchorTakesNoPortOrDescriptorFromItsArguments`, `.aDroppedSwapIsReadBack`, `.theStartWaitsForTheKeeperThenExitsHavingReadNothing`, `.aFullQueueCostsTheStartItsLimitOnly`, `.aRefusedSendIsTriedAgainAfterAPause`, `.aRefusalOnARunningHostHasTheStartsWords`, `.aPinsReadErrorIsNotNoRecordAndNeverMentionsAnInstall`, `.aTrialKeepersReplyIsRefused`, `.somethingAnsweringInTheKeepersNameHasItsOwnWords`, `.aRefusedReplyIsDestroyed`; `KeeperLintTests.everyPairTheHostImageMakesIsClassified`, `.theClearIsMainsFirstStatementInEveryMode`; `HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask`, `.theCheckedStartRefusesAnEnvironmentOutsideItsList`; `HostJournalTests.noOtherModeTouchesTheNodesItems` (keeper arm) | here | K3, K4a-i, K4a-ii, J0a, then **buildable** with these findings written in; K-M5 and K-M10 (c) (on the port: whether a full queue makes a send wait or fail) for its retry loop; **offered only after K-M15 and K-M16's trial part** (it is what gives a host the node's key), and, if the trial leaves a route of A open, after the fallback's check is measured (the interface's A) | **yes**, with J3a's |
| K5 | The keeper step and the install's call: the root half as text; `--install COMMIT --objects STAGED` with the root build under the five conditions, root's `git` refusing if it doesn't detect a collision (question 1), the trigger by the recorded `Keeper` tree id and the refusal for an unchanged source built differently (F2); `--remove [--forget-store]` with `bootout` waited on (F8), `--start-over`, `--dry-run`, the trial paths, the plist as fixed text; the install's user half: the objects staged, the `Keeper` tree id read from the install's fresh fetch with `GIT_NO_REPLACE_OBJECTS=1` as its other git runs do (the re-check's F2 note), the step run only when the keeper's source changed, the setup's pins step in its `--fresh` form and the floor refused at the setup and after (N2), K4b's floor check kept and **raised from K4a-ii's commit to K4b's** (the lead's ruling of 2026-11-27: it closes the rollback to a commit between K4a-ii and K4b, "Rows a format-2 record can hold") | `KeeperStepTests.theDryRunPrintsExactlyWhatItWouldDo`, `.theRootHalfRefusesEveryValueOutOfPattern`, `.theRootHalfRefusesObjectsThatDontHashToTheCommit`, `.theRootHalfRefusesALinkOrSubmoduleInTheTree`, `.theRootBuildReadsNothingOfTheAccount`, `.anUnchangedSourceBuiltDifferentlyIsRefused`, `.theStepRefusesWhenRootsGitDoesntDetectACollision` (the root half's text run as the user against a scratch tree, its root-only checks given the scratch owner, as the pins step's root half can be), `.anUpdateKeepsTheStore`, `.removeKeepsTheStore`, `.forgettingTheStoreThenInstallingMakesANewKey`, `.startOverIsRefusedForAStoreThatParses`, `.theInstallRunsTheStepOnlyWhenTheKeeperSourceChanged`, `.theSetupKeepsOnlyTheBuildItInstalls`, `.theSetupSaysOlderBuildsAreDroppedBeforeThePassword`, `.anInstallRefusesACommitBeforeTheFloor` | here, but the real write | K3; K4b on v2 (the format and the floor check); K-M13's here part (offline, reproducible, and root's `git` detecting a collision: else the step refuses and K5 isn't offered) before it is offered; **its real use (the keeper installed, serving a host the node's key) only after K-M15 and K-M16's trial part** | **yes** (the Mac's S9, and the root build) |
| K6 | `vibeswitcher start` and `status` tell the keeper not installed (root's plist or program absent: `ENOENT` alone), installed, not answering (no reply to its `open` within 2 s: busy and not running are one state under the Mach form, N6's words, no login item: D5), something of your account answering in its name (a reply not from root running the node's installed cdhash, or naming another uid or store: D5), and "couldn't be checked" for a walk failing any other way (N3 (c)), with the words above: only "not installed" and `damaged`, which your account can't cause, mention the password or the setup line (F4) | `KeeperStatusTests.startSaysTheKeeperIsntInstalled`, `.startSaysTheKeeperIsntAnsweringAndNeverMentionsThePassword`, `.startSaysSomethingAnswersInItsNameAndNeverMentionsThePassword`, `.theMergedStateNamesNoLoginItem`, `.aWalkThatFailsOtherThanENOENTIsntNotInstalled` | here | K4; K-M10 (c) for its deadline; `status`'s Login Items line on K-M12 | no |
| K7 | **The trial, at your keyboard**: the keeper step with the trial paths and label (`dev.vibeswitcher.keeper-trial.<uid>`), the root build included; K-M2, K-M3, K-M6, K-M7, K-M8, K-M9 (with `bootout`'s timing), K-M12 and K-M13 (as root) against it; a scratch pinned host's `open` and `swap` against the real root keeper; then `--remove --forget-store`. And **a read-only look at this Mac's real pins record** (N2: `/Library/Application Support/VibeSwitcher/node-<uid>.pins`, readable by any account, no `sudo`): whether it holds rows, of which commits, and in which format, kept in the trial's record. And **KP20f's owed run**: the first update after the setup pins two real builds, and the switch between them, a hardened host to a hardened target through a proven handover keeper with its server child ended and started again, is run and watched end to end. And the checked start's environment names logged at the node's real start (D6), and, if K7a left a route of A open, the fallback's check (launchd's record of the node job's process and the kernel's of the process, as root) measured | the trial's record | **your `sudo` line** (and another account for K-M6) | K5 | no |
| K7a | **K-M16's trial part, at your keyboard** (the proof review's I1; a step of its own, not part of K7, since it needs no installed keeper): on scratch hardened images the probe builds, never the node's, the app's or any session's, as the user with no `sudo`: (1) a fault from the window (K-M16 here (q2)'s 16 KiB stack) and one after the first statement's clear, delivered or not to a handler the parent named; (2) a state reply moving the faulting thread or not; (3) a crash or corpse message's port reading memory or not; (4) a task port the child handed over before the exec, live or dead after it; (5) a traced exec refused or marked `CS_DEBUGGED`; and whether the list KA1 to KA12 is complete | the trial's record, K-M16's row | your keyboard (not an agent's session: each acts on another process's exception, registers, task port or tracing) | none: it can run any time, before K4a-i lands or after | no |
| K8 | A checked node's started-over vault (the switch-on list's third item): no wait for the app's key on a checked start; the file that didn't open set aside before the first save under the keeper's key, **only once a key was obtained from the keeper and the file failed to open with it** (a host with no key exits before) | `HostJournalTests.aStartedOverNodeVaultSavesAndSetsTheOldFileAside`, `HostJournalTests.anAppHostsStartedOverVaultStillWaitsForTheAppsKey`, `HostJournalTests.aHostWithNoKeySetsNothingAside` | here | `5e98c1fc` in v2; J3b | with J3b |

**What each slice waits on, in short** (the review's "What must be measured" and the re-check's slice table, row by
row, after the proof's redesign; the table above says the same): K0 on nothing more (the re-check cleared it, N7
written here); K1 on K0, and K-M4 before it is offered (the store never rested on the token); **K2** (the Mach form)
on K0, K-M1 (g) to (o) and K-M16 here (D1 settled: the kernel's record, not `runs`), all done, so **K2 is buildable
now** (its checks act on no store; K1 is built beside it), and K-M15's launchd half before it is offered; **K3 after
K2** and K1, then K-M10 (on the port: a flood, complex
messages carrying many rights, (d), CPU per message), K-M5 and K-M15 before it is offered; **K4a-i** on nothing
(behaviour-preserving, **buildable now**); **K4a-ii** (the Mach form, with the proof review's I3, D6, D7, N3 and N5
written in) on K4a-i and K-M1 (n), done, and before it is offered K-M14, extended as the narrow re-check lists and now
with the host's own image started with a bootstrap port that isn't launchd's (its port drained), a fileport's round
trip, **and K-M16's trial part** (A for the child) (N1's rule, N4's four answers and N4 (b)'s four sentences are
written here; KP20f is settled: the by-path handover kept); **K4c** (the handover keeper in the Mach form, with I3, D6
and D7 written in) on K4a-i and K-M1 (n), and before it is offered the same K-M14 part and K-M16's trial part; **K4b**
on K0, K4a-i and **the redesigned K4a-ii on v2** (the lead's ruling: it names K4a-ii's commit as the floor its own
install script checks, KP6b); **K4** (with I2's first statement, D4, D5, D6 and N4 written in) on K3, K4a-i, K4a-ii
and J0a, with K-M5 and K-M10 (c) for its retry loop, and **offered only after K-M15 and K-M16's trial part** (and, if
the trial leaves a route of A open, the fallback's check); K5 on K3, K4b on v2 (the format and the floor check, which
K5 raises to K4b's commit: the lead's ruling) and K-M13's here part (collision detection included), and its real use
on K7's K-M7, K-M9 (`bootout`'s timing), K-M12, K-M13's root part, K-M15 and K-M16's trial part; K6 on K4 and K-M10
(c), `status`'s Login Items line on K-M12; K7 on K5, at your keyboard, with K-M2, K-M3, K-M6, K-M8, K-M9, K-M12, K-M13,
K-M15, the real record's read-only look, and the fallback's check if K7a left a route of A open; **K7a** (K-M16's
trial part) on nothing: at your keyboard, any time, on scratch images; K8 on `5e98c1fc` in v2 and J3b. **Nothing that
gives a host the node's key is offered before K-M15 and K-M16's trial part** (K4's client and K5's real install are
the two that do). **"On v2" and "offered" are different waits:** a slice is on v2 once it is merged there (the node
stays off behind `isCheckedMacNode` and the rest, so nothing of it reaches you); it is offered once it is switched on
for you. K4b waits on K4a-ii being **on v2**, not offered, so the waits make no loop: K4a-ii lands, K4b and K5 land
after it, and K7a, which waits on no slice, settles what K4a-ii's, K4c's and K4's offering wait on. K4a-i, K4a-ii and K4c
are homed in the Mac node spec's order of work (steps 10 and 11), the node's removal there too (step 12, after K5),
each with its own review. **The switch-on review** (row 15, the lead) waits on every slice here, K4a-i, K4a-ii and
K4b included, on the Mac spec's removal step (it checks that nothing removes the node without the keeper's removal),
and on K7's trial with every K-M row it owes and its look at the real record. K-M11 gates nothing (F15).

**The journal's slices with the keeper:** J0a, J1, J2, J6, J9a and J11 may still be built now (the lead's decision of
2026-11-27). **J3a** after J0a and J2 (the re-check of 2026-11-27 found it safe to build on the in-memory seam); its
keeper arm after K4, which waits on K3, K4a-i, K4a-ii and J0a (no J-M2). **J3b** after J3a, its words corrected for
the keeper (F13); its keeper arm after K4. **J4a** and **J4b** after J3a's seam, as before. The rest as the journal's
build order says. **Nothing switches on** until the switch-on review (the measurement table's row 15), by the lead.

## Measurements owed

K-M1 and K-M16's here part were run for this design; the rest are owed. "Here" needs no `sudo` and no dialog; "trial"
is K7, your `sudo` line and your keyboard.

| # | What | Why it matters | Where |
| --- | --- | --- | --- |
| K-M1 | **Measured 2026-11-27, both parts.** **Second part (g) to (o)** (the record's "K-M1, second part"): a failed write or read stamps the token with no byte ((j), (g4), (g5)), so a nonce round and a keeper-made end are each defeated ((g4), (m)); a Mach message's trailer is fixed at its send ((n2): sent before an exec, refused; (n4) another task named as itself; (n5), (n6) the exec'd and the spawned image named and accepted); registered ports don't reach a forked child ((n0)), the bootstrap special port does across fork, spawn and exec; `SCM_CREDS` refused ((o)); the end of file in flight, 14 to 172 of 200 runs when the sender closes early (K-M1's runs, the proof review's and this round's), none when it waits ((l)). **First part** ([the record's K-M1 row](../../process/v2-mac-measurements.md), from `v2-mac-keeper-k0` `7860d50d`): **the premise is refuted**, the token is read live ((a) a forked holder, (b) the exec'd image, accepted by Security, (c) a third process that reads); only a token kept from before the exec is refused; (d) as assumed; (e) a closed end's token refused, `POLLHUP` no test; (f) the connection's last writer. What was owed: a received pair end's `LOCAL_PEERTOKEN`: that it names the pair's maker as it was at the making after (a) a forked child of the maker writes and reads on the maker's end, (b) the keeper itself reads and writes on its end, (c) a third process holding a copy of the maker's end reads, **each with the token asked after the maker's exec** (KP10's exact order: the review's F6, since the Mac spec's result is kept only as a sentence); and that Security refuses it (`SecCodeCopyGuestWithAttributes`) once the maker exec'd, also into a pinned hardened image. (d): that `getsockname` and `getpeername` give no path on both ends of a `socketpair`, and the listener's path on one side of a connection made by `connect` and `accept`, also after the listener's path is unlinked; and that nothing else makes two connected stream ends unnamed on both sides. **(e)** (F5, F1 (c)): what `LOCAL_PEERTOKEN` read again on the received end returns after the other end's `close`, after its `shutdown(SHUT_WR)`, and after a former holder's `shutdown(SHUT_RD)`; and whether `POLLHUP` tells a closed other end from a half-closed one. **(f)**: a connection's token after a process holding a copy of the connecting socket writes last (how far the hello's sender check narrows: Doubts 12). **Kept:** the probes and their output as a row of the measurement record, which this design and the Mac spec then cite | the proof (KP9a, KP10, KP11, KP20c) and K4a's child proof: if the token moves, or a pair's end can't be told from a connection's, the pair proves nothing (it does move: the Mach form was taken, not XPC's peer requirement, which this cell named before the measurement); (e) decided how the pair's step 5 would tell a closed other end (struck with the pair) | here: probes beside `scripts/mac-measure/probes` (`token-exec`'s shape, M7), with the handover keeper's own pairs as the positive control |
| K-M2 | **Replaced by K-M15** (the proof after K-M1: no socket): that the keeper's reply's trailer names root (euid 0) running the installed cdhash | the host's check of the keeper (KP17) | trial |
| K-M3 | That a LaunchDaemon with `RunAtLoad` listens before a login's LaunchAgents start, how long after boot, and how launchd throttles and gives up on a daemon that keeps exiting | the start's 60 s wait (KP26); the words of KP28 | trial, with a restart |
| K-M4 | The time of one durable store write on APFS (`fsync` and `F_FULLFSYNC`), and whether `rename` then the folder's `fsync` survives a power loss as assumed | KP3's "on disk before the answer" | here, on a scratch folder |
| K-M5 | One request end to end (the message, the kernel's record by its token, the pins walk, the store's write, the reply) on this Mac, calm and under `scripts/test-under-load.sh` | raises are rare, but the start and each guarded change wait on it | here; again in the trial |
| K-M6 | On a root-owned `0600` socket with an access entry (`chmod +a "user:<name> allow write"`) for the account alone: whether `connect` honours it (the account's allowed, another uid's refused), and that the account can't change the root-owned socket's mode or entries | KP7, KP7a | trial, with another account (keyboard) |
| K-M7 | `codesign -d -a <arch>` run as root on the root-owned copy gives the install's cdhash | the root half's check (KP21) | trial |
| K-M8 | Whether Time Machine copies `store/node.keep` by default, and whether a sticky exclusion set by root holds | Open questions 2 | trial |
| K-M9 | That your account can't `launchctl bootout`, `disable` or `kill` the keeper's daemon, nor `kickstart -k` it; and whether root's `launchctl bootout` returns only after the job's process has exited (F8: else the step waits for the pid itself) | KP18, KP3a | trial |
| K-M10 | **On the keeper's port, after the proof's redesign:** the keeper's memory, ports and CPU under a flood of malformed messages and of exact-form requests from sessions (Security's check and a pins walk each); **(b)** (F7, Mach's form) its port and memory count after complex messages carrying 2, 64 and the most rights and regions one message can carry, each destroyed; **(c)** a full queue: whether a send waits or fails, and for how long. (The socket's (c), a full backlog, went with the socket.) **(d)** (the re-check's N3) whether a process of your account can make a root process's `open` fail (a full system file table, `ENFILE`, across processes of your account), which the design assumes it can | KP16a, KP19, the connect's deadline (F9), K6's limit; (d): only whether `readError`'s words are ever reached at will (they are written as if they are) | here, under `scripts/test-under-load.sh` |
| K-M11 | Whether signing the genuine host's file again (ad hoc, or with the local identity) gives another cdhash | **information, gating nothing** (F15): either it is other code, refused, or the same cdhash, the genuine code | here, on a scratch copy, nothing installed |
| K-M12 | Login Items (F10): whether an ad hoc LaunchDaemon runs at boot without your approval, how System Settings › General › Login Items names it, whether turning it off there needs an administrator (and whether a program of yours can script that), and whether macOS shows a notice naming it when it is installed | KP18a; K6's `status` (whether it lists Login Items among the places to look; the start's merged words carry no login-item sentence, N6); K5's real use and the switch-on | trial |
| K-M13 | The keeper's root build (F2): that `swift build` of `Keeper/` under `env -i` with its caches in the build folder builds offline and touches nothing outside it (here, as the user, on a scratch folder; then in the trial as root); that two builds of one tree give one cdhash (whether the unchanged-source check can ever answer "already this build"); how long it takes as root; and that the hash check root runs (root's own `git`, `index-pack --strict`) refuses a changed object and detects a SHA-1 collision attack: the exact `git` root runs under `env -i`, its `git version --build-options` naming the SHA-1 backend (`sha1dc` expected, not asserted), and its `index-pack --strict` refusing a published colliding pair; and whether it takes a pack without the commit's parents or needs the whole history as a bundle (the re-check's question 1: if it doesn't detect, the step refuses and K5's real use waits; no fallback reader) | KP21, KP23a, Doubts 14 | here, then trial |
| K-M14 | **K4a-ii's cost** (the re-check's N4 (c)): the time of a session start, a history read and an app connection on this Mac, before and after K4a-ii (the child's proof by the kernel's record by its token, KA11, the launcher written afresh at each host start and its first exec, N1's pins read in a pinned image), calm and under `scripts/test-under-load.sh`; and the proof's own time under that load, against K4a-ii's 10 s limit. **Extended (the narrow re-check of 2026-11-27, N4 (b)):** the parser spawn's own time (`posix_spawn` until it returns) after a fresh launcher write, calm and under `scripts/test-under-load.sh`; a launcher replaced by a copy carrying the quarantine attribute (how long its exec blocks); whether your account can mount a volume without an administrator, and how long an exec of a launcher linked to a file on it blocks once the volume stalls; and a burst of never-proving history reads, against the time of another client's request and of the server child's restart (which sets the cap on spawns in flight, 4 until then). **And** (the proof review's N5) the child's bootstrap port drained until the child exits, every message counted, so "sends nothing before its proof" is shown, not read off one receive | whether the proof is affordable at every session start, whether its limit holds under load, and whether the spawn's move off the host's queue and the no-thread wait hold what N4 (b) claims (N4 (b) and its four sentences) | here, before K4a-ii is offered |
| K-M15 | **The Mach form's launchd half** (the proof after K-M1): with the trial's keeper as a LaunchDaemon whose plist names `MachServices`, that a process of your login session finds it by `bootstrap_look_up`; that a LaunchAgent of your account naming the same service in your own domain is found first or not (the host's check of the first reply refuses it either way, KP17; D5's "something answers in its name" words); that the keeper's reply's trailer names root running the installed cdhash, read by the user's host through the kernel's record (`csops_audittoken` on a root process's token, as the user); that launchd holds the port and queues sends while the daemon is down (N2, D5: busy and not running one state); whether `bootstrap_register` (or its successor) of a send right your account holds still works in your domain, putting another root process's port under the name (D4); the port's queue limit and what a send does once it is full (waits until its timeout, or fails); one request's time end to end; and the keeper's own `csops_audittoken` as root on a user's token (Doubts 7) | the interface's steps 1, 2 and 5; KP7a, KP17, KP19; K2's offering, K4's | trial (K7) |
| K-M16 | **Assumption A** (the proof round's blind check; widened by the proof review's I1). **Here, measured 2026-11-27** ([the record's "K-M16, here"](../../process/v2-mac-measurements.md)): task-level exception ports a parent names cross into the hardened image, every behaviour and mask (p1, p2, p4); thread-level ones don't cross an exec (p3); a launcher's limits force `SIGSEGV` (a 16 KiB stack) or `SIGABRT` (4 descriptors, none free) before the first statement ((q2), (q3), (q4), (q6), each without the first statement's marker); the window is 1 to 6 ms (w1, w2); the one-call clear of every mask works, task and main thread; and D1: Security's `runs` reads the sender's file at its path, not its pages, while the kernel's record by the token opens nothing and refuses a stale token ((d1) to (d3)). **Trial part, owed:** (1) a fault from the window, and one after the clear, delivered or not to a handler the parent named; (2) a state reply moving the faulting thread or not; (3) a crash or corpse message's port reading memory or not; (4) a task port handed over before the exec, live or dead after it; (5) a traced exec refused or marked `CS_DEBUGGED`; and, if any stays open, the fallback's check (launchd's record of the node job's process and the kernel's of the process, as root) | the interface's A; KA1 to KA12; K4's offering, K4a-ii's, K4c's, K5's real use | here (done); K7a, at your keyboard, waiting on no slice: each of (1) to (5) acts on another process's exception, registers, task port or tracing, which an agent's session doesn't run (the lead's ruling of 2026-11-27); the fallback's check, if needed, in K7 (as root) |

## Open doubts

1. **The proof's primitive.** A socket pair's token proved nothing (K-M1: it names the last to send, receive or poll
   on the other end, as it runs now, and a failed act stamps leaving no byte, (j), (g4)); the proof is now the Mach
   form, each request judged by its message's audit trailer, fixed at the send (K-M1 (n)). What still rests on
   reading rather than measuring: that libsystem's `bootstrap_check_in` and launchd give a root daemon's name to your
   login session's lookups and how a same-named service in your own domain is ordered against it (K-M15, trial); that
   a full port queue makes a send wait (K-M10 (c) on the port). The client's check of the first reply makes a wrong
   answer to either a denial, never a served request.
2. **The key travels in clear in the `open` reply**, a Mach message the kernel copies to the task holding the reply
   port's receive right, which is the requesting host (its own port, made per request). That rests on the host's code
   never giving that receive right away and on assumption (A) of the interface (no session reads the host's memory
   through an exception or corpse port: closed after its first statement by the clear, measured; open before it until
   K-M16's trial part). Sealing the answer to a fresh key the host makes per request would add nothing against (A),
   which reads the key wherever the host holds it.
3. **The keeper can't tell the genuine host's modes apart**, and serves every pinned build. J0a's rule 2 and the
   unswitched-build rule carry it, as they carry the Keychain today; a mode added later that calls `NodeAnchor` breaks
   it, and only J0a's test would catch it. What a pinned image's other modes hand out is N1's rule (KP20d); a test
   flag or a mode added later that gives a pair end to code a session names breaks that, and only K4a-ii's tests and
   the pair lint would catch it.
4. **It runs as root, unsandboxed.** A sandbox profile, or a dedicated system user owning `store/`, would narrow what a
   bug in it reaches; not taken (more install, more to measure). Its input from your account is one Mach message
   received into a fixed buffer (no `MACH_RCV_LARGE`) and, for one of the exact form, the kernel's record by its token
   before anything else is read; it opens no file of the sender's (D1).
5. **Denial by your own account** against the serial keeper (KP19): a flood keeps the node from starting, refuses
   guarded changes, and through them keeps the journal's P36 (an uncounted revocation undone by a put-back) and P42
   (a file ahead, devices held) reachable at will, as the locked keychain did. Accepted as the journal's stated limits
   were; a keeper serving connections side by side would raise the flood's cost, not end it. Bounded resources are
   claimed, not measured (K-M10).
6. **`noCounter`** stays a "Fail closed" row though only root can reach it (a key without a `journal` slot while a
   file exists): kept, since a fail-closed row costs nothing.
7. **The kernel's record by the token from a root process** of a process of another uid (the caller), and from the
   user's host of the root keeper's reply, is assumed to behave as it does between processes of one account (K-M16
   here, (d1) to (d3), as the user): **not measured** across uids, covered by K2's tests run as the user and by K7
   (K-M15). The keeper no longer asks Security (D1), so Security's own behaviour from root no longer matters to it.
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
12. **Telling a pair's end from a connection's** is no longer asked: the keeper takes no socket end (K-M1 (d) stays in
    the record as measured).
13. **A pair end the pinned image hands to code that hasn't proven itself** (KP20a, the review's F1) no longer reaches
    the keeper; it exposes the host's own data (a session's terminal output, the connector, the handover's state). K4a-ii
    and K4c prove a child by a Mach message and hand it ends as fileports to its own port; what rests on reading, not
    measuring: that the host's Swift image, started with a bootstrap port that isn't launchd's, sends nothing there
    before its proof (K-M14, extended), and the fileport's round trip.
14. **The root build's tie to the commit is git's object hashes** (SHA-1 in this repository): root recomputes each and
    requires them to lead to `COMMIT`, but a chosen-prefix collision would let objects of a session's making hash as a
    commit that passed CI. Root's `git` must detect a collision attack (git's `sha1dc`), or the step refuses; K-M13
    measures it (the backend `git version --build-options` names, and `index-pack --strict` refusing a published
    colliding pair), and K5's real use waits on it. The fallback reader is dropped (the re-check's question 1: it
    could only recompute hashes). Once detection is measured present it is enough for this threat: a useful collision
    also needs its benign twin merged through review and both CI runners on v2, and any second tie would have to cover
    the commit object and the top tree too, with none found that ties to the CI'd commit without SHA-1 and GitHub.

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
   lint (K4a, [The host's side](#the-hosts-side)), and (the re-check's N1, the lead's ruling) a pinned image gives pair
   ends only to its own code, its row's server, or across the checked node's own switch a target the record pins, with
   its test flags and by-path handover refused (KP20d, KP20e). The command line read as root is not taken (it was the
   re-check's alternative (B) for N1, not chosen); were the lead ever to
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
| **F5** (Doubt) step 5's token | **adopted, then struck by the proof after K-M1** (the proof review's N1): the token read afresh from the received end, equal to the first, a closed other end refused; K-M1 (e). Under the Mach form no socket end reaches the keeper and no token is read again | The interface, step 5; KP20c; K-M1; K2 |
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
| KP20c (a genuine end whose holder closes after writing) | adopted, then **gone** with the socket under the Mach form (the proof review's N1): no socket end reaches the keeper | KP20c |
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

## Re-check of 2026-11-27: the answers

The re-check of `8a2f13ea` (`RECHECK-keeper-design.md`), each new finding and each answer to the design's open
questions, with what this branch changed and where. The lead's rulings of 2026-11-27 decided N1 to N4 and the four
questions; the readings the lead accepted on N1's extension and N2's close are said as such.

| Finding | What changed | Where |
| --- | --- | --- |
| **N1** (Important) in a host a session starts, the server child and a `--handover-test-keeper` keeper are "proven" against the session's own program | **A pinned host image never gives an end of a pair it writes on to code other than its own or its row's pinned server, in any mode** (the lead's ruling), with **one named extension the lead accepted**: across the checked node's own switch only, a target host the same record pins, proven by its token against that row, both rows at or after the floor, the target itself a pinned image under the rule (without it the ruling's words would forbid the checked node's own switch, whose handover keeper and new image run the target build's cdhash: `keeperTarget`). Pinned is read as the keeper reads it (hardened, its own cdhash a `host` row, the record read afresh before each handout, nothing from arguments or environment; a failed read refuses the handout). A pinned image's server child is its row's server in every mode (a `--server` that isn't is refused before the spawn; the proof against the row's cdhash; each app connection checked against the record again); `--handover-test-keeper` and `--handover-test-secret` refused at the start and at a switch; the by-path handover refused; so every switch form is refused in a pinned image's non-checked modes. The property is now stated that way in the host's side, the call-site table and the threat table | The host's side (its fourth rule, K4a step 2, the new rule after K4a's tests, the call-site table's `AppConnector.swift:123`, `:286`, `HostHandover.swift:315`, `MacHandoverKeeper.swift:141`); For you ("What it doesn't", last bullet); the threat rows "Copies the node" and "Talks to the keeper"; **KP20d** (the server child and the test keeper) and **KP20e** (the extension) in Every path to the property; Doubts 3, 13; Open questions 8; build order **K4a-ii** with N1's tests (`aPinnedImageGivesNoPairEndToCodeASessionNamed` for the server child, `aPinnedImageRefusesTheTestKeeperAndItsSecret` for the `--handover-test-keeper` keeper, and four more). **This round's blind check found one more path** (a build run by a session in the install window, before its pins step, would keep the ends it gave out then, served once pinned): closed by the lead's choice (A), the rule keyed on "hardened" (a hardened image that isn't pinned hands out nothing), its cost stated (the hardened arm of `MacKeeperHandoverTests` to function level and K7); (B), a row's write time against the maker's start, rejected (the checked switch execs in place) | **KP20f** too |
| **N2** (Important) builds pinned before K4a carry F1's gap whole, and the keeper serves every pinned build | **Three rules** (the ruling, and the close the lead adopted): the setup's pins step in its existing `--build … --fresh` form, the same record `--keep 1` leaves, in the pins step's own `sudo` (no third password), said before the password; **the floor** (K4b's commit on v2), refused by the install at the setup and after, `git merge-base --is-ancestor` in its fresh fetch (every update runs the installed build's copy of the script, so it checks; **amended by the narrow re-check**: a script from K4b up to K5 had no check, so the floor is K4a-ii's commit, checked by K4b's own install script: [below](#narrow-re-check-of-2026-11-27-the-answers)); **the pins record's `format 2` from the floor on**, which pre-floor pins steps refuse whole and the keeper alone reads, so a first-form install of an older commit (run by that commit's own script once `current` is deleted) writes no served row. Costs stated (no build from before the floor installed or started as the node again; going back needs an administrator); what stays under "the choice of commit" stated (commits at or after the floor; a rewritten install script, S1's class); the general rule beside the `--keep 1` lever. K7's read-only look at this Mac's real record (owed: not made here) | Install, update and removal ("Only builds at or after the floor are ever served", "Order at setup"); How this relates to rows 7 and 10's record (the general rule); For you ("Setup"); the threat row "Copies the node"; **KP6b**, KP6, KP14, KP22; build order **K4b**, K5 (`theSetupKeepsOnlyTheBuildItInstalls`, `anInstallRefusesACommitBeforeTheFloor` and the rest), K7 |
| **N3** (Doubt) the password rule rests on a classification of read failures the design didn't make | **Three kinds, and no other**: `damaged` only when read whole and refused (parse, owner, mode, ACL, link, uid); `ENOENT` alone is missing for the store and "not installed" for the plist and program; every other failure is `readError`, worded like busy, making no key, never mentioning a password, the setup line or an install. The same split for the pins record (`noRecord` only when missing or read whole and refused) and for K6's walk. K1 gives the walk's refusal a kind. Whether your account can make a root `open` fail is K-M10 (d), written as if it can | What it stores ("What a failed read of the store is"); The interface, step 5 (the statuses); While the keeper is down (the rule, the new `readError` row, the running host's rows); For you (the password sentence); KP4, KP19a, KP25, KP29a; K1 (`aReadErrorIsNeitherDamagedNorMissing`, `aReadErrorMakesNoKey`), K4 (`aPinsReadErrorIsNotNoRecordAndNeverMentionsAnInstall`), K6 (`aWalkThatFailsOtherThanENOENTIsntNotInstalled`); K-M10 (d) |
| **N4** (Doubt) K4a left open three things that decide whether it is safe to build | **(a)** hardened is keyed on the code's own signature: the child must be hardened exactly when the image is, never on an argument, the environment or a parcel; extended to the handover keeper's proof by KP20f's choice; **(b)** the proof waits off the host's queue, at most 10 s, holding only the session start or history read that needs it; **(c)** its cost per session start, history read and app connection (N1's pins read included) measured as **K-M14**, calm and under load, before and after, before it is offered | The host's side ("Three things the child proof states before it is built"); K-M14; build order K4a-ii (`aChildIsHardenedExactlyWhenTheImageIs`, `aProofThatNeverComesHoldsNothingElse`; K-M14 before it is offered) |
| **N5** (Nit) the store's lock against the socket | the lock is taken before anything in the folder is touched; a second keeper exits having touched nothing | What it stores (`store/lock`); KP3a; K3 (`aSecondKeeperLeavesTheFirstsSocketAlone`) |
| **N6** (Nit) the merged state's last sentence can be false | "…either a program on your Mac keeps it busy, or it keeps stopping", no login-item claim; that sentence kept on the busy row alone | While the keeper is down (the merged words); KP19a; K6 (`theMergedStateNamesNoLoginItem`) |
| **N7** (Nit) where the keeper's own tests run | `Keeper/` declares no test target; its tests stay in the root package's test targets, which `scripts/test.sh` runs; the package lint checks there is no test target | Its program; K0 |
| **N8** (Nit) the remedy doesn't say to stop what did it first | every copy of the remedy begins with "stop your sessions and what they started" | For you ("What it doesn't"); the threat row "Edits the build"; What it does (`open`); KP6a |

| The design's question | Answer written in | Where |
| --- | --- | --- |
| **1.** Is collision detection in root's `git` enough? | K-M13 measures it with the exact `git` root runs (`git version --build-options` naming the SHA-1 backend; `index-pack --strict` refusing a published colliding pair); **the fallback reader is dropped**; if root's `git` doesn't detect, the step refuses and K5's real use waits; once present, detection is enough for this threat | Install (condition 1); Doubts 14; K-M13; K5 (`theStepRefusesWhenRootsGitDoesntDetectACollision`) |
| **2.** Which slice owns the node's removal (F18)? | **the node-removal slice**, the Mac spec's step 12 (stops the agent first, then the keeper step's `--remove` or `--remove --forget-store`, said before the password), with `theNodesRemovalRemovesTheKeeper`; K5 keeps `--remove` and its own tests; the switch-on review checks it | Install, update and removal ("The node's removal runs the keeper's"); KP27; K5; the waits-on paragraph; the Mac spec's order of work, step 12 |
| **3.** Where does K4a belong? | **K4a-i** (every spawn `CLOEXEC_DEFAULT` with its lint, behaviour-preserving, waits on nothing) and **K4a-ii** (the child proof, with N1's rule and N4's answers; waits on K4a-i, K-M1's row and K-M14), homed in the Mac spec's order (steps 10 and 11), each with its own review, listed in the keeper's build order because K4 and K4b wait on them | The host's side ("The change, K4a"); build order; the waits-on paragraph; the Mac spec's order of work, steps 10 and 11; the journal's J3a and J3b waits |
| **4.** Is the fourth pair class sound? | **Yes, and held by a type**: `HandshakeEnd` exposes a channel's and a proof pair's end only through `sayHolding` and `sendDescriptor`, never a raw descriptor; the lint checks every channel and proof pair is one (`everyChannelAndProofPairIsAHandshakeEnd`) | The host's side (above the call-site table); KP20; Doubts 13; K4a-ii |

**Also from the re-check's tables, taken:** `TCP.swift:144` named beside `EgressProxy.swift:418` in F1 (c)'s
candidate lint; K5's user half reads the `Keeper` tree id from the install's fresh fetch with
`GIT_NO_REPLACE_OBJECTS=1` (F2's note); K-M10 (b) may already be answered by `SocketDescriptors+Darwin.swift:62-66`'s
recorded measurement (F7's note), cited or run again in K2.

**Not closed, said plainly:** under "the choice of commit", any commit at or after the floor on v2 with both runners
green is installed and served, and a rewritten install script (or a pins step of a session's making run with your
password) writes any row: S1's class, as before. KP6a (F3) is unchanged, accepted by the user. Every K-M row stays
owed (none was run), and the narrow re-check should attack first N1's extension (KP20e), then KP20f (a hardened image not yet
pinned, keyed on "hardened"), then the floor's format close (KP6b), then N4 (b)'s wait. **KP20f's cost:** until K7,
this Mac doesn't run a hardened host's switch end to end (`MacKeeperHandoverTests`' hardened arm); K7 carries it.

## Narrow re-check of 2026-11-27: the answers

The narrow re-check of `654c241c` (`RECHECK2-keeper-design.md`), limited to four points, and the lead's ruling of
2026-11-27 ("v2 keeper design, after its narrow re-check"), which adopted the reviewer's four changes and ended the
design's review rounds. Each change, and where the body now says it:

| Point | The re-check's verdict | What changed | Where |
| --- | --- | --- | --- |
| **KP20e** (N1's one extension, the checked node's own switch) | closed | Nothing of its own. Its "both rows at or after the floor" now reads "both rows' commits contain K4a-ii", since a commit between K4a-ii and K4b can hold a row of a format-2 record (KP6b's change; that image refuses every handout, its `NodePins` reading only `format 1`) | The host's side (N1's rule, 3); KP20e; Install ("Rows a format-2 record can hold") |
| **KP20f** (N1's rule keyed on "hardened") | closed with changes; **its by-path point settled by the proof after K-M1** (the keeper takes no socket end, so the by-path end carries no request; the by-path handover of a hardened unpinned image is kept, the app's host keeps its handover at every app update, its test `theAppsHostStillHandsOverByPathAtAnAppUpdate`) | (Before the redesign:) **The by-path point is written as open, not as ruled** (the lead's instruction of 2026-11-27, after K-M1 was measured): the ruling dropped rule 5's by-path refusal because "the by-path end is already dead after the in-place exec, resting on K-M1"; K-M1 as measured refutes that ground (a token read after the maker's exec names the exec'd image and Security accepts it). Both facts are side by side in the body: the refusal as the second fix round wrote it would refuse **the Mac app's own host** (hardened, never pinned) at every app update, ending its sessions; dropping it rests on the refuted premise. The proof's redesign settles it, under the stated constraint that the app's own host keeps its handover at every app update (the candidate test `HostChildProofTests.theAppsHostStillHandsOverByPathAtAnAppUpdate`). The two parts that don't rest on the token are in as ruled: **no exemption is keyed on `ownsLaunchers`** anywhere (a session sets `VIBESWITCHER_HOME`), and **`parentRefusal`'s hardened check follows "exactly when"** beside `refusal`'s, so the switch's tests run on unhardened scratch hosts (`.aHandoverKeeperRequiresItsParentHardenedExactlyWhenItIs`). Pinned images still refuse the by-path handover (rule 4) | The host's side (N1's rule, 5; "Open: the by-path handover of a hardened image that isn't pinned"; its cost; N4 (a)); the call-site table's `HostHandover.swift:315`; KP20f; K4a-ii (row, tests, waits on the redesign); the waits-on paragraph; the Mac spec's step 11 |
| **KP6b** (the floor by the record's `format 2`) | not closed | **K4b's own install script refuses, unconditionally, any commit that doesn't contain K4a-ii's commit** (`git merge-base --is-ancestor` in its fresh fetch, beside step 6), so the floor check lands in the format's own commit and no script whose pins step writes `format 2` lacks it; the floor is K4a-ii's commit, and K5 raises it to K4b's (the lead's ruling of 2026-11-27). The re-check's sequence (a K4b-to-K5 script, installed or faked through `current`, installing a pre-floor commit into the format-2 record) is listed as **KP6c**, closed by that check, with its tests: `KeeperStepTests.aPreFloorCommitInstalledAfterAK4bToK5CommitWritesNoRow`, `.currentPointedAtAFolderOfSuchACommitsPublicFilesChangesNothing`, `.everyInstallThatWritesFormat2RefusesACommitWithoutK4a`. The general rule: a format bump and the install's floor check land in one commit, the floor naming an ancestor. Its cost (this edit's blind check): a rollback to a commit between K4a-ii and K4b leaves the node not starting and its updates refused, until an install of a commit from K4b on in the first form; K5 raising the floor to K4b's commit (recommended) closes it | Install, update and removal (rules 2 and 3, "Rows a format-2 record can hold", the general rule); KP6b, KP6c; K4b (row, tests, after K4a-ii on v2), K5; the waits-on paragraph; the Mac spec's step 11 |
| **N4 (b)** (the child proof's wait off the host's queue, 10 s) | closed with changes | **Four sentences in K4a-ii**: the parser's spawn runs off the host's queue, each on a queue of its own, with the 10 s limit counted from its dispatch (a spawn that never returns is a timeout) and at most 4 spawns in flight per host, since a spawn blocked in `posix_spawn` holds its thread whatever the design does (the server child's alike); the child ended at the limit off the queue and reaped by a process-exit source, never a blocking `waitpid`; a proof's wait is a read source and a steady-clock timer on its own queue, holding no thread; a proof that only timed out gets words that accuse nothing ("the helper didn't answer in time"). Tests: `.aSpawnThatBlocksHoldsNotTheHostsQueue`, `.aSpawnThatNeverReturnsIsRefusedAtTheLimit`, `.spawnsInFlightAreCapped`, `.theReapAtTheLimitNeverBlocksTheHost`, `.proofsInFlightHoldNoThreadEach`, `.aProofThatOnlyTimedOutAccusesNothing`. **K-M14 extended**: the spawn's own time after a fresh launcher write, calm and under load; a launcher replaced by a quarantined copy; whether your account can mount a volume without an administrator and how long an exec from it blocks once stalled; a burst of never-proving history reads against another client's request and the server child's restart | The host's side (N4 (b) and its four sentences; the words for a failed proof); K4a-ii (row and tests); K-M14; the waits-on paragraph; the Mac spec's step 11 |

**K-M1, measured the same day, and what it changed here** (the lead's instruction of 2026-11-27): the premise that a
pair's token is fixed at the making is refuted ([the record's K-M1 row](../../process/v2-mac-measurements.md)); the
status line and the first page carried the notice; every sentence that rested on it was marked, then rewritten or struck
by the proof's redesign (next section); K2, K4a-ii and K4 waited on the proof's
redesign (K4 no longer buildable as the design stands; K3 too, through K2); K1 and K4b's install refusal don't rest
on the token and stand as written, but K4b's floor names K4a-ii's commit, so K4b can land only once a redesigned
K4a-ii is on v2 (not "buildable now": a point for the lead).

**Not changed, said plainly:** no other redesign; the re-check's remark on KP20e (rule 1's "afresh before each
handout" against `keeperTarget`'s one read at the switch's ask: only root moves the record in between) needs no
change and has none. What stays open is as before: the choice among commits at or after the floor, a rewritten
install script (S1's class), KP6a (accepted by the user), every K-M row owed, and KP20f's cost until K7.

## The proof after K-M1: what changed

For the independent security review that follows (2026-11-27, branch `v2-mac-keeper-proof`). **Attack first:** the
interface's candidate C, steps 2 and 4 (the client's check of a looked-up port, and the keeper's judgement by the
trailer alone), and KP17 (a fake service in your own domain), with K-M15 the launchd facts they read rather than
measure; then K4c and K4a-ii's use of the bootstrap special port (a Swift image started with a port that isn't
launchd's, K-M14 extended).

| What | Where it is now |
| --- | --- |
| K-M1's second part, (g) to (o): the whole write-then-exec, a silent holder, both orders of a nonce round, a keeper-made end, which acts move a socket's token, the token once the last to act exited, the end of file in flight by count, a Mach message's trailer, `SCM_CREDS` | the record ("K-M1, second part"), the probe (`pair-token.c`, `pair-image.c`, `pair-token.sh`); Measurements owed, K-M1 |
| The proof: three candidates, each with its order, what each check proves, what a session can still do, its cost; A and B rejected on (g4), (g5) and (m); C (the Mach form, raw messages, the trailer read directly) chosen; XPC kept as the second choice | The interface |
| The keeper serving a host | the interface's steps 1 to 5; K2 (the proof), K3 (the program over its port), K4 (the client), each row rewritten with its tests |
| A host proving its children | The host's side, K4a-ii's steps 1 to 3 in the Mach form; K4a-ii's row |
| The handover keeper | The host's side, "The handover keeper … under the Mach form" (open today to K-M1 (b) with the pid matching; what changes); K4c, new; the Mac spec's step 11 |
| KP20f | The host's side, "KP20f's by-path point, settled"; rule 5; KP20f's row; the answers' KP20f row; the Mac spec's step 11 |
| Every path to the property | the channel rows redone, KP10 (write then exec) first, then KP10a to KP10c (a copy-holder, a replay, the reply taken), KP7 to KP19a in the Mach form (KP16 and KP16a folded into KP8), KP20 to KP20f as the host's own ends |
| The threat table's "Talks to the keeper"; Doubts 1, 12, 13; the status line and the first page's notice | rewritten |
| The lead's rulings of 2026-11-27 | K5 raises the floor to K4b's commit (Install, rule 2; K4b's and K5's rows); K4b lands only after the redesigned K4a-ii is on v2 (K4b's row; the waits-on paragraph) |
| The Mac spec | its "fixed at creation" sentence corrected, citing K-M1; step 11 in the Mach form, with K4c |

**What the floor and the format do now, said plainly.** Under the Mach form a session's bytes can't reach the keeper
through any socket end, and a build without the keeper's client (any build before K4) sends the keeper nothing, so
the floor (KP6b) and the record's `format 2` are no longer what keeps a request from the keeper; they keep every
served build one whose children prove themselves (the host's own data), as ruled. N1's rule and the lead's choice (A)
stand as ruled, for the same reason. Whether to keep them is the lead's.

## Proof review of 2026-11-27: the answers

The independent review of `7579879b` (`REVIEW-keeper-proof.md`, 2026-11-27: "sound with changes"; 3 Important, 7
Doubt, 5 Nit), each finding with what this branch (`v2-mac-keeper-proof2`) changed and where. Assumption A was
measured here as far as the probe's own children allow (the lead's ruling of 2026-11-27: only what a hardened child
observes about itself, and D1's timing; the active routes are the keyboard trial's), [the record's "K-M16,
here"](../../process/v2-mac-measurements.md).

| Finding | What changed | Where |
| --- | --- | --- |
| **I1** (Important) K-M16 tested less than A needs: state replies, a fault forced before the clear, a pre-exec task port, a traced exec and thread-level ports weren't listed, and no fallback was named | **K-M16 widened to every route**, each with the case or the rule that closes it, or the trial's item that owes it. **Measured here:** task-level ports a parent names cross into the hardened image, every behaviour and mask (p1, p2, p4); thread-level ports don't cross an exec (p3: closed by a measured fact); a launcher's limits force a fault (`SIGSEGV`, 16 KiB stack) or an abort (`SIGABRT`, 4 descriptors, none free) before the first statement ((q2), (q3), (q4), (q6), each without the first statement's marker); the window is 1 to 6 ms (w1, w2). **Closed by the first statement's rule:** every route after it. **Owed to K7, open until then:** a fault delivered to the parent's handler, a state reply moving the thread, a crash or corpse port reading memory, a pre-exec task port after the exec, a traced exec (K-M16's trial part (1) to (5)), each because it acts on another process, which an agent's session doesn't run. **The rule in force until then:** nothing that gives a host the node's key is offered (K4, K5's real install). **The fallback named:** if the trial leaves a route open, the keeper serves only a host launchd itself started as the node's job from the host's own file, its check measured first; with none, the keeper isn't offered at all (K4 and K5's real install, so no node with its keeper on the Mac) | the interface, assumption (A); Every path, K-M16's row and KA1 to KA6, KA10; Measurements owed, K-M16 (new row); K4's, K5's and K7's rows; the waits-on paragraph; the first page's notice; the record's "K-M16, here" |
| **I2** (Important) A's clear named no mask (the obvious `EXC_MASK_ALL` misses `EXC_MASK_CRASH` and `EXC_MASK_CORPSE_NOTIFY`) and ran after `main` dispatched five modes on `argv` | **the clear is `main`'s first statement in every mode, before `argv` is read**: `EXC_MASK_ALL \| EXC_MASK_CRASH \| EXC_MASK_CORPSE_NOTIFY` to `MACH_PORT_NULL`, on the task and on the main thread, a failure ending the process; measured accepted, one call, leaving every mask null (K-M16 here); its lint (`theClearIsMainsFirstStatementInEveryMode`) and test (`HostFirstStatementTests.theClearLeavesNoHandlerOnAnyMask`) in K4's row, built in K4a-ii (the first slice to land that needs it, its commit the floor) and listed again in K4's; its cost (no task-level handler, the system's pair included, so reports go to the host-level handler; checked in the sandbox) stated | The host's side, "The first statement"; the interface, (A); KA1 to KA3; K4's row |
| **I3** (Important) K4a-ii's children and K4c's processes rest on A but cleared nothing and didn't wait on K-M16; the parser takes `--parser-test-hooks` from `argv` in every image, and its `trap` is reachable from the session's tty | **the same first statement** in every child and handover process (they are modes of the same `main`), before any proof; **a hardened image's parser refuses `--parser-test-hooks`** (exit 64), so the OSC handler is never registered and `ESC ] 7599 ; trap BEL` written into the session's tty is ignored; any other trap after the first statement goes to no session handler; **K4a-ii and K4c are offered only after K-M16's trial part** | The host's side, "The first statement", K4a-ii's (d) "The parser's test hooks", K4a-ii's "Not measured here" (A for the child), K4c's last bullet; KA9, KA10; K4a-ii's and K4c's rows; the waits-on paragraph |
| **D1** (Doubt) `runs` might hash files a session chooses, per message | **measured** (K-M16 here (d1) to (d3)): Security doesn't hash the pages (0.2 ms for a 256 MiB image), **but reads the sender's file at its path** (a rename over it fails the check, `errSecCSStaticCodeChanged`), so a session can make the check fail or, on a stalled volume, hold the keeper. **The keeper judges by the kernel's record by the token** (`csops_audittoken`: the cdhash the process started with and its status word; no file opened, unchanged by a rename, refused for a stale or gone token) and never calls `runs`; "it never reads anything under a user's home" now holds | the interface, step 4; What it does (the never list); While the keeper is down (a flood's cost); KA11; K2's row; Doubts 4, 7; K-M15 (root's call, across uids) |
| **D2** (Doubt) B's `CS_REQUIRE_LV` refuses the genuine ad hoc host, whose word is `0x22011311` (`CS_FORCED_LV`, not `CS_REQUIRE_LV`) | the hardened check is worded on the bits the genuine host has, read from the kernel's word: `CS_VALID`, `CS_RUNTIME`, `CS_HARD`, `CS_KILL`, `CS_FORCED_LV` or `CS_REQUIRE_LV`; none of `CS_GET_TASK_ALLOW`, `CS_DEBUGGED`, `CS_INVALID_ALLOWED`; B's library half is measured (M6; K-M16 here read the same word), not owed to K-M16 | the interface, step 4 and (B); KP15, KA8; K2's row |
| **D3** (Doubt) the floor's rule was written for pair rules only | the general rule covers **every host-side rule the property rests on** (J0a's rule 2, the first statement's clear and environment rule, the hardened parser's refusal, each proof's role, and what K7 adds): a fix reaches the keeper's service only once older rows are dropped, by a floor and a format bump in one commit; the first statement and the roles land in K4's, K4a-ii's and K4c's commits, so every build that can ask the keeper has them | How this relates to rows 7 and 10's record; Install ("Rows a format-2 record can hold", the general rule) |
| **D4** (Doubt) a host pointed at the trial keeper's port would take the trial store's key | **every reply names the keeper's uid and its store (`node` or `trial`)**, and the host requires its own uid and `node`, beside the reply's trailer (root, the node's installed cdhash); K-M15 adds whether `bootstrap_register` of a held send right still works in your domain | the interface, steps 2 and 5; the threat table's "Impersonates the keeper"; KP17; K2's, K3's and K4's rows; K-M15 |
| **D5** (Doubt) under Mach busy and not running are one state, and the host can tell a third | **one state, "installed, not answering"** (the merged words, no login item), and a third, **"something of your account answers in the keeper's name"** (a reply not from root running the node's installed cdhash, or naming another uid or store: a LaunchAgent of your own), with its own words, never the password or an install; K6 tells the same by its own `open` (a refusal from the real keeper is "running") | While the keeper is down (the states, the words, the table); KP17, KP19a, KP28; K4's and K6's rows |
| **D6** (Doubt) environment that steers system libraries isn't covered by B | **refused at the first statement, right after the clear, never reset**: the checked start (`--node`) ends with exit 78 on any variable outside its fixed list (its plist's and launchd's; launchd's names read at K7); a hardened image's parser and handover keeper don't go on with one outside theirs (`PATH=/usr/bin:/bin`, `HOME`, `TMPDIR`, `LANG`): they exec themselves again once with exactly the list before their proof, so a parent of an older build still gets a working child, and every host spawns them with exactly the list; the app's own host (its `host` mode and its by-path handover, which uses no handover keeper) unchanged; what a library reads before the first statement is A's window | The host's side, "The first statement"; the interface, (B); KA7; K4's, K4a-ii's and K4c's rows |
| **D7** (Doubt) proofs bind code at a pid, not a role: a parser's proof could take K4c's parcel | **each proof names its role** (`parser`, `server`, `handoverKeeper`, `newImage`); each receiver takes a proof only for its own role and only its own handout's exact form; today's other modes have no other sink (`HostImages.mayTakeHandover`, `main.swift:233`, `:250`), stated with a test | K4a-ii's step 2; K4c's last bullet; KA12; K4a-ii's and K4c's rows |
| **N1** (Nit) socket-era words | rewritten: the two keepers' shared pattern, the "Impersonates the keeper" row, one request per message, the never list, the store's folder, the start's states and K6's look, a flood's cost, KP27, K6's row, K-M5, Doubts 4, K-M1's last cell; the answers' F5 and KP20c rows say they were struck | the places named |
| **N2** (Nit) step 2's "its receive right never leaves the keeper's task" | launchd holds the receive right while the keeper isn't running and hands it over at check-in (assumed, K-M15); only root ever holds it | the interface, step 2; K-M15 |
| **N3** (Nit) the server's check of its host had no item in K4a-ii | the server judges its host by **the handout's own message** (its trailer's pid running a row's host, hardened, by the kernel's record), the Mach form of `NodeCheck.macConnectorRefusal`, with `theServerChecksItsHostByTheHandoutsOwnMessage` | K4a-ii's step 3; K4a-ii's row |
| **N4** (Nit) the client should destroy what it refuses; the keeper should receive without `MACH_RCV_LARGE`; out-of-line ports are copied in before any check | written: every refused reply destroyed; the receive into a fixed buffer without `MACH_RCV_LARGE` (an oversize message is destroyed by the kernel); out-of-line ports copied before any check, counted by K-M10 (b) and released by the destroy | the interface, steps 2, 4 and (C); K2's, K3's and K4's rows |
| **N5** (Nit) "sent nothing else in (n5) and (n6)" wasn't shown (one receive per trial) | reworded; K-M14 drains the child's bootstrap port until it exits and counts every message | K4a-ii's "Not measured here"; K-M14 |

**The routes this round lists by which a session could run its own code inside the genuine image, and where each
stands** (the review's and this round's; **not shown complete**: the adversarial check of the list's completeness was
stopped by the model's safeguards before it answered and, by the lead's ruling, not run again; the keyboard trial,
K7, examines the open routes and the list itself): task-level handlers (KA1: measured to cross; closed after the first
statement by the rule), thread-level handlers (KA2: closed by a measured fact), crash and corpse handlers (KA3: as
KA1), a fault forced in the window and a state reply (KA4: open until K7), a pre-exec task port (KA5: open until K7), a
traced exec (KA6: open until K7, refused by the status word if the kernel marks it), environment (KA7: closed by the
rule after the clear; before it, KA4's window), injected code (KA8: closed by a measured fact), the parser's test hooks
(KA9: closed by the rule), the children and handover processes (KA10: the same first statement), the check that read a
session's file (KA11: closed by the rule), a proof for another role (KA12: closed by the rule).

**Still open, said plainly:** KA4, KA5 and KA6, until K-M16's trial part at your keyboard; whether the list KA1 to
KA12 is complete (no adversarial check of it was run); the fallback's check, if the trial needs it, is itself
unmeasured, and without it the keeper isn't offered. Every other K-M row owed before
stays owed. Nothing here switches a refusal constant on.
