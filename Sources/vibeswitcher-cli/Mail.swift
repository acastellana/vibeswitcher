import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher mail [FOLDER] [--all] [--json]` (the parity table's "Between leads" row): the messages the lead of the
/// project holding FOLDER and other projects' leads sent each other with tell_lead, refused ones too, newest first; every
/// project with a lead on this node without FOLDER. `--all`: every message, whole. A read of the projects' private
/// record: the user's own terminal's (as `config held`), no code.
enum MailCommand {
    static let usage = "usage: vibeswitcher mail [FOLDER] [--all] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var all = false, json = false
        for word in arguments {
            switch word {
            case "--all": all = true
            case "--json": json = true
            default:
                guard folder == nil, !word.isEmpty, !word.hasPrefix("--") else { return Say.usage(usage) }
                folder = CardCommand.absolute(word)
            }
        }
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        var args: [String: NodeWire.Value] = [:]
        if let folder { args["folder"] = .string(folder) }
        if all { args["all"] = .bool(true) }
        switch client.request("mail", args: args) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let projects = reply.result?["projects"]?.array else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(reply.result ?? .null)).dropLast(), as: UTF8.self))
                return 0
            }
            if projects.isEmpty { Say.out("no lead on this node: `vibeswitcher mail FOLDER` shows a project's messages") }
            for (index, project) in projects.enumerated() {
                if index > 0 { Say.out("") }
                MailText.lines(project, whole: all).forEach(Say.out)
            }
            return 0
        }
    }
}
