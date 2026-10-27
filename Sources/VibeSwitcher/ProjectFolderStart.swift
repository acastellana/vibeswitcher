import AppKit
import Foundation
import VibeCore

/// A new session asked for without a folder (Home's Choose Folder…, ⌘N with nothing selected): you pick the project's
/// folder, and its project lead starts there (or the one running is shown), as New Project… does. A preset you chose
/// first (⊕ › Other Folder… › a preset, New Shell) still starts that preset in the folder you pick, and one asked for
/// in a known folder starts there without asking.
struct ProjectFolderStart {
    /// What a new session does.
    enum Plan: Equatable {
        /// In a known folder: the preset (nil: the folder's first).
        case session(LaunchPreset?, in: String)
        /// Asks for a folder, then starts its lead.
        case chooseForLead
        /// Asks for a folder, then starts the preset you chose.
        case chooseForSession(LaunchPreset)
    }

    static func plan(preset: LaunchPreset?, folder: String?) -> Plan {
        if let folder { return .session(preset, in: folder) }
        return preset.map(Plan.chooseForSession) ?? .chooseForLead
    }

    /// The folder panel's button.
    static func prompt(for plan: Plan) -> String {
        switch plan {
        case .chooseForSession(let preset): return "Start \(preset.name) Here"
        case .chooseForLead, .session: return "Start Lead Here"
        }
    }

    /// The answer to a chosen folder that isn't in a git repository.
    enum NotRepositoryChoice: Equatable { case makeRepository, plainSession, cancel }

    static let notRepositoryButtons = ["Make it a git repository and start the lead", "Start a plain Claude session", "Cancel"]

    /// The question for a folder in no repository, from what making it one would commit.
    static func notRepositoryQuestion(_ plan: FolderRepository.Plan) -> (title: String, text: String) {
        let name = (plan.folder as NSString).lastPathComponent
        let count = plan.files.count
        var text = "A project lead works in a git repository. VibeSwitcher can run git init in \(ProjectCreation.tildePath(plan.folder)) "
            + "and make a first commit of its \(count == 1 ? "1 file" : "\(count) files")"
            + (plan.addsGitignore ? " (with a .gitignore for secrets and build output)" : "")
            + ". The commit stays on this Mac: nothing is pushed."
        if !plan.leftOut.isEmpty {
            let shown = plan.leftOut.prefix(8).joined(separator: ", ") + (plan.leftOut.count > 8 ? " and \(plan.leftOut.count - 8) more" : "")
            text += "\n\nLeft out, as they look like secrets: \(shown)."
        }
        if !plan.nested.isEmpty {
            let shown = plan.nested.prefix(8).joined(separator: ", ") + (plan.nested.count > 8 ? " and \(plan.nested.count - 8) more" : "")
            text += "\n\nA repository of its own, committed as a reference (its files aren't included): \(shown)."
        }
        return ("“\(name)” isn't a git repository.", text)
    }

    /// The alert asking it (the sandbox draws it too).
    static func notRepositoryAlert(_ plan: FolderRepository.Plan) -> NSAlert {
        let question = notRepositoryQuestion(plan)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        notRepositoryButtons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    static func askInAlert(_ plan: FolderRepository.Plan) -> Int {
        let alert = notRepositoryAlert(plan)
        NSApp.activate()
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func choice(forButton index: Int) -> NotRepositoryChoice {
        switch index {
        case 0: return .makeRepository
        case 1: return .plainSession
        default: return .cancel
        }
    }

    /// Asks for a folder with the panel's button title; nil: cancelled.
    var chooseFolder: (_ prompt: String) -> String?
    /// Runs git in a folder (off the main thread).
    var git: ProjectCreation.GitRunner = { Git.run($0, in: $1) }
    /// Where `FolderRepository.plan` lists a folder's files.
    var scratch: URL = FileManager.default.temporaryDirectory
    /// Asks what to do with a folder in no repository (`notRepositoryButtons`): the index of the button chosen.
    var ask: (_ plan: FolderRepository.Plan) -> Int = ProjectFolderStart.askInAlert
    /// Starts the project lead of the repository holding a folder (or shows the running one).
    var startLead: (_ folder: String) -> Void
    /// Starts a preset in a folder (nil: the folder's first).
    var startSession: (_ preset: LaunchPreset?, _ folder: String) -> Void
    /// Says why something couldn't be done.
    var failed: (_ title: String, _ text: String) -> Void

    func run(preset: LaunchPreset?, folder: String?) {
        let plan = Self.plan(preset: preset, folder: folder)
        switch plan {
        case .session(let preset, let folder):
            startSession(preset, folder)
        case .chooseForSession(let preset):
            guard let folder = chooseFolder(Self.prompt(for: plan)) else { return }
            startSession(preset, folder)
        case .chooseForLead:
            guard let folder = chooseFolder(Self.prompt(for: plan)) else { return }
            startLead(chosen: folder)
        }
    }

    /// A folder in a repository (or inside one: its lead is that repository's) starts the lead; one in none asks first.
    func startLead(chosen folder: String) {
        let (git, scratch) = (git, scratch)
        // git can be slow (a network volume): off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let top = git(["rev-parse", "--show-toplevel"], folder)
            let inRepository = top.ok && !top.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let plan = inRepository ? nil : FolderRepository.plan(for: folder, scratch: scratch, git: git)
            DispatchQueue.main.async {
                guard let plan else { return self.startLead(folder) }
                switch plan {
                case .failure(let problem):
                    self.failed("“\((folder as NSString).lastPathComponent)” isn't a git repository.",
                                "A project lead needs one, and its files couldn't be listed: \(problem.message)")
                case .success(let plan):
                    self.answer(plan)
                }
            }
        }
    }

    private func answer(_ plan: FolderRepository.Plan) {
        switch Self.choice(forButton: ask(plan)) {
        case .cancel: return
        case .plainSession: startSession(nil, plan.folder)
        case .makeRepository:
            let git = git
            DispatchQueue.global(qos: .userInitiated).async {
                let problem = FolderRepository.make(plan, git: git)
                DispatchQueue.main.async {
                    if let problem {
                        self.failed("“\((plan.folder as NSString).lastPathComponent)” couldn't be made a git repository.", problem.message)
                    } else {
                        self.startLead(plan.folder)
                    }
                }
            }
        }
    }
}
