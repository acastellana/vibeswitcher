# The Mac node's journal: what it records, where, and how you acknowledge it

Status: **design, final for building, nothing built** (2026-11-27, branch `v2-mac-journal-design` off
`v2-mac-anchored-cli` `b15e0052`). The review of `5acb15c2` (verdict "not yet", 2026-11-26) found seven Important
findings (I1 to I7) and nine notes (N1 to N9), each answered where [Review of 2026-11-26](#review-of-2026-11-26) says.
The re-check of `b225d8c0` (verdict "sound with changes", 2026-11-27) found two Important findings (R1, R2) and ten
notes (N-a to N-j), each answered where [Re-check of 2026-11-27](#re-check-of-2026-11-27) says. No further
whole-design review follows: each slice marked "Review" in [Build order](#build-order) gets its own when built. It is step 6 of [the node on macOS](2026-11-19-v2-node-on-macos.md) ("The unified log for events and the
ack rule"), row 11 of the measurement record's table "What stands between this Mac and `vibeswitcher start`"
(v2-mac-measurements (`docs/process/v2-mac-measurements.md`, not on this branch), newest copy on `v2-mac-runbook`), and item C9 with
decision N6 of V2 without a terminal (`docs/process/v2-no-terminal.md`, not on this branch) (newest copy on `v2-remaining`). It replaces
the Mac spec's call in "Logs: the unified log for events, a file for stderr" that "the ack rule (`NodeJournal.passes`)
becomes 'written by the installed command line's image'": measurement M10 showed that anchor can be forged.

**Amended 2026-11-27 by [the keeper design](2026-11-27-v2-mac-keeper-design.md)** (branch `v2-mac-keeper-design`):
the user chose the root-owned keeper of [Open for the user](#open-for-the-user) 2 (9CDB5A99) and took the
recommendations of items 1, 3 and 4 (90BBAD80). The node's vault key, its journal counter and slice 20's device epoch
are the keeper's, not the login Keychain's; the slices that rested on the Keychain (J0a's seam, J3a, J3b, J4a, J4b)
say inline what changes, and [Amended by the keeper design](#amended-by-the-keeper-design) lists every other place
this design's Keychain text no longer holds for the node; the keeper design's review's fix round
(`v2-mac-keeper-design-fix`) corrected the wording you would read (its F13), and its second fix round
(`v2-mac-keeper-design-fix2`, after the keeper design's re-check) changed only what J3a, J3b and the keeper's K4 wait
on (below). "The keeper" here is that root-owned process; the switch's
`MacHandoverKeeper` is "the handover keeper" or "a proven keeper".

Two readers: you (the first page), and the independent security reviewer who reads it before any slice is built (the
rest, exact). Read with device keys (`2026-11-26-v2-device-keys-design.md`, not on this branch) (on `v2-keys-vault`: guarded changes,
slices 4, 9, 14, 15, 20, 23), the Mac spec's newest copy (on `v2-mac-seal-list`, and `v2-mac-runbook` for row 3's
settled rule), and the node's journal code at `b15e0052` (`Sources/VibeNode/Facts/NodeJournal.swift`,
`Sources/VibePlatform/Journal*.swift`, `Sources/vibeswitcher-cli/Status.swift`). Each statement about the Mac is
**measured** (with its M- or K- number), **read** from code (with the file), or **not measured** (with the measurement
owed, in [Measurements owed](#measurements-owed)).

## For you, in one page

**What the journal is for.** It tells you when something happened to your node that you didn't do: it was stopped
and started again, its server restarted, or its own record was lost or put back. Something of yours that runs as you
(an agent session, a script it wrote) can do each of these. The journal can't stop it. It makes sure you hear about
it, and that only you can say "seen".

**What you see.** When there is something to review, the page shows a notice on This node: "Your node was restarted
at 14:02 and you didn't restart it." Review opens the list in plain words. Acknowledge shows the Mac's own Touch ID
window, which names what you are acknowledging. When you approve, the notice goes. Something that happens after you
opened the list isn't covered: it comes back as a new notice. Everything else the journal records (your own starts,
stops and updates) is listed in This node › Journal as history, and asks nothing of you.

**While something waits for you,** the node refuses the changes that always ask for Touch ID (updates, hooks, review
floors, plugins, adding a device), and says "Review what happened to your node first". Reading, answering, sending
and stopping are never held. Adding your first device is never held either, so you can reach the notice from a page.
After an old copy of the record was put back, or the record went on while its keeper wasn't answering, your
devices are held. A program of yours can cause either whenever it likes, and on a Mac with no phone Terminal is then
the place to acknowledge from (and to make the changes the command line has its own forms for), until device keys
gives held devices a way back.

**Without a page** (no device yet), the node's own command in Terminal shows the same list and asks the same Touch ID.
It doesn't work from a shell card in the Mac app, which the node refuses for everything.

**What it costs you.**

- One Touch ID when you start the node yourself after stopping it from Terminal, so the node knows both were yours.
  If it stopped any other way (a crash, something else ended it, or a stop from the page), the start leaves a notice
  even when you started it: the end is what you need to see.
- **Decided ([Open for the user](#open-for-the-user) 3, 90BBAD80), what the review's fixes cost:** with the keeper,
  locking your login keychain no longer refuses anything; while the keeper doesn't answer (a program of yours can
  keep it busy, as it could lock the keychain), the changes that always ask for Touch ID are refused, so that none
  of them can go unrecorded; after the record begins again, each setting the node checks waits for your accept once.
- **Decided ([Open for the user](#open-for-the-user) 4, 90BBAD80):** no longer arises with the keeper: the node keeps
  no Keychain item. Its principle (hold, name it, delete nothing without your word) holds for the keeper's store.
- **Decided ([Open for the user](#open-for-the-user) 1, 90BBAD80):** a start when you log in asks you every time,
  until a measurement says a program can't fake a new login. Each login leaves one notice to acknowledge.
- **Decided ([Open for the user](#open-for-the-user) 2, 9CDB5A99), signing and the record's anchor together:** a
  small system-level keeper ([the keeper design](2026-11-27-v2-mac-keeper-design.md)) holds the record's key and its
  checks, for one more `sudo` line at setup, so a program of yours can no longer put back or replace the node's whole
  record unseen, and unsigned builds keep the record across updates.

**What it doesn't do.** It doesn't stop a program running as you from killing the node, and it doesn't protect you
from a program that becomes the node itself (S11 item 3, accepted as today). Until the keeper of choice 2 is built
(decided; [its design](2026-11-27-v2-mac-keeper-design.md)), nothing of the record is anchored at all, since the
node is refused on the Mac until then; with it, a program of yours that rewrites Keychain items or signs itself as
the node no longer reaches the record. One that rewrites your node's build during an update you run still does: the
keeper then serves that build as your node (the keeper design's first page; you accepted that limit on 2026-11-27,
8B298106). Between a stop you typed in Terminal and your next start,
a copy of the node that recorded nothing isn't shown ([Open for the user](#open-for-the-user) 3). The Mac's system
log gets a copy of each event for diagnosis. Anything on the Mac can write there under any name, so the node never reads it.

## Amended by the keeper design

2026-11-27, [the keeper design](2026-11-27-v2-mac-keeper-design.md) on `v2-mac-keeper-design`, and its review's fix
round on `v2-mac-keeper-design-fix` (the review's F13: the wording you would read that still named the login keychain
as a cause). The rest of this document was written while the record's anchor was the login Keychain, and its Keychain
text is kept as the reasoning it was. For the node's record, where they disagree, the keeper design holds. Edited
inline: the status, the first page's choices and its "devices are held" sentence, P30's row, Open for the user 1 to
4, For the reviewer: the keeper, J-M2's row, and the build order's J0a, J3a, J3b, J4a and J4b with what each waits on;
and, in the fix round, the places in the second table below. Superseded without an inline edit:

| Place here | With the keeper |
| --- | --- |
| The property's "except a process that holds or replaces the vault's key" (P30, P34, P35) | no process of your account holds or replaces it, except a host pinned through an update a session rewrote (the keeper design's KP6a: a stated limit, accepted by the user on 2026-11-27, 8B298106): the key is the keeper's, given only to a checked start whose running code is a host the pins record pins (keeper design, "The interface"); J0a's rule 2 keeps the genuine host's other modes away |
| The threat table's first two rows: Keychain items overwritten, deleted and planted, `login.keychain-db` put back, holders (1) to (5) | the node keeps no Keychain item; holders (4) and (5) hold nothing of the record; (1) to (3) are the keeper's served builds, the deputy stopped by rule 2 as before (keeper design, its threat table) |
| "Where entries rest": the vault's key and the journal's counter in your login Keychain | the keeper's key and its `journal` slot (keeper design, "What it stores") |
| "The node's own Keychain items": rule 1's item names, the node's `-i` | `NodeKeychain` becomes `NodeAnchor` (in-memory and keeper stores); the names are the keeper's key and slots; rules 2 to 4 unchanged |
| "One writer" 4: the Keychain's two-call compare-and-set and its residue (P40) | the keeper's swap is one atomic compare-and-set: the residue closes; the lock rule stays (keeper design, Open questions 4) |
| "When a raise fails": a locked login keychain, an item deleted and planted, `noKeychain` at the start, "Unlock your login keychain" | the keeper not answering (down, or kept busy by a program of yours: keeper design, KP19); no host starts without its key (it exits 78, at once when the keeper isn't installed, after a minute when it is busy or not running: keeper design, "While the keeper is down", its Open questions 1 decided by the lead, 2026-11-27), so no `noKeychain` start; a failed raise while running appends `record.begins` with `noKeeper`, with the keeper's words |
| Fail closed's row 1 (`noKeychain`) and the words "its key in your login keychain" | the host's exit at the start (no record begins); row 6 (`noCounter`) reachable only by root |
| P13, P29: "Stopped unless the counter is overwritten in place (P34) or the login keychain file is put back (P35)" | stopped: the counter is the keeper's |
| P31: the keychain locked or its items replaced, again and again | moot for the keychain; the same denial stays, its lever the keeper's socket kept busy (keeper design, KP19): guarded changes refused, and a node that doesn't start while it lasts |
| P36: a revocation made uncounted by locking the keychain first, then undone by a put-back | unchanged, its lever the busy keeper instead of the locked keychain (KP19): a stated limit as before |
| P42 and Fail closed's row 7a: the file sealed past failed raises (`ahead`) caused at will by locking the keychain | unchanged, its lever the busy keeper (KP19): open, devices held, as before |
| P34, P35 | closed for the node's record |
| P39: "one started without its key" | gone: no host starts without its key; the rest of P39 stands |
| P40's "Not stopped in the Keychain" | closed by the keeper's atomic swap |
| The engineering calls: "The counter and the vault's key are the node's own Keychain items" | they are the keeper's |
| Measurements owed, J-M2 | gates nothing of the node |
| Differences from Linux: "the node's sealed vault, with a Keychain counter" | with the keeper's counter |
| "When a raise fails": its words ("Unlock your login keychain, then try again"; "Your node couldn't use its login keychain when it started") and the keyless host | the keeper design's words ("While the keeper is down"): never a password for a keeper installed but busy or not running; no keyless host |

**Edited inline in the fix round** (the review's F13), each now saying the keeper where it said the login keychain,
so J3b builds the keeper's words:

| Place here | Now |
| --- | --- |
| The first page: "or the record went on while your login keychain was locked, your devices are held" | "…while its keeper wasn't answering…" |
| Fail closed's row 7a, its words | "Your node's record went on without its keeper, or an older copy was put back. Changes may have been undone." (under 120 characters, as "The words" require) |
| "What the counter covers": the removal's refusal and its status line ("Removal waiting: unlock your login keychain"); "one Keychain write each" | the keeper's words, which never mention a password ("Removal waiting: your node's keeper isn't answering"); one keeper swap each |
| "The words": the order of seriousness ranked `noKeychain` and gave `noKeeper` no rank | `noKeeper` takes `noKeychain`'s rank, with its own words |
| "Across a host end and a node restart", its last bullet ("No Keychain key …") | with the keeper it doesn't arise: a host with no key exits 78 having read nothing |
| "What the node refuses": "not even when the counter can't be raised (`noKeychain`)" | `noKeeper` |
| The engineering call "Each needs a Keychain write (the counter)" | a counter raise, one keeper swap |
| P4 ("under the Keychain key"), P14 (the counter item), P15 (the Keychain key) | the vault's key and the `journal` slot are the keeper's; deleting or resetting either is root's |

## The property, and the threat it answers

**The property.** On a Mac node, every start of the node's host that nothing you did explains, every restart of its
server, and every loss, rollback or unreadable state of its own record becomes a journal entry. That entry stays
**open** (shown to you, holding guarded changes) until you acknowledge it with a fresh biometric. The acknowledgement
names it and is recorded as yours. No process but the node's own host and server can add an entry, and none can make
one disappear or look acknowledged without the change itself becoming an open entry, **except a process that holds or
replaces the vault's key** ([What a holder of the vault's key reaches](#what-a-holder-of-the-vaults-key-reaches)): a
program signed as the node (P30: expected, J-M2 B); a process of yours that overwrites the node's Keychain items in
place (P34: measured on items of this kind, the lead's decision of 2026-11-26); one that puts the login keychain file
back with an older vault (P35, the review's I4: expected, J-M2 E). All three are closed only by the keeper of
[Open for the user](#open-for-the-user) 2. The property rests on two preconditions: **a checked node seals only what
it read from its own file under its own key, or took from a proven keeper**, and only the checked node start touches
the node's items (J0a, P33); and **one host writes the record at a time** (the re-check's R1, P40: [One
writer](#one-writer-and-a-counter-bound-to-the-last-entry)), so that two checked hosts can't each continue one record
and leave two files that both match the counter.

**Why it matters on the Mac** (the reason step 6 is on the path to `start`): several stated limits of the device keys
design rest on "a host start the journal records". A process of the uid can end the host and bind its page's address
(device keys, "Open to attack" 4; the "ends the host and binds its addresses" row). The next unlock you give that page
certifies the squatter's key. The only thing that tells you it happened is the restart the journal shows.

**Who could forge, drop, rewrite or pre-acknowledge an entry,** in order of how close they are to you:

| Who | What they can do to a journal on a Mac (measured or read) | Here |
| --- | --- | --- |
| **A team's session of your own account**, or any process of your uid that isn't you | write the unified log under any subsystem and, by Mach-O UUID, under the installed command line's image (**M10**); read, delete, replace and copy every file under `~/.vibeswitcher/v2/node` (your files, 0600/0700, read: `VaultStorage`, `VibePaths.writePrivate`); end, `kickstart`, `bootout` and `bootstrap` the node's LaunchAgent (read: the Mac spec's step 5; `immediate reason = speculative` after a bootstrap with `RunAtLoad`, `non-ipc demand` after a `kickstart`, measured in the spec's "What a real Mac proved"); run the installed command line (row 3's lines refuse it early when they can tell; escapes through launchd pass them, K-ESC-1 to 3); raise LocalAuthentication dialogs of its own (**M9**); drive your unlocked browser (device keys, accepted risk 1); lock your login keychain. **Measured on Keychain items of this kind** (the lead's decision of 2026-11-26: an item can be overwritten in place, or deleted and planted, by another process of the account, with no dialog; reading stays refused): **overwrite the node's vault key with a key of its own and the counter with any value** (`journal.list` shows it the record's id and seq, never the counter's binding of the last entry; P34). **Expected, not measured (J-M2 E): copy `~/Library/Keychains/login.keychain-db` and put it back with an older vault** (the items are generic passwords with no data-protection flag, `Keychain+Darwin.swift:12-26`, so they live in that file of your uid; securityd reads a replaced file at the next login, earlier is not known; P35). **Expected, not measured (J-M2 B): sign a program of its own as the node and read the vault's key and counter with no dialog.** `Keychain+Darwin.swift` adds the key with no access list of its own, so the Keychain trusts the program that made it by its designated requirement. For a host signed with `setup-signing.sh`'s local identity, that is its identifier and certificate. `codesign` uses that identity without asking while its keychain is unlocked, which `setup-signing.sh` leaves unlocked from a build until the Mac sleeps | **Stopped**, without the vault's key and without touching the Keychain items, from adding an entry, rewriting one or making one look acknowledged, **once the one-writer rule and the bound counter are built** (J3a: [One writer](#one-writer-and-a-counter-bound-to-the-last-entry)). **Before that change it didn't hold** (the design at `b225d8c0`, the re-check's R1): a session could delete `host.lock`, start the installed host with the job's command line as a second checked start beside the running node, keep a copy of that second host's file, and later put it back over a guarded change the first host made at the same seq, with no Keychain write but the node's own raises and no `older` (P40); **limited** for dropping by the file alone (deleting it, truncating it or putting back an older copy alone makes the record begin again with an open entry saying why). **Not stopped in your account:** two checked hosts whose timing and lock file a session drives between their checks (P40's residue, the Keychain's compare-and-set being two calls), a vault replaced whole under a key overwritten in place (P34, measured kind), an older vault put back with the counter overwritten to match (P34) or with the login keychain file (P35, expected), and every program that holds the key (P30, expected). Each reaches every guarded state in the vault, not only the journal ([below](#what-a-holder-of-the-vaults-key-reaches)). These are stated limits under the lead's standing decision (no paid Developer ID, 2026-11-26); [Open for the user](#open-for-the-user) 2 offers the root-held keeper that closes them, the pattern you accepted for the server check's pins. **Denial** (I2): locking the login keychain refuses every guarded change until it is unlocked ([The journal's counter](#the-journals-counter)). **Accepted**: killing the node (it becomes an open entry); a driven page asking the real Touch ID window with the real words (prompt fatigue, as device keys); denials (below) |
| **Programs that hold the node's Keychain items' code identity** (the review's I1d: every program with the items' designated requirement, in every mode its code allows; [The node's own Keychain items](#the-nodes-own-keychain-items-and-the-one-start-that-touches-them)) | read, raise, delete and replace the node's vault key and journal counter with no dialog, since the Keychain trusts code, not the mode it runs in. The holders: **(1)** the node's host build in its checked start, the intended holder, one host at a time (the one-writer rule; a second checked start beside the running node writes nothing, P40); **(2)** the same build in every other mode its code has: a user's host of any `VIBESWITCHER_HOME` (by lock path alone, `HostHardening.swift:135`, `Paths.swift:11`), a scratch or test host, a start from a handover state file or `--handover`; **(3)** every other build of the node's host signed with the same identity and identifier (older and newer builds, a worktree's test build); **(4)** any program a process of yours signs with the local identity and the node's identifier while the signing keychain is unlocked (P30: `codesign` is in that key's list, `setup-signing.sh:261`, and that keychain locks only at sleep, `:258`); **(5)** any program you once clicked Always Allow for on those items. Under ad hoc signing: (1) and (2) of that one build only. Not a holder once J0a is built: the Mac app's host, signed `vibeswitcher-host` (`build-app.sh:239` passes no `-i`), since the node's builds get an identifier of their own | (1): by design. (2): **stopped by code, not by the Keychain**: only the checked node start calls the items (J0a's rule and its test, P33). (3): **stopped** for every build the root-owned record doesn't pin, since their code calls the items only from a checked start, which an unpinned build can't pass. **Not stopped for a pinned older build:** the record pins up to 16 builds a rollback may go to (`NodePins.swift:3-14`, `maxBuilds`; `build(host:)` matches any row), so a session can kill the host, put a pinned older build's server at the node root's `bin/`, and start that build with `--node`; it passes the checked start and holds the items, and the keeper would serve it too. The journal shows it: a `host.start` whose `build` isn't the previous start's, with no `switch` naming it, is open, worded "An older build of your node started, and you didn't switch to it" (the unswitched-build rule, [What explains a start](#what-explains-a-start); `HostJournalTests.anUnswitchedBuildChangeIsOpen`; P41). A downgrade to a pinned build with a bug fixed since is the Mac spec's rollback list's limit, stated here, not this design's to close. (4) and (5): **not stopped** in your account (P30); [Open for the user](#open-for-the-user) 2's keeper takes the items out of the Keychain |
| **A process of another uid** | write the unified log; nothing of yours (your files, your Keychain, the node's sockets check the uid) | **Stopped** |
| **Someone at your unlocked page, or a program driving it** | anything not guarded, for up to 12 hours (device keys, accepted 2026-11-25), including `stop`; begin an acknowledgement, which puts up the real Touch ID window with the real words | **Stopped** from acknowledging without your finger or password on the Mac's own window |
| **A program that becomes the host or replaces the command line** (S11 item 3, T3, T12), or that takes the host's task port (which puts the Developer Tools password dialog up first, so it needs you to approve that dialog) | anything, including appending acknowledgements: on the Mac's dialog route the vault takes the server's word (below) | **Accepted**, as today; the checked start (rows 4, 5, 7, 10) refuses a replaced host or server by cdhash against the root-owned record |
| **Root** | anything | out of scope (S1) |

### What a holder of the vault's key reaches

P30's whole scope (the review's I5). A program that holds the vault's key (one signed as the node, P30; I1's deputy
before J0a, P33) can open the vault, make any change it holds, seal it again and set the counter to match, so nothing
shows. That covers every guarded state the vault keeps, not only the journal: the devices (its own, with its key and a
live unlock), review floors and the 13 settings, first-look baselines, slice 20's device epoch, and the journal. It
also **reads every secret in the vault** (confidentiality). A process that overwrites the key in place (P34) reads
nothing of the old vault, but can replace it whole with one of its making under its own key, which reaches the same
states. A process that puts the login keychain file back with an older vault (P35) undoes every guarded change since
the copy, slice 20's epoch with them (it sits in the same keychain), and buries every entry since; its cost is that
every other keychain change since the copy is undone too, which you may notice.

So an anchor that catches these must cover the **whole sealed vault**, not the journal's position: a keeper that
remembers only the journal's id, last seq and chain misses a vault rewritten around its journal's bytes. The keeper
offered in [Open for the user](#open-for-the-user) 2 anchors the whole vault, and is called only from the checked
start (J0a's rule 2), since the deputy is the same build with the same cdhash.

## What is journalled, and by whom

The journal is a list of **entries** in one **record**. Each entry has a `seq` (1, 2, 3 … in the order the vault
appends them, never reused), a `kind`, a time (`at`, the host's wall clock in whole seconds) and fixed fields per kind.
The record has an id (16 random bytes, made when it begins). A new record (below) gets a new id, so nothing done to
an old record applies to the new one.

| Kind | Written by | When | Fields | Open until acknowledged? |
| --- | --- | --- | --- | --- |
| `record.begins` | the host | when it can't continue a record (a first start, a missing, changed, rolled-back or unreadable record, no Keychain key; a record too full to trim; [Fail closed](#fail-closed)); and, with `noKeychain`, when a counter raise fails ([The journal's counter](#the-journals-counter)) | `reason` (one of a fixed list) | **yes, always** |
| `host.start` | the host | at each start, before its server is made | `pid` (its own), `boot` (`kern.bootsessionuuid`), `login` (the host's audit session id, `getaudit_addr`), `launchd` (`speculative` or `demand`: launchd's `immediate reason` for its job), `job` (the job's pid as `launchctl print` gives it, or none), `build` (the commit of its build-info), `previous` (how the job's last process ended, launchd's `last exit code` / `last terminating signal` for the job, read from `launchctl print` as `NodeAgent.printed` parses it, or `unknown`), `how` (`switch`, `login` or `other`, below). `launchd`, `previous` and the manager name describe **the job**, not necessarily this host: a checked host needn't be the job's process, since `macNodeStart` doesn't ask who started it (the re-check's N-j); `job` lets a reader tell | **yes**, unless explained ([What explains a start](#what-explains-a-start)) |
| `start.explained` | the server, through the vault | when it takes a `start` request in your voice within 120 s of a `host.start` | `start` (that entry's seq), `action`, `via` (always `terminal`: `start` is the terminal's kind in device keys, and a page's `start` is refused) | no; it explains its `host.start` |
| `stop` | the server, through the vault | when it takes a `stop` request in your voice, before it acts | `action`, `via` | no |
| `host.end` | the host | as its last act when it ends for a `stop` it was asked (after its server and sessions are done, before it exits) | `action` (the stop's) | no; with that `stop`, it lets your next `start` explain the next `host.start` |
| `switch` | the server, through the vault | when it takes a guarded `build.switch`, before the handover | `action`, `via`, `to` (the commit) | no; it explains the next `host.start` with `how = switch` |
| `guarded` | the server, through the vault | when it takes any guarded kind, before it acts | `kind` (the guarded kind's name), `action`, `via` | no (it puts every guarded change under the counter) |
| `server.restart` | the host | when its server child ended and it started another | `ended` (exit status or signal) | **yes** |
| `page.held` | the host | at its start, when it can't bind the page's address at once (today the failure goes to its log only, `HostWebListeners.swift:89`; the review's N1), whatever [Open for the user](#open-for-the-user) 1's answer | `errno` | **yes**: "Something else held your node's page address when it started." |
| `ack` | the server, through the vault, after the vault's own check | when you acknowledge | `through`, `digest`, `via`, `approval` | no |
| `revoked` | the vault, inside each request that drops an unlock or a key (`dropUnlocks`, which `device.lock` uses, and the requests behind `phone.off` and `web.revoke`; device keys' lines 517, 719, 733), so no route skips it (the review's N5), and inside a device's removal | before the request answers | `what` (`device.lock`, `phone.off`, `dropUnlocks`, `web.revoke`, never refused for a failed raise; and `device.remove`, the removal of a device, so a put-back can't bring a removed device back unseen, which acts only once its raises succeeded: [What the counter covers](#what-the-counter-covers)), `action`, `via` | no (it puts each revocation under the counter) |
| `lock.lost` | the host, **in its memory only**: never sealed, never counted ([One writer](#one-writer-and-a-counter-bound-to-the-last-entry)) | when its lock's path no longer names the file it holds, or a raise's compare finds the counter moved | none | **yes**, until the host ends (it can't be acknowledged, since an `ack` would be a write): "Something replaced your node's lock or its record's check, so another copy of your node may have run. Restart your node." |
| `more` | the vault | in place of each open event that comes while 64 entries are open ([Fail closed](#fail-closed)); never changed once written | `counts` (by kind, every event appended as a `more` since the 64th open entry, this one included), `worst` (the most serious kind among them) | **yes**; it ranks as its `worst` |

**`via`** is how your voice came: `device:<id>` (an unlocked device's signed frame, device keys slice 7), or
`terminal` (the command line under the Mac's `approval` voice, the server's dialog). **`approval`** for an `ack`: `dialog`
(the server's Touch ID window, the Mac's route for a guarded kind; slice 23) or `passkey:<device>` (a phone's
assertion, once phone access exists on a Mac node, slice 17). A device's **name** is never written into an entry or
shown in the Touch ID window: a driven page can rename a device (`device.rename` is an `.acts` kind), so a name could
mislead you. The id is shown on the page beside the name the Devices list gives it now.

**Accepted requests are not entries.** The vault already records each request it takes in your voice, before it is
done (`recordUserAction`, `recordPageAction`; rule 8's record of actions). This Mac's journal adds only what needs your
eyes or explains something that does. Linux's journal marks a request the server accepted that the command line's own
journal entry doesn't record (`NodeJournal.marks`). That comparison needs a second witness that a session can't forge,
and the Mac has none (M10). On the Mac each request's proof is checked when it is taken, and is recorded with it
instead ([Differences from Linux](#differences-from-linux)).

**Writers, all of them:** the node's host (in its own process, `LeadVault.Book`) and its server, through the vault's
requests that only the app may make (`VaultV2Handler.answer`'s `caller == .app`, over the connector the host made for
the server child it started from a cdhash-checked file: the Mac spec's step 3, rows 4 and 7). The server may append
only `start.explained`, `stop`, `switch`, `guarded` and `ack` (never `host.end`, `host.start`, `server.restart`, `page.held` or `record.begins`). The vault refuses any other kind from it. Nothing else writes:
not the command line (on the Mac its `writeJournal` sends nothing, `Journal+Darwin.swift`; [Differences](#differences-from-linux)
lists each call), not a session, not the Mac app, not launchd.

**Readers, all of them:**

| Reader | Reads | Trusted for |
| --- | --- | --- |
| the host | its record at start (to continue it, or begin again) | everything: it is the record's keeper |
| the server | the record through the vault's `journal` request | the notice, `journal.list`, `status`, the guarded refusal, the acknowledgement's text and digest |
| the page (an unlocked device, or a desktop's read key) | `journal.list`, a read kind | showing; it decides nothing |
| the command line | `status` and `journal.list` through the server; never the vault, the log or a file | showing; `status --ack` sends what it showed |
| nobody the node points to | the unified log's copy ([below](#where-entries-rest-on-a-mac)), which anyone can read with `log show` | nothing: anyone can write there, and the node never sends you to it (the review's N6) |
| nobody | the host's and server's stderr file (`StandardErrorPath` under the node's root) | nothing, as the Mac spec says |

## Where entries rest on a Mac

| Place | Owner, mode | Who can write or rewrite it | Role |
| --- | --- | --- | --- |
| **The node's vault**, `lead/vault.sealed` under the node's root (`~/.vibeswitcher/v2/node`; read: `vibeswitcher-host/main.swift`'s `vaultFile`, `Platform.Service`'s `nodeRootFolder`), the journal one part of the vault's book | you, 0600 in a 0700 folder (`VibePaths.writePrivate`) | any process of yours can delete it, truncate it or put back an older copy. Its contents are ChaChaPoly under the node's own key, `dev.vibeswitcher.node.vault` / `key` in your login Keychain (today the node uses the app's `dev.vibeswitcher.lead-vault` / `vault`, `VaultStorage.swift:121`; J0a gives it its own), which `VaultStorage`'s header says the Keychain gives without asking "only to the binary that created it". Read more closely (`Keychain+Darwin.swift`: no access list), that binary is any program with the same designated requirement, in any mode: the threat table's holders (1) to (5), so for the local signing identity it is **any program signed as the host** (expected, J-M2 B). The node's own key has **not been measured**: "not measurable before item 13" (the measurement record's item 7) | **the record** (the source) |
| **The journal's counter**, the node's own Keychain item `dev.vibeswitcher.node.journal` / `counter` (never the vault key's item, never the app's), holding `{record, seq, bind}`: the record's id, its last seq, and a binding of its last entry that `journal.list` doesn't show ([One writer](#one-writer-and-a-counter-bound-to-the-last-entry)) | your login Keychain | the holders of the key, as above; **not measured** (J-M2) | the check against a deleted or older vault (below) |
| **The host's memory** | the host | nobody else: the checked node's Hardened Runtime, no task port without the Developer Tools dialog (the Mac spec's step 3; the measurement record's preamble) | the record while the host runs; the only place it lives when there is no Keychain key |
| **The unified log** (`os_log`, subsystem `dev.vibeswitcher.node`, category `journal`) | logd, root | **any process of any uid** can write entries under that subsystem, and logd names the writer's image by Mach-O UUID, so the installed command line's image can be claimed (**M10**). Nobody can rewrite one | **a sink only**: the host copies each entry's kind and seq there, nothing else (no ids, no paths, no names), each line starting "a copy, not the record". Nothing in the node reads it (a lint, slice J9a), and the node never points you to it. `log show` reads it without admin in 2 s (**M10**). Whether another, non-admin user of the Mac can read it is **not measured** (J-M4); with kinds and numbers only, the answer changes nothing |
| the stderr file | you | any process of yours | read by you, trusted for nothing (the Mac spec) |

**Why the vault and not the unified log** (the M10 conclusion's second anchor, "the record in the host's vault
alone"): the unified log's writer field can be forged (M10). Whether a forger's message can be made to compose too is
**not measured**, and a rule that leant on it would stand on what isn't measured. The vault's write path is the app's
alone and its file is sealed. The first anchor M10 named, "a nonce the server hands only to the request it accepted",
was for entries the command line writes. On the Mac the command line writes none.

### The node's own Keychain items, and the one start that touches them

The Keychain trusts code, not the mode it runs in: an item added with no access list of its own
(`Keychain+Darwin.swift:12-26`) is given without asking to any program with its maker's designated requirement. The
node's host build has many modes, and today every one that holds "the user's" lock seals its vault under the same
item, the Mac app's `lead-vault` (`VaultStorage.swift:121`). A host that isn't a checked node takes any state file's
secrets (`mayTakeHandover` returns nil when `checkedNode` is nil, `HostImages.swift:438`; `HostHandover.takeSecrets`,
`HostHandover.swift:299-304`) and seals them at once (`VaultStorage.book(handedOver:)`, `VaultStorage.swift:43`;
`vibeswitcher-host/main.swift`'s `vaultFile`). So the genuine build, run by a session with
`VIBESWITCHER_HOME=/scratch --handover /scratch/state` and a descriptor of its own, seals a vault of the session's
making under the node's key, and the session swaps the file in over the node's (the review's I1, steps 1 to 6). The
rule that closes it, built by slice **J0a** before any of J3a, J3b, J4a and J4b:

1. **Names of the node's own (I1a).** The node's vault key is `dev.vibeswitcher.node.vault` / `key` and its journal
   counter `dev.vibeswitcher.node.journal` / `counter`, never the app's item. They are named in one file,
   `Sources/VibeHost/V2/NodeKeychain.swift`, and a lint keeps them there
   (`JournalLintTests.theNodesItemsAreNamedInOneFile`). The node's builds are signed with an identifier of their own,
   `dev.vibeswitcher.node.host` (the node's build passes `-i`; `build-app.sh:239` passes none, so the app's host is
   signed `vibeswitcher-host`), so a build of the app's host signed with the same local identity doesn't hold the
   node's designated requirement. Slice 20's device epoch is the node's too: its item goes under `NodeKeychain` with
   the same rules (slice 20's reviewer reads J0a's and J3a's seam, N9).
2. **Only the checked node start touches them (I1b).** `NodeKeychain` is called only when `config.checkedNode != nil`
   (`isCheckedNodeHost`), after the checked start passed (rows 4, 5, 7, 10). No other mode of the build reads, makes,
   raises or deletes them: a scratch home's user's host, a test host, a start from a state file or `--handover`. Those
   keep sealing exactly as before, under the item they used. A separate name alone changes nothing about whom the
   Keychain trusts (the same build holds both); this rule and its test are what keep the deputy out. Test (J0a):
   `HostJournalTests.noOtherModeTouchesTheNodesItems`, whose arms make no call on a counting in-memory key store for
   the node's names and seal the same bytes as before: a scratch-home user's host, a test host and a host started
   from a state file, each with `--handover`; **a scratch-home user's host started with no handover at all** (the
   shape of `a-host-started-on`, the re-check's N-a); and **the `--test-checked-shape` host**, reset as a checked
   node is and given its checked sessions but with `checkedNode` nil (`main.swift:54-61`, `:126-129`), the mode most
   likely to be mistaken for a checked node. J3a, J3b, J4a and J4b each add their arm to it, so none switches
   Keychain writes or the record on in another mode (N9); J3a's arm is **a second checked start while the node runs**,
   which writes nothing ([One writer](#one-writer-and-a-counter-bound-to-the-last-entry); J0a doesn't add it, since
   the lock's move is J3a's). [Open for the user](#open-for-the-user) 2's keeper, if built, is
   called from `NodeKeychain` alone and falls under the same test: the deputy is the same build with the same cdhash,
   so a keeper that checks the cdhash can't tell it from the checked start, and only this code keeps it away (I5).
3. **The precondition, stated (I1c).** The property rests on this: **a checked node seals only what it read from its
   own file under its own key, or took from a proven keeper.** `mayTakeHandover`'s checked branch already holds the
   second half (a checked node takes state only through a keeper it proved, never from a file,
   `HostImages.swift:439-443`). J0a's test adds that a checked start given `--handover <file>` takes nothing and seals
   nothing (`HostJournalTests.aCheckedStartTakesNoStateFile`).
4. **The holders, named (I1d):** the threat table's row "Programs that hold the node's Keychain items' code
   identity".

**What the app's vault on v2 rests on: the handover's receiving side** (the re-check's N-c). The node's property
doesn't rest on it: rules 1 to 3 alone keep the node's items out of every other mode's reach, whatever a receiving
side lets through. What rests on it is the Mac app's vault (`lead-vault`) on v2, as on main. The same path reaches
the Mac app's own host on this repository's main (main's `main.swift:114` and `:129` take any state file's secrets and
seal them under `lead-vault`; main has no `mayTakeHandover`; read, not measured), and so does a host started on
another home with no handover at all (`a-host-started-on`). Both are the app's concern on main, not the node's. A
separate task on main, `the-session-host-s`, fixes the app's host. Its requirement, as the lead gives it: the
receiving host accepts a handover only from the process it can prove is the running host it replaces, and refuses
anything else **before reading any secret or writing any vault file**; a refused handover leaves the sealed file byte
for byte as it was. Its mechanism isn't chosen yet. So J0 is split: **J0a, now,** builds the node's items, rules 2
and 3, the node's `-i` and the deputy tests with N-a's arms; **J0b, once main's mechanism is chosen,** carries main's
receiving side into v2's `main.swift`. v2's host needs:

- **(J0b) the same requirement carried into v2's own `main.swift`**, whose handover code has diverged from main's (the
  checked start's keeper branch, `mayTakeHandover`, `HandoverMemory`): its unchecked branch (`else if let
  handoverPath`) still takes any unmarked state and seals it whenever `ownsLaunchers`, which follows
  `VIBESWITCHER_HOME`. A merge of main into v2 doesn't carry the fix by itself, since the files differ;
- **(J0a) the node's own items and the checked-start-only rule** above, which no fix on main gives (main has no node), so
  that even a receiving side that one day lets something through can't reach the node's key;
- **the deputy test on v2's build**, `noOtherModeTouchesTheNodesItems` and `aCheckedStartTakesNoStateFile` (J0a),
  with `the-session-host-s`'s own cases (J0b) (a planted state file, descriptors from an unrelated parent, no host running, a
  replayed state file, `VIBESWITCHER_HOME` or the lock path pointed elsewhere) run against v2's host too;
- **the review's point not read:** whether a vault a host opened can be handed on (`server.secretsForHandover = {
  vault.serialized }`, `main.swift`). Under rule 2 no other mode ever opens the node's vault, so what it can hand on
  is only what it sealed in its own mode. J0a's review reads that path and says so.

### The journal's counter

**In device keys' I6 order:** for each append, **raise the counter first, then seal the vault**. A failed seal is
retried by `VaultStorage`'s saver. A host that ends between the two leaves the counter ahead of the file, which the
next start reads as `older` ([Fail closed](#fail-closed)). The counter is the node's own item, apart from slice 20's
device `epoch` item: a device change needn't raise the journal's counter. Both are `NodeKeychain`'s (J0a), and **one
rule for a failed raise holds for both** (below; device keys' I6: "a failed raise refuses the change"). J3a builds the
seam on an in-memory store; slice 20 takes it, and its reviewer reads J3a's seam ([Build order](#build-order)).

#### One writer, and a counter bound to the last entry

The re-check's R1 (P40). Read at `b15e0052`: the vault is opened (`main.swift:268`) before the host takes its lock
(`server.start()`, `main.swift:345`; `flock`, `HostServer.swift:220`). The lock is a file in the node's root
(`host.lock`) that any process of yours can delete, and `server.start()` makes it again with `O_CREAT`
(`HostServer.swift:218`). On the Mac a checked start's `heldLockIsAllowed` is nil (`HostHardening.swift:176-179`,
`main.swift:168`), and nothing takes the path back (`watchesItsPath` is false there, `main.swift:163`). `macNodeStart`
checks the lock's path, the pins and the server's cdhash (`HostImages.swift:370-415`), not that the lock is free or
that launchd started the host. So, **at `b225d8c0`**, a session that deleted `host.lock` and ran the installed host
with the job's command line had a second checked host beside the running one. Both continued one record, and with a
counter of `{record, seq}` alone, a copy of the second host's file could match the counter at the same seq as the
first host's later guarded change, and be put back over it with no `older`. The requirements, which J3a builds (its
own review reads the mechanism):

1. **One writer.** On a checked node start, the host takes the node's lock, by its exact path, **before** it reads
   the vault file or the counter for writing, before it makes an absent key (row 1), and before its `host.start`. It
   appends, raises and seals nothing until it holds the lock. A host that can't take it exits having read no secret
   and written nothing (today's exit on a held lock, `main.swift:347-349`, moved before the vault's open). So a second
   checked start while the node holds its lock writes nothing
   (`HostJournalTests.aSecondCheckedStartBesideTheNodeWritesNothing`, J3a's arm of J0a's test). On a `switch` the new
   build doesn't take the lock by its path: it receives the held lock's descriptor through the proven keeper (read:
   `MacHandoverKeeper.swift:331`, `lockFD`), so it holds the lock before it reads the record, and the build before it
   writes nothing after the handover (`HostJournalTests.aSwitchHoldsTheLockBeforeItReadsTheRecord`).
2. **A host whose lock is gone writes nothing more.** Before each append, raise and seal, and again after each raise
   before it acts or seals (4), a checked Mac host checks that its lock's path still names the file whose descriptor
   it holds and locks (the same device and inode). A path that is absent, replaced, renamed over or turned into a link
   counts as changed, and so does a descriptor the host no longer holds. If either fails, the host writes nothing
   more for its life: no append, no raise, no seal, its saver stopped. It refuses every guarded change, with the
   `lock.lost` words rather than `journalOpen`'s (there is nothing it can let you acknowledge), and shows an open
   notice that lives in its memory only, `lock.lost`: "Something replaced your node's lock or its record's check, so
   another copy of your node may have run. Restart your node." **What still acts, in memory and unrecorded:** reads,
   answers, `stop` (the safe direction, never held) and the four revocations ("Lock now", `phone.off`,
   `dropUnlocks`, `web.revoke`), so locking a device always works; a device's removal is refused, as when a raise
   fails. That notice is never sealed and can't be acknowledged (an `ack` would be a write); it ends with the host.
   The next start finds a record with no `host.end` (a stop under `lock.lost` writes none), so its `host.start` is
   open as after any end you didn't ask for. A revocation made while `lock.lost` is up isn't sealed, so the restart
   loads the unlock as last sealed: the notice's words add "Lock your devices again after you restart" when one was
   made, a stated limit beside P36's. A session can cause `lock.lost` at will (delete the lock, or overwrite the
   counter): a denial until you restart, as P32's. Tests: `HostJournalTests.aDeletedLockStopsTheHostsWrites`,
   `HostJournalTests.aReplacedLockStopsTheHostsWrites` (the lock's path renamed over, or a new file made at it).
3. **The counter binds the last entry.** It holds `{record, seq, bind}`. `bind` is made from the record's last entry
   and something only the sealed vault holds, so that nothing a process of yours can see lets it compute `bind`:
   not `journal.list` (seq, kind, time and words), not the unified log's copy, launchd or the process list. A plain
   hash of the entry's bytes doesn't meet this, since its fields (`pid`, `boot`, `login`, `at`) can be guessed or read
   elsewhere. Two hosts' histories part at the second host's own `host.start` (its own pid), and a binding chained over
   every entry carries that difference forward, so two records at one seq never both match. The start's check
   compares all three values with the file's last entry; a `bind` that differs at the same record and seq is row 7,
   `older` (`HostJournalTests.twoRecordsAtOneSeqDontMatchTheCounter`). The candidate J3a's review weighs (the
   re-check's unreviewed suggestion): a MAC chained over each entry's bytes, under a random key kept in the sealed
   vault with the record and never shown, its current value sealed with the vault. Whether that also closes P34's
   rollback form (the counter set back to an older copy's values, which a process can neither read from the item nor
   compute) is for that review to confirm; this design doesn't claim it.
4. **The raise is a compare-and-set.** A raise first checks that the counter still holds what this host last wrote
   (at its start, what it read and matched; for a record that begins again, what it read there, an absent item
   included), and only then sets it. A host whose compare fails writes nothing more, as in 2, and shows `lock.lost`:
   another host wrote, or something overwrote the counter. In the Keychain the compare and the set are two calls (a read,
   then `SecItemUpdate`), not one atomic step, so a host acts on a counted entry, and seals it, only when its set was
   made, a read-back returns its own value, and its lock still names its file. A second host reads the record only
   after taking a new lock: if it took it before that last check, this host stops; if after, it reads either this
   host's sealed file (one history) or the file before this host's seal with this host's counter (`older`, open).
   Either way no two files both match, **while the lock's path changes only once**
   (`HostJournalTests.twoHostsRacingARaiseLeaveOneHistory`, on an in-memory store whose reads and updates interleave
   at every point). **The residue, stated** (the blind check of this change): the lock check reads the path at one
   moment, and any process of yours can rename files in the node's root. A session that starts the second host with
   the first host's lock renamed aside, renames it back, stops the second host (`SIGSTOP`) between its read and its
   `SecItemUpdate`, waits for your guarded change to be sealed, then swaps the second host's lock in and resumes it,
   gets both checks passed and the second host's file sealed last over your change: R1's outcome, behind "restarted"
   notices. It needs the session to drive both hosts' timing and the lock's file between their checks; a swap the
   node's own host catches shows you `lock.lost`. No lock in your own files can stop it: **in the Keychain it is a
   stated limit, closed only by the keeper's atomic compare-and-set** (P40), as P34 and P35 are. J3a's review may
   weigh a candidate that would make the Keychain's step atomic (a `SecItemUpdate` whose query names a hash of the
   old `bind` in an attribute, so it updates nothing when the counter moved), **not measured**: whether securityd
   applies such a query and update as one step would be a J-M2 probe, and until one says so the limit stands.
   Test: `HostJournalTests.aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet` (on an in-memory store with
   an atomic compare-and-set, the keeper's seam, the racing host's set fails and it writes nothing however the lock's
   path flips; on the two-call store the test names the residue). **The keeper's raise, in either form, is a
   compare-and-set too**, against what that caller last wrote, which the keeper makes atomic
   ([For the reviewer: the keeper](#for-the-reviewer-the-keeper)).

So R1's steps meet this: without the lock deleted, the second host exits before it opens the vault. With it deleted,
the second host continues the record and its `host.start` is open, and the first host's next write (R1's step 5, a
`server.restart`) finds its lock gone and its compare failed: it writes nothing, shows `lock.lost`, and refuses your
floor at step 6. A copy of the second host's file put back later undoes nothing of yours.

**When a raise fails** (a locked login keychain; an item the host can't use without asking, such as one deleted and
planted), the review's I2:

- **A guarded act, and anything P29 relies on, acts only after its entry's raise succeeded.** The server appends
  `guarded` (or `switch`, for an update) through the vault before it acts, and the vault answers whether that entry is
  counted. If it isn't, the act is refused, `recordUncounted`, in plain words: "Your node can't keep its record right
  now. Unlock your login keychain, then try again." Slice 20's device add, removal and rename refuse alike when their
  epoch raise fails (one rule for both items; [What the counter covers](#what-the-counter-covers) for removal).
- **The raise is tried again at each later append**, a compare-and-set against what this host last wrote (a failed
  raise changed nothing), and one that succeeds sets the counter to the newest seq and its `bind`, so it covers every
  entry before it. From then on guarded acts are taken again.
- **The record notes it:** the vault appends an open `record.begins` entry with `reason: noKeychain` to the same record
  (the same id, the next seq; the record id changes only when a record begins at a host's start, or is `full`), once for each run of
  failed raises.
- **What is sealed meanwhile:** the saver goes on sealing the file with the key the host holds in memory, so the file
  runs ahead of the counter. A next start that finds them apart begins again (`ahead`, row 7a), open and held: a copy of
  such a file put back later over counted changes would otherwise undo them. So the raise is also tried at the host's
  own end, and a restart before any raise succeeds costs the holds of a record begun again (Open for the user 3). An older copy put back at the
  counter's seq matches the counter and continues, so whatever was appended uncounted since can be buried: that is
  why nothing guarded may be uncounted. What such a put-back can bury is only what is still taken (next).
- **Still taken:** `stop` (the safe direction); every host and server entry (a restart is open, and loading an older
  copy needs a restart, itself counted or failing again); the acknowledgement (an uncounted `ack` lost to a put-back
  only reopens what it covered); and the revocations ("Lock now", `phone.off`, `dropUnlocks`, `web.revoke`: [What the
  counter covers](#what-the-counter-covers)), since refusing "Lock now" would be worse than an uncounted lock. An
  uncounted revocation that a put-back undoes is a stated limit (P36). A device's removal is not among them: it
  raises slice 20's epoch and is refused when a raise fails (the re-check's N-d, below).
- **A host that started without its key** (`noKeychain` at the start, below) stays memory-only for its life and
  refuses guarded acts for its life, with its own words ("Your node couldn't use its login keychain when it started.
  Unlock it, then restart your node."). **It leaves nothing on disk** (it has no key to seal with), so the next start
  with the key can't see that it ran: the file and the counter still match, and the record continues. When the host
  before the keyless one ended without your `stop`, that start's `host.start` is open, since nothing explains it, but
  what the keyless host recorded (its `noKeychain` entry, a `page.held`) is lost with it: one open "restarted" notice,
  not the squat's own (P39). Nothing guarded is lost, since the keyless host took none.
- **What leaves no notice at all** (the re-check's R2; P39): when the sealed record ends with your terminal `stop` and
  its `host.end`, a host that sealed nothing, run between that stop and your typed `start`, isn't shown: one started
  without its key, one killed before its first raise, or one whose lock was replaced before it wrote, whether launchd or a session started it (the checked start
  doesn't ask who started it). Your typed `start` is then explained by rule 2 as usual. That is acceptable because
  such a host sealed nothing and took nothing guarded, and the page's address was free in that window by your own
  stop anyway, which the journal doesn't claim to watch. At `b225d8c0` rule 2 also asked for a clean previous exit to
  catch this; that clause could never pass (launchd reports the previous exit as unknown after the bootout and
  bootstrap every stop and start does) and is dropped. The bigger alternative, keeping the job loaded across `stop`
  and `start` and binding `host.end` to launchd's `runs` count (`NodeAgent.swift:240-241`), would change MacAgent's
  reviewed sequence, and isn't taken.
- **The denial**, stated in P31: a session that keeps the keychain locked buys an open entry and the refusal of every
  guarded change until you unlock it. The way out is yours: unlock the login keychain (it is unlocked at each login),
  and restart the node if it started locked. A session that deletes an item and plants its own buys the same refusal
  at every start, which unlocking doesn't clear: the node holds and tells you which item, and deletes it only on your
  word ([Open for the user](#open-for-the-user) 4). Reads,
  answers, `stop` and the acknowledgement go on.

### What the counter covers

Every journal entry, and through them every guarded change and every revocation. Each guarded kind's act (an
update, hooks, a first config accept, a setting or floor, a plugin, a device added) appends a `guarded` entry before it
is done (not open), and acts only once that entry is counted. Each revocation (`device.lock`, `phone.off`,
`dropUnlocks`, `web.revoke`: `.acts` kinds that don't raise slice 20's epoch) appends a `revoked` entry (not open): an
older vault put back over "Lock now" would otherwise bring the unlock back for the rest of its 12 hours with only a
restart's notice. They are rare: one counter raise each (one keeper swap; written when it was a Keychain write). A revocation is never refused for a failed raise (P36).
**A device's removal** (`device.remove`; the re-check's N-d) is one rule with slice 20's epoch, which rises on an add,
a removal or a rename: it appends its `revoked` entry (`what: device.remove`) and raises the epoch, and acts only once
both raises succeeded; otherwise it is refused, `recordUncounted`. Its refusal says what to do instead, right there:
"Your node can't remove a device while its keeper isn't answering. Lock the device now, which always works and ends
what it can do; it will be removed once the keeper answers." (Corrected for the keeper, as the keeper design's words
are; it never mentions a password.) A refused removal is retried by itself: the vault records it as waiting (sealed as
any vault change is, not counted), the page's device list and `status` show "Removal waiting: your node's keeper isn't
answering", and the next raise that succeeds carries the removal out with its
`revoked` entry and epoch raise, so a lost phone isn't left listed because the removal was forgotten
(`HostJournalTests.aRefusedRemovalIsRetriedWhenTheRaiseSucceeds`). Your voice was the removal's own request; a waiting
removal lost to a put-back leaves the device listed and shown, never removed unseen. The epoch's side is slice 20's,
with device keys' I6 (**not read here**). So an older copy put back over any guarded change reads as `older`, and a raised
review floor or a removed hook can't be quietly undone (unless the counter is set back with it, P34 and P35). Not
covered: the vault's other records, such as a request's record (rule 8) or a page's draft. Those between a copy and
its putting-back are lost with no entry of their own, and the restart that loading the copy needs is a `host.start`
entry, open. A Keychain write on every vault change (the book saves on each) would cost far more than on guarded
changes and events, which are rare.

### Where the vault's other contents stand

**Whenever the record begins again at a host's start, for every reason** (the review's I3; [Fail closed](#fail-closed)'s
table rows 1 to 7; `full`, row 8, is the one exception: it happens while a host runs, whose vault in memory is its own), a Mac node's vault doesn't take its other contents as they stand. Today `VaultFirstLook.holds` is false whenever
the code identity is available (`VaultFirstLook.swift:16`), so a Mac vault that starts empty seals its first look as
it finds it (`LeadVault.swift:668-669`): a session that lowered a floor in a project's `workflow.md`, changed rails or
added a hook to `~/.claude/settings.json`, then deleted `vault.sealed` and restarted the host, would have its changes
sealed as the baseline, and nothing you acknowledge would restore it. So, on a checked Mac node (J0a's rule 2: no other
mode changes):

- **every record that begins again holds its first looks** (`holdsFirstLook`, Linux's S7 rule), `begins` included,
  since a first start can't be told from both files being deleted. Each record whose first look a fresh vault would
  hold waits for your accept, as on Linux after a host end;
- **the devices the vault still lists are held** as device keys' I6 holds them (slice 20). A vault that doesn't open
  lists none;
- **a journal that doesn't parse holds the vault as `older` does** (I7);
- **what an opened vault recorded is dropped too, not only what it hadn't.** `holdsFirstLook` holds only what has
  nothing recorded (`LeadVault.swift:1130-1138, 1149-1152`), so an older copy's recorded floors and seals would apply
  from the start. On `older`, `ahead`, `noCounter` and an unparsed journal (rows 5 to 7a), the vault's recorded first looks,
  seals and floors are dropped and held as a fresh vault's are, none applied until you accept it again
  (`HostJournalTests.anOlderCopysRecordedFloorsAreHeldNotApplied`);
- **the server's calls arrive as `.app`** (the re-check's N-e, read here): the node's server child is `.app` (the
  connector, `VaultV2Handler`; `HostImages.macServerRefusal`'s doc). The vault exempts `.app` from the rails'
  first-look hold (`LeadVault.swift:1132`: `if caller != .app, isHeld(root:)`) but not from the floor's (`:1150`). So
  on a Mac node the rails' hold rests on the server recording rails only through your accept
  (`ConfigHoldStore.swift:239-247`) or a guarded set (`NodeSettingsSet.swift:132`, `SessionPresets.swift:210`), as on
  Linux's S7 today. J3b's review walks those three callers by name.

Rolled-back or planted settings therefore never take effect unseen, short of P34 and P35 (stated limits until the keeper). The cost: after any record begins again, a first
start included, each setting the node checks waits for your accept once. Tests (J3b):
`HostJournalTests.aMissingFileHoldsItsFirstLooks`, `HostJournalTests.everyReasonHoldsItsFirstLooks` (row by row),
`HostJournalTests.anUnparsedJournalHoldsTheVaultAsOlderDoes`.

## What explains a start

A host's **end** is never seen while it happens: a killed or booted-out host writes nothing. So the record judges a
start by **what came before it in the record**.

**The unswitched-build rule, before every case** (the re-check's N-b): a `host.start` whose `build` isn't the
previous `host.start`'s, with no `switch` naming that build right before it, is **open whatever `how` says**, even
after your terminal `stop` and your typed `start`: "An older build of your node started, and you didn't switch to
it" (P41, `HostJournalTests.anUnswitchedBuildChangeIsOpen`). This is how a pinned older build that a session (or
your own typed start, after a session put it at `bin/`) loads shows. The older build's own code writes and judges
that entry; every build the record pins post-dates the switch-on review, which follows J4a, so each carries the rule,
and every later build keeps it (the test stays in the suite; dropping it is a change to this design).

Past that rule, a `host.start` is **explained**, and so not open, in exactly these cases (`how`):

1. **`switch`**: the host was given its state by the build before through a proven keeper (`MacHandoverKeeper`,
   `HostImages.mayTakeHandover` with `viaKeeper` true, rows 5 and 10), and the record's last entry is a `switch` whose
   `to` is this build's commit. A checked node takes no handover state file (`mayTakeHandover`), so a planted one
   can't claim a switch. A checked node's failed switch doesn't go back (`main.swift`: "No state file, no going back";
   the host ends), so the next start after it is open.
2. **Your `stop`, then your `start`**: the record's last two entries before this `host.start` are a `stop` the
   server took **through the terminal's route** (`via terminal`: the `approval` mode's dialog, appended before it
   acted) and the host's own `host.end` naming that stop's action. So a stop that didn't end the host (a session
   ignoring the hangup outlives it, the Mac spec) explains nothing later, and neither does a host killed before it
   wrote its end. `previous` is not asked (the re-check's R2: after the bootout and bootstrap of every stop and
   start it is always `unknown`, so a clean-exit clause could never pass; a host that sealed nothing between your stop
   and this start isn't shown, P39). No other `host.start` came between, and a `start.explained` follows within 120 s
   (`JournalAckTests.aTypedStartAfterYourTerminalStopIsExplained`, on the agent's real order: bootout, then bootstrap,
   `previous` unknown). On the Mac, `vibeswitcher start` loads the agent, waits for the server, then sends the `start` kind
   (today's `StartSequence` sends it as a request that changes nothing; on the Mac it becomes a voiced one). The server
   takes it only in your voice: the `approval` mode's dialog, after row 3's lines (a session's command line is refused
   before any dialog when the lines can tell). Its words name the start: "Confirm that you started your node at 14:02
   after you stopped it at 13:58", and carry the stop's date when it isn't today ("after you stopped it at 13:58 on 25
   November"), so a put-back `stop` and `host.end` (P35) can't read as today's. **The command line sends the voiced
   `start` only after its own `bootstrap` or `kickstart` succeeded** (the review's N2): never from `MacAgent.start`'s
   "the node runs already" branch (`MacAgent.swift:168`), and never after a failed bootstrap, so a session's start
   after your stop isn't explained by your typing `start` (`JournalAckTests.aStartThatFoundTheNodeRunningExplainsNothing`).
   The request names the host pid that the command line's own load produced
   (`launchctl print`'s `pid` right after its `bootstrap` or `kickstart`, as `NodeAgent.printed` reads it). The server
   explains only the newest `host.start`, and only when that entry's `pid`, the request's and its own host's are the
   same pid. One Touch ID per start you type after a stop, none at login.
3. **`login`**: launchd started the job at load (`speculative`), in your login session's `gui/<uid>` domain (the host
   reads its own manager name, `Aqua`), **the job's pid is the host's own** (`job` equals `pid`: the launchd fields
   describe the job, and a checked host needn't be its process; the re-check's N-j), and the host's audit session id
   differs from every `host.start` of this record in the same boot. **Never for a record's first `host.start`** (the review's N1): with no earlier start of this
   record to compare its audit session with, a record that began again (every start under `noKeychain`, for one)
   would let any `speculative` bootstrap in the same login pass. A start whose host logged `page.held` is never
   explained either: its `page.held` entry stays open whatever `how` says. **Off** (`JournalRecord.loginExplains =
   false`) until J-M1 measures that a process of yours can't start the job that way within your login, nor force a
   logout or restart and load ahead of the node at the next login, and you decide
   ([Open for the user](#open-for-the-user) 1). Until then a start at login is an open entry.

Everything else is open:

- a start after a crash, a kill, a `kickstart` or a `bootout` and `bootstrap`;
- **a start you typed after the node stopped without your `stop`**. You may see the node down and start it yourself,
  but its end is the thing to see, so the entry stays open with the cause launchd gives (`previous`): "killed", or
  unknown after a `bootout`;
- a start after your `stop` that you didn't start yourself;
- **a start after a `stop` sent from a page** (`via device:…`). `stop` is an unguarded kind, so a program driving your
  unlocked page can send one (device keys, accepted risk 1), take the page's address while the node is down, and wait
  for you to start the node. A page's stop explains nothing, so that start stays open;
- a `start` request whose pid isn't the newest start's, including a restart slipped in between your load and your
  request, which leaves both starts open;
- **a start of a build other than the previous start's with no `switch` naming it** (the unswitched-build rule
  above), whatever else explains it;
- a start after a host you stopped while it showed `lock.lost`: that host wrote no `host.end`;
- a first start.

**What an unexplained start gains an attacker on a Mac** (why it is worth your eyes): the time between the host's end
and its next start, which can be as long as the attacker likes, when its page's address is free (device keys, "Open to
attack" 4). A fresh host's memory also drops (the vault's ceremonies, guard challenges, in-flight acts). What it
doesn't gain: a different host. The checked start refuses any build but the anchored one (rows 4, 5), and the vault
survives on a signed node. So the open entry is your signal of a squat that needs the host's end, which is why it
holds guarded changes. A squat that needs no end (another socket taking the page's port while the host holds it, for
example with `SO_REUSEADDR` on a more specific address) is device keys' and row 8's, **not read here**. So is whether
the page's listener crosses a switch's handover.

## The acknowledgement

### It is a guarded change, with its own Touch ID

The device keys design lists "the journal's acknowledgment (the N6 kind to be added)" as guarded, "stricter than N6's
words". Its review called that right, and the lead's ruling for this task agrees (`v2-remaining`, item 6). The reason:
an acknowledgement clears the one signal that the node's address was free. The party that most wants it cleared is a
program that drove your unlocked page during those seconds, and the 12-hour unlock is exactly what device keys
accepts such a program can use (accepted risk 1). A guarded kind is never covered by the unlock: it needs a biometric
of its own, with the change shown by the Mac's own window, whose words a page's script can't change (N1, the lead's
ruling).

### On the wire

- **`journal.list`** (a read; an unlocked device, a desktop's read key, the command line): `{record, entries: [{seq,
  kind, at, words, open}], open: {through, digest, words} | null}`. `words` is the entry in plain words, built by the
  server from fixed text, times and counts only (no names, no paths, no hashes). `open` is what an acknowledgement now
  would cover.
- **`journal.ack`** (`.guarded`, `KindSpec`'s guarded table): args `{through, digest}`, through device keys'
  `guard.begin` (slice 14). The server builds the change's text from the vault's record (never from the args) and the
  guard's digest, which covers the kind and the args, so it covers this digest. A Mac node then asks its own Touch ID
  with that text (slice 23's route). At the act, on the server's queue, the guard is checked **before** `kept` and
  `retry` (device keys' N6). The server computes the digest again from the record as it is then: if it differs, the
  request is refused with `changed`, as `seenStands` does. The vault then checks the digest again itself before it
  appends the `ack`.

**The digest** (lower-case hex SHA-256), over UTF-8 text:

```
vibeswitcher-journal-ack-v1
record <record id, base64url>
through <seq>
<seq> <hex SHA-256 of that entry's bytes>      one line for each OPEN entry with seq ≤ through, in seq order
```

Each line ends with `\n`. An **entry's bytes** are `vibeswitcher-journal-entry-v1\n` followed by `record <id>`,
`seq <n>`, `kind <kind>`, `at <unix seconds>`, then each of the kind's fields in the table's order as
`<name> <base64url of its UTF-8>`, each line ending `\n`, a missing field as an empty value. It binds:

- **the entries, not a time:** an entry appended after `guard.begin` has a higher seq than `through`, so it isn't
  covered. One with a lower seq can't appear later, since seqs are the vault's and only rise.
- **the record:** an acknowledgement for a record that has begun again carries the old id, and is refused.
- **what you saw:** an entry changed by a bug or a restore changes its hash.

`through` must be the seq of an open entry and the list it covers non-empty: "nothing to acknowledge" is refused. The
whole list of open entries up to `through` is acknowledged, never a choice among them.

### Which key signs it, and what the vault checks, on each route

| Route | What carries your voice | Signed by | What the vault checks itself before it appends `ack` |
| --- | --- | --- | --- |
| **The Mac's own page** (the route N6 asks for) | the request in an unlocked device's signed frame (device keys slice 7), then the server's Touch ID window with the text | the frame: the device's unlock key (ECDSA P-256 over `vibeswitcher-frame-v1`…), certified by that device's passkey at its unlock. The Touch ID: **no key**. LocalAuthentication answers the server with yes or no | the digest against its own record; `via` a listed device with a live unlock; the approval is the server's word. **Refused on a Mac node by the journal's own constant** (the review's N3: device keys' `touchID {action}` refusal sits among `addDevice`'s approvals, not `journalAck`'s): `MacJournal.pageAck = false` (VibeCore, beside `holdsGuarded` in `DeviceGates.swift`), checked by the server before the guard and by the vault before it appends, refuses `journal.ack` from a page or a phone on a Mac node (`journalAckOnThisRoute`). Built by J7 with its test (`JournalAckTests.aPagesAckIsRefusedOnAMacNode`); **no slice lifts it**: the switch-on review (row 15) does, by the lead, once slice 23's route is built and reviewed, as it does `holdsGuarded`. Its anchor is then the checked server (rows 4, 7) and the app-only connector |
| **A phone paired to a Mac node** | the phone's passkey over `vibeswitcher-guard-v1\n` + origin + conn + challenge + guard digest (device keys) | the phone's passkey | the assertion itself (device keys slice 4's verifier) and the digest. **Phone access on a Mac node is off** until slice 17's measurement, so not before |
| **The terminal fallback** (no device, or no page) | `vibeswitcher status --ack` in Terminal.app: it shows `journal.list`'s `open` words, then sends `journal.ack {through, digest}` as a state change; the server's `approval` mode asks Touch ID with the same text | **no key**: the caller check (row 3's lines) then the dialog | the digest; `via terminal`; the server's word for the dialog, as above. Off with the rest of the Mac's voice (`NodeSystem.approvalMeasured`); refused from the Mac app's shell cards by the environment line |

**Stated plainly for the reviewer:** on a Mac node today, nothing the vault can verify proves a biometric. **On both
Mac routes, the page's and the terminal's, the anchor is the checked server** (the review's N3): the vault takes the
server's word for the dialog. The proof that an acknowledgement was yours is that the checked server's own window,
whose text it built from the vault, returned yes, and that the vault took it over the app's own connector. The
terminal route is live as soon as `approvalMeasured` is; the page route only once the switch-on review lifts `pageAck`, after slice 23's route is built.
The anchor is the checked server, not a signature. A key the vault could check (a Secure Enclave key whose use needs the biometric, signing the guard digest)
would make it a signature. That is slice 23's choice for every guarded kind on the Mac, not the journal's alone, and it
needs a Keychain measurement with you at the keyboard.

### The words

On the page: the list, each entry in a line ("Your node was restarted at 14:02 on 27 November. You didn't restart it.
How it ended before: it was stopped by a signal (killed)."). The Touch ID window's text, built by the server: "Acknowledge
what happened to your node: it was restarted at 14:02 without you" for one entry. For several: the count and the
most serious and the count, "Acknowledge 3 events on your node, among them: its record was older than expected".
The order of seriousness: a lost lock (`lock.lost`, which only a restart clears), a record that began again (`older`, `ahead`, `missing`, `unreadable`, `noCounter`, `full`,
`noKeeper`, then `begins`), a page address held at the start (`page.held`), an unexplained start, a server restart. A `more` ranks as its `worst`. With the keeper, `noKeeper` (a run of failed raises while the host ran) takes the rank `noKeychain` had, which no longer arises. Each reason has its own words, for example `older`: "Your
node's record was put back to an older copy. Changes you made may have been undone.", `begins`: "Your node's record
begins here. If you didn't just set up this node, its record was deleted." and `noKeeper`: "Your node's keeper didn't
answer for a while; changes that ask for Touch ID were refused." No hashes, ids, commands or internal names
anywhere a person reads (the user's bar). Whether the window shows a long reason whole is **not measured** (J-M3; the
dialog's words are open from K-LA-1, owed step 1). The words are kept under 120 characters until then.

**A lookalike window** (M9: a session can raise a LocalAuthentication dialog under its own program's name and any
words) gains nothing by your approval: no secret comes back, and the node's acknowledgement is only the server's own
evaluation. What remains is prompt fatigue: being trained to approve windows you didn't ask for (device keys' stated
limit, unchanged).

## What the node refuses while something is open

While the record has an open entry, or the server can't read the record (a vault request that fails or doesn't
answer), the server refuses **every guarded kind except `journal.ack` and the first device's enrolment** (while no
device is listed, **held devices counting as listed**: device keys' W3; the review's N4). The first enrolment's
window names the open record's most serious reason first ("Your node's record was missing. Add this device?"), since
a session can make "no device listed" happen at will by deleting the vault (`missing`), which is device keys' "Open to
attack" 5 moment. The refusal is `journalOpen`, worded "Review what happened to your node first", and
carries `journal.list`'s `open` so the page opens the review. The same refusal comes from any sender: the page, a
phone, or the command line's own forms of those kinds.

- **Why guarded changes:** they are the changes whose worth rests on the node being the one you think it is (an
  update, hooks, a plugin, a review floor, a new device). An open start says it may not have been, for some seconds.
  One Touch ID for the acknowledgement comes before the change, not instead of it.
- **Why not more:** reads, answers, messages and typing are what device keys lets an unlock do. Holding them would
  hold your day on a crash, and the acknowledgement is one click away. `stop` is never held: stopping is the safe
  direction.
- **The acknowledgement itself is never held,** not even when the counter can't be raised (`noKeeper` with the keeper;
  `noKeychain` as first written): it is then
  appended uncounted, and a put-back that loses it only reopens what it covered. Guarded changes are then refused for
  the failed raise ([The journal's counter](#the-journals-counter)), not for the open entry.
- **Why the first enrolment isn't held:** a record that begins again (a lost vault) loses the device list with it,
  since both are in the vault. Holding the enrolment would leave only the terminal to acknowledge from, against the
  user's direction (nothing day to day in a terminal). After `older`, `ahead`, `noCounter` or an unparsed journal on
  a Mac with no phone, the vault's devices are held and no first enrolment is offered (they count as listed): held
  devices have no way back until slice 20's Mac arm gives one, and **the terminal is then the only acknowledgement
  route** (said here; the cost of N4's rule). **A program of yours can cause this at will** (the re-check's N-g): for
  `older`, copy the file, cause one counted append (kill the server child), kill the host and put the copy back; for
  `ahead`, lock the keychain, kill the server child and kill the host. Meanwhile the page's devices are unusable on
  that Mac, and Terminal is where you acknowledge (`vibeswitcher status --ack`) and make the changes the command line
  has its own forms for; nothing in this design gives the page back before slice 20's way back.
- **Behind its own gate:** `MacJournal.holdsGuarded` (VibeCore, beside device keys' gates in `DeviceGates.swift`),
  false. Slice J8 builds the refusal with a test that, with the gate false, the refusal set and `hello.kinds` are
  byte-identical to before. **No slice switches it on.** Its switch is the switch-on review's (row 15), by the lead,
  with `approvalMeasured`, `isCheckedMacNode`, `macUnbuilt` and `pageAck`, which no slice here touches either. **It
  may be switched on only once the page's acknowledgement route is live** (slice 23's dialog route built, and `pageAck`
  lifted by the same switch-on review; the review's N3), not with the terminal's route alone: with only the terminal, every login would need Terminal
  before any guarded change, against your direction (nothing day to day in a terminal). Before any route, every start
  is open and nothing can acknowledge it, so every guarded change would be refused for good.

**Linux refuses nothing for an unacknowledged entry** (read: `Status.journalLines` only shows lines; `start` refuses
only without the `not-promised-ack`). This refusal is new, and the Mac's alone.

## Across a host end and a node restart

- **A host end:** the record is in the sealed vault (a signed node) and survives. The new host reads it, appends its
  `host.start` (open unless explained), and continues the seq.
- **What doesn't survive:** guard challenges and in-flight ceremonies (the host's memory only, device keys' K5). An
  acknowledgement begun before the end is begun again. An acknowledgement whose act was in flight was either appended
  before the end (the vault seals before it answers) or not. Its retry needs a new guard (N6), and its digest now
  misses the new `host.start`, which stays open.
- **A switch** (`build.switch`): the `switch` entry is appended before the handover. The vault rides in memory through
  the proven keeper, and the new build appends `host.start` with `how = switch`.
- **A server restart:** the host appends `server.restart`, open. The new server reads the record through the vault as
  the old one did.
- **The Mac restarting or you logging out:** the next start is at login (`speculative`). Open until J-M1 and your
  decision (above). A process of yours can force a logout or restart (an AppleEvent to loginwindow or System Events;
  `launchctl bootout gui/<uid>`), so the next start being a real login says nothing about who ended the host before
  it (J-M1 (a)); and a job of its own in `~/Library/LaunchAgents` can bind the page's address at login ahead of the
  node (J-M1 (b)), which the node's `page.held` entry shows.
- **No key: with the keeper, this doesn't arise** (a host that gets no key from the keeper exits 78 having read
  nothing: the keeper design's decided Open questions 1). As first written, **no Keychain key** (an unsigned build
  after its first update, row 12's decision; a locked keychain at the start):
  the vault is memory only (`VaultStorage.key` nil), so each host start begins a new record with `record.begins`
  (`reason: noKeychain`), open, and refuses guarded changes for its life (the review's I2). Fail closed, at a cost:
  [Open for the user](#open-for-the-user).

## Fail closed

Every unusual state of the record has one outcome: **the record begins again**. There is a new record id, seq 1 is a
`record.begins` entry with its reason (open), and the old entries are not shown as trusted. **The rest of the vault,
for every reason at a host's start** (the review's I3; `full` excepted, row 8): on a Mac node it is never taken as it stands. A file that doesn't open, or isn't
there, starts empty, as `VaultStorage` already does (`startingOver`); a file that opens but whose journal doesn't parse
or doesn't match its counter (rows 7 and 7a) keeps its contents held. Either way the vault **holds its first looks**
(`holdsFirstLook`, Linux's S7 rule), and the devices it still lists are held as device keys' I6 holds them:
[Where the vault's other contents stand](#where-the-vaults-other-contents-stand).

The host checks in this order, and the first check that fails names the reason (the review's I7): **the key, the
file, open, parse, then the counter**, every one of them after it holds the node's lock ([One
writer](#one-writer-and-a-counter-bound-to-the-last-entry) 1).

| # | State at the host's start | `reason` (its words on the page) | The rest of the vault |
| --- | --- | --- | --- |
| 1 | the key or the counter **is there but can't be read without asking**, or the login keychain is locked (the host never asks: no window). An item that **isn't there** is not this row: an absent key is made (rows 2 to 4 then apply), an absent counter is rows 3 and 6 | `noKeychain` ("Your node couldn't use its key in your login keychain.") | empty, memory only for this host's life; first looks held; guarded changes refused for its life (I2) |
| 2 | no vault file and no counter item (a first start; or both deleted, which can't be told apart from it) | `begins` ("Your node's record begins here. If you didn't just set up this node, its record was deleted.") | empty; first looks held, a first start's too |
| 3 | no vault file, counter item present | `missing` ("Your node's record was missing.") | empty; first looks held |
| 4 | the file doesn't open: truncated, changed, sealed with another key, or the key absent and a new one made at row 1 (`VaultStorage.book`'s `startingOver`) | `unreadable` ("Your node's record couldn't be read. Changes you made may have been undone.") | empty; first looks held |
| 5 | it opens, but the journal part doesn't parse: an unknown version, a field missing or extra, seqs not strictly rising (gaps are the trim's and allowed), a record id that isn't 16 bytes, an entry over 4 KiB, more than 600 entries | `unreadable` (the same words) | held as for `older`: first looks held, devices held |
| 6 | a file and a journal but no counter item | `noCounter` ("Your node's record lost its check. Changes you made may have been undone.") | held: first looks held, devices held |
| 7 | the counter's record id differs from the file's, or its seq is higher than the file's last (an older copy, or a lost seal), or the same record and seq with a `bind` that isn't the file's last entry's (another host's history at that seq, the re-check's R1: [One writer](#one-writer-and-a-counter-bound-to-the-last-entry)) | `older` ("Your node's record was older than expected. Changes you made may have been undone.") | held: first looks held, devices held |
| 7a | the same record id, and the counter's seq **lower** than the file's last: the file was sealed past failed raises (I2), or a file sealed then was copied and is put back now over later counted changes. Both are the host's own seals, but not necessarily its newest, so it is **refused, as the first version refused it** (`HostJournalTests.aFileAheadOfItsCounterBeginsAgainHeld`) | `ahead` ("Your node's record went on without its keeper, or an older copy was put back. Changes may have been undone."; was "…while your login keychain was locked…", corrected for the keeper and kept under 120 characters) | held: first looks held, devices held |
| 8 | while a host runs: 500 kept entries that the trim can't drop, and another entry ([below](#fail-closed)) | `full`, carrying the counts by kind and the `worst` of the open entries it couldn't keep, and ranked as that worst or as `full`, whichever is more serious ("Your node had more events than its record can hold, among them: something else held its page address") | kept as it is: it is the running host's own |

Rows 4 and 5 share their words, never `older`'s condition: whether the last seq is the counter's is asked only at row
7, after the parse.

**Entries never change once written** (the review's I6). Whether an entry is open is **derived** from the record,
never stored on the entry: an entry of a kind that is open by kind (`record.begins`, `server.restart`, `more`, the
bind entry of [What explains a start](#what-explains-a-start), a `host.start` that nothing explains) is open until an
`ack` covers it (its seq at most that `ack`'s `through`, its line in that `ack`'s digest). A `host.start`'s
explanation is derived from the entries around it. So nothing appended later can change an entry a `through` already
showed, and an `ack` can never carry a later event in as acknowledged.

**The trim.** The record keeps at most 500 entries. When it is full, entries that aren't open are dropped, oldest first,
and **an open entry is never dropped**. Two more rules keep dropping from opening or closing anything: an entry that
explains a kept `host.start` (its `switch`, its `stop` and `host.end`, its `start.explained`) is dropped only with
that start, and an `ack` only once every entry it covered is dropped. The kept seqs can therefore have gaps: the parse
asks only that they rise, and the counter that the last one is its (row 7). A dropped entry can't be put back in a
gap, since the vault is sealed and only the host appends. A record whose 500 kept entries can't be trimmed (every one
open, or kept by those rules) begins again when the next entry comes, with reason `full`, open. Its `record.begins`
carries `counts` and `worst` of every open entry the old record held, and ranks as that worst (or as `full`, if more
serious), so the window names the most serious of them ("…, among them: something else held its page address"); the
entry that came is the new record's seq 2. That is the one time a record begins again while a host runs, and it keeps the
rest of the vault as it is, since the vault in the running host's memory is its own.

**Past 64 open entries,** each further open event is appended as a new `more` entry, in place of its own kind's, **except a `host.start`, which is always appended as itself** (each needs a host start, and its fields, `pid`, `login`, `build`, are what explains it or not). A
`more` is never raised or changed: each carries `counts`, the count by kind of every event appended as a `more` since
the 64th open entry, this one included (`host.start=1,server.restart=64`, in seriousness order), and `worst`, the
most serious kind among them. A `more` **ranks as its `worst`**, so the window and the page name the most serious
event however it was counted: "Acknowledge 65 events on your node, among them: it was restarted without you". The page
lists every open entry that isn't folded (more than 64 can exist, since a `host.start` is never folded) and the
newest `more`'s counts; the digest covers each `more` like any open entry.

A journal that can't be read through the server (the vault doesn't answer) is treated as open: guarded kinds are
refused, `status` says the journal can't be read, and nothing is acknowledged.

## Every path to the property

Each way an entry could be made to look acknowledged, explained or never written, or to vanish, with the check that
refuses it and the acceptance test that proves it (planned names: `Tests/VibeCoreTests/JournalRecordTests.swift`,
`Tests/VibeHostTests/HostJournalTests.swift`, `Tests/VibeNodeTests/JournalAckTests.swift`, `Tests/VibeNodeTests/JournalRefusalTests.swift`).

| # | Path | Check | Test |
| --- | --- | --- | --- |
| **Forge** | | | |
| P1 | Write a unified log entry under `dev.vibeswitcher.node`, under the command line's image by its UUID (M10) | nothing reads the unified log: no source in the node's targets (`VibeCore`, `VibePlatform`, `VibeHost`, `VibeNode`, `vibeswitcher-host`, `vibeswitcher-cli`) or in `scripts/` runs `/usr/bin/log` or a `log show`, `log stream` or `log collect` command, uses `OSLogStore`, or names `Platform.Service.unifiedLogTool`, which J9a deletes (`Service.swift:46`, `Service+Darwin.swift:13`, `Service+Linux.swift:12`; used nowhere). The lint reads code, not prose, and leaves the app's benches alone (`UIBench.swift:959`, `BoardBench.swift:440` run `/usr/bin/log` in `Sources/VibeSwitcher`, which isn't the node's) | `JournalLintTests.noNodeSourceReadsTheUnifiedLog`, `JournalLintTests.unifiedLogToolIsGone` |
| P2 | Write a Linux-style command line entry (`logger -t vibeswitcher`, a datagram to a journald socket path) | the Mac's record takes nothing from outside the host and the app's connector; `Journal+Darwin` sends nothing | `HostJournalTests.aCommandLineEntryExplainsNothingOnTheMac` |
| P3 | Append through the vault from a session's process | the vault's journal requests answer `caller == .app` alone | `JournalRecordTests.aNonAppCallerCantAppendOrAcknowledge` |
| P4 | Edit entries in the sealed file | ChaChaPoly under the vault's key (the keeper's; written when it was the Keychain's): a changed file doesn't open, so the record begins again (`unreadable`) | `HostJournalTests.aChangedFileBeginsAnOpenRecord` |
| P5 | The server appends a host's kind (`host.start` explained, `record.begins` absent) | the vault takes only `start.explained`, `stop`, `switch`, `guarded`, `ack` from the server | `JournalRecordTests.theServerMayAppendOnlyItsKinds` |
| P33 | **The deputy** (the review's I1): read `record` and the last `seq` from `journal.list`, kill the host, craft a vault (same record, that seq, its own device, lowered floors), hand it to the genuine build as a scratch home's user's host (`VIBESWITCHER_HOME=/scratch --handover /scratch/state`), let it seal under the node's key, swap the file in | only the checked node start calls the node's items (J0a's rule 2); a checked start takes no state file (rule 3); the app's item, which the deputy can reach, isn't the node's (rule 1); the receiving side refuses before any secret or write (`the-session-host-s`'s requirement, carried by J0b) | `HostJournalTests.noOtherModeTouchesTheNodesItems` (with N-a's arms: no handover at all, the `--test-checked-shape` host), `HostJournalTests.aCheckedStartTakesNoStateFile`, `JournalLintTests.theNodesItemsAreNamedInOneFile` |
| P40 | **Two checked hosts** (the re-check's R1): delete `host.lock`, run the installed host with the job's command line beside the running node, keep a copy of the second host's file, kill it, let the first host append (a killed server child, your raised floor), kill it and put the copy back; or, without deleting the lock, let the second host seal its `host.start` before it finds the lock held | one writer: the lock is taken before the record is read for writing, so a second start beside a held lock exits having written nothing; a host whose lock's path changed or whose lock it no longer holds writes nothing more and shows `lock.lost`; the counter binds the last entry in a form `journal.list` doesn't show, so two histories at one seq never both match (`older`); each raise a compare-and-set, the Keychain's two calls backed by the lock check after the set; the keeper's raise atomic. **At `b225d8c0` none of these was stated, and the steps undid your floor behind two "restarted" notices.** **Not stopped in the Keychain:** a session that drives both hosts' timing (one stopped between its read and its update) and swaps the lock's file back between their checks gets both past them; a stated limit, closed only by the keeper's atomic compare-and-set ([One writer](#one-writer-and-a-counter-bound-to-the-last-entry) 4) | `HostJournalTests.aSecondCheckedStartBesideTheNodeWritesNothing` (J0a's test, J3a's arm), `HostJournalTests.aDeletedLockStopsTheHostsWrites`, `HostJournalTests.aReplacedLockStopsTheHostsWrites`, `HostJournalTests.twoRecordsAtOneSeqDontMatchTheCounter`, `HostJournalTests.twoHostsRacingARaiseLeaveOneHistory`, `HostJournalTests.aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet`; the keeper's own tests |
| **Explain falsely** | | | |
| P6 | End the host, start it again (`kill`, `kickstart`, `bootout` + `bootstrap`); or end it, squat, and let you start it yourself | `how = other`: open; your typed `start` explains only a start whose record's previous entries are your terminal's `stop` and the host's `host.end` for it | `HostJournalTests.aStartNothingExplainsIsOpen`, `JournalAckTests.aTypedStartAfterAnEndNoStopExplainsIsOpen` |
| P7 | Run `vibeswitcher start` from a session to explain its own restart; or restart the host between your load and your `start` request so your voiced `start` explains the session's start | `start.explained` only for a `start` taken in the `approval` voice (the dialog); row 3's lines refuse what they can tell before it; the request's pid must be the newest `host.start`'s and the server's own host's | `JournalAckTests.aStartWithoutTheVoiceExplainsNothing`, `JournalAckTests.aStartExplainsOnlyThePidItLoaded`, `JournalAckTests.aStartThatFoundTheNodeRunningExplainsNothing` |
| P8 | Re-bootstrap the job so it reads as a login (in `gui/<uid>`, in `user/<uid>`, through `launchctl asuser`, `open` or LaunchServices); or delete the vault first so the record's first start has nothing to compare with (the review's N1) | `loginExplains` false: a `speculative` start is open; when switched by J-M1 and you, only an `Aqua` job whose pid is the host's own and whose audit session no start of this record in this boot had, and never a record's first start | `HostJournalTests.aBootstrapInTheSameLoginIsOpen`, `HostJournalTests.aStartOutsideTheAquaDomainIsOpen`, `HostJournalTests.loginNeverExplainsARecordsFirstStart`, `HostJournalTests.loginNeedsTheJobsPidToBeTheHosts` (N-j) |
| P37 | Force a logout or restart (AppleEvent, `launchctl bootout gui/<uid>`), with a job of its own in `~/Library/LaunchAgents` that binds the page's address at login ahead of the node, so the squat hides in the routine login notice (the review's N1) | the host appends an open `page.held` entry when it can't bind the page's address at once, whatever `loginExplains` says; J-M1 (a) and (b) before `loginExplains` can be considered | `HostJournalTests.aPageAddressHeldAtStartIsOpen`; J-M1 (a), (b) |
| P9 | Start the node after your own `stop` (you didn't start it) | a stop alone explains nothing: open until your voiced `start` names its pid | `HostJournalTests.aStartAfterYourStopIsOpen` |
| P41 | Kill the host, put a pinned older build's server at the node root's `bin/`, and start that build (`--node`, or wait for you to start it) | the unswitched-build rule: a `host.start` whose `build` isn't the previous start's with no `switch` naming it is open, whatever `how` says, even after your terminal `stop` and typed `start`; every pinned build carries the rule | `HostJournalTests.anUnswitchedBuildChangeIsOpen` |
| P9b | A terminal `stop` that didn't end the host (a session kept it up), then a kill later and your own `start` | rule 2 needs the host's own `host.end` for that stop's action right after it | `HostJournalTests.aStopWithoutItsHostEndExplainsNothing` |
| P9a | Send `stop` from your unlocked page (a driver), squat the address, let you start the node yourself | only a `stop` taken through the terminal's route (`via terminal`) explains a later start; a page's stop leaves it open | `JournalAckTests.aPagesStopExplainsNoStart` |
| P10 | Plant a handover state file claiming a switch | a checked node takes state only from a proven keeper (`HostImages.mayTakeHandover`); `how = switch` needs the record's `switch` naming this build | `HostJournalTests.aSwitchExplainsOnlyWithItsRecordedSwitch` |
| P11 | End the server child | `server.restart`: open | `HostJournalTests.aServerRestartIsOpen` |
| P11a | Get your `start` dialog approved for a restart you didn't do (a session's `start` through a launchd escape, timed for when you expect a Touch ID) | the words name the start's time and your stop's; with no `stop` before it, no `start` explains anything | `JournalAckTests.theStartsWordsNameItsTimes` |
| **Make it vanish** | | | |
| P12 | Delete the vault file, after changing a floor, rails or a hook so a fresh vault takes them as its baseline (the review's I3) | `missing` (counter present) or `begins` (both gone): open; on a Mac node every record that begins again holds its first looks, so nothing on disk becomes the baseline unseen | `HostJournalTests.aMissingFileBeginsAnOpenRecord`, `HostJournalTests.noFileAndNoCounterIsOpenToo`, `HostJournalTests.aMissingFileHoldsItsFirstLooks` |
| P13 | Put back an older copy (dropping entries or an `ack` it lacks) | the counter: `older`, open. **Stopped unless** the counter is overwritten in place to match the copy (P34, measured kind) **or the login keychain file is put back with it** (P35, I4, expected): then not stopped until [Open for the user](#open-for-the-user) 2's keeper. This holds once the one-writer rule and the bound counter are built (J3a). **At `b225d8c0` it didn't:** a copy made by a second checked host beside the node matched the counter at the same seq as the first host's later entries, with no Keychain write of the session's own (R1, P40) | `HostJournalTests.anOlderCopyBeginsAnOpenRecord`, `HostJournalTests.twoRecordsAtOneSeqDontMatchTheCounter`; J-M2 C, E |
| P14 | Delete or reset the counter (with the keeper, its `journal` slot: only root can, since no request deletes a slot; as first written, the Keychain item, if J-M2 showed it could be done without a dialog) | `noCounter`, open; a counter whose id or seq differs, `older` | `HostJournalTests.aMissingCounterIsOpen` |
| P15 | Remove the vault's key (with the keeper: only root, by deleting the keeper's store, after which the keeper makes a new key, the keeper design's KP25; as first written, the Keychain key) | a new key is made and the file doesn't open: `unreadable`, open; first looks held | `HostJournalTests.aLostKeyBeginsAnOpenRecord`, `HostJournalTests.everyReasonHoldsItsFirstLooks` |
| P16 | Flood open entries so one is pushed out, or buried in a `more` ranked last (the review's I6: 64 server restarts, then a squat's `host.start`) | open entries are never dropped; entries never change; past 64, each open event is a new `more` with counts by kind, ranked as its worst; a full record that can't be trimmed begins again (`full`), open | `JournalRecordTests.openEntriesAreNeverDropped`, `JournalRecordTests.aMoreRanksAsItsWorst`, `JournalRecordTests.entriesNeverChange`, `JournalRecordTests.theTrimNeverOpensOrClosesAnEntry` |
| P17 | Make the record unreadable to the server so the hold lapses | unread is open: guarded kinds refused | `JournalRefusalTests.anUnreadableRecordHoldsGuardedKinds` |
| P18 | Kill the host between the counter's raise and the seal | the counter ahead: `older`, open (a crash here is rare and shown) | `HostJournalTests.aCounterAheadOfTheFileIsOpen` |
| P42 | Lock the keychain, kill the server child, kill the host (the file sealed past failed raises); or copy such a file and put it back later over counted changes | the file ahead of its counter: `ahead` (row 7a), open, first looks and devices held | `HostJournalTests.aFileAheadOfItsCounterBeginsAgainHeld` |
| **Make it look acknowledged** | | | |
| P19 | Pre-acknowledge: begin an acknowledgement, then cause the event | the digest covers open entries with `seq ≤ through` only; the new entry's seq is higher | `JournalRecordTests.anAckDoesntCoverALaterEntry` |
| P20 | Replay an old acknowledgement, or one for an earlier record | the digest is computed again at the act and by the vault; the record id is in it | `JournalRecordTests.anAckForAnotherRecordIsRefused`, `JournalAckTests.aChangedRecordIsRefusedChanged` |
| P21 | Repeat a done acknowledgement's action id after new entries | the guard before `kept` and `retry` (N6): a new biometric; the digest differs | `JournalAckTests.aRepeatedAckActionNeedsANewGuard` |
| P22 | Acknowledge from the unlocked page with no biometric (a driver, accepted risk 1) | `journal.ack` is `.guarded`: refused without the guard's approval | `JournalAckTests.journalAckIsGuarded`, `JournalAckTests.anAckWithoutTheGuardIsRefused` |
| P38 | Acknowledge from a Mac page once slice 14 routes a page's guard to the server's dialog, before slice 23 (the review's N3: nothing listed refused it) | `MacJournal.pageAck` false: the server and the vault refuse `journal.ack` from a page or phone on a Mac node; no slice lifts it | `JournalAckTests.aPagesAckIsRefusedOnAMacNode` |
| P23 | Acknowledge "nothing", or a selection, so a later open entry is skipped | non-empty, every open entry up to `through`, `through` an open entry's seq | `JournalRecordTests.anAckCoversEveryOpenEntryUpToThrough` |
| P24 | A session's `vibeswitcher status --ack` | the `approval` voice: row 3's lines first, then the dialog with the vault's words | `JournalAckTests.aSessionsAckIsRefusedBeforeADialog` (a fake judge) |
| P25 | Mislead the words: a device renamed to read like an all-clear, a project name in an entry | the words come from fixed text, times and counts; no recorded string reaches the dialog or the page's list | `JournalAckTests.theWordsHoldNoRecordedText` |
| P26 | Put a lookalike Touch ID window up (M9) | gains nothing: the acknowledgement is the server's own evaluation | none: a stated limit (prompt fatigue) |
| **Stated limits** | | | |
| P27 | Become the host, or replace the command line (S11 item 3, T3, T12) | the checked start refuses another build by cdhash (rows 4, 5, 7, 10); past that, **accepted** as today | the rows' own tests |
| P28 | Lose a request's record (rule 8) by putting back an older vault between two journal entries | the restart needed to load it is a `host.start`, open; the request records themselves aren't counted | `HostJournalTests.anOlderCopysRestartIsOpen` |
| P29 | Undo a guarded change (a raised floor, a removed hook) by putting back an older vault | every guarded act appends a `guarded` entry and acts only once its counter raise succeeded ([The journal's counter](#the-journals-counter)): `older`, open; the older vault's first looks held, devices held (I6). **Stopped unless** the counter is overwritten in place to match (P34) or the login keychain file is put back with the vault (P35, I4): then not stopped until the keeper. This holds once the one-writer rule and the bound counter are built (J3a). **At `b225d8c0` it didn't:** a second checked host's file put back over the first host's guarded change at the same seq continued the record (R1, P40) | `HostJournalTests.anOlderCopyOverAGuardedChangeIsOlder`, `HostJournalTests.anOlderCopyHoldsItsFirstLooks`, `HostJournalTests.aSecondCheckedStartBesideTheNodeWritesNothing`; J-M2 C, E |
| P30 | Sign a program as the host (the local identity unlocked, holder (4)), or be one you clicked Always Allow for (5), and rewrite the vault and counter | **With the keeper (decided, 9CDB5A99): stopped for the node's record.** The node keeps no Keychain item; the keeper holds the key, the counter and slice 20's epoch, and serves only a caller whose running code is the host cdhash of a row of the root-owned pins record, never by signing identity, so a program of its own code, or the genuine host signed again, is refused, and the vault's secrets are read by no process of yours (keeper design, its threat table and KP9, KP15). What stays: the genuine pinned host in another mode is kept away only by J0a's rule 2 (KP12), and every pinned build is served (P41). The app's own `lead-vault` key, with no access list, is main's. **Before the keeper** (as reviewed): not stopped in your account (expected, J-M2 B), its whole scope every guarded state, the devices and slice 20's epoch, and every secret in the vault ([What a holder of the vault's key reaches](#what-a-holder-of-the-vaults-key-reaches)) | `HostJournalTests.noOtherModeTouchesTheNodesItems` (its keeper arm); the keeper's `KeeperProofTests` (K2). J-M2 B no longer needed for the node |
| P34 | Overwrite the node's Keychain items in place: the counter set to an older copy's values with that copy put back (`journal.list` shows its `{record, seq}`; once the counter binds the last entry, its `bind` too, which `journal.list` doesn't show and the item doesn't give: whether that closes this form is J3a's review's to confirm, not claimed here); or the vault key set to one of its own and a vault of its making sealed under it, the counter set to match | **not stopped** in your account: measured on items of this kind (the lead's decision of 2026-11-26), so the keeper's trigger is met without waiting on J-M2. A delete-and-plant instead leaves an item the host can't read without asking, so every start is `noKeychain`, open, and refuses guarded changes for good: a denial whose way out is [Open for the user](#open-for-the-user) 4. Stopped only by the keeper (either form) | J-M2 C on the node's own item kind; then the keeper's own tests |
| P35 | Put `login.keychain-db` back with an older vault (the review's I4), then wait for or force a logout or restart (N1) | **not stopped** by the counter (expected, J-M2 E): file and counter match at the copy, so the record continues from it with no `older`; every guarded change since, slice 20's epoch and every entry since are undone. Stopped only by the keeper (either form: a put-back keychain file can't move a root-held counter or hash) | J-M2 E; then the keeper's own tests |
| P36 | Undo a revocation: put an older vault back over your "Lock now" (or phone access turned off, a web key revoked, or a device removed), so the unlock returns for the rest of its 12 hours; or lock the login keychain first so the revocation goes uncounted (the review's N5, with I2) | each revocation appends a `revoked` entry under the counter, so an older vault put back over a counted one reads as `older`, open. A revocation ("Lock now", `phone.off`, `dropUnlocks`, `web.revoke`) is **never refused** for a failed raise (refusing "Lock now" would be worse): an uncounted one can be undone by a put-back, which needs the host's restart (an open `host.start`) and, while the keychain stays locked, can't open the vault at all (`noKeychain`). A stated limit. **Under `lock.lost`** (R1's one-writer rule) a revocation acts in memory and isn't sealed, so the restart the notice asks for brings the unlock back as last sealed; the notice says to lock your devices again after the restart, a stated limit too. **A device's removal** is refused when its raises fail (one rule with slice 20's epoch, the re-check's N-d), its refusal saying to lock the device now, and retried by itself at the next raise that succeeds; so a removal is never uncounted | `HostJournalTests.anOlderCopyOverARevocationIsOlder`, `HostJournalTests.aRevocationIsTakenWhenTheRaiseFails`, `HostJournalTests.aRemovalIsRefusedWhenTheRaiseFails`, `HostJournalTests.aRefusedRemovalIsRetriedWhenTheRaiseSucceeds` |
| P39 | Lock the login keychain, kill the host, squat the page's address, let a keyless host start and record it, then kill that host before you look; you unlock at your next login | a keyless host seals nothing and takes no guarded change, so the next start with the key continues the record; its `host.start` is open (nothing explains it), but the keyless host's `noKeychain` and `page.held` are lost. A stated limit: one open "restarted" notice, not the squat's own words. **The set that leaves no notice at all** (the re-check's R2): when the sealed record ends with your terminal `stop` and its `host.end`, a host that sealed nothing, run between that stop and your typed `start` (one started without its key, one killed before its first raise, or one whose lock was replaced before it wrote; started by launchd or by a session), isn't shown: your typed `start` is explained by rule 2. Acceptable: it sealed nothing and took nothing guarded, and the page's address was free in that window by your own stop. At `b225d8c0` P39 named instead a keyless host ended by a page's `stop`, which can't happen (a keyless host lists no device, and its first enrolment is a guarded act it refuses), and rule 2's clean-exit clause meant to cover it could never pass. Told to you in [Open for the user](#open-for-the-user) 3. The keeper narrows it (no start is keyless while the keeper runs) | `HostJournalTests.aKeylessHostsSuccessorIsOpen` (a record that doesn't end in your `stop` and `host.end`), `JournalAckTests.aTypedStartAfterYourTerminalStopIsExplained` (bootout, then bootstrap, `previous` unknown) |
| **Denials** | | | |
| P31 | Lock your login keychain, or replace its items, again and again; or lock it just before a guarded change so the change goes uncounted, then put the older vault back (the review's I2) | a guarded act acts only once its entry's raise succeeded: refused `recordUncounted` otherwise ("Your node can't keep its record right now. Unlock your login keychain, then try again."); the raise retried at each later append, one success covering every entry before it; an open `noKeychain` entry; `stop`, restarts, revocations and the acknowledgement still taken. One rule for the journal's counter and slice 20's epoch. A **denial** while the keychain stays locked: every guarded change refused until you unlock it (and restart the node, if it started locked); after a delete-and-plant, until [Open for the user](#open-for-the-user) 4's way out | `HostJournalTests.aFailedRaiseRefusesAGuardedActAndStillTakesAnAck`, `HostJournalTests.aLaterRaiseCoversEveryEntryBeforeIt`, `HostJournalTests.anUncountedGuardedEntryIsNeverActedOn` |
| P32 | Kill the host or server every few seconds; open an entry at will (kill the server child, lock the keychain); or, from an escaped Terminal, keep the server's single dialog busy (one dialog at a time, then a cooldown, `ApprovalRequests.swift:65-68`) so no acknowledgement's window can be shown (the review's N4) | each is an open entry; the acknowledgement's ceremony can't finish while the node keeps ending or the dialog is taken, so guarded changes stay held. Every guarded kind needs that one dialog anyway, so the hold adds no lock-out the dialog channel doesn't already give: a denial **accepted**, as killing the node is. **The way out:** stopping from the page needs no dialog, and `KeepAlive` is false (`NodeAgent.swift:127`), so a killed host stays down | none: a stated limit |

## Differences from Linux

| | Linux (**read only here**: no Linux node was run) | The Mac (this design) |
| --- | --- | --- |
| The record | journald, the user's journal (`NodeJournal.readArguments`) | the node's sealed vault, with a Keychain counter |
| Who writes | the command line (`NodeContext.writeJournal`: `request`, `unanswered`, `stop`, `ack`, `not-promised-ack`), systemd (job lines), the host's stderr through the unit | the host and the server (app-only); never the command line |
| Why an entry counts | journald's own fields: `_UID`, and `_SYSTEMD_CGROUP` a terminal scope (`NodeJournal.passes`) | it is in the record, which only the app writes, and the record opened, parsed and matched its counter |
| What explains a start | a command line `start` or `stop` entry that passes, up to 120 s **before** it (`NodeJournal.unexplained`) | a `switch` before it, or your terminal's `stop` and the host's `host.end` before it and your voiced `start` naming its pid up to 120 s **after** it (no server exists before a start); `login` when measured and decided |
| What an acknowledgement covers | every event **earlier than** an `ack` entry that passes (`NodeJournal.acknowledged`: by time) | the open entries up to `through`, **by digest** |
| Its voice | the typed code on `/dev/tty`, from a terminal scope | a guarded kind: the Mac's own Touch ID window, from an unlocked device's page or from Terminal |
| Marks for accepted requests | the server's `accepted` list against the command line's entries (`NodeJournal.marks`) | none: each request's proof is checked when taken and recorded with it; no second witness exists (M10) |
| While something is unacknowledged | nothing is refused (only `start` without the `not-promised-ack`) | guarded kinds are held (behind `MacJournal.holdsGuarded`, off) |
| The not-promised list (S11) | `start` shows it once; its ack is a journal entry | not in this design: the Mac has no such list yet (the Mac spec: "For the switch-on review to decide"). If one is written, its ack is an `ack`-like entry of this record |

**Shared code** (compiled on both, VibeCore and VibeNode, platform-free): the record type, its entry bytes, digest,
parsing and the open-entry rule (`JournalRecord`); the wire kinds `journal.list` and `journal.ack` and their `KindSpec`
rows; the words. **On a Linux node** `journal.list` and `journal.ack` answer "not on this system" until Linux's own page
acknowledgement is designed. G3 (`v2-remaining`) builds "the journal's ack kind" for Linux, and this design doesn't
decide how Linux records it: a server-written journald entry wouldn't pass `NodeJournal.passes`, and Linux's vault is
memory only. Nothing Linux does today changes (slice J6's test).

**The Mac's arm**: `Journal+Darwin.swift`'s `send` (still nothing for the command line's datagrams; the host's sink
copy is a separate function), the host's journal (`HostJournal`), the vault's counter, the launchd and audit-session
reads, the refusal.

**Each command line call that writes the journal, on the Mac:** `NodeClient.change` (`request`, `unanswered`): nothing
(the vault's record of actions holds it). `StopSequence` step 5 (`stop`, which refuses the stop on Linux if the entry
can't be written): the Mac's stop goes through the server, which appends `stop`, and the command line's step is
skipped there (slice J5a checks no Mac stop is refused for it). `status --ack`: the Mac's arm above.
`StartSequence`'s `not-promised-ack`: not run on the Mac (the Mac's `start` isn't Linux's start sequence, the Mac spec).
**Readers:** `Status.journalLines`: on the Mac, lines from `journal.list`. `Switch.startLine`: unchanged ("the Mac: the
host writes no start line"; the `host.start` entry carries the build). `Logs.swift`: the Mac arm reads the stderr file,
said untrusted (slice J11).

## Measurements owed

None was run for this design or its revision (docs only). J-M1 to J-M4, and what each gates:

| # | What | Why it matters | How (no dialog / keyboard) |
| --- | --- | --- | --- |
| J-M1 | Whether a LaunchAgent's process gets a new audit session id at each login, and whether a process of yours can, within the login, start the job (or a job of the node's label) in `gui/<uid>` as `speculative` with an audit session id no start of this boot had: by `launchctl bootstrap gui/<uid>`, `bootstrap user/<uid>`, `launchctl asuser`, `open` or LaunchServices, and what manager name (`Aqua`, `Background`) each gets. Added (the review's N1): **(a)** whether a process of yours can force a logout or restart with no window (an AppleEvent to loginwindow or System Events, `launchctl bootout gui/<uid>`), so that the next start is a real login; **(b)** whether a scratch job in `~/Library/LaunchAgents` loaded at login can bind a scratch address (standing in for `127.0.0.1:47830`) before a second scratch job of the node's shape does, and what the second job's bind returns | `loginExplains` (Open for the user 1): it may be considered only once J-M1 is run **and** the `page.held` entry is built (J4b). Nothing else waits for it | **keyboard** (it loads scratch jobs and needs a log-out and log-in): a scratch agent printing `getaudit_addr`'s `ai_asid` and its manager name, loaded each of those ways in one login, then once after logging out and in; for (a), each way of forcing a logout tried once with your work saved, its window or its absence noted; for (b), two scratch jobs at one login, never the node's label or its address; a probe to add to `scripts/mac-measure`, not written here |
| J-M2 | On items of the node's kind (a generic password added with no access list, as `Keychain+Darwin.swift` adds them): **B** whether a different program signed with the same local identity and identifier reads an item a signed probe made, with no dialog (expected yes: P30); **B2** whether the same build run in another mode reads it (expected yes: the Keychain trusts code, not mode, so only J0a's rule keeps I1's deputy out); **C** whether an ad hoc program can read, delete, overwrite in place, or delete and plant it (read refused and the rest silent are expected from the lead's measurement of 2026-11-26: P34); **D** whether the item survives a rebuild under one identity and identifier, and not under ad hoc (N8's facts); **E** whether a keychain file copied and put back by path makes a fresh process read the older value, and when (the review's I4: P35) | **Since the keeper (2026-11-27): nothing of the node.** J3a's and J3b's real store is the keeper's client (the keeper design's K4), and the node keeps no Keychain item, so no Keychain probe is owed for the node; J-M2 stays here only as the record of what it would have measured. As written before: J3a's and J3b's Keychain arm (the real store behind `NodeKeychain`; until then their tests run on the in-memory store only) and what the interim limit in the threat table covers until the keeper is built. Not the keeper's trigger: P34's measured overwrite already met it | **keyboard, Keychain: with you only, under AGENTS.md's Keychain rule** (the review's N7). Every probe runs on a **scratch keychain file** made by `scripts/lib/scratch-keychain.sh` (on this repository's main; the clone's branch has neither the rule nor the script, so the session runs it from main's copy), made never to lock, on a scratch home, so your login and default keychains are never read or changed. The probes come from one source that makes, reads, updates or deletes a generic-password item under a scratch service (`dev.vibeswitcher.measure.<random>`) and **names the scratch keychain on every SecItem call**, never the default one. **Every call runs with interaction off** (`SecKeychainSetUserInteractionAllowed(false)`, as `Keychain+Darwin.swift` does), so a would-be dialog reads as `errSecInteractionNotAllowed` or `errSecAuthFailed` and is recorded as that code: the outcome is a status code, **never "a dialog appears"**. **No partition-list or access-list call** (no `-T`), **no timeout that kills a probe**, and no process is killed in a keychain call. The probes: **A**, signed with the local identity and an identifier of its own, makes the item; **B**, the same source with one function more, same identity and A's identifier, reads it; **B2**, A run with another argument (another mode), reads it; **C**, ad hoc, tries each of read, delete, `SecItemUpdate` in place, and delete then add; **D**, A rebuilt with one change under the same identity and identifier, then ad hoc rebuilt, each reads; **E**, the scratch file copied, A raises the item, then, **as the last probe, after every other probe has exited**, the copy put back **by rename** (a new file moved over the path, never written into, since securityd may hold the file open and the 2026-11-26 crash was securityd's), then a fresh A reads it, and again after the scratch keychain is opened afresh in a new process. Whether securityd re-reads the real login keychain at a login stays **expected**: E answers it for a scratch file only. **The probes carry their own guards** (the re-check's N-i: `scratch-keychain.sh`'s guards wrap the `security` tool only, `keychain_call`): each probe refuses to run unless `HOME` and `CFFIXED_USER_HOME` are the scratch keychain's home and its keychain argument lies under it; each SecItem call names the scratch keychain and passes the per-call no-UI flag as well as `SecKeychainSetUserInteractionAllowed(false)`; the script sources `scratch.sh` and `scratch-keychain.sh`, which make and delete the keychain. **How A, B and D are signed, settled:** by a sign-only step built from `build-app.sh`'s own search-list block (the block `setup-signing.sh` shares and `test-signing.sh` checks), run at the keyboard right after a build has unlocked the signing keychain, so no password dialog comes (`build-app.sh:160-163`) and the search list changes only as every build already changes it. Never a `security list-keychains` or `codesign --keychain` of J-M2's own. Not taken: a throwaway identity inside the scratch keychain, whose import needs `-T /usr/bin/codesign`, an access-list entry the Keychain rule and `keychain_call` refuse today; only the rule's owner (you) could allow it, and the sign-only step makes that unnecessary. J-M2 is ready to hand you once that sign-only step exists (it is J-M2's own script change, under `test-signing.sh`'s check). **If any keychain locks** during it, your login password unlocks it and nothing is lost. The probes, their scratch keychain and home are removed by the same session; no agent runs `security` or a Keychain call |
| J-M3 | The Touch ID window's words for a reason of 60, 120 and 200 characters | whether the acknowledgement's text shows whole. Gates nothing: the words stay under 120 characters until it is run | **keyboard**, with the runbook's owed step 1 (LA-1's words) |
| J-M4 | Whether another, non-admin user of the Mac can `log show` the node's subsystem | who reads the sink (kinds and numbers only). Gates nothing: the answer changes nothing | **keyboard** (another account): `log show --last 5m --predicate 'subsystem == "dev.vibeswitcher.node"'` as that user |
| measured | `log show` without admin (2 s); the writer's image forgeable by UUID | the unified log is a sink only | **M10** |
| measured | launchd's `immediate reason` (`speculative` with `RunAtLoad`, `non-ipc demand` after `kickstart`), `last exit code`, `last terminating signal` | the `host.start` fields | the Mac spec's "What a real Mac proved"; M11 |

## Engineering calls settled here

- **The record is the vault, the unified log a sink.** M10. Not "neither": the sink is a diagnosis copy for whoever
  looks into a fault, and with kinds and numbers, each line saying it is a copy, it misleads no decision. The node
  never sends you to it: a record that begins again is the moment a session has every reason to write a plausible
  history there (M10; the review's N6).
- **Entries are rare events, not every request.** Each needs a counter raise (a keeper swap; written when it was a
  Keychain write). Requests already have
  their record and proof.
- **One fail-closed outcome** (the record begins again, open) for every anomaly, instead of a case for each.
- **Binding by digest and seq**, not by time: a later entry can never be covered, and a clock can't be argued with.
- **A start is explained after it, by your voiced `start`**, since no server exists before a start on any system.
- **A typed start explains only after your terminal's stop and the host's end for it**, and only the start it loaded (P6, P7, P9): an end nobody asked for
  is the event worth seeing, whoever starts the node after it.
- **Every guarded act is a journal entry**, so the counter covers the changes a rollback would want to undo (P29).
- **A failed counter raise refuses guarded acts until a later raise succeeds** (P31; the review's I2, device keys' I6 rule for both items). `stop`, restarts, revocations and the acknowledgement are still taken.
- **The hold covers guarded kinds only**, never the ack itself, the first enrolment, `stop` or reads.
- **Device names never reach the words** (P25).
- **The counter and the vault's key are the node's own Keychain items**, beside slice 20's epoch, touched only by
  the checked node start (J0a, the review's I1).
- **One writer, a counter bound to the last entry, each raise a compare-and-set** (the re-check's R1): the lock
  before the record, a lost lock stopping every write, in the keeper too.
- **Rule 2 doesn't ask how the host before ended** (the re-check's R2): launchd can't say after a bootout; the
  no-notice set is stated instead (P39).
- **A device's removal is counted or refused, and retried by itself** (the re-check's N-d); the other revocations
  are never refused.
- **J-M2's probes are signed by a sign-only step from `build-app.sh`'s own block** (the re-check's N-i), never by
  an identity in the scratch keychain.
- **Entries never change; openness is derived** (the review's I6).
- **Every record that begins again holds its first looks on the Mac** (the review's I3).
- **The acknowledgement waits for slice 23** rather than taking a Touch ID record the vault can't check.

## Open for the user

**All four decided on 2026-11-27:** item 2 by 9CDB5A99 (the keeper), items 1, 3 and 4 by 90BBAD80 (the
recommendations taken). What the keeper changes in 1, 3 and 4 is said under each and, in full, in [the keeper
design](2026-11-27-v2-mac-keeper-design.md)'s "What happens to the journal's choices". The choices are kept as they
were put.

Four choices are yours. Each says what it means, the recommendation, what it costs you day to day, and what happens
if you choose otherwise. The identifiers for the reviewer are in brackets; the keeper's details are in [For the
reviewer: the keeper](#for-the-reviewer-the-keeper).

1. **A start when you log in: ask every time, or count it as yours?**
   - **Recommendation:** ask every time, until a test still owed shows that a program of yours can't make its own
     start look like a login, nor log you out and get its own program ahead of the node at the next login, and until
     the node's "something else held your page address" notice is built. Then count logins as yours, and keep asking
     after any other start.
   - **Day to day:** one notice and one Touch ID after each login or restart of the Mac. Once the hold is on (only
     when the page's own Touch ID route exists), changes that always ask for Touch ID wait until you've acknowledged
     it. A notice at every login can train you to approve the window without reading it.
   - **If you count logins as yours now:** no notice at login, but if that test finds a way, a program that kills the
     node and starts it that way leaves no notice. Either way, a record's first start is never counted as yours, and
     the node always leaves a notice when something else held its page's address as it started.

   [J-M1 with (a) and (b); `loginExplains`; `page.held`, J4b]

   **Decided (90BBAD80): ask every time.** The keeper sees no login and explains no start: unchanged by it.
2. **Signing and the record's anchor: one decision.** Today the node's record is anchored in your login Keychain, and
   a program of yours can rewrite the node's Keychain items without a window (measured on items of this kind). So it
   can put an older record back with the counter set to match, replace the node's key and whole record with its own,
   or (expected, not yet measured) put your whole keychain file back; and while your signing keychain is unlocked it
   can sign itself as the node and read the record's secrets. Each undoes or forges more than the journal: your
   devices, review floors, settings, and the record of what changed.
   - **Recommendation:** add a small system-level keeper, a root process that makes the record's key, holds it with
     the record's counter and your devices' check, and gives them only to the real node, by the code fingerprint your
     install record already pins. Your login Keychain then plays no part in the node's record, nothing of yours can
     read the record's secrets, and signing no longer matters to the journal (unsigned builds would do).
   - **Day to day, with the keeper:** one more `sudo` line at setup, beside the one you already run; one more
     privileged part, designed and reviewed on its own before any of it is built. It must be running for the node to
     keep its record: while it is down, the node starts without its key and refuses the changes that always ask for
     Touch ID. If its store is ever lost, the record begins again with a notice.
   - **If you accept the limit instead:** nothing to do now, and the risk is yours. The journal still catches the
     node being killed, a second copy of it run beside it, its record deleted, or an old copy put back by a program
     that doesn't touch the Keychain. It doesn't catch one that rewrites the Keychain items or signs itself as the
     node, nor a program that runs a second copy and times both copies' steps precisely, swapping the node's lock
     file between them. (Before the re-check's change, any second copy of the node run beside it could undo a
     change of yours unseen, without touching the Keychain at all; the one-writer rule closes that once built,
     except the precisely timed case just named.) Unsigned builds then lose the record at every update and, after
     the first, can't make any change that asks for Touch ID: not workable.

   [Row 12's signing decision with the anchor; P30, P34, P35, P40; the keeper's forms]

   **Decided (9CDB5A99): the keeper**, designed in [its own document](2026-11-27-v2-mac-keeper-design.md) for its own
   review before anything of it is built; form (i), the key and both counters. Signing no longer matters to the
   record: the keeper serves by the cdhash the install pins.
3. **What the reviews' fixes cost you: accept them, or say which to revisit.**
   - *While your login keychain is locked,* the changes that always ask for Touch ID are refused ("Your node can't
     keep its record right now. Unlock your login keychain, then try again."); if it was locked when the node started,
     you also restart the node. A device can be locked then but not removed: the refusal tells you to lock it now,
     and the removal goes through by itself once your keychain is unlocked.
   - *After the record begins again for any reason, a first start included,* each setting your node checks waits for
     your accept once, one Touch ID each.
   - *A program of yours can leave your page's devices held whenever it likes* (by putting an old copy of the record
     back, or by restarting the node while your keychain is locked). On a Mac with no phone the page is then unusable,
     and Terminal is where you acknowledge, and make the changes the command line has its own forms for, until device
     keys gives held devices a way back.
   - *One case leaves no notice:* between a stop you typed in Terminal and your next start, a copy of the node that
     recorded nothing (for example, one started without its key, or ended before it wrote anything) isn't shown. It
     changed nothing and took nothing, and your node's page address was free then anyway, since you had stopped it.
   - *A program of yours can make your node stop recording until you restart it* (by replacing its lock): it then
     refuses those changes and asks you to restart, and a device you lock meanwhile must be locked again after the
     restart.
   - **Recommendation:** accept them all.
   - **Day to day:** a refusal you clear by unlocking (sometimes with a restart); one accept per checked setting after
     the record begins again; Terminal whenever a program holds your devices on a Mac with no phone; a restart when a
     program replaced your node's lock.
   - **If you revisit one,** its gap opens again: a change that goes unrecorded while the keychain is locked, a
     planted setting taken as your baseline, or a held device brought back without your seeing it.

   [I2, I3, N4; the re-check's N-d, N-g, R2 (P39)]

   **Decided (90BBAD80): accepted.** With the keeper, bullet by bullet: the keychain-locked refusals are moot, the
   same refusals remain while the keeper doesn't answer, which a program of yours can cause by keeping it busy as it
   could lock the keychain (and a node whose keeper doesn't answer at its start doesn't start: the keeper design's
   Open questions 1, decided by the lead on 2026-11-27, stricter than this item asked); the accept per checked setting remains; devices held at will remain, through an older copy put
   back and through `ahead` with the busy keeper as its lever; the no-notice case narrows (no host starts without its
   key); the lock-replaced denial remains (the keeper design's Open questions 4).
4. **When a program of yours replaces the node's Keychain items with ones it can't read.** It can delete the node's
   key or counter and add its own item under the same name (measured on items of this kind). The node never asks for
   a Keychain window, so it can't read that item: it starts without its key every time and refuses every change that
   asks for Touch ID, and unlocking doesn't help.
   - **Recommendation:** the node holds and tells you which item it can't read, and deletes nothing on its own. It
     replaces the item only on your word: your confirmation in Terminal with Touch ID, or your deleting it yourself in
     Keychain Access. Its old record file is kept aside, renamed and never overwritten, until you acknowledge, so a
     key put right can still open it.
   - **Day to day:** nothing, until it happens; then one step from you, with those changes refused until you take it.
   - **If the node deletes the items by itself instead:** no step from you, but the delete can't be undone. If the
     unreadable item is the node's own key (your signing identity changed, or its access list was edited in Keychain
     Access), the old record is lost for good, and a program of yours can cause that whenever it likes.

   With the keeper of choice 2 none of this arises: the key and counter aren't in your keychain. [P34's
   delete-and-plant; `noKeychain`; `keyReplaced`, the reason the record begins again with, and the Terminal
   confirmation, a voiced request of the command line's own taken uncounted, since the record begins again]

   **Decided (90BBAD80): hold and tell you.** With the keeper (9CDB5A99) it doesn't arise, and `keyReplaced` and its
   Terminal confirmation aren't built. Its principle holds for the keeper's store: one the keeper can't read is held
   and named, nothing deletes it by itself, and only your `sudo` line starts it over, setting it aside.

## For the reviewer: the keeper

**Superseded by [the keeper design](2026-11-27-v2-mac-keeper-design.md)** (2026-11-27), which takes form (i) below
(the key, the journal's counter and slice 20's epoch, each raise an atomic swap), says how the keeper reads a
caller's cdhash (a fresh socket pair's token, the handover keeper's pattern, against the pins record's host rows) and
its store, and lists what is owed. What follows is the form this design asked for.

[Open for the user](#open-for-the-user) 2's keeper, its two forms. **(i) Key and counter together** (recommended):
the keeper makes the vault's key and holds it and `{record, seq, bind}`, **and slice 20's device epoch with them**
(else a same-seq older copy with the epoch overwritten in place would bring a removed device back). It gives the key
and raises the counter and the epoch only for a caller whose cdhash the root-owned record (BCECD1F3) pins for the
checked host, **and each raise is a compare-and-set against what that caller last wrote, which the keeper makes
atomic** (the re-check's R1). Both forms serve every pinned cdhash alike, so two checked hosts are told apart only by
the compare-and-set and the one-writer rule ([One writer](#one-writer-and-a-counter-bound-to-the-last-entry)); with
them, none of the gaps in the threat table is left (P30, P34, P35, P40 and the vault's confidentiality close; the
login Keychain drops out of the node's record and devices). "The real node" is every build the record pins (up to
16, `NodePins.maxBuilds`): a pinned older build started by a session is served too, and shows as an open `host.start`
with a build no `switch` named (P41). **(ii) A hash of the vault:** the hash of what the checked host last sealed,
with `{record, seq}`, advanced only for that cdhash and only by a compare-and-set against the hash that caller last
sealed (without it, whichever host sealed last would win); P34's replacement, P35 and P30's rewrite close, P30's
reading of secrets doesn't, and every seal (the book saves on each change) is a call to the keeper. A keeper holding
the key alone, the counter left in `login.keychain-db`, leaves P35 open: not offered. Either rests on J0a's rule 2
(I1b): the deputy is the same build with the same cdhash, so only the checked start's code calls the keeper, and
J0a's test covers those calls. The keeper's cost to the user, stated in item 2: a root process that must be running;
while it is down every start is `noKeychain` and guarded changes are refused. The lead's three reasons of 2026-11-26
against a root-owned pin of Keychain keys, answered for form (i): no trust on first use (the keeper makes the key,
nothing is taken from your account); no hand-off race (its first answer goes only to a cdhash the root-owned record
already pins, set by your `sudo` line); no admin prompt per change (the key never changes; the counter rises on the
cdhash check; an update moves the pinned cdhash by the install record's own route, rows 4 and 5). How the keeper reads
a caller's cdhash from the connection's audit token, and its store, are its own design's, **not measured** here.

## Build order

Each slice is under an hour, docs and tests included. "Review": needs its own independent security review before it
is offered. **No slice switches on `approvalMeasured`, `isCheckedMacNode`, `macUnbuilt`, `loginExplains` or
`holdsGuarded`, and none lifts `pageAck`'s refusal.** Every slice's Mac behaviour stays behind `macUnbuilt` on the
user's node, except J11, whose `logs` command never asks `usersNodeRefusal` (`LogsCommand`): harmless, since it only
prints the stderr file's inert, masked lines, said untrusted. **J0a, J0b, J3a, J3b, J4a and J4b change files every
host on a Mac runs** (`VaultStorage.swift`, `vibeswitcher-host/main.swift`), so each keys its new behaviour on the
checked node start and adds its arm to J0a's test (`noOtherModeTouchesTheNodesItems`): that test, not a constant, is what keeps
them from switching Keychain writes or the record on in any other mode (the review's N9). Device keys slices are named
by number. Files are as they are on `v2-mac-anchored-cli` (`b15e0052`). [GitHub's `v2`](#which-files-exist-on-v2)
says which exist there.

| # | Slice | Files | After | Review |
| --- | --- | --- | --- | --- |
| J0a | The node's own Keychain items ([The node's own Keychain items](#the-nodes-own-keychain-items-and-the-one-start-that-touches-them)): `NodeKeychain` with the node's two names, called only from a checked node start (rule 2); a checked start takes no state file (rule 3); the node's builds signed with their own identifier (`-i`); the deputy tests on an in-memory key store (no Keychain), with N-a's arms (a scratch-home host with no handover at all, the `--test-checked-shape` host). **With the keeper:** the seam is `NodeAnchor` (in-memory and keeper stores, no Keychain store), its names the keeper's key and its `journal` and `devices` slots; rules 2 and 3 and their tests unchanged, since they are what keeps the genuine host's other modes away from the keeper too (the keeper design's KP12); the `-i` guards nothing of the record (the keeper design's Open questions 5). Built before K4, K4 renames it | new `Sources/VibeHost/V2/NodeKeychain.swift`, `Sources/vibeswitcher-host/main.swift`, `Sources/VibeHost/V2/HostImages.swift`, `Sources/VibeHost/VaultStorage.swift`, the node's build script's `-i`, `Tests/VibeHostTests/HostJournalTests.swift`, `JournalLintTests.swift` | none | yes; it reads whether an opened vault can be handed on |
| J0b | The handover's receiving side on v2: `the-session-host-s`'s requirement carried into v2's `main.swift` (a proven predecessor or a refusal, before any secret is read or any vault file written), with its cases run against v2's host. The app's vault on v2 rests on it, not the node's property (N-c) | `Sources/vibeswitcher-host/main.swift`, `HostJournalTests.swift` | J0a; `the-session-host-s`'s mechanism, once chosen on main | yes |
| J1 | The record type: entries, the entry bytes, the digest (`open.digest`, J1's function, used by J6 and J7), parsing that refuses anything unusual, the open-entry rule (derived, never stored: I6), immutable entries, `more` with counts by kind ranked as its worst, the trim's rules and `full`, the 500/64 caps | new `Sources/VibeCore/V2/JournalRecord.swift`, `Tests/VibeCoreTests/JournalRecordTests.swift` | none | yes, with J2; it covers I6 and that openness is derived |
| J2 | The vault's journal requests, app-only, behind `isMacNodeHost`: `journal` (read), `journalAppend` (the server's five kinds only), `journalAck` (the digest checked again by the vault); the host's own append in-process | `Sources/VibeCore/V2/LeadVaultV2.swift`, `Sources/VibeHost/V2/VaultV2Handler.swift` | J1; device keys 4 (same files) | yes |
| J3a | The counter in I6's order on `NodeKeychain`'s seam, keyed on the checked start, and the record beginning again on each anomaly in the check order (key, file, open, parse, counter: `noKeychain`, `begins`, `missing`, `unreadable`, `noCounter`, `older`, `ahead`). **One writer** (the re-check's R1, [One writer](#one-writer-and-a-counter-bound-to-the-last-entry)): the lock taken before the record is read for writing, the lock's check before each write and after each raise, `lock.lost`; the counter's `bind` of the last entry; each raise a compare-and-set; J0a's test gains the arm "a second checked start while the node runs". Tests on an in-memory key store (no Keychain): with those of row 7a and P40. **With the keeper:** on `NodeAnchor`'s seam; the counter is the keeper's `journal` slot and each raise its atomic `swap` (the in-memory store atomic too), so the two-call Keychain store isn't built and `aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet` passes on the keeper's seam (P40's residue closes); the start's order is the lock, then the keeper's `open`, then key, file, open, parse, counter, and a host that gets no key exits 78 having read nothing, so no record begins `noKeychain` (the keeper design's Open questions 1, decided by the lead on 2026-11-27: no no-key arm is built); the lock rule kept as it is (the keeper design's Open questions 4) | `Sources/VibeHost/VaultStorage.swift`, `NodeKeychain.swift` (`NodeAnchor.swift` with the keeper), `Sources/vibeswitcher-host/main.swift` (the lock before the vault's open), `Sources/VibeHost/HostServer.swift` (the held lock's check), `Tests/VibeHostTests/HostJournalTests.swift` | J0a, J2 (the keeper design's review is done, and its re-check of 2026-11-27 found J3a safe to build on the in-memory seam). **Before or beside device keys 20**: J3a builds the seam and the one failed-raise rule for both items (I2), slice 20 takes them, and slice 20's reviewer reads J3a's seam. Its real store: **the keeper's client, after K4** (K4 waits on K3, K4a-i, K4a-ii and J0a; was: its Keychain arm after J-M2, no longer owed) | yes, with J3b; it reads R1's mechanism (the lock's check, the binding, the compare-and-set) |
| J3b | every record that begins again holding the vault's first looks on a checked Mac node (`VaultFirstLook`, keyed on the checked start), the devices it still lists held, an unparsed journal held as `older`; a failed raise: the vault's answer "uncounted", the retry at each later append, the open `noKeychain` entry; the no-key arm (`noKeychain`). **With the keeper:** a failed raise is the keeper not answering, its entry `record.begins` with `noKeeper`, its words the keeper's ("its keeper isn't answering"); no no-key arm (no host starts without its key); the keeper design's K8 (a checked node's started-over vault saves under the keeper's key, the file that didn't open set aside) rides with it | `VaultStorage.swift`, `Sources/VibeHost/V2/VaultFirstLook.swift`, `HostJournalTests.swift` | J3a; its real store after K4 (was: its Keychain arm after J-M2) | yes |
| J4a | The host's start, after the lock (J3a): `host.start` with its fields and `how`, the job's launchd fields recorded as the job's with its pid (`job`), and `login` only when the job's pid is the host's own (N-j); the `switch` check against the keeper's handover; the unswitched-build rule (N-b, `anUnswitchedBuildChangeIsOpen`); `login` never for a record's first start; keyed on the checked start. `loginExplains` false. **With the keeper:** nothing it builds changes ("the keeper's handover" in this row is the handover keeper's); it touches no Keychain and runs on J3a's in-memory seam; it comes after the keeper's `open` in the start's order | new `Sources/VibeHost/V2/HostJournal.swift`, `Sources/vibeswitcher-host/main.swift` | J3a | yes, with J4b |
| J4b | The host's other entries: `host.end` for a stop, `server.restart`, `page.held` when the page's address can't be bound at start. **With the keeper:** unchanged; P39's no-notice set narrows (no host starts without its key) | `HostJournal.swift`, the server child's restart in `Sources/VibeHost/V2/`, `Sources/VibeHost/V2/HostWebListeners.swift` | J4a | yes |
| J5a | The server's entries `stop` (with its `via`), `switch` and `guarded`, each before its act, **on slice 14's single act path**, each guarded act acting only once its entry is counted (`recordUncounted` otherwise), with a test that walks `KindSpec`'s guarded table so every kind slice 15 wires gets its entry, **`journal.ack` excepted**: it is taken uncounted when the raise fails (a lost `ack` only reopens what it covered), and the test says so (`JournalAckTests.everyGuardedKindAppendsItsEntryBeforeItActs`); `StopSequence`'s journal step skipped on the Mac | `Sources/VibeNode/Server/Requests.swift`, `Sources/VibeNode/Start/StopSequence.swift` | J4a, J3b; device keys 14 (the guarded act) | yes, with J5b |
| J5b | The Mac's `start` kind voiced, its words naming the times (the stop's date when not today), its pid; `start.explained` only after a terminal's `stop` and the host's `host.end` and for the newest start's pid, `previous` not asked (R2; `aTypedStartAfterYourTerminalStopIsExplained` on the agent's real order); the command line's Mac `start` sending it only after its own load succeeded | `Requests.swift`, `Sources/VibeNode/Server/KindSpec.swift`, the command line's Mac `start` (`Sources/vibeswitcher-cli/Start.swift`, `MacAgentCommand`) | J5a, J4b; row 3's lines built (the voice) | yes |
| J5c | `revoked` entries inside the vault's requests that drop an unlock, a key or a device (`dropUnlocks`, a device's removal, and those behind `phone.off` and `web.revoke`). The revocations are never refused for a failed raise; a device's removal raises slice 20's epoch, is refused when a raise fails with words saying to lock the device now, and is retried by itself at the next raise that succeeds (N-d) | `LeadVaultV2.swift`, `HostJournalTests.swift` | J3b; the device keys slices that build those requests | yes, with J5a |
| J6 | `journal.list` (a read), the words, `status`'s Mac lines from it; Linux answers "not on this system", Linux's `status` lines are byte-identical, and Linux's `hello.kinds` are byte-identical but for the new kinds' "not on this system" | new `Sources/VibeNode/Server/JournalRequests.swift`, `KindSpec.swift`, `Sources/VibeNode/Live/Wire/ReadKinds.swift`, `Sources/vibeswitcher-cli/Status.swift` | J1, J2 | no, since `open.digest` is J1's function (a read; its words with J7's review) |
| J7 | `journal.ack` as a guarded kind: its digest in the guard, the act's check before `kept`/`retry`, the vault's check, `status --ack`'s Mac arm; `MacJournal.pageAck` false with its test (the page's and phone's route refused on a Mac node) | `JournalRequests.swift`, `KindSpec.swift` (the guarded table), `Status.swift`, `DeviceGates.swift` | J6; device keys 14, and 23 for the Mac's dialog route (refused until then) | **yes, its digest** (as slice 15's rule) |
| J8 | The hold: guarded kinds refused while open or unread, except `journal.ack` and the first enrolment (held devices counting as listed; the enrolment's window naming the open record's worst reason); `MacJournal.holdsGuarded` false; the byte-identical-when-off test | `Sources/VibeCore/V2/DeviceGates.swift`, `Sources/VibeNode/Server/PageRequests.swift` (`pageChecks`), `Requests.swift` | J7; device keys 14 | yes |
| J9a | The lint that nothing in the node's targets or `scripts/` reads the unified log (P1), and `Platform.Service.unifiedLogTool` deleted | `Tests/VibeNodeTests/JournalLintTests.swift` (or the lint suite's home), `Sources/VibePlatform/Service.swift`, `Service+Darwin.swift`, `Service+Linux.swift` | none | no (a lint and a deletion) |
| J9b | The unified log sink: the host's copy, kinds and seqs, `.default` level, each line starting "a copy, not the record" | `Sources/VibePlatform/Journal+Darwin.swift`, `HostJournal.swift` | J4a | with J4a |
| J10 | The page: This node › Journal, the notice, Review and Acknowledge (guard flow), words only | `WebApp/js/views/node.js`, `WebApp/js/i18n*.js` | J7; device keys 5, 14 | with J7 (text you read) |
| J11 | `vibeswitcher logs` on the Mac: the stderr file, said untrusted (not behind `macUnbuilt`: above) | `Sources/vibeswitcher-cli/Logs.swift` | none | no |

**What may start now** (the design is final; the re-check's list): **J0a** (the node's items, rules 2 and 3, the
`-i`, the deputy tests with N-a's first two arms), **J1** (with I6's change; its entry bytes also serve J3a's
binding), **J2**, **J6**, **J9a** and **J11**. **What each of the rest waits on** (slices, not the design):

- **J0b:** J0a, and `the-session-host-s`'s mechanism, once chosen on main.
- **J3a:** J0a and J2 (the keeper design was reviewed, and its re-check of 2026-11-27 found J3a safe to build on the
  in-memory seam; before or beside device keys 20); its real store, the keeper's client (K4, which waits on the
  keeper's K3, the Mac spec's steps 10 and 11 (the keeper design's K4a-i and K4a-ii) and J0a). Was: its Keychain arm,
  J-M2, which the node no longer needs.
- **J3b:** J3a (safe to build on the in-memory seam, as the keeper design's re-check found); its real store, K4; K8
  with it once main's `5e98c1fc` is in v2.
- **J4a:** J3a (its seam). **J4b:** J4a. Neither waits on the keeper's build: they run on the in-memory seam.
- **J5a:** J4a, J3b and device keys 14. **J5b:** J5a, J4b and row 3's lines. **J5c:** J3b and the device keys slices
  that build the revocations and removal (20 for the epoch).
- **J7:** J6, device keys 14, and 23 for the Mac's dialog route. **J8:** J7 and device keys 14.
- **J9b:** J4a. **J10:** J7 and device keys 5 and 14; it closes C9 for the Mac.
- **Nothing switches on** until the switch-on review (row 15), by the lead.

### Which files exist on v2

Read from a shallow clone of GitHub's `v2` at `8df1ee3` (2026-11-26), file by file, without building anything.
**On `v2` today:** `LeadVaultV2.swift`, `VaultV2Handler.swift`, `VaultStorage.swift`, `vibeswitcher-host/main.swift`,
`Requests.swift`, `KindSpec.swift`, `PageRequests.swift`, `ReadKinds.swift`, `StopSequence.swift`, `Status.swift`,
`Logs.swift`, `Journal+Darwin.swift` (its `send` still returns false), `Keychain.swift`, `MacHandoverKeeper.swift`,
`VaultFirstLook.swift`, the command line's `Start.swift` and `MacAgentCommand.swift`, the test folders `Tests/VibeCoreTests`,
`Tests/VibeHostTests` and `Tests/VibeNodeTests`,
`WebApp/js/views/node.js`, `i18n.js`, `i18n-es.js`, and device keys' `WebAuthn.swift` and `DeviceProof.swift`.
**Not on `v2`:** the new files `JournalRecord.swift`, `HostJournal.swift`, `JournalRequests.swift`, and device keys'
`DeviceGates.swift` and `DeviceRequests.swift`. `v2` has no journal acknowledgement kind (G3 isn't built there):
`status --ack` is still the typed code and the journald entry.

## Sources

- The Mac spec, `v2-mac-seal-list` `01a05734`: "Logs: the unified log for events, a file for stderr"; the table row
  "The journal (write, read, the ack rule)"; step 6 in "The order of work"; "The Mac's `start` is not Linux's start
  sequence". `v2-mac-runbook` `d9a38524`: "The rule's lines, settled from the measurements (row 3, 2026-11-26)".
- The measurement record, `v2-mac-runbook`: M9, M10, M11, row 11, item 7.
- The re-check of `b225d8c0` (2026-11-27, verdict "sound with changes"): R1, R2, N-a to N-j; the lead's ruling of
  2026-11-27 on device removal (refused when its raise fails, its words saying what to do, retried by itself).
- The independent review of this design at `5acb15c2` (2026-11-26, verdict "not yet"): I1 to I7, N1 to N9; the lead's
  decisions of 2026-11-26 (the Keychain items overwritten in place, a stated limit; no Developer ID for now; the
  Mac's handover finding for the switch-on review).
- V2 without a terminal, `v2-remaining`: C9, N1, N6; `v2-remaining.md`: G3, G6, item 6 (N6 against the design).
- Device keys, `v2-keys-vault` `f278a5a3`: "The unlock, and what it never covers", "How a guarded change is asked",
  "Where the node keeps the devices" (the Mac, I6), "The Mac", "Open to attack" 4 and 5, slices 4, 9, 14, 15, 20, 23.
- Code at `b15e0052`: `NodeJournal.swift`, `Journal.swift`, `Journal+Darwin.swift`, `Journal+Linux.swift`,
  `Status.swift` (`journalLines`, `acknowledge`), `NodeClient.swift` (`writeJournal`, `change`), `StopSequence.swift`,
  `StartSequence.swift`, `NotPromised.swift`, `VaultStorage.swift`, `vibeswitcher-host/main.swift` (the handover and
  the vault), `HostImages.mayTakeHandover`, `NodeSystem.swift` (`macUnbuilt`, `approvalMeasured`).

## Review of 2026-11-26

The independent review of `5acb15c2` (verdict "not yet"), each finding with the section that answers it and its
planned test, in the order the review asked them taken. "Re-check" means the re-check of these findings only.

| Finding | What changed | Where | Planned test |
| --- | --- | --- | --- |
| **I1** the genuine host seals any vault handed to it; the node's key is the app's | the node's own items (`dev.vibeswitcher.node.vault`, `dev.vibeswitcher.node.journal`), named in one file, touched only by the checked node start; the node's own signing identifier; the precondition stated; every holder of the items' code identity in the threat table; the dependency on `the-session-host-s`'s receiving side and what v2 needs beyond it, as slice J0 before J3a | [The node's own Keychain items](#the-nodes-own-keychain-items-and-the-one-start-that-touches-them); the threat table's holders row; P33; J0 | `HostJournalTests.noOtherModeTouchesTheNodesItems`, `HostJournalTests.aCheckedStartTakesNoStateFile`, `JournalLintTests.theNodesItemsAreNamedInOneFile`; and, from the attacker read, a pinned older build started by a session is an open unswitched build change: `HostJournalTests.anUnswitchedBuildChangeIsOpen` |
| **I5** P30 reaches every guarded state; the keeper as described leaves most of it | P30's whole scope stated (guarded state, devices, epoch, secrets); the keeper anchors the whole vault (key and counter together, recommended, or its hash), called only from the checked start | [What a holder of the vault's key reaches](#what-a-holder-of-the-vaults-key-reaches); P30; [Open for the user](#open-for-the-user) 2 | J-M2 B; the keeper's own tests; J0's test covers its calls (the keeper's form (i) holds slice 20's epoch too, from the attacker read) |
| **I4** the counter rolls back with the login keychain file | stated in the threat table, P13 and P29, as P35; measured in J-M2 E; a trigger for the keeper. Also (the lead's decision of 2026-11-26): the counter overwritten in place, P34, which already meets the trigger | the threat table's first row; P13, P29, P34, P35; J-M2; Open for the user 2 | J-M2 C, E; the keeper's own tests |
| **N7** J-M2 breaks the Keychain rule and gates J3 | J-M2 rewritten on a scratch keychain file from `scratch-keychain.sh`, interaction off, status codes not dialogs, no access-list call, no killing timeout, you at the keyboard; I1's other mode (B2) and I4's put-back (E) added; it gates J3a's and J3b's Keychain arm | [Measurements owed](#measurements-owed) J-M2; Build order | J-M2 itself |
| **I2** a failed raise lets guarded changes through uncounted | a guarded act acts only once its entry's raise succeeded (`recordUncounted`), the raise retried at each later append, one success covering every entry before it; `stop`, restarts, revocations and the acknowledgement still taken; one rule with slice 20's epoch; what is sealed meanwhile | [The journal's counter](#the-journals-counter); P31, P39; J3b, J5a; Open for the user 3 and 4 (its costs, the planted item's way out) | `HostJournalTests.aFailedRaiseRefusesAGuardedActAndStillTakesAnAck`, `aLaterRaiseCoversEveryEntryBeforeIt`, `anUncountedGuardedEntryIsNeverActedOn`, `aKeylessHostsSuccessorIsOpen` (P39); rule 2 needs a clean previous exit (dropped by the re-check's R2: it could never pass); a file ahead of its counter refused as `ahead` (row 7a); `journal.ack` excepted from J5a's counted test |
| **I3** an emptied vault takes what is on disk as its baseline | every record that begins again on a Mac node holds its first looks (`begins` included) and the devices it still lists, row by row | [Where the vault's other contents stand](#where-the-vaults-other-contents-stand); [Fail closed](#fail-closed)'s table; P12, P15; J3b; Open for the user 3 (its cost) | `HostJournalTests.aMissingFileHoldsItsFirstLooks`, `everyReasonHoldsItsFirstLooks`, `anOlderCopysRecordedFloorsAreHeldNotApplied` (an older copy's recorded floors held, not applied) |
| **I7** the parse row and the `older` row overlap | the counter clause out of the parse row; checks ordered key, file, open, parse, counter; an unparsed journal holds the vault as `older` does | [Fail closed](#fail-closed) rows 4 to 7 | `HostJournalTests.anUnparsedJournalHoldsTheVaultAsOlderDoes`; row 1 only for an item present but unreadable (an absent key is made) |
| **I6** `more` hides an unexplained start and is changed in place | entries never change; each overflow appends a new `more` with counts by kind, ranked as its worst; openness derived, not stored; the trim never opens or closes an entry; `full` | [Fail closed](#fail-closed) (after the table); the kinds table; the words' order; P16; J1 | `JournalRecordTests.aMoreRanksAsItsWorst`, `entriesNeverChange`, `theTrimNeverOpensOrClosesAnEntry`, `openEntriesAreNeverDropped`; `full` carries the worst it couldn't keep, and a `host.start` is never folded into a `more` |
| **N1** the start at login | `login` never explains a record's first start; `page.held`, an open entry when the page's address can't be bound at start; J-M1 adds a forced logout and a squatter at login; "ask every time" kept until both | [What explains a start](#what-explains-a-start) 3; the kinds table; P8, P37; J-M1; Open for the user 1; J4a, J4b | `HostJournalTests.loginNeverExplainsARecordsFirstStart`, `aPageAddressHeldAtStartIsOpen` |
| **N3** the acknowledgement's routes | the checked server is the anchor on both routes; the page route's refusal is the journal's own constant `MacJournal.pageAck` (no slice lifts it: the switch-on review does); `holdsGuarded` only once the page route exists | [Which key signs it](#which-key-signs-it-and-what-the-vault-checks-on-each-route); [What the node refuses](#what-the-node-refuses-while-something-is-open); P38; J7 | `JournalAckTests.aPagesAckIsRefusedOnAMacNode` |
| **N2** what explains a start, case 2 | the voiced `start` only after the command line's own load succeeded; the stop's date in the words when not today | [What explains a start](#what-explains-a-start) 2; P7; J5b | `JournalAckTests.aStartThatFoundTheNodeRunningExplainsNothing`, `theStartsWordsNameItsTimes` |
| **N4** the hold and its exceptions | the denials stated with their way out (stop from the page, `KeepAlive` false); held devices count as listed; the enrolment's window names the worst open reason; the terminal as the only route after `older` with no phone | [What the node refuses](#what-the-node-refuses-while-something-is-open); P32; J8; Open for the user 3 (its cost) | none: stated limits (P32); J8's own |
| **N5** revocations outside the counter | `revoked` entries (not open) for `device.lock`, `phone.off`, `dropUnlocks`, `web.revoke`, appended by the vault itself; never refused for a failed raise, stated | the kinds table; [What the counter covers](#what-the-counter-covers); P36; J5c | `HostJournalTests.anOlderCopyOverARevocationIsOlder`, `aRevocationIsTakenWhenTheRaiseFails` |
| **N6** the unified log | `unifiedLogTool` deleted; J9a's lint scoped to the node's targets and `scripts/` (so the app's benches don't fail it); the pointer to Console dropped; each sink line says it is a copy | the readers table; [Where entries rest](#where-entries-rest-on-a-mac); P1; the engineering calls; J9a, J9b | `JournalLintTests.noNodeSourceReadsTheUnifiedLog`, `unifiedLogToolIsGone` |
| **N8** signing states its cost inaccurately | signing and the anchor presented as one decision, with ad hoc's real cost (the record lost at each update, and no guarded change after it under I2) | [Open for the user](#open-for-the-user) 2; the first page | none (a decision) |
| **N9** the build order | J0 before J3a; J3a before or beside slice 20 with one failed-raise rule and slice 20's reviewer reading its seam; J3 and J4 keyed on the checked start with J0's test; J5a on slice 14's act path with a test over the guarded table; J4 split into J4a and J4b, J9 into J9a and J9b, J5c added; J6 without a review since `open.digest` is J1's; J11 outside `macUnbuilt`, said harmless | [Build order](#build-order) | `JournalAckTests.everyGuardedKindAppendsItsEntryBeforeItActs`; J0's test arms |

**What could start before the re-check:** J1 (with I6's change), J2 (app-only, behind `isMacNodeHost`), J6, J9a (the
lint, with N6) and J11, as the review lists them. What may start now: [Build order](#build-order).

## Re-check of 2026-11-27

The re-check of `b225d8c0` (verdict "sound with changes"): I1, I3, I6 and I7 closed; I2, I4 and I5 closed with limits
that are yours to accept ([Open for the user](#open-for-the-user) 2 and 3); two new Important findings and ten notes,
each answered here by the change the re-check named. Nothing more is reviewed as a whole design: each slice marked
"Review" gets its own.

| Finding | What changed | Where | Planned test |
| --- | --- | --- | --- |
| **R1** two checked hosts write one record, and the counter can't tell their files apart | one writer: the lock taken before the record is read for writing, before an absent key is made and before `host.start`; a host whose lock's path changed or whose lock it no longer holds writes nothing more, refuses guarded changes and shows `lock.lost` (memory only); the counter holds `{record, seq, bind}`, `bind` made from the last entry and something only the sealed vault holds, so `journal.list` doesn't show it; each raise a compare-and-set, the Keychain's two calls backed by the lock check after the set; the keeper's raise atomic in either form; the threat table, P13, P29 and Open for the user 2 say what holds after the change and what held at `b225d8c0`; the precondition gains "one host writes at a time"; the blind check's residue stated (a session driving both hosts' timing and swapping the lock's file between their checks passes the Keychain's two-call compare-and-set: closed only by the keeper's atomic one) | [One writer](#one-writer-and-a-counter-bound-to-the-last-entry); the property; the threat table; the kinds table (`lock.lost`); Fail closed row 7; P13, P29, P40; [For the reviewer: the keeper](#for-the-reviewer-the-keeper); J3a | `HostJournalTests.aSecondCheckedStartBesideTheNodeWritesNothing` (J0a's test, J3a's arm), `aDeletedLockStopsTheHostsWrites`, `aReplacedLockStopsTheHostsWrites`, `twoRecordsAtOneSeqDontMatchTheCounter`, `twoHostsRacingARaiseLeaveOneHistory`, `aLockSwappedBetweenTwoHostsChecksNeedsAnAtomicCompareAndSet`; the keeper's own tests |
| **R2** rule 2's "clean previous exit" can never be met (bootout, then bootstrap: `previous` unknown) | the clause dropped; P39 states the real no-notice set (a host that sealed nothing, between your terminal stop and your typed start: one started without its key, or killed before its first raise, by launchd or a session), told to you in Open for the user 3 and the first page; P39's impossible residue (a keyless host stopped from a page) removed; the bigger alternative (the job kept loaded, `host.end` bound to launchd's `runs`) not taken | [What explains a start](#what-explains-a-start) 2; [The journal's counter](#the-journals-counter); P39; Open for the user 3; J5b | `JournalAckTests.aTypedStartAfterYourTerminalStopIsExplained` (the agent's real order); `HostJournalTests.aKeylessHostsSuccessorIsOpen`, scoped to a record that doesn't end in your `stop` and `host.end` |
| **N-a** J0's test arms | a scratch-home host with no handover at all, and the `--test-checked-shape` host, added to J0a's arms; R1's second checked start added by J3a, not J0a; `a-host-started-on` named beside `the-session-host-s` as the app's concern on main | [The node's own Keychain items](#the-nodes-own-keychain-items-and-the-one-start-that-touches-them) rule 2 and what the app's vault rests on; P33; J0a | `HostJournalTests.noOtherModeTouchesTheNodesItems`'s arms |
| **N-b** the unswitched build only in the threat table | the rule stated before every case of What explains a start, in "Everything else is open", in J4a and the path table (P41); the older build's own code judges it, every pinned build carries it, and every later build keeps it | [What explains a start](#what-explains-a-start); P41; J4a | `HostJournalTests.anUnswitchedBuildChangeIsOpen` |
| **N-c** J0 needn't wait for main's mechanism | J0 split: J0a now (items, rules 2 and 3, `-i`, the deputy tests), J0b once main's mechanism is chosen; "what this rests on" corrected: the app's vault on v2 rests on the receiving side, not the node's property; J3a to J4b wait on J0a only | [The node's own Keychain items](#the-nodes-own-keychain-items-and-the-one-start-that-touches-them); Build order | J0a's tests; J0b's cases |
| **N-d** device removal said two things | one rule: `device.remove` raises slice 20's epoch with its `revoked` entry and is refused when a raise fails, its words saying to lock the device now; a refused removal is retried by itself at the next raise that succeeds (the lead, 2026-11-27); "Lock now", `phone.off`, `dropUnlocks` and `web.revoke` never refused; you're told a device can be locked but not removed while the keychain is locked | the kinds table; [The journal's counter](#the-journals-counter); [What the counter covers](#what-the-counter-covers); P36; J5c; Open for the user 3 | `HostJournalTests.aRemovalIsRefusedWhenTheRaiseFails`, `aRefusedRemovalIsRetriedWhenTheRaiseSucceeds` |
| **N-e** I3's `.app` question | answered from the code: `.app` is exempt from the rails' first-look hold (`LeadVault.swift:1132`), not the floor's (`:1150`); the rails' hold rests on the three callers (`ConfigHoldStore.swift:239-247`, `NodeSettingsSet.swift:132`, `SessionPresets.swift:210`), which J3b's review walks by name | [Where the vault's other contents stand](#where-the-vaults-other-contents-stand) | J3b's review |
| **N-f** `ahead` not carried everywhere | `ahead` in J3a's reasons, in the held-devices sentence, and in the path table (P42) | Fail closed row 7a; [What the node refuses](#what-the-node-refuses-while-something-is-open); P42; J3a | `HostJournalTests.aFileAheadOfItsCounterBeginsAgainHeld` |
| **N-g** held devices can be caused at will | said, with how (`older`: copy, one counted append, kill, put back; `ahead`: lock, kill the server child, kill the host), and what you can do meanwhile (Terminal for acknowledging and changes; the page unusable on a Mac with no phone until slice 20's way back) | the first page; [What the node refuses](#what-the-node-refuses-while-something-is-open); Open for the user 3 | none (a stated cost) |
| **N-h** item 4's recommendation was an irreversible delete | the recommendation is now the safer default: the node holds and tells you, and deletes only on your word; the old vault file kept aside, renamed, until you acknowledge; the self-delete option's cost says it can't be undone | Open for the user 4; the first page; [The journal's counter](#the-journals-counter)'s denial | none (a decision) |
| **N-i** J-M2's probes' signing open, and E | settled: a sign-only step from `build-app.sh`'s own search-list block, at the keyboard after a build (no throwaway identity, which needs an access-list entry the Keychain rule refuses); the probes carry their own guards; E puts the copy back by rename, last, after every probe exited, with the recovery said | [Measurements owed](#measurements-owed) J-M2; the engineering calls | J-M2 itself |
| **N-j** the launchd fields describe the job | `job` (the job's pid) added to `host.start`; `how = login` also needs the job's pid to be the host's own | the kinds table; [What explains a start](#what-explains-a-start) 3; P8; J4a | `HostJournalTests.loginNeedsTheJobsPidToBeTheHosts` |
| I6's one line; I5's keeper cost | the page lists every open entry that isn't folded; the keeper's cost includes a root process that must run, and what happens while it's down | Fail closed; Open for the user 2 | none |
