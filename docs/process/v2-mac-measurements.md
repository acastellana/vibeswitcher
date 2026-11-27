# The Mac's voice, measured (step 4)

The measurements [the node on macOS](../superpowers/specs/2026-11-19-v2-node-on-macos.md) (its "The order of work",
step 4) and [the Mac's tasks](v2-mac-tasks.md) ("Before approvalMeasured flips") say need a real Mac, taken on the first
real one, 2026-11-25, from `v2-mac-fixes` at `b9df9949`. Nothing here turns anything on: `NodeSystem.approvalMeasured`,
`HostImages.isCheckedMacNode`, `NodeSystem.macUnbuilt` and `HostImages.macServerRefusal` are as they were.

**The Mac.** MacBook Pro (Mac15,7, Apple M3 Pro, 12 cores), macOS 27.2 (26B123), System Integrity Protection
**enabled**, Touch ID enrolled, Xcode from the App Store (Swift 6.4.2), Remote Login off. The app was running with
real sessions; none of it was touched.

**From where.** An agent's session (Claude Code) under the app's session host, in the login session's `Aqua` domain
(`launchctl managername`). Every process measured is one the measurement started (its own children, a double-forked
child, launchd's pid 1 for the root records, as `ProcessesTests` reads it); no task port was taken (`task_for_pid` would
put the Developer Tools dialog on the screen: the status word was read instead), no dialog was shown, no job was loaded.
The probes are [scripts/mac-measure/probes](../../scripts/mac-measure/probes), built with `clang`/`swiftc` into
`.build/mac-measure`. Paths below are cut to `<clone>` and `~`. **M1 to M8 and M10 run again in one command**, what an
agent may run (no dialog, no job, only its own processes and pid 1):
`bash scripts/mac-measure/taken-here.sh` ([taken-here.sh](../../scripts/mac-measure/taken-here.sh)); its run of
2026-11-25 gave the same lines as below (and the two additions marked "the runner").

Reads beyond the measurement's own processes, all of them reads the kernel or launchd answers any process of the
user's: pid 1's records; `launchctl list` (to pick an Apple agent) and `launchctl print` of Finder's job (M11); the
frontmost app's bundle id, which `keys` prints (LA-7's helper, checked here posting nothing). Written: a few entries in
the unified log (M10, under `dev.vibeswitcher.measure.<random>`, and two `logger -t vibeswitcher`); scratch folders under
`/tmp/mac-measure.*`, made and removed by the project's `scripts/lib/scratch.sh`.

**The user's keyboard session (2026-11-26, 19:29 to 19:38), part A of [the runbook](v2-mac-keyboard-session.md).**
Its records, kept as written (the scripts had already taken the account's name and home out; nothing else needed
taking out), are in [measurements/2026-11-26](measurements/2026-11-26/); what each answers is
["The keyboard session of 2026-11-26"](#the-keyboard-session-of-2026-11-26) below. In short: **run from a VibeSwitcher
shell session (a shell card), not Terminal.app.** Done: ESC-3, AG-1, LA-1, LA-2, LA-3, LA-6, LA-7, ESC-1, ESC-2.
Not done: ANC-1 (needs Terminal.app), LA-5 and ANC-2 (need Remote Login), LA-4 (needs an external display), the `sudo`
trial of the anchor's record. The person's "what you saw" lines are empty or a few words: no record holds the dialog's
wording, and nothing here infers it.

## What step 4 names, and where each stands

| Measurement | Where | Here |
| --- | --- | --- |
| The environment line under SIP | step 4 | **taken** (M2): readable, except for Apple's platform binaries |
| Double fork, `setsid`: the process facts left | design, "What a same-uid process can do" | **taken** (M3) |
| `open -a Terminal x.command`: its process facts | step 4 | **taken** by the user (K-ESC-1, from a shell card): Terminal's coalition, a fresh terminal, no `VIBESWITCHER_SESSION` |
| `osascript … do script`: its process facts | step 4 | **taken** by the user (K-ESC-2, from a shell card): as ESC-1; no consent stopped it |
| `launchctl submit`/`bootstrap` of a session's own agent | step 4 | **taken** by the user (K-ESC-3, twice): `ppid=1`, no terminal, a coalition of its own |
| The responsible pid | step 4 | **taken** (M5; K-ESC-1 to 3): Terminal's after `open -a Terminal`, each process its own after `osascript` and `launchctl`: no line (the spec's row 3) |
| LocalAuthentication from a LaunchAgent in `gui/<uid>` | step 4, item 2 | **taken** by the user (K-LA-1): approved; the dialog's words **not recorded** |
| … declined, cancelled, its 60 s against the CLI's 120 s | item 2, the tasks' `1a6c4688` row | **taken** by the user (K-LA-2): Cancel and the 60 s limit each a decline; the CLI's 120 s read from the code (M14) |
| … with no Touch ID (the password) | step 4 | **taken** by the user (K-LA-3): approved; the route by the runbook's instruction, not in the record |
| … with the lid closed | step 4 | script LA-4 (needs an external display): **not run** |
| … over ssh (`.notInteractive` read as unavailable) | step 4 | script LA-5 (needs Remote Login: off here): **not run** |
| A second dialog while one is open | the tasks' `8f8b7e20` row | run (K-LA-6), **still open**: the first was cancelled before the second was asked |
| Whether a process of the user's can answer it (Accessibility) | item 3 | **taken** for an untrusted process (K-LA-7): one Escape it posted didn't end the dialog (dropped or ignored: not told apart); a trusted one open; no Escape by hand yet (owed step 1) |
| Whether an agent session's process can raise the dialog | design, "What it can't do" | **taken** (M9): it can |
| Item 3: `DYLD_INSERT_LIBRARIES` into the hardened command line refused | item 3 | **taken** (M6) |
| Item 3: the connect-write-exec race | item 3 | **taken** (M7) |
| Item 6: the five reads with no gate | item 6 | a decision of the user's (below) |
| Item 7: a link of another user's process, a zombie, a process that execs | item 7 | **taken** (M8, M7) |
| Item 7: the Mac node host's vault on disk (its Keychain key), across a handover | item 7 | not measurable before item 13: no Mac node host exists |
| Item 7: the server check against a real job | item 7 | not before step 5 wires `start`; the job's shape in AG-1. **Since:** step 5 is wired and reviewed (row 9), `start` still refused by `NodeSystem.macUnbuilt`, so still not before the switch-on (corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26) |
| Item 7: gh's token in the login Keychain, GitHub through curl | item 7 | not taken: the user's Keychain item (an install run reads it) |
| Item 7: an App Store Xcode passing the toolchain check | item 7 | **taken** in part (M12): root-owned throughout |
| Item 7: launchd taking the written agent; entitlements for the host | item 7 | **taken** for the shape (K-AG-1, twice); the node's own agent waits for step 5 |
| Item 7: the run paths (macOS 26 or later) | item 7 | **taken** (M12): macOS 27.2 |
| Item 9: the server gets the web socket; a second process can't bind the port | item 9 | not built (below); nothing to measure. **Since: built and reviewed**, the host holds the web port (row 8; corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26) |
| Item 10: an anchor a session can't write | item 10 | a decision of the user's (below). **Since:** the user chose the root-owned record (2026-11-25, BCECD1F3), **built and reviewed** (row 4); the `sudo` trial owed (corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26) |
| Item 11: a chain from Terminal and one from ssh read whole | item 11 | **taken** for root's records (M8) and for an escaped Terminal window's chain (K-ESC-1/2: `login` refused, every link read by the fallback); ANC-1, ANC-2 **not run** |
| Item 12: `launchctl print`'s lines | item 12 | **taken** (M11): the format `NodeAgent.printed` parses |
| Item 13: the checked node start | item 13 | the check not built (it waits on item 10); what it gates built and off. **Since: built and reviewed, off** behind `HostImages.isCheckedMacNode` (row 5; corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26) |
| The unified log: writing under another image's name; `log show` without admin | step 6 | **taken** (M10) |
| The design's own tests with SIP on | the tasks' rows | **taken** (M13): 98 of 98 |

## The measurements taken

### M1. System Integrity Protection

```
$ csrutil status
System Integrity Protection status: enabled.
```

The hosted runner's SIP is off; every result below is with it on.

### M2. The environment line under SIP

`facts --pid PID MEASURE_MARK` reads `KERN_PROCARGS2` of a target started with `MEASURE_MARK=1`, from a sibling process
(not its parent: the relation the server has to a peer). Three kinds of target: an Apple platform binary
(`/bin/sleep`), the probe as the linker signed it (ad hoc, no runtime), and a copy signed
`codesign -s - -o runtime` (ad hoc, Hardened Runtime: what the install makes of the command line); each as a child and
double-forked into launchd (`detach`).

```
=== child of this shell, read by a sibling: /bin/sleep 30
procargs=read bytes=34 argc=2 environment_entries=0 MEASURE_MARK_seen=0
cs_status=0x26011b11 valid=1 … runtime=1 … platform=1
=== detached (double fork + setsid, parent launchd): /bin/sleep 30
procargs=read bytes=34 argc=2 environment_entries=0 MEASURE_MARK_seen=0
=== child of this shell, read by a sibling: <clone>/.build/mac-measure/facts --sleep 30
procargs=read bytes=3236 argc=3 environment_entries=46 MEASURE_MARK_seen=1
cs_status=0x22020201 valid=1 … runtime=0 linker_signed=1 platform=0
=== detached (double fork + setsid, parent launchd): <clone>/.build/mac-measure/facts --sleep 30
procargs=read bytes=3236 argc=3 environment_entries=46 MEASURE_MARK_seen=1
=== child of this shell, read by a sibling: <clone>/.build/mac-measure/facts-hardened --sleep 30
procargs=read bytes=3260 argc=3 environment_entries=46 MEASURE_MARK_seen=1
cs_status=0x22011311 valid=1 … hard=1 kill=1 runtime=1 linker_signed=0 platform=0
=== detached (double fork + setsid, parent launchd): <clone>/.build/mac-measure/facts-hardened --sleep 30
procargs=read bytes=3252 argc=3 environment_entries=46 MEASURE_MARK_seen=1
```

The runner reads each target with the hardened copy too (the server is hardened): the same `environment_entries` and
`MEASURE_MARK_seen` each time (`/bin/sleep` 0, the two builds 46 and 1).

