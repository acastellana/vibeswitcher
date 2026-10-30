import AppKit
import Darwin
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// With an accessibility client attached the main window froze for 4–16 s at a time while a lead's chat was shown
/// (hang-20261030-095700, 100754, 100802, 100807, 101253, 101318): SwiftUI keeps its accessibility tree up to date while
/// a client watches the app, and on every update it built and compared the sidebar's, the header's and the composer's
/// nodes again (`AccessibilityViewGraph.needsUpdate`, `AccessibilityChildBehavior.Combine` merging each row's texts,
/// `PlatformItemList.Item.Accessibility.resolvedAttributedLabel`). A sidebar of 30 rows (a lead and its team among them),
/// the selected lead's header and a composer with its chips, updated as the host's sessions change, and walked as a
/// client walks them after each update.
@MainActor
@Suite(.serialized)
struct MainWindowAccessibilityTests {
    let scratch = Scratch()
    static let now = Date()
    static let projects = ["alpha", "bravo", "charlie", "delta"]

    /// 30 window sessions over four projects: a lead with four workers and a verifier under it, the rest on their own;
    /// all working but a few waiting for you.
    static func members() -> [SidebarDiffTests.Member] {
        let root = "/Users/you/dev/alpha"
        var members = [SidebarDiffTests.member("Lead the work in alpha", project: "alpha", label: "Lead · alpha", cwd: root)]
        for index in 0..<4 {
            members.append(SidebarDiffTests.member("Task \(index): a change of its own", project: "alpha", label: "Worker: task-\(index)",
                                                   cwd: root + "/.vibeswitcher/worktrees/task-\(index)"))
        }
        members.append(SidebarDiffTests.member("Audit of task 0", project: "alpha", label: "Verifier: task-0",
                                               cwd: root + "/.vibeswitcher/worktrees/task-0-audit"))
        for index in 0..<24 {
            let project = projects[index % projects.count]
            var member = SidebarDiffTests.member("Session \(index) in \(project)", project: project, label: "Shell", cwd: "/Users/you/dev/\(project)")
            if index % 5 == 0 { member.status = .needsInput }
            members.append(member)
        }
        return members
    }

    /// The main window's three hosting views that matter here, as `MainWindowController` lays them out: the sidebar on
    /// the left, the header over the chat's place, the composer under it.
    final class Window {
        let window: NSWindow
        let sidebar: NSView, header: NSView, composer: NSView

        init(model: WindowModel, leads: LeadController, host: HostClient, chat: ChatModel, row: WindowRow) {
            window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
            sidebar = NSHostingView(rootView: SessionListView(model: model, leads: leads, actions: EndedSnapshots.actions))
            sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
            header = NSHostingView(rootView: SessionHeaderView(model: model, host: host, actions: EndedSnapshots.actions))
            header.frame = NSRect(x: 300, y: 748, width: 900, height: 52)
            composer = NSHostingView(rootView: ComposerView(chat: chat, composer: chat.composer, rowID: row.draftKey, agent: .claude, working: true,
                                                            actions: ComposerActions(send: { _ in false }, steer: { _ in false }, stop: {}, cycleMode: {})))
            composer.frame = NSRect(x: 300, y: 0, width: 900, height: 140)
            [sidebar, header, composer].forEach(content.addSubview)
            window.contentView = content
            window.orderFrontRegardless()
        }

        func settle() {
            for view in [sidebar, header, composer] { view.layoutSubtreeIfNeeded() }
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        }
    }

