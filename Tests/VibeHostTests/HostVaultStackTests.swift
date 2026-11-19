import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The session host takes the lead's vault calls in `HostServer.handle`, on its queue: a GCD thread, with the 512 KB
/// stack of a secondary thread. A host that overflows it ends every session. The vault's answer runs on a thread of
/// `ToolThread.stackSize` (`answerOffQueue`) while the queue waits: on the queue, a board-sized vault's calls took 156 KB
/// in a debug build and 76 KB in release (2026-11-19), over a quarter of 512 KB in debug. Each call here runs the host's
/// own code for a frame (`handle`: decoding, the vault's answer, saving the sealed vault, encoding and writing the
/// reply) inside `queue.sync` on a `StackGauge` thread, its answer on another the host is given (`vaultThread`),
/// against a vault as full as a busy board's team leaves it: the deepest of each fits a quarter of its thread's stack.
extension LeadVaultHostTests {
    /// Tasks on the board, each with its worker, verifier, done evidence, verdict, findings, approval and review.
    static let boardTasks = 120

    @Test func theHostsVaultCallsFitAQuarterOfItsQueuesStack() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try gitRepo()
        let first = Git.run(["rev-parse", "main"], in: root).output
        let full = try boardSizedVault(root: root, head: first)
        // Saved sealed after each change, as the user's host saves it (`VaultStorage`).
        let storage = VaultStorage(file: folder.appendingPathComponent("vault.sealed"), key: SymmetricKey(size: .bits256))
        let book = storage.book(handedOver: full.book.serialized)
        let host = try TestHost(vault: book)
        // The base moved since the lead left it: acceptMove reads git for it.
        try commit("b.txt", in: root)

        let queueStack = stackSize(of: host.server.queue)
        let gauge = HostGauge(host.server)
        let lead = LeadVault.Caller.session(full.lead), worker = LeadVault.Caller.session(full.workers[0])
        let task = "task-0", evidence = Self.evidence(0, checks: 12)

