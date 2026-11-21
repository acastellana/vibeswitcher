import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher brief [FOLDER] [--json]` (the parity table's Brief me row; the app's `Briefing/`): what happened lately
/// and what is asked of you, across the projects this node leads, or the one holding FOLDER. Written by the summaries'
/// model when AI summaries are on, else the written briefing. A read of the user's own (no code): a session's process
/// is refused.
enum BriefCommand {
    static let usage = "usage: vibeswitcher brief [FOLDER] [--json]"

    static func run(_ arguments: [String]) -> Int32 {
        var folder: String?
        var json = false
        for word in arguments {
            switch word {
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
        switch client.request("brief", args: folder.map { ["folder": .string($0)] } ?? [:]) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(result)).dropLast(), as: UTF8.self))
                return 0
            }
            BriefCommandLines.lines(result).forEach(Say.out)
            return 0
        }
    }
}
