import Foundation

/// A message VibeSwitcher handed to an agent (see `SteerReply.context`, `LeadDelivery.typed`): a worker's or
/// verifier's report, a witness notice, a message from the lead, the user's words relayed while it worked. The chat
/// shows it as what it is, under its sender, never as something the user typed.
public struct TeamMessage: Equatable, Sendable {
    public enum Sender: Equatable, Sendable {
        /// The user, relayed by VibeSwitcher (an answer to the lead, a message steered in while it worked).
        case user
        /// A project lead (its name: "lead of vibeswitcher").
        case lead(String)
        /// VibeSwitcher itself, about something ("worker fix-the-chat-layout", "verifier x", "witness", "reports").
        case vibeSwitcher(String)
    }

    public enum Kind: String, Equatable, Sendable {
        /// From a worker: done, blocked, or a question.
        case report
        /// A verifier's verdict.
        case audit
        /// VibeSwitcher noticed something (a worker stalled, sessions ended, low disk).
        case witness
        /// The user's own words.
        case userAnswer
        /// From the lead.
        case leadMessage
        /// Anything else VibeSwitcher says (the wake-up for waiting reports, a timer).
        case notice
    }

    /// Which part of a message too long for one delivery.
    public struct Part: Equatable, Sendable {
        public var index: Int
        public var count: Int
    }

    public var sender: Sender
    public var kind: Kind
    /// The task it's about, for a worker's or verifier's message.
    public var task: String?
    /// The sender's words, unquoted (without the part line).
    public var body: String
    public var part: Part?

    public init(sender: Sender, body: String, part: Part? = nil) {
        self.sender = sender
        self.body = body
        self.part = part
        switch sender {
        case .user: kind = .userAnswer; task = nil
        case .lead: kind = .leadMessage; task = nil
        case .vibeSwitcher(let about):
            let words = about.split(separator: " ", maxSplits: 1).map(String.init)
            if words.count == 2, words[0] == "worker" || words[0] == "verifier", !words[1].contains(" ") {
                kind = words[0] == "worker" ? .report : .audit
                task = words[1]
            } else {
                kind = about == "witness" ? .witness : .notice
                task = nil
            }
        }
    }

    /// The text as the chat had it before (`SteerReply.messages`): the part line, then the body.
    public var text: String {
        guard let part else { return body }
        return SteerReply.partLine(part.index, of: part.count) + "\n" + body
    }

    /// Whether the agent should take it as from someone other than the user.
    public var fromLead: Bool { sender != .user }

    /// "Report from the worker on fix-the-chat-layout", "Audit of x passed", "VibeSwitcher: worker x stalled".
    public var title: String {
        let base: String
        switch (kind, sender) {
        case (.userAnswer, _): base = "You, relayed by VibeSwitcher"
        case (.leadMessage, .lead(let name)): base = "Message from \(name)"
        case (.report, _):
            let slug = task ?? ""
            let opening = "The worker on \(slug) "
            if firstLine.hasPrefix(opening + "asks") { base = "Question from the worker on \(slug)" }
            else if firstLine.hasPrefix(opening + "is blocked") { base = "The worker on \(slug) is blocked" }
            else { base = "Report from the worker on \(slug)" }
        case (.audit, _):
            let slug = task ?? ""
            if firstLine.hasPrefix("The audit of \(slug) passed") { base = "Audit of \(slug) passed" }
            else if firstLine.hasPrefix("The audit of \(slug) did not pass") { base = "Audit of \(slug) didn't pass" }
            else { base = "From the verifier on \(slug)" }
        case (.witness, _):
            base = "VibeSwitcher: " + LeadWake.short(SteerMessage(text: firstLine, from: .system(""), agentPid: 0))
        case (_, .vibeSwitcher("reports")): base = "VibeSwitcher: reports are waiting"
        case (_, .vibeSwitcher(let about)): base = about.isEmpty ? "VibeSwitcher" : "VibeSwitcher · \(about)"
        default: base = "VibeSwitcher"
        }
        guard let part, part.count > 1 else { return base }
        return base + " · part \(part.index) of \(part.count)"
    }

