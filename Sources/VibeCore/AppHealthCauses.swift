import Foundation

/// Causes: what keeps going wrong in VibeSwitcher's own logs, grouped and counted by day, so a problem the user lives
/// with turns into one task with its evidence before they report it (backlog A3). Deterministic, no model: a freeze's
/// cause is its signature (its top 3 app frames, as the digest prints them), an app.log error line's is its pattern
/// (numbers, ids and paths masked, the detail after its second colon cut), and a failure notice the app logs (a
/// dictation cut short, keys that didn't reach the session, a message the host didn't confirm, a shell Run that didn't
/// start) is one cause per notice. When a cause shows on 3 of 7 days, or doubles day over day, the day's close proposes
/// it to the lead once, with its counts by day, its first and last report, its stack or masked line and a task title;
/// it isn't proposed again for 7 days unless it doubles again. 2026-11-07: 75 freezes in a day, most of them three
/// causes, each told once as a repeat and never as a task.
extension AppHealth {
    /// A cause appearing on at least this many of the last `repeatSpan` days is proposed.
    public static let repeatDays = 3
    public static let repeatSpan = 7
    /// A proposed cause isn't proposed again for this many days, unless it doubles again (`doubled`).
    public static let proposeEvery = 7
    /// Doubling day over day counts from this many a day: 1 → 2 is noise.
    public static let doubledFrom = 4
    /// At most this many proposals a day; the others wait for the next day's close.
    public static let proposalsADay = 5
    /// Causes kept (the busiest, most recent); a flood of distinct patterns can't grow the state file without end.
    static let causesKept = 300

