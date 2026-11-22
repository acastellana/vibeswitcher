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
enum LeadCommand {
    static let usage = "usage: vibeswitcher lead FOLDER [--goal TEXT | --resume] [--take-head] [--replace]"

    struct Asked: Equatable {
        var folder: String
        var goal: String?
        var takeHead = false
        var replace = false
        var resume = false
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
            default:
                guard folder == nil, !word.hasPrefix("--") else { return nil }
                folder = word
            }
            index += 1
        }
        guard let folder, !folder.isEmpty, !(asked.resume && asked.goal != nil) else { return nil }
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
        let action = UUID().uuidString.lowercased()
        var what = asked.resume
            ? "This reopens the project lead for \(ConfigSeal.inert(asked.folder, limit: 400)) that the session host's restart ended, in its same conversation"
            : "This starts the project lead for \(ConfigSeal.inert(asked.folder, limit: 400)) (or shows the one running)"
        if asked.takeHead { what += ", taking its base branch as it is now" }
        if asked.replace { what += ", replacing a running lead that lost its role" }
        what += ".\nThe lead runs \(ConfigSeal.inert(program, limit: 400))."
        if let goal = asked.goal { what += "\nIts goal: \(ConfigSeal.inert(goal, limit: 400))" }
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: what)
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
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
