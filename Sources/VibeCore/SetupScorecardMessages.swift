import Foundation

/// Why the lead messaged the user, as far as the tool it used says (decision 2026-11-17 19:55 allows four reasons). Never
/// read from what the message says, and no model classifies anything:
/// - `mustAct`: ask_user (a question) and a vs-shell card (a command for the user to run).
/// - `dailySummary`: a post_update titled "Today:…".
/// - `finishedOrProblem`: any other post_update (something asked for is finished, or a real problem: the tool doesn't
///   say which).
/// - `other`: the lead's plain text replies in its chat, one per turn.
public enum LeadMessageReason: String, CaseIterable, Sendable {
    case mustAct, finishedOrProblem, dailySummary, other

    public var label: String {
        switch self {
        case .mustAct: "you must act"
        case .finishedOrProblem: "finished or a problem"
        case .dailySummary: "daily summary"
        case .other: "other"
        }
    }
}

/// One message from the lead to the user: why, when, and whether the user acted on it within a day (answered, clicked
/// or replied); `acted` nil while its day isn't over and nothing came yet.
public struct LeadMessage: Equatable, Sendable {
    public var reason: LeadMessageReason
    public var at: Double
    public var acted: Bool?

    public init(reason: LeadMessageReason, at: Double, acted: Bool?) {
        self.reason = reason
        self.at = at
        self.acted = acted
    }
}

/// A week's messages from the leads to the user (see `LeadMessages`).
public struct ScorecardMessages: Equatable, Sendable {
    /// The week's length in days, what the per-day figure divides by.
    public static let days = 7.0

    public var byReason: [LeadMessageReason: Int] = [:]
    /// Of the messages whose day is over or that were acted on (the n of the share), those the user acted on.
    public var judged = 0
    public var acted = 0
    /// Some project keeps a board to count from; false: not recorded.
    public var kept = false
    /// Some project's lead chat transcript was read: its text replies and shell cards are in; false: they aren't.
    public var chatKept = false

    public init() {}

    public init(_ messages: [LeadMessage], from t0: Double, to t1: Double, kept: Bool) {
        self.kept = kept
        for message in messages where t0 <= message.at && message.at < t1 {
            byReason[message.reason, default: 0] += 1
            guard let acted = message.acted else { continue }
            judged += 1
            if acted { self.acted += 1 }
        }
    }

    public var total: Int { byReason.values.reduce(0, +) }
    public var perDay: Double? { kept ? Double(total) / Self.days : nil }
    public func perDay(_ reason: LeadMessageReason) -> Double? { kept ? Double(byReason[reason] ?? 0) / Self.days : nil }
    public var actedShare: Double? { judged > 0 ? Double(acted) / Double(judged) : nil }
}

