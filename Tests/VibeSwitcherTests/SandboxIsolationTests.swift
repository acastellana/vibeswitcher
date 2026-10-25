import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The sandboxed app (scripts/sandbox-app.sh, `Sandbox`) a worker runs to photograph its UI change has no effect on the
/// user's real app: driven through a whole run (a fake session's chat, a message typed and sent, Settings, a sheet,
/// shots, quit), it writes nothing of its own into the real preferences or ~/.vibeswitcher, leaves the real host's
/// socket and sessions alone, reads no Keychain item, and is never active or on screen. A run's own marker (typed into
/// the composer, so it lands in the sandbox's defaults, outbox and transcript) is looked for on the real side.
struct SandboxIsolationTests {
    private let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The real side, read only (never written): the account's own home, not the run's scratch one.
    struct RealSide {
        static var home: String { VibePaths.accountHome }
        static var root: String { home + "/.vibeswitcher" }
        static func preferences(_ domain: String) -> Data? {
            FileManager.default.contents(atPath: home + "/Library/Preferences/\(domain).plist")
        }

        struct Entry: Equatable { var size: Int64; var modified: Double; var inode: UInt64 }

        /// Each file and folder under the real ~/.vibeswitcher (symbolic links not followed), by path.
        static func tree() -> [String: Entry] {
            var entries: [String: Entry] = [:]
            guard let walk = FileManager.default.enumerator(atPath: root) else { return entries }
            for case let relative as String in walk {
                var info = stat()
                guard lstat(root + "/" + relative, &info) == 0 else { continue }
                entries[relative] = Entry(size: Int64(info.st_size),
                                          modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                                          inode: UInt64(info.st_ino))
            }
            return entries
        }

        /// The real host's socket: its inode and when it was made (nil: there's none).
        static func socket() -> Entry? {
            var info = stat()
            guard lstat(root + "/host.sock", &info) == 0 else { return nil }
            return Entry(size: 0, modified: Double(info.st_mtimespec.tv_sec), inode: UInt64(info.st_ino))
        }

        /// The user's session hosts (started on the default lock: no --lock among their arguments), by pid, each with
        /// its sessions' processes (its children) and their arguments.
        static func hosts() -> [Int32: [Int32: [String]]] {
            let table = ProcessTable.snapshot()
            var hosts: [Int32: [Int32: [String]]] = [:]
            for host in table.values where host.comm.hasPrefix("vibeswitcher-hos") {
                let arguments = ProcessTable.readArguments(pid: host.pid)
                guard !arguments.isEmpty, !arguments.contains("--lock") else { continue }
                hosts[host.pid] = Dictionary(uniqueKeysWithValues: table.values.filter { $0.ppid == host.pid }
                    .map { ($0.pid, ProcessTable.readArguments(pid: $0.pid)) })
            }
            return hosts
        }
    }

