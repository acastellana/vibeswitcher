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
    @Published private(set) var problem: String?
    private let file: URL
    private var loading = false

    init(file: URL = MacLimits.file) {
        self.file = file
        let limits = MacLimits.load(from: file)
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
        heavySlots = limits.heavySlots
    }

    /// The limits as the leads read them (a value out of range as it's kept).
    var limits: MacLimits { MacLimits(maxSessions: maxSessions, loadThreshold: loadThreshold, heavySlots: heavySlots) }

    /// The file as it is now.
    func reload() {
        let limits = MacLimits.load(from: file)
        loading = true
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
        heavySlots = limits.heavySlots
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

/// Settings › Project lead's Mac-wide limits: what every project's leads start teams under.
struct MacLimitsSection: View {
    @StateObject private var editor = MacLimitsEditor()

    var body: some View {
        Section {
            LabeledContent("Team sessions on this Mac, at most") {
                HStack(spacing: 4) {
                    TextField("Team sessions", value: $editor.maxSessions, format: .number)
                        .labelsHidden().accessibilityLabel("Team sessions on this Mac, at most")
                        .multilineTextAlignment(.trailing).frame(width: 44)
                    Stepper("Team sessions", value: $editor.maxSessions, in: 1...99).labelsHidden()
                }
            }
            LabeledContent("Start nothing above a load of") {
                TextField("Load limit", value: $editor.loadThreshold, format: .number,
                          prompt: Text(MacLoad.number(Double(2 * MacLoad.processors))))
                    .labelsHidden().accessibilityLabel("Start nothing above a load of; empty is twice the cores")
                    .multilineTextAlignment(.trailing).frame(width: 60)
            }
            BoostStepper(label: "Test and build slots at once", value: $editor.heavySlots, range: 1...MacLimits.heavySlotsCeiling)
            if let problem = editor.problem {
                Text(problem).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Project lead: Mac-wide limits")
        } footer: {
            SettingsFooter("Every project's leads share this Mac. They start no workers or audits while the workers and verifiers of all projects together are at the first limit, or the Mac's load is above the second (the greater of its 1- and 5-minute averages, so a dip after a spike isn't room; empty: twice the \(MacLoad.processors) cores); merges wait for the load. A lead refused for either is told once there's room again. Builds and full test runs (vs-heavy's, merges', audits') take one of the test and build slots; one more waits. Each gets VS_HEAVY_CORES, the \(MacLoad.processors) cores ÷ the slots (\(BoostSection.coresPerSlot(editor.heavySlots)) each), and caps its own parallelism to it; a project's heavy_slots in workflow.md sets its own. Kept in ~/.vibeswitcher/mac-limits.json; workflow.md's load_threshold and mac_max_sessions are ignored.")
        }
        .onAppear { editor.reload() }
    }
}

/// Settings › Project lead's Boost mode (see `Boost`): Off, On, or Automatic (only while you're away and the Mac is on
/// AC power), and the limits it raises to. Saved through `Preferences`; `BoostWatch` decides and tells the leads.
struct BoostSection: View {
    @ObservedObject var preferences: Preferences
    /// The app's watch, for what's decided now; nil in previews and tests without one.
    var watch: BoostWatch?

    var body: some View {
        Section {
            Picker("Boost", selection: $preferences.boostMode) {
                ForEach(BoostMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Boost mode: off, on, or automatic while you're away and on AC power")
            LabeledContent("Start nothing above a load of, while boosted") {
                TextField("Boost load limit", value: $preferences.boostLimits.loadThreshold, format: .number)
                    .labelsHidden().accessibilityLabel("Start nothing above a load of, while boosted")
                    .multilineTextAlignment(.trailing).frame(width: 60)
            }
            BoostStepper(label: "Team sessions on this Mac while boosted, at most", value: $preferences.boostLimits.maxSessions,
                         range: 1...BoostLimits.countCeiling)
            BoostStepper(label: "Workers per project while boosted, at most", value: $preferences.boostLimits.maxWorkers,
                         range: 1...BoostLimits.countCeiling)
            BoostStepper(label: "Test and build slots while boosted", value: $preferences.boostLimits.heavySlots,
                         range: 1...BoostLimits.slotCeiling)
            if let watch { BoostNow(watch: watch) }
        } header: {
            Text("Project lead: Boost")
        } footer: {
            SettingsFooter("Boost raises the Mac-wide limits to these for more throughput: leads start more workers and audits, and projects whose merge_batching is boost test merges in batches. Automatic boosts only while the Mac is on AC power and you're away (screen locked, or no input for 5 minutes), and drops back within \(BoostWatch.every) seconds of either changing: new starts stop above the normal limits, running work finishes. Never on battery, whatever the mode; the usage watch keeps it off at \(MacLoad.number(Boost.vetoPercent)) % of an account limit. While boosted, room freed on the Mac goes first to the project you last worked in, and no project runs more than its workers' limit. The test and build slots go up to these for vs-heavy and the leads' merges and audits alike (never below the normal count), and VS_HEAVY_CORES follows: the \(MacLoad.processors) cores ÷ the slots (\(Self.coresPerSlot(preferences.boostLimits.heavySlots)) each).")
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
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...99

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: $value, format: .number)
                    .labelsHidden().accessibilityLabel(label)
                    .multilineTextAlignment(.trailing).frame(width: 44)
                Stepper(label, value: $value, in: range).labelsHidden()
            }
        }
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
