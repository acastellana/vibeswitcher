import Foundation
import Testing
@testable import VibeCore

/// The session host as the lead's tools reach it, except that the requests `drop` picks get no answer (a timeout: the
/// vault's calls have 5 seconds, and the Mac spends hours loaded past that). Every request is noted, so a test can say
/// which were made and which weren't.
final class FlakyHost: @unchecked Sendable {
    /// What the failure looks like before `LeadVault.call` turns it into its refusal.
    struct NoAnswer: Error {}

    private let lock = NSLock()
    private var dropped: (@Sendable (LeadVault.Request) -> Bool)?
    private var before: (@Sendable (LeadVault.Request) -> Void)?
    private var asked: [LeadVault.Request] = []

    /// From here on, the requests `picked` picks go unanswered (nil: all are answered again).
    func drop(_ picked: (@Sendable (LeadVault.Request) -> Bool)?) {
        lock.lock()
        defer { lock.unlock() }
        dropped = picked
        asked = []
    }

    /// From here on, the first request `picked` picks is answered, and none of them after it.
    func drop(firstAnswered picked: @escaping @Sendable (LeadVault.Request) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        var answered = false
        dropped = { request in
            guard picked(request) else { return false }
            defer { answered = true }
            return answered
        }
        asked = []
    }

    /// Runs just before each request reaches the host.
    func beforeEach(_ body: @escaping @Sendable (LeadVault.Request) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        before = body
    }

    /// How many requests `picked` picks were made since the last `drop`.
    func count(_ picked: (LeadVault.Request) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return asked.filter(picked).count
    }

    func vault(over host: LeadVault) -> LeadVault {
        LeadVault(folder: host.folder) { [self] request in
            lock.lock()
            asked.append(request)
            let drop = dropped?(request) == true
            let hook = before
            lock.unlock()
            hook?(request)
            if drop { throw NoAnswer() }
            return try host.call(request)
        }
    }

    static func readsHead(of branch: String) -> @Sendable (LeadVault.Request) -> Bool {
        { if case .head(_, branch) = $0 { true } else { false } }
    }

    static func setsHead(of branch: String) -> @Sendable (LeadVault.Request) -> Bool {
        { if case .setHead(_, branch, _) = $0 { true } else { false } }
    }
}

extension LeadTeamFixture {
    /// The lead (`lead(_:_:)`, its grant and session), its tools reaching the host through `flaky`.
    func lead(_ root: String, _ runtime: FakeRuntime, through flaky: FlakyHost) throws -> LeadToolset {
        _ = try lead(root, runtime)
        let tools = LeadToolset(root: root, runtime: runtime, vault: flaky.vault(over: vault(for: runtime)))
        tools.testLock = testLock
        tools.macLimits = { MacLimits(maxSessions: 6) }
        tools.roomWaits = roomWaits
        tools.usageStore = usageStore
        tools.auditSampleSeed = { unsampledSeed }
        tools.power = { nil }
        return tools
    }
}

