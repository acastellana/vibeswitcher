import Foundation
import VibeCore

/// What `vibeswitcher answer CARD TEXT` shows before the code (2026-11-25, the text walk and its review): the lead's
/// question whole, inert, when it is `shownLines` lines or fewer, with its options and proposal one line each, and none
/// of the card's header, ids or times; a longer one its first `shownLines` lines and how many more, with the command that
/// shows all of it (`long`: all of it). Never a silent cut: the code is typed for what was read.
public enum AnswerPrompt {
    public static let shownLines = 8

    public static func lines(_ card: NodeWire.Value, long: Bool = false) -> [String] {
        let id = ConfigSeal.inert(card["id"]?.string ?? "", limit: 80)
        guard let text = card["question"]?["text"]?.string else { return ["Card \(id)"] }
        let all = text.components(separatedBy: .newlines).map { ConfigSeal.inert($0, limit: 400) }
        var lines = ["The lead asks (its words):"]
        if long || all.count <= shownLines {
            lines += all.map { "  " + $0 }
        } else {
            lines += all.prefix(shownLines).map { "  " + $0 }
            let more = all.count - shownLines
            lines.append("  … \(more) more line\(more == 1 ? "" : "s"): `vibeswitcher answer \(id) --long` shows all of it before you answer")
        }
        let options = (card["question"]?["options"]?.array ?? []).compactMap(\.string)
        if !options.isEmpty { lines.append("options (the lead's): " + options.map { ConfigSeal.inert($0, limit: 200) }.joined(separator: " | ")) }
        if let proposal = card["question"]?["proposal"]?.string, !proposal.isEmpty {
            lines.append("the lead proposes: " + ConfigSeal.inert(proposal.replacingOccurrences(of: "\n", with: " "), limit: 400))
        }
        return lines
    }
}
