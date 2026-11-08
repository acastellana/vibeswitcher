import SwiftUI
import VibeCore

/// The Mac-wide limits as Settings › Project lead edits them (see `MacLimits`): each change is saved to
/// `~/.vibeswitcher/mac-limits.json` at once, and every project's lead tool server reads it at its next call.
final class MacLimitsEditor: ObservableObject {
    /// Team sessions (workers and verifiers) of all projects at once, at least 1.
    @Published var maxSessions: Int { didSet { changed() } }
    /// The load (the greater of the 1- and 5-minute averages) above which leads start nothing; nil (empty) or 0: twice the cores.
    @Published var loadThreshold: Double? { didSet { changed() } }
    /// Builds and full test runs at once, Mac-wide (vs-heavy's, merges', audits'), 1 to the cores.
    @Published var heavySlots: Int { didSet { changed() } }
    /// "Ignore usage limits": no back-off for the Claude account's usage (see `MacLimits.ignoreUsageLimits`).
    @Published var ignoreUsageLimits: Bool {
        didSet {
            changed()
            if !loading, ignoreUsageLimits != oldValue { NotificationCenter.default.post(name: Self.usageLimitsChanged, object: self) }
        }
    }
    /// Posted once "Ignore usage limits" is saved changed: the leads look again at what they held for usage.
    static let usageLimitsChanged = Notification.Name("VibeSwitcher.MacLimits.usageLimitsChanged")
    @Published private(set) var problem: String?
    private let file: URL
    /// The memory holds as the file has them (no control here: kept as they are on each save).
    private var memoryPressure: String?
    private var swapOutRate: Double?
    private var loading = false

    init(file: URL = MacLimits.file) {
        self.file = file
        let limits = MacLimits.load(from: file)
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
        heavySlots = limits.heavySlots
        ignoreUsageLimits = limits.ignoreUsageLimits
        memoryPressure = limits.memoryPressure
        swapOutRate = limits.swapOutRate
    }

    /// The limits as the leads read them (a value out of range as it's kept).
    var limits: MacLimits { MacLimits(maxSessions: maxSessions, loadThreshold: loadThreshold, heavySlots: heavySlots,
                                     ignoreUsageLimits: ignoreUsageLimits, memoryPressure: memoryPressure, swapOutRate: swapOutRate) }

    /// The file as it is now.
    func reload() {
        let limits = MacLimits.load(from: file)
        loading = true
        memoryPressure = limits.memoryPressure
        swapOutRate = limits.swapOutRate
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
        heavySlots = limits.heavySlots
        ignoreUsageLimits = limits.ignoreUsageLimits
        loading = false
    }

    private func changed() {
        guard !loading else { return }
        let kept = limits
        // Shown as kept: 0 sessions is 1, a threshold of 0 or less is none.
        if kept.maxSessions != maxSessions || kept.loadThreshold != loadThreshold || kept.heavySlots != heavySlots {
            loading = true
            maxSessions = kept.maxSessions
            loadThreshold = kept.loadThreshold
            heavySlots = kept.heavySlots
            loading = false
        }
        do {
            try kept.save(to: file)
            problem = nil
        } catch {
            problem = "Couldn't save \(file.path): \(error.localizedDescription)"
        }
    }
}

/// Settings › Performance's Mac-wide limits and usage limits: what every project's leads start teams under.
struct MacLimitsSection: View {
    @StateObject private var editor = MacLimitsEditor()

    var body: some View {
        Section {
            SettingRow("max-sessions") { label in
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("Team sessions", value: $editor.maxSessions, format: .number)
                            .labelsHidden().accessibilityLabel("Team sessions on this Mac, at most")
                            .multilineTextAlignment(.trailing).frame(width: 44)
                        Stepper("Team sessions", value: $editor.maxSessions, in: 1...99).labelsHidden()
                    }
                } label: { label }
            }
            SettingRow("load-threshold") { label in
                LabeledContent {
                    TextField("Load limit", value: $editor.loadThreshold, format: .number,
                              prompt: Text(MacLoad.number(Double(2 * MacLoad.processors))))
                        .labelsHidden().accessibilityLabel("Start nothing above a load of; empty is twice the cores")
                        .multilineTextAlignment(.trailing).frame(width: 60)
                } label: { label }
            }
            SettingRow("heavy-slots") { label in
                BoostStepper(label: label, name: "Test and build slots at once", value: $editor.heavySlots, range: 1...MacLimits.heavySlotsCeiling)
            }
            if let problem = editor.problem {
                Text(problem).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Mac-wide limits")
        } footer: {
            SettingsFooter("Every project's leads share this Mac: they start nothing at the first limit, or while the load (the greater of the 1- and 5-minute averages) is above the second, and merges wait for the load. A lead refused for either is told once there's room. Builds and full test runs take one slot each; each gets VS_HEAVY_CORES, the \(MacLoad.processors) cores ÷ the slots (\(BoostSection.coresPerSlot(editor.heavySlots)) each); a project's heavy_slots in workflow.md sets its own. Kept in ~/.vibeswitcher/mac-limits.json; workflow.md's load_threshold and mac_max_sessions are ignored.")
        }
        .onAppear { editor.reload() }
        Section {
            SettingRow("ignore-usage-limits") { label in
                Toggle(isOn: $editor.ignoreUsageLimits) { label }
                    .accessibilityLabel("Ignore usage limits: start workers and audits whatever share of a Claude limit is used")
            }
        } header: {
            Text("Usage limits")
        } footer: {
            SettingsFooter("Leads start workers and audits at any share of a Claude limit (normally they stop at \(Int(AccountUsage.threshold)) %), Boost isn't held off for usage, and agent: auto stays on Claude until Claude refuses at a limit. A session that reaches a limit still stops, and the lead is told. Usage still shows, marked \(AccountUsage.ignoredMark).")
        }
    }
}

