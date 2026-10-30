import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// The app's own client handing a real `vibeswitcher-host` over to a new build whose probe takes past a request's 15 s,
/// as a loaded Mac makes a fresh build's first exec wait on amfid. A scratch host (its own home, socket, lock and key;
/// never the user's) in a process of its own: a handover replaces the process's image.
@MainActor
@Suite(hostTestLimit) struct HostClientSlowProbeTests {
    /// The host and its two builds: copies of the built host with their own modification times, which is what tells
    /// builds apart.
    final class ScratchHost {
        let dir: String
        let socket: String
        let newBinary: String
        let newBuild: Int
        let process = Process()
        let appKey = SymmetricKey(size: .bits256)
        private var watchdog: Process?

        init() throws {
            // Short: a socket's path has a 104-byte limit.
            dir = "\(shortScratchRoot)/vshp-\(UUID().uuidString.prefix(8))"
            socket = dir + "/h.sock"
            let oldBinary = dir + "/old/vibeswitcher-host"
            newBinary = dir + "/new/vibeswitcher-host"
            let files = FileManager.default
            for folder in [dir + "/home", dir + "/old", dir + "/new"] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            try files.copyItem(atPath: launcher, toPath: oldBinary)
            try files.copyItem(atPath: launcher, toPath: newBinary)
            // The app beside each build is this test process's own binary: its clients are the app once they answer the
            // challenge with `appKey`, given to the host on stdin as the app does.
            let runner = try #require(HostServer.executable(of: getpid()))
            for folder in ["old", "new"] { try files.copyItem(atPath: runner, toPath: dir + "/\(folder)/VibeSwitcher") }
            let now = Date().timeIntervalSince1970.rounded(.down)
            try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 2_000)], ofItemAtPath: oldBinary)
            try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 1_000)], ofItemAtPath: newBinary)
            newBuild = HostBuild.id(ofExecutableAt: newBinary)

            process.executableURL = URL(fileURLWithPath: oldBinary)
            process.arguments = ["--socket", socket, "--lock", dir + "/h.lock", "--idle-exit", "600", "--log", dir + "/session.log",
                                 AppProof.hostStdinFlag]
            process.environment = ["HOME": dir + "/home", "CFFIXED_USER_HOME": dir + "/home", "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin",
                                   "TMPDIR": dir + "/"]
            files.createFile(atPath: dir + "/host.log", contents: nil)
            let log = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/host.log"))
            process.standardOutput = log
            process.standardError = log
            let stdin = Pipe()
            stdin.fileHandleForWriting.write(appKey.data)
            try stdin.fileHandleForWriting.close()
            process.standardInput = stdin
            try process.run()
            // Should the runner die before `stop`, the host goes with it.
            let watchdog = Process()
            watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
            watchdog.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do kill -0 \(getpid()) 2>/dev/null || exec kill -KILL \(pid); sleep 1; done"]
            watchdog.standardInput = FileHandle.nullDevice
            watchdog.standardOutput = FileHandle.nullDevice
            watchdog.standardError = FileHandle.nullDevice
            try? watchdog.run()
            self.watchdog = watchdog
        }

        var pid: pid_t { process.processIdentifier }
        var log: String { (try? String(contentsOfFile: dir + "/host.log", encoding: .utf8)) ?? "" }

        /// A build whose probe waits `seconds` before it runs, then the new build itself.
        func slowBuild(_ seconds: Int) -> String {
            let path = dir + "/slow-host"
            FileManager.default.createFile(atPath: path, contents: Data("""
                #!/bin/sh
                case " $* " in *" --handover-probe "*) sleep \(seconds);; esac
                exec '\(newBinary)' "$@"

                """.utf8), attributes: [.posixPermissions: 0o755])
            return path
        }

        /// Ends the host (by its pid) and removes its files.
        func stop() {
            if process.isRunning {
                kill(pid, SIGTERM)
                let deadline = Date().addingTimeInterval(10)
                while process.isRunning, Date() < deadline { usleep(20_000) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }

        deinit { stop() }
    }

    final class Anchor {}

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func note(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
        var handover: [String] { lines.filter { $0.contains("handed over") || $0.contains("handover failed") } }
    }

    @Test func aNewBuildWhoseProbeTakesTwentySecondsIsHandedOverWithNoFalseFailure() async throws {
        let host = try ScratchHost()
        defer { host.stop() }
        // A live session first (an empty outdated host is replaced, not handed over), by a client that takes any build.
        let spawner = HostClient(socketPath: host.socket, appKey: { host.appKey }, bundledBuild: { 0 }, note: { _ in })
        #expect(await until { spawner.connectIfRunning(); return spawner.state == .connected }, "\(host.log)")
        var spawned: Result<HostSession, HostClientError>?
        spawner.spawn(SpawnRequest(cwd: "/tmp", command: "sleep 600", env: [:], cols: 80, rows: 24, keepShell: false, label: "Sleep",
                                   agent: nil)) { spawned = $0 }
        #expect(await until { spawned != nil })
        let session = try #require(spawned).get()
        defer { kill(-session.childPID, SIGKILL) }

        let log = Log()
        let slow = host.slowBuild(20)
        let client = HostClient(socketPath: host.socket, appKey: { host.appKey }, bundledBuild: { host.newBuild },
                                handoverExecutable: { slow }, note: { log.note($0) })
        client.connectIfRunning()
        #expect(await until { log.lines.contains { $0.hasPrefix("host: handing over") } }, "\(log.lines)")
        #expect(await until { client.state == .connected || !log.handover.isEmpty }, "\(log.lines)\n\(host.log)")
        #expect(await until { client.state == .connected }, "\(log.lines)\n\(host.log)")
        #expect(log.handover == ["host: handed over (pid \(host.pid), build \(host.newBuild))"], "\(log.lines)\n\(host.log)")
        #expect(log.lines.contains("host: handover: waiting for the new build's probe, 15 s"), "\(log.lines)")
        #expect(client.sessions.map(\.id) == [session.id])
    }
}
