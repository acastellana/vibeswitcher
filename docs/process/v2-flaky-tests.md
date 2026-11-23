# VibeSwitcher 2: flaky tests

Tests that fail on some runs and pass on others, with no change to the code they check. The nightly
(`scripts/nightly.sh`) lists each failure that passed on its retry; a failure that keeps failing is a real one and gets
a fix, not a line here. Each entry says where it failed, how, and when it was first seen; one that stops failing for two
weeks of nightlies and CI runs comes out, saying so in its commit. A flake is still a bug: an entry is a reason to fix it
later, never to skip it.

| Test | Where it failed | Evidence | First seen |
| --- | --- | --- | --- |
| `WebListenerTests.theListenerBindsToLoopbackOnly` | local, under parallel suites | its descriptor count read 2 where it expects its own listener's alone: another suite's descriptors counted while they run in parallel | 2026-11-21 |
| `WebListenerTests`' slow-client case | local, under load | the slow client's timing is read against the wall clock under parallel suites | 2026-11-21 |
| `ComposerDeliveryTests` | the Mac's CI (`v2 macos`, app job) | main's known flake on the runner (see v2-mac-tasks.md, "Main's known flakes on the runner") | 2026-11-21 |
| `ShellDeskTests` | the Mac's CI (`v2 macos`, app job) | main's known flake on the runner (as above) | 2026-11-21 |
| `NodeAcceptanceTests` A30 (its second `settings --find`) | local, under load (`test-under-load.sh --load 24`, with the race tests beside it) | once in 12 load runs: the command exited non-zero with nothing on stdout; its stderr wasn't in the message then (it is now, with the server's log), so the cause isn't known yet; the next 9 runs passed. Likely the cause `SettingsRequestTests`' was (below, `808e2a13`): kept here until a nightly shows it gone | 2026-11-21 |
| `SettingsRequestTests.theCommandLineSetsAndReadsASetting` (`set`, at load ~110 on 4 cores) | local, `taskset -c 0-3` under load | once in 20: `set` refused, "not recorded in the host's vault, so not done: the session host didn't answer its connector": the host's vault call timed out at a load far past CI's; no fix (the reply-queue crash is fixed and gone from these runs) | 2026-11-22 |
| The session host on `config held <home>` (a scratch node, held first look; the plugins lane's "tenth field on `LeadVaultV2.Book`" crash) | local, twice in a row on 2026-11-22 (~19:45), each the first run after the worktree switched from `272d568a` back to its branch | the host died with SIGILL (wait status 4: a Swift runtime trap on a dispatch worker; no symbols, the host is non-dumpable). Not stack depth (the look uses ~130 KB of 8 MB, `VaultStackTests`) and not the field count (ten fields pass every acceptance case on clean builds; 96 probe runs, 0 deaths). Gone after the host was rebuilt; reading: stale build state after a tree switch, unconfirmed. The host-probe nightly (`v2-host-probe.yml`, `scripts/ci/host-probe.sh`) looks for it, with a symbolized trace | 2026-11-22 |

## Fixed

Taken off the list above (or never on it) once their cause was found and fixed; each fix ran 20 times under load
(`test-under-load.sh --load 48 -r 20`, and on 4 cores as CI has).

| Test | Cause | Fix |
| --- | --- | --- |
| `TailnetWebTests.aPeerOutsideTailscalesRangesIsClosedAtAccept` | the web listener closed a refused peer's connection before writing its note, so the test read the notes in the gap (a product ordering bug) | `c40c13de`: the note before the close |
| `HostWebListenersTests.aHandoversSocketIsHeldAgainOnlyWhenItIsOne` | the closed socket's number checked with `fcntl`, which another test's open in the process can take in between | `3430ad3c`: checked by device and inode |
| `DroppedHostTests.aHostThatClosesBeforeItsWelcomeIsAnErrorNotNoSessions` | the test's dropping host counted a connection after closing it | `48710ea0`: counted before the close |
| `SessionResumeTests.anEndedSessionIsListedAndResumedInItsConversation` | the wire rounds dates to the millisecond, so an end time just past one came back later and the rounded-up "listed in" read 27 s | `956fa8ad`: the engine's clock fixed before the end, on a whole second |
| `ProjectAllowListTests.aForgedWorktreePairPassesAsKnown` | git 2.56's background maintenance after a commit pruned the test's half-written `.git/worktrees` entry (from the CI log; git here is older) | `79a44efc`: the test repositories turn automatic maintenance off |
| `IndexLockTests.aGitInAWorktreeDoesntHoldTheMainCheckoutsLock` (the Mac) | the real holder search reads every process's open files; on a loaded runner it ran past `find`'s default 10 s, and a search out of time can't call a lock stale | `54f57c0d`: the tests asking who holds a lock give the search `hangGuard` |
| `SettingsRequestTests.theCommandLineSetsAndReadsASetting` (`settings --find`, exit 77; and A30's) | one unreadable look at the listener's dumpable state on a loaded runner refused the command | `808e2a13`: read again while it can't be told and the process lives, 3 s at most, still refused after |
| `SessionEnvironmentTests.aLinuxSessionGetsNoAgentSocketNoInteropNoBus` | bash execs the line's last command in its own process; reading `/proc/<pid>/environ` during that exec came back empty | `40eec040`: the read waited for |
| `EgressProxyTests.aTunnelToAListedHostCarriesBytesBothWays` | the tunnel's first echoed bytes came in the same read as the 200, and the echo was compared without them | `bf231346`: kept |
| `HandoverLinuxTests` (ETXTBSY) and `EndingASessionTests.theAppCarryingASessionsIdIsNotEndedWithThatSession` | a copy of a program this process wrote (`FileManager.copyItem`, an append) was held open for writing by another test's child, and Linux won't run a file open for writing anywhere | `installProgram` (a child's `cp`, or `cat` and `printf`) for every program the host tests copy and run |
| `InstallTests.aFilterInTheCheckoutsOwnConfigNeverRuns` | the courtesy check copied the index with a plain `cp`: the copy was newer than its entries, so git trusted a same-size change made in an entry's second ("racily clean") and the check passed it; the later checks refused the install (69) | `cp -p` of the index in install-node.sh and install-node-mac.sh; `aRacilyCleanChangeIsStillFound` crafts the case |
| `CodexWorkerTests.aCodexWorkerReportsAndAutoAdvanceAuditsItWithAClaudeVerifierAndSendsFindingsBack` | the lead's message reaches the worker first (`LeadToolset.sent`'s delivery), and the failed task is set back to running after it; the test read the status in between | the test waits for both |
| `NodeAcceptanceTests` A40 (`merge_remote`) | `merge_remote` waits for the machine's load to drop below load_threshold before it tests (`waitForLoad`, up to test_timeout); a loaded runner held it past the test's 300 s | the case sets `noLoadHold`, as the cases that start workers do |
| `AnswerVoiceTests` (:111, no `cards` snapshot) | the web listener's keepalive ping (every 15 s on a node's page) came before the subscription's snapshot under load, and the tests' `LivePage` took any frame that isn't JSON for the connection's end | `LivePage.next()` answers a ping with a pong and reads on, as `TermPage` and a browser do |
