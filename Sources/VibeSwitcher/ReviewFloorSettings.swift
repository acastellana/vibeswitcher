import SwiftUI
import VibeCore

/// A project's review rules' floor as Settings › Project lead edits it (see `LeadReviewFloor`): read from the session
/// host's vault and written there by the app alone, beside the project's own values (its workflow.md, as its lead
/// set them). Saved only on Save: a floor is a decision, not a draft.
final class ReviewFloorEditor: ObservableObject {
    /// The projects to choose from: those with a lead's workflow.md.
    @Published private(set) var projects: [String] = []
    @Published var root: String? { didSet { if root != oldValue { load() } } }
    /// The floor as edited.
    @Published var sensitive = ""
    @Published var strict = ""
    @Published var finders = 1
    @Published var policy = LeadWorkflow.MergePolicy.auto
    @Published var riskLines = 0
    @Published var riskModel = false
    @Published var verifierDifferent = true
    @Published var samplePercent = 0
    /// The floor as the vault has it; nil while none is recorded (the fields then show the project's values: what
    /// the app records when it next starts the lead).
    @Published private(set) var recorded: LeadReviewFloor?
    /// The project's workflow.md now.
    @Published private(set) var workflow = LeadWorkflow()
    @Published private(set) var problem: String?
    /// The vault is being asked (read or saved): the fields wait for its answer.
    @Published private(set) var busy = false
    private let vault: LeadVault
    private let listProjects: () -> [String]
    private let workerModel: (String) -> String?
    /// Where the vault is asked: off the main thread (a host call waits up to its timeout); the sandbox's own
    /// in-process vault, right here.
    private let background: (@escaping () -> Void) -> Void
    private let main: (@escaping () -> Void) -> Void
    /// Counts the vault calls asked: an answer to one that a later one replaced (another project chosen) is dropped.
    private var asked = 0

    /// `workerModel`: the model a project's workers start with (nil: not known), for the floor shown before one is
    /// recorded. `inline`: the vault answers at once (in-process), so it's asked on the calling thread.
    init(vault: LeadVault = .standard, projects: @escaping () -> [String], workerModel: @escaping (String) -> String? = { _ in nil },
         inline: Bool = false) {
        self.vault = vault
        self.listProjects = projects
        self.workerModel = workerModel
        background = inline ? { $0() } : { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
        main = inline ? { $0() } : { DispatchQueue.main.async(execute: $0) }
    }

    static func workflowPath(_ root: String) -> String { BoardStore(root: root).folder + "/workflow.md" }

    /// The projects again, keeping the one chosen while it's still there.
    func reload() {
        projects = Array(Set(listProjects().map { ($0 as NSString).standardizingPath }
            .filter { FileManager.default.fileExists(atPath: Self.workflowPath($0)) })).sorted()
        if let root, projects.contains(root) { load() } else { root = projects.first }
    }

    /// The project's workflow.md here, and its floor from the vault off the main thread.
    private func load() {
        guard let root else {
            // No project: an answer still on its way is for none shown.
            asked += 1
            busy = false
            return
        }
        workflow = LeadWorkflow.load(from: Self.workflowPath(root))
        let starting = LeadReviewFloor.starting(from: workflow, workerModel: workerModel(root))
        ask { vault in
            let read = Result { try vault.reviewFloor(root: root) }
            return { editor in
                switch read {
                case .success(let floor):
                    editor.recorded = floor
                    editor.problem = nil
                case .failure(let error):
                    editor.recorded = nil
                    editor.problem = "The session host couldn't say what the floor is: \(error)"
                }
                editor.show(editor.recorded ?? starting)
            }
        }
    }

    /// Asks the vault in the background; `asking`'s answer applies on the main thread, unless the project changed or
    /// a later call was asked meanwhile.
    private func ask(_ asking: @escaping (LeadVault) -> (ReviewFloorEditor) -> Void) {
        asked += 1
        let (call, root, vault) = (asked, root, vault)
        busy = true
        background { [weak self, main] in
            let apply = asking(vault)
            main {
                guard let self, self.asked == call, self.root == root else { return }
                self.busy = false
                apply(self)
            }
        }
    }

    private func show(_ floor: LeadReviewFloor) {
        sensitive = floor.sensitivePaths.joined(separator: ", ")
        strict = floor.strictPaths.joined(separator: ", ")
        finders = floor.auditFinders
        policy = floor.mergePolicy
        riskLines = floor.riskLines
        riskModel = floor.riskModel
        verifierDifferent = floor.verifierDifferent
        samplePercent = floor.auditSamplePercent
    }

    /// The floor as the fields say.
    var edited: LeadReviewFloor {
        LeadReviewFloor(sensitivePaths: LeadWorkflow.globsList(sensitive), strictPaths: LeadWorkflow.globsList(strict), auditFinders: finders,
                        mergePolicy: policy, riskLines: riskLines, riskModel: riskModel, verifierDifferent: verifierDifferent,
                        auditSamplePercent: samplePercent)
    }

    var changed: Bool { root != nil && !busy && edited != recorded }

    func save() {
        guard let root, !busy else { return }
        let edited = self.edited
        ask { vault in
            let saved = Result { try vault.setReviewFloor(edited, root: root) }
            return { editor in
                switch saved {
                case .success(let recorded):
                    editor.recorded = recorded
                    editor.problem = nil
                    editor.show(recorded ?? edited)
                case .failure(let error):
                    editor.problem = "Not saved: \(error)"
                }
            }
        }
    }

    func revert() { load() }
}

extension LeadWorkflow {
    /// A comma-separated list of globs; empty when it names none.
    static func globsList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Settings › Project lead's review rules' floor: per project, each rule's floor beside the project's value now.
struct ReviewFloorSection: View {
    @ObservedObject var editor: ReviewFloorEditor

