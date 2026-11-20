import Foundation
import VibeCore

/// What `vibeswitcher push` and `vibeswitcher decline-push` show before their typed code (the parity table's push row):
/// the lead whose project holds the folder, from `status`'s leads, and its open push request (`LeadStore.Lead.push`) in
/// words: what goes where, its commits. Every field a session could have written (the subjects, the branch, the URL)
/// goes through `ConfigSeal.inert`, so no escape sequence or bidirectional character reaches the terminal the code is
/// asked on.
public enum PushText {
    /// The lead among `leads` (`status`'s) whose root is `folder` or holds it, the deepest one.
    public static func lead(for folder: String, in leads: [NodeWire.Value]) -> NodeWire.Value? {
        leads.filter { lead in
            guard let root = lead["root"]?.string else { return false }
            return folder == root || folder.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }.max { ($0["root"]?.string?.count ?? 0) < ($1["root"]?.string?.count ?? 0) }
    }

    static func inert(_ text: String?, limit: Int = 200) -> String { ConfigSeal.inert(text ?? "", limit: limit) }

    /// The lines shown above the code: `push` true for Push, false for Decline.
    public static func what(_ push: NodeWire.Value, root: String, approve: Bool) -> String {
        let ahead = push["ahead"]?.int ?? 0
        let commits = "\(ahead) commit" + (ahead == 1 ? "" : "s")
        let request = "\(inert(push["branch"]?.string)) at \(inert(push["short"]?.string, limit: 12)) (\(commits)) to "
            + "\(inert(push["target"]?.string)), \(inert(push["url"]?.string, limit: 400))"
        let asked = "as the lead of \(inert(root, limit: 400)) asked (request \(inert(push["id"]?.string, limit: 64)))"
        var lines = [approve
            ? "This pushes \(request), \(asked): that commit itself, as a fast-forward only, nothing forced."
            : "This declines the push of \(request), \(asked): nothing is pushed, and the lead is told."]
        let subjects = push["subjects"]?.array?.compactMap(\.string) ?? []
        if !subjects.isEmpty {
            lines.append("The commits, newest first" + (ahead > subjects.count ? " (the first \(subjects.count))" : "") + ":")
            lines += subjects.map { "  \(inert($0))" }
        }
        return lines.joined(separator: "\n")
    }
}
