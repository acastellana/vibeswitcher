import Foundation
import Testing

/// This target's load-time guard ran, and let the run go on: its root isn't the account's own ~/.vibeswitcher (see
/// `refuseTheAccountRoot` in TestSupport.swift, and VibeCoreTests' `HomeIsolationTests`).
struct TestHomeGuardTests {
    @Test func theGuardRan() {
        #expect(homeGuardRan == true)
    }

    @Test func onlyTheAccountsOwnFolderIsRefused() {
        let own = URL(fileURLWithPath: "/Users/someone/.vibeswitcher")
        #expect(TestHome.refusal(root: own, accountHome: "/Users/someone")?.contains("/Users/someone/.vibeswitcher") == true)
        #expect(TestHome.refusal(root: URL(fileURLWithPath: "/Users/someone/dev/../.vibeswitcher/"), accountHome: "/Users/someone/") != nil)
        #expect(TestHome.refusal(root: URL(fileURLWithPath: "/Users/someone/dev/app/.build/scratchhome/.vibeswitcher"), accountHome: "/Users/someone") == nil)
        #expect(TestHome.refusal(root: URL(fileURLWithPath: "/Users/someone/.vibeswitcher-scratch"), accountHome: "/Users/someone") == nil)
    }

    @Test func theRootFollowsTheVariablesInVibeCoresOrder() {
        func root(_ variables: [String: String]) -> String {
            TestHome.root(variable: { variables[$0] }, fallbackHome: "/fallback").path
        }
        #expect(root(["VIBESWITCHER_HOME": "/own", "CFFIXED_USER_HOME": "/fixed", "HOME": "/home"]) == "/own")
        #expect(root(["VIBESWITCHER_HOME": "relative", "CFFIXED_USER_HOME": "/fixed", "HOME": "/home"]) == "/fixed/.vibeswitcher")
        #expect(root(["HOME": "/home"]) == "/home/.vibeswitcher")
        #expect(root(["HOME": ""]) == "/fallback/.vibeswitcher")
    }

    #if os(Linux)
    /// The initializer's other job on Linux: a write to a pipe nobody reads fails, and the run lives to say so.
    @Test func aWriteToAClosedPipeIsAnError() {
        // What SIGPIPE did until now, asked by setting it again: a run that didn't ignore it fails here, and isn't
        // ended by the write below.
        let before = signal(SIGPIPE, SIG_IGN)
        #expect(unsafeBitCast(before, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self), "the bundle's initializer didn't ignore SIGPIPE")
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        defer { close(ends[1]) }
        let written = write(ends[1], "x", 1)
        let code = errno
        #expect(written == -1)
        #expect(code == EPIPE)
    }
    #endif
}
