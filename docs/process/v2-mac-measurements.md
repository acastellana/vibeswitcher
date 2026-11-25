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
`.build/mac-measure`. Paths below are cut to `<clone>` and `~`.

## What step 4 names, and where each stands

| Measurement | Where | Here |
| --- | --- | --- |
| The environment line under SIP | step 4 | **taken** (M2): readable, except for Apple's platform binaries |
| Double fork, `setsid`: the process facts left | design, "What a same-uid process can do" | **taken** (M3) |
| `open -a Terminal x.command`: its process facts | step 4 | script ESC-1 (a window on the user's screen) |
| `osascript … do script`: its process facts | step 4 | script ESC-2 (an Automation consent may appear) |
| `launchctl submit`/`bootstrap` of a session's own agent | step 4 | script ESC-3 (a job in the login session) |
| The responsible pid | step 4 | **taken** for this context (M5: every process its own); inheritance in ESC-1 to 3 |
| LocalAuthentication from a LaunchAgent in `gui/<uid>` | step 4, item 2 | script LA-1 (the dialog) |
| … declined, cancelled, its 60 s against the CLI's 120 s | item 2, the tasks' `1a6c4688` row | script LA-2; the CLI's 120 s read from the code (M14) |
| … with no Touch ID (the password) | step 4 | script LA-3 |
| … with the lid closed | step 4 | script LA-4 (needs an external display) |
| … over ssh (`.notInteractive` read as unavailable) | step 4 | script LA-5 (needs Remote Login: off here) |
| A second dialog while one is open | the tasks' `8f8b7e20` row | script LA-6 |
| Whether a process of the user's can answer it (Accessibility) | item 3 | script LA-7 |
| Whether an agent session's process can raise the dialog | design, "What it can't do" | **taken** (M9): it can |
| Item 3: `DYLD_INSERT_LIBRARIES` into the hardened command line refused | item 3 | **taken** (M6) |
| Item 3: the connect-write-exec race | item 3 | **taken** (M7) |
| Item 6: the five reads with no gate | item 6 | a decision of the user's (below) |
| Item 7: a link of another user's process, a zombie, a process that execs | item 7 | **taken** (M8, M7) |
| Item 7: the Mac node host's vault on disk (its Keychain key), across a handover | item 7 | not measurable before item 13: no Mac node host exists |
| Item 7: the server check against a real job | item 7 | not before step 5 wires `start`; the job's shape in AG-1 |
| Item 7: gh's token in the login Keychain, GitHub through curl | item 7 | not taken: the user's Keychain item (an install run reads it) |
| Item 7: an App Store Xcode passing the toolchain check | item 7 | **taken** in part (M12): root-owned throughout |
| Item 7: launchd taking the written agent; entitlements for the host | item 7 | AG-1 for the shape; the node's own agent waits for step 5 |
| Item 7: the run paths (macOS 26 or later) | item 7 | **taken** (M12): macOS 27.2 |
| Item 9: the server gets the web socket; a second process can't bind the port | item 9 | not built (below); nothing to measure |
| Item 10: an anchor a session can't write | item 10 | a decision of the user's (below) |
| Item 11: a chain from Terminal and one from ssh read whole | item 11 | **taken** for root's records (M8); scripts ANC-1, ANC-2 |
| Item 12: `launchctl print`'s lines | item 12 | **taken** (M11): the format `NodeAgent.printed` parses |
| Item 13: the checked node start | item 13 | not built: it waits on item 10 |
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
of its own. So a session's descendants stay in the coalition of whatever job started the session (the app's today,
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
inherited from the shell to its child. So from here this line tells nothing. Whether it is inherited under Terminal
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
program carrying the original's UUID is logged as the original's image (its message failed to compose here because its
format strings sit elsewhere; one built to match the layout would compose). So **the design's step 6 ack rule,
"written by the installed command line's image" (`processImagePath`), is forgeable by any process of the user's**: the
installed command line's UUID is readable from its file. Weaker than the design's "weaker than Linux's". Step 6 needs
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

## The scripts for the user

Each in [scripts/mac-measure](../../scripts/mac-measure), one measurement each, run by the user in Terminal (or an ssh
login where said). Each prints what will appear before it happens and waits for Return; refuses from an agent's
session or without a terminal; loads only a job labelled `dev.vibeswitcher.measure.<what>.<pid>` from a property list in
its own `/tmp/mac-measure.*` folder (never `~/Library/LaunchAgents`), boots it out when it ends (Ctrl-C too), and
prints a record (the account's name and home taken out) to paste back. A job's property list carries
`MEASURE_ASK=yes` (`la ask` refuses without it; a job inherits nothing from the shell), and `la` writes line by line. `--dry-run` builds the probes, writes and lints
the property list, and stops before anything is shown or loaded: all thirteen were dry-run from the agent's session, and
the real run of three was checked to refuse there (`STOPPED: this runs from an agent's session …`, exit 1) and without
a terminal (`STOPPED: no terminal on stdin and stdout`, exit 1).

| Id | Command (in Terminal, from the clone) | Look for |
| --- | --- | --- |
| LA-1 | `bash scripts/mac-measure/la-agent.sh` | the dialog appears from a LaunchAgent; its exact words: does "MEASURE-1 …" read first, after the program's name "la"? Touch ID → `outcome=approved` |
| LA-2 | `bash scripts/mac-measure/la-cancel.sh` | Cancel → `outcome=declined("cancelled at the Mac")`; left alone → gone by itself at 60 s, `declined("not answered within 60 s")` |
| LA-3 | `bash scripts/mac-measure/la-password.sh` | "Use Password…" offered; the login password in the system dialog → `approved` |
| LA-4 | `bash scripts/mac-measure/la-lid-closed.sh` | with an external display and the lid shut: `la can`'s biometry, then which route the dialog offers |
| LA-5 | `bash scripts/mac-measure/la-ssh.sh` (from `ssh localhost`) | `la can` over ssh, the ask's outcome (expected `.notInteractive`, unavailable), and whether anything appeared on the Mac's screen. Needs Remote Login on |
| LA-6 | `bash scripts/mac-measure/la-second.sh` | a second dialog 3 s after the first: queued, replaced, or refused |
| LA-7 | `bash scripts/mac-measure/la-keys.sh` | `accessibility_trusted=`; "keys: posted Escape at=T" then `outcome=declined(…)` at T plus a second or two, untouched, means synthetic keys reach the dialog; it posts only while the dialog's process is frontmost (else "posted nothing", naming the frontmost bundle id: rerun with it). Decline any "control this computer" request |
| ESC-1 | `bash scripts/mac-measure/escape-open-terminal.sh` | a Terminal window opened by a detached process: its shell's chain, terminal, coalition and responsible pid against yours |
| ESC-2 | `bash scripts/mac-measure/escape-osascript.sh` | the same through `osascript … do script`, and any Automation consent (its words) |
| ESC-3 | `bash scripts/mac-measure/escape-launchctl.sh` | a job of its own in `gui/<uid>`: `ppid=1`, no terminal, its coalition and responsible pid |
| AG-1 | `bash scripts/mac-measure/agent-bootout.sh` | `launchctl print`'s `pid`/`program` as `NodeAgent.printed` parses them; which of the job's process, a child in its group and a `setsid` child outlive `bootout` |
| ANC-1 | `bash scripts/mac-measure/ancestry-terminal.sh` | every ancestor read (`shortbsdinfo=read` or `kern_proc_pid=read`), `login` with `bsdinfo=refused` |
| ANC-2 | `bash scripts/mac-measure/ancestry-ssh.sh` (from `ssh localhost`) | the same through `sshd-session`; `managername` (`Background`, so `LimitLoadToSessionType Aqua` keeps the node out). Needs Remote Login on |

## `web_acts: trust` under the Mac's rule

The user wants to authorize once rather than per command. Read from the code at `b9df9949`:

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
  squatted" of item 9 isn't built: once a Mac node starts, `web` would come up squattable between one server and the
  next. An acting page at `trust` on a squatted port is the worst case of item 9. Item 9 (or `web` refused on the Mac)
  belongs before any Mac `start`.
- **One dialog for the lot** would need a change: e.g. `vibeswitcher web --trust` asking one dialog whose card names
  all three (raise the level, open, confirm the phrase), the server holding the open and the confirm under that one
  approval. Not built; a design change for the user and a security review.

## What stands between this Mac and `vibeswitcher start`

In the design's order. "Built, off" names the constant that keeps it off; "built, unproven" has code and tests but no
real-Mac run. Every row that turns on a security path needs its own independent review (the design's rule); the
user's decisions are named.

| # | What | State | What proves it | Review | Who |
| --- | --- | --- | --- | --- | --- |
| 1 | Step 4's dialog measurements (LA-1 to LA-7) | scripts ready (this) | the records pasted back | no | the user at the keyboard (LA-4 needs an external display; LA-5 needs Remote Login turned on: the user's call) |
| 2 | Step 4's escape measurements (ESC-1 to 3, ANC-1, ANC-2, AG-1) | scripts ready (this) | the records | no | the user at the keyboard |
| 3 | The rule written from them: whether to add the coalition line (M4) and the peer's environment line (M2); the `approval` mode's guard rails settled | **built, off** behind `NodeSystem.approvalMeasured` (`VoiceRule.Mode.approval`, `ApprovalVoice`, `Requests.approvalJudgment`); coalition line not built | `ApprovalJudgmentTests`, `ApprovalVoiceTests` (pass here); then a manual `set` and `answer` from Terminal, a Claude Code Bash tool, and ESC-1/2 started by a session (the tasks' `1a6c4688` row) | **yes**: `ApprovalRequests.swift`, `ApprovalCard.swift`, `Requests.handle`'s split, and the trust path (above) | a worker; the user's decision on the five reads (item 6: a dialog for them, plain reads, or refused on the Mac) |
| 4 | Item 10: an anchor a session can't write for the server check | **not built** (design) | a fake server (genuine host, evil server in `~/.vibeswitcher/v2/builds/…`, plist rebootstrapped) refused | **yes** | **the user's decision**: root-owned pins (a `sudo` at each install), a Keychain item bound to the CLI's code (the login keychain unlocked; the ACL rewritten each install), or a Developer ID team (a paid identity); then a worker |
| 5 | Item 13: the checked Mac node start | **built, off** behind `HostImages.isCheckedMacNode` (and `HostImages.macServerRefusal` refusing a server child on the account's locks) | a node host on a scratch root with a server child, its vaultV2 and hooks; `LeadVaultV2.recordsOnThisHost` moved into the vault (item 14) | **yes** | a worker, after 4 |
| 6 | Item 11: Darwin ancestry through root's processes | **built, unproven** (`Platform.Processes.link`'s fallback, `PeerFacts.runner`) | M8 here; ANC-1, ANC-2 | **yes** (owed) | a worker for the review; the user runs ANC-1/2 |
| 7 | Item 3's owed half: the CLI's cdhash anchored where the host anchors the server's, not re-read from `<root>/bin` | **not built** | a CLI swapped in `<root>/bin` after the host's start refused | yes (with 4) | a worker |
| 8 | Item 9: the Mac's H1, the web port held by the host (`SCM_RIGHTS` over the stream, or launchd's `Sockets`), or `web` refused on the Mac until then | **not built**; today `WebBind.direct` on the Mac | a second process can't bind the port while the host holds it; the server gets the descriptor | yes | a worker; the user's call on an opt-in that says the port can be squatted |
| 9 | Step 5: the LaunchAgent wired (`start`/`stop`/`status` by `launchctl`, the plist written and checked, the server check by audit token and cdhash) | **built as data** (`NodeAgent`, `NodeAgentTests` pass here), not wired; `start` refused by `NodeSystem.macUnbuilt` | AG-1's record; then `start` loads `dev.vibeswitcher.node` and the host starts; `bootout` ends the group | yes (it is the start path) | a worker, after 4 and 5 |
| 10 | Item 12: the check reads the host's running image (`proc_pidpath` bound to the token), not `launchctl print`'s `program` | **not built** | a switch (plist rewritten, host handed over) keeps the check passing | yes (with 4) | a worker, before the first switch |
| 11 | Step 6: the unified log for events and the ack rule | **not built** (`Platform.Journal` sends nothing on the Mac) | M10 shows `processImagePath` forgeable by UUID: the ack rule needs another anchor | yes | a worker; the design to change first |
| 12 | Step 7: `install-node-mac.sh` and signing | **built, unproven** (`install-node-mac.sh`, `lib/mac-sign.sh`, `MacSigningTests` pass here; its dry run runs on the hosted Mac) | an install from a v2 commit on this Mac (gh's token from the login keychain, curl, the App Store Xcode, `find`'s time) | **yes** (it is the Mac's S9) | **the user's decision**: the signing identity (`setup-signing.sh`'s local identity vs ad hoc, which makes the vault's Keychain key ask at each switch); the user at the keyboard for the Keychain read; then a worker |
| 13 | Step 8: the Mac seal list | **not built** (`MacSealList` doesn't exist) | each row measured, a change held until accepted | yes | a worker |
| 14 | Step 9: coexistence: `lead` refusing an app-led project; the hooks | **not built** | a project the app leads refused by `lead` | no (refusal only); the hooks yes | **the user's decision**: how the node and the app share `~/.claude` hooks; then a worker |
| 15 | `approvalMeasured` on, `macUnbuilt` lifted for a checked install | **off** (`NodeSystem.swift` 34, 26) | the whole path on this Mac: `vibeswitcher start` starts the agent; `set`/`answer` ask once; a session's are refused or its escape's dialog declined | **yes**: the review that flips it | the user's go-ahead |

The order that matters: 1–2 (the user, any time) → 3 with the user's item 6 decision → **4, the user's anchor
decision**, which 5, 7, 9 and 10 wait on → 8 before any `start` that serves `web` → 9 → 11 → 12 with the signing
decision → 13, 14 → 15.
