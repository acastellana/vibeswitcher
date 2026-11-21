import Foundation
import VibeCore

/// The session a command line's SESSION names among those `status` lists (`sessions`, each its live value): its node id
/// (`local:<uuid>`, `local:pts/9`) or that id without `local:`; the terminal name `status` prints for it (`ttypts4`,
/// also given as `pts/4` or `/dev/pts/4`); or a prefix of 4 or more of its host id that only one session has (as the
/// page and `status` show it, 8). An exact id wins over a terminal name, and a terminal name over a prefix. A name two
/// sessions answer to is refused, naming each with its id and terminal, never guessed.
public enum SessionLookup {
    public struct Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        public let description: String
        /// More than one session answers to it (false: none does).
        public let ambiguous: Bool
        init(_ description: String, ambiguous: Bool = false) {
            self.description = description
            self.ambiguous = ambiguous
        }
    }

    /// `idKey`: the field holding a session's node id (`id` in `status`'s `sessions`; `session` in its `ended` and
    /// `reopen`, which hold no terminal); `noun`: what a refusal calls them; `hostedOnly`: a prefix names only a session
    /// the node's host runs (`sessions`' `hosted`).
    public static func match(_ wanted: String, in sessions: [NodeWire.Value], idKey: String = "id", hostedOnly: Bool = true,
                             noun: String = "session", listed: String = "`vibeswitcher status` lists them") -> Result<NodeWire.Value, Refusal> {
        let given = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        let prefix = NodeIds.node + ":"
        let bare = given.hasPrefix(prefix) ? String(given.dropFirst(prefix.count)) : given
        let id = { (session: NodeWire.Value) in (session[idKey]?.string ?? "").lowercased() }
        let exact = sessions.filter { id($0) == prefix + bare }
        let terminal = bare.isEmpty ? "" : Platform.Terminals.name(devicePath: bare)
        let byTerminal = terminal.isEmpty ? [] : sessions.filter {
            guard let tty = $0["terminal"]?.string, !tty.isEmpty else { return false }
            return Platform.Terminals.name(devicePath: tty.lowercased()) == terminal
        }
        let byPrefix = bare.count >= 4 && bare.allSatisfy({ $0.isHexDigit || $0 == "-" })
            ? sessions.filter { (!hostedOnly || $0["hosted"]?.bool == true) && id($0).dropFirst(prefix.count).hasPrefix(bare) } : []
        let matches = !exact.isEmpty ? exact : !byTerminal.isEmpty ? byTerminal : byPrefix
        let shown = ConfigSeal.inert(wanted, limit: 80)
        guard let session = matches.first else { return .failure(Refusal("no \(noun) \(shown) on this node (\(listed))")) }
        guard matches.count == 1 else {
            let named = matches.map { session -> String in
                let terminal = session["terminal"]?.string.map { " on " + ConfigSeal.inert($0, limit: 20) } ?? ""
                return ConfigSeal.inert(session[idKey]?.string ?? "?", limit: 80) + terminal
            }
            return .failure(Refusal("\(shown) names \(matches.count) \(noun)s: \(named.joined(separator: ", ")); give one's id", ambiguous: true))
        }
        return .success(session)
    }
}
