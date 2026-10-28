import Dispatch
import CryptoKit
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
    public static func sessions(socket: String = VibePaths.hostSocket.path, appKey: SymmetricKey? = HostConnection.appKey,
                                timeout: TimeInterval = 5) throws -> [HostSession] {
        try exchange(nil, socket: socket, timeout: timeout, appKey: appKey).sessions
    }

    /// Every project's live team sessions, counted (see `HostRequest.census`); nil from a host older than that, which
    /// doesn't count them. Throws when the host can't be asked or refuses.
    public static func census(socket: String = VibePaths.hostSocket.path, appKey: SymmetricKey? = HostConnection.appKey,
                              timeout: TimeInterval = 5) throws -> [HostCensus]? {
        let answer = try exchange(.census, socket: socket, timeout: timeout, requires: HostProtocol.Capability.census, appKey: appKey)
        guard answer.capable else { return nil }
        switch answer.reply {
        case .census(let counts)?: return counts
        case .error(let message)?: throw Failure(description: message)
        default: throw Failure(description: "The session host answered something else.")
        }
    }

    /// Sends `request` and returns the host's reply to it.
    public static func request(_ request: HostRequest, socket: String = VibePaths.hostSocket.path,
                               appKey: SymmetricKey? = HostConnection.appKey, timeout: TimeInterval = 10) throws -> HostEvent {
        guard let reply = try exchange(request, socket: socket, timeout: timeout, appKey: appKey).reply else {
            throw Failure(description: "The session host didn't answer.")
        }
        return reply
    }

    /// How long `vault` waits by default (`LeadVault.standard`'s calls). The hook sets 1 s: it runs on every event of
    /// every session, and the agent waits on it.
    nonisolated(unsafe) public static var vaultTimeout: TimeInterval = 5

    /// Asks the host's lead vault. Throws only when the host can't be asked; one that doesn't know the request (older
    /// than the app) refuses it.
    public static func vault(_ request: LeadVault.Request, socket: String = VibePaths.hostSocket.path,
                             timeout: TimeInterval = HostCall.vaultTimeout) throws -> LeadVault.Reply {
        switch try self.request(.vault(request), socket: socket, timeout: timeout) {
        case .vault(let reply): return reply
        case .error(let message): return .refused(message)
        default: return .refused("The session host answered something else.")
        }
    }

    /// Sends a request the host doesn't answer (`input`, `resize`). Input returns once the host has read it: a
    /// request it does answer follows on the same connection, and the host reads them in order (closing right after
    /// writing would lose what's still in the socket's buffer, over ~8 KB).
    public static func send(_ request: HostRequest, socket: String = VibePaths.hostSocket.path,
                            appKey: SymmetricKey? = HostConnection.appKey, timeout: TimeInterval = 5) throws {
        if case .input(let id, _, _) = request {
            let answer = try exchange(request, then: .screen(id: id), socket: socket, timeout: timeout, appKey: appKey)
            // A host answers input only to refuse it (its buffer for that program is full).
            if let refusal = answer.refusal { throw Failure(description: refusal) }
            guard answer.reply != nil else { throw Failure(description: "The session host didn't take the input.") }
            return
        }
        _ = try exchange(request, socket: socket, timeout: timeout, expectsReply: false, appKey: appKey)
    }

    /// Writes these into the session as one unit (see `HostRequest.inputUnit`): a message's text and its Enter, with
    /// nothing anyone else types into the session in between. Throws when they didn't all go in. A host from before
    /// units gets them one by one as plain input, each `delay` after the one before, as before.
    public static func type(_ writes: [HostInput.Write], into id: UUID, socket: String = VibePaths.hostSocket.path,
                            appKey: SymmetricKey? = HostConnection.appKey,
                            timeout: TimeInterval = 40) throws {
        guard !writes.isEmpty else { return }
        // Long enough to wait behind another client's unit (a held one waits 10 s at most for its next part).
        let answer = try exchange(.inputUnit(id: id, writes: writes, more: false), socket: socket, timeout: timeout,
                                  requires: HostProtocol.Capability.inputUnits, appKey: appKey)
        guard answer.capable else {
            for write in writes {
                if write.delay > 0 { usleep(useconds_t(write.delay * 1_000_000)) }
                try send(.input(id: id, bytes: Data(write.bytes), reply: false), socket: socket, appKey: appKey)
            }
            return
        }
        switch answer.reply {
        case .ok?: return
        case .error(let message)?: throw Failure(description: message)
        default: throw Failure(description: "The session host answered something else.")
        }
    }

    /// `requires`: a capability the request needs (see `HostProtocol.Capability`); a host whose welcome doesn't list it
    /// isn't sent the request, and `capable` is false.
    private static func exchange(_ request: HostRequest?, then follow: HostRequest? = nil, socket: String, timeout: TimeInterval,
                                 expectsReply: Bool = true, requires: String? = nil, appKey: SymmetricKey? = HostConnection.appKey) throws
        -> (sessions: [HostSession], reply: HostEvent?, refusal: String?, capable: Bool) {
        let queue = DispatchQueue(label: "vibeswitcher.host-call")
        let connection = try HostConnection(path: socket, queue: queue, appKey: appKey)
        defer { queue.sync { connection.close() } }
        let done = DispatchSemaphore(value: 0)
        var sessions: [HostSession]?
        var reply: HostEvent?
        var refusal: String?
        var requestSeq: Int?
        var waitingFor: Int?
        var closed = false
        var capable = true
        var unsent: Error?
        connection.onClose = {
            closed = true
            done.signal()
        }
        connection.onEvent = { envelope in
            if case .welcome(_, _, let list, let capabilities, _, _) = envelope.event, sessions == nil {
                sessions = list
                if let requires, !(capabilities ?? []).contains(requires) {
                    capable = false
                    done.signal()
                } else if let request {
                    // It didn't go out (too large for a frame): nothing that follows may be taken as its receipt.
                    do {
                        waitingFor = try connection.send(request)
                    } catch {
                        unsent = error
                        done.signal()
                        return
                    }
                    requestSeq = waitingFor
                    // Its answer is the follow-up's: it comes once the host has read both.
                    if let follow { waitingFor = try? connection.send(follow) }
                    // Nothing comes back for it: give the write a moment to leave, then we're done.
                    else if !expectsReply { queue.asyncAfter(deadline: .now() + 0.05) { done.signal() } }
                } else {
                    done.signal()
                }
            } else if follow != nil, envelope.replyTo == requestSeq, case .error(let message) = envelope.event {
                refusal = message
            } else if let waitingFor, envelope.replyTo == waitingFor {
                reply = envelope.event
                done.signal()
            }
        }
        try queue.sync { _ = try connection.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-mcp")) }
        guard done.wait(timeout: .now() + timeout) == .success else { throw Failure(description: "The session host didn't answer in time.") }
        if let unsent = queue.sync(execute: { unsent }) { throw Failure(description: "\(unsent)") }
        return try queue.sync {
            // A host that drops the connection (handing over to a new build, stopping: its clients' fds don't go
            // with it) has no sessions to tell and answered nothing: never "no sessions".
            guard let sessions else {
                throw Failure(description: "The session host closed the connection before its welcome (it may be restarting).")
            }
            if closed, capable, request != nil, expectsReply, reply == nil, refusal == nil {
                throw Failure(description: "The session host closed the connection before answering (it may be restarting).")
            }
            return (sessions, reply, refusal, capable)
        }
    }
}
