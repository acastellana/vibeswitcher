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

    /// A remote's URL as it may be shown (on the wire, in `status`, on the page, in the log, to the lead, on the terminal):
    /// a URL with a scheme loses its userinfo (`https://user:token@host/…`: a token is often the user's name alone), and
    /// an http(s) URL its query and fragment too; an scp-like `user@host:path` keeps its user (a login name, no secret)
    /// unless what comes before its `@` holds a `:`. The full URL stays node-side, where the push compares it with the
    /// vault's pin.
    public static func displayURL(_ url: String) -> String {
        if let scheme = url.range(of: "://") {
            let head = url[..<scheme.upperBound], rest = url[scheme.upperBound...]
            let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
            var authority = rest[..<authorityEnd]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            var tail = rest[authorityEnd...]
            if head.lowercased().hasPrefix("http"), let cut = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) { tail = tail[..<cut] }
            return String(head) + authority + tail
        }
        if let at = url.firstIndex(of: "@"), url[..<at].contains(":") { return "…" + url[at...] }
        return url
    }

    /// `text` with no URL's credentials in it: every URL's userinfo taken out (`scheme://anything@` is `scheme://`), and in
    /// an http(s) URL the value of a token-ish query parameter (`token`, `access_token`, `private_token`, `password`,
    /// `secret`, `api_key`, `apikey`, `sig`, `signature`, `auth`) written `…`. Nothing else in the text changes. Git's own
    /// words, the lead's message, the outcome, and every chat item the node serves (`ChatValue`) go through it.
    public static func scrub(_ text: String) -> String {
        guard text.contains("://") else { return text }
        let bare = text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/'"]+@"#, with: "$1", options: .regularExpression)
        guard bare.range(of: "[?&]", options: .regularExpression) != nil else { return bare }
        let found = urls.matches(in: bare, range: NSRange(bare.startIndex..., in: bare))
        guard !found.isEmpty else { return bare }
        var scrubbed = bare
        for match in found.reversed() {
            guard let range = Range(match.range, in: bare) else { continue }
            let url = String(bare[range])
            let cleaned = queryTokens.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "$1…")
            if cleaned != url, let at = Range(match.range, in: scrubbed) { scrubbed.replaceSubrange(at, with: cleaned) }
        }
        return scrubbed
    }

    /// An http(s) URL in text, to its first space, quote or angle bracket.
    private static let urls = try! NSRegularExpression(pattern: #"[Hh][Tt][Tt][Pp][Ss]?://[^\s'"<>]+"#)
    /// A token-ish query parameter's name, and its value up to the next parameter or the fragment.
    private static let queryTokens = try! NSRegularExpression(
        pattern: #"([?&](?:access_token|private_token|token|password|secret|api_key|apikey|sig|signature|auth)=)[^&#]+"#,
        options: [.caseInsensitive])

    /// The lines shown above the code: `push` true for Push, false for Decline.
    public static func what(_ push: NodeWire.Value, root: String, approve: Bool) -> String {
        let ahead = push["ahead"]?.int ?? 0
        let commits = "\(ahead) commit" + (ahead == 1 ? "" : "s")
        let request = "\(inert(push["branch"]?.string)) at \(inert(push["short"]?.string, limit: 12)) (\(commits)) to "
            + "\(inert(push["target"]?.string)), \(inert(push["url"]?.string.map(displayURL), limit: 400))"
        let asked = "as the lead of \(inert(root, limit: 400)) asked (request \(inert(push["id"]?.string, limit: 64)))"
        var lines = [approve
            ? "This pushes \(request), \(asked): that commit itself, as a fast-forward only, nothing forced."
            : "This declines the push of \(request), \(asked): nothing is pushed, and the lead is told."]
        let subjects = push["subjects"]?.array?.compactMap(\.string) ?? []
        if !subjects.isEmpty {
            lines.append("The commits, newest first" + (ahead > subjects.count ? " (the first \(subjects.count))" : "") + ":")
            lines += subjects.map { "  \(inert(scrub($0)))" }
        }
        return lines.joined(separator: "\n")
    }
}
