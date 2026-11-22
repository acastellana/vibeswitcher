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
/// `ProjectFolderStart`'s question): a folder in no repository gets `git init` and a first commit of its files, an empty
/// repository's top folder a first commit (`FolderRepository`, shared: what looks like a secret left out, a nested
/// repository committed as a reference), shown before the code and made after it, by this process as `git init` in a
/// terminal is; nothing left on a failure. A folder with commits needs nothing; one inside a repository with no
/// commits, the home folder or `/` is refused.
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
        case .failure(let refusal): program = "none found (\(refusal.missing.joined(separator: "; "))): the server will refuse"
        case .success(let path): program = path
        }
        var firstCommit: FolderRepository.Plan?
        if asked.initialize {
            switch FirstCommit.plan(asked.folder, scratch: context.root.appendingPathComponent("scratch", isDirectory: true)) {
            case .failure(let why): return Say.refused(why.message)
            case .success(let plan): firstCommit = plan
            }
        }
        let action = UUID().uuidString.lowercased()
        var what = firstCommit.map { FirstCommit.words($0) + "\n" } ?? ""
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
            if let problem = FolderRepository.make(firstCommit) { return Say.refused("the first commit wasn't made, nothing was left: \(problem.message)") }
            Say.out("made: " + (firstCommit.inRepository ? "a first commit" : "a git repository with a first commit")
                    + " in \(ConfigSeal.inert(firstCommit.folder, limit: 400)) (\(FirstCommit.count(firstCommit.files.count)))")
        }
        var args: [String: NodeWire.Value] = ["folder": .string(asked.folder), "takeHead": .bool(asked.takeHead), "replace": .bool(asked.replace)]
        if asked.resume { args["resume"] = .bool(true) }
        if let goal = asked.goal { args["goal"] = .string(goal) }
        switch client.change("lead", args: args, action: action, typed: typed, timeout: 180) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            let happened = result["happened"]?.string ?? "?"
            let session = ConfigSeal.inert(result["session"]?.string ?? "", limit: 80)
            switch happened {
            case "started": Say.out("the lead started (session \(session)), running \(ConfigSeal.inert(result["program"]?.string ?? "?", limit: 400))")
            case "shown": Say.out("the lead runs already (session \(session)): nothing was started")
            default: Say.out("the lead's start \(ConfigSeal.inert(happened, limit: 80))")
            }
            for note in result["notes"]?.array ?? [] { Say.out("  " + ConfigSeal.inert(note.string ?? "", limit: .max)) }
            return 0
        }
    }
}

/// `vibeswitcher lead FOLDER --init`: what the folder needs before a lead can start in it (the app's offer, read here
/// as `LeadController` reads it), and the words for it.
enum FirstCommit {
    struct Refusal: Error, Equatable { var message: String }

    /// nil: the folder has commits, nothing to make. A folder in no repository: its git init and first commit; a
    /// repository's top folder with no commits at all (`FolderRepository.isEmptyRepository`): its first commit.
    static func plan(_ folder: String, home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                     scratch: URL) -> Result<FolderRepository.Plan?, Refusal> {
        let shown = ConfigSeal.inert(folder, limit: 400)
        guard ProjectCreation.existing(folder) == .folder else { return .failure(Refusal(message: "\(shown) isn't a folder")) }
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        let chosen = resolved(folder)
        guard chosen != "/", chosen != resolved(home) else {
            return .failure(Refusal(message: "--init makes no repository of \(shown): a project's lead goes in a folder of its own"))
        }
        let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
        if top.ok, !top.output.isEmpty {
            let root = resolved(top.output)
            if Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok { return .success(nil) }
            // A stray git init in a parent (the home folder's), or an orphan branch or a fetch: no commit made there.
            guard root == chosen, FolderRepository.isEmptyRepository(root) else {
                return .failure(Refusal(message: "\(shown) is in the repository \(ConfigSeal.inert(root, limit: 400)), which has no commits"
                                        + (root == chosen ? " on this branch but has some elsewhere" : "") + ": --init makes a first commit only in a repository's own folder with none at all"))
            }
        }
        switch FolderRepository.plan(for: chosen, scratch: scratch) {
        case .failure(let problem): return .failure(Refusal(message: problem.message))
        case .success(let plan): return .success(plan)
        }
    }

    static func count(_ files: Int) -> String { files == 1 ? "1 file" : "\(files) files" }

    /// What the code is asked for, as the app's question says it (`ProjectFolderStart`).
    static func words(_ plan: FolderRepository.Plan) -> String {
        let folder = ConfigSeal.inert(plan.folder, limit: 400)
        var text = (plan.inRepository ? "First, in \(folder) (a repository with no commits yet), a first commit" : "First, git init in \(folder), and a first commit")
            + " of its \(count(plan.files.count))" + (plan.addsGitignore ? " (with a .gitignore for secrets and build output)" : "")
            + ". It stays on this node: nothing is pushed."
        func some(_ list: [String]) -> String {
            list.prefix(8).map { ConfigSeal.inert($0, limit: 200) }.joined(separator: ", ") + (list.count > 8 ? " and \(list.count - 8) more" : "")
        }
        if !plan.leftOut.isEmpty { text += "\nLeft out, as they look like secrets: \(some(plan.leftOut))." }
        if !plan.nested.isEmpty { text += "\nA repository of its own, committed as a reference (its files aren't included): \(some(plan.nested))." }
        return text
    }
}
