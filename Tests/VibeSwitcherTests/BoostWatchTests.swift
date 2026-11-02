import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Boost mode as the app decides it (`BoostWatch`): the power source, the user's presence and the usage watch are
/// injected, and each `look` is one heartbeat. What it decides is what every lead reads (boost.json).
@MainActor
struct BoostWatchTests {
    let temp = Scratch()

    final class Signals {
        var onAC: Bool? = true
        var percent: Int? = 86
        var away = true
        var usage = AccountUsage()
        var now = Date(timeIntervalSince1970: 1_793_000_000)
        var folder: String?
    }

    func watch(_ mode: BoostMode, _ signals: Signals, defaults: UserDefaults? = nil) -> (BoostWatch, Preferences, URL) {
        let folder = temp.url("boost")
        let preferences = Preferences(defaults: defaults ?? temp.defaults("boost-defaults"), presetsFile: folder.appendingPathComponent("presets.json"))
        preferences.boostMode = mode
        let file = folder.appendingPathComponent("boost.json")
        let watch = BoostWatch(preferences: preferences, file: file)
        watch.onAC = { signals.onAC }
        watch.percent = { signals.percent }
        watch.away = { signals.away }
        watch.usage = { signals.usage }
        watch.clock = { signals.now }
        watch.currentFolder = { signals.folder }
        // A disk with one repository, /Users/x/dev/alpha.
        watch.projectRoot = { Boost.projectRoot(of: $0, exists: { $0 == "/Users/x/dev/alpha/.git" }) }
        return (watch, preferences, file)
    }

