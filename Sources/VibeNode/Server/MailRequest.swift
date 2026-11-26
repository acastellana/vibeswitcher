import Foundation
import VibeCore

/// "Between leads" (the parity table's row; the app's Team tab, `LeadMailViews.swift`): the messages projects' leads
/// sent each other with `tell_lead`, refused ones too, as each project's private record keeps them (`LeadMail`,
/// `.vibeswitcher/lead-mail.jsonl`). `mail [FOLDER] [all]` is a read, of a private record: the user's voice (no session's
/// process), no typed code, or since 2026-11-21 a page's token that reads (`webRead`, the page's Between leads view);
/// nothing changes.
extension Requests {
    /// A page's read of a private record (`NodeWire.Voice.webRead`), its token's `read` right judged by the screen and
    /// `NodeLive`: only `mail`, `recent` and `brief`, never anything that changes state. On `queue`.
    func webRead(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        switch request.kind {
        case "mail": mail(request, reply: reply)
        case "recent": recent(request, reply: reply)
        case "brief": brief(request, reply: reply)
        case "logs": logs(request, reply: reply)
        default: reply(.init(re: request.id, error: .init(.voice, "\(ConfigSeal.inert(request.kind, limit: 80)) isn't a page's read")))
        }
    }

    /// How many of a project's messages `mail` gives without `all`: the newest.
    static let mailShown = 20

    /// `mail` with `folder` (the project whose repository holds it) or none (every project with a lead on this node),
    /// and `all`: each project's root, name, how many messages its record holds and the newest `mailShown` of them
    /// (all of them with `all`), newest first, as `mailValue` gives each. The records are read on the engine's work
    /// queue.
    func mail(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server keeps no leads"))) }
        let args: WireKinds.Mail.Args
        switch request.typedArgs(WireKinds.Mail.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let typed): args = typed
        }
        let folder = args.folder
        if let folder, !folder.hasPrefix("/") { return reply(.init(re: request.id, error: .init(.badArgs, "folder is an absolute path"))) }
        let all = args.all == true
        let roots = Set(engine.leads.leads.values.map(\.root)).sorted()
        let (find, queue) = (repositoryOf, self.queue)
        engine.work.async {
            let chosen = folder.map { [find($0)] } ?? roots
            let projects = chosen.map { root -> WireKinds.Mail.Project in
                let records = LeadMail.load(root: root)
                let project = LeadMail.project(of: root)
                let shown = all ? records : Array(records.suffix(Self.mailShown))
                return .init(root: root, project: project, total: records.count, messages: shown.reversed().map { Self.mailMessage($0, project: project) })
            }
            queue.async { reply(.init(re: request.id, typed: WireKinds.Mail.Result(projects: projects))) }
        }
    }

    /// One message as `mail` gives it: when, from and to which project, whether it came to `project`'s lead
    /// (`received`), its kind (null: refused for its kind), its text (masked where it's kept), what became of it and
    /// what `tell_lead` answered. The text and the detail are a lead's words: shown inert.
    static func mailValue(_ record: LeadMail.Record, project: String) -> NodeWire.Value { NodeWire.Value(wire: mailMessage(record, project: project)) }

    static func mailMessage(_ record: LeadMail.Record, project: String) -> WireKinds.Mail.Message {
        let received = record.to.caseInsensitiveCompare(project) == .orderedSame && record.from.caseInsensitiveCompare(project) != .orderedSame
        return .init(at: NodeWire.dateText(Date(timeIntervalSince1970: record.at)), from: record.from, to: record.to, received: received,
                     kind: record.kind?.rawValue, text: record.text, outcome: record.outcome.rawValue, sent: record.outcome.sent, detail: record.detail)
    }
}

/// `mail`'s projects as `vibeswitcher mail` prints them: a heading a project, then each message newest first, a line
/// saying when, which way, its kind and what became of it, then its text indented (its first `textLimit` characters,
/// whole with `whole`), and for one not sent, why. Everything a lead wrote goes through `ConfigSeal.inert`.
public enum MailText {
    static let textLimit = 300

    public static func lines(_ project: NodeWire.Value, whole: Bool = false) -> [String] {
        (try? project.wire(WireKinds.Mail.Project.self)).map { lines($0, whole: whole) } ?? []
    }

    public static func lines(_ project: WireKinds.Mail.Project, whole: Bool = false) -> [String] {
        let name = ConfigSeal.inert(project.project ?? "?", limit: 80)
        let total = project.total ?? 0
        let messages = project.messages ?? []
        var lines = ["Between leads · \(name) (\(total) message\(total == 1 ? "" : "s")"
                     + (messages.count < total ? ", the newest \(messages.count) shown: --all for every one" : "") + ")"]
        if messages.isEmpty { lines.append("  no message sent or received with tell_lead") }
        for message in messages {
            let at = message.at.flatMap(NodeWire.date).map(shortDate) ?? "?"
            let way = message.received == true ? "from the lead of \(ConfigSeal.inert(message.from ?? "?", limit: 80))"
                : "to the lead of \(ConfigSeal.inert(message.to ?? "?", limit: 80))"
            let kind = message.kind.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No kind"
            lines.append("  \(at)  \(way) · \(kind) · \(outcome(message.outcome))")
            let text = ConfigSeal.inert(message.text ?? "", limit: whole ? .max : textLimit)
            lines += text.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }
            if message.sent == false {
                lines.append("      why: " + ConfigSeal.inert(message.detail ?? "", limit: whole ? .max : textLimit))
            }
        }
        return lines
    }

    /// What became of a message, in a few words (the app's `LeadMailFeed.outcomeLabel`).
    static func outcome(_ raw: String?) -> String {
        switch raw.flatMap(LeadMail.Outcome.init(rawValue:)) {
        case .delivered?: return "delivered"
        case .waiting?: return "waiting in its inbox"
        case .refused?: return "refused"
        case .noLead?: return "not sent: no lead running"
        case .off?: return "refused: lead mail is off"
        case .failed?: return "not sent: delivery failed"
        case nil: return ConfigSeal.inert(raw ?? "?", limit: 40)
        }
    }

    static func shortDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }
}
