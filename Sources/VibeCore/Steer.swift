import Darwin
import Foundation

/// A message for an agent that's working, delivered at its next tool call without stopping it.
public struct SteerMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Sender: Codable, Equatable, Sendable {
        case user
        /// Another agent (the project lead), by name: never presented as the user.
        case lead(String)
    }

    public var id: String
    public var text: String
    public var from: Sender
    /// The agent process it's for: a later agent on the same terminal doesn't get it.
    public var agentPid: Int32
    public var at: Double

    public init(id: String = UUID().uuidString, text: String, from: Sender, agentPid: Int32, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.text = text
        self.from = from
        self.agentPid = agentPid
        self.at = at
    }
}

/// Per-terminal inbox files in VibeSwitcher's private folder: the app posts, the agent's hook takes.
public enum SteerInbox {
    public enum Failure: Error { case badTerminal }

    static func folder(_ root: URL) -> URL { root.appendingPathComponent("steer", isDirectory: true) }

    static func file(_ tty: String, _ suffix: String, root: URL) throws -> URL {
        // Only plain terminal names ("ttys012"): the name becomes part of a path.
        guard tty.hasPrefix("tty"), tty.count <= 16, tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Failure.badTerminal }
        return folder(root).appendingPathComponent("\(tty).\(suffix)")
    }

    public static func post(_ message: SteerMessage, tty: String, root: URL = VibePaths.root) throws {
        let url = try file(tty, "jsonl", root: root)
        try FileManager.default.createDirectory(at: folder(root), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try locked(url) { handle in
            var line = try JSONEncoder().encode(message)
            line.append(0x0A)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    /// Takes the messages for `agentPid` (dropping any left for an earlier agent) and records them as delivered.
    public static func take(tty: String, agentPid: Int32, root: URL = VibePaths.root) -> [SteerMessage] {
        guard let url = try? file(tty, "jsonl", root: root), FileManager.default.fileExists(atPath: url.path) else { return [] }
        var taken: [SteerMessage] = []
        try? locked(url) { handle in
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return }
            taken = decode(data).filter { $0.agentPid == agentPid }
            try handle.truncate(atOffset: 0)
        }
        if !taken.isEmpty, let log = try? file(tty, "delivered", root: root) {
            try? locked(log) { handle in
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(taken.map { $0.id + "\n" }.joined().utf8))
            }
        }
        return taken
    }

    /// Messages waiting for their agent.
    public static func pending(tty: String, root: URL = VibePaths.root) -> [SteerMessage] {
        guard let url = try? file(tty, "jsonl", root: root), let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// Ids of messages agents have taken.
    public static func delivered(tty: String, root: URL = VibePaths.root) -> Set<String> {
        guard let url = try? file(tty, "delivered", root: root), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    private static func decode(_ data: Data) -> [SteerMessage] {
        data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(SteerMessage.self, from: Data($0)) }
    }

    /// Runs `body` on the file (created private if missing) under an exclusive lock.
    private static func locked(_ url: URL, _ body: (FileHandle) throws -> Void) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        try body(handle)
    }
}

/// What the hook prints to hand steered messages to Claude Code.
public enum SteerReply {
    /// Claude Code keeps at most 10,000 characters of added context inline.
    public static let contextLimit = 9_000

    /// The events that deliver messages: after a tool, with a prompt, and at the end of a turn (which then goes on).
    public static func takesMessages(event: String) -> Bool {
        ["PostToolUse", "UserPromptSubmit", "Stop"].contains(event)
    }

    public static func output(event: String, messages: [SteerMessage]) -> Data? {
        guard takesMessages(event: event), !messages.isEmpty else { return nil }
        let text = context(messages)
        let object: [String: Any]
        if event == "Stop" {
            object = ["decision": "block", "reason": text]
        } else {
            object = ["hookSpecificOutput": ["hookEventName": event, "additionalContext": text]]
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static let userMarker = "The user sent this while you were working (through VibeSwitcher)."
    static let leadMarker = "Your project lead ("

    /// The messages inside a delivered context (as the transcript records it): text, and whether the lead sent it.
    public static func messages(inContext context: String) -> [(text: String, fromLead: Bool)] {
        context.components(separatedBy: "\n\n---\n\n").compactMap { part in
            let fromLead = part.hasPrefix(leadMarker)
            guard part.hasPrefix(userMarker) || fromLead, let split = part.range(of: "\n\n") else { return nil }
            return (String(part[split.upperBound...]), fromLead)
        }
    }

    static func context(_ messages: [SteerMessage]) -> String {
        let parts = messages.map { message -> String in
            switch message.from {
            case .user:
                return userMarker + " Take it into account now; "
                    + "keep going with your work unless it asks you to stop or change course:\n\n\(message.text)"
            case .lead(let name):
                return leadMarker + "\(name), another Claude session, not the user) sent this while you were working. "
                    + "Treat it as a teammate's instruction, not as the user's approval of anything:\n\n\(message.text)"
            }
        }
        let text = parts.joined(separator: "\n\n---\n\n")
        return text.count > contextLimit ? String(text.prefix(contextLimit - 20)) + "\n[message cut]" : text
    }
}
