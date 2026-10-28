import Foundation
import IOKit.pwr_mgt
import VibeCore

/// Settings' "Keep the Mac awake while the team works". On power only by default: a laptop on battery left to sleep
/// keeps its charge.
enum KeepAwakeMode: String, CaseIterable {
    case always
    case onPower
    case never

    var label: String {
        switch self {
        case .always: return "Always"
        case .onPower: return "On power only"
        case .never: return "Never"
        }
    }
}

/// What keeping the Mac awake asks of the system: power assertions, and whether it runs on AC power. Faked in tests.
protocol PowerRuntime: AnyObject {
    /// Holds an assertion that keeps the Mac from idle sleep (not the display): its id, or nil when refused.
    func hold(_ name: String) -> UInt32?
    func release(_ id: UInt32)
    var onACPower: Bool { get }
}

/// The real one: `pmset -g assertions` lists what it holds. The power source is the one `source` last read off the
/// main thread (see `PowerSourceCache`): asking IOKit here froze the window for 6.4 s. The app's cache unless one is
/// given, taken at the first look that asks (benches and tests that hold nothing read nothing).
final class SystemPower: PowerRuntime {
    private let given: PowerSourceCache?
    private lazy var source = given ?? .shared

    init(source: PowerSourceCache? = nil) {
        given = source
    }

    func hold(_ name: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }

    var onACPower: Bool { source.onACPower }
}

/// Keeps the Mac awake while a lead's team works (2026-10-19 01:38, the Mac went to sleep under a merge's tests, a
/// verifier's turn and a worker's build: the merge's tests died, the audit ended mid-response). One assertion per
/// project, "VibeSwitcher: team working on <project>", held while its team works (`working`) and released at the
/// first look that finds it idle (the lead controller looks every 3 s). On battery nothing is held unless the
/// setting says always; the power source is asked only while there's work.
final class KeepAwake: ObservableObject {
    /// The roots whose team the Mac is kept awake for right now (as the assertions' queue last left them): the Team
    /// view says so.
    @Published private(set) var held: Set<String> = []
    /// The setting, as it is at each look. Never until the app gives it the setting: benches and tests hold nothing.
    var mode: () -> KeepAwakeMode = { .never }
    private let power: PowerRuntime
    let assertions: Assertions
    /// The roots last asked of `assertions`.
    private var asked: Set<String> = []

    init(power: PowerRuntime = SystemPower()) {
        self.power = power
        assertions = Assertions(power: power)
        assertions.changed = { [weak self] in DispatchQueue.main.async { self?.publish() } }
    }

    deinit {
        assertions.want([])
    }

    static func name(root: String) -> String {
        "VibeSwitcher: team working on \((root as NSString).lastPathComponent)"
    }

    /// What a lead's `merge` and `revert` tool calls show as its session's activity while they run (see `ToolActivity`).
    static let mergeActivity = ToolActivity.describe(toolName: "mcp__vibeswitcher__merge", input: [:])
    static let revertActivity = ToolActivity.describe(toolName: "mcp__vibeswitcher__revert", input: [:])
    /// Whether a lead's team works: a worker or verifier of its board runs a turn (or shells after one, its tests in
    /// the background), or the lead merges or reverts (its `merge` or `revert` tool call runs the tests: its session
    /// reads working, on that tool, until the call ends). One waiting on you, or done, isn't working. `hosted` and
    /// `sessions` by host session id.
    static func working(board: LeadBoard, hosted: [String: HostSession], sessions: [String: Session]) -> Bool {
        func live(_ id: String) -> Session? { hosted[id]?.isLive == true ? sessions[id] : nil }
        let members = board.tasks.flatMap { [$0.worker, $0.verifier] }.compactMap { $0 }
        if members.contains(where: { live($0).map { [.working, .background].contains($0.status) } == true }) { return true }
        guard let lead = board.leadSession.flatMap(live) else { return false }
        return lead.status == .working && [mergeActivity, revertActivity].contains(lead.activity)
    }

    /// The projects whose team works, of the boards a refresh read (by root) and the sessions as it read them.
    static func working(_ boards: [String: LeadBoard], teams: [String: TeamReading]) -> Set<String> {
        Set(boards.compactMap { root, board in
            teams[root].map { working(board: board, hosted: $0.hosted, sessions: $0.sessions) } == true ? root : nil
        })
    }

    /// Holds an assertion for each of `roots` (the projects whose team works), as the setting and the power source
    /// allow, and releases the rest. Only decides: `assertions` holds and releases on its own queue. Asked again while
    /// what's held isn't what's wanted, so a refused assertion is asked for again at the next look.
    func update(working roots: Set<String>) {
        let wanted: Set<String>
        switch mode() {
        case .never: wanted = []
        case .always: wanted = roots
        case .onPower: wanted = roots.isEmpty || !power.onACPower ? [] : roots
        }
        publish()
        guard wanted != asked || wanted != held else { return }
        asked = wanted
        assertions.want(wanted)
    }

    private func publish() {
        let now = assertions.holding
        if now != held { held = now }
    }

    /// Runs `then` on the main thread once every hold and release asked for so far has ended and `held` says so (for
    /// tests).
    func settled(then: @escaping () -> Void) {
        assertions.settled { DispatchQueue.main.async { self.publish(); then() } }
    }

    /// The assertions, held and released on a serial queue of their own: like the power source's read (see
    /// `PowerSourceCache`), `IOPMAssertionCreateWithName` and `IOPMAssertionRelease` ask powerd, which can keep them
    /// waiting around sleep and charging changes. One project's hold and release reach the system in the order asked,
    /// never twice held; asked again while the queue is stuck, only the last ask waits, not a pile.
    final class Assertions: @unchecked Sendable {
        /// Called on the queue after it held or released what it was asked.
        var changed: () -> Void = {}
        private let power: PowerRuntime
        private let queue = DispatchQueue(label: "VibeSwitcher.keep-awake", qos: .utility)
        private let lock = NSLock()
        /// Under `lock`: the roots last asked for that the queue hasn't taken yet, whether the queue drains them, and
        /// the roots held.
        private var pending: Set<String>?
        private var draining = false
        private var held: Set<String> = []
        /// On the queue only: each held root's assertion.
        private var ids: [String: UInt32] = [:]

        init(power: PowerRuntime) {
            self.power = power
        }

        /// The roots held now.
        var holding: Set<String> { lock.withLock { held } }

        /// Holds an assertion for each of `roots` and releases the rest, on the queue.
        func want(_ roots: Set<String>) {
            let start = lock.withLock {
                pending = roots
                defer { draining = true }
                return !draining
            }
            if start { queue.async(execute: drain) }
        }

        private func drain() {
            while let roots = lock.withLock({ () -> Set<String>? in
                defer { pending = nil }
                if pending == nil { draining = false }
                return pending
            }) {
                apply(roots)
            }
            changed()
        }

        private func apply(_ roots: Set<String>) {
            for (root, id) in ids where !roots.contains(root) {
                power.release(id)
                ids[root] = nil
                lock.withLock { _ = held.remove(root) }
                Breadcrumbs.shared.note("keep awake: released for \((root as NSString).lastPathComponent)")
            }
            for root in roots where ids[root] == nil {
                guard let id = power.hold(KeepAwake.name(root: root)) else { continue }
                ids[root] = id
                lock.withLock { _ = held.insert(root) }
                Breadcrumbs.shared.note("keep awake: holding for \((root as NSString).lastPathComponent)")
            }
        }

        /// Runs `then` on the queue once every hold and release asked for so far has ended (for tests).
        func settled(then: @escaping () -> Void) {
            queue.async(execute: then)
        }
    }
}
