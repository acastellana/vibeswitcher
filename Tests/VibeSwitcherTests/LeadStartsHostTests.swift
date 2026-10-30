import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A lead started with no session host running (a fresh Mac, a first launch with no session open): the start launches
/// the host, as opening a session does, before its first vault call; it used to call the vault first and say "the
/// session host didn't answer (connect: connection refused)" (the user's second Mac, 2026-10-30). A scratch host the
/// client starts, on its own socket and lock, ending with this process; never the user's.
@MainActor
@Suite(hostTestLimit) struct LeadStartsHostTests {
    private let scratch = Scratch()
    private static let host = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path

    struct World {
        let dir: String
        let root: String
        let client: HostClient
        let controller: LeadController
        /// The same vault, for the test's own looks (not counted in `calls`).
        let vault: LeadVault
        /// The vault's calls, in order: whether each was answered (nil: the host couldn't be asked).
        let calls: Calls
        /// The alerts the start showed: title and text.
        let alerts: Alerts

        /// Every host this world started (the script appends its pid), with what it runs (its own process group).
        func stop() {
            let started = (try? String(contentsOfFile: dir + "/starts", encoding: .utf8)) ?? ""
            for pid in started.split(separator: "\n").compactMap({ pid_t($0) }) {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                _ = BenchHostTests.waitForExit(of: pid, timeout: hangGuard)
            }
        }

        var starts: Int { ((try? String(contentsOfFile: dir + "/starts", encoding: .utf8)) ?? "").split(separator: "\n").count }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String?] = []
        func add(_ error: String?) { lock.withLock { list.append(error) } }
        var all: [String?] { lock.withLock { list } }
    }

    final class Alerts {
        var list: [(title: String, text: String)] = []
    }

    /// A repository with a commit, and an app whose host isn't running: `script` (sh) is what starting it runs, given
    /// the built host's path. The built host is copied beside this test process's own binary as the app's (it takes
    /// this process as VibeSwitcher once it proves itself with the key the client gives the host on stdin).
    func world(script: (_ host: String) -> String) throws -> World {
        AppStatus.enabled = false
        let dir = try scratch.shortFolder("vslh")
        let files = FileManager.default
        try files.createDirectory(atPath: dir + "/build", withIntermediateDirectories: true)
        try files.copyItem(atPath: Self.host, toPath: dir + "/build/vibeswitcher-host")
        try files.copyItem(atPath: try #require(HostServer.executable(of: getpid())), toPath: dir + "/build/VibeSwitcher")
        let path = dir + "/vibeswitcher-host"
        try Data("#!/bin/sh\necho $$ >> '\(dir)/starts'\n\(script(dir + "/build/vibeswitcher-host"))\n".utf8).write(to: URL(fileURLWithPath: path))
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try files.createDirectory(at: VibePaths.hostLog.deletingLastPathComponent(), withIntermediateDirectories: true)

        let socket = dir + "/h.sock"
        let key = HostClient.ownKey()
        let client = HostClient(socketPath: socket, appKey: key, bundledBuild: { 0 }, note: { _ in })
        client.confirmKeyReset = { _, _ in false }
        client.hostPath = path
        client.hostArguments = ["--socket", socket, "--lock", dir + "/h.lock", "--log", dir + "/session.log"] + HostClient.endsWithThisProcess

        let repository = scratch.url("project")
        try files.createDirectory(at: repository, withIntermediateDirectories: true)
        let root = repository.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)

        // The app's vault, as `LeadVault.standard` asks it, on this host's socket with this client's key.
        let calls = Calls()
        let vault = { (calls: Calls?) in LeadVault(folder: scratch.url("vault")) { request in
            do {
                let reply = try HostCall.request(.vault(request), socket: socket, appKey: key(), timeout: 5)
                calls?.add(nil)
                switch reply {
                case .vault(let reply): return reply
                case .error(let message): return .refused(message)
                default: return .refused("The session host answered something else.")
                }
            } catch {
                calls?.add("\(request): \(error)")
                throw error
            }
        } }
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { URL(fileURLWithPath: dir) }, cwd: { _ in nil },
                                                         arguments: { _ in [] }))
        let inbox = scratch.url("inbox")
        try files.createDirectory(at: inbox, withIntermediateDirectories: true)
        let controller = LeadController(host: client, store: store, vault: vault(calls), inbox: inbox, home: scratch.url("home").path) { _ in
            "exec /bin/sleep 600"
        }
        controller.answersTrust = false
        controller.preflight = { _ in nil }
        let alerts = Alerts()
        controller.confirm = { title, text, buttons in alerts.list.append((title, text)); return buttons.count - 1 }
        return World(dir: dir, root: root, client: client, controller: controller, vault: vault(nil), calls: calls, alerts: alerts)
    }

    @Test func aLeadStartedWithNoHostRunningStartsTheHostFirst() async throws {
        let world = try world { "exec '\($0)' \"$@\"" }
        defer { world.stop() }
        #expect(world.client.state == .notRunning)
        world.controller.startLead(in: world.root)
        #expect(await until { world.vault.current(.lead, root: world.root, task: nil)?.session != nil || !world.alerts.list.isEmpty })
        #expect(world.alerts.list.isEmpty, "\(world.alerts.list)")
        // Its first vault call was answered: the host was up before it.
        #expect(world.calls.all.first == .some(nil), "\(world.calls.all)")
        #expect(world.client.state == .connected)
        #expect(world.starts == 1)
        // The lead's session ends before its host does.
        if let session = world.vault.current(.lead, root: world.root, task: nil)?.session.flatMap(UUID.init(uuidString:)) {
            world.client.kill(session)
            #expect(await until { world.client.sessions.first { $0.id == session }?.isLive != true })
        }
    }

    @Test func aHostThatDoesntStartSaysSoNotConnectionRefused() async throws {
        let world = try world { _ in "exit 1" }
        defer { world.stop() }
        world.controller.startLead(in: world.root)
        #expect(await until { !world.alerts.list.isEmpty })
        let alert = try #require(world.alerts.list.first)
        #expect(alert.title == "The lead didn't start.")
        #expect(alert.text == "The session host didn't start. See ~/.vibeswitcher/host.log.", "\(alert.text)")
        // The vault wasn't asked of a host that isn't there.
        #expect(world.calls.all.isEmpty, "\(world.calls.all)")
    }

    /// A host already starting (a session asked for it a moment before) is waited for: a second isn't started beside it.
    @Test func aStartWhileTheHostStartsWaitsForIt() async throws {
        // Late to listen: the lead start comes while it still starts.
        let world = try world { "sleep 1\nexec '\($0)' \"$@\"" }
        defer { world.stop() }
        var first: String??
        world.client.ensureHost { first = .some($0) }
        #expect(await until { world.starts == 1 })
        var second: String??
        world.client.ensureHost { second = .some($0) }
        #expect(await until { first != nil && second != nil })
        #expect(first == .some(nil) && second == .some(nil), "\(String(describing: first)), \(String(describing: second))")
        #expect(world.starts == 1)
    }
}

private final class Anchor {}
