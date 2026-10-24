import SwiftUI
import VibeCore

/// The Mac-wide limits as Settings › Project lead edits them (see `MacLimits`): each change is saved to
/// `~/.vibeswitcher/mac-limits.json` at once, and every project's lead tool server reads it at its next call.
final class MacLimitsEditor: ObservableObject {
    /// Team sessions (workers and verifiers) of all projects at once, at least 1.
    @Published var maxSessions: Int { didSet { changed() } }
    /// The 1-minute load above which leads start nothing; nil (empty) or 0: twice the cores.
    @Published var loadThreshold: Double? { didSet { changed() } }
    @Published private(set) var problem: String?
    private let file: URL
    private var loading = false

    init(file: URL = MacLimits.file) {
        self.file = file
        let limits = MacLimits.load(from: file)
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
    }

    /// The limits as the leads read them (a value out of range as it's kept).
    var limits: MacLimits { MacLimits(maxSessions: maxSessions, loadThreshold: loadThreshold) }

    /// The file as it is now.
    func reload() {
        let limits = MacLimits.load(from: file)
        loading = true
        maxSessions = limits.maxSessions
        loadThreshold = limits.loadThreshold
        loading = false
    }

    private func changed() {
        guard !loading else { return }
        let kept = limits
        // Shown as kept: 0 sessions is 1, a threshold of 0 or less is none.
        if kept.maxSessions != maxSessions || kept.loadThreshold != loadThreshold {
            loading = true
            maxSessions = kept.maxSessions
            loadThreshold = kept.loadThreshold
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
            LabeledContent("Start nothing above a 1-minute load of") {
                TextField("Load limit", value: $editor.loadThreshold, format: .number,
                          prompt: Text(MacLoad.number(Double(2 * MacLoad.processors))))
                    .labelsHidden().accessibilityLabel("Start nothing above a 1-minute load of; empty is twice the cores")
                    .multilineTextAlignment(.trailing).frame(width: 60)
            }
            if let problem = editor.problem {
                Text(problem).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("Project lead: Mac-wide limits")
        } footer: {
            SettingsFooter("Every project's leads share this Mac. They start no workers or audits while the workers and verifiers of all projects together are at the first limit, or the Mac's 1-minute load is above the second (empty: twice the \(MacLoad.processors) cores); merges wait for the load. A lead refused for either is told once there's room again. Kept in ~/.vibeswitcher/mac-limits.json; workflow.md's load_threshold and mac_max_sessions are ignored.")
        }
        .onAppear { editor.reload() }
    }
}