        try gauge.call("reportDone", .reportDone(root: root, task: task, commit: String(repeating: "c", count: 40), evidence: evidence), as: worker)
        // A verifier's audit with a dozen findings, one auditing alone and a panel of two finders (the second casts the vote).
        let verifier = try bound(book, .verifier, root: root, task: "task-1", from: full.lead)
        try gauge.call("submitVerdict", .submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "checked",
                                                       findings: Self.findings(12, "Audited") + Self.fixed(3)), as: .session(verifier))
        let panel = try (1...2).map { index in
            try bound(book, .verifier, root: root, task: "task-2", from: full.lead,
                      finder: LeadVault.Finder(panel: "p", index: index, size: 2, focus: "correctness", nitCap: 3))
        }
        for finder in panel {
            try gauge.call("submitVerdict (finder)", .submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "found",
                                                                    findings: Self.findings(12, "Found") + Self.fixed(3)), as: .session(finder))
        }
        try gauge.call("roster", .roster(root: nil), as: .app)
        try gauge.call("audits", .audits(root: root, task: "task-3"), as: lead)
        try gauge.call("unaudited", .unaudited(root: root, task: "task-3"), as: lead)
        try gauge.call("dismissFinding", .dismissFinding(root: root, task: "task-3", id: "F1", reason: "not reachable", followUp: nil), as: lead)
        try gauge.call("noteWorking", .noteWorking(root: root, sessions: full.workers, at: Date().timeIntervalSince1970), as: .app)
        try gauge.call("ranGit", .ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: "c", verb: "commit", branch: "main", head: first)),
                       as: .session(UUID().uuidString))
        try gauge.call("setGuarded", .setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), as: lead)
        try gauge.call("acceptMove", .acceptMove(root: root, branch: "main"), as: .app)
        try gauge.call("verify", .verify((0..<100).map { SteerMessage(text: "message \($0)", from: .user, agentPid: 1) }), as: .unknown)

        let hello = try gauge.send(.hello(protocolVersion: HostProtocol.version, app: "x"), as: .app)
        print("HostVaultStackTests: on the host's queue (\(StackGauge.kb(queueStack))) + on the answer's thread "
              + "(\(StackGauge.kb(ToolThread.stackSize))), by call: hello \(StackGauge.kb(hello.bytes)), "
              + gauge.all.map { "\($0.call) \(StackGauge.kb($0.queue)) + \(StackGauge.kb($0.answer))" }.joined(separator: ", "))
        #expect(queueStack > 0 && gauge.all.allSatisfy { $0.queue > 0 && $0.answer > 0 })
        let onQueue = gauge.all.max { $0.queue < $1.queue }!, answering = gauge.all.max { $0.answer < $1.answer }!
        #expect(onQueue.queue * 4 <= queueStack,
                """
                The vault call \(onQueue.call) used \(StackGauge.kb(onQueue.queue)) of stack on the session host's queue, more \
                than a quarter of the \(StackGauge.kb(queueStack)) its threads have. A host whose stack overflows ends every \
                session: do the work on the answer's thread (HostServer.answerOffQueue), or move what grew to the heap (`@Boxed`).
                """)
        #expect(answering.answer * 4 <= ToolThread.stackSize,
                """
                The vault's answer to \(answering.call) used \(StackGauge.kb(answering.answer)) of stack, more than a quarter of \
                the \(StackGauge.kb(ToolThread.stackSize)) its thread gets (ToolThread.stackSize). Move what grew to the heap \
                (`@Boxed`), or raise ToolThread.stackSize.
                """)
    }

    /// The stack size of the threads `queue` runs its work on.
    func stackSize(of queue: DispatchQueue) -> Int {
        final class Size: @unchecked Sendable { var bytes = 0 }
        let size = Size(), done = DispatchSemaphore(value: 0)
        queue.async {
            size.bytes = pthread_get_stacksize_np(pthread_self())
            done.signal()
        }
        done.wait()
        return size.bytes
    }

    /// A grant for `role` on `task` from the lead, bound to a new session id; that id.
    func bound(_ book: LeadVault.Book, _ role: LeadLaunch.Role, root: String, task: String, from lead: String,
               finder: LeadVault.Finder? = nil) throws -> String {
        let session = UUID().uuidString
        guard case .grant(let grant) = book.answer(.issue(role: role, root: root, task: task, auditing: String(repeating: "a", count: 40),
                                                          finder: finder), from: .session(lead)) else { throw CancellationError() }
        guard book.answer(.bind(grant: grant, root: root, session: session), from: .session(lead)) == .ok else { throw CancellationError() }
        return session
    }

    /// A team with `boardTasks` tasks, each worked, reported done with evidence, audited with findings, approved and
    /// reviewed, and the most git runs it keeps.
    func boardSizedVault(root: String, head: String) throws -> (book: LeadVault.Book, lead: String, workers: [String]) {
        let book = LeadVault.Book()
        let lead = UUID().uuidString
        guard case .grant(let grant) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { throw CancellationError() }
        #expect(book.answer(.bind(grant: grant, root: root, session: lead), from: .app) == .ok)
        #expect(book.answer(.setHead(root: root, branch: "main", commit: head), from: .app) == .ok)
        var workers: [String] = []
        for index in 0..<Self.boardTasks {
            let task = "task-\(index)", commit = String(repeating: "b", count: 39) + "\(index % 10)"
            let worker = try bound(book, .worker, root: root, task: task, from: lead)
            workers.append(worker)
            #expect(book.answer(.reportDone(root: root, task: task, commit: commit, evidence: Self.evidence(index, checks: 4)),
                                from: .session(worker)) == .ok)
            let verifier = try bound(book, .verifier, root: root, task: task, from: lead)
            guard case .verdict = book.answer(.submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "audit of \(task)",
                                                             findings: Self.findings(3)), from: .session(verifier)) else { throw CancellationError() }
            #expect(book.answer(.approve(root: root, task: task, commit: commit), from: .app) == .ok)
            #expect(book.answer(.setReview(root: root, task: task, review: .audit), from: .session(lead)) == .ok)
        }
        let user = UUID().uuidString
        for run in 0..<200 {
            _ = book.answer(.ranGit(root: root, step: LeadVault.GitStep(phase: .before, call: "r\(run)", verb: "commit", branch: "main", head: head)),
                            from: .session(user), userOpened: true)
        }
        return (book, lead, workers)
    }

    static func evidence(_ task: Int, checks: Int) -> LeadDoneEvidence {
        LeadDoneEvidence(checks: (1...checks).map { check in
            LeadDoneEvidence.Check(check: "\(check)", how: "bash scripts/test.sh --filter Task\(task)Check\(check): " + String(repeating: "passed ", count: 40),
                                   result: "passed, \(check * 7) tests", screenshots: [".build/sandbox-shots/task-\(task)-\(check).png"])
        }, blindCheck: "Nothing blocking. " + String(repeating: "Checked the diff against the contract. ", count: 10))
    }

    /// The first `count` of `findings(_:)`, as an audit of their fix marks them.
    static func fixed(_ count: Int) -> [LeadFinding.Report] {
        findings(count).enumerated().map { index, finding in
            var finding = finding
            finding.id = "F\(index + 1)"
            finding.status = .fixed
            finding.reason = "fixed in the next commit"
            return finding
        }
    }

    /// `count` findings, each in a file of its own named after `prefix`.
    static func findings(_ count: Int, _ prefix: String = "File") -> [LeadFinding.Report] {
        (1...count).map { index in
            LeadFinding.Report(severity: index % 3 == 0 ? .important : .nit, file: "Sources/VibeCore/\(prefix)\(index).swift", line: index * 10,
                               evidence: "What it found: " + String(repeating: "detail ", count: 30), status: .open,
                               failureScenario: index % 3 == 0 ? "Given this input the call returns the wrong value." : nil)
        }
    }
}

