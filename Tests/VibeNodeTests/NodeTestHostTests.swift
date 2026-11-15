import Foundation
import Testing
import VibeCore
import VibeNode

/// The engine's scratch host (`NodeTestHost`): the test process is its app through the connector, and each has a root
/// and a `HOME` of its own.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(10)))
struct NodeTestHostTests {
    private let scratch = Scratch()

    @Test func theTestProcessIsTheScratchHostsApp() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        #expect(host.appConnector != nil && HostConnection.connector(for: host.socket) == host.appConnector)
        let repository = host.folder.appendingPathComponent("repository")
        try await scratchRepository(repository)
        // Only the app starts a lead (`LeadVault.Book`'s rule): a grant is the host taking this process as its app.
        let vault = host.vault
        let grant = try await offPool { try vault.issue(role: .lead, root: repository.path, task: nil) }
        #expect(!grant.isEmpty)
        #expect(host.book.answer(.current(role: .lead, root: repository.path, task: nil), from: .app) != .member(nil))

        // The dialer's connection is the app's too: welcomed, with the vault listed and the host's sessions shown (a
        // client that came by the socket's path is shown none).
        let session = try await host.spawn("sleep 600")
        let queue = DispatchQueue(label: "node-test-host-dialer")
        let events = Events()
        let connection = try host.dialer.connect(queue: queue)
        defer { connection.close() }
        connection.onEvent = { events.add($0) }
        let seq = try connection.send(.hello(protocolVersion: HostProtocol.version, app: "NodeTestHostTests"))
        #expect(await eventually { events.reply(to: seq) != nil })
        guard case .welcome(_, let build, let sessions, let capabilities, _, _)? = events.reply(to: seq) else {
            Issue.record("no welcome: \(String(describing: events.reply(to: seq)))"); return
        }
        #expect(build == 42 && capabilities?.contains(HostProtocol.Capability.leadVault) == true)
        #expect(sessions.map(\.id).contains(session.id), "the dialer was shown \(sessions.map(\.id)), not \(session.id)")
    }

    @Test func eachTestHostHasItsOwnHome() async throws {
        let first = try NodeTestHost(scratch), second = try NodeTestHost(scratch)
        defer {
            first.stop()
            second.stop()
        }
        #expect(first.root != second.root && first.home != second.home && first.socket != second.socket)
        // Each vault reads its agents' config from, and keeps its seal copies in, its sessions' HOME.
        #expect(first.book.configHome == first.home.path && second.book.configHome == second.home.path,
                "\(first.book.configHome), \(second.book.configHome)")
        let ours = [VibePaths.root.standardizedFileURL.path, NSHomeDirectory(), ProcessInfo.processInfo.environment["HOME"] ?? ""]
        // What each host's sessions see: their HOME, their PATH, and where VibeSwitcher's folder is for them.
        var seen: [String] = []
        for host in [first, second] {
            // Written to a file, not read off the screen: a scratch HOME's path can be longer than the screen is wide.
            let said = host.folder.appendingPathComponent("environment.txt")
            let session = try await host.spawn("printf 'home=[%s] path=[%s] own=[%s]' \"$HOME\" \"$PATH\" \"$VIBESWITCHER_HOME\" > \(FakeClaude.quoted(said.path)).part"
                                               + " && mv \(FakeClaude.quoted(said.path)).part \(FakeClaude.quoted(said.path)); sleep 600")
            #expect(await eventually { FileManager.default.fileExists(atPath: said.path) }, "session \(session.id) wrote nothing")
            let line = (try? String(contentsOf: said, encoding: .utf8)) ?? ""
            #expect(line.contains("home=[\(host.home.path)]") && line.contains("path=[/usr/bin:/bin]") && line.contains("own=[]"), "\(line)")
            #expect(!ours.contains { !$0.isEmpty && line.contains("home=[\($0)]") }, "\(line)")
            #expect(!ours.contains(host.root.standardizedFileURL.path) && !ours.contains(host.home.path))
            seen.append(line)
        }
        #expect(seen.count == 2 && seen[0] != seen[1])
    }

    /// What a connection was sent, from its queue.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [HostEventEnvelope] = []
        func add(_ envelope: HostEventEnvelope) { lock.withLock { all.append(envelope) } }
        func reply(to seq: Int) -> HostEvent? { lock.withLock { all.first { $0.replyTo == seq }?.event } }
    }
}
