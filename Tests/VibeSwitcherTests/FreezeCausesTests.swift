import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The week to 2026-11-07 had 94 freezes a day (backlog B3). Its recurring stacks, each with a fix here:
/// - `SessionHeaderView.body` on top (hang-20261101-115308, hang-20261107-095327, hang-20261107-115633), and the
///   AttributeGraph and NSHostingView transactions with no app frame: the header was drawn again, its picker, menu and
///   clock remade, for every change any session made to the host or the window's model.
/// - `TeamRow.spoken` under `TeamRowView.header` (hang-20261101-172410, hang-20261107-002528, hang-20261107-011006):
///   a `DateComponentsFormatter` in every Team row's body.
@MainActor
@Suite(.serialized)
struct FreezeCausesTests {
    // MARK: SessionHeaderView

    func show<V: View>(_ view: V) -> (window: NSWindow, settle: () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 52), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 900, height: 52))
        window.contentView = host
        window.orderFrontRegardless()
        return (window, {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        })
    }

    @Test func theHeaderIsNotDrawnAgainWhenAnotherSessionChanges() {
        UserDefaults.standard.removeObject(forKey: "windowGrouping")
        let model = WindowModel()
        let host = HostClient(socketPath: "/nonexistent-freeze-causes", bundledBuild: { 0 }, note: { _ in })
        let lead = SidebarArrangeTests.hosted("Lead · acme", cwd: "/Users/you/dev/acme")
        var other = SidebarArrangeTests.hosted("Shell", cwd: "/Users/you/dev/tools")
        model.update(sessions: [], hosted: [lead, other], table: TableRead(at: SidebarArrangeTests.now))
        model.select(hostID: lead.id)
        let drawn = SessionHeaderBar.Drawn()
        let (window, settle) = show(SessionHeaderView(model: model, host: host, actions: EndedSnapshots.actions, drawn: drawn))
        defer { window.close() }
        settle()
        #expect(drawn.count >= 1)
        // The first updates after the first draw may draw it again (whatever they change, as SwiftUI settles the new
        // view): published to until one doesn't, at most 10 times.
        for _ in 0..<10 {
            let before = drawn.count
            host.objectWillChange.send()
            settle()
            if drawn.count == before { break }
        }
        let first = drawn.count, observed = drawn.observed
        // Another session's events, 20 of them: the host publishes each, and the window's model its sections.
        var drewAt: [Int] = []
        for index in 0..<20 {
            let before = drawn.count
            other.title = "Shell \(index)"
            model.update(sessions: [], hosted: [lead, other], table: TableRead(at: SidebarArrangeTests.now))
            host.objectWillChange.send()
            settle()
            if drawn.count != before { drewAt.append(index) }
        }
        // Each change was read (what the whole header did before, its picker, menu and clock remade each time), and the
        // bar wasn't drawn again.
        #expect(drawn.observed - observed >= 20, "read \(drawn.observed - observed) times: the changes didn't reach the header")
        let same = zip(drawn.shown, drawn.shown.dropFirst()).map { $0 == $1 }
        #expect(drawn.count == first, "drawn \(drawn.count - first) times for another session's 20 changes, at \(drewAt); each draw's values the same as the one before's: \(same); the last two: \(drawn.shown.suffix(2))")
        // The selected session's own change is shown.
        var renamed = lead
        renamed.title = "Lead · acme, renamed"
        model.update(sessions: [], hosted: [renamed, other], table: TableRead(at: SidebarArrangeTests.now))
        settle()
        #expect(drawn.count > first)
        // And so is another selection.
        let before = drawn.count
        model.select(hostID: other.id)
        settle()
        #expect(drawn.count > before)
    }

    // MARK: TeamRow.spoken

    /// The formatter it replaced, as it was made (`TeamRow`'s, before).
    static func formatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        // In GMT: in a zone with daylight saving, the formatter counted from 2001-01-01 local, and a day across its change
        // was 23 or 25 hours (over 84 days, in Europe's zones, it said a day more).
        calendar.timeZone = TimeZone(identifier: "GMT")!
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = units
        return formatter
    }

    static func formatted(_ seconds: TimeInterval, seconds secondsFormatter: DateComponentsFormatter, longer: DateComponentsFormatter) -> String {
        (seconds < 60 ? secondsFormatter : longer).string(from: max(0, seconds)) ?? ""
    }

    @Test func aRowsSpokenTimeReadsAsTheFormatterSaidIt() {
        let seconds = Self.formatter([.second]), longer = Self.formatter([.day, .hour, .minute])
        // Every 7 s for 3 days, each hour and half hour's edges, then days and their halves for a year.
        var values: [TimeInterval] = [-5, 0, 0.4, 0.6, 1, 1.5, 59, 59.6, 59.99]
        values += stride(from: 0, through: 3 * 86_400, by: 7).map(Double.init)
        for hour in 0..<(24 * 4) {
            for offset in [-1, 0, 1] as [Double] { values += [Double(hour) * 3600 + offset, Double(hour) * 3600 + 1800 + offset] }
        }
        for day in 0..<366 {
            for offset in [-1, 0, 1] as [Double] { values += [Double(day) * 86_400 + offset, Double(day) * 86_400 + 43_200 + offset] }
        }
        var differ: [String] = []
        for value in values where Durations.spoken(value) != Self.formatted(value, seconds: seconds, longer: longer) {
            differ.append("\(value): \(Durations.spoken(value)) vs \(Self.formatted(value, seconds: seconds, longer: longer))")
        }
        #expect(differ.isEmpty, "\(differ.prefix(10))")
        #expect(Durations.spoken(.infinity) == "0 seconds" && Durations.spoken(.nan) == "0 seconds")
        let row = TeamPanelCostTests.rows(1)[0]
        #expect(row.spoken(now: TeamRowsTests.now, summary: nil).hasPrefix("Alpha-00: "))
    }

    /// A day's Team list said: 250 rows' spoken labels, as each draw of the list makes them, with the formatter and now.
    @Test(.tags(.perf), .enabled(if: perfRun, perfOnly)) func aRowsSpokenLabelCostsAFractionOfTheFormatter() {
        let rows = TeamPanelCostTests.rows(250)
        let seconds = Self.formatter([.second]), longer = Self.formatter([.day, .hour, .minute])
        let clock = ContinuousClock()
        let rounds = 40
        var sink = 0
        let before = clock.measure {
            for round in 0..<rounds {
                for (index, row) in rows.enumerated() {
                    sink &+= Self.formatted(Double(index * 61 + round * 7 + 30), seconds: seconds, longer: longer).count + row.state.count
                }
            }
        }
        let after = clock.measure {
            for round in 0..<rounds {
                for (index, row) in rows.enumerated() {
                    sink &+= row.spoken(now: TeamRowsTests.now.addingTimeInterval(Double(index * 61 + round * 7 + 30)), summary: nil).count
                }
            }
        }
        let perRow = { (duration: Duration) in Double(duration.components.attoseconds) / 1e12 / Double(rounds * rows.count) + Double(duration.components.seconds) * 1e6 / Double(rounds * rows.count) }
        print("RESULT spoken label per row: formatter \(String(format: "%.2f", perRow(before))) µs (the time alone), now \(String(format: "%.2f", perRow(after))) µs (the whole label); sink \(sink)")
        #expect(after < before / 4, "formatter \(before), now \(after)")
    }
}
