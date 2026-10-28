import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The sidebar's List (`SessionListView`, an NSOutlineView underneath) driven in a window through the updates around the
/// crash of 2026-10-23 (EXC_BAD_ACCESS in -[NSOutlineView rowForItem:] ← _shouldShowOutlineCellForGroupRow: ← expandItem
/// ← SwiftUI's OutlineListCoordinator.diffRows): rows moving between the attention groups as their state changes,
/// groups coming and going, workers starting under an open lead, the Ended fold opening and closing, the grouping
/// switched, a row selected, with the pointer resting on a header.
///
/// The cause: a sidebar group row (a Section's header) under the pointer is kept by NSOutlineView, unretained, in
/// `_outlineCellTrackingAreaItem` (set by `_setOutlineCellTrackingAreaRow:` from the header's tracking area, cleared only
/// when the pointer leaves or enters another header). When SwiftUI's update takes that group out of the list it frees
/// the item, and the next `_shouldShowOutlineCellForGroupRow:` (drawing or expanding a group row) hands the freed item
/// to rowForItem:. These tests read that pointer without a message to it and require it to be one of the list's items.
@MainActor
@Suite(.serialized)
struct SidebarDiffTests {
    static let now = Date()
    /// Each test's scratch folder, removed when the test's suite instance goes: whatever way the test ends.
    let scratch = Scratch()

    /// One window session: its host record and, while its agent runs, the scan's status.
    struct Member {
        var host: HostSession
        var status: SessionStatus?
    }

    static func member(_ title: String, project: String, label: String, cwd: String? = nil) -> Member {
        let host = HostSession(id: UUID(), tty: "ttys\(Int.random(in: 100...999))", childPID: 1, cwd: cwd ?? "/Users/you/dev/\(project)",
                               command: "claude", label: label, agent: "claude", title: title, startedAt: now - 3_600, cols: 80, rows: 24, exit: nil)
        return Member(host: host, status: .working)
    }

    static func feed(_ model: WindowModel, _ members: [Member], at now: Date) {
        let sessions = members.compactMap { member -> Session? in
            guard let status = member.status, member.host.exit == nil else { return nil }
            var session = Session(tty: member.host.tty, agent: .claude, pid: 1, startedAt: member.host.startedAt, cwd: member.host.cwd,
                                  project: (member.host.cwd as NSString).lastPathComponent, task: nil, status: status, statusSince: now,
                                  detail: nil, hasHooks: true, inTerminalApp: false)
            session.hostID = member.host.id
            session.customName = member.host.title
            return session
        }
        model.update(sessions: sessions, hosted: members.map(\.host), table: TableRead(at: now))
    }

