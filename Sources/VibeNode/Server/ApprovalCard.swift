import Foundation
import VibeCore

/// The card a Touch ID approval names (`ApprovalVoice.judge`'s `card`, the user's voice on the Mac): what the server
/// itself knows of the request, never what the command line said of it. A request on a card (`Requests.carded`) names
/// that card as the engine built it (its first lines: the question, the commit, the held names, the moved base) and,
/// for an answer, the words sent; any other state change names its own arguments, each key with its value, inert and
/// cut short (the dialog is small: the command line's screen showed the whole). Nil when there is nothing to name (a
/// card the server doesn't hold), and then the voice refuses without asking.
extension Requests {
    /// The longest value of one argument a card carries.
    static let approvalValueLimit = 80
    /// The arguments never named: the card's code and the bookkeeping, which say nothing of what is done.
    static let approvalUnnamed: Set<String> = ["code", "version", "card"]

    /// What `request` does, as the person at the Mac is asked to agree to it. On `queue`.
    func approvalCard(_ request: NodeWire.Request) -> String? {
        let args = request.args ?? [:]
        var parts: [String] = []
        if Self.carded.contains(request.kind) {
            guard let wanted = args["card"]?.string, let card = engine?.cards.resolve(wanted) else { return nil }
            let lines = CardText.lines(card.value).dropFirst().prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
            parts.append("card \(card.id.split(separator: ":").last.map { String($0.prefix(8)) } ?? card.id) in \(LeadMail.project(of: card.root))")
            parts += lines
        }
        for key in args.keys.sorted() where !Self.approvalUnnamed.contains(key) {
            guard let shown = Self.approvalValue(args[key]) else { continue }
            parts.append("\(key) \(shown)")
        }
        let text = parts.joined(separator: "; ")
        return text.isEmpty ? (NodeWire.changesState(request.kind) ? nil : request.kind) : text
    }

    /// One argument's value as a card names it: a string or number as it is, a list's items joined, an object's keys;
    /// nil for none. Inert and cut at `approvalValueLimit`.
    static func approvalValue(_ value: NodeWire.Value?) -> String? {
        guard let value else { return nil }
        let text: String
        switch value {
        case .null: return nil
        case .string(let string): text = string
        case .int(let number): text = String(number)
        case .bool(let flag): text = flag ? "yes" : "no"
        case .array(let items): text = items.compactMap { approvalValue($0) }.joined(separator: ", ")
        case .object(let fields): text = fields.keys.sorted().joined(separator: ", ")
        case .double(let number): text = String(number)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ConfigSeal.inert(text.replacingOccurrences(of: "\n", with: " "), limit: approvalValueLimit)
    }
}
