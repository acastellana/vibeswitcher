import Foundation
import VibeCore
import VibeNode

/// `vibeswitcher push FOLDER` and `vibeswitcher decline-push FOLDER` (the parity table's push row, 2026-11-20): the
/// user settles the push the lead of FOLDER's project asked for (push_remote), as the app's Push and Decline buttons
/// do. The open request is read from `status` and shown (`PushText`) before the command line's own typed code (EN-D5,
/// as `tell`'s: no card); the server records the request in the host's vault, then settles exactly the request shown
/// (`push`/`push.decline` with its id): a newer one the lead asked for meanwhile is left open. Push runs the push in
/// the server (`LeadPush.settle`), never in a session; the lead is told what came of it. The accepted request is
/// written to the journal (ids only).
enum PushCommand {
    static func usage(_ approve: Bool) -> String { "usage: vibeswitcher \(approve ? "push" : "decline-push") FOLDER" }

    static func run(_ arguments: [String], approve: Bool) -> Int32 {
        guard arguments.count == 1, !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else { return Say.usage(usage(approve)) }
        let folder = URL(fileURLWithPath: CardCommand.absolute(arguments[0])).resolvingSymlinksInPath().path
        let context = NodeContext.current()
        context.sayScratch()
        let client: NodeClient
        switch NodeClient.connect(context) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let connected): client = connected
        }
        let leads: [NodeWire.Value]
        switch client.request("status") {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let listed = reply.result?["leads"]?.array else { return Say.replyError(reply) }
            leads = listed
        }
        guard let lead = PushText.lead(for: folder, in: leads), let root = lead["root"]?.string else {
            return Say.refused("no lead on this node holds \(ConfigSeal.inert(folder, limit: 400))")
        }
        guard let push = lead["push"], let id = push["id"]?.string else {
            return Say.refused("the lead of \(ConfigSeal.inert(root, limit: 400)) has no push request open: nothing to "
                               + (approve ? "push" : "decline"))
        }
        let action = UUID().uuidString.lowercased()
        let said = TypedWord.said(approval: client.approvalRule, action: action, what: PushText.what(push, root: root, approve: approve))
        guard case .success(let typed) = said else { return Say.refused(said.refusal) }
        let kind = approve ? "push" : "push.decline"
        switch client.change(kind, args: ["folder": .string(root), "request": .string(id)], action: action, typed: typed, timeout: LeadPush.timeout + 60) {
        case .failure(let failure): return Say.failed(failure)
        case .success(let reply):
            guard reply.ok, let result = reply.result else { return Say.replyError(reply) }
            (result["said"]?.string ?? "settled").split(separator: "\n", omittingEmptySubsequences: false)
                .forEach { Say.out(ConfigSeal.inert(PushText.scrub(String($0)), limit: 2000)) }
            return result["ok"]?.bool == true ? 0 : 1
        }
    }
}
