import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher new-project NAME [--in LOCATION] [--folder NAME] [--goal TEXT] [--no-lead]` (the parity table's New
/// Project… row; the app's sheet, `ProjectCreation`, shared): a folder named for NAME ("My App": my-app) in LOCATION
/// (default: the node's projects folder, `vibeswitcher set projects_folder PATH`, else `~/dev`, as the app's Settings ›
/// General), with a git repository and a first commit of README.md and
/// .gitignore, or nothing left behind; then its lead started (`vibeswitcher lead FOLDER [--goal TEXT]`, the user's voice
/// with its own typed code), unless `--no-lead`. Making the folder is this process's own, as `git init` in a terminal
/// is: nothing of the node's is asked for it. A project made whose lead didn't start says so and how to start it.
enum NewProjectCommand {
    static let usage = "usage: vibeswitcher new-project NAME [--in LOCATION] [--folder NAME] [--goal TEXT] [--no-lead]"

    struct Asked: Equatable {
        var name: String
        /// nil: the node's projects folder.
        var location: String?
        var folder: String?
        var goal: String?
        var lead = true
    }

    static func parse(_ arguments: [String]) -> Asked? {
        var asked: Asked?
        var words = arguments[...]
        var location: String?, folder: String?, goal: String?, lead = true
        while let word = words.popFirst() {
            switch word {
            case "--in":
                guard let value = words.popFirst(), !value.isEmpty else { return nil }
                location = value
            case "--folder":
                guard let value = words.popFirst(), !value.isEmpty else { return nil }
                folder = value
            case "--goal":
                guard let value = words.popFirst(), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                goal = value
            case "--no-lead": lead = false
            default:
                guard asked == nil, !word.hasPrefix("--") else { return nil }
                asked = Asked(name: word)
            }
        }
        guard var asked, goal == nil || lead else { return nil }
        if let location { asked.location = location }
        asked.folder = folder
        asked.goal = goal
        asked.lead = lead
        return asked
    }

    static func run(_ arguments: [String], home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                    nodeRoot: @autoclosure () -> URL = NodeContext.current().root) -> Int32 {
        guard let asked = parse(arguments) else { return Say.usage(usage) }
        // The node's projects folder is read from its settings file, as the command's own read: a node not running yet
        // still has it, and nothing of the node's is asked.
        let location = asked.location ?? NodeSettings.projectsFolder(files: NodeSettings.Files(root: nodeRoot()))
        let plan: ProjectCreation.Plan
        switch ProjectCreation.plan(name: asked.name, folderName: asked.folder ?? ProjectCreation.folderName(for: asked.name),
                                    location: location, home: home) {
        case .failure(let problem): return Say.refused(problem.message)
        case .success(let made): plan = made
        }
        if let problem = ProjectCreation.create(plan) { return Say.refused(problem.message) }
        let shown = ConfigSeal.inert(ProjectCreation.tildePath(plan.folder, home: home), limit: 200)
        Say.out("made: \(shown), a git repository with a first commit (README.md, .gitignore)")
        guard asked.lead else {
            Say.out("`vibeswitcher lead \(ConfigSeal.inert(plan.folder, limit: 200)) --goal TEXT` starts its lead")
            return 0
        }
        let status = LeadCommand.run([plan.folder] + (asked.goal.map { ["--goal", $0] } ?? []))
        if status != 0 {
            Say.err("the project is made, its lead isn't started: `vibeswitcher lead \(ConfigSeal.inert(plan.folder, limit: 200))"
                + (asked.goal == nil ? "" : " --goal TEXT") + "` starts it once what was refused above is done")
        }
        return status
    }
}
