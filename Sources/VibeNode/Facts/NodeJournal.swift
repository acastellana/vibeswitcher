import Foundation
import VibeCore

/// One journal entry, as `journalctl -o json` gives it: every field by name, a binary one as its bytes' text.
public struct JournalEntry: Equatable, Sendable {
    public var fields: [String: String]

    public init(_ fields: [String: String]) { self.fields = fields }

    /// journald's own fields (it stamps them from the sender's credentials; no sender can write them).
    public var uid: uid_t? { fields["_UID"].flatMap { uid_t($0) } }
    public var cgroup: String? { fields["_SYSTEMD_CGROUP"] }
    public var time: Date? { fields["__REALTIME_TIMESTAMP"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000_000) } }
    /// What the sender says.
    public var identifier: String? { fields["SYSLOG_IDENTIFIER"] }
    public var message: String? { fields["MESSAGE"] }
    /// The command line's own fields (`NodeJournal.entry`).
    public var event: String? { fields["VIBESWITCHER_EVENT"] }
    public var action: String? { fields["VIBESWITCHER_ACTION"] }
    public var kind: String? { fields["VIBESWITCHER_KIND"] }
    public var epoch: String? { fields["VIBESWITCHER_EPOCH"] }
}

/// The journal, read and written by the command line (the engine plan's EN-D15, the security architecture document's
/// S2): the node unit's entries (systemd's start and stop lines, the host's stderr), the command line's own
/// (`SYSLOG_IDENTIFIER=vibeswitcher`), and the unit's state from `systemctl --user show`. An entry explains a start,
/// records an acknowledgment or records a request only when journald's own fields (`_UID`, `_SYSTEMD_CGROUP`) pass the
/// voice rule's scope list (`passes`): an identifier the entry carries is never enough. The server reports only what
/// it holds; what it says about itself is never the record.
public enum NodeJournal {
    /// The command line's `SYSLOG_IDENTIFIER`.
    public static let identifier = "vibeswitcher"
    /// How long before a start or stop an explaining entry may be.
    public static let explainWindow: TimeInterval = 120

