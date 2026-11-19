import Foundation
import Testing

/// This target's load-time handler for SIGPIPE ran (see `catchBrokenPipes` in TestSupport.swift): a write to a pipe
/// whose reader has gone fails with EPIPE, and doesn't end the run (which `brokenPipesFailTheRun` fails, naming it).
struct BrokenPipeTests {
    @Test func theRunCatchesSIGPIPE() {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        // Its default (0) would end the run. A test's moment of ignoring it (HostedSessionTests) passes too. On Linux
        // the run ignores it (TestSupport.swift's `refuseTheAccountRootOnLinux`): SIG_IGN, never the default either.
        #if canImport(Darwin)
        let handler = current.__sigaction_u.__sa_handler
        #else
        let handler = current.__sigaction_handler.sa_handler
        #endif
        #expect((handler.map { unsafeBitCast($0, to: Int.self) } ?? 0) != 0)
    }
}
