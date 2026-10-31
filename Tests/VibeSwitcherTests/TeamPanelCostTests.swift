import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// With a lead selected the window froze for 10–144 s at a time on a loaded Mac (2026-10-28, 17:17–17:57): the Team tab
/// and the inspector redid work in their bodies on every update (`TeamRows.finishedTitle`, the glance's summary
/// lines, `LeadController.lead(for:)` with `LeadTeams.role`, `BriefingModel.project`, the window's rows copied, a
/// message's `needsSummary`), read files on the main thread (the Mac-wide line's limits, the heavy slots' locks), and
/// every Team row was in the accessibility tree a client walks. Each of those is made once for its inputs here, or
/// off the main thread, and only the rows on screen (and a screen either side) are exposed.
@MainActor
@Suite(.serialized)
struct TeamPanelCostTests {
    let temp = Scratch()

    /// What a parent's update hands a view: drawn again for each change, its other inputs the same.
    final class Ticker: ObservableObject {
        @Published var count = 0
    }

    func show<V: View>(_ view: V, size: NSSize = NSSize(width: 400, height: 600)) -> (window: NSWindow, settle: () -> Void) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        return (window, {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        })
    }

    static func rows(_ count: Int, finished: Int = 0) -> [TeamRow] {
        var board = LeadBoard()
        board.tasks = (0..<count).map { TeamRowsTests.task(String(format: "row-%02d", $0), .running, title: String(format: "Alpha-%02d", $0)) }
            + (0..<finished).map { TeamRowsTests.task("done-\($0)", .done, title: "Merged \($0)") }
        return TeamRows.rows(board, seen: [:])
    }

    // MARK: TeamRows.finishedTitle < TeamTaskList (hang-20261028-174102)

    struct ListRoot: View {
        @ObservedObject var ticker: Ticker
        let rows: [TeamRow]
        let parts: TeamTaskList.Parts

        var body: some View {
            TeamTaskList(rows: rows, now: TeamRowsTests.now.addingTimeInterval(Double(ticker.count) * 10), summary: { _ in nil },
                         canOpen: { _ in false }, open: { _ in }, parts: parts)
        }
    }

    @Test func theTaskListSplitsItsRowsOncePerRows() {
        let rows = Self.rows(5, finished: 40)
        let parts = TeamTaskList.Parts()
        let split = parts.split(rows)
        #expect(split.open.count == 5 && split.finished.count == 40 && split.title == "Merged (40)")
        _ = parts.split(rows)
        #expect(parts.made == 1)
        // Drawn as the clock ticks: the same rows, split once.
        let ticker = Ticker()
        let fresh = TeamTaskList.Parts()
        let (window, settle) = show(ListRoot(ticker: ticker, rows: rows, parts: fresh))
        defer { window.close() }
        settle()
        for _ in 0..<5 {
            ticker.count += 1
            settle()
        }
        #expect(fresh.made == 1)
        // Other rows: split again.
        _ = fresh.split(Self.rows(5, finished: 40))
        #expect(fresh.made == 2)
    }

    // MARK: LeadTeamView.glancing < LeadTeamView.body (173406, 175314)

    struct TeamRoot: View {
        @ObservedObject var ticker: Ticker
        let board: LeadBoard
        let rows: [TeamRow]
        let lines: LeadTeamView.Lines
        let version: Int?
        let looked: () -> Void

        var body: some View {
            LeadTeamView(root: "/r", board: board, seen: [:], open: { _ in }, decisions: [],
                         summary: { _ in looked(); return nil }, keepingAwake: false,
                         mac: MacLine(text: "Mac: load \(ticker.count), 10 team sessions", spoken: "", isOver: false), rows: rows,
                         linesVersion: version, lines: lines)
        }
    }

    @Test func theGlanceLooksUpItsLinesOncePerInputs() {
        var board = LeadBoard()
        board.tasks = (0..<40).map { TeamRowsTests.task("t\($0)", .running) }
        let rows = TeamRows.rows(board, seen: [:])
        let lines = LeadTeamView.Lines()
        var looked = 0
        let ticker = Ticker()
        let (window, settle) = show(TeamRoot(ticker: ticker, board: board, rows: rows, lines: lines, version: 7, looked: { looked += 1 }))
        defer { window.close() }
        settle()
        let first = lines.made
        #expect(first >= 1)
        // The Team tab drawn again (here its Mac line changed) with the same rows, decisions and summaries: no look-ups.
        for _ in 0..<5 {
            ticker.count += 1
            settle()
        }
        #expect(lines.made == first)
        #expect(looked == 40 * first)
        // A summary came (the version moved): looked up again, once.
        _ = lines.lines(rows: rows, decisions: [], version: 8, summary: { _ in nil }, decisionSummary: { _ in nil })
        _ = lines.lines(rows: rows, decisions: [], version: 8, summary: { _ in nil }, decisionSummary: { _ in nil })
        #expect(lines.made == first + 1)
        // Without a version (pictures): every time.
        _ = lines.lines(rows: rows, decisions: [], version: nil, summary: { _ in nil }, decisionSummary: { _ in nil })
        _ = lines.lines(rows: rows, decisions: [], version: nil, summary: { _ in nil }, decisionSummary: { _ in nil })
        #expect(lines.made == first + 3)
    }

    // MARK: TeamSummaryModel.line(LeadDecision) < LeadTeamView.Lines.lines < LeadTeamView.glancing (hang-20261031-003909)

    /// A lead's decisions.md of a busy day: 64 decisions, about 44 KB, two in three long enough for a summary (synthetic).
    static func decisions(_ count: Int = 64) -> [LeadDecision] {
        let words = ["merge", "the", "worker's", "branch", "after", "its", "suite", "passes", "under", "load", "then", "retire"]
        return (0..<count).map { index in
            let length = index % 3 == 0 ? 8 : 30 + index % 20
            let text = (0..<length).map { words[($0 + index) % words.count] }.joined(separator: " ")
            let why = String(repeating: "Because the lead checked it twice — and it held. ", count: 10)
            return LeadDecision(at: 1_793_400_000 + Double(index) * 61.25, text: text, why: why)
        }
    }

    /// A model that writes a line for each decision at once, on the calling thread.
    static func summaries() -> TeamSummaryModel {
        TeamSummaryModel(generate: { prompt in "Plain line \(prompt.utf8.count)" }, run: { $0() }, deliver: { $0() })
    }

    func glance(_ board: LeadBoard, _ decisions: [LeadDecision], _ lines: (rows: [String: String], decisions: [String: String])) -> TeamGlance {
        TeamGlance(board: board, rows: [], openable: [], notices: [:], decisions: decisions, lines: lines.rows, decisionLines: lines.decisions,
                   openRows: [], showFinished: false, openDecisions: [], showEarlier: false, clock: nil, open: { _ in }, answer: { _, _ in })
    }

    @Test func theDecisionLinesCostLittleAsSummariesCome() {
        let decisions = Self.decisions()
        let bytes = decisions.reduce(0) { $0 + $1.text.utf8.count + $1.why.utf8.count + 24 }
        #expect(decisions.count == 64 && (40_000...48_000).contains(bytes), "\(bytes) bytes")
        let long = decisions.filter(DecisionFeed.needsSummary)
        #expect(long.count == 42)
        let summaries = Self.summaries()
        summaries.request(rows: [], decisions: decisions)
        let board = LeadBoard()
        let lines = LeadTeamView.Lines()
        func pass(_ version: Int) -> TeamGlance {
            glance(board, decisions, lines.lines(rows: [], decisions: decisions, version: version, summary: { summaries.line($0) },
                                                 decisionSummary: { summaries.line($0) }))
        }
        var last = pass(summaries.version)
        #expect(last.decisionLines.count == 42 && last.decisionLines[long[0].id] == "Plain line \(SummaryPrompts.decision(long[0].text, why: long[0].why).utf8.count)")
        // A task's summary came each time (the version moved), the decisions and their lines didn't: the glance drawn
        // again is the same, and a pass costs less than walking every decision's text 3 times (`String.count`, what each
        // pass did for each decision, with making its key and its id). Both measured as this thread's CPU time, in turns,
        // so a slower core or a loaded Mac slows both alike: 1.2 walks now, 6 before.
        let passes = 500
        var same = 0
        var cost: UInt64 = 0, walks: UInt64 = 0, walked = 0
        for version in 1...passes {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let next = pass(summaries.version + version)
            if next == last { same += 1 }
            let passed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            walked &+= decisions.reduce(0) { $0 + $1.text.count }
            walks += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - passed
            cost += passed - start
            last = next
        }
        #expect(same == passes)
        #expect(walked > 0)
        let ratio = Double(cost) / Double(walks)
        #expect(ratio < 3, "a pass cost \(ratio) walks of the decisions' texts (\(Double(cost) / Double(passes) / 1000) µs of CPU)")
    }

    @Test func theDecisionLinesFollowTheirSummariesAndDecisions() {
        var decisions = Self.decisions(12)
        let summaries = TeamSummaryModel(generate: { _ in nil }, run: { $0() }, deliver: { $0() })
        let lines = LeadTeamView.Lines()
        func look() -> [String: String] {
            lines.lines(rows: [], decisions: decisions, version: summaries.version, summary: { summaries.line($0) },
                        decisionSummary: { summaries.line($0) }).decisions
        }
        // None written (the model gave nothing): none shown.
        summaries.request(rows: [], decisions: decisions)
        #expect(look().isEmpty)
        // A new decision, long, its line written: shown, under its id.
        let added = LeadDecision(at: 1_793_500_000, text: String(repeating: "Retire the old picker once the new one ships. ", count: 3), why: "")
        decisions.append(added)
        let writing = TeamSummaryModel(generate: { _ in "Retire the old picker" }, run: { $0() }, deliver: { $0() })
        writing.request(rows: [], decisions: decisions)
        let written = lines.lines(rows: [], decisions: decisions, version: 1, summary: { _ in nil }, decisionSummary: { writing.line($0) }).decisions
        #expect(written[added.id] == "Retire the old picker")
        #expect(written.count == decisions.filter(DecisionFeed.needsSummary).count)
        // The same decision with another text is another decision: its line isn't the old one's.
        decisions[decisions.count - 1].text = String(repeating: "Keep the old picker for one more release instead. ", count: 3)
        let edited = lines.lines(rows: [], decisions: decisions, version: 2, summary: { _ in nil }, decisionSummary: { writing.line($0) }).decisions
        #expect(edited[decisions.last!.id] == nil && edited[added.id] == nil)
        // Summaries turned off: none.
        writing.enabled = false
        #expect(lines.lines(rows: [], decisions: decisions, version: 3, summary: { _ in nil }, decisionSummary: { writing.line($0) }).decisions.isEmpty)
    }

    // MARK: LeadTeamPane.body (173905, 175702): the Mac-wide line off the main thread

    @Test func theMacLineIsMadeOffTheMainThreadOncePerSessions() async {
        final class Runs: @unchecked Sendable {
            let lock = NSLock()
            var onMain = 0, off = 0
            func ran(main: Bool) {
                lock.lock()
                if main { onMain += 1 } else { off += 1 }
                lock.unlock()
            }
            func counts() -> (onMain: Int, off: Int) {
                lock.lock()
                defer { lock.unlock() }
                return (onMain, off)
            }
        }
        let runs = Runs()
        let queue = DispatchQueue(label: "mac-line-test")
        let reads = LeadTeamPane.MacReads(run: { work in queue.async { runs.ran(main: Thread.isMainThread); work() } })
        let session = HostSession(id: UUID(), tty: "ttys1", childPID: 1, cwd: "/r/.vibeswitcher/worktrees/a", command: "claude",
                                  label: "Worker: A", agent: "claude", title: "A", startedAt: Date(), cols: 80, rows: 24, exit: nil)
        let hosted = [MacLine.Session(session)]
        var lines: [MacLine] = []
        reads.make(hosted, reread: false) { lines.append($0) }
        // The same sessions again (another draw, another session's change elsewhere): nothing made.
        reads.make(hosted, reread: false) { lines.append($0) }
        reads.make(hosted, reread: false) { lines.append($0) }
        #expect(reads.made == 1)
        #expect(await until { lines.count == 1 }, "the line never came")
        // A tick reads the load and limits again.
        reads.make(hosted, reread: true) { lines.append($0) }
        #expect(reads.made == 2)
        #expect(await until { lines.count == 2 }, "the tick's line never came")
        let counts = runs.counts()
        #expect(counts.onMain == 0 && counts.off == 2)
    }

    // MARK: LeadTeams.role < LeadController.lead(for:) < InspectorView.body (174653)

    func controller() throws -> LeadController {
        let folder = temp.url("team-panel-cost")
        let inbox = folder.appendingPathComponent("inbox")
        let stateDir = folder.appendingPathComponent("state")
        for dir in [inbox.path, stateDir.path] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        return LeadController(host: host, store: store, vault: vault, inbox: inbox, home: folder.path) { _ in "true" }
    }

    @Test func theLeadsRootsAreMadeOncePerSessionList() throws {
        let controller = try controller()
        func session(_ label: String, _ cwd: String) -> HostSession {
            HostSession(id: UUID(), tty: "ttys1", childPID: 1, cwd: cwd, command: "claude", label: label, agent: "claude", title: label,
                        startedAt: Date(), cols: 80, rows: 24, exit: nil)
        }
        let lead = session("Lead · acme", "/Users/you/dev/acme/")
        let sessions = [lead, session("Worker: One", "/Users/you/dev/acme/.vibeswitcher/worktrees/one"), session("Shell", "/Users/you/dev/tools")]
        #expect(controller.leadRoots(of: sessions) == [lead.id: "/Users/you/dev/acme"])
        for _ in 0..<10 { _ = controller.leadRoots(of: sessions) }
        #expect(controller.leadRootsMade == 1)
        // The inspector asking for the selected row's lead on every draw, the host's list the same.
        let row = WindowRow(content: .hosted(lead), project: "acme")
        let made = controller.leadRootsMade
        for _ in 0..<10 { _ = controller.lead(for: row) }
        #expect(controller.leadRootsMade <= made + 1)
        let settled = controller.leadRootsMade
        _ = controller.lead(for: row)
        #expect(controller.leadRootsMade == settled)
        // Another list from the host: made again, once.
        _ = controller.leadRoots(of: sessions + [session("Shell", "/Users/you/dev/tools")])
        _ = controller.leadRoots(of: sessions)
        #expect(controller.leadRootsMade == settled + 2)
    }

    // MARK: BriefingModel.project < InspectorView.body (171900), and the Mac line's sessions

    @Test func theInspectorKeepsItsBriefingAndSessionsByTheirInputs() {
        let cache = InspectorView.Cache()
        let briefing = BriefingModel(snapshot: { .init(boards: [:], sessions: []) }, language: { BriefingLanguage.named("en")! },
                                     keyStore: AppProof.MemorySecret(nil), generate: { _ in nil }, voice: BriefingButtonTests.FakeVoice(),
                                     defaults: temp.defaults("team-panel-cost"))
        let project = cache.briefing(briefing, root: "/r")
        for _ in 0..<10 { #expect(cache.briefing(briefing, root: "/r") === project) }
        #expect(cache.briefingsLooked == 1)
        #expect(cache.briefing(briefing, root: "/s") !== project)
        #expect(cache.briefingsLooked == 2)

        let sessions = [HostSession(id: UUID(), tty: "ttys1", childPID: 1, cwd: "/r", command: "claude", label: "Lead · r", agent: "claude",
                                    title: "r", startedAt: Date(), cols: 80, rows: 24, exit: nil)]
        let listed = cache.hosted(sessions)
        for _ in 0..<10 { #expect(cache.hosted(sessions) == listed) }
        #expect(cache.hostedMade == 1)
        // Another list from the host: listed again.
        #expect(cache.hosted(sessions + sessions).count == 2)
        #expect(cache.hostedMade == 2)
    }

    // MARK: WindowRow copies in SessionHeaderView.body (175306)

    @Test func theWindowsRowsAreCopiedOncePerChange() {
        UserDefaults.standard.removeObject(forKey: "windowGrouping")
        let model = WindowModel()
        let lead = SidebarArrangeTests.hosted("Lead · acme", cwd: "/Users/you/dev/acme")
        let other = SidebarArrangeTests.hosted("Shell", cwd: "/Users/you/dev/tools")
        model.update(sessions: [], hosted: [lead, other], table: TableRead(at: SidebarArrangeTests.now))
        model.select(hostID: lead.id)
        let made = model.allRowsMade
        // The header, the inspector and the sidebar asking on every draw.
        for _ in 0..<10 {
            #expect(model.selectedRow?.hostID == lead.id)
            _ = model.allRows
        }
        #expect(model.allRowsMade <= made + 1)
        let settled = model.allRowsMade
        // The same sessions again: nothing to copy.
        model.update(sessions: [], hosted: [lead, other], table: TableRead(at: SidebarArrangeTests.now))
        _ = model.selectedRow
        #expect(model.allRowsMade == settled)
        // Another selection: found among the rows kept.
        model.select(hostID: other.id)
        #expect(model.selectedRow?.hostID == other.id)
        #expect(model.allRowsMade == settled)
        // A session's title changed: copied again, once.
        var renamed = other
        renamed.title = "Shell, renamed"
        model.update(sessions: [], hosted: [lead, renamed], table: TableRead(at: SidebarArrangeTests.now))
        #expect(model.selectedRow?.title == model.allRows.first { $0.hostID == other.id }?.title)
        _ = model.allRows
        #expect(model.allRowsMade == settled + 1)
    }

    // MARK: TeamMessage.needsSummary < TeamSummaryModel.line < TeamMessageTLDR.body (175314)

    @Test func aMessagesNeedForASummaryIsWorkedOutOnce() {
        let summaries = TeamSummaryModel(generate: { _ in nil })
        summaries.enabled = true
        let long = TeamMessage(sender: .vibeSwitcher("worker fix-it"), body: String(repeating: "The worker ran the suite again. ", count: 40))
        for _ in 0..<20 { _ = summaries.line(long, id: "entry-1") }
        #expect(summaries.needsMade == 1)
        _ = summaries.line(long, id: "entry-2")
        #expect(summaries.needsMade == 2)
        #expect(summaries.needsSummary(long, id: "entry-1"))
        #expect(!summaries.needsSummary(TeamMessage(sender: .lead("lead of acme"), body: "Short."), id: "entry-3"))
    }

    // MARK: TestLock.holders < HeavySlots.look < LeadController.lookAtHeavySlots (175702)

    @Test func theHeavySlotsAreLookedAtOffTheMainThread() async throws {
        let controller = try controller()
        let folder = temp.url("team-panel-cost-locks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.watchHeavySlots(LeadWitness.HeavySlots(lock: TestLock(directory: folder.path)))
        var told = 0
        controller.lookAtHeavySlots { told += 1 }
        #expect(await until { told == 1 }, "the look never came back")
        let watch = try #require(controller.heavySlots)
        #expect(watch.looks == 1 && watch.lookedOnMain == 0)
    }

    // MARK: The Team list's accessibility tree (AccessibilityNode.updateChildren, impliedVisibility)

    struct ExposedRoot: View {
        let board: LeadBoard
        let rows: [TeamRow]

        var body: some View {
            LeadTeamView(root: "/r", board: board, seen: [:], open: { _ in }, decisions: [], keepingAwake: false, rows: rows)
        }
    }

    @Test func theTeamListExposesOnlyTheRowsOnScreen() async throws {
        var board = LeadBoard()
        board.tasks = (0..<60).map { TeamRowsTests.task(String(format: "row-%02d", $0), .running, title: String(format: "Alpha-%02d", $0)) }
        let rows = TeamRows.rows(board, seen: [:])
        #expect(rows.first?.task.title == "Alpha-00" && rows.last?.task.title == "Alpha-59")
        let (window, settle) = show(ExposedRoot(board: board, rows: rows), size: NSSize(width: 360, height: 500))
        defer { window.close() }
        settle()
        #expect(AXClient.attach(window) == 1)
        settle()
        func texts() -> String { AXClient.texts(window).joined(separator: "\n") }
        // Scrolled to the top: the first rows are seen; the last, screens below, go out of the tree once the scroll
        // view has said where it is.
        var seen = texts()
        _ = await until {
            settle()
            seen = texts()
            return !seen.contains("Alpha-59")
        }
        #expect(seen.contains("Alpha-00"), "the first row isn't in the tree")
        #expect(!seen.contains("Alpha-59"), "the last row, screens below, is in the tree")
        // Its label is the row's, as before.
        let first = try #require(rows.first)
        #expect(seen.contains(first.spoken(now: Date(), summary: nil).components(separatedBy: ",").first ?? "-"))

        // Scrolled to the end: the band follows.
        let scroll = try #require(Self.scrollView(in: window.contentView))
        let document = try #require(scroll.documentView)
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
        _ = await until {
            settle()
            seen = texts()
            return seen.contains("Alpha-59") && !seen.contains("Alpha-00")
        }
        #expect(seen.contains("Alpha-59"), "the last row, now on screen, isn't in the tree")
        #expect(!seen.contains("Alpha-00"), "the first row, now screens above, is in the tree")
    }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    /// The band and the rows it hides, as `ChatExposure` makes them: nothing hidden before the scroll view says where
    /// it is; then what's out of a screen either side.
    @Test func theExposureHidesRowsOutOfTheBand() async {
        let exposure = TeamExposure()
        for (id, top) in ["a": 0.0, "b": 400, "c": 900, "d": 2_100, "e": 2_500] { exposure.place(id, top: top) }
        #expect(exposure.unexposed.isEmpty)
        exposure.scrolled(top: 1_000, height: 500)
        #expect(exposure.unexposed == ["a", "d", "e"])
        // A little scroll: the band stays.
        exposure.scrolled(top: 1_100, height: 500)
        #expect(exposure.band == 500...2_000)
        // A row gone: no longer counted, once the layout is done.
        exposure.place("e", top: nil)
        #expect(await until { exposure.unexposed == ["a", "d"] })
    }
}