    /// What happened to the node that the journal shows.
    public struct Event: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case start, stop, serverRestart = "server restart"
        }
        public var kind: Kind
        public var at: Date
        public init(kind: Kind, at: Date) {
            self.kind = kind
            self.at = at
        }
    }

    /// The node unit's state: how its last main process ended, and when it started.
    public struct UnitState: Equatable, Sendable {
        public var result: String?
        public var execMainStatus: String?
        public var execMainStartTimestamp: String?
    }

    // MARK: Reading

    /// The entries of a `journalctl -o json` text, one JSON object a line; a line that isn't one is passed over.
    public static func entries(json text: String) -> [JournalEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            var fields: [String: String] = [:]
            for (name, value) in object {
                if let text = value as? String {
                    fields[name] = text
                } else if let bytes = value as? [Any] {
                    let numbers = bytes.compactMap { ($0 as? NSNumber)?.uint8Value }
                    if numbers.count == bytes.count { fields[name] = String(decoding: numbers, as: UTF8.self) }
                } else if let number = value as? NSNumber {
                    fields[name] = number.stringValue
                }
            }
            return JournalEntry(fields)
        }
    }

    /// `systemctl --user show -p Result,ExecMainStatus,ExecMainStartTimestamp`'s `Name=value` lines.
    public static func unitState(show text: String) -> UnitState {
        var state = UnitState()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            switch line[..<equals] {
            case "Result": state.result = value
            case "ExecMainStatus": state.execMainStatus = value
            case "ExecMainStartTimestamp": state.execMainStartTimestamp = value
            default: break
            }
        }
        return state
    }

    /// The node's starts, stops and server restarts in `entries`: systemd's job lines for the node's unit
    /// (`JOB_TYPE=start|stop` with `JOB_RESULT=done`, its `UNIT` or `USER_UNIT` the node's), and the host's line for a
    /// server child that ended and is started again (stage 2's Task 8b). Ordered by time.
    public static func events(_ entries: [JournalEntry]) -> [Event] {
        entries.compactMap { entry -> Event? in
            guard let at = entry.time else { return nil }
            let unit = entry.fields["USER_UNIT"] ?? entry.fields["UNIT"]
            if unit == VoiceRule.nodeUnit, entry.fields["JOB_RESULT"] == "done" {
                switch entry.fields["JOB_TYPE"] {
                case "start": return Event(kind: .start, at: at)
                case "stop": return Event(kind: .stop, at: at)
                default: return nil
                }
            }
            if let message = entry.message, message.hasPrefix("vibeswitcher-host: server child pid"), message.contains(" ended after ") {
                return Event(kind: .serverRestart, at: at)
            }
            return nil
        }.sorted { $0.at < $1.at }
    }

    /// Whether `entry` counts: journald's `_UID` is the rule's user and its `_SYSTEMD_CGROUP` is one of the rule's
    /// terminal scopes (outside the user's manager and the node's unit).
    public static func passes(_ entry: JournalEntry, rule: VoiceRule) -> Bool {
        guard entry.uid == rule.uid, let cgroup = entry.cgroup, !rule.scopes.isEmpty else { return false }
        return rule.cgroupRefusal(["0::" + cgroup]) == nil
    }

    /// The command line's own entries that count (`passes`), of `event` (and `kind`, when given), in time order.
    static func own(_ entries: [JournalEntry], rule: VoiceRule, where wanted: (JournalEntry) -> Bool) -> [JournalEntry] {
        entries.filter { $0.identifier == identifier && wanted($0) && passes($0, rule: rule) }
            .sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
    }

    /// Each of `starts` no `vibeswitcher start` or `stop` entry explains: an explaining entry is the command line's
    /// record of a `start` or `stop` request (or a `start`/`stop` event of its own) at most `explainWindow` before the
    /// event and not after it, and counts only when it `passes`. A start, a stop or a server restart is explained alike
    /// (a `stop` ends the server, a `start` restarts it).
    public static func unexplained(starts: [Event], entries: [JournalEntry], rule: VoiceRule) -> [Event] {
        let explaining = own(entries, rule: rule) { entry in
            ["start", "stop"].contains(entry.event ?? "") || (entry.event == "request" && ["start", "stop"].contains(entry.kind ?? ""))
        }
        return starts.filter { event in
            !explaining.contains { entry in
                guard let at = entry.time else { return false }
                return at <= event.at && event.at.timeIntervalSince(at) <= explainWindow
            }
        }
    }

    /// Whether `event` was acknowledged: an `ack` entry of the command line's that `passes`, later than it.
    public static func acknowledged(_ event: Event, entries: [JournalEntry], rule: VoiceRule) -> Bool {
        own(entries, rule: rule) { $0.event == "ack" }.contains { ($0.time ?? .distantPast) > event.at }
    }

    /// What `status` marks (S3): an accepted request (`status`'s list from the server: its kind, action and time) that
    /// no journal entry records, and an entry of the command line's whose `_SYSTEMD_CGROUP` isn't a terminal scope (or
    /// whose user isn't the user). An entry records a request when it `passes` (a session's process can write any
    /// identifier and field with `logger -t vibeswitcher`: only journald's own fields say who sent it), its event is
    /// `request`, and its action and kind are the request's; given the server's `epoch` (`status`'s), its epoch is
    /// that one too (the command line writes the epoch of the server it asked).
    public static func marks(accepted: [(kind: String, action: String?, at: Date?)], epoch: String? = nil, entries: [JournalEntry],
                             rule: VoiceRule) -> [String] {
        var marks: [String] = []
        let recording = own(entries, rule: rule) { $0.event == "request" && (epoch == nil || $0.epoch == epoch) }
        let recorded = Set(recording.compactMap { entry in entry.action.flatMap { action in entry.kind.map { "\(action)|\($0)" } } })
        for request in accepted where !(request.action.map { recorded.contains("\($0)|\(request.kind)") } ?? false) {
            marks.append("the server accepted \(ConfigSeal.inert(request.kind, limit: 40))"
                         + (request.at.map { " at \(NodeWire.dateText($0))" } ?? "")
                         + " (action \(ConfigSeal.inert(request.action ?? "none", limit: 40))) and the journal has no entry for it")
        }
        for entry in entries where entry.identifier == identifier && !passes(entry, rule: rule) {
            marks.append("a journal entry of the command line's (\(ConfigSeal.inert(entry.event ?? "?", limit: 40))"
                         + (entry.time.map { " at \(NodeWire.dateText($0))" } ?? "")
                         + ") came from \(ConfigSeal.inert(entry.cgroup ?? "no cgroup", limit: 200)), not a terminal's")
        }
        return marks
    }

    // MARK: Writing

    /// The fields of an entry of the command line's: ids and hashes only (the journal is readable by the `adm` group:
    /// no answer text, goal or screen content). `event`: `request`, `ack`, `not-promised-ack`; `kind`: the request's;
    /// `digest`: the SHA-256 of what it asked, when it asked anything.
    public static func entry(event: String, action: String?, kind: String? = nil, digest: String? = nil,
                             epoch: String? = nil) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [("SYSLOG_IDENTIFIER", identifier), ("MESSAGE", "vibeswitcher \(event)" + (kind.map { " \($0)" } ?? "")),
                                                       ("VIBESWITCHER_EVENT", event)]
        if let action { fields.append(("VIBESWITCHER_ACTION", action)) }
        if let kind { fields.append(("VIBESWITCHER_KIND", kind)) }
        if let digest { fields.append(("VIBESWITCHER_DIGEST", digest)) }
        if let epoch { fields.append(("VIBESWITCHER_EPOCH", epoch)) }
        return fields
    }
}