/// A vault that doesn't answer isn't a vault with nothing recorded: what reads its head stops rather than record the
/// branch as it is now. And a merge that moved the base is recorded, or said not to be, whatever failed after it.
struct LeadVaultNoAnswerTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("no-answer")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        #expect(Git.run(["commit", "-q", "-m", "change \(file)"], in: dir).ok)
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    /// A task whose worker committed its file, reported, and passed its audit: add-<name>, adding <name>.txt.
    func audited(_ name: String, _ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        let slug = "add-\(name)"
        #expect(!lead.call("add_task", ["title": "Add \(name)", "goal": "\(name).txt exists", "acceptance": ["test -f \(name).txt"]]).isError)
        #expect(!lead.call("start_worker", ["task": slug]).isError)
        try commit("\(name).txt", "\(name)\n", in: Worktrees.path(root: root, slug: slug))
        #expect(!(try seat("worker-\(slug)", runtime)).call("report", doneReport("added")).isError)
        #expect(!lead.call("audit", ["task": slug]).isError)
        let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    // MARK: Reading the head

    @Test func headTellsNoneRecordedFromNoAnswer() throws {
        let root = try repo()
        let flaky = FlakyHost()
        let reader = flaky.vault(over: vault)
        #expect(try reader.head(root: root, branch: "main") == nil)
        #expect(reader.noHeadRecorded(root: root, branch: "main"))
        flaky.drop(FlakyHost.readsHead(of: "main"))
        #expect(throws: LeadVault.Refused.self) { try reader.head(root: root, branch: "main") }
        #expect(!reader.noHeadRecorded(root: root, branch: "main"))
    }

    /// Before: no answer read as "none recorded", so the check recorded main as it stood, and an unaudited commit became
    /// the lead's.
    @Test func checkBaseMovesDoesntRecordAMoveWhenTheHostDoesntAnswer() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let flaky = FlakyHost()
        let lead = try lead(root, runtime, through: flaky)
        try audited("b", lead, runtime, root: root)
        let known = try #require(try vault.head(root: root, branch: "main"))
        try commit("sneaked.txt", "nobody audited this\n", in: root)
        let moved = head("main", root)

        flaky.drop(FlakyHost.readsHead(of: "main"))
        let merged = lead.call("merge", ["task": "add-b"])

        #expect(merged.isError && merged.text.contains("didn't answer"), "\(merged.text)")
        #expect(flaky.count(FlakyHost.setsHead(of: "main")) == 0)
        #expect(try vault.head(root: root, branch: "main") == known)
        #expect(head("main", root) == moved)
        #expect(BoardStore(root: root).load().task("add-b")?.status != .done)
        // It isn't a refused move either: nothing is said about the commit until the host can be asked.
        #expect(LeadVault.BaseMoveRefusal.load(root: root) == nil)
    }

    @Test func recordsWaitAndRecordNothingWhenTheHostDoesntAnswer() throws {
        let root = try repo()
        let flaky = FlakyHost()
        let lead = try lead(root, FakeRuntime(), through: flaky)
        #expect(!lead.call("record_decision", ["decision": "Use SQLite", "why": "no server to run"]).isError)
        let known = try #require(try vault.head(root: root, branch: "main"))
        try commit("sneaked.txt", "nobody audited this\n", in: root)
        let moved = head("main", root)

        flaky.drop(FlakyHost.readsHead(of: "main"))
        guard case .waiting(let why) = lead.records.flush(base: "main") else { Issue.record("it should wait"); return }

        #expect(why.contains("didn't answer"), "\(why)")
        #expect(lead.records.statusLine?.contains("didn't answer") == true, "\(lead.records.statusLine ?? "")")
        #expect(flaky.count(FlakyHost.setsHead(of: "main")) == 0)
        #expect(try vault.head(root: root, branch: "main") == known)
        #expect(head("main", root) == moved)
    }

    // MARK: After the fast-forward

    /// Before: `try vault.setHead` threw past everything: the board kept the task unmerged, the reply didn't say main had
    /// moved, and the next merge was refused as a move nobody made.
    @Test func aHeadTheVaultCouldntRecordIsSaidAndTheNextMergeIsntRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let flaky = FlakyHost()
        let lead = try lead(root, runtime, through: flaky)
        try audited("b", lead, runtime, root: root)
        try audited("c", lead, runtime, root: root)
        let before = head("main", root)

        flaky.drop(FlakyHost.setsHead(of: "main"))
        let merged = lead.call("merge", ["task": "add-b"])

        let landed = head("main", root)
        #expect(landed != before)
        #expect(merged.isError && merged.text.contains("main moved to \(landed.prefix(8))"), "\(merged.text)")
        let progress = read(BoardStore(root: root).recordPath("progress.md"))
        #expect(progress.contains("main moved to \(landed.prefix(8))"), "\(progress)")
        // The merge has happened: the board says so, and running it again says that rather than merging nothing.
        #expect(BoardStore(root: root).load().task("add-b")?.status == .done)
        #expect(BoardStore(root: root).load().task("add-b")?.merged?.commit == landed)
        #expect(try vault.head(root: root, branch: "main") == before)

        flaky.drop(nil)
        let next = lead.call("merge", ["task": "add-c"])

        #expect(!next.isError, "\(next.text)")
        #expect(try vault.head(root: root, branch: "main") == head("main", root))
        #expect(LeadVault.BaseMoveRefusal.load(root: root) == nil)
        #expect(read(BoardStore(root: root).recordPath("progress.md")).contains("Recorded main at \(landed.prefix(8))"))
    }

    /// What's remembered is that one move: a commit on top of it is still nobody's.
    @Test func aMoveOnTopOfTheUnrecordedMergeIsStillRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let flaky = FlakyHost()
        let lead = try lead(root, runtime, through: flaky)
        try audited("b", lead, runtime, root: root)
        try audited("c", lead, runtime, root: root)
        let before = head("main", root)
        flaky.drop(FlakyHost.setsHead(of: "main"))
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        flaky.drop(nil)
        try commit("sneaked.txt", "nobody audited this\n", in: root)

        let next = lead.call("merge", ["task": "add-c"])

        #expect(next.isError && next.text.contains("moved since the lead last left it"), "\(next.text)")
        #expect(try vault.head(root: root, branch: "main") == before)
        #expect(BoardStore(root: root).load().task("add-c")?.status != .done)
    }

    @Test func aBoardThatCantBeWrittenAfterTheFastForwardIsSaid() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let flaky = FlakyHost()
        let lead = try lead(root, runtime, through: flaky)
        try audited("b", lead, runtime, root: root)
        let store = BoardStore(root: root)
        let (board, before) = (store.file, head("main", root))
        // The moment the merge records the head: the fast-forward is done, the board's write is next.
        flaky.beforeEach { request in
            if FlakyHost.setsHead(of: "main")(request) { try? "not a board".write(toFile: board, atomically: true, encoding: .utf8) }
        }

        let merged = lead.call("merge", ["task": "add-b"])

        let landed = head("main", root)
        #expect(landed != before)
        #expect(merged.isError && merged.text.contains("main moved to \(landed.prefix(8))") && merged.text.contains("the board couldn't be written"), "\(merged.text)")
        #expect(read(store.recordPath("progress.md")).contains("main moved to \(landed.prefix(8))"))
        #expect(try vault.head(root: root, branch: "main") == landed)
    }
}
