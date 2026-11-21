import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A lead's board on the live wire and the command line (the parity table's gap 4): `BoardValue` reads a board as the
/// page and `vibeswitcher board` show it (its groups, its states in the Mac's words, a dim line, its facts), every
/// string the sessions wrote inert and capped, a huge or malformed board bounded or refused; `LiveBoards` follows each
/// lead's board file, so a change is a delta on the `boards` stream with no timer between, a resume is one delta, and a
/// lead gone takes its board. Each test has a scratch root; nothing is slept on: each waits on the event it checks.
struct BoardTests {
    private let scratch = Scratch()

    // MARK: What a board reads as

    /// The vectors' made-up board: each task in its group, in the Mac's words, with the line under it.
    @Test func eachTaskReadsInItsGroupAndWords() throws {
        let value = WireVectors.boardValue
        let tasks = try #require(value["tasks"]?.array)
        let read = tasks.map { [$0["slug"]?.string ?? "", $0["group"]?.string ?? "", $0["state"]?.string ?? ""] }
        #expect(read == [["pricing-copy", "attention", "Blocked"], ["onboarding-steps", "running", "Rework 1"],
                         ["upload-retry", "running", "In review"], ["sidebar-pass", "waiting", "Queued"], ["cache-assets", "done", "Merged"]])
        #expect(tasks[0]["line"] == .string("Which plan names do we launch with?"), "a blocked task's line is its blocker's first")
        #expect(tasks[1]["worker"] == .string(NodeIds.session(host: WireVectors.boardWorker)))
        #expect(tasks[1]["checkpoint"]?["text"] == .string("Step two's form validates on blur; writing its tests"))
        #expect(tasks[1]["budgetMin"] == .int(60) && tasks[1]["attempts"] == .int(2))
        #expect(tasks[2]["audit"] == .object(["verdict": .string("failed"), "open": .int(1), "findings": .int(1), "rounds": .int(1)]))
        #expect(tasks[3]["line"] == .string("Waits on Onboarding: the three first-run steps"))
        #expect(tasks[4]["merged"]?["commit"] == .string("8a3f1e2c"))
        #expect(value["counts"] == .object(["attention": .int(1), "running": .int(2), "waiting": .int(1), "done": .int(1)]))
        #expect(WireSchema.check(value, as: "board", strict: true) == nil)
    }

    /// The other ways a task reads: failed with its setback, a worker waiting on the lead, ready to merge, abandoned, kept.
    @Test func theOtherStatesReadAsTheMacsTeamRows() {
        func shown(_ status: LeadTask.Status, _ change: (inout LeadTask) -> Void = { _ in }) -> BoardValue.Shown {
            var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: status)
            change(&task)
            return BoardValue.Shown(task, board: LeadBoard())
        }
        let failed = shown(.failed) {
            $0.worktree = "/w"
            $0.setback = LeadSetback(stage: .review, reason: "The audit found the retry unsafe")
        }
        #expect(failed.group == "attention" && failed.state == "Failed" && failed.line == "The audit found the retry unsafe")
        let asking = shown(.running) { $0.leadQuestionAt = 1 }
        #expect(asking.group == "attention" && asking.state == "Waits on lead")
        let ready = shown(.review) { $0.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok", at: 1) }
        #expect(ready.group == "running" && ready.state == "Ready to merge")
        let cleaned = shown(.failed) { $0.worker = UUID().uuidString }
        #expect(cleaned.group == "done" && cleaned.state == "Abandoned")
        let kept = shown(.kept) { $0.keptBecause = "a prototype the user hasn't seen" }
        #expect(kept.group == "waiting" && kept.state == "Kept" && kept.line == "a prototype the user hasn't seen")
    }

    /// Every field of the board's shapes seen set and, where it may be, null, from the encoder (the schema is what it
    /// writes, both ways), with an unreadable board too.
    @Test func theBoardSchemaIsWhatTheEncoderWrites() throws {
        var seen: Set<String> = []
        let unreadable = BoardValue.value(project: "p", root: "/r", board: nil, refusal: "the board isn't one this build reads", now: WireVectors.boardNow)
        // A board from before the stamps (no since, times of 0) with a verifier at work and an audit with no verdict yet.
        var old = WireVectors.sampleBoard(now: WireVectors.boardNow.timeIntervalSince1970, verifier: UUID())
        for index in old.tasks.indices {
            old.tasks[index].createdAt = 0
            old.tasks[index].since = nil
        }
        old.tasks[1].checkpoints = [LeadCheckpoint(text: "Started", at: 0)]
        old.tasks[2].audits?.passed = nil
        old.tasks[4].merged?.at = WireVectors.boardNow.timeIntervalSince1970
        old.tasks[3].status = .kept  // kept after a merge undone by hand: its record says no time
        old.tasks[3].merged = LeadMergeRecord(commit: "c0ffee", tested: false, at: 0)
        let older = BoardValue.value(project: "p", root: "/r", board: old, now: WireVectors.boardNow,
                                     decisions: [BoardDecision(id: "0|An old decision", at: 0, text: "An old decision", why: "")])
        for value in [WireVectors.boardValue, WireVectors.boardMoved, unreadable, older] {
            #expect(WireSchema.check(value, as: "board", strict: true) { field, state in seen.insert("\(field) \(state)") } == nil)
        }
        let missed = WireSchema.coverage(of: ["board"]).subtracting(seen).sorted()
        #expect(missed.isEmpty, "never seen: \(missed.joined(separator: ", "))")
    }

    // MARK: A board is the sessions' writing

    /// Escape sequences, bidirectional overrides and other controls in what a session wrote come out replaced; a
    /// blocker keeps its lines; a worker that isn't a host's UUID (a path, say) is no session.
    @Test func aTasksTextIsInert() throws {
        var board = WireVectors.sampleBoard(now: WireVectors.boardNow.timeIntervalSince1970)
        board.tasks[0].title = "Fix \u{1b}[31mred\u{1b}[0m \u{202e}txt.exe\u{7}"
        board.tasks[0].blocker = "First \u{1b}]52;c;cGF5bG9hZA==\u{7} line\nsecond\u{2028}line\n\n\nfourth"
        board.tasks[1].worker = "../../../etc/passwd"
        board.tasks[1].checkpoints = [LeadCheckpoint(text: "\u{1b}[2J\nhidden on line two", at: 1)]
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: WireVectors.boardNow)
        let tasks = try #require(value["tasks"]?.array)
        func clean(_ text: String?, newlines: Bool = false) -> Bool {
            guard let text else { return false }
            return !text.unicodeScalars.contains { scalar in
                if newlines && scalar == "\n" { return false }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return true
                default: return false
                }
            }
        }
        #expect(clean(tasks[0]["title"]?.string), "\(String(describing: tasks[0]["title"]))")
        #expect(tasks[0]["title"]?.string?.contains("[31mred") == true, "the text is kept, only the controls go")
        let blocker = try #require(tasks[0]["blocker"]?.string)
        #expect(clean(blocker, newlines: true) && blocker.contains("\n"), "\(blocker)")
        #expect(clean(tasks[0]["line"]?.string) && !(tasks[0]["line"]?.string?.contains("\n") ?? true))
        #expect(tasks[1]["worker"] == .null)
        #expect(tasks[1]["checkpoint"]?["text"] == .string("\u{FFFD}[2J"), "a checkpoint is its first line")
    }

    /// A board of 400 tasks with huge titles and blockers: the first `mostTasks` by group are sent, the rest counted,
    /// each string capped, and the value stays well under a frame (1 MiB).
    @Test func aHugeBoardIsBounded() throws {
        var board = LeadBoard()
        let now = WireVectors.boardNow.timeIntervalSince1970
        for index in 0..<400 {
            var task = LeadTask(id: "t\(index)", slug: "task-\(index)", title: String(repeating: "T", count: 50_000),
                                contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""),
                                status: index % 4 == 0 ? .blocked : .planned)
            task.createdAt = now
            task.blocker = String(repeating: "why\n", count: 5_000)
            task.after = (0..<100).map { "a\($0)" }
            board.tasks.append(task)
        }
        board.tasks.append(board.tasks[0])  // a slug twice: shown once
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: WireVectors.boardNow)
        let tasks = try #require(value["tasks"]?.array)
        #expect(tasks.count <= BoardValue.mostTasks && tasks.count > 0)
        #expect(value["more"] == .int(400 - tasks.count))
        #expect(tasks.prefix(100).allSatisfy { $0["group"] == .string("attention") }, "what needs someone comes first")
        let title = try #require(tasks[0]["title"]?.string)
        #expect(title.utf8.count <= BoardValue.titleBytes + 3)
        let blocker = try #require(tasks[0]["blocker"]?.string)
        #expect(blocker.split(separator: "\n").count <= BoardValue.blockerLines && blocker.utf8.count <= BoardValue.blockerLimit + 3)
        #expect(tasks[0]["after"]?.array?.count == 20)
        #expect(NodeWire.message(value).count <= BoardValue.mostBytes, "a board's value fits its budget")
        // Small tasks: the count's cap, not the bytes', is what cuts.
        var small = LeadBoard()
        for index in 0..<400 {
            var task = LeadTask(id: "s\(index)", slug: "s-\(index)", title: "Task \(index)", contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""))
            task.createdAt = WireVectors.boardNow.timeIntervalSince1970
            small.tasks.append(task)
        }
        let few = BoardValue.value(project: "p", root: "/r", board: small, now: WireVectors.boardNow)
        #expect(few["tasks"]?.array?.count == BoardValue.mostTasks && few["more"] == .int(400 - BoardValue.mostTasks))
    }

    /// A file over the most read, a link, and one that isn't a board are refused, saying why; none there is an empty board.
    @Test func aBoardThatCantBeReadIsRefused() throws {
        let root = scratch.url("board-file")
        let folder = root.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("board.json").path
        #expect(BoardFile.read(root: root.path).board == LeadBoard(), "no board yet: an empty one")
        try Data(String(repeating: " ", count: 2048).utf8).write(to: URL(fileURLWithPath: path))
        #expect(BoardFile.read(root: root.path, mostBytes: 1024).refusal?.contains("more than") == true)
        try Data("{\"tasks\": [{\"title\": 3}]}".utf8).write(to: URL(fileURLWithPath: path))
        #expect(BoardFile.read(root: root.path).refusal == "the board isn't one this build reads")
    }

    /// A `board.json` that is a link, and a `.vibeswitcher` that is a link to a folder holding a good board: neither is
    /// followed, each refused saying so.
    @Test func aLinkedBoardOrFolderIsntFollowed() throws {
        let root = scratch.url("board-link")
        let folder = root.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = scratch.url("board-elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let good = elsewhere.appendingPathComponent("board.json")
        try NodeWire.line(WireVectors.sampleBoard(now: 0)).write(to: good)

        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("board.json").path, withDestinationPath: good.path)
        let linkedFile = BoardFile.read(root: root.path)
        #expect(linkedFile.board == nil && linkedFile.refusal == "the board isn't read: board.json is a link", "\(linkedFile)")

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: elsewhere.path)
        let linkedFolder = BoardFile.read(root: root.path)
        #expect(linkedFolder.board == nil && linkedFolder.refusal?.contains(".vibeswitcher isn't a folder") == true, "\(linkedFolder)")
    }

    /// A FIFO at the board's path (nobody writing it) is refused at once: the open doesn't wait for a writer.
    @Test func aFIFOAtTheBoardsPathDoesntHang() async throws {
        let root = scratch.url("board-fifo")
        let folder = root.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(mkfifo(folder.appendingPathComponent("board.json").path, 0o600) == 0, "mkfifo: \(errno)")
        let done = Locked<(board: LeadBoard?, refusal: String?)?>(nil)
        Thread { let read = BoardFile.read(root: root.path); done.mutate { $0 = read } }.start()
        try #require(await eventually(timeout: 10) { done.value != nil }, "the read of a FIFO waited")
        #expect(done.value?.refusal == "the board isn't read: board.json isn't a regular file", "\(String(describing: done.value))")
    }

    /// A title of a few characters each carrying thousands of combining marks: at most `marksKept` marks a character,
    /// and the whole string capped in bytes, not characters.
    @Test func combiningMarksAreBoundedAndStringsCappedInBytes() throws {
        let zalgo = String(repeating: "Z" + String(repeating: "\u{0301}", count: 5_000), count: 3)
        let title = BoardValue.text(zalgo, limit: BoardValue.titleBytes)
        #expect(title.unicodeScalars.filter { $0.properties.generalCategory == .nonspacingMark }.count == 3 * BoardValue.marksKept, "\(title.unicodeScalars.count)")
        #expect(Array(title.unicodeScalars.prefix(6)) == Array("Z\u{0301}\u{0301}\u{0301}\u{0301}Z".unicodeScalars))
        // Four-byte scalars: the cap is bytes of UTF-8, cut between scalars.
        let emoji = BoardValue.text(String(repeating: "😀", count: 1_000), limit: BoardValue.titleBytes)
        #expect(emoji.dropLast().utf8.count <= BoardValue.titleBytes && emoji.hasSuffix("…"))
        #expect(emoji.dropLast().unicodeScalars.allSatisfy { $0 == "😀" })
        // One character of 5 000 marks is one Character, and still a few bytes.
        let one = BoardValue.text("e" + String(repeating: "\u{0300}", count: 5_000), limit: 10_000)
        #expect(one.utf8.count < 20, "\(one.utf8.count)")
    }

    /// A board whose tasks would take more than `mostBytes` encoded (150 tasks, each near its caps): the last ones go
    /// to `more` until the value fits.
    @Test func aBoardOverTheByteBudgetMovesTasksToMore() throws {
        var board = LeadBoard()
        for index in 0..<150 {
            var task = LeadTask(id: "t\(index)", slug: "task-\(index)", title: String(repeating: "界", count: 1_000),
                                contract: LeadContract(goal: "", acceptance: [], boundaries: [], context: ""), status: .blocked)
            task.createdAt = WireVectors.boardNow.timeIntervalSince1970
            task.blocker = String(repeating: "原因 ", count: 3_000)
            task.after = (0..<20).map { String(repeating: "a", count: 200) + "\($0)" }
            board.tasks.append(task)
        }
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: WireVectors.boardNow)
        let tasks = try #require(value["tasks"]?.array)
        #expect(NodeWire.message(value).count <= BoardValue.mostBytes, "\(NodeWire.message(value).count)")
        #expect(tasks.count < 150 && tasks.count > 0)
        #expect(value["more"] == .int(150 - tasks.count))
        #expect(tasks.last?["slug"] == .string("task-\(tasks.count - 1)"), "the first by group and place are kept")
    }

    /// A task merged an hour ago is sent; one merged 25 hours ago is the board's history.
    @Test func aFinishedTaskIsSentForADay() throws {
        let now = WireVectors.boardNow
        var board = WireVectors.sampleBoard(now: now.timeIntervalSince1970)
        board.tasks[4].merged?.at = now.timeIntervalSince1970 - 25 * 3600
        let value = BoardValue.value(project: "p", root: "/r", board: board, now: now)
        #expect(value["tasks"]?.array?.contains { $0["slug"] == .string("cache-assets") } == false)
        #expect(value["more"] == .int(0), "history isn't counted as cut")
    }

    // MARK: The stream

    /// A lead's board read at the start is in the `boards` snapshot; a new board renamed into place (as the lead's tools
    /// write it) is one delta whose `prev` is the snapshot's `seq`, carrying the project's board as it is now.
    @Test func aBoardChangeIsADelta() async throws {
        let world = try BoardWorld(scratch)
        defer { world.stop() }
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        world.start()
        try await world.waitFor { $0?["tasks"]?.array?.count == 5 }
        let client = Recorder()
        world.subscribe(client, sub: "b1")
        let snapshot = try #require(client.events.first)
        #expect(snapshot["collection"] == .string("boards"))
        #expect(LiveWorld.rows(of: snapshot)[world.project]?["tasks"]?.array?.count == 5)

        var board = WireVectors.sampleBoard(now: world.now.timeIntervalSince1970)
        board.tasks[0].status = .running
        board.tasks[0].blocker = nil
        try world.write(board)
        try await client.waitFor(events: 2)
        let delta = client.events[1]
        #expect(delta["kind"] == .string("delta") && delta["prev"] == snapshot["seq"], "\(delta)")
        let changed = try #require(delta["changes"]?.array?.first)
        #expect(changed["id"] == .string(world.project))
        #expect(changed["value"]?["tasks"]?.array?.first?["state"] == .string("Working"))
        #expect(WireSchema.check(delta, as: "delta.boards") == nil)
    }

    /// A board that stops reading (a session wrote something else there) says so, with no tasks; a good board again is
    /// read again.
    @Test func aMalformedBoardSaysItCantBeShown() async throws {
        let world = try BoardWorld(scratch)
        defer { world.stop() }
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        world.start()
        try await world.waitFor { $0?["tasks"]?.array?.count == 5 }
        try world.write(raw: Data("{\"tasks\": \"not a list\"}".utf8))
        try await world.waitFor { $0?["unreadable"]?.string != nil }
        #expect(world.value?["tasks"] == .array([]))
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        try await world.waitFor { $0?["unreadable"] == .null && $0?["tasks"]?.array?.count == 5 }
    }

    /// The board's folder made after the lead started (no watch could be made) is found at the clock's next look.
    @Test func aFolderMadeLaterIsFoundAtTheNextLook() async throws {
        let world = try BoardWorld(scratch, makeFolder: false)
        defer { world.stop() }
        world.start()
        try await world.waitFor { $0?["tasks"] == .array([]) }
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        world.queue.sync { world.boards.lookAll() }
        try await world.waitFor { $0?["tasks"]?.array?.count == 5 }
        // Watched from that look on: the next change comes by itself.
        var board = WireVectors.sampleBoard(now: world.now.timeIntervalSince1970)
        board.tasks.removeLast()
        try world.write(board)
        try await world.waitFor { $0?["tasks"]?.array?.count == 4 }
    }

    /// A page that held the stream's `seq` and came back gets one delta, not a snapshot.
    @Test func aBoardResumesFromItsSeq() async throws {
        let world = try BoardWorld(scratch)
        defer { world.stop() }
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        world.start()
        try await world.waitFor { $0?["tasks"]?.array?.count == 5 }
        let first = Recorder()
        world.subscribe(first, sub: "b1")
        let held = try #require(first.events.first?["seq"]?.int)
        world.hub.closed(first)
        var board = WireVectors.sampleBoard(now: world.now.timeIntervalSince1970)
        board.tasks[3].status = .running
        try world.write(board)
        try await world.waitFor { $0?["tasks"]?.array?.contains { $0["slug"] == .string("sidebar-pass") && $0["group"] == .string("running") } == true }
        try #require(await eventually { world.queue.sync { world.stream.seq } > held })
        let again = Recorder()
        world.subscribe(again, sub: "b1", since: .object(["epoch": .string(world.hub.epoch), "seq": .int(held)]))
        #expect(again.messages.first?["result"]?["mode"] == .string("resume"), "\(again.messages)")
        #expect(again.events.count == 1 && again.events[0]["kind"] == .string("delta") && again.events[0]["prev"] == .int(held))
    }

    /// A project whose lead goes takes its board off the stream.
    @Test func aLeadGoneTakesItsBoard() async throws {
        let world = try BoardWorld(scratch)
        defer { world.stop() }
        try world.write(WireVectors.sampleBoard(now: world.now.timeIntervalSince1970))
        world.start()
        try await world.waitFor { $0 != nil }
        world.leads.send(world.project, nil)
        try #require(await eventually { world.queue.sync { world.stream.entries[world.project] } == nil }, "the board stayed")
    }

    // MARK: The command line's text

    @Test func theCommandLinePrintsOneShortLineATask() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let lines = BoardText.lines(WireVectors.boardValue, now: WireVectors.boardNow, calendar: utc, home: "/home/u")
        #expect(lines == [
            "~/acme-site · base main",
            "Needs attention",
            "  Blocked 18m  Rewrite the pricing page's copy — Which plan names do we launch with?",
            "Running",
            // The running task's AI summary, in its line's place (the vectors' board carries one).
            "  Rework 1 4m  Onboarding: the three first-run steps — Making the sign-up form check each field as you leave it",
            "  In review 1m  Retry a failed upload once — Waiting for the audit",
            "Waiting",
            "  Queued 25m  UI consistency pass over the sidebar — Waits on Onboarding: the three first-run steps",
            "Done today",
            "  Merged  Cache the static assets — merged 8a3f1e2c, tests passed",
            "1 needs attention · 2 running · 1 waiting · 1 done today",
            // The lead's latest decisions: the long one by its AI summary.
            "Decisions",
            "  Decided: run the two small tasks side by side (5m ago)",
            "  Decided: keep the sidebar pass for after onboarding (30m ago)",
        ], "\(lines.joined(separator: "\n"))")
        let unreadable = BoardValue.value(project: "p", root: "/r", board: nil, refusal: "the board isn't one this build reads", now: WireVectors.boardNow)
        #expect(BoardText.lines(unreadable).last == "  the board can't be shown: the board isn't one this build reads")
    }
}

