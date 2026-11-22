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
        switch client.read(WireKinds.Brief.self, .init(folder: folder)) {
        case .failure(let failure): return Say.failed(failure)
        case .refused(let reply): return Say.replyError(reply)
        case .success(let result, let raw):
            if json {
                Say.out(String(decoding: NodeWire.printable(NodeWire.line(raw)).dropLast(), as: UTF8.self))
                return 0
            }
            BriefCommandLines.lines(result).forEach(Say.out)
            return 0
        }
    }
}