    var body: some View {
        Section {
            if editor.projects.isEmpty {
                Text("No project has a lead yet.").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $editor.root) {
                    ForEach(editor.projects, id: \.self) { Text(($0 as NSString).lastPathComponent).tag(Optional($0)) }
                }
                ReviewFloorRows(editor: editor).disabled(editor.busy)
                HStack {
                    if editor.busy {
                        ProgressView().controlSize(.small)
                        Text("Asking the session host…").foregroundStyle(.secondary).font(.caption)
                    } else if let problem = editor.problem {
                        Text(problem).foregroundStyle(.red).font(.caption)
                    } else if editor.recorded == nil {
                        Text("Not recorded yet: these are the project's values, recorded when its lead next starts.")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                    Button("Revert") { editor.revert() }.disabled(!editor.changed || editor.recorded == nil)
                    Button("Save") { editor.save() }.disabled(!editor.changed)
                }
            }
        } header: {
            Text("Project lead: review rules floor")
        } footer: {
            SettingsFooter("The least strict each project's review rules may be. Its lead can raise a rule above the floor with configure, never lower one below it; what's in force is the floor joined with the project's workflow.md (paths: both lists; the rest: the stricter). Kept in the session host's vault, written only by VibeSwitcher.")
        }
        .onAppear { editor.reload() }
    }
}

/// Each rule: its floor's control, and the project's value now beneath it.
struct ReviewFloorRows: View {
    @ObservedObject var editor: ReviewFloorEditor

    var body: some View {
        let workflow = editor.workflow
        row("Sensitive paths", project: workflow.sensitivePaths.map { $0.joined(separator: ", ") } ?? "the defaults") {
            TextField("Sensitive paths", text: $editor.sensitive, axis: .vertical).lineLimit(1...4)
                .labelsHidden().accessibilityLabel("Sensitive paths floor, comma-separated")
                .font(.system(.callout, design: .monospaced))
        }
        row("Strict paths", project: workflow.strictPaths?.joined(separator: ", ") ?? "none") {
            TextField("Strict paths", text: $editor.strict, prompt: Text("none"), axis: .vertical).lineLimit(1...4)
                .labelsHidden().accessibilityLabel("Strict paths floor, comma-separated")
                .font(.system(.callout, design: .monospaced))
        }
        row("Audit finders, at least", project: String(workflow.auditFinders)) {
            Stepper("\(editor.finders)", value: $editor.finders, in: 1...LeadWorkflow.maxFinders)
                .accessibilityLabel("Audit finders floor").accessibilityValue("\(editor.finders)")
        }
        row("Merge policy, at least", project: workflow.mergePolicy?.rawValue ?? "not chosen") {
            Picker("Merge policy", selection: $editor.policy) {
                ForEach(LeadWorkflow.MergePolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().accessibilityLabel("Merge policy floor").fixedSize()
        }
        row("Risk lines, at most", project: workflow.riskLines == 0 ? "0 (no size trigger)" : String(workflow.riskLines)) {
            HStack(spacing: 4) {
                TextField("Risk lines", value: $editor.riskLines, format: .number)
                    .labelsHidden().accessibilityLabel("Risk lines floor, 0 for none")
                    .multilineTextAlignment(.trailing).frame(width: 60)
                if editor.riskLines == 0 { Text("(none)").foregroundStyle(.secondary) }
            }
        }
        row("Risk check's model pass", project: workflow.riskModel ? "on" : "off") {
            Toggle("Always on", isOn: $editor.riskModel).accessibilityLabel("Keep the risk check's model pass on")
        }
        row("Audit sample, at least", project: "\(workflow.auditSamplePercent) %") {
            Stepper("\(editor.samplePercent) %", value: $editor.samplePercent, in: 0...100, step: 5)
                .accessibilityLabel("Audit sample percent floor").accessibilityValue("\(editor.samplePercent) percent")
        }
        row("Verifier", project: workflow.verifierModel.map { $0.isEmpty ? "another model" : $0 } ?? "another model") {
            Toggle("Never the workers' model", isOn: $editor.verifierDifferent).accessibilityLabel("Verifier never on the workers' model")
        }
    }

    private func row<Control: View>(_ title: String, project: String, @ViewBuilder control: () -> Control) -> some View {
        LabeledContent {
            control()
        } label: {
            Text(title)
            Text("Project: \(project)").lineLimit(2).truncationMode(.middle)
        }
    }
}