    /// The sidebar in a window off screen, drawn; the window closes when the returned closure runs.
    static func show(_ model: WindowModel, scratch: URL) async throws -> (hosting: NSView, close: () -> Void) {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path) { _ in "true" }
        let hosting = NSHostingView(rootView: SessionListView(model: model, leads: leads, actions: EndedSnapshots.actions)
            .frame(width: 300, height: 700))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        return (hosting, { window.close() })
    }

    static func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews { if let found = outline(in: subview) { return found } }
        return nil
    }

    /// The rows AppKit gives a Show/Hide button on hover: the sidebar's group rows.
    static func headerAreas(_ outline: NSOutlineView) -> [NSTrackingArea] {
        outline.trackingAreas.filter { $0.userInfo?["NSOutlineCellTrackingAreaRowKey"] != nil }
    }

    /// The pointer enters every header in turn and stays on `row`'s (or the last one's), as the window would tell
    /// AppKit: a mouseEntered: to the header's tracking area's owner (`NSOVTrackingAreaOwner`).
    static func hover(_ outline: NSOutlineView, row: Int? = nil) {
        guard let window = outline.window else { return }
        let areas = headerAreas(outline)
        let chosen = areas.first { ($0.userInfo?["NSOutlineCellTrackingAreaRowKey"] as? Int) == row } ?? areas.last
        for area in areas.filter({ $0 !== chosen }) + (chosen.map { [$0] } ?? []) {
            let point = outline.convert(NSPoint(x: area.rect.midX, y: area.rect.midY), to: nil)
            guard let owner = area.owner as? NSObject,
                  let event = NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)
            else { continue }
            owner.perform(#selector(NSResponder.mouseEntered(with:)), with: event)
        }
    }

    /// The group row NSOutlineView holds as hovered, read without a message to it (it may be freed).
    static func hovered(_ outline: NSOutlineView) -> UnsafeRawPointer? {
        guard let ivar = class_getInstanceVariable(NSOutlineView.self, "_outlineCellTrackingAreaItem") else { return nil }
        return UnsafeRawPointer(Unmanaged.passUnretained(outline).toOpaque()).load(fromByteOffset: ivar_getOffset(ivar), as: UnsafeRawPointer?.self)
    }

    /// Whether the hovered group, if any, is still one of the list's items.
    static func hoveredIsListed(_ outline: NSOutlineView) -> Bool {
        guard let hovered = hovered(outline) else { return true }
        return (0..<outline.numberOfRows).contains { row in
            outline.item(atRow: row).map { UnsafeRawPointer(Unmanaged.passUnretained($0 as AnyObject).toOpaque()) == hovered } ?? false
        }
    }

    /// What the crash needs is gone: the sidebar has no group rows, so no header AppKit tracks for its Show/Hide button
    /// (today's had one per Section).
    @Test func theSidebarHasNoGroupRows() async throws {
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer {
            UserDefaults.standard.set(saved, forKey: "windowGrouping")
            UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
        }
        let model = WindowModel()
        var members = [Self.member("Alpha", project: "genswap", label: "Shell"), Self.member("Beta", project: "acme", label: "Shell"),
                       Self.member("Gamma", project: "acme", label: "Shell")]
        members[0].status = .needsInput
        members[2].host.exit = HostSession.Exit(status: 129, at: Self.now)
        Self.feed(model, members, at: Self.now)
        model.endedOpen = true
        let (hosting, close) = try await Self.show(model, scratch: scratch.url("sidebar-groups"))
        defer { close() }
        for grouping in [WindowGrouping.attention, .projects] {
            model.grouping = grouping
            try await Task.sleep(for: .milliseconds(200))
            let outline = try #require(Self.outline(in: hosting))
            // Two groups and the Ended fold, each a header row, and the three sessions.
            #expect(outline.numberOfRows == 6, "\(grouping)")
            #expect(Self.headerAreas(outline).isEmpty, "\(grouping)")
            #expect((0..<outline.numberOfRows).allSatisfy { outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: $0)!) != true },
                    "\(grouping)")
        }
    }

    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A random walk of the list's updates, each drawn by the real List, a run-loop turn apart, the pointer on a
    /// header half the time. After each: no id twice, every row maps back to itself, the hovered group is listed.
    /// Each step awaits its turn rather than running the run loop itself: a test holding the main actor through the
    /// whole walk (11 s) held every other test's main-queue work with it (HostAppMainThreadTests, PickerCardTests).
    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func theListSurvivesItsUpdates(seed: UInt64) async throws {
        let saved = UserDefaults.standard.string(forKey: "windowGrouping")
        defer {
            UserDefaults.standard.set(saved, forKey: "windowGrouping")
            UserDefaults.standard.removeObject(forKey: WindowModel.endedOpenKey)
        }
        let model = WindowModel()
        model.grouping = .attention
        var random = Generator(state: seed)
        var members = [Self.member("Lead", project: "genswap", label: "Lead · genswap"),
                       Self.member("Alpha", project: "genswap", label: "Shell"),
                       Self.member("Beta", project: "acme", label: "Shell"),
                       Self.member("Gamma", project: "tools", label: "Shell")]
        let lead = "host:\(members[0].host.id)"
        Self.feed(model, members, at: Self.now)
        let (hosting, close) = try await Self.show(model, scratch: scratch.url("sidebar-diff"))
        defer { close() }

        let statuses: [SessionStatus] = [.needsInput, .working, .done, .idle]
        var clock = Self.now
        for step in 0..<200 {
            clock += 5
            let outline = try #require(Self.outline(in: hosting))
            if Bool.random(using: &random) {
                let headers = Self.headerAreas(outline).compactMap { $0.userInfo?["NSOutlineCellTrackingAreaRowKey"] as? Int }
                Self.hover(outline, row: headers.randomElement(using: &random))
            }
            switch Int.random(in: 0..<10, using: &random) {
            case 0 where members.count < 14:
                // A worker starts under the lead.
                let name = "w\(step)"
                members.append(Self.member("Worker \(name)", project: "genswap", label: "Worker: \(name)",
                                           cwd: "/Users/you/dev/genswap/.vibeswitcher/worktrees/\(name)"))
            case 1:
                // One ends; or one ended long ago is removed.
                let index = Int.random(in: 1..<members.count, using: &random)
                if members[index].host.exit == nil {
                    members[index].host.exit = HostSession.Exit(status: 129, at: clock)
                } else {
                    members.remove(at: index)
                }
            case 2:
                model.toggleTeam(lead)
            case 3:
                model.endedOpen.toggle()
            case 4:
                if Int.random(in: 0..<3, using: &random) == 0 { model.grouping = model.grouping == .attention ? .projects : .attention }
            case 5:
                model.selectedID = model.rows.randomElement(using: &random)?.id
            default:
                // Several change state at once (the attention groups move them).
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    let index = Int.random(in: 0..<members.count, using: &random)
                    members[index].status = statuses.randomElement(using: &random)
                }
            }
            Self.feed(model, members, at: clock)
            try await Task.sleep(for: .milliseconds(10))

            let folded = model.folded(model.arranged)
            let ids = folded.sections.map(\.id) + folded.sections.flatMap(\.rows).map(\.id) + folded.ended.map(\.id)
            #expect(Set(ids).count == ids.count, "step \(step): an id twice in \(ids)")
            for row in 0..<outline.numberOfRows {
                let item = try #require(outline.item(atRow: row), "step \(step)")
                #expect(outline.row(forItem: item) == row, "step \(step): row \(row)")
            }
            // A freed group is looked up by the next hover or group row drawn: stop at the first.
            try #require(Self.hoveredIsListed(outline), "step \(step): the hovered group left the list and is still held")
        }
    }
}