/// A `LiveBoards` on an engine queue of its own, following a lead store's changes, its stream on a hub; the lead's
/// root a scratch folder.
final class BoardWorld: @unchecked Sendable {
    let queue = DispatchQueue(label: "engine")
    let leads = Changes<LeadStore.Lead>()
    let boards: LiveBoards
    let hub: LiveHub
    let stream = LiveStream(collection: "boards", order: .field("project"))
    let root: URL
    let project: String
    let now = WireVectors.boardNow

    init(_ scratch: Scratch, makeFolder: Bool = true) throws {
        root = scratch.url("board-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if makeFolder { try FileManager.default.createDirectory(at: root.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true) }
        project = NodeIds.project(root: root.path)
        let now = WireVectors.boardNow
        boards = LiveBoards(queue: queue, leads: leads, now: { now })
        hub = LiveHub(queue: queue, epoch: "epoch-b")
    }

    func start() {
        leads.send(project, LeadStore.Lead(project: project, root: root.path))
        queue.sync {
            hub.add(collection: "boards", stream)
            boards.start(clock: nil)
            hub.follow(boards.changes, into: stream) { $0 }
        }
    }

    func stop() { boards.stop() }

    var value: NodeWire.Value? { boards.values[project] }

    func waitFor(_ condition: @escaping (NodeWire.Value?) -> Bool) async throws {
        try #require(await eventually { condition(self.value) }, "the board never read as wanted: \(String(describing: value))")
    }

    /// `board` written whole and renamed into place, as `BoardStore` writes it.
    func write(_ board: LeadBoard) throws { try write(raw: NodeWire.line(board)) }

    func write(raw: Data) throws {
        let folder = root.appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("board.json.\(UUID().uuidString).tmp")
        try raw.write(to: temporary)
        try #require(rename(temporary.path, folder.appendingPathComponent("board.json").path) == 0, "rename: \(errno)")
    }

    func subscribe(_ client: Recorder, sub: String, since: NodeWire.Value? = nil) {
        var args: [String: NodeWire.Value] = ["sub": .string(sub), "collection": .string("boards")]
        if let since { args["since"] = since }
        queue.sync { _ = hub.handle(NodeWire.Request(id: "1", kind: "subscribe", args: args), on: client, rights: .read) }
    }
}