    /// One cause: what it is, what it's counted by day, and where its evidence is.
    public struct Cause: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case freeze, line, notice }

        public var kind: Kind
        /// What it is, in a line: a freeze's top frames, a line's pattern, a notice's name.
        public var what: String
        /// Its evidence: a freeze's top frames (up to 5), a line's masked pattern. Redacted, masked; never raw text.
        public var detail: String
        /// The task it suggests.
        public var title: String
        /// Its count each day (yyyy-MM-dd).
        public var counts: [String: Int] = [:]
        /// Its first and last report: a hang's name, or app.log and the line's time.
        public var first: String
        public var last: String
        /// When it was last proposed: the day closed, and its count that day.
        public var proposed: Proposal?

        public struct Proposal: Codable, Equatable, Sendable {
            public var day: String
            public var count: Int
        }

        public init(kind: Kind, what: String, detail: String, title: String, at: String) {
            self.kind = kind
            self.what = what
            self.detail = detail
            self.title = title
            first = at
            last = at
        }
    }

    // MARK: Cause keys

    /// A freeze's cause: its signature (top 3 app frames, else its top 3 frames); nil without one (nothing to group by)
    /// or when its sample says starvation (no app work to fix: the digest asks no task for it).
    public static func cause(of hang: Hang) -> (key: String, cause: Cause)? {
        guard let signature = hang.signature, hang.verdict != .starved else { return nil }
        let frames = hang.frames.isEmpty ? hang.systemFrames : hang.frames
        let title = hang.frames.isEmpty
            ? "Find what stalls the main thread in \(hang.systemFrames.first ?? signature) (no app frames)"
            : "Fix the freeze in \(hang.frames[0])" + (hang.frames.count > 1 ? " (from \(hang.frames[1]))" : "")
        let cause = Cause(kind: .freeze, what: "freezes with " + (hang.frames.isEmpty ? signature : "top app frames " + signature),
                          detail: Redaction.secrets(in: frames.joined(separator: " < ")), title: Redaction.secrets(in: title), at: hang.name)
        return ("freeze " + signature, cause)
    }

    /// A failure notice the app logs, by what its line says (lowercased, after its time): `all` of these in it.
    struct Notice {
        let name: String
        let title: String
        let all: [String]
        /// A part of the notice's reason (after this) names it further ("no text: <why>").
        var reasonAfter: String?
    }

    /// The notices, the first that matches wins. Their app.log lines are VibeSwitcher's own words (ClaudeVoice,
    /// DictationController, ChatSync, ChatModel, ChatRunner, ComposerOutbox, HostClient, ShellDesk).
    static let notices: [Notice] = [
        Notice(name: "Dictation cut short", title: "Find why dictations are cut short", all: ["dictation: claude's ended", "cut short"]),
        Notice(name: "Dictation: the keys didn't reach the session", title: "Find why dictation's keys don't reach the session",
               all: ["dictation:", "keys didn't reach"]),
        Notice(name: "Dictation gave no text", title: "Find why dictations end with no text", all: ["dictation: claude's ended", ", no text: "],
               reasonAfter: ", no text: "),
        Notice(name: "Dictation didn't start", title: "Find why dictation doesn't start", all: ["dictation: claude's didn't start"]),
        Notice(name: "Dictation not started", title: "Find why dictation isn't started", all: ["dictation:", "not started"]),
        Notice(name: "Message not sent: the session host didn't confirm it", title: "Find why the session host doesn't confirm sent messages",
               all: ["composer: the host didn't confirm"]),
        Notice(name: "Message after a dictation didn't go in", title: "Find why a message sent over a dictation doesn't go in",
               all: ["composer: a message sent over a dictation didn't go in"]),
        Notice(name: "Steer didn't reach the agent's inbox", title: "Find why steers don't reach the agent's inbox",
               all: ["composer: steer to", "didn't reach"]),
        Notice(name: "Message refused by the composer", title: "Find why the composer refuses messages", all: ["composer: refused"]),
        Notice(name: "Unsent messages dropped", title: "Find why unsent messages are dropped", all: ["composer: dropped", "unsent"]),
        Notice(name: "Run not confirmed: the session host didn't confirm a code block", title: "Find why a code block's Run isn't confirmed",
               all: ["chat: the host didn't confirm a code block"]),
        // A code block's Run refused in the chat (`RunRefusal.logLine`): one cause per refusal kind, whatever the session.
        Notice(name: "Code block's Run refused", title: "Find why code blocks' Runs in the chat are refused",
               all: ["chat: run refused ("], reasonAfter: ", kind: "),
        Notice(name: "Run refused: the shell session didn't start", title: "Find why a shell request's Run doesn't start its shell",
               all: ["shell: ", "didn't start"]),
        Notice(name: "Run refused: the shell request wasn't started", title: "Find why a shell request isn't started",
               all: ["shell: ", "not started"]),
        Notice(name: "Terminal answer refused or stopped", title: "Find why answers to a Terminal session's question don't go",
               all: ["chat: a terminal answer "]),
        Notice(name: "Input cut by the session host", title: "Find why the session host cuts input short", all: ["host: input to", " cut: "]),
        Notice(name: "Input refused by the session host", title: "Find why the session host refuses input", all: ["host: ", "bytes of input refused"]),
        Notice(name: "Not sent to the session host", title: "Find why requests to the session host aren't sent", all: ["host: not sent"]),
    ]

    /// An app.log line's cause: a failure notice's, else an error line's pattern; nil for other lines.
    public static func cause(ofLine line: String, at: String) -> (key: String, cause: Cause)? {
        let text = String(withoutTime(line))
        let lower = text.lowercased()
        if let notice = notices.first(where: { notice in notice.all.allSatisfy { lower.contains($0) } }) {
            var name = notice.name
            if let after = notice.reasonAfter, let range = text.range(of: after, options: .caseInsensitive) {
                // The reason, up to how long it took (", after 3.1 s"): VibeSwitcher's own words, masked.
                var reason = text[range.upperBound...]
                for stop in [", after ", ", before any Space", ", cancelled by "] {
                    if let cut = reason.range(of: stop, options: .caseInsensitive) { reason = reason[..<cut.lowerBound] }
                }
                let why = masked(String(reason), limit: 100)
                if !why.isEmpty { name += ": " + why }
            }
            let cause = Cause(kind: .notice, what: "the notice \"\(name)\"", detail: pattern(text), title: notice.title, at: at)
            return ("notice " + name, cause)
        }
        guard errorKind(line) != nil else { return nil }
        let pattern = pattern(text)
        let clause = pattern.prefix(80)
        let cause = Cause(kind: .line, what: "app.log error lines like \"\(pattern)\"", detail: pattern,
                          title: "Fix the repeated app.log error: \(clause)", at: at)
        return ("line " + pattern, cause)
    }

    /// A line without its breadcrumb time ("14:02:10.123 lead: …").
    static func withoutTime(_ line: String) -> Substring {
        let text = Substring(line)
        if let space = text.firstIndex(of: " "), text[..<space].first?.isNumber == true, text[..<space].contains(":") {
            return text[text.index(after: space)...]
        }
        return text
    }

    /// An error line's pattern: its part and first clause, masked (`masked`), and "…" for the detail after its second
    /// ": " (an interpolated error, a name: what varies, and what the line says rather than what went wrong).
    public static func pattern(_ line: String) -> String {
        let text = String(withoutTime(line))
        let segments = text.components(separatedBy: ": ")
        let kept = segments.prefix(2).joined(separator: ": ")
        return masked(kept, limit: 160) + (segments.count > 2 ? ": …" : "")
    }

    /// `text` through `Redaction` (first: masking digits would break a token's shape before it's recognised), then
    /// each word masked: a path → <path>, an id (a UUID, hex with a digit, 0x…, a long run of letters and digits) →
    /// <id>, a quoted run → "…", each run of digits → #. At most `limit` characters.
    static func masked(_ text: String, limit: Int) -> String {
        let redacted = Redaction.secrets(in: text)
        var words: [String] = []
        var quote: Character?
        let quotes: [Character: Character] = ["\"": "\"", "“": "”", "'": "'"]
        for word in redacted.split(whereSeparator: \.isWhitespace) {
            if let open = quote {
                if word.last == open || word.dropLast().last == open { quote = nil }
                continue
            }
            if let first = word.first, let close = quotes[first] {
                let rest = word.dropFirst()
                // Closed in the same word ("'x'", "\"x\":"): that word only; otherwise up to the word that closes it.
                let closed = !rest.isEmpty && (rest.last == close || rest.dropLast().last == close)
                if !closed { quote = close }
                words.append("\(first)…\(close)")
                continue
            }
            words.append(maskWord(word))
        }
        let joined = words.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    /// One word masked, its leading and trailing punctuation kept ("(/Users/x/y):" → "(<path>):").
    static func maskWord(_ word: Substring) -> String {
        let edges: Set<Character> = ["(", ")", "[", "]", ",", ":", ";", "."]
        var start = word.startIndex, end = word.endIndex
        while start < end, edges.contains(word[start]) { start = word.index(after: start) }
        while end > start, edges.contains(word[word.index(before: end)]) { end = word.index(before: end) }
        let core = word[start..<end]
        guard !core.isEmpty else { return String(word) }
        let replaced: String
        if core.hasPrefix("/") || core.hasPrefix("~/") || core.contains("/Users/") || core.hasPrefix("file://") {
            replaced = "<path>"
        } else if isID(core) {
            replaced = "<id>"
        } else {
            var out = "", inDigits = false
            for character in core {
                if character.isASCII, character.isNumber {
                    if !inDigits { out.append("#") }
                    inDigits = true
                } else {
                    out.append(character)
                    inDigits = false
                }
            }
            replaced = out
        }
        return String(word[word.startIndex..<start]) + replaced + String(word[end..<word.endIndex])
    }

    /// A UUID (or its first part), 0x…, hex of 6 or more with a digit, or 20 or more letters and digits with both.
    static func isID(_ core: Substring) -> Bool {
        if core.hasPrefix("0x"), core.count > 2 { return true }
        let hexDigits = core.filter { $0 != "-" }
        let digits = core.contains { $0.isASCII && $0.isNumber }
        if hexDigits.count >= 6, digits, hexDigits.allSatisfy(\.isHexDigit) { return true }
        let alnum = core.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return alnum && core.count >= 20 && digits && core.contains { $0.isLetter }
    }

    // MARK: Counting and proposing

    /// What's counted by cause, kept in the watch's state.
    public struct Causes: Codable, Equatable, Sendable {
        public var byKey: [String: Cause] = [:]

        public init() {}

        /// One more of `cause` (made for this occurrence: its `first` is where it was seen) on `day`.
        public mutating func count(_ key: String, _ cause: Cause, day: String) {
            guard var known = byKey[key] else {
                var new = cause
                new.counts[day] = 1
                byKey[key] = new
                return
            }
            known.counts[day, default: 0] += 1
            known.last = cause.first
            // The newest evidence: a deeper stack, a line masked the same way.
            if cause.detail.count >= known.detail.count { known.detail = cause.detail }
            byKey[key] = known
        }

        /// Why `cause` is worth proposing when `day` closes, or nil: 3 of 7 days, or doubled day over day; within 7 days
        /// of its last proposal, only doubled again (twice its count the day it was proposed).
        public func why(_ cause: Cause, closing day: String) -> String? {
            let count = cause.counts[day] ?? 0
            guard count > 0 else { return nil }
            if let proposed = cause.proposed, let since = Watch.day(day, offset: -AppHealth.proposeEvery), proposed.day > since {
                guard count >= max(2 * proposed.count, AppHealth.doubledFrom) else { return nil }
                return "doubled again since it was proposed for \(proposed.day) (\(proposed.count) → \(count) a day)"
            }
            let span = (0..<AppHealth.repeatSpan).compactMap { Watch.day(day, offset: -$0) }
            let daysSeen = span.filter { (cause.counts[$0] ?? 0) > 0 }.count
            let before = Watch.day(day, offset: -1).flatMap { cause.counts[$0] } ?? 0
            if before > 0, count >= 2 * before, count >= AppHealth.doubledFrom {
                return "doubled day over day (\(before) → \(count))"
            }
            if daysSeen >= AppHealth.repeatDays { return "seen on \(daysSeen) of the \(AppHealth.repeatSpan) days to \(day)" }
            return nil
        }

        /// The proposals when `day` closes, in one message (nil: none), the busiest first, at most `proposalsADay`;
        /// each proposed is marked so.
        public mutating func propose(closing day: String) -> String? {
            let due = byKey.compactMap { key, cause in why(cause, closing: day).map { (key, cause, $0) } }
                .sorted { ($0.1.counts[day] ?? 0, $1.0) > ($1.1.counts[day] ?? 0, $0.0) }
            guard !due.isEmpty else { return nil }
            let chosen = due.prefix(AppHealth.proposalsADay)
            var parts = ["VibeSwitcher's own logs show \(chosen.count == 1 ? "a cause that keeps" : "\(chosen.count) causes that keep") coming back, grouped by cause and counted by "
                         + "VibeSwitcher itself (no model; lines masked and redacted). One proposed task each; one already on the board needs nothing:"]
            for (index, (key, cause, why)) in chosen.enumerated() {
                parts.append(Self.proposal(index + 1, cause, why: why, closing: day))
                byKey[key]?.proposed = Cause.Proposal(day: day, count: cause.counts[day] ?? 0)
            }
            if due.count > chosen.count {
                parts.append("\(due.count - chosen.count) more \(due.count - chosen.count == 1 ? "cause comes" : "causes come") back too; proposed at the next day's close if still due.")
            }
            return Redaction.secrets(in: parts.joined(separator: "\n"))
        }

        static func proposal(_ number: Int, _ cause: Cause, why: String, closing day: String) -> String {
            let span = (0..<AppHealth.repeatSpan).reversed().compactMap { Watch.day(day, offset: -$0) }
            let counts = span.map { "\($0.dropFirst(5)) ×\(cause.counts[$0] ?? 0)" }.joined(separator: ", ")
            var lines = ["Proposed task \(number): \(cause.title)",
                         "  Cause: \(cause.what) (\(why)).",
                         "  Counts by day, \(span.first ?? day) to \(day): \(counts)."]
            switch cause.kind {
            case .freeze:
                lines.append("  Reports: first \(cause.first), last \(cause.last) in ~/.vibeswitcher/debug (.txt the sampled stacks, .log the state).")
                lines.append("  Stack (top first): \(cause.detail)")
            case .line, .notice:
                lines.append("  Lines: first at \(cause.first), last at \(cause.last) in ~/.vibeswitcher/debug/app.log (app.log.1 once it rotated).")
                lines.append("  Line, masked: \(cause.detail)")
            }
            return lines.joined(separator: "\n")
        }

        /// Days older than the span (and a week's margin for the cooldown) go; a cause with none left goes, unless
        /// still cooling down; past `causesKept`, the least recent go.
        public mutating func prune(today: String) {
            guard let oldest = Watch.day(today, offset: -(AppHealth.repeatSpan + 1)),
                  let cooling = Watch.day(today, offset: -AppHealth.proposeEvery) else { return }
            byKey = byKey.compactMapValues { cause in
                var cause = cause
                cause.counts = cause.counts.filter { $0.key >= oldest }
                return cause.counts.isEmpty && (cause.proposed?.day ?? "") <= cooling ? nil : cause
            }
            guard byKey.count > AppHealth.causesKept else { return }
            let ranked = byKey.sorted { a, b in
                let (lastA, lastB) = (a.value.counts.keys.max() ?? "", b.value.counts.keys.max() ?? "")
                return lastA != lastB ? lastA > lastB : a.value.counts.values.reduce(0, +) > b.value.counts.values.reduce(0, +)
            }
            byKey = Dictionary(uniqueKeysWithValues: ranked.prefix(AppHealth.causesKept).map { ($0.key, $0.value) })
        }
    }
}

