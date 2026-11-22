import Foundation
import Testing
import VibeCore
import VibeHost
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
        let connection = try host.dialer.connect(queue: queue, patience: 5)
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

    /// The stop ends what its sessions left running before it returns: a program that ignores the hangup and the
    /// terminate the host's stop sends (the host's SIGKILL comes 5 s later, after the stop has returned), and a child it
    /// detached (no longer under the program when the stop lists it), each writing into the sessions' `HOME`, which the
    /// scratch removes next.
    @Test func theStopEndsWhatItsSessionsLeftRunning() async throws {
        let host = try NodeTestHost(scratch)
        defer { host.stop() }
        let pids = host.home.appendingPathComponent("pids")
        let loop = "trap '' HUP TERM; echo $$ >> \(FakeClaude.quoted(pids.path)); while :; do date >> \"$HOME/late\"; sleep 0.05; done"
        let session = try await host.spawn("( sh -c \(FakeClaude.quoted(loop)) & ); \(loop)")
        func written() -> [pid_t] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        }
        #expect(await eventually { written().count == 2 }, "session \(session.id) started \(written())")
        let links = written().compactMap(Platform.Processes.link)
        #expect(links.count == 2 && links.allSatisfy(ScratchNode.runs), "\(links)")
        await offPool { host.stop() }
        let left = links.filter(ScratchNode.runs)
        #expect(left.isEmpty, "still running once the stop returned: \(left.map(\.pid))")
    }

    /// The scratch host's own writer, the host's log (a held resize line, an input unit's hold, a session's exit),
    /// can write after the stop returned, while or after the scratch removes the folder: it writes nowhere, so its
    /// folder never comes back.
    @Test func aLineTheHostLogsAfterItsStopLeavesNothing() throws {
        let host = try NodeTestHost(scratch)
        host.stop()
        // The stop removed it already (the host's folder is its socket's short folder); as the scratch would, else.
        try? FileManager.default.removeItem(at: host.folder)
        host.server.note("host: a line after the stop")
        #expect(!FileManager.default.fileExists(atPath: host.folder.path))
    }

    /// What a connection was sent, from its queue.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [HostEventEnvelope] = []
        func add(_ envelope: HostEventEnvelope) { lock.withLock { all.append(envelope) } }
        func reply(to seq: Int) -> HostEvent? { lock.withLock { all.first { $0.replyTo == seq }?.event } }
    }
}

/// What the scratch hosts' stops wait for and end (`ScratchNode.descendants`), on a process table of the test's own.
@Suite struct ScratchStopTests {
    /// A child listed under its parent that ended before its link was read, its pid gone to a process of someone
    /// else's, isn't taken for it, nor is anything under that process: the stop would kill them 10 s on.
    @Test func aChildWhosePidWentToAnotherProcessIsntItsParents() {
        // 10 has children 11 and 12; 12 ended after the listing and its pid is now another process's (its parent 99),
        // which has a child of its own, 13. 11 has a child, 14.
        let children: [pid_t: [pid_t]] = [10: [11, 12], 11: [14], 12: [13]]
        let parents: [pid_t: pid_t] = [11: 10, 12: 99, 13: 12, 14: 11]
        let found = ScratchNode.descendants(of: 10, children: { children[$0] ?? [] }) { pid in
            parents[pid].map { Platform.Processes.Link(pid: pid, parent: $0, startTicks: UInt64(pid), terminal: nil) }
        }
        #expect(found.map(\.pid).sorted() == [11, 14], "\(found)")
    }
}
