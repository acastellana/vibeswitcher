import Darwin
import Foundation
import VibeCore

/// Gives malloc's free pages back to the system once the app's footprint has grown by `slack` over what it was after
/// the last time (10-26). Malloc keeps the pages it freed dirty, counted in the footprint, until the system runs short
/// of memory: each peak (a long transcript read, the boards decoded) left the footprint at its high-water mark, and the
/// peaks grow with the day's transcripts and boards. In the soak bench the footprint rose ~30 MB an hour with what's
/// live flat, and came back down to its first minute's when the pages were given back (`scripts/soak-bench.sh
/// --soak-relief`). It looks once a minute; the reading and the relief run on its own queue, off the main thread.
final class FootprintRelief {
    /// Growth over the last relief's footprint (MB) that's given back: a terminal's GPU memory for a moment is more,
    /// but a relief then finds nothing and the next look starts from there.
    static let slack = 24.0

    private let footprint: () -> Double?
    private let relieve: () -> Void
    private let queue = DispatchQueue(label: "vibeswitcher.footprint-relief", qos: .utility)
    /// The footprint after the last relief, or the least since (it follows the footprint down); nil before the first look.
    private var floor: Double?
    private var timer: Heartbeat.Subscription?

    init(footprint: @escaping () -> Double? = { AppHealthWatcher.ownFootprint()?.now },
         relieve: @escaping () -> Void = { malloc_zone_pressure_relief(nil, 0) }) {
        self.footprint = footprint
        self.relieve = relieve
    }

    func start() {
        timer = Heartbeat.shared.every(60) { [weak self] in self?.look() }
    }

    /// Reads the footprint and gives the free pages back when it's `slack` over the floor; `done` (tests) after.
    func look(done: (() -> Void)? = nil) {
        queue.async { [self] in
            defer { done?() }
            guard let now = footprint() else { return }
            guard let floor, now >= floor + Self.slack else {
                floor = min(floor ?? now, now)
                return
            }
            // It holds malloc's locks while it runs: how long, in the log, to see what it costs a big heap.
            let started = DispatchTime.now()
            relieve()
            let after = footprint() ?? now
            Breadcrumbs.shared.note(String(format: "footprint relief: %.0f → %.0f MB in %.0f ms", now, after,
                                           Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6))
            self.floor = after
        }
    }
}
