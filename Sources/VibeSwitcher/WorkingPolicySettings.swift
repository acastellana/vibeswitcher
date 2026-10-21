import SwiftUI
import VibeCore

/// The working policy as Settings › Project lead edits it (see `WorkingPolicy`): a draft, saved to
/// `~/.vibeswitcher/policy.md` with Save, or put back to the user's five rules with Reset to Default. Each save tells
/// the running leads at once (`saved`); the witness looks once a minute too, for an edit made in the file itself.
final class WorkingPolicyEditor: ObservableObject {
    @Published var draft: String
    /// The text as saved (or the default, while there's no file).
    @Published private(set) var saved: String
    @Published private(set) var problem: String?
    private let file: URL
    private let didSave: () -> Void

    init(file: URL = WorkingPolicy.file, saved: @escaping () -> Void = {}) {
        self.file = file
        didSave = saved
        let text = WorkingPolicy.load(from: file)
        self.saved = text
        draft = text
    }

    var changed: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) != saved }
    var isDefault: Bool { saved == WorkingPolicy.defaultText && !changed }

    /// The file as it is now, unless the draft has edits of its own.
    func reload() {
        let text = WorkingPolicy.load(from: file)
        if !changed { draft = text }
        saved = text
    }

    func save() {
        do {
            try WorkingPolicy.save(draft, to: file)
            problem = nil
        } catch {
            problem = "Couldn't save \(file.path): \(error.localizedDescription)"
            return
        }
        saved = WorkingPolicy.load(from: file)
        draft = saved
        didSave()
    }

    func resetToDefault() {
        draft = WorkingPolicy.defaultText
        save()
    }
}

/// Settings › Project lead's working policy: what every project's lead, workers and verifiers are told.
struct WorkingPolicySection: View {
    @ObservedObject var editor: WorkingPolicyEditor

    var body: some View {
        Section {
            TextEditor(text: $editor.draft)
                .font(.system(.callout))
                .frame(minHeight: 120)
                .accessibilityLabel("Working policy")
            HStack {
                if let problem = editor.problem {
                    Text(problem).foregroundStyle(.red).font(.caption)
                }
                Spacer()
                Button("Reset to Default") { editor.resetToDefault() }
                    .disabled(editor.isDefault)
                Button("Save") { editor.save() }
                    .disabled(!editor.changed)
            }
        } header: {
            Text("Project lead: working policy")
        } footer: {
            SettingsFooter("Every project's lead, workers and verifiers get this in their prompts. When you save a change, each lead running now is told it once and applies it from then on. Kept in ~/.vibeswitcher/policy.md.")
        }
        .onAppear { editor.reload() }
    }
}
