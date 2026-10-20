import Foundation
import Testing
@testable import VibeSwitcher

/// app.log says why each session's terminal changed size (`host: resize 1A2B3C4D to 110×40 (window resize)`), with
/// the same id as host.log's line for the PTY; one line a second at most per session, the newest of a burst a second
/// after the line before. No host: the lines are the client's own. On a clock the test moves: no real time passes.
@MainActor
struct ResizeLogTests {
    let temp = Scratch()

    /// A clock that moves only when told, and what was asked to run at a later time on it.
    final class ManualClock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        private var later: [(at: Date, run: () -> Void)] = []

        func schedule(_ wait: TimeInterval, _ run: @escaping () -> Void) { later.append((now + wait, run)) }

        /// Moves on by `seconds`, running what came due, in order.
        func advance(_ seconds: TimeInterval) {
            now += seconds
            let due = later.filter { $0.at <= now }.sorted { $0.at < $1.at }
            later.removeAll { $0.at <= now }
            due.forEach { $0.run() }
        }
    }

    @Test func eachSizeChangeIsLoggedWithItsReasonAtMostOnceASecond() {
        var notes: [String] = []
        let clock = ManualClock()
        let host = HostClient(socketPath: temp.url("no-host.sock").path, note: { notes.append($0) })
        host.resizeClock = { clock.now }
        host.resizeLater = clock.schedule
        let id = UUID(), other = UUID()
        let short = id.uuidString.prefix(8)
        func resizes(_ id: UUID) -> [String] { notes.filter { $0.contains("resize \(id.uuidString.prefix(8)) ") } }
        host.attach(id, cols: 100, rows: 40, sink: .init(output: { _ in }, attached: {}, resync: {}))
        host.attach(other, cols: 100, rows: 40, sink: .init(output: { _ in }, attached: {}, resync: {}))
        #expect(resizes(id) == ["host: resize \(short) to 100×40 (initial)"])
        // A window drag, then the size it already has: no line for that one. (Steps in eighths: exact sums.)
        for cols in 101...104 {
            clock.advance(0.125)
            host.resize(id, cols: cols, rows: 40, reason: .windowResize)
        }
        host.resize(id, cols: 104, rows: 40, reason: .shown)
        // Another session has its own second.
        host.resize(other, cols: 90, rows: 40, reason: .focusMode)
        #expect(resizes(id).count == 1 && resizes(other).count == 1)
        // Held until a second after the attach's line (0.5 s gone): not at 0.875 s, at 1 s.
        clock.advance(0.375)
        #expect(resizes(id).count == 1 && resizes(other).count == 1)
        clock.advance(0.125)
        #expect(resizes(id).last == "host: resize \(short) to 104×40 (window resize), the last of 4 within a second")
        #expect(resizes(other).last == "host: resize \(other.uuidString.prefix(8)) to 90×40 (focus mode)")
        // Within a second of that line: held again; a second after it: at once.
        clock.advance(0.5)
        host.resize(id, cols: 104, rows: 30, reason: .paneSplit)
        #expect(resizes(id).count == 2)
        clock.advance(0.5)
        #expect(resizes(id).last == "host: resize \(short) to 104×30 (pane split)")
        clock.advance(1)
        host.resize(id, cols: 120, rows: 30, reason: .fontSize)
        #expect(resizes(id).last == "host: resize \(short) to 120×30 (font size)")
        #expect(resizes(id).count == 4)
        host.detach(id)
        host.detach(other)
    }

    /// The reasons as written: what a grep of app.log looks for.
    @Test func reasonsReadAsWords() {
        #expect([HostClient.ResizeReason.initial, .shown, .windowResize, .paneSplit, .focusMode, .fontSize].map(\.rawValue)
            == ["initial", "shown", "window resize", "pane split", "focus mode", "font size"])
    }
}