/// The lead's messages to the user, counted from what the lead's own records keep, by kind and time only: its questions
/// (ask_user, the board's and its archive's), its updates (post_update, likewise; the title read only for its "Today:"
/// prefix), and from its chat transcript (`LeadChatReader`) its vs-shell cards and its text replies.
public enum LeadMessages {
    /// How long after a message the user's answer, click or reply still counts as acting on it.
    public static let day: Double = 86_400
    /// A post_update titled so is the daily summary.
    public static let dailyPrefix = "Today:"
    /// The board's updates the tool server and the app post themselves, not the lead: a move of the base they took
    /// ("Took 3 commits on main", `LeadToolset.checkBaseMoves` and the app's `BaseMoves`, pinned by a test).
    static let takenTitle = try! Regex(#"^Took [0-9]+ commits? on \S+$"#)

    /// Whether the board's update titled `title` is the lead's own (post_update), not one the server or app posted.
    public static func isLeadsUpdate(_ title: String) -> Bool { (try? takenTitle.wholeMatch(in: title)) == nil }

    /// Every message of one project, oldest first. A question counts as acted on when the user answered it (not
    /// withdrawn or decided on its timer) within a day; a shell card when the user pressed Run or declined it within a
    /// day; an update or a text reply when the user wrote in the lead's chat within a day after it.
    public static func messages(questions: [LeadQuestion], updates: [(title: String, at: Double)], chat: LeadChatTimeline?,
                                now: Double) -> [LeadMessage] {
        let replies = chat?.userMessages.sorted() ?? []
        // No transcript of this lead's chat: whether the user replied isn't known, so an update isn't judged.
        func replied(after at: Double) -> Bool? {
            guard chat != nil else { return nil }
            if replies.contains(where: { $0 > at && $0 <= at + day }) { return true }
            return now < at + day ? nil : false
        }
        var found: [LeadMessage] = []
        for question in questions {
            let answered = question.state == .answered && (question.answeredAt ?? .infinity) <= question.askedAt + day
            found.append(LeadMessage(reason: .mustAct, at: question.askedAt,
                                     acted: answered ? true : (question.isOpen && now < question.askedAt + day) ? nil : false))
        }
        for update in updates {
            let reason: LeadMessageReason = update.title.hasPrefix(dailyPrefix) ? .dailySummary : .finishedOrProblem
            found.append(LeadMessage(reason: reason, at: update.at, acted: replied(after: update.at)))
        }
        if let chat {
            for reply in chat.replies { found.append(LeadMessage(reason: .other, at: reply, acted: replied(after: reply))) }
            // Each card by its request's id, with how VibeSwitcher said it ended: run or declined within its day (acted
            // on), started at once (no card was shown: not a message), expired or failed (not acted on).
            for card in chat.shells where !card.atOnce {
                let end = chat.shellEnds[card.request]
                switch end?.outcome {
                case .atOnce: continue
                case .answered where end.map({ $0.at <= card.at + day }) == true:
                    found.append(LeadMessage(reason: .mustAct, at: card.at, acted: true))
                case .answered, .unanswered: found.append(LeadMessage(reason: .mustAct, at: card.at, acted: false))
                case nil: found.append(LeadMessage(reason: .mustAct, at: card.at, acted: now < card.at + day ? nil : false))
                }
            }
        }
        return found.sorted { $0.at < $1.at }
    }
}

/// What a lead's chat transcript holds that the scorecard counts, by kind and time only (no text is kept): its text
/// replies, one per turn (the turn's last text block; a turn ends at the next message in), the user's messages (typed,
/// or relayed by VibeSwitcher while it worked), its vs-shell cards and VibeSwitcher's notices that the user answered one.
public struct LeadChatTimeline: Equatable, Sendable {
    /// A vs-shell request the tool said it filed (`Filed shell request <id>`), when the lead filed it; `atOnce`: the
    /// tool said VibeSwitcher starts it without a card (Settings › Agents).
    public struct ShellCard: Equatable, Sendable {
        public var request: String
        public var at: Double
        public var atOnce: Bool

        public init(request: String, at: Double, atOnce: Bool = false) {
            self.request = request
            self.at = at
            self.atOnce = atOnce
        }
    }

    /// How VibeSwitcher told the lead a request ended, and when.
    public struct ShellEnd: Equatable, Sendable {
        public var outcome: LeadChatReader.ShellOutcome
        public var at: Double

        public init(_ outcome: LeadChatReader.ShellOutcome, at: Double) {
            self.outcome = outcome
            self.at = at
        }
    }

    public var replies: [Double] = []
    public var userMessages: [Double] = []
    public var shells: [ShellCard] = []
    /// By request id: the first notice of how each ended.
    public var shellEnds: [String: ShellEnd] = [:]

    public init(replies: [Double] = [], userMessages: [Double] = [], shells: [ShellCard] = [], shellEnds: [String: ShellEnd] = [:]) {
        self.replies = replies
        self.userMessages = userMessages
        self.shells = shells
        self.shellEnds = shellEnds
    }

