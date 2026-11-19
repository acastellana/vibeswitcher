import Foundation

/// Codex's hooks take nothing from its steer inbox (only Claude's do, see `vibeswitcher-hook`): a message reaches a
/// Codex session typed into its box, mid-turn too (it takes it into its running turn), and its rollout then records it
/// as a user message of that turn. A copy can still wait in the inbox although Codex took it: the keys went in but the
/// host's answer didn't come in time (`HostCall.type`, a loaded Mac), so `LeadDelivery.deliver` posted the message to
/// wait for the turn's end. The witness then told the lead "a message … has waited N min in its inbox, undelivered"
/// again and again while the worker worked on it and answered it (audits-run-on-codex, 2026-11-19: at 5 min, 27 min,
/// 38 min and 1 h), and the turn's end would have typed it a second time. What the rollout shows taken is recorded as
/// delivered (`retire`). A message it doesn't show stays, and is told as ever once it has waited past the threshold.
public enum CodexInbox {
    /// How long before a message was posted its rollout record may be: the keys go out before the copy is posted,
    /// which waits for the host's answer (`HostCall.type`, up to 40 s) first.
    public static let typedBefore: TimeInterval = 120

    /// How much of the rollout's end is read for what it recorded: about an hour of a busy worker's turn.
    public static let window = 4 << 20

    /// A user message the rollout recorded: its text, and when.
    public struct Recorded: Equatable, Sendable {
        public var text: String
        public var at: Double

        public init(text: String, at: Double) {
            self.text = text
            self.at = at
        }
    }

    /// The user messages in a rollout's complete lines (`response_item` messages with the user's role: one per
    /// submitted prompt or steered message; the `item_completed` echo of each isn't counted again).
    public static func recorded(in data: Data) -> [Recorded] {
        var lines = TranscriptReader.lines(data)
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        let role = Data(#""role":"user""#.utf8)
        return lines.compactMap { line in
            // Cheap filter first: most lines are tool output.
            guard line.range(of: role) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message", payload["role"] as? String == "user",
                  let at = ChatReader.date(object["timestamp"])?.timeIntervalSince1970 else { return nil }
            let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return Recorded(text: text, at: at)
        }
    }

    /// Of `pending` (in the inbox's order), the messages the rollout recorded: a user message from `typedBefore` before
    /// it was posted on that holds all of the text typed for it (`LeadDelivery.typed`, whitespace aside: the box may
    /// wrap it), and nothing more after it but another typed message. Each time the text is recorded stands for one copy, so a second copy of the same text waits for a
    /// second record; a prompt typed for several (`LeadDelivery.flush`'s whole queue) records each of them.
    public static func taken(_ pending: [SteerMessage], recorded: [Recorded]) -> [SteerMessage] {
        let squeezed = recorded.map { squeeze($0.text) }
        var used: [Int: [String: Int]] = [:]
        return pending.filter { message in
            let needle = squeeze(LeadDelivery.typed(message.text, from: message.from))
            guard !needle.isEmpty else { return false }
            for index in recorded.indices where recorded[index].at >= message.at - typedBefore {
                let had = used[index]?[needle] ?? 0
                guard occurrences(of: needle, in: squeezed[index]) > had else { continue }
                used[index, default: [:]][needle] = had + 1
                return true
            }
            return false
        }
    }

    /// Records as delivered what waits in the inbox for the Codex agent `agentPid` on `tty` and its rollout (`rollout`,
    /// a checked path) shows taken. Returns those messages.
    @discardableResult
    public static func retire(tty: String, agentPid: Int32, rollout: URL, root: URL = VibePaths.root) -> [SteerMessage] {
        let pending = SteerInbox.pending(tty: tty, root: root).filter { $0.agentPid == agentPid }
        guard !pending.isEmpty, let data = tail(of: rollout) else { return [] }
        let taken = taken(pending, recorded: recorded(in: data))
        guard !taken.isEmpty else { return [] }
        let ids = SteerInbox.recordDelivered(ids: Set(taken.map(\.id)), tty: tty, root: root)
        return taken.filter { ids.contains($0.id) }
    }

    /// The rollout's last `window` bytes, from its first whole line.
    static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.subdata(in: (data.startIndex + TranscriptReader.tailStart(data))..<data.endIndex) }
        return data
    }

    private static func squeeze(_ text: String) -> String { String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init)) }

    /// How many times `needle` is all of a message in `haystack`: it ends where the record ends or the next message's
    /// frame starts (each typed message not the user's starts with `LeadDelivery.prefix`), so a waiting "Merged." isn't
    /// taken for a later "Merged. Next: …".
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        let frame = squeeze(LeadDelivery.prefix)
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .literal, range: range) {
            if found.upperBound == haystack.endIndex || haystack[found.upperBound...].hasPrefix(frame) { count += 1 }
            range = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return count
    }
}

extension LeadObserver {
    /// For a Codex session: what waits in its inbox that its rollout (where its hooks say it is) shows it took,
    /// recorded as delivered (see `CodexInbox`). Nothing for a Claude session: its hooks hand over and record its messages.
    /// `agent`: what the process scan found running there, when known; else the session's preset and its hooks say.
    @discardableResult
    public func retireTaken(_ session: HostSession, agent: Agent? = nil, agentPid: Int32, root: URL = VibePaths.root) -> [SteerMessage] {
        let hook = hook(session, agentPid: agentPid)
        guard (agent ?? hook?.agent ?? session.agent.flatMap(Agent.init(rawValue:))) == .codex,
              SteerInbox.pending(tty: session.tty, root: root).contains(where: { $0.agentPid == agentPid }),
              let path = transcript(session, hook: hook),
              let (url, format) = TranscriptReader.checkedURL(path, home: home), format == .codex else { return [] }
        return CodexInbox.retire(tty: session.tty, agentPid: agentPid, rollout: url, root: root)
    }
}
