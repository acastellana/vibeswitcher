import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A host the client starts that takes seconds to listen, as a loaded Mac makes a fresh build's first exec wait on
/// amfid (`HostClient.hostProbeLimit`): the client waits for it while it runs, rather than calling it failed after 3 s
/// (the sandbox's first fake session failed so: "The session host didn't start", SandboxIsolationTests in 3 merges'
/// runs, 2026-10-28). A host that ends without listening is still failed at once. A scratch host on its own socket and
/// lock, ending with this process.
@MainActor
@Suite(hostTestLimit) struct HostClientSlowStartTests {
    private let scratch = Scratch()
    private static let host = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path

    /// A client whose host is `script` (sh), run with the host's arguments; its pid is written to `dir/host.pid`. The
    /// built host is copied to `dir/build/vibeswitcher-host`, with this test process's own binary beside it as the app
    /// (its client is the app once it answers the challenge with its key, given to the host on stdin as the app does).
    /// `shared`: the folder whose socket, lock and session log it uses (`dir`'s own otherwise), as another app's would.
    func client(_ dir: String, shared: String? = nil, script: (_ host: String) -> String) throws -> HostClient {
        let shared = shared ?? dir
        let files = FileManager.default
        try files.createDirectory(atPath: dir + "/build", withIntermediateDirectories: true)
        try files.copyItem(atPath: Self.host, toPath: dir + "/build/vibeswitcher-host")
        try files.copyItem(atPath: try #require(HostServer.executable(of: getpid())), toPath: dir + "/build/VibeSwitcher")
        let path = dir + "/vibeswitcher-host"
        try Data("#!/bin/sh\necho $$ > '\(dir)/host.pid'\n\(script(dir + "/build/vibeswitcher-host"))\n".utf8).write(to: URL(fileURLWithPath: path))
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        // The host's output goes to the run's (scratch) ~/.vibeswitcher/host.log, as the app's does.
        try files.createDirectory(at: VibePaths.hostLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let client = HostClient(socketPath: shared + "/h.sock", appKey: HostClient.ownKey(), bundledBuild: { 0 }, note: { _ in })
        // A refused proof would ask in an alert (the main thread waits on it): the test's no instead.
        client.confirmKeyReset = { _, _ in false }
        client.hostPath = path
        client.hostArguments = ["--socket", shared + "/h.sock", "--lock", shared + "/h.lock", "--log", shared + "/session.log"] + HostClient.endsWithThisProcess
        return client
    }

    func pid(_ dir: String) -> pid_t? {
        (try? String(contentsOfFile: dir + "/host.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @Test func aHostThatTakesSecondsToListenIsWaitedFor() async throws {
        let dir = try scratch.shortFolder("vshs")
        // The real host, 5 s late: past the 3 s the client used to give it.
        let client = try client(dir) { "sleep 5\nexec '\($0)' \"$@\"" }
        // The host, and its sleep should it still be in it (its own process group: the client starts it in a session).
        defer { if let host = pid(dir) { kill(-host, SIGKILL); kill(host, SIGKILL); _ = BenchHostTests.waitForExit(of: host, timeout: hangGuard) } }
        var answer: String??
        client.ensureHost { answer = .some($0) }
        #expect(await until { answer != nil })
        #expect(answer == .some(nil), "\(String(describing: answer))")
        #expect(client.state == .connected)
    }

    /// The host that answers isn't the one this client started (still starting) but another's: one that took the lock
    /// first, or the build a handover put in its place. The client connects to it as soon as it listens, rather than
    /// waiting on its own host for `hostStartLimit`.
    @Test func anotherHostListeningIsConnectedToWhileOursStillStarts() async throws {
        let dir = try scratch.shortFolder("vshs")
        try FileManager.default.createDirectory(atPath: dir + "/other", withIntermediateDirectories: true)
        // Ours never gets as far as listening; the other app's host is the real one, on the same socket and lock.
        let ours = try client(dir) { _ in "sleep 3600" }
        let theirs = try client(dir + "/other", shared: dir) { "exec '\($0)' \"$@\"" }
        defer {
            for folder in [dir, dir + "/other"] {
                if let host = pid(folder) { kill(-host, SIGKILL); kill(host, SIGKILL); _ = BenchHostTests.waitForExit(of: host, timeout: hangGuard) }
            }
        }
        var answer: String??
        ours.ensureHost { answer = .some($0) }
        #expect(await until { pid(dir) != nil })
        var started: String??
        theirs.ensureHost { started = .some($0) }
        #expect(await until { started != nil })
        try #require(started == .some(nil), "the other host didn't start: \(String(describing: started))")
        let listening = Date()
        #expect(await until { answer != nil })
        #expect(answer == .some(nil), "\(String(describing: answer))")
        #expect(ours.state == .connected)
        // Ours still runs: the client didn't wait for it to end, or for its limit.
        #expect(pid(dir).map { kill($0, 0) == 0 } == true)
        #expect(Date().timeIntervalSince(listening) < HostClient.hostStartLimit, "waited \(Int(Date().timeIntervalSince(listening))) s")
    }

    @Test func aHostThatEndsWithoutListeningIsFailed() async throws {
        let dir = try scratch.shortFolder("vshs")
        let client = try client(dir) { _ in "exit 1" }
        var answer: String??
        client.ensureHost { answer = .some($0) }
        #expect(await until { answer != nil })
        #expect(answer == .some("The session host didn't start. See ~/.vibeswitcher/host.log."), "\(String(describing: answer))")
    }
}

private final class Anchor {}
