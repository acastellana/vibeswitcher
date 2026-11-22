# VibeSwitcher 2: flaky tests

Tests that fail on some runs and pass on others, with no change to the code they check. The nightly
(`scripts/nightly.sh`) lists each failure that passed on its retry; a failure that keeps failing is a real one and gets
a fix, not a line here. Each entry says where it failed, how, and when it was first seen; one that stops failing for two
weeks of nightlies and CI runs comes out, saying so in its commit. A flake is still a bug: an entry is a reason to fix it
later, never to skip it.

| Test | Where it failed | Evidence | First seen |
| --- | --- | --- | --- |
| `ProjectAllowListTests.aForgedWorktreePairPassesAsKnown` | Linux CI | failed on CI at `2ceb69f7`, passed on the next runs of the same commit | 2026-11-21 |
| `WebListenerTests.theListenerBindsToLoopbackOnly` | local, under parallel suites | its descriptor count read 2 where it expects its own listener's alone: another suite's descriptors counted while they run in parallel | 2026-11-21 |
| `WebListenerTests`' slow-client case | local, under load | the slow client's timing is read against the wall clock under parallel suites | 2026-11-21 |
| `ComposerDeliveryTests` | the Mac's CI (`v2 macos`, app job) | main's known flake on the runner (see v2-mac-tasks.md, "Main's known flakes on the runner") | 2026-11-21 |
| `ShellDeskTests` | the Mac's CI (`v2 macos`, app job) | main's known flake on the runner (as above) | 2026-11-21 |
| `NodeAcceptanceTests` A30 (its second `settings --find`) | local, under load (`test-under-load.sh --load 24`, with the race tests beside it) | once in 12 load runs: the command exited non-zero with nothing on stdout; its stderr wasn't in the message then (it is now, with the server's log), so the cause isn't known yet; the next 9 runs passed | 2026-11-21 |
| `SessionResumeTests.anEndedSessionIsListedAndResumedInItsConversation` | local, beside the lint suites (`test.sh --filter 'LintTests/|…'`) | its `resume` words read other than "ended 4 s ago … listed in 26 s" once: the engine's own refresh can note the session ended (at the real clock) before the test's `noteOpenSessions` with its fixed `openNow`, so the times it reads aren't the test's; alone and under load (3 × 2·cores) it passes | 2026-11-22 |