    /// One heartbeat's look, to its end (decided on the watch's queue, published on the main thread).
    func look(_ watch: BoostWatch) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in watch.look { done.resume() } }
    }

    /// Automatic: away on AC is boost; on battery, or the user back, is the normal limits at the next heartbeat, and
    /// the leads read the same from the file at once.
    @Test func automaticFollowsPowerAndPresenceWithinOneHeartbeat() async {
        let signals = Signals()
        let (watch, _, file) = watch(.automatic, signals)
        var turned: [Bool] = []
        watch.changed = { turned.append($0.on) }
        await look(watch)
        #expect(watch.state?.text == "boost: on (automatic: away, on AC)")
        #expect(watch.menuText == "Boost on (automatic: away, on AC)")
        #expect(MacLimits.current(file: file.deletingLastPathComponent().appendingPathComponent("mac-limits.json"), boostFile: file, now: signals.now).maxSessions == 18)
        // Unplugged: off at the next look.
        signals.onAC = false
        signals.now += TimeInterval(BoostWatch.every)
        await look(watch)
        #expect(watch.state?.text == "boost: off (automatic: on battery)")
        #expect(BoostState.active(from: file, now: signals.now) == nil)
        #expect(watch.menuText == nil)
        // Plugged in again, then the user comes back: off at once.
        signals.onAC = true
        signals.now += TimeInterval(BoostWatch.every)
        await look(watch)
        #expect(BoostState.active(from: file, now: signals.now) != nil)
        signals.away = false
        signals.now += TimeInterval(BoostWatch.every)
        await look(watch)
        #expect(watch.state?.text == "boost: off (automatic: you're at the Mac)")
        #expect(MacLimits.current(file: file.deletingLastPathComponent().appendingPathComponent("mac-limits.json"), boostFile: file, now: signals.now) == MacLimits())
        #expect(turned == [true, false, true, false])
        // The power source not read yet: off.
        signals.away = true
        signals.onAC = nil
        await look(watch)
        #expect(watch.state?.on == false)
    }

    @Test func onNeverBoostsOnBatteryAndOffNeverBoosts() async {
        let signals = Signals()
        signals.away = false
        let (watch, preferences, file) = watch(.on, signals)
        await look(watch)
        #expect(watch.state?.text == "boost: on (on in Settings, on AC)")
        signals.onAC = false
        await look(watch)
        #expect(watch.state?.on == false && BoostState.active(from: file, now: signals.now) == nil)
        signals.onAC = true
        preferences.boostMode = .off
        signals.away = true
        await look(watch)
        #expect(watch.state?.text == "boost: off (off in Settings)")
    }

    /// "Also on battery": the watch passes the charge, so boost stops at the first look below `Boost.batteryFloor` %
    /// and comes back above it; turning the option off or on re-decides at once.
    @Test func alsoOnBatteryFollowsTheChargeAndTheOption() async {
        let signals = Signals()
        signals.onAC = false
        signals.percent = 31
        let defaults = temp.defaults("boost-defaults")
        let (watch, preferences, file) = watch(.automatic, signals, defaults: defaults)
        #expect(preferences.boostOnBattery == false)
        preferences.boostOnBattery = true
        #expect(Preferences(defaults: defaults, presetsFile: file.deletingLastPathComponent().appendingPathComponent("presets.json")).boostOnBattery)
        var turned: [Bool] = []
        watch.changed = { turned.append($0.on) }
        await look(watch)
        #expect(watch.state?.text == "boost: on (automatic: away, on battery (allowed, 31%))")
        #expect(BoostState.active(from: file, now: signals.now) != nil)
        // The charge drops below 30%: off at the next look.
        signals.percent = 29
        signals.now += TimeInterval(BoostWatch.every)
        await look(watch)
        #expect(watch.state?.text == "boost: off (automatic: on battery at 29%: boost on battery stops below 30%)")
        #expect(BoostState.active(from: file, now: signals.now) == nil)
        // Charged back to 30%: on again.
        signals.percent = 30
        signals.now += TimeInterval(BoostWatch.every)
        await look(watch)
        #expect(watch.state?.on == true)
        // The charge unknown: off.
        signals.percent = nil
        await look(watch)
        #expect(watch.state?.text == "boost: off (automatic: on battery, charge not known: boost on battery stops below 30%)")
        signals.percent = 86
        await look(watch)
        #expect(turned == [true, false, true, false, true])
        // Settings turns the option off: the started watch re-decides at once, without a heartbeat.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var resumed = false
            watch.changed = { state in
                guard !state.on, !resumed else { return }
                resumed = true
                done.resume()
            }
            watch.start()
            preferences.boostOnBattery = false
        }
        #expect(watch.state?.text == "boost: off (automatic: on battery)")
    }

    /// The usage watch's veto: near an every-model limit boost stays off, and the menu bar, Settings and the leads say why.
    @Test func aUsageVetoKeepsBoostOff() async {
        let signals = Signals()
        signals.usage = AccountUsage(limits: [AccountUsage.Limit(name: "five_hour", usedPercent: 82, resetsAt: signals.now.timeIntervalSince1970 + 3600,
                                                                 at: signals.now.timeIntervalSince1970)])
        let (watch, _, file) = watch(.automatic, signals)
        await look(watch)
        #expect(watch.state?.on == false)
        #expect(BoostState.load(from: file, now: signals.now)?.text.hasPrefix("boost: off (held off by the usage watch: the 5-hour limit") == true)
        signals.usage = AccountUsage()
        await look(watch)
        #expect(watch.state?.on == true)
    }

    /// The boost values are saved through Preferences (kept as their nearest valid), and each look writes them for
    /// the leads, with the project the user last worked in; the file is rewritten while unchanged so it never goes
    /// stale under a running app.
    @Test func theValuesAreSavedAndTheFileKeptFresh() async throws {
        let signals = Signals()
        let defaults = temp.defaults("boost-defaults")
        let (watch, preferences, file) = watch(.automatic, signals, defaults: defaults)
        preferences.boostLimits = BoostLimits(loadThreshold: 40, maxSessions: 20, maxWorkers: 6, heavySlots: 4)
        preferences.boostLimits.maxWorkers = 0
        #expect(preferences.boostLimits.maxWorkers == 1)
        let again = Preferences(defaults: defaults, presetsFile: file.deletingLastPathComponent().appendingPathComponent("presets.json"))
        #expect(again.boostMode == .automatic)
        #expect(again.boostLimits == BoostLimits(loadThreshold: 40, maxSessions: 20, maxWorkers: 1, heavySlots: 4))
        signals.folder = "/Users/x/dev/alpha/.vibeswitcher/worktrees/one"
        await look(watch)
        let written = try #require(BoostState.load(from: file, now: signals.now))
        #expect(written.limits == again.boostLimits && written.favored == "/Users/x/dev/alpha")
        // A session in a subfolder of it (F5): the same project.
        signals.folder = "/Users/x/dev/alpha/Sources/VibeCore"
        await look(watch)
        #expect(watch.state?.favored == "/Users/x/dev/alpha")
        // No current session: the last project is kept.
        signals.folder = nil
        signals.now += BoostState.refresh
        await look(watch)
        let refreshed = try #require(BoostState.load(from: file, now: signals.now + BoostState.staleAfter - 1))
        #expect(refreshed.at == signals.now.timeIntervalSince1970 && refreshed.favored == "/Users/x/dev/alpha")
    }

    /// F2: a power source the system doesn't say (IOKit's read failed) is battery for boost, though the cache's
    /// `onACPower` (keep-awake's, the witness's) still takes it as AC power.
    @Test func anUnreadablePowerSourceNeverBoosts() async {
        let unknown = PowerSourceCache(read: { PowerSourceCache.Reading(onACPower: true, state: nil, knownAC: nil) })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in unknown.settled { done.resume() } }
        #expect(unknown.onACPower)
        let folder = temp.url("boost")
        let preferences = Preferences(defaults: temp.defaults("boost-defaults"), presetsFile: folder.appendingPathComponent("presets.json"))
        preferences.boostMode = .on
        let watch = BoostWatch(preferences: preferences, file: folder.appendingPathComponent("boost.json"), power: unknown)
        watch.away = { true }
        watch.usage = { AccountUsage() }
        await look(watch)
        #expect(watch.state?.text == "boost: off (on in Settings, but power source not known yet: boost never runs on battery)")
        // Read as AC: boost.
        let ac = PowerSourceCache(read: { PowerSourceCache.Reading(onACPower: true, state: nil, knownAC: true) })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in ac.settled { done.resume() } }
        let onAC = BoostWatch(preferences: preferences, file: folder.appendingPathComponent("boost.json"), power: ac)
        onAC.away = { true }
        onAC.usage = { AccountUsage() }
        await look(onAC)
        #expect(onAC.state?.on == true)
    }

    /// F4: a look reads the usage file, your presence and the project's folder, and writes boost.json, on the watch's
    /// queue: the main thread's part returns while they're held up.
    @Test func aLookDoesItsFileWorkOffTheMainThread() async throws {
        let signals = Signals()
        let (watch, _, file) = watch(.automatic, signals)
        let gate = DispatchSemaphore(value: 0)
        let onMain = BoostLocked<[String]>([])
        watch.usage = {
            if Thread.isMainThread { onMain.change { $0.append("usage") } }
            gate.wait()
            return AccountUsage()
        }
        watch.away = {
            if Thread.isMainThread { onMain.change { $0.append("away") } }
            return true
        }
        watch.projectRoot = { folder in
            if Thread.isMainThread { onMain.change { $0.append("projectRoot") } }
            return folder
        }
        signals.folder = "/Users/x/dev/alpha"
        let done = BoostLocked(false)
        let finished = DispatchSemaphore(value: 0)
        watch.look { done.set(true); finished.signal() }
        // Back on the main thread while the queue waits on the usage read: nothing decided or written yet.
        #expect(!done.get() && watch.state == nil && !FileManager.default.fileExists(atPath: file.path))
        gate.signal()
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { finished.wait(); resume.resume() }
        }
        #expect(onMain.get().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(watch.state?.on == true)
    }
}