    /// Several transcripts' (a lead restarted, or resumed: a resumed transcript repeats the lines it continues), each
    /// line once by its id.
    static func merged(_ parts: [[LeadChatReader.Event]]) -> LeadChatTimeline {
        var seen = Set<String>(), timeline = LeadChatTimeline()
        for event in parts.joined() where seen.insert(event.id).inserted {
            switch event.kind {
            case .reply: timeline.replies.append(event.at)
            case .user: timeline.userMessages.append(event.at)
            case .shell(let request, let atOnce): timeline.shells.append(ShellCard(request: request, at: event.at, atOnce: atOnce))
            case .shellOutcome(let outcome, let request):
                if timeline.shellEnds[request].map({ $0.at > event.at }) ?? true { timeline.shellEnds[request] = ShellEnd(outcome, at: event.at) }
            }
        }
        timeline.shells.sort { $0.at < $1.at }
        return timeline
    }
}

/// Reads a lead's Claude Code transcript into `LeadChatReader.Event`s: what the Mac's chat shows (`ChatReader`), reduced
/// to each entry's kind and time. A shell card is a Bash call whose command's first two words are `vs-shell run` and
/// whose result says the request was filed (`Filed shell request <id>`, `ShellAsk.run`'s fixed wording); VibeSwitcher's
/// notice of how one ended is told by `ShellAsk.message`'s fixed wording (`shellOutcome`), paired with its card by the
/// request's id. Not the user's message: the prompts VibeSwitcher starts or reopens a lead with (`startOpenings`), its
/// relays of an answer to a question or a hold on one (`questionActs`: the board counts those on the question), its
/// marked notices (`[VibeSwitcher · …, not the user]`, which `ChatReader` reads as not the user's) and Claude Code's
/// compaction summary. Lines that can hold none of these (other tool results, thinking) are passed over before parsing.
public enum LeadChatReader {
    struct Event: Equatable {
        enum Kind: Equatable { case reply, user, shell(request: String, atOnce: Bool), shellOutcome(ShellOutcome, request: String) }
        var kind: Kind
        var at: Double
        /// The transcript line's id (with the block's index): the same line in a resumed copy is the same event.
        var id: String
    }

    /// How a shell request ended, as VibeSwitcher told the lead (`ShellAsk.message`).
    public enum ShellOutcome: Equatable, Sendable { case answered, atOnce, unanswered }

    /// The parts of `ShellAsk.message` that tell each outcome (pinned to it by a test): the user pressed Run or
    /// declined; it started at once (Settings › Agents lets agents open shells without asking: no card); it expired or
    /// didn't start.
    static let shellWords: [(String, ShellOutcome)] = [(": the user pressed Run", .answered), (" was declined by the user", .answered),
                                                       (" started at once ", .atOnce), (" expired after ", .unanswered), (" didn't start (", .unanswered)]
    /// `ShellAsk.head`'s opening, before the request's id.
    static let shellHead = "Shell request "
    /// `ShellAsk.run`'s output once a request is filed, before its id; a `.` after the id: started at once, no card.
    static let filedWords = "Filed shell request "

    /// What VibeSwitcher's message `text` says of a shell request (typed in plain, or steered with its lines quoted),
    /// with the request's id; nil when it's about none.
    static func shellOutcome(_ text: String) -> (outcome: ShellOutcome, request: String)? {
        guard let head = text.range(of: shellHead), let outcome = shellWords.first(where: { text.contains($0.0) })?.1 else { return nil }
        let request = requestID(text[head.upperBound...])
        return request.id.isEmpty ? nil : (outcome, request.id)
    }

    /// The request id `text` opens with (a lower-case UUID), and the character after it.
    static func requestID(_ text: Substring) -> (id: String, next: Character?) {
        let id = text.prefix { $0.isHexDigit || $0 == "-" }
        return (String(id), text.dropFirst(id.count).first)
    }

    /// The request `vs-shell run`'s output says it filed, and whether it starts at once (no card); nil when it filed
    /// none (refused, or a usage error).
    static func filed(_ output: String) -> (request: String, atOnce: Bool)? {
        guard let marker = output.range(of: filedWords) else { return nil }
        let request = requestID(output[marker.upperBound...])
        guard !request.id.isEmpty, request.next == "." || request.next == ":" else { return nil }
        return (request.id, request.next == ".")
    }

    /// The openings of the prompts VibeSwitcher starts a lead with (its start or handover, and its reopening after a
    /// restart: pinned by a test): not the user's words.
    static let startOpenings = [LeadPrompts.startOpening, "The Mac restarted, and its session host ended"]
    /// The openings of what VibeSwitcher sends as the user's when they answer or hold one of the lead's questions
    /// (`LeadAnswerOutcome.message`, `LeadAnswerOutcome.holdMessage`: pinned by a test). The board counts that act on
    /// the question; it isn't a reply to whatever the lead said before.
    static let questionActs = ["Answer to your question ", "The user answered your question ", "The user answered your withdrawn question ",
                               "The user is holding your question "]

