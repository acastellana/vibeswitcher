import Dispatch
import Foundation

/// A session's conversation, condensed for the lead to read: prompts, replies, each tool run as one line with its
/// failures. Raw tool output stays out (the verifier looks at the real thing).
public enum SessionDigest {
    public static func text(_ log: ChatLog, limit: Int) -> String {
        var lines: [String] = []
        var run: [ChatTool] = []
        func flush() {
            guard !run.isEmpty else { return }
            let summary = ChatTimeline.summary(run)
            if !summary.isEmpty { lines.append("[\(summary)]") }
            for tool in run where tool.result?.failed == true {
                let first = tool.result?.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                lines.append("✕ \(tool.title)\(first.isEmpty ? "" : ": \(clip(first, 200))")")
            }
            run = []
        }
        for entry in log.entries {
            switch entry.kind {
            case .prompt(let text, let images):
                flush()
                lines.append("You: \(clip(text, 600))\(images.isEmpty ? "" : " [\(images.count) image(s)]")")
            case .steered(let text, let fromLead):
                flush()
                lines.append("\(fromLead ? "Another agent" : "You") (while it worked): \(clip(text, 600))")
            case .reply(let text):
                flush()
                lines.append("Agent: \(clip(text, 1500))")
            case .tool(let tool):
                run.append(tool)
            }
        }
        flush()
        // What the lead reads leaves the session's secrets out (a token pasted into a prompt, printed by a tool).
        var text = Redaction.secrets(in: lines.joined(separator: "\n"))
        if text.count > limit {
            let marker = "[earlier part left out]\n"
            text = marker + String(text.suffix(limit - marker.count))
        }
        return text
    }

    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > count ? String(flat.prefix(count)) + "…" : flat
    }
}

/// One request to the session host from a process other than the app (the lead's tool server): connect, say
/// hello, ask, wait for the answer.
public enum HostCall {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        public init(description: String) { self.description = description }
    }

    /// The host's sessions (from its welcome).
    public static func sessions(socket: String = VibePaths.hostSocket.path, timeout: TimeInterval = 5) throws -> [HostSession] {
        try exchange(nil, socket: socket, timeout: timeout).sessions
    }

    /// Sends `request` and returns the host's reply to it.
    public static func request(_ request: HostRequest, socket: String = VibePaths.hostSocket.path, timeout: TimeInterval = 10) throws -> HostEvent {
        guard let reply = try exchange(request, socket: socket, timeout: timeout).reply else {
            throw Failure(description: "The session host didn't answer.")
        }
        return reply
    }

    /// Sends a request the host doesn't answer (`input`, `resize`): returns once it's written.
    public static func send(_ request: HostRequest, socket: String = VibePaths.hostSocket.path, timeout: TimeInterval = 5) throws {
        _ = try exchange(request, socket: socket, timeout: timeout, expectsReply: false)
    }

    private static func exchange(_ request: HostRequest?, socket: String, timeout: TimeInterval,
                                 expectsReply: Bool = true) throws -> (sessions: [HostSession], reply: HostEvent?) {
        let queue = DispatchQueue(label: "vibeswitcher.host-call")
        let connection = try HostConnection(path: socket, queue: queue)
        defer { queue.sync { connection.close() } }
        let done = DispatchSemaphore(value: 0)
        var sessions: [HostSession]?
        var reply: HostEvent?
        var waitingFor: Int?
        var closed = false
        connection.onClose = {
            closed = true
            done.signal()
        }
        connection.onEvent = { envelope in
            if case .welcome(_, _, let list) = envelope.event, sessions == nil {
                sessions = list
                if let request {
                    waitingFor = connection.send(request)
                    // Nothing comes back for it: give the write a moment to leave, then we're done.
                    if !expectsReply { queue.asyncAfter(deadline: .now() + 0.05) { done.signal() } }
                } else {
                    done.signal()
                }
            } else if let waitingFor, envelope.replyTo == waitingFor {
                reply = envelope.event
                done.signal()
            }
        }
        queue.sync { _ = connection.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-mcp")) }
        guard done.wait(timeout: .now() + timeout) == .success else { throw Failure(description: "The session host didn't answer in time.") }
        return queue.sync {
            if closed && sessions == nil { return ([], nil) }
            return (sessions ?? [], reply)
        }
    }
}
