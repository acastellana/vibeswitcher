import Foundation
import VibeCore

/// The node's ids (the engine plan's EN-D4, the design's rule 1): each carries the node it names something on, `local`
/// until nodes have names of their own, and none holds a path.
public enum NodeIds {
    /// This node's name in every id.
    public static let node = LocalSessions.node

    /// A project: `local:project:` and 9 bytes of SHA-256 of `lead|` and its standardized root, base64url (the phone's
    /// lead id, `PhoneLeads.id(root:)`, copied): short, stable for every spelling of one folder, and no path.
    public static func project(root: String) -> String {
        "\(node):project:" + Base64URL.encode(Data(SHA256.hash(data: Data(("lead|" + (root as NSString).standardizingPath).utf8))).prefix(9))
    }

    /// A session of the session host: `local:` and its host id, lower case.
    public static func session(host id: UUID) -> String { "\(node):\(id.uuidString.lowercased())" }

    /// A session the host doesn't run: `local:` and its terminal's name (stage 1's `LocalSession.id`).
    public static func session(terminal: String) -> String { "\(node):\(terminal)" }

    /// A new card: `local:card:` and a new UUID, lower case.
    public static func card() -> String { "\(node):card:\(UUID().uuidString.lowercased())" }

    /// The four letters a request on `card` is confirmed with (EN-D5): typed by the user, checked by the server.
    public static func code(card: String) -> String { code(of: "card|" + card) }

    /// The four letters a request with no card is confirmed with, from its action id (EN-D5): checked by the command
    /// line alone, a guard rail against a request run without the user's hands.
    public static func code(action: String) -> String { code(of: "action|" + action) }

    /// The letters codes are made of: capitals with none that reads as a digit or another letter (no I, L, O).
    static let codeLetters = Array("ABCDEFGHJKMNPQRSTUVWXYZ")

    /// Four letters from the first bytes of SHA-256 of `text`.
    private static func code(of text: String) -> String {
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        var value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        var letters: [Character] = []
        for _ in 0..<4 {
            letters.append(codeLetters[Int(value % UInt32(codeLetters.count))])
            value /= UInt32(codeLetters.count)
        }
        return String(letters)
    }
}