extension AppHealth.Watch {
    /// The causes counted so far (`causeLog` is optional so a state file from before it decodes).
    public var causes: AppHealth.Causes {
        get { causeLog ?? AppHealth.Causes() }
        set { causeLog = newValue }
    }

    /// An app.log line's time on `now`'s day ("2026-11-08 14:02:10"), from its breadcrumb time, else `now`'s.
    static func lineTime(_ line: String, now: Date) -> String {
        let stamp = line.prefix { $0 != " " }
        let time = stamp.count >= 8 && stamp.first?.isNumber == true && stamp.contains(":") ? String(stamp.prefix(8)) : {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: now)
        }()
        return day(now) + " " + time
    }

    /// App.log lines' causes, counted on `now`'s day.
    mutating func countCauses(lines: [String], now: Date) {
        let today = Self.day(now)
        for line in lines {
            guard let (key, cause) = AppHealth.cause(ofLine: line, at: Self.lineTime(line, now: now)) else { continue }
            causes.count(key, cause, day: today)
        }
    }

    /// Freezes' causes, each counted on the day it began.
    mutating func countCauses(hangs: [AppHealth.Hang], now: Date) {
        for hang in hangs {
            guard let (key, cause) = AppHealth.cause(of: hang) else { continue }
            causes.count(key, cause, day: Self.day(hang.since ?? now))
        }
    }
}
