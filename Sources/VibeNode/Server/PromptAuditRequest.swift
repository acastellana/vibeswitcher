import Foundation
import VibeCore

extension Requests {
    /// `prompt-audit` with `folder` (absolute: the project whose repository holds it) and `do` (`snooze`, `off` or `on`)
    /// (the stability lane, 2026-11-20; the app's prompt-audit card's Remind me in a week and Not for this project,
    /// `PromptAuditWatch.swift`): the project's reminder snoozed for a week, turned off, or back on. The user's voice,
    /// recorded. The reply names the project, its root, what was done and, when snoozed, until when.
    func promptAudit(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no leads"))) }
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "prompt-audit needs folder, an absolute path")))
        }
        let word = request.args?["do"]?.string ?? ""
        guard let change = LeadEngine.PromptAuditChange(rawValue: word) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "prompt-audit's do is snooze, off or on, not \(ConfigSeal.inert(word, limit: 20))")))
        }
        let (find, queue, note) = (repositoryOf, self.queue, self.note)
        engine.work.async {
            let root = (find(folder) as NSString).standardizingPath
            queue.async {
                engine.changePromptAudit(root: root, change) { project in
                    note("prompt-audit: \(change.rawValue) for \(LeadMail.project(of: root))")
                    reply(.init(re: request.id, typed: WireKinds.PromptAudit.Result(
                        project: LeadMail.project(of: root), root: root, do: change.rawValue,
                        until: project.snoozedUntil.map { NodeWire.dateText(Date(timeIntervalSince1970: $0)) })))
                }
            }
        }
    }
}
