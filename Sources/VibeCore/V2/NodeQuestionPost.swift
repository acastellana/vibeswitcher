import Foundation

/// The lead's question, as its tool server posts it to the node's server (the engine plan's EN-D10, the security
/// architecture document's S3): `ask_user`, `revise_question` and `withdraw_question` each write the board, as before,
/// and post the question as the board now stores it on `<root>/v2/server.sock` (a revision: what the lead gave, `Revision`),
/// so the server makes the user's card from what the lead's tool server said, never from `board.json` (which any session
/// can write). A post carries the
/// host's seal of a `.lead` message over the post's digest (`LeadVault.seal`, which the host makes only for the lead's
/// own callers); the server takes it only when the seal verifies, the poster isn't under branch code, and its session
/// is the one the vault binds to the project's lead role.
///
/// One hook line in each of the three tools (`LeadToolset`). It does nothing on the Mac (`enabled` false where
/// `Platform.CodeIdentity.isAvailable`), nor where no server socket exists; it waits for the server at most `limit` (1 s)
/// and never fails the tool: the board has the question either way.
public enum NodeQuestionPost {
    /// What the post says happened to the question: its request kind on the server's socket.
    public enum Op: String, CaseIterable, Sendable {
        case post = "question.post"
        case revise = "question.revise"
        case withdraw = "question.withdraw"
    }

    /// How long a post waits for the server: the tool's caller waits on it.
    public static let limit: TimeInterval = 1

    /// The node's server socket under `home` (`VibePaths.root`: a scratch node's lead has its root there).
    public static func socket(home: URL = VibePaths.root) -> String { home.appendingPathComponent("v2/server.sock").path }

    /// The name a lead's own lines carry for `root` (`LeadVault.Book.leadNames`): what the seal is made as.
    public static func leadName(root: String) -> String { "lead of " + LeadMail.project(of: root) }

    /// What `revise_question` was given, as its post carries it: the question's id, the new text and the new options
    /// (nil: unchanged) and the note, never the question as the board stores it after the revision. The board is
    /// `board.json`, which any session can write: a worker's options (an "Approve <its commit>"), text or revisions there
    /// would otherwise reach the card under the lead's seal at the lead's next revise (S3, T38). The server rewords the
    /// card's own question with these alone (`LeadEngine.questionRevised`).
    public struct Revision: Codable, Equatable, Sendable {
        public var id: String
        public var text: String?
        public var options: [String]?
        public var note: String

        public init(id: String, text: String?, options: [String]?, note: String) {
            self.id = id
            self.text = text
            self.options = options
            self.note = note
        }
    }

    /// The question as the post carries it and its digest covers: JSON with sorted keys.
    public static func encoded(_ question: LeadQuestion) -> Data { encodedSorted(question) }

    /// A revision as its post carries it and its digest covers: JSON with sorted keys.
    public static func encoded(_ revision: Revision) -> Data { encodedSorted(revision) }

    static func encodedSorted<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// The post's digest: SHA-256 of the kind, the root and the question's text exactly as the post carries it, so
    /// the server checks the very bytes it decodes.
    public static func digest(op: Op, root: String, question: Data) -> String {
        var data = Data("\(op.rawValue)\n\(root)\n".utf8)
        data.append(question)
        return BuildInfo.sha256(of: data)
    }

    /// The message whose `.lead` seal vouches for the post: no agent's (pid 0, as a board note), its text the digest.
    public static func sealed(digest: String, root: String, id: String, at: Double) -> SteerMessage {
        SteerMessage(id: id, text: "question post " + digest, from: .lead(leadName(root: root)), agentPid: 0, at: at)
    }

    /// Posts `question` (as the board stores it after `op`) for the lead of `root`: the seal asked of `vault` first, then
    /// one request on `socket` if it exists, waiting at most `limit` for the reply. Nothing on the Mac (`enabled`), with
    /// no socket, or when the seal is refused. Whether the server took it (for tests).
    /// A revision is posted with `revise` (what the lead gave), never as a question.
    @discardableResult
    public static func post(_ question: LeadQuestion, op: Op, root: String, vault: LeadVault = .standard,
                            socket: String = NodeQuestionPost.socket(), enabled: Bool = !Platform.CodeIdentity.isAvailable,
                            limit: TimeInterval = NodeQuestionPost.limit) -> Bool {
        guard op != .revise else { return false }
        return send(encoded(question), op: op, root: root, vault: vault, socket: socket, enabled: enabled, limit: limit)
    }

    /// Posts `revise_question`'s revision of question `id` as the lead gave it (`Revision`: the text and options it
    /// passed, nil when unchanged, and its note), as `post` does.
    @discardableResult
    public static func revise(_ id: String, text: String?, options: [String]?, note: String, root: String, vault: LeadVault = .standard,
                              socket: String = NodeQuestionPost.socket(), enabled: Bool = !Platform.CodeIdentity.isAvailable,
                              limit: TimeInterval = NodeQuestionPost.limit) -> Bool {
        send(encoded(Revision(id: id, text: text, options: options, note: note)), op: .revise, root: root, vault: vault, socket: socket,
             enabled: enabled, limit: limit)
    }

    /// The post of `text` (the question's or the revision's JSON) as `op`.
    static func send(_ text: Data, op: Op, root: String, vault: LeadVault, socket: String, enabled: Bool, limit: TimeInterval) -> Bool {
        guard enabled, FileManager.default.fileExists(atPath: socket) else { return false }
        let message = sealed(digest: digest(op: op, root: root, question: text), root: root, id: UUID().uuidString.lowercased(),
                             at: Date().timeIntervalSince1970)
        guard let seal = try? vault.seal(message) else { return false }
        // The question's JSON and the seal's time as text: a number read and written again could come back otherwise.
        let request: [String: Any] = [
            "v": 1, "id": "post-" + message.id, "kind": op.rawValue,
            "args": ["root": root, "question": String(decoding: text, as: UTF8.self),
                     "seal": ["id": message.id, "at": String(message.at), "name": leadName(root: root), "seal": seal] as [String: Any]] as [String: Any],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes]) else { return false }
        line.append(0x0A)
        return exchange(line, socket: socket, id: "post-" + message.id, limit: limit)
    }

    /// Connects, sends `line` and reads until the reply to `id` (true when it's `ok`), at most `limit` in all.
    static func exchange(_ line: Data, socket: String, id: String, limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        guard let fd = try? UnixSocket.connect(path: socket, patience: min(limit, 0.2)) else { return false }
        defer { Sys.close(fd) }
        let sent = line.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                guard Date() < deadline else { return false }
                let written = Platform.Sockets.send(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR || errno == EAGAIN { usleep(1_000); continue }
                return false
            }
            return true
        }
        guard sent else { return false }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let woke = poll(&watched, 1, Int32(max(1, left * 1_000)))
            if woke < 0, errno == EINTR { continue }
            guard woke > 0 else { continue }
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return false }
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let message = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: Data(message))) as? [String: Any] else { continue }
                if object["re"] as? String == id { return object["ok"] as? Bool == true }
                if object["kind"] as? String == "bye" { return false }
            }
        }
    }
}
