import Combine
import Foundation
import VibeCore

/// Decides Boost mode for every project's leads (see `Boost`, `BoostState`): every `every` seconds of the app's
/// heartbeat, and at once when Settings changes the mode or the limits, it reads the power source, whether you're at
/// the Mac (the presence the notifications go by, `UserPresence`) and the usage watch's readings, and keeps the
/// decision in `~/.vibeswitcher/boost.json`, which the leads' tool servers read at each call. Automatic boosts only on
/// AC power while you're away and drops back at the first look after either changes: new starts then stop above the
/// normal limits, and running work finishes. With Settings' "Also on battery" the battery counts as AC while its charge
/// is at `Boost.batteryFloor` % or more: each look reads the charge, so boost stops at the first look below it.
///
/// The main thread only reads what it holds (Settings, the session you're on, the power source as last read); the
/// rest (your presence, the usage file, the project's folder on disk, boost.json's write) runs on a queue of the
/// watch's own, one look at a time: the app froze for seconds on main-thread reads under load (2026-10-28, 11-01).
final class BoostWatch: ObservableObject {
    /// What was decided last (nil before the first look).
    @Published private(set) var state: BoostState?
    /// Why the decision couldn't be kept for the leads, for Settings; nil when it was.
    @Published private(set) var problem: String?

    private let preferences: Preferences
    private let file: URL
    /// The power source: AC (true), battery (false), not read yet or unreadable (nil: boost stays off). Read on the
    /// main thread: it's the cache's last reading, never the power daemon.
    var onAC: () -> Bool?
    /// The battery's charge (`PowerState.percent`); nil without a battery reading. Read on the main thread, as `onAC`.
    var percent: () -> Int?
    /// You're away from the Mac: screen locked, or no input for 5 minutes. On the watch's queue.
    var away: () -> Bool = { !UserPresence.isPresent() }
    /// The account's usage as the usage watch keeps it. On the watch's queue.
    var usage: () -> AccountUsage = { AccountUsageStore().load() }
    /// Settings' "Ignore usage limits" (`MacLimits.ignoreUsageLimits`): the usage watch holds nothing off. On the watch's queue.
    var ignoringUsage: () -> Bool = { MacLimits.load().ignoreUsageLimits }
    /// The project a session's folder is in (`Boost.projectRoot`). On the watch's queue.
    var projectRoot: (String) -> String = { Boost.projectRoot(of: $0) }
    /// The folder of the session you're on (its project gets first claim on freed room while boosted); nil: none.
    /// Read on the main thread.
    var currentFolder: () -> String? = { nil }
    var clock: () -> Date = { Date() }
    /// Run on the main thread after a look that turned boost on or off (the app looks at the leads' room waits at once).
    var changed: (BoostState) -> Void = { _ in }

    private let queue = DispatchQueue(label: "VibeSwitcher.boost", qos: .utility)
    /// The queue's: the project you last worked in (kept while no session is current), and what was last written.
    private var favored: String?
    private var written: (state: BoostState, at: Date)?
    private var timer: Heartbeat.Subscription?
    private var settings: AnyCancellable?

    /// The heartbeat's period: how long Automatic takes, at most, to follow the power or you.
    static let every = 10

    init(preferences: Preferences, file: URL = BoostState.file, power: PowerSourceCache = .shared) {
        self.preferences = preferences
        self.file = file
        onAC = { power.current()?.knownAC }
        percent = { power.current()?.state?.percent }
    }

    /// Looks now, then every `every` seconds and whenever Settings changes the mode, the limits or "Also on battery".
    func start() {
        look()
        timer = Heartbeat.shared.every(Self.every) { [weak self] in self?.look() }
        settings = preferences.$boostMode.combineLatest(preferences.$boostLimits, preferences.$boostOnBattery).dropFirst()
            .receiveLatest(on: RunLoop.main)
            .sink { [weak self] _ in self?.look() }
    }

    /// Decides (on the watch's queue) and writes the file when the decision changed, or it was written over
    /// `BoostState.refresh` ago; then publishes on the main thread and runs `then` there. Main thread.
    func look(then: (() -> Void)? = nil) {
        let now = clock()
        let mode = preferences.boostMode
        let limits = preferences.boostLimits
        let folder = currentFolder()
        let ac = onAC()
        let onBattery = preferences.boostOnBattery
        let charge = percent()
        queue.async { [self] in
            if let folder { favored = projectRoot(folder) }
            // Presence and the usage file only matter when boost could be on.
            let away = mode == .off ? false : self.away()
            let veto = mode == .off ? nil : Boost.veto(usage(), now: now, ignoring: ignoringUsage())
            let decided = Boost.decide(mode: mode, onAC: ac, away: away, veto: veto, onBattery: onBattery, percent: charge, now: now)
            let next = BoostState(on: decided.on, why: decided.why, limits: limits, favored: favored, at: now.timeIntervalSince1970)
            var problem: String?? = .none
            if !next.sameAs(written?.state) || written.map({ now.timeIntervalSince($0.at) >= BoostState.refresh }) ?? true {
                do {
                    try next.save(to: file)
                    written = (next, now)
                    problem = .some(nil)
                } catch {
                    // The leads keep reading the last decision until it's stale (then: the normal limits).
                    problem = .some("Couldn't save \(file.path): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [self] in
                let turned = state?.on != next.on
                if !next.sameAs(state) { state = next }
                if case .some(let text) = problem, text != self.problem { self.problem = text }
                if turned { changed(next) }
                then?()
            }
        }
    }

    /// The menu bar's word on it: "Boost on (automatic: away, on AC)"; nil while off.
    var menuText: String? {
        guard let state, state.on else { return nil }
        return "Boost on (\(state.why))"
    }
}
