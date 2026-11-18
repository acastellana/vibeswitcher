# SIGPIPE hunt: what blocks two tests a core

At `VIBESWITCHER_TESTS_PER_CORE=2` a full run's tests take 388–487 s instead of 814 s (4 cores), but 3 of 10 such runs got a SIGPIPE (1 of 6 after d097e8d0; wideC2 had 88 in one burst 8.4 s in); at 1 a core, none in 4. The run catches it and fails naming it (`brokenPipesFailTheRun`, Tests/VibeCoreTests/TestSupport.swift). A pipe's SIGPIPE goes to the process, not the writing thread, so no handler's stack names the writer.

Ruled out: the app's stdin writers (only CodexTrust, with F_SETNOSIGPIPE); the host's sockets (`UnixSocket.configure`; ClientConnection and HostConnection stop writing once closed); MCPServer's handover probe and ToolServerStressTests (files); TestHosts (key written before the spawn); Shell.run (reads only); StatusRowsTests (no SIGPIPE without its fix; ends seconds before the signal); HostSecurityHardeningTests' descriptor test (guarded sockets; not in step with the signal in every run). The fake hosts (DroppedHost, StyledScreen, HostServer, DevPreviewHardening) were unguarded writers and are fixed.

Not checked yet: `LeadAdvance.stop` writes a byte to its stop pipe, whose reader thread may already have gone (a kevent error): one SIGPIPE, not a burst.

`early-suites.txt`: the 52 suites with a test that ended in wideC2's first 12 s (its burst came at 8.4 s), to bisect with `bash scripts/test.sh --filter '(A|B|…)/'` at `VIBESWITCHER_TESTS_PER_CORE=2`.

`epipe-probe.patch` (nothing builds or runs it): at each SIGPIPE it suspends the test process's other threads in turn (`task_threads` on its own task, never another process's), walks their frame pointers, and appends the stacks that hold a write or a send to `$VS_EPIPE_DUMP`. Checked on a synthetic writer, which it named. It reads raw stack memory, so it's for hunting only. Run: `git apply scripts/dev/sigpipe-hunt/epipe-probe.patch`, then `VIBESWITCHER_TESTS_PER_CORE=2 VS_EPIPE_DUMP=<file> vs-heavy bash scripts/test.sh` until the file has a `=== SIGPIPE` entry; `git apply -R` the patch after.
