import Foundation
import IOKit.ps
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

/// The real one: `pmset -g assertions` lists what it holds.
final class SystemPower: PowerRuntime {
    func hold(_ name: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }

    var onACPower: Bool {
        // No power source information: taken as power (a desktop Mac says AC anyway).
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) != kIOPMBatteryPowerKey && (type as String) != kIOPMUPSPowerKey
    }
}

/// Keeps the Mac awake while a lead's team works (2026-10-19 01:38, the Mac went to sleep under a merge's tests, a
/// verifier's turn and a worker's build: the merge's tests died, the audit ended mid-response). One assertion per
/// project, "VibeSwitcher: team working on <project>", held while its team works (`working`) and released at the
/// first look that finds it idle (the lead controller looks every 3 s). On battery nothing is held unless the
/// setting says always; the power source is asked only while there's work.
final class KeepAwake: ObservableObject {
    /// The roots whose team the Mac is kept awake for right now: the Team view says so.
    @Published private(set) var held: Set<String> = []
    /// The setting, as it is at each look. Never until the app gives it the setting: benches and tests hold nothing.
    var mode: () -> KeepAwakeMode = { .never }
    private let power: PowerRuntime
    private var assertions: [String: UInt32] = [:]

    init(power: PowerRuntime = SystemPower()) {
        self.power = power
    }

    deinit {
        assertions.values.forEach(power.release)
    }

    static func name(root: String) -> String {
        "VibeSwitcher: team working on \((root as NSString).lastPathComponent)"
    }

    /// What a lead's `merge` tool call shows as its session's activity while it runs (see `ToolActivity`).
    static let mergeActivity = ToolActivity.describe(toolName: "mcp__vibeswitcher__merge", input: [:])

    /// Whether a lead's team works: a worker or verifier of its board runs a turn (or shells after one, its tests in
    /// the background), or the lead merges (its `merge` tool call rebases and runs the tests: its session reads
    /// working, on that tool, until the merge ends). One waiting on you, or done, isn't working. `hosted` and
    /// `sessions` by host session id.
    static func working(board: LeadBoard, hosted: [String: HostSession], sessions: [String: Session]) -> Bool {
        func live(_ id: String) -> Session? { hosted[id]?.isLive == true ? sessions[id] : nil }
        let members = board.tasks.flatMap { [$0.worker, $0.verifier] }.compactMap { $0 }
        if members.contains(where: { live($0).map { [.working, .background].contains($0.status) } == true }) { return true }
        guard let lead = board.leadSession.flatMap(live) else { return false }
        return lead.status == .working && lead.activity == mergeActivity
    }

    /// The projects whose team works, of the boards a refresh read (by root) and the sessions as it read them.
    static func working(_ boards: [String: LeadBoard], teams: [String: TeamReading]) -> Set<String> {
        Set(boards.compactMap { root, board in
            teams[root].map { working(board: board, hosted: $0.hosted, sessions: $0.sessions) } == true ? root : nil
        })
    }

    /// Holds an assertion for each of `roots` (the projects whose team works), as the setting and the power source
    /// allow, and releases the rest.
    func update(working roots: Set<String>) {
        let wanted: Set<String>
        switch mode() {
        case .never: wanted = []
        case .always: wanted = roots
        case .onPower: wanted = roots.isEmpty || !power.onACPower ? [] : roots
        }
        for (root, id) in assertions where !wanted.contains(root) {
            power.release(id)
            assertions[root] = nil
            Breadcrumbs.shared.note("keep awake: released for \((root as NSString).lastPathComponent)")
        }
        for root in wanted where assertions[root] == nil {
            guard let id = power.hold(Self.name(root: root)) else { continue }
            assertions[root] = id
            Breadcrumbs.shared.note("keep awake: holding for \((root as NSString).lastPathComponent)")
        }
        let now = Set(assertions.keys)
        if now != held { held = now }
    }
}
