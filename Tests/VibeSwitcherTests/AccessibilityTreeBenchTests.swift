import AppKit
import Darwin
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// What an update of the main window's sidebar and Team tab costs the main thread while an accessibility client watches
/// the app (a dictation tool, VoiceOver): SwiftUI keeps its accessibility tree up to date then, and on 2026-10-30/31 its
/// accessibility machinery (`AccessibilityViewGraph.needsUpdate`, `PropertiesTransform.updateValue`,
/// `AnyAccessibilityActionStorage.isEqual`) was most of the main thread in 20-odd freezes (scripts/hang-accessibility.py).
/// 100 sidebar rows and 100 Team rows, each update a tick of their clocks (every row's time moves on a minute) and one
/// row's state changing, the client reading the window after each. `RESULT ax-tree` lines: the main thread's CPU per
/// update with a client and without one.
@MainActor
@Suite(.serialized, .tags(.perf), .enabled(if: perfRun, perfOnly))
struct AccessibilityTreeBenchTests {
    let scratch = Scratch()
    static let rows = 100
    static let updates = 30

    /// What a parent's update hands a view: drawn again for each change.
    final class Ticker: ObservableObject {
        @Published var step = 0
    }

    func show<V: View>(_ view: V, size: NSSize) -> (window: NSWindow, settle: () -> Void) {
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

    /// The main thread's CPU per update (settled, then read as a client reads the window), and the dearest one.
    static func cost(_ window: NSWindow, settle: () -> Void, update: (Int) -> Void) -> (each: Double, worst: Double) {
        let main = mach_thread_self()
        var worst = 0.0
        let before = TeamChurnBench.cpu(of: main)
        for step in 0..<updates {
            let start = TeamChurnBench.cpu(of: main)
            update(step)
            settle()
            _ = AXClient.texts(window)
            worst = max(worst, TeamChurnBench.cpu(of: main) - start)
        }
        return ((TeamChurnBench.cpu(of: main) - before) / Double(updates) * 1000, worst * 1000)
    }

    // MARK: The sidebar

    /// `rows` window sessions over four projects: a lead with five workers and a verifier under it, the rest on their own.
    static func members(_ count: Int) -> [SidebarDiffTests.Member] {
        let root = "/Users/you/dev/alpha"
        var members = [SidebarDiffTests.member("Lead the work in alpha", project: "alpha", label: "Lead · alpha", cwd: root)]
        for index in 0..<5 {
            members.append(SidebarDiffTests.member("Task \(index): a change of its own", project: "alpha", label: "Worker: task-\(index)",
                                                   cwd: root + "/.vibeswitcher/worktrees/task-\(index)"))
        }
        members.append(SidebarDiffTests.member("Audit of task 0", project: "alpha", label: "Verifier: task-0",
                                               cwd: root + "/.vibeswitcher/worktrees/task-0-audit"))
        let projects = MainWindowAccessibilityTests.projects
        for index in 0..<(count - members.count) {
            let project = projects[index % projects.count]
            var member = SidebarDiffTests.member("Session \(index) in \(project)", project: project, label: "Shell", cwd: "/Users/you/dev/\(project)")
            if index % 5 == 0 { member.status = .needsInput }
            members.append(member)
        }
        return members
    }

    func sidebar(attach: Bool) throws -> (each: Double, worst: Double, elements: Int) {
        let folder = scratch.url("ax-bench")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer { UserDefaults.standard.set(saved, forKey: "windowGrouping") }
        let model = WindowModel()
        model.grouping = .projects
        var members = Self.members(Self.rows)
        SidebarDiffTests.feed(model, members, at: MainWindowAccessibilityTests.now)
        let lead = try #require(model.allRows.first { model.role(of: $0) == .lead })
        model.selectedID = lead.id
        model.expandedTeams.insert(lead.id)
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { folder }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: folder, home: folder.path) { _ in "true" }
        // Tall enough to hold every row: the list's rows off screen aren't in the tree, and a window's sidebar can hold 100.
        let (window, settle) = show(SessionListView(model: model, leads: leads, actions: EndedSnapshots.actions),
                                    size: NSSize(width: 300, height: 4_000))
        defer { window.close() }
        settle()
        #expect(model.rows.count >= Self.rows - 1, "rows: \(model.rows.count)")
        if attach { #expect(AXClient.attach(window) == 1) }
        settle()
        let elements = attach ? AXClient.walk(window.contentView!) : 0
        let cost = Self.cost(window, settle: settle) { step in
            // A worker turns to you or back to work, and every row's state began a minute earlier: each row's time moves.
            let index = 1 + step % 5
            members[index].status = members[index].status == .working ? .needsInput : .working
            SidebarDiffTests.feed(model, members, at: MainWindowAccessibilityTests.now.addingTimeInterval(-60 * Double(step + 1)))
        }
        return (cost.each, cost.worst, elements)
    }

    // MARK: The Team tab

    struct TeamRoot: View {
        @ObservedObject var ticker: Ticker
        let board: LeadBoard
        let rows: [[TeamRow]]

        var body: some View {
            // Each step its clock a minute on (every row's time changes) and every other step one row's state changed.
            LeadTeamView(root: "/r", board: board, seen: [:], open: { _ in }, decisions: [], keepingAwake: false,
                         clock: TeamRowsTests.now.addingTimeInterval(61 * Double(ticker.step)), rows: rows[ticker.step % 2], linesVersion: 1)
        }
    }

    func team(attach: Bool) throws -> (each: Double, worst: Double, elements: Int) {
        var board = LeadBoard()
        board.tasks = (0..<Self.rows).map { index in
            var task = TeamRowsTests.task(String(format: "row-%03d", index), [.running, .review, .running, .failed][index % 4],
                                          title: String(format: "Task %03d: a change of its own", index))
            task.verifier = index % 4 == 1 ? "v-\(index)" : nil
            return task
        }
        var changed = board
        changed.tasks[3].status = .review
        let rows = [TeamRows.rows(board, seen: [:]), TeamRows.rows(changed, seen: [:])]
        let ticker = Ticker()
        // The Team tab as the window shows it: a screen's rows exposed, and a screen either side (`TeamExposure`).
        let (window, settle) = show(TeamRoot(ticker: ticker, board: board, rows: rows), size: NSSize(width: 520, height: 800))
        defer { window.close() }
        settle()
        if attach { #expect(AXClient.attach(window) == 1) }
        settle()
        let elements = attach ? AXClient.walk(window.contentView!) : 0
        let cost = Self.cost(window, settle: settle) { _ in ticker.step += 1 }
        return (cost.each, cost.worst, elements)
    }

    // MARK: The chat

    /// A lead chat of 300 entries beside its Team tab (as `ChatAccessibilityTests` shows it), scrolled to its end, each
    /// update the window drawing it again for a host change.
    func chat(attach: Bool) async throws -> (each: Double, worst: Double, elements: Int) {
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/ax-bench-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        try ChatKeyViewLoopTests.transcript(turns: 75).write(to: path)
        let chat = ChatModel()
        chat.show(path: path.path)
        #expect(await until { chat.state == .ready && chat.staging == nil }, "the chat didn't load")
        let ticker = ChatAccessibilityTests.Ticker()
        let (window, settle) = show(ChatAccessibilityTests.Root(chat: chat, ticker: ticker, board: ChatAccessibilityTests.board()),
                                    size: NSSize(width: 1260, height: 1000))
        defer { window.close() }
        #expect(await until { settle(); return ChatKeyViewLoopTests.count("ChatTextView", in: window.contentView!) >= 10 }, "the chat's rows weren't drawn")
        if attach { #expect(AXClient.attach(window) == 1) }
        // Settled once the rows screens above what's on screen are out of the tree (the scroll view has said where it is).
        var last = -1
        _ = await until {
            settle()
            let count = attach ? AXClient.walk(window.contentView!) : 0
            defer { last = count }
            return count == last
        }
        let elements = attach ? AXClient.walk(window.contentView!) : 0
        let cost = Self.cost(window, settle: settle) { _ in ticker.count += 1 }
        return (cost.each, cost.worst, elements)
    }

    @Test func anUpdateOfASidebarATeamAndAChatWithAClientAttached() async throws {
        let runs: [(String, (Bool) async throws -> (each: Double, worst: Double, elements: Int))] = [
            ("sidebar", { try sidebar(attach: $0) }), ("team", { try team(attach: $0) }), ("chat", { try await chat(attach: $0) }),
        ]
        for (name, run) in runs {
            let without = try await run(false)
            let with = try await run(true)
            print(String(format: "RESULT ax-tree %@ rows %d elements %d, main-thread ms per update %.1f (worst %.1f), without a client %.1f "
                         + "(worst %.1f), the client's share %.1f", name, Self.rows, with.elements, with.each, with.worst, without.each,
                         without.worst, with.each - without.each))
            #expect(with.elements > 0, "\(name): the client read nothing")
            // A tick of 100 rows read by a client: well under a frame budget's worth of seconds, never the freezes' seconds.
            #expect(with.worst < 1_000, "\(name): an update took \(Int(with.worst)) ms of the main thread's CPU")
        }
    }
}

/// Where the main window's hosting views sit, as a hang report's stack shows it: how many views deep from the window's
/// frame view (the frame view 1), the count of `-[NSView _layoutSubtreeWithOldSize:]` frames above a hosting view's
/// `NSHostingView.layout()` in a layout pass. `RESULT ax-host` lines, for reading scripts/hang-accessibility.py's
/// hosting-view depths.
@MainActor
@Suite(.serialized, .tags(.perf), .enabled(if: perfRun, perfOnly))
struct HostingViewDepthTests {
    let temp = Scratch()

    @Test func theMainWindowsHostingViewsAndTheirDepths() throws {
        let controller = try SidePaneSizeTests().window()
        let window = try #require(controller.window)
        let frame = try #require(window.contentView?.superview)
        var found: [(depth: Int, name: String, frame: NSRect)] = []
        func visit(_ view: NSView, _ depth: Int) {
            let name = String(describing: type(of: view))
            if name.hasPrefix("NSHostingView") || name.contains("HostingView") { found.append((depth, name, view.frame)) }
            view.subviews.forEach { visit($0, depth + 1) }
        }
        visit(frame, 1)
        for host in found {
            print("RESULT ax-host depth \(host.depth) \(host.name.prefix(80)) \(Int(host.frame.width))x\(Int(host.frame.height))")
        }
        #expect(!found.isEmpty)
    }
}