/// F5: a session's folder maps to its project, so a session in a subfolder (or a task's worktree) favours the project
/// whose leads' room waits name its root.
struct BoostProjectRootTests {
    @Test func aSubfolderOrAWorktreeMapsToItsProjectsRoot() {
        let repos: Set<String> = ["/Users/x/dev/alpha/.git", "/Users/x/dev/beta/.git"]
        let exists = { (path: String) in repos.contains(path) }
        #expect(Boost.projectRoot(of: "/Users/x/dev/alpha", exists: exists) == "/Users/x/dev/alpha")
        #expect(Boost.projectRoot(of: "/Users/x/dev/alpha/Sources/VibeCore/", exists: exists) == "/Users/x/dev/alpha")
        #expect(Boost.projectRoot(of: "/Users/x/dev/beta/.vibeswitcher/worktrees/one/Sources", exists: exists) == "/Users/x/dev/beta")
        // Not in a repository: the folder itself.
        #expect(Boost.projectRoot(of: "/Users/x/notes/", exists: exists) == "/Users/x/notes")
        // And the leads' room waits match it: the favored root, not the subfolder.
        let limits = MacLimits(maxSessions: 6).boosted(by: BoostState(on: true, why: "w", favored: Boost.projectRoot(of: "/Users/x/dev/alpha/Sources", exists: exists)))
        #expect(limits.boost?.favored == "/Users/x/dev/alpha")
    }
}

/// A value shared with the watch's queue.
final class BoostLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: Value) { change { $0 = new } }

    func change<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
