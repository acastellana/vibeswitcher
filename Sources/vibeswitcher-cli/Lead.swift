import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher lead FOLDER [--goal TEXT | --resume] [--take-head] [--replace]` (the engine plan's E4): the server's `lead`, in
/// the user's voice, after the command line's own typed code (EN-D5). What the app asked in a dialog is a flag:
/// `--take-head` takes a base that moved since the lead last left it as it is (without it merges stay refused until
/// `base accept`); `--replace` starts a new lead where one runs without its role (without it that one is shown);
/// `--resume` reopens the lead a session host restart ended in its same conversation (`claude --resume`, the node's
/// restart card: `status` offers it), after the same accepts, telling it which workers ended. Before
/// the code it prints the program the lead will run, `claude` resolved as the server resolves it (EN-D13); the reply
/// says the one it ran. The accepted request is written to the journal (ids only: no goal, no folder).
/// `--init` is the app's offer for a folder a lead can't start in yet (`LeadController`'s first commit,
/// `ProjectFolderStart`'s question), narrowed to a folder in no repository: a git repository and a first commit of its
/// files (`LeadInit`: built privately, installed through the folder's descriptor, every committed name shown before the
/// code, as the user's global identity, secrets left out and named), made after the code by this process as `git init`
/// in a terminal is; nothing left on a refusal. A folder with any `.git`, inside a repository, the home folder or `/` is
/// refused, and so is everything when no claude is there for the lead. Not under the Mac's approval rule yet (its
/// dialog is the server's, after this process would have made the commit).
enum LeadCommand {
    static let usage = "usage: vibeswitcher lead FOLDER [--goal TEXT | --resume] [--take-head] [--replace] [--init]"

    struct Asked: Equatable {
        var folder: String
        var goal: String?
        var takeHead = false
        var replace = false
        var resume = false
        var initialize = false
    }

    /// The arguments read; nil when they're not the command's.
    static func parse(_ arguments: [String], cwd: String = FileManager.default.currentDirectoryPath) -> Asked? {
        var folder: String?
        var asked = Asked(folder: "")
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            switch word {
            case "--goal":
                guard index + 1 < arguments.count else { return nil }
                index += 1
                asked.goal = arguments[index]
            case "--take-head": asked.takeHead = true
            case "--replace": asked.replace = true
            case "--resume": asked.resume = true
            case "--init": asked.initialize = true
            default:
                guard folder == nil, !word.hasPrefix("--") else { return nil }
                folder = word
            }
            index += 1
        }
        guard let folder, !folder.isEmpty, !(asked.resume && asked.goal != nil), !(asked.resume && asked.initialize) else { return nil }
        asked.folder = URL(fileURLWithPath: folder, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
        return asked
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let asked = parse(arguments) else { return Say.usage(usage) }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let program: String
        switch NodePreflight(claudeLink: NodePreflight.claudeLink(root: context.root)).check() {
        case .failure(let refusal):
            // Nothing is made for a lead the server will refuse to start.
            if asked.initialize { return Say.refused("no claude for the lead (\(refusal.missing.joined(separator: "; "))): nothing was made") }
            program = "none found (\(refusal.missing.joined(separator: "; "))): the server will refuse"
        case .success(let path): program = path
        }
        var firstCommit: LeadInit.Plan?
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        if asked.initialize {
            guard !client.approvalRule else {
                return Say.refused("--init isn't offered where the Mac asks its approval yet: make the first commit yourself, then start the lead")
            }
            switch LeadInit.plan(asked.folder, home: home, scratch: context.root.appendingPathComponent("scratch", isDirectory: true)) {
            case .failure(let why): return Say.refused(why.message)
            case .success(let plan): firstCommit = plan
            }
        }
        let action = UUID().uuidString.lowercased()
        var what = firstCommit.map { LeadInit.words($0) + "\n" } ?? ""
        what += asked.resume
            ? "This reopens the project lead for \(ConfigSeal.inert(asked.folder, limit: 400)) that the session host's restart ended, in its same conversation"
            : "This starts the project lead for \(ConfigSeal.inert(asked.folder, limit: 400)) (or shows the one running)"
        if asked.takeHead { what += ", taking its base branch as it is now" }
        if asked.replace { what += ", replacing a running lead that lost its role" }
        what += ".\nThe lead runs \(ConfigSeal.inert(program, limit: 400))."
        if let goal = asked.goal { what += "\nIts goal: \(ConfigSeal.inert(goal, limit: 400))" }
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        if let firstCommit {
            switch LeadInit.make(firstCommit, home: home, scratch: context.root.appendingPathComponent("scratch", isDirectory: true)) {
            case .failure(let why): return Say.refused("the first commit wasn't made, nothing was left: \(why.message)")
            case .success(let made):
                Say.out("made: a git repository with a first commit \(made.commit.prefix(8)) in \(ConfigSeal.inert(firstCommit.folder, limit: 400)) ("
                        + (made.files.count == 1 ? "1 file" : "\(made.files.count) files") + ")")
            }
        }
        let args = WireKinds.Lead.Args(folder: asked.folder, goal: asked.goal, takeHead: asked.takeHead, replace: asked.replace,
                                       resume: asked.resume ? true : nil, initialized: firstCommit != nil ? true : nil)
        switch client.change(WireKinds.Lead.self, args, action: action, typed: typed, timeout: 180) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, _):
            let happened = result.happened ?? "?"
            let session = ConfigSeal.inert(result.session ?? "", limit: 80)
            switch happened {
            case "started": Say.out("the lead started (session \(session)), running \(ConfigSeal.inert(result.program ?? "?", limit: 400))")
            case "shown": Say.out("the lead runs already (session \(session)): nothing was started")
            default: Say.out("the lead's start \(ConfigSeal.inert(happened, limit: 80))")
            }
            for note in result.notes ?? [] { Say.out("  " + ConfigSeal.inert(note, limit: .max)) }
            return 0
        }
    }
}
