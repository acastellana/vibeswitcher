import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The lead controller's look every 3 s, off the main thread (`LeadReads`): a board or decisions file is read again only
/// when it changed, and what's read is handed to the main thread.
struct LeadFilesTests {
    private func newRoot() throws -> String {
        let root = scratchRoot.appendingPathComponent("lead-files-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func anUnchangedBoardIsNotReadAgain() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { $0.baseBranch = "main" }
        try store.appendDecision("Ship it", why: "It works.")
        var files = LeadFiles()
        #expect(files.board(root).baseBranch == "main")
        #expect(files.decisions(root).map(\.text) == ["Ship it"])
        #expect(files.fileReads == 2)
        for _ in 0..<5 {
            _ = files.board(root)
            _ = files.decisions(root)
        }
        #expect(files.fileReads == 2)
        // Written again (the lead's tools): read again, once.
        try store.update { $0.baseBranch = "develop" }
        try store.appendDecision("Keep going", why: "")
        #expect(files.board(root).baseBranch == "develop")
        #expect(files.decisions(root).map(\.text) == ["Ship it", "Keep going"])
        #expect(files.board(root).baseBranch == "develop")
        #expect(files.fileReads == 4)
    }

    /// What `reads` hands the main thread, and whether it read on the main thread.
    @MainActor
    private func read<T>(_ reads: LeadReads, _ work: @escaping (inout LeadFiles) -> T) async -> (value: T, onMain: Bool, handedOnMain: Bool)? {
        var result: (value: T, onMain: Bool, handedOnMain: Bool)?
        reads.async({ files in (work(&files), Thread.isMainThread) }) { value, onMain in
            result = (value, onMain, Thread.isMainThread)
        }
        _ = await until { result != nil }
        return result
    }

    @Test @MainActor func boardsAreReadOffTheMainThreadAndHandedToIt() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { $0.baseBranch = "main" }
        let reads = LeadReads()
        let first = try #require(await read(reads) { $0.board(root) })
        #expect(first.value.baseBranch == "main")
        #expect(!first.onMain && first.handedOnMain)
        // A write through the same queue is seen by the read after it.
        reads.async { _ in try? store.update { $0.baseBranch = "develop" } }
        #expect(try #require(await read(reads) { $0.board(root) }).value.baseBranch == "develop")
    }

    @Test @MainActor func aBoardThatDoesntReadIsShownEmptyAsBefore() async throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(throws: BoardError.self) { try store.read() }
        let shown = try #require(await read(LeadReads()) { $0.board(root) })
        #expect(shown.value == LeadBoard())
        #expect(shown.handedOnMain)
    }

    /// What the witness reads of a team off the main thread (`TeamReading`) is what it read on it before: a worker's
    /// transcript whatever it shows, a verifier's while it doesn't show working, none for an ended session or one the
    /// scan didn't take for an agent's.
    @Test func theWitnessReadsWhatItReadBefore() throws {
        let home = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let states = (home as NSString).appendingPathComponent("state")
        let projects = (home as NSString).appendingPathComponent(".claude/projects/-r")
        try FileManager.default.createDirectory(atPath: states, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let observer = LeadObserver(home: home, stateFile: { URL(fileURLWithPath: (states as NSString).appendingPathComponent("\($0).json")) })
        let started = Date().addingTimeInterval(-600)
        let finished = """
            {"type":"assistant","timestamp":"2026-10-19T09:00:00.250Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
            {"type":"system","subtype":"turn_duration","timestamp":"2026-10-19T09:00:01Z"}

            """
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        func member(_ index: Int, status: SessionStatus, live: Bool = true, scanned: Bool = true) throws -> String {
            let id = UUID()
            let tty = "ttys\(900 + index)"
            hosted[id.uuidString] = HostSession(id: id, tty: tty, childPID: 1, cwd: "/r", command: "claude", label: "task-\(index)", agent: "claude",
                                                title: "", startedAt: started, cols: 120, rows: 40,
                                                exit: live ? nil : HostSession.Exit(status: 0, at: Date()))
            let transcript = (projects as NSString).appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
            try finished.write(toFile: transcript, atomically: true, encoding: .utf8)
            var hook = HookState(agent: .claude, tty: tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970)
            hook.agentPid = Int32(7000 + index)
            hook.transcriptPath = transcript
            try hook.save(to: observer.stateFile(tty))
            if scanned {
                var session = Session(tty: tty, agent: .claude, pid: Int32(7000 + index), startedAt: started, cwd: "/r", project: "r", task: nil,
                                      status: status, statusSince: started, detail: nil, hasHooks: true, inTerminalApp: false)
                session.hostID = id
                sessions[id.uuidString] = session
            }
            return id.uuidString
        }
        let worker = try member(0, status: .working)
        let working = try member(1, status: .working)
        let ended = try member(2, status: .done, live: false)
        let verifier = try member(3, status: .done)
        let unscanned = try member(4, status: .done, scanned: false)
        var board = LeadBoard()
        for (index, pair) in [(worker, working), (ended, verifier), (unscanned, nil)].enumerated() {
            var task = LeadTask(slug: "task-\(index)", title: "Task \(index)", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                                status: .running)
            task.worker = pair.0
            task.verifier = pair.1
            board.tasks.append(task)
        }
        let team = TeamReading.read(root: home, board: board, hosted: hosted, sessions: sessions, observer: observer)
        #expect(Set(team.watched.keys) == [worker, verifier])
        for id in [worker, verifier] {
            let reading = observer.watching(try #require(hosted[id]), agentPid: try #require(sessions[id]).pid)
            #expect(team.watched[id]?.activity == reading.activity)
            #expect(team.watched[id]?.tail == reading.tail)
            #expect(team.watched[id]?.progress == reading.progress)
        }
        #expect(team.watched[worker]?.tail?.state == .turnOver(apiError: nil))
        #expect(team.watched[worker]?.progress?.lastWritten == ISO8601DateFormatter().date(from: "2026-10-19T09:00:01Z")?.timeIntervalSince1970)
        #expect(team.hosted == hosted && team.sessions == sessions)
    }

    /// Whom to deliver to, read on the main thread: only the lead's fields, the same as the whole board says, and read
    /// again only when the board changed.
    @Test func theLeadsNameIsReadAloneAndOnlyWhenTheBoardChanged() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { board in
            board.leadPid = 4242
            board.leadTTY = "ttys004"
            board.leadSession = "S1"
            board.baseBranch = "main"
            board.reports = [LeadReport(about: "worker a", text: String(repeating: "report ", count: 2000))]
        }
        var names = LeadNames()
        let named = names.board(root)
        #expect(LeadHandover.named(named) == LeadHandover.named(store.load()))
        #expect(named.leadSession == "S1" && named.baseBranch == nil && named.reports == nil)
        _ = names.board(root)
        #expect(names.fileReads == 1)
        try store.update { LeadHandover.release(&$0) }
        #expect(LeadHandover.named(names.board(root)) == nil)
        #expect(names.fileReads == 2)
    }

    @Test func aBoardThatDoesntReadNamesNoLead() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ \"leadPid\": 1, not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(store.loadLead() == LeadBoard())
        var names = LeadNames()
        #expect(LeadHandover.named(names.board(root)) == nil)
    }

    @Test func aMissingBoardIsAnEmptyOneAndIsLookedForAgain() throws {
        let root = try newRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var files = LeadFiles()
        #expect(files.board(root) == LeadBoard())
        try BoardStore(root: root).update { $0.baseBranch = "main" }
        #expect(files.board(root).baseBranch == "main")
    }
}
