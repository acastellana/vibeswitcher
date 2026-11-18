# SIGPIPE hunt: what blocks two tests a core

At `VIBESWITCHER_TESTS_PER_CORE=2` a full run's tests take 388–487 s instead of 814 s (4 cores), but 3 of 10 such runs got a SIGPIPE (1 of 6 after d097e8d0; wideC2 had 88 in one burst 8.4 s in); at 1 a core, none in 4. The run catches it and fails naming it (`brokenPipesFailTheRun`, Tests/VibeCoreTests/TestSupport.swift). A pipe's SIGPIPE goes to the process, not the writing thread, so no handler's stack names the writer.

Ruled out: the app's stdin writers (only CodexTrust, with F_SETNOSIGPIPE); the host's sockets (`UnixSocket.configure`; ClientConnection and HostConnection stop writing once closed); MCPServer's handover probe and ToolServerStressTests (files); TestHosts (key written before the spawn); Shell.run (reads only); StatusRowsTests (no SIGPIPE without its fix; ends seconds before the signal); HostSecurityHardeningTests' descriptor test (guarded sockets; not in step with the signal in every run). The fake hosts (DroppedHost, StyledScreen, HostServer, DevPreviewHardening) were unguarded writers and are fixed.

Not checked yet: `LeadAdvance.stop` writes a byte to its stop pipe, whose reader thread may already have gone (a kevent error): one SIGPIPE, not a burst.

`early-suites.txt`: the 52 suites with a test that ended in wideC2's first 12 s (its burst came at 8.4 s), to bisect with `bash scripts/test.sh --filter '(A|B|…)/'` at `VIBESWITCHER_TESTS_PER_CORE=2`.

`epipe-probe.patch` (nothing builds or runs it): at each SIGPIPE it suspends the test process's other threads in turn (`task_threads` on its own task, never another process's), walks their frame pointers, and appends the stacks that hold a write or a send to `$VS_EPIPE_DUMP`. Checked on a synthetic writer, which it named. It reads raw stack memory, so it's for hunting only. Run: `git apply scripts/dev/sigpipe-hunt/epipe-probe.patch`, then `VIBESWITCHER_TESTS_PER_CORE=2 VS_EPIPE_DUMP=<file> vs-heavy bash scripts/test.sh` until the file has a `=== SIGPIPE` entry; `git apply -R` the patch after.

## Second hunt, 2026-11-18 (find-the-test-that): not found

Runs, each with the probe, one at a time under vs-heavy:

- 5 full runs at 2 a core: no SIGPIPE (tests 431–479 s; run 2 also failed 2 HookBoundsTests after its driver shell was killed mid-run, an artifact of that).
- 42 runs of the 52 early suites at 2 a core (about 65 s each): one caught SIGPIPE, in the second (before the write hook and the in-handler snapshot below existed); none in the 40 after.
- 5 runs of the early suites at 3 a core: no SIGPIPE. The hunt stopped with every vs-heavy slot held by other sessions.
- Then, with the new probe, 60 minutes of `scripts/test-under-load.sh --load 24 -r 3` on the early suites (once the disk had 22 GB free): 17 load runs, 51 completed early-suite runs (the probe installed in each), no SIGPIPE, and not one unguarded EPIPE from the bundle's writes. Each load run also exited 1 on a `vswt-*` entry some test leaves in its TMPDIR.

So the probe now in the patch has caught nothing yet in about 60 early-suite runs; the early catch came before it existed. At this rate (1 in about 100 early-suite runs overall, none in 5 full runs) the writer is rare at 2 a core.

What the one catch showed (`dump-early2.txt` here):

- **It was one signal, not ten.** The run printed 10 SIGPIPE issues, but the dispatch source's count was 1 (`1 signals` in the dump) and the probe ran once. An issue recorded outside any test seems to be printed once for each test running at the time: with a single test running (the probe's self-test) issues and signals matched 1:1. So wideC2's "88 in one burst" may also have been a few signals, or one. Look for a one-shot writer, not a loop.
- The writer had already returned when the dispatch handler ran, so the stacks show only bystanders: 4 threads in `HostCall.exchange` (ToolServerStressTests' `manyCallsAtOnce…`, on `UnixSocket.connect`'s guarded sockets), 30 threads in `SessionStrays.endNow`'s grace sleep (SIGTERM and SIGKILL only), host-test clients polling screens.
- It came between ClearDraftTests ending and VerifierHookTests ending, about 13 s in.

