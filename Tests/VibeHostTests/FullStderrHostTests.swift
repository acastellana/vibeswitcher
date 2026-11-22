import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// A host whose stderr fails every write (/dev/full: what a full disk does to `<root>/v2/host.log`) runs on: its log
/// lines are lost, not its sessions (the architecture review's row 2; `Platform.Stdio`). Before, its first line on
/// stderr ("started", right after the start) ended it with a SIGILL.
struct FullStderrHostTests {
    let scratch = Scratch()

    /// The built host on a private socket, lock, log and home, its stderr on /dev/full: it starts, writes its lines to
    /// stderr, and ends by its idle exit (code 0), not by a trap.
    @Test func aHostWithStderrOnAFullDeviceRunsToItsIdleExit() async throws {
        let folder = scratch.adopt(URL(fileURLWithPath: shortScratchRoot).appendingPathComponent("full-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = folder.appendingPathComponent("h.sock").path, log = folder.appendingPathComponent("host.log").path
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Every write fails: /dev/full where there is one; on the Mac (none) a pipe whose reader has gone (EPIPE; the host
        // ignores SIGPIPE).
        let full: FileHandle
        if FileManager.default.fileExists(atPath: "/dev/full") {
            full = try #require(FileHandle(forWritingAtPath: "/dev/full"))
        } else {
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            full = pipe.fileHandleForWriting
        }
        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", socket + ".lock", "--log", log, "--idle-exit", "1"]
        host.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        host.standardError = full
        host.standardOutput = full
        try TestHosts.run(host)
        defer { TestHosts.end(host) }
        #expect(await exited(host), "pid \(host.processIdentifier) still running")
        let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(host.terminationReason == .exit && host.terminationStatus == 0,
                "ended by \(host.terminationReason == .uncaughtSignal ? "signal" : "exit") \(host.terminationStatus); log:\n\(text)")
        #expect(text.contains("host: started") && text.contains("host: idle 1 s"), "\(text)")
    }
}