/// Settings › Performance's Boost mode (see `Boost`): Off, On, or Automatic (only while you're away and the Mac is on
/// AC power), "Also on battery" (down to `Boost.batteryFloor` % of charge), and the limits it raises to. Saved through
/// `Preferences`; `BoostWatch` decides and tells the leads.
struct BoostSection: View {
    @ObservedObject var preferences: Preferences
    /// The app's watch, for what's decided now; nil in previews and tests without one.
    var watch: BoostWatch?

    var body: some View {
        Section {
            SettingRow("boost-mode") { label in
                Picker(selection: $preferences.boostMode) {
                    ForEach(BoostMode.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: { label }
                .pickerStyle(.segmented)
                .accessibilityLabel("Boost mode: off, on, or automatic while you're away and on AC power")
            }
            SettingRow("boost-on-battery") { label in Toggle(isOn: $preferences.boostOnBattery) { label } }
            SettingRow("boost-load") { label in
                LabeledContent {
                    TextField("Boost load limit", value: $preferences.boostLimits.loadThreshold, format: .number)
                        .labelsHidden().accessibilityLabel("Start nothing above a load of, while boosted")
                        .multilineTextAlignment(.trailing).frame(width: 60)
                } label: { label }
            }
            SettingRow("boost-sessions") { label in
                BoostStepper(label: label, name: "Team sessions on this Mac while boosted, at most", value: $preferences.boostLimits.maxSessions,
                             range: 1...BoostLimits.countCeiling)
            }
            SettingRow("boost-workers") { label in
                BoostStepper(label: label, name: "Workers per project while boosted, at most", value: $preferences.boostLimits.maxWorkers,
                             range: 1...BoostLimits.countCeiling)
            }
            SettingRow("boost-slots") { label in
                BoostStepper(label: label, name: "Test and build slots while boosted", value: $preferences.boostLimits.heavySlots,
                             range: 1...BoostLimits.slotCeiling)
            }
            if let watch { BoostNow(watch: watch) }
        } header: {
            Text("Boost")
        } footer: {
            SettingsFooter("Automatic boosts only while the Mac is on AC power and you're away (screen locked, or no input for 5 minutes), and drops back within \(BoostWatch.every) seconds of either changing: new starts stop above the normal limits, running work finishes. On battery it's off whatever the mode, unless Also on battery is on (the battery limit below still pauses lead work). Projects whose merge_batching is boost test merges in batches while boosted. The usage watch keeps it off at \(MacLoad.number(Boost.vetoPercent)) % of an account limit, unless Ignore usage limits is on. While boosted, room freed on the Mac goes first to the project you last worked in. VS_HEAVY_CORES follows the slots: the \(MacLoad.processors) cores ÷ the slots (\(Self.coresPerSlot(preferences.boostLimits.heavySlots)) each).")
        }
    }
}

extension BoostSection {
    /// A slot's share of the cores as vs-heavy gives it (VS_HEAVY_CORES): the cores ÷ the slots, rounded up, at least 2.
    static func coresPerSlot(_ slots: Int, cores: Int = MacLoad.processors) -> Int {
        max(2, (cores + max(1, slots) - 1) / max(1, slots))
    }
}

/// One whole-number limit: a field and a stepper, within `range`.
private struct BoostStepper: View {
    let label: SettingLabel
    /// Its name for VoiceOver: the field and stepper hide their labels.
    let name: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...99

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(name, value: $value, format: .number)
                    .labelsHidden().accessibilityLabel(name)
                    .multilineTextAlignment(.trailing).frame(width: 44)
                Stepper(name, value: $value, in: range).labelsHidden()
            }
        } label: { label }
    }
}

/// What the watch decided now: "Now: boost on (automatic: away, on AC)".
private struct BoostNow: View {
    @ObservedObject var watch: BoostWatch

    var body: some View {
        if let state = watch.state {
            Label("Now: \(state.text)", systemImage: state.on ? "bolt.fill" : "bolt.slash")
                .foregroundStyle(state.on ? Color.orange : Color.secondary)
                .font(.callout)
                .accessibilityLabel("Now: \(state.text)")
        }
        if let problem = watch.problem {
            Text(problem).foregroundStyle(.red).font(.caption)
        }
    }
}