Newly ruled out:

- **A pty.** A write to a pty master whose slave is closed returns EIO and raises no SIGPIPE (checked with openpty), so `HostedSession`'s input writes can't be the writer.
- **`FileHandle.write(_:)`** (VerifierHookTests, HookBoundsTests, LeadVaultHostTests' `nc`, MCPHandoverTests…): on EPIPE it raises NSFileHandleOperationException and aborts the process (checked). A quiet SIGPIPE can't come from one; only a raw write/send, or a `try?` on `write(contentsOf:)` to a pipe (none found).
- **MCPKeeper's signal-driven wake pipe:** `MCPKeeper.run` runs only in vibeswitcher-mcp's own process (which ignores SIGPIPE), never in the tests'.
- **MCPServer's wake pipe:** written and closed under its lock.
- **The host's accepted sockets:** `UnixSocket.configure` runs before the first write. About 130 EPIPEs a run come from ClientConnection's challenge to SocketBacklogTests' 128 clients that close at once; all are on sockets with F_GETNOSIGPIPE 1, so no signal.
- **Running out of descriptors:** the test process's limit is 1,048,576 under vs-heavy here; ToolServerStressTests' limit of 32 is its tool server's (`ulimit -n` in the child's shell), not the test process's.
- **LeadToolServerHandover's Server:** talks to its tool server over files.

Not the early catch's writer, since none of them ran in it (the filter is `(suite|…)/`): `LeadAdvance.stop`'s 1-byte write (no early suite starts a LeadAdvance, LeadToolset or MCPServer in the test process; its reader exits only on that byte, its EOF or a kevent error), the raw TCP write in `PhoneRepliesTests.exchange` (no SO_NOSIGPIPE), and `TooLargeReplyTests` (its socketpair's `fds[0]` isn't configured, though its peer stays open while the connection lives). Each could still be a full run's writer. The early catch's writer is in one of the 52 early suites or the code they run.

Flakes seen meanwhile, none a SIGPIPE: `StatusLineBinaryTests.claudeCodeStoppingTheStatusLineStopsYourCommandToo` (3 early runs and 6 of 51 under load, after about 300 s each), `HostServerTests.inputBeyondTheBufferIsRefusedOutLoudNeverLost` (1 early run), `HostedSessionTests.aShellThatIsntThereIsNamedOnTheSessionsScreen` (1 run at 3 a core), `endedSessionsCloseTheirPTYs` and `refusedInputIsAnError` (1 each under load).

The probe in `epipe-probe.patch` now does three things, all in the test process on its own task. They read raw stack memory, so they're for hunting only:

1. The dispatch source's dump as before. It no longer counts `mach_msg_overwrite` (every main thread has it) as a write. With no thread in a write it dumps every thread, with the signal count and a timestamp.
2. A real SIGPIPE handler, installed after every target's own, takes every thread's stack inside the handler itself, microseconds after the write. The dispatch handler then symbolizes it to `$VS_EPIPE_DUMP.writers` (`=== SNAPSHOT`).
3. The test bundle's own pointers to write, writev, send, sendto and sendmsg are rebound to wrappers. On an EPIPE whose descriptor has no F_GETNOSIGPIPE, the wrapper writes the writer's own stack, the descriptor's kind and the test to `$VS_EPIPE_DUMP.writers` (`=== EPIPE`). A write from another image (Foundation, libdispatch) isn't seen this way; the snapshot covers those.

The self-test (`VS_EPIPE_SELFTEST=1 VS_EPIPE_DUMP=<file> bash scripts/test.sh --filter EPipeProbeCheck`) names its writer in all three. The quickest loop is the early suites:

```sh
VIBESWITCHER_TESTS_PER_CORE=2 VS_EPIPE_DUMP=<file> vs-heavy bash scripts/test.sh --filter "($(paste -sd'|' scripts/dev/sigpipe-hunt/early-suites.txt))/"
```

At about 65 s a run, it caught one SIGPIPE in 42 runs. Once `<file>.writers` has an `=== EPIPE` or `=== SNAPSHOT` entry, the writer is named.