/// Vault calls as the host answers them, each measured on `StackGauge` threads: a connection on a socket pair (this
/// process at both ends, so its caller is whoever the test says) and `HostServer.handle` inside `queue.sync`, which runs
/// the block on the calling thread, as the host's queue would on one of its own; the vault's answer on the thread the
/// host is given for it (`vaultThread`), of `ToolThread.stackSize` as the host's own.
final class HostGauge: @unchecked Sendable {
    let server: HostServer
    /// Each call: the stack it took on the queue, and its answer on its own thread.
    private(set) var all: [(call: String, queue: Int, answer: Int)] = []
    /// The answer's, written on its thread after it answered, read once `answered` is signalled.
    private var answer = 0
    private let answered = DispatchSemaphore(value: 0)

    init(_ server: HostServer) {
        self.server = server
        server.queue.sync {
            server.vaultThread = { [weak self] body in
                StackGauge.start(body) { used in
                    self?.answer = used
                    self?.answered.signal()
                }
            }
        }
    }

    /// Sends `request` as `caller`; its reply, which must not be a refusal.
    @discardableResult
    func call(_ name: String, _ request: LeadVault.Request, as caller: LeadVault.Caller,
              sourceLocation: SourceLocation = #_sourceLocation) throws -> LeadVault.Reply {
        let (reply, bytes) = try send(.vault(request), as: caller, sourceLocation: sourceLocation)
        // Measured once its thread is done, a moment after the queue had the answer.
        guard answered.wait(timeout: .now() + hangGuard) == .success else {
            Issue.record("\(name): its answer never ran on the vault's thread", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        all.append((name, bytes, answer))
        guard case .vault(let answer) = reply else {
            Issue.record("\(name): \(reply)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        if case .refused(let why) = answer { Issue.record("\(name) refused: \(why)", sourceLocation: sourceLocation) }
        return answer
    }

    /// `request` from `caller`, handled on a gauge's thread: the reply, and the stack it took there.
    func send(_ request: HostRequest, as caller: LeadVault.Caller,
              sourceLocation: SourceLocation = #_sourceLocation) throws -> (event: HostEvent, bytes: Int) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CancellationError() }
        let (hosts, ours) = (pair[0], pair[1])
        defer {
            Darwin.close(ours)
            Darwin.close(hosts)
        }
        UnixSocket.configure(hosts)
        let client = ClientConnection(fd: hosts, queue: server.queue)
        client.peer = UnixSocket.peerToken(hosts)
        client.caller = caller
        let payload = try HostCoding.encode(HostRequestEnvelope(seq: 1, request: request))
        final class Threads: @unchecked Sendable { var outside: pthread_t?, inside: pthread_t? }
        let threads = Threads()
        let server = server
        let bytes = StackGauge.used {
            threads.outside = pthread_self()
            server.queue.sync {
                threads.inside = pthread_self()
                server.handle(.control, payload, from: client)
            }
        }
        #expect(threads.inside.map { pthread_equal($0, threads.outside!) != 0 } == true, "\(request) didn't run on the gauge's thread",
                sourceLocation: sourceLocation)
        let reply = try Self.reply(on: ours)
        server.queue.sync { client.close() }
        return (reply, bytes)
    }

    /// The host's reply to request 1, read from `fd` (blocking: the host's queue writes what didn't fit at once).
    static func reply(on fd: Int32) throws -> HostEvent {
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var timeout = timeval(tv_sec: Int(hangGuard), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while true {
            while let frame = try decoder.next() {
                guard frame.kind == .control else { continue }
                let envelope = try HostCoding.decode(HostEventEnvelope.self, from: frame.payload)
                if envelope.replyTo == 1 { return envelope.event }
            }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw CancellationError() }
            decoder.append(Data(buffer[..<count]))
        }
    }
}
