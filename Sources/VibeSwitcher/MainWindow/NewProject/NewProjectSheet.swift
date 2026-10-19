import AppKit
import SwiftUI
import VibeCore

/// Home's New Project… sheet: a name, where it goes, git with a first commit, and what to do once it's made.
final class NewProjectModel: ObservableObject {
    enum Then: Hashable { case nothing, session, lead }

    @Published var name = "" {
        didSet { if !folderEdited { folderName = ProjectCreation.folderName(for: name) } }
    }
    /// Derived from the name until it's edited (and again once an edit matches what it would derive).
    @Published private(set) var folderName = ""
    private var folderEdited = false
    /// As shown: "~/dev".
    @Published var location: String
    @Published var initializeGit = true
    @Published var then: Then = .nothing
    @Published var presetID: UUID?
    @Published var goal = ""
    @Published private(set) var creating = false
    /// Create was pressed: an empty name says so from then on.
    @Published private(set) var attempted = false
    /// What went wrong making it (git's message), for the one alert.
    @Published var failure: String?
    let presets: [LaunchPreset]
    /// How git runs (tests give it a scratch HOME and config).
    var git: ProjectCreation.GitRunner = { Git.run($0, in: $1) }

    init(location: String, presets: [LaunchPreset]) {
        self.location = location
        self.presets = presets
        presetID = (presets.first { $0.kind == .claude && $0.place == .window } ?? presets.first { $0.kind == .claude }
                    ?? presets.first)?.id
    }

    func editFolderName(_ text: String) {
        folderName = text
        folderEdited = text != ProjectCreation.folderName(for: name)
    }

    var plan: Result<ProjectCreation.Plan, ProjectCreation.Problem> {
        ProjectCreation.plan(name: name, folderName: folderName, location: location,
                             options: .init(initializeGit: initializeGit))
    }

    static let leadNeedsGit = "The project lead needs the git repository and its first commit: turn that on, or pick another next step."

    /// The line under the form saying why Create won't go; nil while the name is still empty and untried.
    var problem: String? {
        if case .failure(let problem) = plan, attempted || problem != .emptyName { return problem.message }
        if then == .lead && !initializeGit { return Self.leadNeedsGit }
        if then == .session && preset == nil { return "There's no launch preset to open: add one in Settings › Launch." }
        return nil
    }

    var preset: LaunchPreset? { presets.first { $0.id == presetID } }

    var next: ProjectCreation.Next {
        switch then {
        case .nothing: return .nothing
        case .session: return preset.map { .session($0) } ?? .nothing
        case .lead:
            let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            return .lead(goal: text.isEmpty ? nil : text)
        }
    }

    /// "~/dev isn't there yet" while it isn't.
    var locationNote: String? {
        guard case .success(let plan) = plan, plan.createsLocation else { return nil }
        return "\(ProjectCreation.tildePath((plan.folder as NSString).deletingLastPathComponent)) isn't there yet: it will be made."
    }

    /// Makes the project off the main thread (git can be slow); `done` gets its folder on the main thread.
    func create(_ done: @escaping (String, ProjectCreation.Next) -> Void) {
        guard !creating else { return }
        attempted = true
        guard problem == nil, case .success(let plan) = plan else { return }
        creating = true
        let next = next, git = git
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem = ProjectCreation.create(plan, git: git)
            DispatchQueue.main.async {
                guard let self else { return }
                self.creating = false
                if let problem { self.failure = problem.message } else { done(plan.folder, next) }
            }
        }
    }
}

struct NewProjectSheet: View {
    @StateObject private var model: NewProjectModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    let created: (String, ProjectCreation.Next) -> Void
    let close: () -> Void

    init(model: NewProjectModel, created: @escaping (String, ProjectCreation.Next) -> Void, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.created = created
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Project").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 18)
            Form {
                Section {
                    TextField("Name", text: $model.name, prompt: Text("My Project"))
                        .focused($nameFocused)
                        .accessibilityLabel("Project name")
                    LabeledContent("Folder") {
                        TextField("Folder name", text: Binding(get: { model.folderName }, set: { model.editFolderName($0) }),
                                  prompt: Text("my-project"))
                            .labelsHidden().font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Folder name")
                    }
                    LabeledContent("Location") {
                        HStack {
                            TextField("Location", text: $model.location).labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Location")
                            Button("Choose…") {
                                if let folder = ProjectsFolderPanel.choose(startingAt: ProjectCreation.expand(model.location)) {
                                    model.location = ProjectCreation.tildePath(folder)
                                }
                            }
                            .accessibilityLabel("Choose the location")
                        }
                    }
                    if let note = model.locationNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Initialize a git repository with a first commit", isOn: $model.initializeGit)
                } footer: {
                    SettingsFooter("On git's default branch (init.defaultBranch, else main), with a README.md titled with the name and a .gitignore for .DS_Store and .build/.")
                }
                Section {
                    Picker("Then", selection: $model.then) {
                        Text("Nothing").tag(NewProjectModel.Then.nothing)
                        Text("Open a session").tag(NewProjectModel.Then.session)
                        Text("Start the project lead").tag(NewProjectModel.Then.lead)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityLabel("Then")
                    if model.then == .session {
                        Picker("Preset", selection: $model.presetID) {
                            ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .accessibilityLabel("Preset")
                    }
                    if model.then == .lead {
                        TextField("First goal", text: $model.goal, prompt: Text("Optional: what the lead should build first"))
                            .accessibilityLabel("First goal")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.creating)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.then)
            HStack(spacing: 10) {
                if let problem = model.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.creating {
                    ProgressView().controlSize(.small).accessibilityLabel("Creating the project")
                    Text("Creating…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).disabled(model.creating)
                Button("Create") { model.create { folder, next in close(); created(folder, next) } }
                    .keyboardShortcut(.defaultAction).disabled(model.creating)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { nameFocused = true }
        .alert("The project couldn't be made", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }
}

/// Asks for a folder to put projects in (Settings, and the sheet's Location).
enum ProjectsFolderPanel {
    static func choose(startingAt directory: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // The folder itself if it's there, else the nearest one that is.
        var start = directory
        while !start.isEmpty, start != "/", ProjectCreation.existing(start) != .folder { start = (start as NSString).deletingLastPathComponent }
        if !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