    /// The sidebar, header and composer in a window, a client attached unless `attach` is false; `body` runs with them and
    /// the way to update them.
    func withWindow(attach: Bool = true, _ body: (Window, _ update: (Int) -> Void, _ rows: [WindowRow]) async throws -> Void) async throws {
        let folder = scratch.url("main-ax")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer { UserDefaults.standard.set(saved, forKey: "windowGrouping") }
        let model = WindowModel()
        model.grouping = .projects
        var members = Self.members()
        SidebarDiffTests.feed(model, members, at: Self.now)
        let lead = try #require(model.allRows.first { model.role(of: $0) == .lead })
        model.selectedID = lead.id
        model.expandedTeams.insert(lead.id)

        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { folder }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: folder, home: folder.path) { _ in "true" }
        // The lead's conversation, for the composer's chips: its model, context and tokens out.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/main-ax-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("lead.jsonl")
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "u1", "timestamp": "2026-10-30T09:00:00Z", "message": ["role": "user", "content": "Lead the work in alpha"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-10-30T09:00:05Z",
             "message": ["role": "assistant", "id": "m1", "model": "claude-opus-5-5", "content": [["type": "text", "text": "On it."]],
                         "usage": ["input_tokens": 45_000, "output_tokens": 1_200]]],
        ]
        try Data(lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8 + [0x0A])
            .write(to: transcript)
        let chat = ChatModel()
        chat.show(path: transcript.path)
        #expect(await until { chat.state == .ready && chat.log.usage != nil }, "the chat didn't load")
        chat.mode = .plan
        let window = Window(model: model, leads: leads, host: host, chat: chat, row: lead)
        defer { window.window.close() }
        // An update as the host's sessions change: one of the team's workers turns to you, or back to work.
        func update(_ step: Int) {
            let index = 1 + step % 4
            members[index].status = members[index].status == .working ? .needsInput : .working
            SidebarDiffTests.feed(model, members, at: Self.now.addingTimeInterval(Double(step)))
        }
        #expect(await until { window.settle(); return model.rows.count >= 30 }, "the sidebar didn't fill")
        window.settle()
        if attach { #expect(AXClient.attach(window.window) == 3) }
        window.settle()
        try await body(window, update, model.rows)
    }

    /// Each sidebar row is one element that says what the row says: its status, its title, its state; the team's
    /// rows say their role.
    @Test func eachSidebarRowIsOneElementWithAMeaningfulLabel() async throws {
        try await withWindow { window, _, rows in
            let read = AXClient.rows(window.sidebar).filter { !$0.texts.isEmpty }
            // A session's row: the list's row, its cell and one element in it (a group's header row has its name, count
            // and New Session menu).
            let sessions = read.filter { !$0.texts.contains { Self.projects.contains($0) } }
            #expect(sessions.count == rows.count, "rows: \(rows.count), read: \(read.map(\.texts))")
            #expect(sessions.allSatisfy { $0.elements == 3 && $0.texts.count == 1 }, "\(sessions.filter { $0.elements != 3 }.map(\.texts))")
            let labels = sessions.compactMap(\.texts.first)
            let lead = try #require(labels.first { $0.contains("Lead the work in alpha") }, "\(labels)")
            #expect(lead.hasPrefix("Lead: "), "\(lead)")
            #expect(lead.contains("team: 4 working"), "the lead's team summary: \(lead)")
            let worker = try #require(labels.first { $0.contains("Task 2: a change of its own") }, "\(labels)")
            #expect(worker.hasPrefix("Worker: "), "\(worker)")
            // The header's pill and the composer's chips say what they show.
            let header = AXClient.texts(window.header)
            #expect(header.contains("Lead the work in alpha") && header.contains("Working"), "\(header)")
            let composer = AXClient.texts(window.composer)
            #expect(composer.contains("45.0k context") && composer.contains("Opus 5.5"), "\(composer)")
            let verifier = try #require(labels.first { $0.contains("Audit of task 0") }, "\(labels)")
            #expect(verifier.hasPrefix("Verifier: "), "\(verifier)")
            let waiting = try #require(labels.first { $0.contains("Session 5 in") }, "\(labels)")
            #expect(waiting == "Session 5 in bravo, Claude, needs you", "\(waiting)")
        }
    }

    /// The main thread's CPU for each of `updates` updates, settled and walked as a client walks the window (the walk
    /// finds nothing without one); and the most one took.
    static func cost(_ window: Window, _ update: (Int) -> Void, updates: Int = 30) -> (each: TimeInterval, worst: TimeInterval) {
        let main = mach_thread_self()
        var worst: TimeInterval = 0
        let before = TeamChurnBench.cpu(of: main)
        for step in 0..<updates {
            let start = TeamChurnBench.cpu(of: main)
            update(step)
            window.settle()
            _ = AXClient.walk(window.window)
            worst = max(worst, TeamChurnBench.cpu(of: main) - start)
        }
        return ((TeamChurnBench.cpu(of: main) - before) / Double(updates), worst)
    }

    /// The sidebar's, header's and composer's trees stay small: a row is one element, not each of its texts and marks;
    /// and an update walked by a client costs milliseconds, not seconds.
    @Test func anUpdateWithAClientAttachedStaysCheap() async throws {
        var without: (each: TimeInterval, worst: TimeInterval) = (0, 0)
        try await withWindow(attach: false) { window, update, _ in without = Self.cost(window, update) }
        try await withWindow { window, update, rows in
            let elements = (sidebar: AXClient.walk(window.sidebar), header: AXClient.walk(window.header), composer: AXClient.walk(window.composer))
            let with = Self.cost(window, update)
            print(String(format: "RESULT main-ax rows %d, elements sidebar %d header %d composer %d, main-thread ms per update %.1f (worst %.1f), "
                         + "without a client %.1f (worst %.1f)", rows.count, elements.sidebar, elements.header, elements.composer,
                         with.each * 1000, with.worst * 1000, without.each * 1000, without.worst * 1000))
            // The sidebar: the grouping, the list, three for each row (the list's row, its cell, the row's one element),
            // five for each project's header row, and the filter.
            #expect(elements.sidebar <= rows.count * 3 + Self.projects.count * 5 + 15, "sidebar elements: \(elements.sidebar)")
            #expect(elements.header <= 20, "header elements: \(elements.header)")
            #expect(elements.composer <= 20, "composer elements: \(elements.composer)")
            // Milliseconds, not seconds: the main thread's own CPU (a loaded Mac's waits aren't in it), at most a second
            // for the dearest update.
            #expect(with.worst < 1, "an update took \(Int(with.worst * 1000)) ms of the main thread's CPU")
        }
    }
}