    /// Whether `words`, sent in as the user's, is the user writing to the lead (not VibeSwitcher's start, reopening, or
    /// relay of an answer).
    static func isUsersMessage(_ words: String) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(startOpenings + questionActs).contains { words.hasPrefix($0) }
    }

    /// `data`'s events, in the transcript's order.
    static func events(_ data: Data) -> [Event] {
        var events: [Event] = []
        // The turn's latest text reply so far: it counts once the turn ends (the next message in, or the end).
        var pending: Event?
        func endTurn() {
            if let reply = pending { events.append(reply) }
            pending = nil
        }
        // The vs-shell calls waiting for their results, by tool call id: a card counts once its result says it's filed.
        var shellCalls: [String: (at: Double, id: String)] = [:]
        let assistant = Data(#""type":"assistant""#.utf8), user = Data(#""type":"user""#.utf8)
        let attachment = Data(#""type":"attachment""#.utf8), text = Data(#""type":"text""#.utf8)
        let shell = Data("vs-shell".utf8), result = Data(#""tool_result""#.utf8), filedMark = Data(filedWords.utf8)
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func time(_ value: Any?) -> Double? {
            guard let stamp = value as? String else { return nil }
            return (fractional.date(from: stamp) ?? plain.date(from: stamp))?.timeIntervalSince1970
        }
        var start = data.startIndex
        var lineNumber = 0
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? end + 1 : end
            lineNumber += 1
            let isAssistant = line.range(of: assistant) != nil
            var isResult = false
            if isAssistant {
                guard line.range(of: text) != nil || line.range(of: shell) != nil else { continue }
            } else if line.range(of: user) != nil {
                if line.range(of: result) != nil {
                    guard !shellCalls.isEmpty, line.range(of: filedMark) != nil else { continue }
                    isResult = true
                }
            } else if line.range(of: attachment) == nil {
                continue
            }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  object["isCompactSummary"] as? Bool != true else { continue }
            let lineID = object["uuid"] as? String ?? "line-\(lineNumber)"
            if isResult {
                // The vs-shell calls' results: a card counts at its call's time once filed, by its request's id.
                let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let call = (block["tool_use_id"] as? String).flatMap({ shellCalls.removeValue(forKey: $0) }) else { continue }
                    let output = block["content"] as? String
                        ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                    if let filed = filed(output) {
                        events.append(Event(kind: .shell(request: filed.request, atOnce: filed.atOnce), at: call.at, id: call.id))
                    }
                }
                continue
            }
            if object["type"] as? String == "assistant" {
                guard let at = time(object["timestamp"]), let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                for (index, block) in blocks.enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        if let words = block["text"] as? String, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            pending = Event(kind: .reply, at: at, id: "\(lineID).\(index)")
                        }
                    case "tool_use":
                        if block["name"] as? String == "Bash", let input = block["input"] as? [String: Any],
                           let command = input["command"] as? String, isShellCard(command), let call = block["id"] as? String {
                            shellCalls[call] = (at, "\(lineID).\(index)")
                        }
                    default: break
                    }
                }
                continue
            }
            for case .entry(let entry) in ChatReader.claude(object, lineID: lineID) {
                guard let at = entry.at?.timeIntervalSince1970 else { continue }
                switch entry.kind {
                case .prompt(let words, _), .steered(text: let words, fromLead: false):
                    endTurn()
                    if isUsersMessage(words) { events.append(Event(kind: .user, at: at, id: entry.id)) }
                case .steered(text: let words, fromLead: true):
                    endTurn()
                    if let told = shellOutcome(words) ?? entry.team.flatMap({ shellOutcome($0.body) }) {
                        events.append(Event(kind: .shellOutcome(told.outcome, request: told.request), at: at, id: entry.id))
                    }
                case .reply, .tool:
                    break
                }
            }
        }
        endTurn()
        return events
    }

    /// The command's first two words are `vs-shell run`.
    static func isShellCard(_ command: String) -> Bool {
        Array(command.split(whereSeparator: \.isWhitespace).prefix(2)) == ["vs-shell", "run"]
    }

}