**Conclusion.** With SIP on, a process of the user's reads another's environment, its own or hardened code alike;
only an Apple platform binary's environment comes back empty (its arguments still read). **The design assumed the
opposite** ("a real Mac with SIP on is expected not to, which fails the line for every peer"). For the rule: the line
can be read of the peer itself (the command line is the user's build, not a platform binary), so
`VIBESWITCHER_SESSION` on the peer is visible; it is empty for an Apple ancestor (`zsh`, `bash`, `login`), so an
ancestor's environment says nothing. It stays a guard rail: a session's process runs the command line with the
variable unset. `ApprovalVoice` dropping the line costs little; putting it back for the peer alone is possible.
`SessionStraysTests/aProcessWhoseEnvironmentIsHiddenIsTheSessionsOnlyWhenItStartedIt` (skipped on the runner for this)
passes here (M13).

### M3. Double fork and setsid

The same runs (M2): a double-forked, `setsid` child has `ppid=1`, a process group of its own, `tty=none`, and keeps its
environment and code; a third probe reads all of it (`bsdinfo=read ppid=1 pgid=61834 … tty=none`). As the design says:
ancestry says nothing after it, the terminal line is lost to it (and `script` gives a new one, not measured again).

### M4. Coalitions: a fact the design doesn't name

`launchctl print` shows each job's `resource coalition` and `jetsam coalition`. xnu's `PROC_PIDCOALITIONINFO` (flavour
20, not in the SDK's headers) reads a process's two ids:

```
--- self                    coalition=read resource=1841 jetsam=1842
--- child                   coalition=read resource=1841 jetsam=1842
--- detached (facts)        bsdinfo=read ppid=1 …  coalition=read resource=1841 jetsam=1842
--- detached (hardened)     bsdinfo=read ppid=1 …  coalition=read resource=1841 jetsam=1842
--- detached (/bin/sleep)   bsdinfo=read ppid=1 …  coalition=read resource=1841 jetsam=1842
--- pid 1                   coalition=read resource=1 jetsam=3
--- zombie                  coalition=refused got=0 errno=3 (No such process)
```

**Conclusion.** A process keeps its coalition through fork, exec, `setsid` and being reparented to launchd: what
Linux's cgroup gives (a process of the user's can't leave `user@<uid>.service`). launchd puts each job in a coalition
of its own (each job's `resource coalition` in `launchctl print`; that a session's own job gets a new one is ESC-3's to
show, not measured here). So a session's descendants stay in the coalition of whatever job started the session (the app's today,
the node's LaunchAgent on a node), however they detach, **unless they go through launchd** (`open -a Terminal`,
AppleScript, `launchctl bootstrap`): the escapes ESC-1 to 3 measure where those land. A candidate line, at no dialog's
cost: "the peer isn't in the node's coalition" refuses every detached descendant of a node session that didn't go
through launchd. It is private (an SPI risk like the responsible pid's) and escapable as the design says the Mac is;
the dialog stays the lock. Not in the design today: for the review that writes the rule.

### M5. The responsible pid

`responsibility_get_pid_responsible_for_pid` (private, by `dlsym`) for each process above:

```
self: pid=60004 …            responsible=60004
child /bin/sleep (59980)     responsible=59980
detached /bin/sleep (59985)  responsible=59985
child facts (59988)          responsible=59988
the reader's shell (59979)   responsible=59979
```

**Conclusion.** Under the app's session host every process measured is its own responsible process: nothing was
inherited from the shell to its child. There is no positive control here (no case returned anything but its
argument), so this says only that from here the line tells nothing; ANC-1 and ESC-1 (run from Terminal.app) are the
first that can show it naming another process. Whether it is inherited under Terminal
(the design: "inherited across fork, exec, setsid") and where the escapes land is in ESC-1 to 3's records (each prints
`responsible=` for the escaped shell and for the user's own). Not a rule alone, as the design says.

### M6. The Hardened Runtime: the status word and `DYLD_INSERT_LIBRARIES`

`inject.dylib` writes a marker file if dyld loads it. The same probe, as the linker signed it and as signed
`codesign -s - -o runtime`:

```
$ MEASURE_INJECTED=<marker> DYLD_INSERT_LIBRARIES=<clone>/.build/mac-measure/inject.dylib facts --sleep 0
facts: exit=0 marker=injected
facts-hardened: exit=0 marker=absent
$ codesign -dv facts-hardened
CodeDirectory v=20500 size=312 flags=0x10002(adhoc,runtime) hashes=3+2 location=embedded
```

The status word of the hardened copy, read with `csops(CS_OPS_STATUS)`: `0x22011311`: valid, `CS_HARD`, `CS_KILL`,
`CS_RUNTIME`, no `CS_GET_TASK_ALLOW`, not `CS_DEBUGGED`; exactly what `Platform.CodeIdentity.isHardened` asks.
`Tests/SecurityAudit/library-injection.test.mjs` (skipped on the runner) passes here: "app and all three helpers reject
DYLD injection with valid hardened signatures". `task_for_pid` wasn't tried (the dialog); the status word is the
design's own proof.

**Conclusion.** Matches item 3: an ad hoc signature with `--options runtime` keeps `DYLD_*` out of the command line
and the server, with SIP on. Without the runtime flag, injection works: `mac_sign_hardened` is what makes it hold.

### M7. The connect-write-exec race

`token-exec`: a child connects to this process's socket, writes, then execs the hardened probe; the audit token read
at the accept (`LOCAL_PEERTOKEN`) is asked of Security before and after the exec.

```
this program's file cdhash=dd3ee75e4333bf14
PROGRAM's file cdhash=bd5977d7fff8c336
before exec: SecCodeCopyGuestWithAttributes=0 SecCodeCheckValidity=0 cdhash=dd3ee75e4333bf14
child now runs <clone>/.build/mac-measure/facts-hardened
after exec, the token read at the accept: SecCodeCopyGuestWithAttributes=-67065
after the child ended: SecCodeCopyGuestWithAttributes=100003
```

`-67065` is "host has no guest with the requested attributes"; `100003` is `ESRCH`.

**Conclusion.** Matches the design: once the peer execs, the token taken at its connect names no code, so a check
bound to the token (`Link.isProcess(of:)`, `ApprovalVoice`'s code check) fails closed. A process can't connect as one
image and be judged as the command line it execs into.

### M8. Root's records, a zombie

```
--- pid 1 (root)
bsdinfo=refused got=0 errno=1 (Operation not permitted)
shortbsdinfo=read ppid=0 pgid=1 uid=0 status=2
kern_proc_pid=read ppid=0 tdev=none
procargs=refused errno=22 (Invalid argument)
--- a child of this process's that exited, not reaped (facts --zombie)
bsdinfo=refused got=0 errno=3 (No such process)
shortbsdinfo=refused got=0 errno=3 (No such process)
kern_proc_pid=read ppid=60297 tdev=none
procargs=refused errno=22 (Invalid argument)
cs_status=unreadable errno=3 (No such process)
```

**Conclusion.** Item 11's premise holds: `PROC_PIDTBSDINFO` is refused (EPERM) for root's processes, the short record
and `sysctl KERN_PROC_PID` read them, the arguments don't. A zombie gives only `KERN_PROC_PID` (its parent), and no code
status: the fallback reads a zombie's parent, and only the token check (`isProcess(of:)`, M7) keeps such a link from
counting. `ProcessesTests` (launchd's link, a zombie, another user's process listed) passes here (M13). The chains
through `login` and `sshd-session` themselves are ANC-1 and ANC-2.

### M9. LocalAuthentication, asked nothing

`la can` (the node's own `Platform.Approval.availability()`, compiled from `Sources/VibePlatform/Approval*.swift`
unchanged) from this agent session's process:

```
availability=available
deviceOwnerAuthentication=true error=none
deviceOwnerAuthenticationWithBiometrics=true error=none
biometryType=touchID
$ la ask "test" 5      # without MEASURE_ASK=yes
la: ask refused: MEASURE_ASK=yes isn't set (only the user's measurement scripts set it)    (exit 65)
```

**Conclusion.** A process under an agent's session, in the login session, can raise the dialog (the design: "can make
the prompt appear; can't answer it"). The server's one-at-a-time rule and its 10 s cooldown (`ApprovalRequests.swift`
66, 68) hold for the server's dialogs only: a session can raise LocalAuthentication dialogs of its own, worded like the
node's, but under its own program's name (LA-1 records what the title shows). Approving one gives it nothing (no secret
comes back, and a password typed goes to the system), so the risk is training the user to approve: the review should
weigh it.

### M10. The unified log (step 6)

One entry each under a throwaway subsystem (`dev.vibeswitcher.measure.<random>`), written by `oslog` run four ways, and
one by `logger`; then `log show` as the user:

```
$ /usr/bin/log show --last 2m --style ndjson --predicate 'subsystem == "…" OR eventMessage CONTAINS "logger-…"'
log show exit=0 seconds=2
'measure plain-…'    processImagePath=<clone>/.build/mac-measure/oslog
'measure symlink-…'  processImagePath=<clone>/.build/mac-measure/oslog   (run through fakebin/vibeswitcher, a link)
'measure copy-…'     processImagePath=<clone>/.build/mac-measure/oslog   (run as fakebin/vibeswitcher-copy, a copy)
'measure execa-…'    processImagePath=<clone>/.build/mac-measure/oslog   (exec -a /usr/local/bin/vibeswitcher)
'logger-…'           processImagePath=/usr/bin/logger  userID=501
```

Then a different program (`forger`), its `LC_UUID` set to `oslog`'s and signed again ad hoc, run from another folder:

```
UUID: EB152B86-… (arm64) <clone>/.build/mac-measure/oslog
UUID: EB152B86-… (arm64) <clone>/.build/mac-measure/fakebin/forger        (after the patch; cmp: the files differ)
{'eventMessage': '<compose failure [UUID]>', 'processImagePath': '<clone>/.build/mac-measure/oslog',
 'senderImagePath': '<clone>/.build/mac-measure/oslog', 'processID': 60638}
```

**Conclusion.** `log show` needs no admin (2 s for two minutes). logd names an entry's image **by the Mach-O UUID**, as
first seen at a path, not by the file that ran: a copy, a link and `exec -a` all read as the original, and another
program carrying the original's UUID is logged under the original's path. Its message failed to compose
(`<compose failure [UUID]>`); the runner's forger, built from `oslog.c` itself with one function more, failed the same
way, so whether a forger can make its message compose too is **not measured**. The runner adds one more: its fresh
`oslog`, built in a scratch folder from the same source (a deterministic build, so the same UUID), was logged under
the `.build/mac-measure` path logd saw first; a build of the installed command line's commit has its UUID. So **the
design's step 6 ack rule, "written by the installed command line's image" (`processImagePath`), is forgeable by any
process of the user's** as to the path: the installed command line's UUID is readable from its file, and a rule that
also wanted the message to compose would stand on what isn't measured. Weaker than the design's "weaker than Linux's". Step 6 needs
another anchor (a nonce the server hands only to the request it accepted, or the record in the host's vault alone).

### M11. `launchctl print`'s lines (item 12, `NodeAgent.printed`)

`launchctl print gui/501/com.apple.Finder`, the job's own lines (tabs shown as `^I`):

```
1:gui/501/com.apple.Finder = {
3:^Ipath = /System/Library/LaunchAgents/com.apple.Finder.plist
4:^Itype = LaunchAgent
5:^Istate = running
8:^Iprogram = /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
9:^Iinherited environment = {
22:^Idomain = gui/501 [100020]
28:^Ipid = 774
```

**Conclusion.** On macOS 27.2 the job's own lines sit one tab in, `pid = ` and `program = ` as `NodeAgent.printed`
parses them; nested blocks deeper. Item 12 stands as written: `program` is the configured program, and `path` the
plist launchd loaded (any path a session gives `bootstrap`, which is item 10's point).

### M12. The install's machine (item 7)

```
root:wheel drwxr-xr-x /Applications/Xcode.app                          (xattrs: com.apple.appstore.*)
root:wheel drwxr-xr-x /Applications/Xcode.app/Contents/Developer
root:wheel lrwxr-xr-x …/XcodeDefault.xctoolchain/usr/bin/swiftc
root:wheel drwxr-xr-x …/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx
<user>:admin drwxrwxr-x /opt/homebrew/bin        (writable by the user)
which -a shasum: /opt/homebrew/bin/shasum, /usr/bin/shasum
/usr/bin/jq: jq-1.7.1-apple; /usr/bin/shlock; /bin/realpath
server socket path for this account (~/.vibeswitcher/v2/node/v2/server.sock): 50 bytes (limit 104)
port 22 on loopback: closed (Remote Login off)
```

**Conclusion.** An App Store Xcode is root-owned throughout, as the toolchain check wants (its `find`'s time not
measured: no install run). Homebrew's `shasum` comes first on the user's PATH: `install-node-mac.sh` names
`/usr/bin/shasum` and sets `PATH=/usr/bin:/bin` (its lines 49, 150), so it holds; the seal list's "Homebrew's prefix"
row (step 8) is right to watch it. macOS 27.2 is past item 7's "macOS 26 or later" for the run paths. The socket path
fits. Remote Login is off: LA-5 and ANC-2 need the user to turn it on (and off).

### M13. The design's tests, with SIP on

```
$ bash scripts/test.sh --filter 'MacServerChildTests|MacSigningTests|CodeIdentityTests|ProcessesTests|PeerRunnerTests|
    ApprovalVoiceTests|ApprovalJudgmentTests|ApprovalLintTests|NodeAgentTests|SocketsTests|HostConnectorTests|
    NodeRootHostTests|ServiceTests|NodeSystemTests|SessionStraysTests/aProcessWhoseEnvironmentIsHidden|
    EndingASessionTests/endingASessionEndsWhatItStartedOnly|MCPHandoverTests/anUnsignedBuildLeavesTheOldOneServing'
━ Test run with 98 tests in 17 suites passed after 7.109 seconds with 2 known issues.
web tests: 33 of 33 passed
PASS: unknown processes cannot spawn, discover, read, attach, type, resize or shut down the scratch host.
PASS: app and all three helpers reject DYLD injection with valid hardened signatures.
exit 0
```

Among them: `MacServerChildTests`' three (`aHardenedServerFromItsCheckedFileIsTheApp`,
`aServerWithoutTheHardenedRuntimeIsRefusedAndEnded`, `aServerFileReplacedAfterTheStartStartsNothing`) with SIP on, as
`87de7244`'s row asks; `MacSigningTests`' two; and the runner's SIP skips: `SessionStraysTests/aProcessWhoseEnvironmentIsHiddenIsTheSessionsOnlyWhenItStartedIt`,
`EndingASessionTests/endingASessionEndsWhatItStartedOnly`, `MCPHandoverTests/anUnsignedBuildLeavesTheOldOneServing`
and `library-injection.test.mjs` all pass, so those four are the runner's. The two known issues are `ProcessesTests`'
own `withKnownIssue` (`aChildCollectedElsewhereIsNamedAndItsEndComes`, `aChildStillThereAtTheLimitIsNamedAndTheWaitEnds`).

### M14. Read from the code

- The command line's wait for a state change under the Mac's rule: `max(timeout, 120)` (`NodeClient.swift` 431,
  `approvalPatience`), so `web`'s `timeout: 30` waits 120 s there; the dialog's own is 60 s (`ApprovalVoice.System(timeout: 60)`, `ServerStart.swift` 120).
- `launchctl print` of the user's GUI domain works without admin from the `Aqua` session (M11).

### K-M1. A received pair end's token, in KP10's order (the keeper's design)

The row [the keeper's design](../superpowers/specs/2026-11-27-v2-mac-keeper-design.md) owes ("Measurements owed",
K-M1; slices K2 and K4a wait on it), taken 2026-11-27 on this Mac (as above: macOS 27.2, SIP enabled), as the user, no
`sudo`, no dialog, no debugger or process-inspection tool, from an agent's session in a scratch clone of
`v2-mac-keeper-k0`. The probe is [probes/pair-token.c](../../scripts/mac-measure/probes/pair-token.c), run by
[pair-token.sh](../../scripts/mac-measure/pair-token.sh) (`bash scripts/mac-measure/pair-token.sh`: it builds the probe
and `facts`, signs both ad hoc with the Hardened Runtime, runs it on a socket in its scratch folder and prints its lines
with the scratch folder, home and account name cut). The probe plays the keeper: each trial forks a fresh **maker**,
which makes a pair after its fork and sends one end with the hello's 23 bytes over a connection by `SCM_RIGHTS`; the
keeper asks the received end's `LOCAL_PEERTOKEN` afresh (a new `getsockopt` each time) and asks Security for that token
(`SecCodeCopyGuestWithAttributes`, then `SecCodeCheckValidity`, the dynamic cdhash and status word: the node's
`runs`/`isHardened`). In (a) to (c) the token is asked only after the maker's exec (the exec seen by its close-on-exec
pipe's end of file), except in the control marked so. The maker execs `facts-hardened` (`facts --sleep 30`, ad hoc,
Hardened Runtime: the measurements' hardened image of M6 and M7), not the node's host: a copy of the host started bare
could touch the account's `~/.vibeswitcher`, and Security's answer for a token doesn't depend on which hardened image it
names. Each process reports its own pid and pidversion (its own task's audit token, `TASK_AUDIT_TOKEN`), so each token
read is named by whose it is; no other task's port is taken. The handover keeper's own pairs as the positive control:
`MacKeeperHandoverTests` pass on this branch (`bash scripts/test.sh --filter MacKeeperHandoverTests`, with K0's move),
and the probe's own control trial is the first below.

```
$ bash scripts/mac-measure/pair-token.sh
## K-M1  27.2 (26B123), System Integrity Protection status: enabled.
pair-token: CodeDirectory v=20500 size=372 flags=0x10002(adhoc,runtime) hashes=5+2 location=embedded
PROGRAM (facts-hardened): CodeDirectory v=20500 size=312 flags=0x10002(adhoc,runtime) hashes=3+2 location=embedded
this probe's file cdhash=0ab8a83174341971
PROGRAM's file cdhash=bd5977d7fff8c336
== control: a live maker that hasn't exec'd (the positive control)
  keeper pid=64169 pidversion=3701278; maker pid=64231 pidversion=3701453
  the maker alive, not exec'd, nothing written: LOCAL_PEERTOKEN pid=64231 pidversion=3701453 = the maker, as it was before any exec | LOCAL_PEERPID=64231 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
== control: the token asked at the receipt too, then the maker writes a request and execs
  keeper pid=64169 pidversion=3701278; maker pid=64235 pidversion=3701460
  asked at the receipt, before the exec (this control only): LOCAL_PEERTOKEN pid=64235 pidversion=3701460 = the maker, as it was before any exec | LOCAL_PEERPID=64235 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=64235 pidversion=3701462 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64235 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the token kept from the receipt, asked of Security again after the exec: pid=64235 pidversion=3701460 = the maker, as it was before any exec | Security: guest=-67065
  the keeper read the 3-byte request and wrote a 3-byte answer on its end
  after the keeper's read and write: LOCAL_PEERTOKEN pid=64235 pidversion=3701462 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64235 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
== (a) a forked child of the maker writes on the maker's end; the maker execs; then the token
  keeper pid=64169 pidversion=3701278; maker pid=64238 pidversion=3701466; forked child pid=64239 pidversion=3701468
  the forked child wrote 1 byte on the maker's end
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=64239 pidversion=3701468 = the maker's forked child | LOCAL_PEERPID=64239 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
== (a) a forked child of the maker writes and reads on the maker's end; the maker execs; then the token
  keeper pid=64169 pidversion=3701278; maker pid=64240 pidversion=3701472; forked child pid=64241 pidversion=3701473
  the keeper wrote 1 byte on its end (for the child to read), before the child acted
  the forked child wrote 1 byte on the maker's end and read 1
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=64241 pidversion=3701473 = the maker's forked child | LOCAL_PEERPID=64241 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
== (b) the maker writes a request and execs; the keeper reads and writes on its end; the token after each
  keeper pid=64169 pidversion=3701278; maker pid=64242 pidversion=3701476
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=64242 pidversion=3701481 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64242 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper read the 3-byte request and wrote a 3-byte answer on its end
  after the keeper's read and write: LOCAL_PEERTOKEN pid=64242 pidversion=3701481 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64242 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
== (c) KP10: the maker writes a request, gives a copy of its end to a third process, execs; the keeper answers; the third reads it
  keeper pid=64169 pidversion=3701278; maker pid=64246 pidversion=3701484; third pid=64249 pidversion=3701488
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=64246 pidversion=3701490 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64246 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper read the 3-byte request and wrote a 3-byte answer on its end
  after the keeper's read and write: LOCAL_PEERTOKEN pid=64246 pidversion=3701490 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=64246 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the third process read the answer on its copy of the maker's end
  after the third's read: LOCAL_PEERTOKEN pid=64249 pidversion=3701488 = the third process | LOCAL_PEERPID=64249 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
== (d) the names of a pair's ends and of a connection's
  socketpair, end 0: getsockname len=16 family=1 path="" getpeername len=16 family=1 path=""
  socketpair, end 1: getsockname len=16 family=1 path="" getpeername len=16 family=1 path=""
  socketpair, end 1 received by SCM_RIGHTS: getsockname len=16 family=1 path="" getpeername len=16 family=1 path=""
  connect: the connecting end: getsockname len=16 family=1 path="" getpeername len=106 family=1 path="<scratch>/d.sock"
  connect: the accepted end: getsockname len=106 family=1 path="<scratch>/d.sock" getpeername len=16 family=1 path=""
  (the listener's path unlinked)
  connect: the connecting end: getsockname len=16 family=1 path="" getpeername len=106 family=1 path="<scratch>/d.sock"
  connect: the accepted end: getsockname len=106 family=1 path="<scratch>/d.sock" getpeername len=16 family=1 path=""
  (the listener closed)
  connect: the accepted end: getsockname len=106 family=1 path="<scratch>/d.sock" getpeername len=16 family=1 path=""
  (a listener's path renamed before a connect through the new name)
  connect via the new name: the connecting end: getsockname len=16 family=1 path="" getpeername len=106 family=1 path="<scratch>/d.sock"
  connect via the new name: the accepted end: getsockname len=106 family=1 path="<scratch>/d.sock" getpeername len=16 family=1 path=""
  other ways tried to make two connected stream ends unnamed on both sides:
  bind to an empty path (sun_path "", full length): refused errno=2 (No such file or directory)
  bind with no path (the length of the family alone): refused errno=22 (Invalid argument)
  listen on a socket never bound: refused errno=22 (Invalid argument)
  that socket: getsockname len=16 family=1 path="" getpeername refused errno=57 (Socket is not connected)
  connect to an empty path: refused errno=2 (No such file or directory)
  connect with no path (the length of the family alone): refused errno=22 (Invalid argument)
  connect to a path where nothing is bound: refused errno=2 (No such file or directory)
== (e) baseline: the other end open
  keeper pid=64169 pidversion=3701278; maker pid=64250 pidversion=3701492
  the maker's end open, untouched (the baseline): LOCAL_PEERTOKEN pid=64250 pidversion=3701492 = the maker, as it was before any exec | LOCAL_PEERPID=64250 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x4 POLLOUT
  recv(MSG_PEEK|MSG_DONTWAIT): -1 errno=35 (Resource temporarily unavailable)
  (the maker ended)
  after the maker ended too: LOCAL_PEERTOKEN refused errno=57 (Socket is not connected)
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
== (e) the other end half-closed: shutdown(SHUT_WR)
  keeper pid=64169 pidversion=3701278; maker pid=64251 pidversion=3701497
  after the maker's shutdown(SHUT_WR), its end kept open: LOCAL_PEERTOKEN pid=64251 pidversion=3701497 = the maker, as it was before any exec | LOCAL_PEERPID=64251 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
  (the maker ended)
  after the maker ended too: LOCAL_PEERTOKEN refused errno=57 (Socket is not connected)
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
== (e) the other end closed
  keeper pid=64169 pidversion=3701278; maker pid=64252 pidversion=3701498
  after the maker's close of its end (its only holder; the maker alive): LOCAL_PEERTOKEN refused errno=57 (Socket is not connected)
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
  (the maker ended)
  after the maker ended too: LOCAL_PEERTOKEN refused errno=57 (Socket is not connected)
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
== (e) a former holder's shutdown(SHUT_RD)
  keeper pid=64169 pidversion=3701278; maker pid=64254 pidversion=3701501; forked child pid=64256 pidversion=3701504
  after a former holder's shutdown(SHUT_RD) and close (the maker's forked child, ended; the maker's end open): LOCAL_PEERTOKEN pid=64254 pidversion=3701501 = the maker, as it was before any exec | LOCAL_PEERPID=64254 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 0 revents=0x0
  recv(MSG_PEEK|MSG_DONTWAIT): -1 errno=35 (Resource temporarily unavailable)
  (the maker ended)
  after the maker ended too: LOCAL_PEERTOKEN refused errno=57 (Socket is not connected)
  poll (POLLIN|POLLOUT|POLLPRI asked, no wait): 1 revents=0x13 POLLIN POLLPRI POLLHUP
  recv(MSG_PEEK|MSG_DONTWAIT): 0
== (f) a connection: the connector writes, then its forked child holding a copy writes last
  the connector wrote 1 byte, then its forked child (holding a copy of the connecting socket) wrote 1
  keeper pid=64169 pidversion=3701278; maker pid=64260 pidversion=3701511; forked child pid=64261 pidversion=3701512
  at the accept, nothing read: LOCAL_PEERTOKEN pid=64261 pidversion=3701512 = the maker's forked child | LOCAL_PEERPID=64261 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  the keeper read 2 bytes: mf
  after the keeper's read: LOCAL_PEERTOKEN pid=64261 pidversion=3701512 = the maker's forked child | LOCAL_PEERPID=64261 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
== (f) a connection: the connector writes, its forked child writes, the connector writes last
  the connector wrote 1 byte, then its forked child (holding a copy of the connecting socket) wrote 1, then the connector wrote 1 more
  keeper pid=64169 pidversion=3701278; maker pid=64262 pidversion=3701514; forked child pid=64263 pidversion=3701515
  at the accept, nothing read: LOCAL_PEERTOKEN pid=64262 pidversion=3701514 = the maker, as it was before any exec | LOCAL_PEERPID=64262 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
  the keeper read 3 bytes: mfM
  after the keeper's read: LOCAL_PEERTOKEN pid=64262 pidversion=3701514 = the maker, as it was before any exec | LOCAL_PEERPID=64262 | Security: guest=0 valid=0 cdhash=0ab8a83174341971 (this probe's file) hardened=yes
```

Run six times (the script twice before this one, the probe three times by hand from the same source; this last run
added the kept token's line after the blind check asked for it): the same lines but for the pids, the pidversions and
the probe's own cdhash. A first version of the probe, whose maker closed the
sent end and its connection right after the `sendmsg`, before the keeper's `recvmsg`, twice read end of file on the
received end where the maker had written a request (once in (b), once in (c), in two runs); with the maker waiting until
the keeper had the end, no run lost it. Not measured further (XNU's collection of in-flight Unix sockets is a
candidate); the host's client (K4) keeps the connection and both ends until the answer, so it waits for the keeper's
receipt anyway.

**What each letter says, for K2 and K4a.** The design assumes the pair's token is "fixed when the pair was made" (its
"The interface", step 3, from the Mac spec's sentence). **It isn't, on this Mac**: `LOCAL_PEERTOKEN` on a received
pair end names whichever process last sent or received on the other end, as that process runs *now*, which is what
`Sockets+Darwin.swift`'s `peerToken` comment says for every socket.

- **The controls.** A live maker that hasn't exec'd is named and accepted (valid, its cdhash, hardened): the check
  works when nothing moved. Asked at the receipt the token names the maker as it was; asked again after its exec, the
  same pid with a **new pidversion**, and Security **accepts** it as PROGRAM's code, hardened; the token *kept* from the
  receipt, asked of Security again after the exec, is **refused** (`-67065`, no such guest, as M7's connection token).
  So Security refuses a pair's token taken before an exec, but a token read after it names the new image: only a token
  taken before the exec, kept and asked again (or compared with step 5's second read), tells an exec.
- **(a)** A forked child of the maker that writes (or writes and reads) on the maker's end, the maker then exec'd: the
  token names **the forked child**, accepted by Security as the child's code. For K2: the token moves to a forked
  holder, so a pinned host's forked child (or any holder of its end) that writes last is who the keeper would judge.
- **(b)** The maker writes a request and execs; the keeper reads it and answers on its own end: the token names the
  maker's **image after the exec** (new pidversion), accepted as PROGRAM's code, before and after the keeper's own read
  and write. The keeper's own reads and writes don't move it. For K2: **KP10's "write then exec" passes Security**:
  the token asked after the request names the exec'd image, so a session that makes the pair, writes a request and
  execs a pinned hardened host is judged as that host; only a token taken before the exec and compared would tell.
- **(c)** KP10 whole: the maker writes a request, gives a copy of its end to a third process, execs; the keeper reads
  and answers: the token names the maker's exec'd image (accepted as PROGRAM's code) until the third process reads the
  answer on its copy, and then **the third process**. For K2: the keeper's answer goes to whoever holds the maker's
  end, and the token read before answering names the exec'd image, so the sibling of KP10 gets the answer.
- **(d)** Both ends of a `socketpair` have no path on either side (`len=16`, empty), also after an end travels by
  `SCM_RIGHTS`; a connection made by `connect` and `accept` has the listener's path on one side of each end (the
  connecting end's peer name, the accepted end's own name), still after the path is unlinked, after the listener is
  closed, and after the path is renamed (the name stays the one bound). As the design assumes. That nothing else makes
  two connected stream ends unnamed on both sides is argued, not measured: what was tried (binding or connecting to an
  empty path or none, listening unbound) is refused.
- **(e)** After the other end's `close` (its only holder), the token read again on the received end is **refused**
  (`ENOTCONN`, 57); after its `shutdown(SHUT_WR)` with the end kept open, the token **still reads** (the maker); after
  a former holder's `shutdown(SHUT_RD)` and close, the token is still the maker's, no `POLLHUP` and no end of file
  (`recv` `EAGAIN`), but `POLLOUT` is no longer reported (`poll` 0, `revents` 0, where the open baseline gives
  `POLLOUT`). `poll` gives `POLLIN|POLLPRI|POLLHUP` and `recv` end of file **both** after a close and after `SHUT_WR`: `POLLHUP`
  doesn't tell a closed other end from a half-closed one; the token read again does (refused once closed). For K2:
  step 5's second token read refuses a closed other end by itself; `POLLHUP` isn't the test.
- **(f)** A connection's token at the accept names **the last writer** of the connecting socket: its forked child when
  the child wrote last, the connector when it wrote after the child; the keeper's reading doesn't change it. For K2:
  the hello's sender check (the connection's token equals the pair's) narrows only to "the process that last used each
  socket", and both move the same way.

**For the lead (a finding, not designed around here).** (a), (b) and (c) are the design's own "If K-M1 finds a pair's
token moves too" case ("The interface", after step 5): the pair proves nothing as it stands, so K2 isn't built in that
form; and **K4a**, whose children prove themselves with "a fresh pair (the spawned pid, the expected cdhash, hardened)",
rests on the same assumption. The handover keeper (`MacHandoverKeeper.swift`'s header: "each proof is a pair made by
the process proving itself, after its exec") and the Mac spec's "fixed at creation" sentence rest on it too; whether
the handover keeper's order of reads is open to (b) wasn't looked at here.

### K-M1, second part: (g) to (o), for the proof's redesign

Taken 2026-11-27 on this Mac (macOS 27.2, SIP enabled), as the user, no `sudo`, no dialog, no debugger or
process-inspection tool, from an agent's session in a scratch clone of `v2-mac-keeper-proof`, after the first part
refuted the fixed token. Same probe and script (`bash scripts/mac-measure/pair-token.sh`), its first part unchanged (its
lines reproduced in this run but for pids, pidversions and the probe's cdhash), with a second hardened image beside
`facts-hardened`: [probes/pair-image.c](../../scripts/mac-measure/probes/pair-image.c), ad hoc signed with the Hardened
Runtime under its own identifier (its own cdhash, `IMAGE's file` below), which does on the probe's word what the node's
host does in some mode with descriptors it was started with: a line on descriptor 2, one read of descriptor 0 that
doesn't wait, an answer on a descriptor it was named, a descriptor taken by `SCM_RIGHTS` and read once, a Mach message.
Neither image is the node's host (a copy of the host started bare could touch `~/.vibeswitcher`). In the scenes (g),
(h), (i) and (m) the maker is K-M1's (a pair made after its fork, one end sent with the hello over a connection, its
own copy kept until the keeper holds the end), and **S** is the maker's forked child, holding a copy of the maker's end
and doing nothing until told. The Mach trials (n) give the probe's port to a child as its bootstrap special port (set
around the fork and restored at once, or named for `posix_spawn`); the children and images look nothing up through it.
The run below is the second of two whole runs and three runs of the probe by hand; the lines were the same in each
but for the pids, pidversions, cdhashes and (l)'s counts (first runs: 127 and 50 ends of file of 200, this run 62 and 14).

```
$ bash scripts/mac-measure/pair-token.sh
## K-M1  27.2 (26B123), System Integrity Protection status: enabled.
pair-token: CodeDirectory v=20500 size=436 flags=0x10002(adhoc,runtime) hashes=7+2 location=embedded
PROGRAM (facts-hardened): CodeDirectory v=20500 size=312 flags=0x10002(adhoc,runtime) hashes=3+2 location=embedded
IMAGE (pair-image): CodeDirectory v=20500 size=292 flags=0x10002(adhoc,runtime) hashes=3+2 location=embedded
this probe's file cdhash=25c17cee63cbb36a
PROGRAM's file cdhash=bd5977d7fff8c336
IMAGE's file cdhash=712188d35768e0a6
[… the first part, (controls) to (f), as in the row above but for the pids, pidversions and the probe's cdhash …]
#### K-M1, second part: (g) to (o)
== (g1) the whole write-then-exec, the silent image: the maker writes the request and execs PROGRAM; every point a keeper could ask the token
  keeper pid=36555 pidversion=6448272; maker pid=36621 pidversion=6448357; third pid=36622 pidversion=6448358
  at the receipt, before any request: LOCAL_PEERTOKEN pid=36621 pidversion=6448357 = the maker, as it was before any exec | LOCAL_PEERPID=36621 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  the maker writes the request on its end: done
  the maker exec'd: it now runs PROGRAM
  after the exec, before the keeper reads the request: LOCAL_PEERTOKEN pid=36621 pidversion=6448359 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36621 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper read 3 bytes: req
  bytes waiting on the keeper's end after the request: 0
  after the keeper read the request: LOCAL_PEERTOKEN pid=36621 pidversion=6448359 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36621 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper wrote its 3-byte reply
  after the keeper's reply: LOCAL_PEERTOKEN pid=36621 pidversion=6448359 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36621 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper wrote an 8-byte nonce on its end
  the keeper read 0 of the answer's 8 bytes within 1 s
  after a second round (a nonce) that nothing answered: LOCAL_PEERTOKEN pid=36621 pidversion=6448359 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36621 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the last read against the first read after the exec: the same pid and pidversion
== (g2) the same, the nonce sent once the token names PROGRAM (before any reply); S, silent until now, answers it
  keeper pid=36555 pidversion=6448272; maker pid=36727 pidversion=6448504; third pid=36728 pidversion=6448505
  the maker writes the request on its end: done
  the maker exec'd: it now runs PROGRAM
  after the exec: LOCAL_PEERTOKEN pid=36727 pidversion=6448506 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36727 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
  the keeper read 3 bytes: req
  the keeper wrote an 8-byte nonce on its end
  S reads the nonce on its copy and writes it back: done
  the keeper read the answer: the nonce, as sent
  after the answer: LOCAL_PEERTOKEN pid=36728 pidversion=6448505 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36728 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  this read against the first read after the exec: not the same
== (g3) as (g2), IMAGE the exec'd image (the maker's end its descriptors 0, 2, 5); after S's answer IMAGE writes a line on its descriptor 2
  keeper pid=36555 pidversion=6448272; maker pid=36729 pidversion=6448507; third pid=36730 pidversion=6448508
  the maker writes the request on its end: done
  the maker exec'd: it now runs <scratch>/bin/pair-image
  after the exec: LOCAL_PEERTOKEN pid=36729 pidversion=6448509 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36729 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  the keeper read 3 bytes: req
  the keeper wrote an 8-byte nonce on its end
  S reads the nonce on its copy and writes it back: done
  the keeper read the answer: the nonce, as sent
  after the answer: LOCAL_PEERTOKEN pid=36730 pidversion=6448508 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36730 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  IMAGE writes a line on its descriptor 2: done
  after IMAGE's step: LOCAL_PEERTOKEN pid=36729 pidversion=6448509 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36729 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  this read against the first read after the exec: the same pid and pidversion
  bytes waiting on the keeper's end after IMAGE's step: 39
== (g4) as (g3), but S shuts the end's write side after its answer, then IMAGE writes its line on descriptor 2 (SIGPIPE ignored, as the maker left it)
  keeper pid=36555 pidversion=6448272; maker pid=36735 pidversion=6448521; third pid=36736 pidversion=6448522
  the maker writes the request on its end: done
  the maker exec'd: it now runs <scratch>/bin/pair-image
  after the exec: LOCAL_PEERTOKEN pid=36735 pidversion=6448523 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36735 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  the keeper read 3 bytes: req
  the keeper wrote an 8-byte nonce on its end
  S reads the nonce on its copy and writes it back: done
  the keeper read the answer: the nonce, as sent
  after the answer: LOCAL_PEERTOKEN pid=36736 pidversion=6448522 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36736 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  S shuts the end's write side (shutdown SHUT_WR): done
  IMAGE writes a line on its descriptor 2: failed errno=32 (Broken pipe)
  after IMAGE's step: LOCAL_PEERTOKEN pid=36735 pidversion=6448523 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36735 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  this read against the first read after the exec: the same pid and pidversion
  bytes waiting on the keeper's end after IMAGE's step: 0
  the keeper's next read: end of file
== (g5) as (g3), but after S's answer IMAGE reads its descriptor 0 once, without waiting (nothing there)
  keeper pid=36555 pidversion=6448272; maker pid=36737 pidversion=6448524; third pid=36738 pidversion=6448525
  the maker writes the request on its end: done
  the maker exec'd: it now runs <scratch>/bin/pair-image
  after the exec: LOCAL_PEERTOKEN pid=36737 pidversion=6448526 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36737 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  the keeper read 3 bytes: req
  the keeper wrote an 8-byte nonce on its end
  S reads the nonce on its copy and writes it back: done
  the keeper read the answer: the nonce, as sent
  after the answer: LOCAL_PEERTOKEN pid=36738 pidversion=6448525 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36738 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  IMAGE reads its descriptor 0 once, not waiting: failed errno=35 (Resource temporarily unavailable)
  after IMAGE's step: LOCAL_PEERTOKEN pid=36737 pidversion=6448526 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36737 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  this read against the first read after the exec: the same pid and pidversion
  bytes waiting on the keeper's end after IMAGE's step: 0
== (h) S holds a copy and stays silent while the genuine image (IMAGE) talks: its own request, its answer to the nonce; then the keeper's reply
  keeper pid=36555 pidversion=6448272; maker pid=36739 pidversion=6448527; third pid=36740 pidversion=6448528
  the maker exec'd: it now runs <scratch>/bin/pair-image
  after the exec, before IMAGE writes: LOCAL_PEERTOKEN pid=36739 pidversion=6448529 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36739 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  IMAGE writes its request on descriptor 5: done
  after IMAGE's request: LOCAL_PEERTOKEN pid=36739 pidversion=6448529 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36739 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  the keeper read 3 bytes: req
  the keeper wrote an 8-byte nonce on its end
  IMAGE reads the nonce on descriptor 5 and writes it back: done
  the keeper read the answer: the nonce, as sent
  after IMAGE's answer: LOCAL_PEERTOKEN pid=36739 pidversion=6448529 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36739 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  this read against the first read after the exec: the same pid and pidversion
  the keeper wrote its 3-byte reply
  S reads the keeper's reply on its copy: done
  after S took the reply: LOCAL_PEERTOKEN pid=36740 pidversion=6448528 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36740 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
== (i) a nonce sent before the token names a pinned image: the maker (not exec'd) writes the request, answers the nonce, then execs PROGRAM
  keeper pid=36555 pidversion=6448272; maker pid=36741 pidversion=6448530; third pid=36742 pidversion=6448531
  the maker writes the request on its end: done
  the keeper read 3 bytes: req
  after the request, the maker not exec'd: LOCAL_PEERTOKEN pid=36741 pidversion=6448530 = the maker, as it was before any exec | LOCAL_PEERPID=36741 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  the keeper wrote an 8-byte nonce on its end
  the maker reads the nonce and writes it back: done
  the keeper read the answer: the nonce, as sent
  after the answer, the maker not exec'd: LOCAL_PEERTOKEN pid=36741 pidversion=6448530 = the maker, as it was before any exec | LOCAL_PEERPID=36741 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  the maker exec'd: it now runs PROGRAM
  after the maker's exec: LOCAL_PEERTOKEN pid=36741 pidversion=6448532 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36741 | Security: guest=0 valid=0 cdhash=bd5977d7fff8c336 (PROGRAM's file) hardened=yes
== (m) a keeper-made end, sent over the maker's pair once its token names IMAGE: who can be named on it
  keeper pid=36555 pidversion=6448272; maker pid=36743 pidversion=6448533; third pid=36744 pidversion=6448534
  the maker exec'd: it now runs <scratch>/bin/pair-image
  on the maker's pair, after the exec: LOCAL_PEERTOKEN pid=36743 pidversion=6448535 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36743 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
  the keeper made a pair and sent one end over its end of the maker's pair
  S takes that end on its copy of the maker's end and writes a request on it: done
  the keeper read 3 bytes: req
  on the keeper-made end, after S's request: LOCAL_PEERTOKEN pid=36744 pidversion=6448534 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36744 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  IMAGE writes a line on its descriptor 2 (the maker's end, not the keeper-made one): done
  on the keeper-made end, after that line: LOCAL_PEERTOKEN pid=36744 pidversion=6448534 = S, the maker's forked holder (silent until told) | LOCAL_PEERPID=36744 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
  S passes the keeper-made end to IMAGE over a socket IMAGE has as descriptor 6: done
  IMAGE takes a descriptor on descriptor 6 and reads it once, not waiting: done
  on the keeper-made end, after IMAGE took it and read once: LOCAL_PEERTOKEN pid=36743 pidversion=6448535 = the maker's pid, another pidversion (its image after the exec) | LOCAL_PEERPID=36743 | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
== (j) which acts of a holder move the token: a pair made here, its other end held by two forked holders; before each act holder 1 writes a byte (the token then names holder 1)
  keeper pid=36555 pidversion=6448272; holder 1 pid=36745 pidversion=6448536; holder 2 pid=36746 pidversion=6448537
  holder 2: a 1-byte write (done) -> the token names holder 2
  holder 2: a zero-length send (done) -> the token names holder 2
  holder 2: a read that doesn't wait, nothing there (EAGAIN) (failed errno=35 (Resource temporarily unavailable)) -> the token names holder 2
  holder 2: a peek that doesn't wait, nothing there (failed errno=35 (Resource temporarily unavailable)) -> the token names holder 2
  holder 2: poll (done) -> the token names holder 2
  holder 2: getsockopt SO_TYPE (done) -> the token names holder 1
  holder 2: setsockopt SO_RCVTIMEO (what the handover keeper's limitIO does) (done) -> the token names holder 1
  holder 2: getpeername (done) -> the token names holder 1
  holder 2: ioctl FIONREAD (done) -> the token names holder 1
  holder 2: fstat (done) -> the token names holder 1
  holder 2: dup, then close the copy (done) -> the token names holder 1
  holder 2: a peek with a byte there (done) -> the token names holder 2
  holder 2: a read with a byte there (done) -> the token names holder 2
  holder 2: a read that waits, entered, nothing there yet -> while it waits (asked for up to 1 s) the token names holder 2
  holder 2: that read, ended by a byte from the keeper (done) -> the token names holder 2
== (j) after the end's write side is shut (holder 1's shutdown SHUT_WR; SIGPIPE ignored)
  holder 1: shutdown SHUT_WR (done) -> the token names holder 1
  holder 2: a 1-byte write (EPIPE expected) (failed errno=32 (Broken pipe)) -> the token names holder 2
  holder 2: a zero-length send (failed errno=32 (Broken pipe)) -> the token names holder 2
  holder 1: a 1-byte write (failed errno=32 (Broken pipe)) -> the token names holder 1
  bytes waiting on the keeper's end (no byte expected): 0
== (j) after the end's read side is shut (holder 1's shutdown SHUT_RD)
  holder 1: shutdown SHUT_RD (done) -> the token names holder 1
  holder 2: a read that doesn't wait (done) -> the token names holder 2
  holder 2: a read that would wait (done, at once) -> the token names holder 2
== (k) the last to act has exited, another holder keeps the end open
  holder 1 wrote a byte -> the token names holder 1
  holder 1 exited and was reaped; holder 2 still holds the end
  after holder 1's exit: LOCAL_PEERTOKEN refused errno=22 (Invalid argument)
  poll: 1 revents=0x4
  after holder 2 writes: LOCAL_PEERTOKEN pid=36752 pidversion=6448543 = holder 2 | LOCAL_PEERPID=36752 | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
== (l) the maker closes its copy of the sent end and its connection at once, before the keeper's accept
  200 runs: the request read 138, end of file 62, nothing within 1 s 0, no descriptor in the hello 0
== (l) the maker closes them after the keeper's accept, before its recvmsg
  200 runs: the request read 186, end of file 14, nothing within 1 s 0, no descriptor in the hello 0
== (l) the maker closes them once the keeper holds the end (K-M1's makers, and the handover keeper's rule)
  200 runs: the request read 200, end of file 0, nothing within 1 s 0, no descriptor in the hello 0
== (n0) Mach: the probe's port registered for its task (mach_ports_register); a forked child looks its registered ports up and sends to the first
  the child's lookup: 0x0, 3 ports, the first isn't the probe's port name; its send: accepted by the kernel
  the probe's port, once the child exited: no message within 5 s (0x10004003)
== (n1) Mach: a live maker sends one message to the probe's port (its bootstrap special port, set at its fork); it doesn't exec
  keeper pid=36555 pidversion=6448272; maker pid=37661 pidversion=6449759
  the maker alive, not exec'd: the message "maker", its trailer's token pid=37661 pidversion=6449759 = the maker, as it was before any exec | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
== (n2) Mach: the maker sends, then execs PROGRAM; the message read only after the exec
  keeper pid=36555 pidversion=6448272; maker pid=37662 pidversion=6449760
  the maker exec'd: it now runs PROGRAM
  read after the maker's exec: the message "maker", its trailer's token pid=37662 pidversion=6449760 = the maker, as it was before any exec | Security: guest=-67065
== (n3) Mach: the maker sends, then exits; the message read only after its exit
  keeper pid=36555 pidversion=6448272; maker pid=37663 pidversion=6449762
  the maker exited and was reaped
  read after the maker's exit: the message "maker", its trailer's token pid=37663 pidversion=6449762 = the maker, as it was before any exec | Security: guest=100003
== (n4) Mach: the maker's forked child sends; the maker execs PROGRAM; read after the exec
  keeper pid=36555 pidversion=6448272; maker pid=37664 pidversion=6449763; forked child pid=37665 pidversion=6449764
  the maker exec'd: it now runs PROGRAM
  read after the maker's exec: the message "child", its trailer's token pid=37665 pidversion=6449764 = the maker's forked child | Security: guest=0 valid=0 cdhash=25c17cee63cbb36a (this probe's file) hardened=yes
== (n5) Mach: the maker execs IMAGE, whose own code sends to its bootstrap special port (the port crosses the exec)
  keeper pid=36555 pidversion=6448272; maker pid=37666 pidversion=6449766
  the maker exec'd: it now runs <scratch>/bin/pair-image
  read once IMAGE ran: the message "image", its trailer's token pid=37666 pidversion=6449767 = the maker's pid, another pidversion (its image after the exec) | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
== (n6) Mach: IMAGE started by posix_spawn from the probe (as a host starts its children), the probe's port named as its bootstrap special port
  keeper pid=36555 pidversion=6448272; spawned image pid=37667 pidversion=6449769
  read once the spawned image ran: the message "image", its trailer's token pid=37667 pidversion=6449769 = the image the probe spawned | Security: guest=0 valid=0 cdhash=712188d35768e0a6 (IMAGE's file) hardened=yes
== (o) SCM_CREDS: a message on a pair carrying an SCM_CREDS control message of 96 zero bytes (this SDK names SCM_CREDS but defines no struct cmsgcred)
  sendmsg with SCM_CREDS: refused errno=22 (Invalid argument)
```

**What each case says** (each line of the output above is one read; "names X" is `LOCAL_PEERTOKEN` read afresh):

- **(g1) the whole write-then-exec, a silent image.** The maker writes the request and execs PROGRAM: at the receipt
  the token names the maker as it was; after the exec, after the keeper reads the request, after its reply and after a
  second round that nothing answers, it names PROGRAM (accepted by Security, hardened), every read the same pid and
  pidversion as the first after the exec; no byte trails the request. A keeper reading the token at any of these points
  serves the request. A second round goes unanswered by a silent image (0 of 8 bytes within 1 s).
- **(g2) a nonce sent once the token names the image, answered by a silent copy-holder.** S reads the nonce on its copy
  and writes it back; the keeper reads the nonce as sent, and the token then names **S** (this probe's code): a
  copy-holder can answer, and is named for it.
- **(g3) the same, then the image writes a line on its descriptor 2** (the maker's end): the token names the image
  again, the same pid and pidversion as the first read; the line's 39 bytes trail the answer.
- **(g4) the same, but S shuts the end's write side after its answer, then the image's line fails (`EPIPE`, SIGPIPE
  ignored as the maker left it): the token names the image, the same pid and pidversion as the first read, no byte
  trails the answer, and the keeper's next read is the end of file.** A request and a nonce's answer written by S, then
  the end of file, with every token read naming the genuine image: what an honest exchange looks like, made by S.
- **(g5) the same, but the image reads its descriptor 0 once without waiting** (`EAGAIN`, nothing there): the token
  names the image, no byte trails. A failed read stamps as a failed write does.
- **(h) a silent holder while the genuine image talks.** The image writes its own request and answers the nonce: every
  read names the image; S, silent, is named by none. The keeper's reply is then read by S, and only then does the token
  name S. A silent copy is invisible to every read, and can take the answer.
- **(i) a nonce sent before the token names a pinned image.** The maker, not exec'd, writes the request and answers the
  nonce (both reads name the maker as it was, this probe's code), then execs PROGRAM: the token then names PROGRAM. A
  keeper that judges only after the answer serves it; one that asks the token before it sends the nonce refuses there.
- **(m) a keeper-made end, sent over the maker's pair once its token names the image.** S takes it on its copy of the
  maker's end and writes a request on it: the token of the keeper's other end names **S**. A line the image writes on
  its descriptor 2 (the maker's end) doesn't move it. S passes the end to the image over a socket the image holds as
  descriptor 6; the image takes it and reads it once without waiting: the token then names **the image**. An end made
  after the exec can't be an inherited descriptor, but it reaches the image's name through any code of the image that
  takes descriptors from a socket it didn't make and touches them.
- **(j) which acts of a holder move the token.** They move it: a write, a zero-length send, a read or a peek with a
  byte there, a read or a peek that doesn't wait with nothing there (`EAGAIN`), `poll`, a read that waits (named while
  it waits, before any byte comes), a write or a zero-length send that fails with `EPIPE` once the write side is shut,
  a read that returns the end of file after `shutdown(SHUT_RD)`. They don't: `getsockopt`, `setsockopt` (the handover
  keeper's `limitIO`), `getpeername`, `ioctl(FIONREAD)`, `fstat`, `dup` and closing the copy, `shutdown` itself. So any
  send, receive or `poll` by any holder, whether it moves a byte or fails, makes that holder the one named. (A send
  refused with `EAGAIN` on a full buffer: not measured, the trial stalled in a first run and was dropped.)
- **(k) the last to act has exited, another holder keeps the end open:** the token read is refused (`EINVAL`); `poll`
  shows only `POLLOUT`. Once the other holder acts, it is named.
- **(l) the end of file a first version of K-M1 saw.** The maker writes a request on its end, sends the other with the
  hello, and closes its copy of the sent end and its connection: at once, before the keeper's `accept`, the keeper read
  the end of file in place of the request in 62 of 200 runs (127 of 200 in a first run); after the `accept` and before
  its `recvmsg`, in 14 of 200 (50 in a first run); once the keeper holds the end, in none of 200. A socket in flight
  whose sender closed its copy loses what was written on its peer, as the handover keeper's comment says of its
  re-check's flake (XNU's collection of descriptors in flight is the candidate, not read). A liveness rule, not a
  security one: the sender keeps its copy until the receiver says it holds it.
- **(n) a Mach message's audit trailer.** (n0) The registered ports (`mach_ports_register`) don't reach a forked child
  on this Mac: its lookup gives three ports, the first not the probe's, and the probe's port receives nothing. Through
  the bootstrap special port: (n1) a live maker's message is named the maker, accepted; **(n2) a message sent, then the
  sender's exec, read after the exec: the trailer names the maker as it was when it sent (the old pidversion), and
  Security refuses it (`-67065`)**; (n3) a message whose sender exited before it was read: refused (`100003`); (n4) a
  message from the maker's forked child, read after the maker's exec: named the child, as itself; (n5) the image the
  maker exec'd sends with its own code (the special port crosses the exec): named the image at the maker's pid with its
  new pidversion, accepted, IMAGE's file, hardened; (n6) an image started by `posix_spawn` with the probe's port named
  as its bootstrap special port: named and accepted. The trailer's token is the sender's as it was at the send, fixed
  in the message: no later act of anyone moves it.
- **(o) `SCM_CREDS`:** refused (`EINVAL`) on a pair; this SDK names it and defines no `struct cmsgcred`. A Unix socket
  on this Mac carries no sender's credentials per message.

**For the keeper's design.** (g4) and (g5) settle what (b) and (c) left open: a token read is "the process that last
sent, received or polled on the other end, as it runs now", and a failed act stamps as a successful one does, leaving
no byte. So whatever a keeper asks of a pair (the token at the receipt, after the request, after its own reply, after
a nonce's answer, the same pid and pidversion at each, the end of file after), a copy-holder can write every byte and
the genuine image, started with the end as one of its descriptors, can be made the last to act on it with one failed
write or read, with nothing in the stream to show it. A keeper-made end (m) narrows this to an image that takes
descriptors from sockets it didn't make; it doesn't close it. A Mach message's trailer (n2, n4, n5, n6) is fixed at
the send. The design ([the keeper's design](../superpowers/specs/2026-11-27-v2-mac-keeper-design.md), "The proof after
K-M1") takes it.

## The keyboard session of 2026-11-26

The user ran part A of [the runbook](v2-mac-keyboard-session.md), guided step by step, from 19:29 to 19:38 (local
time; the records' `at=` are UTC, an hour behind). The records are copied unchanged, byte for byte, into
[measurements/2026-11-26](measurements/2026-11-26/): one file per script as the scripts saved it, and
`first-runs-19-29.txt`, the earlier gathered file of a first run of ESC-3 and AG-1 two minutes before the ones kept
(the same results). Each fact below is the record's; "by inference" marks what the record doesn't hold.

**Where from: a VibeSwitcher shell session (a shell card), not Terminal.app.** Every record's first line says `run from:
a shell session of the app's host (a shell card)`; the caller blocks read `VIBESWITCHER_SESSION=set CLAUDECODE=unset`,
a pty of the app's (`ttys005`, `ttys009`), `coalition=read resource=1841 jetsam=1842` (the coalition M4 read for an
agent's session under the same app) and `responsible=` each process itself. That matters for the comparisons ESC-1 and
ESC-2 make with "yours" (below); not for the LA-* steps, whose asks run in a job of their own (`la: … ppid=1`, or the job's own `sh` for LA-6), nor for
ESC-3 and AG-1.

**Done:** ESC-3, AG-1 (each twice), LA-1, LA-2, LA-3, LA-6, LA-7, ESC-1, ESC-2. **Not done:** ANC-1 (it refuses a shell
card: it needs Terminal.app), LA-5 and ANC-2 (Remote Login), LA-4 (an external display), the `sudo` trial T1 to T3.

**What the person saw.** The scripts' output was long and unclear to the user, so the one-line answers are thin:
LA-1 nothing typed; LA-2 `yes both`; LA-3 `dialog ok`; LA-6 `after it`; LA-7 `took more than 10sec and i cancelled`;
ESC-1 nothing typed; ESC-2 `nothing poped` (followed by an arrow key's escape sequence, kept as typed). **No record
holds the dialog's words**: its title, whether the reason ("MEASURE-1 …") reads after the program's name, what the
buttons say. Nothing here supplies them. A second look needs the words themselves: a screenshot of the dialog, or its
text typed into the record's line (the owed steps below).

### K-LA-1. The dialog from a LaunchAgent, approved with Touch ID

*Meant to answer* (step 4, item 2; the tasks' `8f8b7e20` row): does LocalAuthentication's dialog appear for a process
launchd started in `gui/<uid>`, the server's place, and does an approval come back as approved? And how is it worded
(the tasks' "Before approvalMeasured flips", item 2: does the request's word read first after the program's name)?

*The record* (`la-agent.txt`): `la: pid=48951 ppid=1` (the job's own process); `availability=available`, both policies
`true`, `biometryType=touchID`; `asking … timeout=60s reason=MEASURE-1 approve setting x to y`;
`outcome=approved after=2.7s`. Seen: nothing typed.

*Answer.* **Yes**: a LaunchAgent's process in the login session raises the dialog and an approval comes back as
`approved` (the node's own `Platform.Approval` code, compiled unchanged into `la`). Sure: high for the outcome; the
route (Touch ID) is the runbook's instruction, and 2.7 s fits a touch. **The wording: open** (nothing recorded).

### K-LA-2. Cancel, and the 60 s limit

*Meant to answer* (item 2; the tasks' `1a6c4688` row): does Cancel read as a decline with nothing approved, does a dialog
left alone end as a decline at the server's 60 s, and does the command line's wait outlast it?

*The record* (`la-cancel.txt`): first ask `outcome=declined("cancelled at the Mac") after=1.6s`; second ask (the job
kick-started again) `outcome=declined("not answered within 60 s") after=60.0s`. Seen: `yes both` (to "did Cancel close
the first dialog, and did the second go away by itself (after about 60 s)?").

*Answer.* **Both are declines, as the server reads them**: Cancel at once, and the untouched dialog at exactly the 60 s
`Platform.Approval` sets (the server's `ApprovalVoice.System(timeout: 60)`), gone from the screen then (the person's
"yes both"). The command line waits `max(timeout, 120)` s (M14), so it always hears the decline. Sure: high.

### K-LA-3. The password route

*Meant to answer* (step 4: "with no Touch ID"): approved through "Use Password…" and the login password typed into the
system's dialog, a stand-in for a Mac with no finger enrolled.

*The record* (`la-password.txt`): `outcome=approved after=3.8s`; `biometryType=touchID`. Seen: `dialog ok`.

*Answer.* **Approved**; the record doesn't say by which route. That it was the password rests on the runbook's
instruction (choose Use Password…, type the password into the dialog) and the person's "dialog ok". Sure: high that the
dialog approves from a LaunchAgent, medium that this run went through the password. A Mac with no finger enrolled (where
the policy without biometrics is the only one) is not measured; nobody un-enrolls a finger for this.

### K-LA-6. Two asks 3 s apart

*Meant to answer* (the tasks' `8f8b7e20` row): what the system does with a second LocalAuthentication dialog while one
is open (queued, replaced, beside it, or refused). It matters because a session can raise dialogs of its own (M9) while
the server's is up; the server's own are one at a time already (`Requests.approvalJudgment`).

*The record* (`la-second.txt`): FIRST asked `18:37:03Z`, `declined("cancelled at the Mac") after=1.0s` (`18:37:04Z`);
SECOND asked `18:37:06Z`, `declined("cancelled at the Mac") after=1.0s`. Seen: `after it`.

*Answer.* **Still open.** The first dialog was cancelled a second after it appeared, two seconds before the second was
asked, so the two were never on screen together; "after it" says the second came after the first had gone. The record
shows that two asks from one job a few seconds apart each get a dialog and each cancel reads as a decline; nothing
about queueing. Closed by the same script with the first dialog left alone until the second comes (owed step 3).

### K-LA-7. An Escape posted while the dialog is in front

*Meant to answer* (item 3; the design's "What it can't do": synthetic events need Accessibility consent): can a process
of the user's end or answer the dialog with a synthetic key?

*The record* (`la-keys.txt`): the helper's first line is its trust print, run bare by the script before the ask (not a
failed post): `accessibility_trusted=false frontmost=dev.vibeswitcher.VibeSwitcher (VibeSwitcher)`. The ask
(`timeout=30s`) at `18:37:33Z`; the helper again, `accessibility_trusted=false
frontmost=com.apple.LocalAuthentication.UIAgent (coreautha)`, `keys: posted Escape at=2026-11-26T18:37:36Z` (one key
down and up at the HID tap); then `outcome=declined("cancelled at the Mac") after=17.8s` at `18:37:50Z`, 14 s after the
Escape. Seen: `took more than 10sec and i cancelled`.

*Answer.* **For a process not trusted for Accessibility: no.** With the dialog frontmost (drawn by `coreautha`, bundle
`com.apple.LocalAuthentication.UIAgent`), its Escape didn't end the dialog; the person's Cancel did, 14 s later. Whether
macOS dropped the key at the post or the dialog ignored it, the record can't tell: there is no positive control (no
Escape pressed by hand on this dialog; owed step 1 adds it), and it was one key from one untrusted process. Sure: high
that this key didn't end it; not a measurement that synthetic keys can't. **Not
shown:** a process that is trusted (or whose responsible process is: the shell an escape opens in Terminal is
attributed to Terminal, K-ESC-1, so a Terminal holding Accessibility would lend it). Even then a key can only cancel
or type: approving needs the enrolled finger or the login password, which no key gives a session that doesn't know it.
The helper ran from a shell card and was untrusted, as the app's sessions' own processes are (by inference: under the
app's session host each process is its own responsible one, M5, so none borrows the app's grants).

### K-ESC-3. A job a session loads itself (`launchctl bootstrap`)

*Meant to answer* (step 4; M4's open question): what a session's own LaunchAgent's process looks like: its parent,
terminal, environment, coalition and responsible process.

*The record* (`escape-launchctl.txt`, and the first run in `first-runs-19-29.txt`): the caller (shell card):
`coalition … resource=1841`, `VIBESWITCHER_SESSION=set`, `tty=ttys009`. The job's process: `ppid=1 pgid=48692 sid=1`,
`dev_tty=none`, `tty=none`, `VIBESWITCHER_SESSION=unset`, `environment_entries=11` (the caller's 29),
`coalition=read resource=242021` (first run: 241969, its caller 1841 too), `responsible=48692` (itself).

*Answer.* **A self-loaded job leaves every trace of the session**: launchd its parent, no terminal, no
`VIBESWITCHER_SESSION`, a **new coalition** of its own (not the caller's), its own responsible process. Ancestry, the
terminal line, the environment line and a coalition line all pass it; what remains is the code check (it must run the
installed command line, which a job can) and the dialog. Sure: high (two runs, the same).

### K-AG-1. What `launchctl bootout` ends

*Meant to answer* (step 5; `NodeAgent`'s "Needs a real Mac"): `launchctl print`'s lines as `NodeAgent.printed` parses
them, and which of the job's process, a child in its group and a child that called `setsid` outlive `bootout`.

*The record* (`agent-bootout.txt`, and the first run): the job's lines one tab in (`path`, `type = LaunchAgent`, `state =
running`, `program = /bin/sh`, `domain = gui/501 [100020]`, `pid = 48782`), parsed `program=/bin/sh pid=48782`; all three
processes `coalition … resource=242023` (first run: all three 241971); after `bootout`, `main (48782): ended`, `group
(48789): ended`, `setsid (48788): still running` (first run the same). The script checks the moment the job's process
has ended (within 5 s) and then ends the survivor itself.

*Answer.* **`bootout` ends the job's process group and nothing outside it.** It agrees with the agent's own measurement
in the spec ("What `bootout` ends", step 5: a `setsid` child ran on after `bootout` returned). For `stop`: every
session (a session of its own, `PTYSpawn`), the server child (a group of its own) and anything a session detached
survive the `bootout`; ending them is the node's, as the spec's `stop` does (the server's stop, the snapshot of the
host's children, survivors found by the session ids their environments carry). **New here, while the job ran:** the
`setsid` child was in the job's coalition (read before the `bootout`), so a LaunchAgent job's coalition holds its
`setsid` descendants: the coalition line's evidence (the spec's row 3). **Not read after the `bootout`:** the record's
after-lines are `kill -0` only, so whether the survivor is still in that coalition, and findable by it, is not
measured. A sweep by coalition for `stop` (to find a detached process that dropped `VIBESWITCHER_SESSION`, which
`stop`'s search by environment misses) would need that measured first: an idea for the step 5 review, not decided.
`print`'s lines: as M11. Sure: high for what ended and what ran on (two runs, and the agent's).

### K-ESC-1. `open -a Terminal x.command` from a detached process

*Meant to answer* (step 4; the design: "a Terminal window so opened is … indistinguishable by process facts from one the
user opened"): the escaped shell's chain, terminal, environment, coalition and responsible process, against the
caller's.

*The record* (`escape-open-terminal.txt`): the caller (shell card) `resource=1841`, `VIBESWITCHER_SESSION=set`,
`responsible=81177` (itself). The escaped shell's `facts`: `tty=ttys014`, `dev_tty=opens`, `VIBESWITCHER_SESSION=unset`
(`environment_entries=31`), `coalition … resource=109496`, `responsible=44707`. Its chain: `/bin/bash` (81860) →
`/bin/zsh` (81846) → `/usr/bin/login` (81841, uid 0: `bsdinfo=refused`, `procargs=refused`, `shortbsdinfo=read`,
`responsible=-1`) → Terminal (44707, `ppid=1`, started long before: the user's running Terminal) → launchd. Every link
from the shell to Terminal itself `resource=109496`; bash and zsh `responsible=44707`. The Apple binaries'
environments read empty (`environment_entries=0`), as M2. Seen: nothing typed.

*Answer.* The escape lands **in Terminal's own coalition** (109496, the coalition of the Terminal process that hosts
the user's windows), with a fresh terminal of Terminal's, without the session's variable, and attributed to Terminal.
**By inference**, every shell in the user's own Terminal windows is in 109496 too (Terminal 44707 is in it, and a
process keeps its coalition through fork and exec, M4), so **no coalition tells a session's escape into Terminal from
the user's own Terminal**: the design's expectation, now measured for the escape's side. What the coalition does tell:
both are apart from the caller's 1841 (the app's: its shell cards and agent sessions), so a session that doesn't go
through launchd stays in its host's coalition. Item 11: the chain through `login` reads whole by the fallback, as M8.
Sure: high for the escape's facts.

*From a shell card instead of Terminal.app.* The escape's own block doesn't depend on where the caller ran (Terminal
starts the shell through `login` either way, the caller's place no part of the chain). What changes is the "yours" block: it is a shell card's (1841, its own
responsible, the variable set), not a Terminal shell's, so the record doesn't put the user's own Terminal shell beside
the escape; the user's Terminal shell's coalition and responsible process are the inference above. ANC-1, run in
Terminal.app, reads them directly (owed step 2).

### K-ESC-2. `osascript … do script` from a detached process

*Meant to answer* (step 4): the same through AppleScript, and whether an Automation consent stops it.

*The record* (`escape-osascript.txt`): the caller as in ESC-1. The escaped shell's `facts` (83033): `tty=ttys014`,
`VIBESWITCHER_SESSION=unset`, `resource=109496`, **`responsible=83033` (itself)**; bash (83026) and zsh (83011) each
their own responsible process; `login` (83010) `-1`; Terminal 44707 itself; every link `resource=109496`. Seen:
`nothing poped`, to "any consent dialog (its words and your answer), and did a new Terminal window open?".

*Answer.* As ESC-1: Terminal's coalition, a fresh terminal, no variable. The record proves the escape ran (its chain was
written from inside the new window); the person's answer most likely means no consent dialog appeared, but it answers a
two-part question, so read it as "no consent dialog reported". Whether a grant from before made it silent isn't
recorded (System Settings › Privacy & Security › Automation would show it). **The responsible process differs from
ESC-1's** (each process its own here, Terminal there), unexplained by the record: the responsible pid is no stable
fact to judge by. Sure: high for the facts; the consent's absence as reported.

### Row 3 from these records

Settled in the spec ([The user's voice on the Mac](../superpowers/specs/2026-11-19-v2-node-on-macos.md#the-users-voice-on-the-mac),
"The rule's lines, settled from the measurements"): the **coalition line added** (the peer isn't in the node's own
coalition), the **peer's environment line added** as an early refusal (the lead's call, reversible; not a boundary),
**no responsible-process line**, and the `approval` mode's guard rails, each with the record that decides it and the
ones left open with the step that closes them. Settled is not built: `ApprovalVoice` has neither line yet, and
`NodeSystem.approvalMeasured` stays false until the independent review and the user's go-ahead (row 15).

### The keyboard steps still owed, by value

Each from the clone, in **Terminal.app** unless said (the runbook's `cd` line first):

```
cd /Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook
```

A run again replaces its record in `.build/mac-measure-records/`; today's are kept in
[measurements/2026-11-26](measurements/2026-11-26/).

1. **The dialog's words** (about 1 minute). Closes the switch-on's own precondition (the tasks' "Before approvalMeasured
   flips", item 2: the request's word reads first in the dialog as drawn); the attribution the whole rule leans on.

   ```
   bash scripts/mac-measure/la-agent.sh
   ```

   While the dialog is up, press ⌘⇧4, then Space, then click the dialog (a picture on the Desktop; if the system won't
   capture it, copy its words). Then press the **Escape key** on the keyboard (not Touch ID, not Cancel, though the
   script's own text says to touch Touch ID; it records any outcome): the record's
   `outcome=` then shows whether a real Escape ends this dialog, the positive control K-LA-7 lacks (`declined(…)`
   within a second: it does; still open: Cancel it). At the record's question type the dialog's words exactly, title
   and line, whether Escape closed it, and where the picture is.

2. **ANC-1: your own Terminal's facts** (under 30 s, nothing on screen; it refuses a shell card). Closes: the user's own
   Terminal shell's coalition (the coalition line refuses no legitimate caller: expected 109496, not the node's) and its
   responsible process (ESC-1's comparison, made directly), whether anything but the variable tells an app session's
   descendants from the user's Terminal (the spec's row 3, open item), and item 11's Terminal chain (row 6).

   ```
   bash scripts/mac-measure/ancestry-terminal.sh
   ```

3. **LA-6 again, the first dialog left up** (about 1 minute). Closes what a second dialog does while one is open: what
   the user sees when a session's own dialog (M9) comes while the server's is up.

   ```
   bash scripts/mac-measure/la-second.sh
   ```

   Leave "MEASURE-6 FIRST" alone until "MEASURE-6 SECOND" has appeared (3 s), note whether the second waits, replaces
   the first or shows beside it, then Cancel each. At the record's question say which.

4. **The `sudo` trial of the anchor's record** (about 3 minutes, two passwords; the runbook's T1 to T3, what each
   prints there). Closes the real root-owned record on this Mac (row 4's anchor; the tasks' item 3, "the real record (a
   `sudo` trial)"). Write the trial record (`sudo` asks the password in this Terminal):

   ```
   /usr/bin/env -i /bin/bash -p /Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook/scripts/node-pins-mac.sh --record "/Library/Application Support/VibeSwitcher-trial/node-501.pins" --build 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333 4444444444444444444444444444444444444444
   ```

   Record its owners, modes and text, and a write and a create as you, both refused:

   ```
   /bin/mkdir -p .build/mac-measure-records; { /bin/ls -lde / /Library "/Library/Application Support" "/Library/Application Support/VibeSwitcher-trial" "/Library/Application Support/VibeSwitcher-trial/node-501.pins"; /bin/cat "/Library/Application Support/VibeSwitcher-trial/node-501.pins"; echo x >> "/Library/Application Support/VibeSwitcher-trial/node-501.pins" && echo "WRITE ALLOWED"; /usr/bin/touch "/Library/Application Support/VibeSwitcher-trial/x" && echo "CREATE ALLOWED"; } > .build/mac-measure-records/sudo-trial.txt 2>&1; cat .build/mac-measure-records/sudo-trial.txt
   ```

   Undo it, the file then its folder:

   ```
   sudo /bin/rm "/Library/Application Support/VibeSwitcher-trial/node-501.pins"
   ```

   ```
   sudo /bin/rmdir "/Library/Application Support/VibeSwitcher-trial"
   ```

5. **LA-5 and ANC-2 over ssh** (about 6 minutes; the runbook's steps 11 to 15). Closes: what a request made over ssh
   does (`.notInteractive` read as unavailable, nothing on the Mac's screen) and `managername` (`Background`, which
   `LimitLoadToSessionType Aqua` keeps the node out of). Turn Remote Login on (System Settings › General › Sharing ›
   Remote Login), check it:

   ```
   /usr/bin/nc -z -G 2 localhost 22 && echo "Remote Login: on" || echo "Remote Login: off"
   ```

   Log in (first time: type `yes`; then your login password at ssh's own `Password:` prompt):

   ```
   ssh localhost
   ```

   In that login, the clone's `cd` line above, then:

   ```
   bash scripts/mac-measure/la-ssh.sh
   ```

   ```
   bash scripts/mac-measure/ancestry-ssh.sh
   ```

   Then leave the login, turn Remote Login off in the same place, and check with the `nc` line that it says `off`:

   ```
   exit
   ```

6. **LA-4 with the lid closed** (about 3 minutes; only with an external display and keyboard; the runbook's step 16).
   Closes which route the dialog offers in clamshell; worth it only if the user works with the lid closed. In a
   Terminal window on the external display, the `cd` line above, then (it asks you to close the lid first; approve the
   dialog with whatever it offers, a password into the dialog only):

   ```
   bash scripts/mac-measure/la-lid-closed.sh
   ```

7. **One word, no command: which route LA-3 took** (password or finger). Turns K-LA-3's "medium" into a fact.

Not worth the user's time now: ESC-1 and ESC-2 again from Terminal.app (step 2 plus today's records make the same
comparison); AG-1 again (two runs and the agent's agree); LA-7 with a process trusted for Accessibility (it needs a
grant given and taken back, and a key can only cancel or type, not approve). After a node runs (row 15's review, not
before): one `vibeswitcher set` and one `answer` from Terminal, from a Claude Code Bash tool, and from ESC-1/2 started
by a session (the tasks' `1a6c4688` row).

## The scripts for the user

Each in [scripts/mac-measure](../../scripts/mac-measure), one measurement each, run by the user in Terminal (or an ssh
login where said). Each prints what will appear before it happens and waits for Return; refuses from an agent's
session or without a terminal; loads only a job labelled `dev.vibeswitcher.measure.<what>.<pid>` from a property list in
its own `/tmp/mac-measure.*` folder (never `~/Library/LaunchAgents`), boots it out when it ends (Ctrl-C too; a job
that asks only once its ask has ended, never killing it mid-dialog), and prints a record (the account's name and home
taken out), saved in the checkout's `.build/mac-measure-records/`. **The user's session, in order, with every command:
[the keyboard session's runbook](v2-mac-keyboard-session.md).** They run in Terminal.app or in a shell card
the lead files (the app's shell session, which carries `VIBESWITCHER_SESSION` and a pty): the guard refuses an agent's
own process (`CLAUDECODE`, `CODEX_SANDBOX`) and a run without a terminal, and the Return prompt is the person's. ANC-1
alone wants Terminal.app (it refuses a shell card); ESC-1 and ESC-2 compare with "your own" facts where they ran, so
Terminal.app gives the comparison the design asks for. A job's property list carries
`MEASURE_ASK=yes` (`la ask` refuses without it; a job inherits nothing from the shell), and `la` writes line by line. `--dry-run` builds the probes, writes and lints
the property list, and stops before anything is shown or loaded: all thirteen were dry-run from the agent's session.
What runs after the `bootstrap` was run without launchd: AG-1's job body (its three pid files, the `setsid` child in a
group of its own), LA-6's body without `MEASURE_ASK` (two refusals), a written `.command` under `detach` (its chain
recorded), a written job's property list (`EnvironmentVariables` `MEASURE_ASK=yes`, by `plutil -p`), and `keys escape`
with the dialog not in front (posts nothing, exit 3). The real run of three was checked to refuse from the agent's
process (`STOPPED: this runs from an agent's process …`, exit 1) and without a terminal (`STOPPED: no terminal on
stdin and stdout`, exit 1).

| Id | Command (in Terminal.app or a shell card, from the clone) | Look for |
| --- | --- | --- |
| LA-1 | `bash scripts/mac-measure/la-agent.sh` | the dialog appears from a LaunchAgent; its exact words: does "MEASURE-1 …" read first, after the program's name "la"? Touch ID → `outcome=approved` |
| LA-2 | `bash scripts/mac-measure/la-cancel.sh` | Cancel → `outcome=declined("cancelled at the Mac")`; left alone → gone by itself at 60 s, `declined("not answered within 60 s")` |
| LA-3 | `bash scripts/mac-measure/la-password.sh` | "Use Password…" offered; the login password in the system dialog → `approved`. A stand-in for "no Touch ID enrolled" (nobody un-enrolls a finger for this) |
| LA-4 | `bash scripts/mac-measure/la-lid-closed.sh` | with an external display and the lid shut: `la can`'s biometry, then which route the dialog offers |
| LA-5 | `bash scripts/mac-measure/la-ssh.sh` (from `ssh localhost`) | `la can` over ssh, the ask's outcome (expected `.notInteractive`, unavailable), and whether anything appeared on the Mac's screen. Needs Remote Login on. It asks from the ssh login's own process; the node's server stays in `Aqua`, so a request a command line sends over ssh would still raise the server's dialog on the Mac's screen (for the rule's review) |
| LA-6 | `bash scripts/mac-measure/la-second.sh` | a second dialog 3 s after the first: queued, replaced, or refused |
| LA-7 | `bash scripts/mac-measure/la-keys.sh` | `accessibility_trusted=`; "keys: posted Escape at=T" then `outcome=declined(…)` at T plus a second or two, untouched, means synthetic keys reach the dialog; it posts only while the dialog's process is frontmost; the dialog's bundle ids in the script are guesses (`com.apple.coreautha` and three more), so the first run may say "posted nothing", naming the frontmost bundle id: add it to `DIALOGS` and run again. Decline any "control this computer" request |
| ESC-1 | `bash scripts/mac-measure/escape-open-terminal.sh` | a Terminal window opened by a detached process: its shell's chain, terminal, coalition and responsible pid against yours |
| ESC-2 | `bash scripts/mac-measure/escape-osascript.sh` | the same through `osascript … do script`, and any Automation consent (its words) |
| ESC-3 | `bash scripts/mac-measure/escape-launchctl.sh` | a job of its own in `gui/<uid>`: `ppid=1`, no terminal, its coalition and responsible pid |
| AG-1 | `bash scripts/mac-measure/agent-bootout.sh` | `launchctl print`'s `pid`/`program` as `NodeAgent.printed` parses them; which of the job's process, a child in its group and a `setsid` child outlive `bootout` |
| ANC-1 | `bash scripts/mac-measure/ancestry-terminal.sh` | every ancestor read (`shortbsdinfo=read` or `kern_proc_pid=read`), `login` with `bsdinfo=refused` |
| ANC-2 | `bash scripts/mac-measure/ancestry-ssh.sh` (from `ssh localhost`) | the same through `sshd-session`; `managername` (`Background`, so `LimitLoadToSessionType Aqua` keeps the node out). Needs Remote Login on |

## `web_acts: trust` under the Mac's rule

The user wants to authorize once rather than per command. **Decided since (2026-11-25, the user's answer 541E258F):**
one Touch ID allows the "page acts for you" mode, opens the page and confirms it, then the page acts with no prompt for
up to 12 hours on loopback (a design change with a security review), and with device keys (2026-11-26, the device-keys
design's review, I2) the Mac desktop's daily unlock is a browser passkey (still one Touch ID), the server's own Touch
ID dialog kept for the first enrolment and for guarded changes. The spec's "The user's voice on the Mac" records it.
What follows is the code as it was read at `b9df9949`, before that change:

- **Today on the Mac: unreachable.** `ActingPages` is given the host link's `vaultV2` (`NodeLive.swift` 84), and the
  host answers it only as a Mac node host (`HostServer.swift` 174: `isCheckedMacNode && serverChild != nil && vault`),
  which is never (`HostImages.isCheckedMacNode = false`, `HostImages.swift` 239); `set web_acts` then refuses ("This
  node's host keeps no record of the user's actions: no page acts here.", `ActingPages.swift` 134). And no user's node
  starts on the Mac at all (`NodeSystem.macUnbuilt`).
- **Once items 10 and 13 are done and `approvalMeasured` is on: three dialogs, then none for up to 12 hours.** Each of
  `set web_acts trust` (`KindSpec.swift` 269), `web.open` (216) and `web.confirm` (223) is a state change, so each is
  its own dialog under `approvalJudgment` (`Requests.swift` 362; one at a time, `ApprovalRequests.swift` 68).
  `vibeswitcher web` sends `web.open` and then, once the page shows its phrase, `web.confirm`, each with its own action
  id and dialog (`Web.swift` 44, 57, 112, 114). The level raised is kept in the vault (`LeadVaultV2.PageActs`); a
  pairing lives 12 hours at most (`ActingPages.life`, `ActingPages.swift` 28). So: one dialog to set `trust` (once while
  the vault keeps it), then **two per pairing** (`web` opens and confirms). Not one.
- **Then no dialog per act.** A page's request goes `pageVoiced` → `pageVoice` (`NoPageVoice` at `trust`,
  `PageRequests.swift` 82) → `voiced(now, from: NodeLive.webPeer, …)` (`PageRequests.swift` 92), never through
  `handle`'s `approvalVoice` (`Requests.swift` 362). So under the Mac's rule an acting page at `trust` acts as the user
  with no Touch ID for up to 12 hours, as on Linux, by design ("Trust risks this: whatever holds the page's two secrets
  while it is open acts as you, a team's own session included", `NodeSettings.swift` 103). The review that turns on
  `approvalMeasured` should say so explicitly: on the Mac it is the one path to the user's voice with no dialog.
- **And item 9 first.** The Mac's server binds the web port itself (`WebBind.forServer` gives `direct` on a stream
  connector, `WebBind.swift` 33-35), and the "keep `web` refused, or behind an opt-in that says the port can be
  squatted" of item 9 isn't built (as read at `b9df9949`; since, item 9 is built and reviewed: the host holds the web port,
  row 8, corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26): once a Mac node starts, `web` would come up squattable between one server and the
  next. An acting page at `trust` on a squatted port is the worst case of item 9. Item 9 (or `web` refused on the Mac)
  belongs before any Mac `start`.
- **One dialog for the lot** would need a change: e.g. `vibeswitcher web --trust` asking one dialog whose card names
  all three (raise the level, open, confirm the phrase), the server holding the open and the confirm under that one
  approval. Not built; the user chose it on 2026-11-25 (above), the design change and its security review owed.

## What stands between this Mac and `vibeswitcher start`

In the design's order. "Built, off" names the constant that keeps it off; "built, unproven" has code and tests but no
real-Mac run. Every row that turns on a security path needs its own independent review (the design's rule); the
user's decisions are named.

| # | What | State | What proves it | Review | Who |
| --- | --- | --- | --- | --- | --- |
| 1 | Step 4's dialog measurements (LA-1 to LA-7) | **partly done** on `v2-mac-runbook` (2026-11-26, from a shell card): LA-1, LA-2, LA-3, LA-7 answered; LA-6 run but still open; LA-4, LA-5 not run; the dialog's words not recorded (K-LA-1 to K-LA-7) | the records ([measurements/2026-11-26](measurements/2026-11-26/)); the owed steps 1, 3, 5, 6 | no | the user at the keyboard (LA-4 needs an external display; LA-5 needs Remote Login turned on: the user's call) |
| 2 | Step 4's escape measurements (ESC-1 to 3, ANC-1, ANC-2, AG-1) | **partly done** on `v2-mac-runbook` (2026-11-26, from a shell card): ESC-1, ESC-2, ESC-3, AG-1 answered; ANC-1 (Terminal.app) and ANC-2 (Remote Login) not run (K-ESC-1 to K-AG-1) | the records; the owed steps 2 and 5 | no | the user at the keyboard |
| 3 | The rule written from them: whether to add the coalition line (M4) and the peer's environment line (M2); the `approval` mode's guard rails settled | **built, off; review owed** (2026-11-27, `v2-mac-approval-lines`: both lines in `ApprovalVoice.callerRefusal`). **Settled in the spec** (2026-11-26, `v2-mac-runbook`: "The rule's lines, settled from the measurements"): the coalition line added, the peer's environment line added as an early refusal (not a boundary), no responsible-process line; what stays open named with its step. The rest **built, off** behind `NodeSystem.approvalMeasured` (`VoiceRule.Mode.approval`, `ApprovalVoice`, `Requests.approvalJudgment`) | `ApprovalJudgmentTests`, `ApprovalVoiceTests`, `ApprovalLinesTests` (pass here); then a manual `set` and `answer` from Terminal, a Claude Code Bash tool, and ESC-1/2 started by a session (the tasks' `1a6c4688` row) | **yes**: the two lines, `ApprovalRequests.swift`, `ApprovalCard.swift`, `Requests.handle`'s split, and the trust path (above) | the review of the whole rule (the two lines included); the user's decision on the five reads (item 6: a dialog for them, plain reads, or refused on the Mac) |
| 4 | Item 10: an anchor a session can't write for the server check | **built and reviewed** on `v2-mac-anchored-cli` (the lead's word, 2026-11-26): the root-owned record the user chose (2026-11-25, BCECD1F3), written by `scripts/node-pins-mac.sh` at the install; off with the rest | a fake server refused (the spec's "The anchor", "The fake host"); the real record on this Mac still owed: the `sudo` trial (owed step 4) | **yes** (done for the branch) | the user: the `sudo` trial |
| 5 | Item 13: the checked Mac node start | **built and reviewed** on `v2-mac-anchored-cli` (the lead's word, 2026-11-26), **off** behind `HostImages.isCheckedMacNode = false` and `HostImages.macServerRefusal` | the spec's "The checked node start" and its "What a real Mac proved"; a real `--node` host waits for the switch-on | **yes** (done for the branch) | the switch-on (row 15) |
| 6 | Item 11: Darwin ancestry through root's processes | **built, unproven** (`Platform.Processes.link`'s fallback, `PeerFacts.runner`) | M8 here; K-ESC-1/2 (an escaped Terminal window's chain through `login` read whole by the fallback); ANC-1, ANC-2 owed | **yes** (owed) | a worker for the review; the user runs ANC-1/2 |
| 7 | Item 3's owed half: the CLI's cdhash anchored where the host anchors the server's, not re-read from `<root>/bin` | **built and reviewed** on `v2-mac-anchored-cli` (the spec's "Rows 7 and 10"; the lead's word, 2026-11-26) | `NodePinsAnchorTests/everyPlaceTakingTheCommandLinesIdentityRefusesOneSwappedInTheBuild` | **yes** (done for the branch) | the signing with `--options runtime` stays row 12's |
| 8 | Item 9: the Mac's H1, the web port held by the host (`SCM_RIGHTS` over the stream, or launchd's `Sockets`), or `web` refused on the Mac until then | **built and reviewed** on `v2-mac-anchored-cli`: the host holds the web port (the spec's step 5: "No `Sockets` (the host holds the web port, item 9)"; the lead's word, 2026-11-26) | a second process can't bind the port while the host holds it; the server gets the descriptor | **yes** (done for the branch) | — |
| 9 | Step 5: the LaunchAgent wired (`start`/`stop`/`status` by `launchctl`, the plist written and checked, the server check by audit token and cdhash) | **built and reviewed** on `v2-mac-anchored-cli` (the spec's "The LaunchAgent: start, stop and status" and its review rounds; the lead's word, 2026-11-26); `start` still refused by `NodeSystem.macUnbuilt` | scratch jobs on this Mac's launchd; the user's AG-1 (K-AG-1, twice) agrees with its `bootout` measurement; a coalition sweep for `stop` an idea for its review, the survivor's coalition after `bootout` not yet read | **yes** (done for the branch) | the switch-on (row 15) |
| 10 | Item 12: the check reads the host's running image (`proc_pidpath` bound to the token), not `launchctl print`'s `program` | **built and reviewed** on `v2-mac-anchored-cli` (the spec's "Rows 7 and 10": the host check across a switch; the lead's word, 2026-11-26) | `MacAgentSwitchTests` (a scratch switch for real) | **yes** (done for the branch) | — |
| 11 | Step 6: the unified log for events and the ack rule | **not built** (`Platform.Journal` sends nothing on the Mac) | M10 shows `processImagePath` forgeable by UUID: the ack rule needs another anchor | yes | a worker; the design to change first |
| 12 | Step 7: `install-node-mac.sh` and signing | **built, unproven** (`install-node-mac.sh`, `lib/mac-sign.sh`, `MacSigningTests` pass here; its dry run runs on the hosted Mac) | an install from a v2 commit on this Mac (gh's token from the login keychain, curl, the App Store Xcode, `find`'s time) | **yes** (it is the Mac's S9) | **the user's decision**: the signing identity (`setup-signing.sh`'s local identity vs ad hoc, which makes the vault's Keychain key ask at each switch); the user at the keyboard for the Keychain read; then a worker |
| 13 | Step 8: the Mac seal list | **built, fix round done, re-check running** on `v2-mac-seal-list` (R1–R9, then 01a05734; joined into `v2-mac-joined`; earlier the same day "built, in its fix round", the lead's word; corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26); off, watched only by a checked node host's book | each row measured, a change held until accepted (the spec's "Built: `MacSealList`") | yes (the fix round's re-check, running) | the re-check; then the seal list's owed items (the spec's "Owed") |
| 14 | Step 9: coexistence: `lead` refusing an app-led project; the hooks | **not built** | a project the app leads refused by `lead` | no (refusal only); the hooks yes | **the user's decision**: how the node and the app share `~/.claude` hooks; then a worker |
| 15 | `approvalMeasured` on, `macUnbuilt` lifted for a checked install | **off** (`NodeSystem.swift` 34, 26) | the whole path on this Mac: `vibeswitcher start` starts the agent; `set`/`answer` ask once; a session's are refused or its escape's dialog declined | **yes**: the review that flips it | the user's go-ahead |

The order that matters (as written 2026-11-25): 1–2 (the user, any time) → 3 with the user's item 6 decision → **4, the
user's anchor decision**, which 5, 7, 9 and 10 wait on → 8 before any `start` that serves `web` → 9 → 11 → 12 with the
signing decision → 13, 14 → 15.

**Since then (2026-11-26).** The anchor was decided (a root-owned record, 2026-11-25) and rows 4, 5, 7, 8, 9 and 10 are
built and reviewed on `v2-mac-anchored-cli`; row 13 is on `v2-mac-seal-list`, its fix round done and its re-check running
(corrected at the join of `v2-mac-seal-list` and `v2-mac-runbook`, 2026-11-26; written first as "in its fix round"); rows 1 and 2 are partly
done (the keyboard session above); row 3 is settled in the spec on this branch, its two lines to build and review. What
is left before 15: the owed keyboard steps (above), row 3's two lines and its review, the five reads (item 6), 11 (the
log's ack anchor), 12 with the signing decision, 13's re-check, 14 with the hooks decision.