    /// The first line of what it says, for the collapsed card.
    public var gist: String {
        let line = firstLine
        return line.count > 200 ? Summarizer.clip(line, 200) : line
    }

    private var firstLine: String {
        body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// Whether a summary says more than its first line does: it runs past a couple of lines.
    public var needsSummary: Bool {
        kind != .userAnswer && (body.count > 280 || body.split(whereSeparator: \.isNewline).count > 3)
    }

    // MARK: Reading

    /// The messages of one delivery in format v2 (as the transcript records a hook's context), in order; nil when
    /// it isn't one. Parts that aren't a sender line we write followed by a quote are left out, as the agent's
    /// reading of them (`SteerReply.messages`) leaves them out.
    public static func messages(inContext context: String) -> [TeamMessage]? {
        guard context.hasPrefix(SteerReply.header) else { return nil }
        return context.components(separatedBy: SteerReply.separator).dropFirst().compactMap { piece in
            guard let split = piece.range(of: "\n\n") else { return nil }
            let line = String(piece[..<split.lowerBound])
            guard !line.contains("\n"), let sender = sender(line) else { return nil }
            var lines: [String] = []
            var part: Part?
            for (index, line) in piece[split.upperBound...].components(separatedBy: "\n").enumerated() {
                if index == 0, SteerReply.isPartLine(line) { part = Self.part(line) }
                else if line == ">" { lines.append("") }
                else if line.hasPrefix("> ") { lines.append(String(line.dropFirst(2))) }
                else if line == SteerReply.cut { lines.append(SteerReply.cut) }
                else { return nil }
            }
            return TeamMessage(sender: sender, body: lines.joined(separator: "\n"), part: part)
        }
    }

    /// A message VibeSwitcher typed in as an idle agent's prompt ("[VibeSwitcher · worker x, not the user] …").
    public static func typed(_ text: String) -> TeamMessage? {
        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = ", not the user]"
        guard rest.hasPrefix(LeadDelivery.prefix + " · "), let close = rest.range(of: marker) else { return nil }
        let about = String(rest[rest.index(rest.startIndex, offsetBy: LeadDelivery.prefix.count + 3)..<close.lowerBound])
        guard !about.isEmpty, !about.contains("\n") else { return nil }
        let body = rest[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let sender: Sender = about.hasPrefix("from ") ? .lead(String(about.dropFirst(5))) : .vibeSwitcher(about)
        return TeamMessage(sender: sender, body: body)
    }

    /// Who a sender line we write names (see `SteerReply.senderLine`).
    static func sender(_ line: String) -> Sender? {
        if line.hasPrefix(SteerReply.userMarker) { return .user }
        if line.hasPrefix(SteerReply.systemMarker + " ("), line.hasSuffix("):") {
            return .vibeSwitcher(String(line.dropFirst(SteerReply.systemMarker.count + 2).dropLast(2)))
        }
        if line.hasPrefix(SteerReply.leadMarker), let end = line.range(of: ", another Claude session, not the user)") {
            return .lead(String(line[line.index(line.startIndex, offsetBy: SteerReply.leadMarker.count)..<end.lowerBound]))
        }
        // Worded otherwise, but from them as the agent reads it.
        if line.hasPrefix(SteerReply.systemMarker) { return .vibeSwitcher("") }
        if line.hasPrefix(SteerReply.leadMarker) { return .lead("your lead") }
        return nil
    }

    /// "[Part 2 of 4 …]" → 2 of 4.
    static func part(_ line: String) -> Part? {
        let numbers = line.dropFirst("[Part ".count).split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        return numbers.count == 2 ? Part(index: numbers[0], count: numbers[1]) : nil
    }
}
