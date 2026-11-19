import AppKit
import Darwin
import Foundation
import VibeCore

/// Gives malloc's free pages back to the system once the app's footprint has grown by `slack` over what it was after
/// the last time (10-26). Malloc keeps the pages it freed dirty, counted in the footprint, until the system runs short
/// of memory: each peak (a long transcript read, the boards decoded) left the footprint at its high-water mark, and the
/// peaks grow with the day's transcripts and boards. In the soak bench the footprint rose ~30 MB an hour with what's
/// live flat, and came back down to its first minute's when the pages were given back (`scripts/soak-bench.sh
/// --soak-relief`). It looks once a minute; the reading and the relief run on its own queue, off the main thread. A
/// relief holds malloc's locks (0.2-0.6 s seen on a loaded Mac), and every allocation on the main thread waits for it:
/// it runs only while the app isn't frontmost, never while you're using it.
final class FootprintRelief {
    /// Growth over the last relief's footprint (MB) that's given back. 8 MB was tried: it read no flatter over the
    /// soak's last 40 minutes (33 MB an hour against 20) and ran 27 reliefs in 65 minutes, the longest 0.2-0.6 s
    /// holding malloc's locks. A terminal's GPU memory for a moment is more, but a relief then finds nothing and the
    /// next look starts from there.
    static let slack = 24.0

    private let footprint: () -> Double?
    private let relieve: () -> Void
    /// What the footprint is made of (`split()`), read on the relief's queue just before each relief, never on main.
    private let split: () -> AppHealth.Memory.Split?
    /// Whether you're using the app now (it's frontmost), read on the main thread at each look: then no relief.
    private let inUse: () -> Bool
    private let queue = DispatchQueue(label: "vibeswitcher.footprint-relief", qos: .utility)
    /// The footprint after the last relief, or the least since (it follows the footprint down); nil before the first look.
    private var floor: Double?
    private var timer: Heartbeat.Subscription?
    private var reliefs = 0
    private var longest = 0.0
    private var lastRelief: AppHealth.Memory.Relief?

    /// The reliefs so far and the longest, in ms (the soak bench's).
    var made: (reliefs: Int, longest: Double) { queue.sync { (reliefs, longest) } }

    /// The last relief's footprint before and after it (the health digest's); nil before the first.
    var last: AppHealth.Memory.Relief? { queue.sync { lastRelief } }

    init(footprint: @escaping () -> Double? = { AppHealthWatcher.ownFootprint()?.now },
         relieve: @escaping () -> Void = { malloc_zone_pressure_relief(nil, 0) },
         inUse: @escaping () -> Bool = { (NSApp as NSApplication?)?.isActive ?? false },
         split: @escaping () -> AppHealth.Memory.Split? = { FootprintRelief.split() }) {
        self.footprint = footprint
        self.relieve = relieve
        self.split = split
        self.inUse = inUse
    }

    func start() {
        timer = Heartbeat.shared.every(60) { [weak self] in self?.look() }
    }

    /// Reads the footprint and gives the free pages back when it's `slack` over the floor and the app isn't in use
    /// (then the next look tries again); `done` (tests) after. Called on the main thread (`inUse` is read here).
    func look(done: (() -> Void)? = nil) {
        let busy = inUse()
        queue.async { [self] in
            defer { done?() }
            guard let now = footprint() else { return }
            guard let floor, now >= floor + Self.slack else {
                floor = min(floor ?? now, now)
                return
            }
            guard !busy else { return }
            // What the footprint is made of, as it stands before the relief (2026-11-18: 262 → 713 MB overnight, and
            // the footprint alone named nothing). How long the reading takes goes in the line too.
            let reading = DispatchTime.now()
            let parts = split()
            let readIn = Double(DispatchTime.now().uptimeNanoseconds - reading.uptimeNanoseconds) / 1e6
            // It holds malloc's locks while it runs: how long, in the log, to see what it costs a big heap.
            let started = DispatchTime.now()
            relieve()
            let took = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let after = footprint() ?? now
            // On macOS 27.2 it gives back nothing (see `AppHealth.keptForReuse`): the line says so.
            Breadcrumbs.shared.note(AppHealth.reliefLine(before: now, after: after, took: took, split: parts, readIn: parts == nil ? nil : readIn))
            lastRelief = AppHealth.Memory.Relief(before: now, after: after, split: parts)
            reliefs += 1
            longest = max(longest, took)
            self.floor = after
        }
    }
}

extension FootprintRelief {
    /// The app's own footprint split (`AppHealth.Memory.Split`): malloc's zones in use and allocated, the graphics and
    /// compressed ledgers (`UIBench.memoryKinds`, this process's task_info), and its largest VM tags (`SoakMemory.byTag`,
    /// a walk of its own regions). Names and numbers only; nil when task_info can't be read. Off the main thread: the
    /// walk takes a few ms on a big heap.
    static func split() -> AppHealth.Memory.Split? {
        let kinds = UIBench.memoryKinds()
        guard kinds["footprint"] != nil else { return nil }
        let mb = { (bytes: Double) in bytes / 1_048_576 }
        let total = { (suffix: String) in mb(kinds.filter { $0.key.hasPrefix("malloc ") && $0.key.hasSuffix(suffix) }.values.reduce(0, +)) }
        let tags = SoakMemory.byTag().prefix(AppHealth.Memory.Split.shownTags).map { AppHealth.Memory.Split.Tag(name: SoakMemory.name($0.tag), mb: $0.mb) }
        return AppHealth.Memory.Split(mallocInUse: total(" in use"), mallocAllocated: total(" allocated"), graphics: mb(kinds["graphics"] ?? 0),
                                      compressed: mb(kinds["compressed"] ?? 0), tags: Array(tags))
    }
}
