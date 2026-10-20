import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A lead through a relaunch of the app (an install): a scratch host (its own socket, lock and key; never the user's)
/// keeps the lead's session running, and a new app's lead controller finds it there. It keeps its role; a new lead
/// starts only when you ask for one, after a question.
@MainActor
struct LeadRelaunchTests {
    let temp = Scratch()

    /// The lead's tool server as seen from a session: only its sessions are asked for (to name the new lead).
    final class Seat: LeadRuntime {
        let list: () -> [HostSession]
        init(_ list: @escaping () -> [HostSession]) { self.list = list }
        let server = "/App/vibeswitcher-mcp"
        func claudeCommand(root: String) -> String { "claude" }
        func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String, trust: Bool) throws -> String { throw CancellationError() }
        func kill(_ session: String) {}
        func forget(_ session: String) {}
        func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
            throw CancellationError()
        }
        func sessions() throws -> [LeadSessionInfo] {
            list().map { LeadSessionInfo(id: $0.id.uuidString, cwd: $0.cwd, label: $0.label, live: $0.isLive, status: nil, tty: $0.tty) }
        }
        func transcript(of session: String) throws -> String? { nil }
        func currentAgent() -> LeadAgent? { nil }
        func isRunning(_ agent: LeadAgent) -> Bool { false }
        func loadAverage() -> Double? { 0.5 }
    }

    struct World {
        let server: HostServer
        let socket: String
        let key: SymmetricKey
        let root: String
        let book: LeadVault.Book
        let vault: LeadVault
        let stateDir: URL

        var project: String { (root as NSString).lastPathComponent }

        func stop() {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }
    }

    func world() throws -> World {
        AppStatus.enabled = false
        let url = temp.url("relaunch")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)

        let launcher = Bundle(for: RelaunchAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
        let socket = try temp.shortFolder("vsh-lr") + "/h.sock"
        let key = SymmetricKey(size: .bits256)
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": temp.url("home").path],
                                       hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
        config.idleExit = nil
        config.appKey = key
        config.appExecutable = HostServer.executable(of: getpid())
        let server = HostServer(config: config)
        try server.start()
        let book = LeadVault.Book()
        let stateDir = temp.url("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return World(server: server, socket: socket, key: key, root: root, book: book,
                     vault: book.vault(folder: temp.url("vault"), as: { .app }), stateDir: stateDir)
    }

    /// The app before the install: it started the lead (its role bound to its session), whose session runs on.
    func leadStarted(in world: World) async throws -> (session: HostSession, grant: String) {
        let before = HostClient(socketPath: world.socket, appKey: { world.key })
        before.connectIfRunning()
        #expect(await until { before.state == .connected })
        var result: Result<HostSession, HostClientError>?
        before.spawn(SpawnRequest(cwd: world.root, command: "exec /bin/sleep 600", env: [:], cols: 80, rows: 24, keepShell: false,
                                  label: "Lead · \(world.project)", agent: "claude")) { result = $0 }
        #expect(await until { result != nil })
        let session = try #require(result).get()
        let grant = try world.vault.startLead(root: world.root, branch: "main")
        try world.vault.bind(grant, root: world.root, session: session.id.uuidString)
        return (session, grant)
    }

    /// The app after the install: its own client and lead controller, connecting to the host that kept the sessions.
    func relaunched(_ world: World) -> (HostClient, LeadController) {
        let host = HostClient(socketPath: world.socket, appKey: { world.key })
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { world.stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        // Its inboxes and home are scratch ones too: a test never reads or writes the user's ~/.vibeswitcher.
        let inbox = temp.url("inbox")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let controller = LeadController(host: host, store: store, vault: world.vault, inbox: inbox, home: temp.url("home").path) { _ in
            "exec /bin/sleep 600"
        }
        controller.answersTrust = false
        return (host, controller)
    }

    @Test func aStartAskedBeforeTheHostsWelcomeWaitsForItsSessions() {
        let running = UUID()
        // Relaunched, the session list is empty until the host's welcome: no lead start is decided on it.
        #expect(LeadController.plan(hostState: .connecting, running: nil, holdsRole: nil, fromUser: true) == .wait)
        #expect(LeadController.plan(hostState: .connected, running: nil, holdsRole: nil, fromUser: true) == .start)
        #expect(LeadController.plan(hostState: .connected, running: running, holdsRole: true, fromUser: true) == .show(running))
        // Without its role: you're asked; a start from outside the app (anything can post it) never replaces it, nor
        // does one while the vault can't be asked.
        #expect(LeadController.plan(hostState: .connected, running: running, holdsRole: false, fromUser: true) == .askToReplace(running))
        #expect(LeadController.plan(hostState: .connected, running: running, holdsRole: false, fromUser: false) == .show(running))
        #expect(LeadController.plan(hostState: .connected, running: running, holdsRole: nil, fromUser: true) == .show(running))
    }

    @Test func aLeadRunningAtRelaunchKeepsItsRoleAndNoNewLeadStarts() async throws {
        let world = try world()
        defer { world.stop() }
        let (lead, grant) = try await leadStarted(in: world)

        let (host, controller) = relaunched(world)
        var asked: [String] = []
        var selected: [UUID] = []
        controller.confirm = { title, _, _ in asked.append(title); return 0 }
        controller.select = { selected.append($0) }
        // You click Project Lead as the app comes back, before the host has said which sessions run (its welcome
        // held back): the start waits for them.
        world.server.queue.suspend()
        host.connectIfRunning()
        #expect(host.state == .connecting)
        controller.startLead(in: world.root)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(selected.isEmpty && asked.isEmpty)
        world.server.queue.resume()
        #expect(await until { host.state == .connected })

        // The lead's role is bound to its session again, the running lead is shown, and nothing else starts.
        #expect(await until { controller.keptLeads[world.root] == lead.id })
        #expect(await until { selected == [lead.id] })
        let current = try #require(world.vault.current(.lead, root: world.root, task: nil))
        #expect(current.id == grant && current.session == lead.id.uuidString)
        controller.startLead(in: world.root)
        #expect(await until { selected == [lead.id, lead.id] })
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(host.sessions.map(\.id) == [lead.id])
        #expect(asked.isEmpty)
        #expect(world.vault.current(.lead, root: world.root, task: nil)?.id == grant)
    }

    /// The user's own home, from the user database (HOME and CFFIXED_USER_HOME point at a scratch one in a test run):
    /// read only.
    static var usersHome: URL {
        URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/nonexistent", isDirectory: true)
    }

    /// The end of a log file: its size, and its last bytes.
    struct LogEnd: Equatable {
        let size: Int
        let tail: Data

        init(_ file: URL) {
            let data = (try? Data(contentsOf: file)) ?? Data()
            size = data.count
            tail = data.suffix(256)
        }
    }

    /// 2026-10-19: tests on the user's home (the load script's runs) wrote 'lead: kept the running lead of
    /// relaunch-DABE6BDC-…' into the user's ~/.vibeswitcher/debug/app.log. A relaunch notes the lead it kept (in memory,
    /// as the app does), and the user's app.log is left as it was: what it held is still there, and nothing that
    /// came after it (the running app writes there meanwhile) is from this test.
    @Test func aRelaunchLeavesTheUsersAppLogAlone() async throws {
        let log = Self.usersHome.appendingPathComponent(".vibeswitcher/debug/app.log")
        let before = LogEnd(log)
        let world = try world()
        defer { world.stop() }
        let (lead, _) = try await leadStarted(in: world)
        let (host, controller) = relaunched(world)
        controller.confirm = { _, _, _ in 0 }
        controller.select = { _ in }
        host.connectIfRunning()
        #expect(await until { controller.keptLeads[world.root] == lead.id })
        let kept = "lead: kept the running lead of \(world.project) (session \(lead.id.uuidString.prefix(8)))"
        #expect(Breadcrumbs.shared.lines.contains { $0.hasSuffix(kept) })
        Breadcrumbs.shared.flush()

        let data = (try? Data(contentsOf: log)) ?? Data()
        let rotated = (try? Data(contentsOf: log.appendingPathExtension("1"))) ?? Data()
        if data.count >= before.size, data.prefix(before.size).suffix(256) == before.tail {
            // Only appended to since: by the running app alone.
            #expect(data.count == before.size || !String(decoding: data.dropFirst(before.size), as: UTF8.self).contains(world.project))
        } else {
            // Rotated by the running app meanwhile (app.log.1): neither holds a line of this test.
            #expect(!String(decoding: rotated + data, as: UTF8.self).contains(world.project))
        }
    }

    @Test func aNewLeadWhileOneRunsIsAskedForAndTheOldOneIsSentToIt() async throws {
        let world = try world()
        defer { world.stop() }
        let (old, grant) = try await leadStarted(in: world)
        // The old lead's tool server, started while its session held the role.
        let oldVault = world.book.vault(folder: world.vault.folder, as: { .session(old.id.uuidString) })
        let (host, controller) = relaunched(world)
        let oldTools = LeadToolset(root: world.root, runtime: Seat { host.sessions }, vault: oldVault)
        #expect(!oldTools.call("status", [:]).isError)
        // Then the host's vault lost it (one that started over): the session runs on without its role.
        try world.vault.revoke(grant, root: world.root)

        var answer = 0
        var asked: [String] = []
        var selected: [UUID] = []
        controller.confirm = { title, _, buttons in asked.append(title); return min(answer, buttons.count - 1) }
        controller.select = { selected.append($0) }
        host.connectIfRunning()
        #expect(await until { host.state == .connected })
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Relaunched, the app gives it no role back (the vault binds it to no session) and starts nothing by itself.
        #expect(controller.keptLeads[world.root] == nil)
        #expect(world.vault.current(.lead, root: world.root, task: nil) == nil)

        // Project Lead: you're asked first. Showing the running lead starts nothing.
        controller.startLead(in: world.root)
        #expect(await until { asked.count == 1 && selected == [old.id] })
        #expect(asked.first?.contains("running, but without its role") == true)
        #expect(host.sessions.count == 1)

        // Asked again, you start a new lead: its session holds the role.
        answer = 1
        controller.startLead(in: world.root)
        #expect(await until { asked.count == 2 && host.sessions.count == 2 })
        let new = try #require(host.sessions.first { $0.id != old.id })
        #expect(new.label == "Lead · \(world.project)")
        #expect(await until { world.vault.current(.lead, root: world.root, task: nil)?.session == new.id.uuidString })
        #expect(await until { selected.last == new.id })

        // The old lead's tools say which session to continue in, and don't send it to /mcp.
        let refused = oldTools.call("status", [:])
        #expect(refused.isError)
        #expect(refused.text.contains("VibeSwitcher started a new lead"), "\(refused.text)")
        #expect(refused.text.contains("session \(new.id.uuidString.prefix(8))"))
        #expect(refused.text.contains("continue in that session"))
        #expect(refused.text.contains("Messages typed into this session go to that lead"))
        #expect(!refused.text.contains("/mcp"))
    }
}

private final class RelaunchAnchor {}