    /// Runs scripts/sandbox-app.sh with `arguments` (after the options that keep it in this test's scratch): its exit
    /// status and what it printed.
    func sandbox(_ arguments: String..., dir: URL, shots: URL, app: URL) throws -> (status: Int32, output: String) {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = [Self.repo.appendingPathComponent("scripts/sandbox-app.sh").path, "--binary", app.path,
                            "--dir", dir.path, "--shots", shots.path, "--minutes", "5", "--wait", "\(Int(hangGuard))"] + arguments
        let output = Pipe()
        script.standardOutput = output
        script.standardError = output
        script.standardInput = FileHandle.nullDevice
        try script.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        script.waitUntilExit()
        return (script.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Whether `condition` holds within the hang guard, checked every 50 ms (a file the sandbox writes as it goes).
    func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(hangGuard)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    static func contains(_ data: Data?, _ text: String) -> Bool {
        guard let data else { return false }
        return data.range(of: Data(text.utf8)) != nil
    }

    @Test func aSandboxRunLeavesTheRealAppsStateHostAndKeychainAlone() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        try #require(FileManager.default.isExecutableFile(atPath: app.path))
        let dir = scratch.url("sandbox-dir"), shots = scratch.url("sandbox-shots")
        let marker = "sandbox-isolation-\(UUID().uuidString)"

        // The real side before.
        let plistBefore = RealSide.preferences("dev.vibeswitcher.VibeSwitcher")
        let treeBefore = RealSide.tree()
        let socketBefore = RealSide.socket()
        let hostsBefore = RealSide.hosts()
        let started = Date()

        var state = ""
        var pids: [Int32] = []
        var quitSeen = false
        defer {
            // Only on a failure (a clean run's quit was seen through): this test's own sandbox, and what it started.
            if !quitSeen {
                _ = try? sandbox("quit", dir: dir, shots: shots, app: app)
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        let run = try sandbox("run", dir: dir, shots: shots, app: app)
        try #require(run.status == 0, "the sandbox didn't start:\n\(run.output)")
        func command(_ words: [String]) throws -> String {
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/bin/bash")
            script.arguments = [Self.repo.appendingPathComponent("scripts/sandbox-app.sh").path, "--dir", dir.path,
                                "--wait", "\(Int(hangGuard))"] + words
            let output = Pipe()
            script.standardOutput = output
            script.standardError = output
            script.standardInput = FileHandle.nullDevice
            try script.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            script.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            #expect(script.terminationStatus == 0, "\(words.joined(separator: " ")): \(text)")
            return text
        }

        let status = try command(["status"])
        state = try #require(status.split(separator: "\n").first { $0.hasPrefix("state ") }.map { String($0.dropFirst("state ".count)) })
        let pid = try #require(status.split(separator: "\n").first { $0.hasPrefix("pid ") }.flatMap { Int32($0.dropFirst("pid ".count)) })
        pids.append(pid)
        let table = ProcessTable.snapshot()
        let host = try #require(table.values.first { $0.ppid == pid && $0.comm.hasPrefix("vibeswitcher-hos") }, "no host under the sandbox")
        pids.append(host.pid)

        // Its own host: on its own lock (a host on the user's lock reads its vault key from the Keychain) in the
        // sandbox's folder, ending with it.
        let hostArguments = ProcessTable.readArguments(pid: host.pid)
        let lock = try #require(hostArguments.firstIndex(of: "--lock").map { hostArguments[$0 + 1] })
        // One spelling for each place: /private/tmp and /tmp, /private/var and /var are the same.
        func spelled(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        #expect(spelled(lock).hasPrefix(spelled(state) + "/"), "the sandbox's host lock: \(lock)")
        #expect(hostArguments.contains("--exit-with") && hostArguments.contains(String(pid)))
        #expect(status.contains("host connected on "), "\(status)")

        _ = try command(["chat"])
        _ = try command(["type", marker])
        // The draft is the sandbox's: its defaults, in its own folder, hold it (and the window's frame, off screen).
        let defaults = state + "/defaults.plist"
        #expect(eventually { Self.contains(FileManager.default.contents(atPath: defaults), marker) }, "the sandbox's defaults never held the draft")
        #expect(eventually { Self.contains(FileManager.default.contents(atPath: defaults), "-20000 -20000 1280 800") })
        _ = try command(["send"])
        // The fake Claude took it: it's in the session's transcript, in the sandbox's home.
        let projects = state + "/home/.claude/projects"
        #expect(eventually {
            (FileManager.default.subpaths(atPath: projects) ?? []).contains { Self.contains(FileManager.default.contents(atPath: projects + "/" + $0), "Got: " + marker) }
        }, "the fake Claude never answered")
        _ = try command(["settings", "agents"])
        _ = try command(["sheet", "new-project"])
        let shot = try command(["shot", "isolation"])
        for name in ["main", "settings", "sheet-new-project"] {
            for mode in ["light", "dark"] {
                let file = shots.appendingPathComponent("isolation-\(name)-\(mode).png").path
                #expect(shot.contains(file), "\(shot)")
                let png = FileManager.default.contents(atPath: file) ?? Data()
                #expect(png.count > 10_000 && png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(file): \(png.count) bytes")
            }
        }

        // While it runs: never active, never on screen, nothing refused, its window off every screen.
        let during = try command(["status"])
        #expect(during.contains("active false, activation policy 2"), "\(during)")
        #expect(!during.contains("\non screen ") && !during.contains("\nrefused "), "\(during)")
        #expect(during.contains("{{-20000, -20000}, {1280, 800}} alpha 0.0"), "\(during)")
        // The user's hosts run none of its sessions.
        for (realHost, sessions) in RealSide.hosts() {
            for (session, arguments) in sessions {
                #expect(!arguments.contains { $0.contains(state) || $0.contains(marker) }, "the real host \(realHost) runs the sandbox's \(session): \(arguments)")
            }
        }
        // No Keychain item read: the app's Keychain stores are made by AppDelegate alone (KeychainLintTests), which the
        // sandbox never makes, and its host, on its own lock, keeps its vault in memory: never sealed with a Keychain key.
        let sandboxSource = try String(contentsOf: Self.repo.appendingPathComponent("Sources/VibeSwitcher/Sandbox.swift"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for reach in ["AppDelegate", "Keychain" + "Store(", "Keychain" + "Secret(", "Sec" + "Item", "Sec" + "Keychain", "keychain" + "Key("] {
            #expect(!sandboxSource.contains(reach), "Sandbox.swift reaches the Keychain: \(reach)")
        }
        #expect(sandboxSource.contains("AppProof.MemoryStore()") && sandboxSource.contains("AppProof.MemorySecret()"))
        #expect(!FileManager.default.fileExists(atPath: state + "/home/.vibeswitcher/lead/vault.sealed"))

        _ = try command(["quit"])
        #expect(BenchHostTests.waitForExit(of: pid, timeout: hangGuard), "the sandbox didn't quit")
        let hostGone = BenchHostTests.waitForExit(of: host.pid, timeout: hangGuard)
        #expect(hostGone, "the sandbox's host outlived it")
        quitSeen = hostGone && kill(pid, 0) != 0
        #expect(!FileManager.default.fileExists(atPath: state), "quit left the state folder")

        // The real side after. The real preferences: unchanged, or (the user's app wrote them meanwhile) with nothing
        // of the sandbox's in them.
        let plistAfter = RealSide.preferences("dev.vibeswitcher.VibeSwitcher")
        if plistAfter.map({ SHA256.hash(data: $0) }) != plistBefore.map({ SHA256.hash(data: $0) }) {
            #expect(!Self.contains(plistAfter, marker) && !Self.contains(plistAfter, "-20000 -20000"), "the real preferences hold the sandbox's")
        }
        // An unbundled build's defaults domain (the benches') neither.
        let unbundled = RealSide.preferences("VibeSwitcher")
        #expect(!Self.contains(unbundled, marker) && !Self.contains(unbundled, "-20000 -20000 1280 800"))
        // ~/.vibeswitcher: what changed during the run (the user's app, host and sessions write there all the time)
        // holds nothing of the sandbox's.
        let treeAfter = RealSide.tree()
        for (path, entry) in treeAfter where treeBefore[path] != entry && entry.size < 16_000_000 {
            let data = FileManager.default.contents(atPath: RealSide.root + "/" + path)
            #expect(!Self.contains(data, marker) && !Self.contains(data, state), "the real ~/.vibeswitcher/\(path) holds the sandbox's")
        }
        #expect(treeAfter.keys.filter { $0.contains("sandbox-host") }.isEmpty)
        // The real host's socket: the same one, and its host still there.
        #expect(RealSide.socket() == socketBefore, "the real host's socket changed")
        let hostsAfter = RealSide.hosts()
        for realHost in hostsBefore.keys where kill(realHost, 0) == 0 {
            // Its sessions now: those that were there, less any that ended by themselves, plus any the user's work
            // started; none of them the sandbox's.
            for (session, arguments) in hostsAfter[realHost] ?? [:] where hostsBefore[realHost]?[session] == nil {
                #expect(!arguments.contains { $0.contains(state) || $0.contains(marker) }, "a session of the sandbox's on the real host: \(session)")
            }
        }
        #expect(Date().timeIntervalSince(started) < hangGuard)
    }
}

private final class Anchor {}
