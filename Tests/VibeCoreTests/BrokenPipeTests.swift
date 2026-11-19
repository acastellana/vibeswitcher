import Darwin
import Testing

/// This target's load-time handler for SIGPIPE ran (see `catchBrokenPipes` in TestSupport.swift): a write to a pipe
/// whose reader has gone fails with EPIPE, and doesn't end the run (which `brokenPipesFailTheRun` fails, naming it).
struct BrokenPipeTests {
    @Test func theRunCatchesSIGPIPE() {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        // Its default (0) would end the run. A test's moment of ignoring it (HostedSessionTests) passes too.
        #expect((current.__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: Int.self) } ?? 0) != 0)
    }
}
