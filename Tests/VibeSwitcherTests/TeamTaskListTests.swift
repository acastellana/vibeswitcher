import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A Team row is drawn again only when what it shows changes (`TeamRowView` is equatable), so a row equal to the one
/// before keeps the closures it was first drawn with. Its link to the task it's folded into must still find the rows
/// of now: here the task it links to went to the finished ones (folded away) while the row itself stayed the same.
@MainActor
struct TeamTaskListTests {
    final class Rows: ObservableObject {
        @Published var rows: [TeamRow]
        init(_ rows: [TeamRow]) { self.rows = rows }
    }

    struct Root: View {
        @ObservedObject var model: Rows

        var body: some View {
            TeamTaskList(rows: model.rows, now: TeamRowsTests.now, summary: { _ in nil }, canOpen: { _ in false }, open: { _ in })
                .frame(width: 400, height: 400)
        }
    }

    static func row(_ task: LeadTask, _ group: TeamRow.Group, foldedInto: LeadTask? = nil) -> TeamRow {
        TeamRow(task: task, group: group, mark: group == .finished ? .merged : .working, state: group == .finished ? "Merged" : "Working",
                foldedInto: foldedInto)
    }

    /// The element of the window's tree offering the action named `name`, and that action.
    static func action(_ name: String, in element: AnyObject) -> NSAccessibilityCustomAction? {
        if let element = element as? NSObject, element.responds(to: #selector(NSAccessibilityProtocol.accessibilityCustomActions)),
           let actions = element.perform(#selector(NSAccessibilityProtocol.accessibilityCustomActions))?.takeUnretainedValue() as? [NSAccessibilityCustomAction],
           let found = actions.first(where: { $0.name == name }) {
            return found
        }
        let children = (element as? NSObject).flatMap {
            $0.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren))
                ? $0.perform(#selector(NSAccessibilityProtocol.accessibilityChildren))?.takeUnretainedValue() as? [AnyObject] : nil
        } ?? []
        for child in children { if let found = action(name, in: child) { return found } }
        return nil
    }

    @Test func aRowsLinkFindsTheRowsOfNow() async throws {
        let target = TeamRowsTests.task("target", .running, title: "Target task")
        let source = TeamRowsTests.task("source", .running, title: "Source task")
        // The link's row stays the same throughout; only the target's row moves to the finished ones.
        let linking = Self.row(source, .working, foldedInto: target)
        let model = Rows([linking, Self.row(target, .working)])
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(model: model))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        }
        #expect(AXClient.attach(window) == 1)
        settle()
        model.rows = [linking, Self.row(target, .finished)]
        settle()
        let texts = { AXClient.texts(window).joined(separator: "\n") }
        // Folded away: the finished ones show only their fold.
        #expect(!texts().contains("Target task"))
        let open = try #require(Self.action("Open Target task", in: window), "the row's link isn't offered")
        if let handler = open.handler { _ = handler() } else { _ = open.target?.perform(open.selector, with: open) }
        #expect(await until { settle(); return texts().contains("Target task") }, "the link didn't unfold the finished rows to show its task")
    }
}
