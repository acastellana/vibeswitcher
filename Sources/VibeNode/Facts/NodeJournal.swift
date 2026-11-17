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
///
/// journald reads a writer's cgroup from `/proc/<pid>` when it takes the datagram, so an entry whose writer had ended
/// by then has no `_SYSTEMD_CGROUP` (measured, the bootstrap path's M4, 2026-11-17: `logger`'s entry had none). Such
/// an entry of the user's uid never counts (`passes` fails closed: any process of the user's can write one and end),
/// and is said for what it is (`hasNoCgroup`, `noCgroupSaid`), not as an entry from another cgroup. So that the
/// command line's own entries don't end so, it stays until journald has each (`awaitEntry`).
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
        /// A start's host line (`startLine`, the start plan's S5): what follows `vibeswitcher-host: started ` (its pid,
        /// build and `SWIFT_BACKTRACE`), with " (not checked)" after it for an earlier invocation's; nil when none is
        /// taken, and for a stop or a server restart.
        public var detail: String?
        public init(kind: Kind, at: Date, detail: String? = nil) {
            self.kind = kind
            self.at = at
            self.detail = detail
        }
    }

    /// The node unit's state: how its last main process ended, and when it started.
    public struct UnitState: Equatable, Sendable {
        public var result: String?
        public var execMainStatus: String?
        public var execMainStartTimestamp: String?
        /// The unit's main process now, or its last (`ExecMainPID`; nil for 0, none since the manager started).
        public var execMainPID: Int32?
    }

    // MARK: Reading

    /// The arguments of each `journalctl` run the command line reads the journal with (`NodeContext.journalEntries`):
    /// the node unit's entries, then its own (`SYSLOG_IDENTIFIER`), each from the user's journal as JSON and each
    /// matched on `_UID=<uid>` too. The user's journal lists the user's own entries without that match (measured, the
    /// bootstrap path's M4, 2026-11-17), and `--user -u` matches the unit's entries by the user already: the match
    /// narrows the read to the user's wherever a journal holds more, and changes nothing that counts (`passes` asks
    /// for the user's `_UID`).
    public static func readArguments(uid: uid_t) -> [[String]] {
        [["-u", VoiceRule.nodeUnit], ["SYSLOG_IDENTIFIER=\(identifier)"]].map {
            ["--user", "-o", "json", "--no-pager"] + $0 + ["_UID=\(uid)"]
        }
    }

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

    /// `systemctl --user show -p Result,ExecMainStatus,ExecMainStartTimestamp,ExecMainPID`'s `Name=value` lines.
    public static func unitState(show text: String) -> UnitState {
        var state = UnitState()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            switch line[..<equals] {
            case "Result": state.result = value
            case "ExecMainStatus": state.execMainStatus = value
            case "ExecMainStartTimestamp": state.execMainStartTimestamp = value
            case "ExecMainPID": state.execMainPID = Int32(value).flatMap { $0 > 0 ? $0 : nil }
            default: break
            }
        }
        return state
    }

    /// The host's start line's opening (`HostStartLine`, the start plan's S5): `<this><pid> build <commit|unknown>
    /// SWIFT_BACKTRACE=<value|unset>`.
    public static let startLine = "vibeswitcher-host: started pid "

    /// The newest start line of the host `pid` in a detached host's log (`NodeStarter.hostLog`, where its stderr goes:
    /// no journal, ST-D6), as what follows `vibeswitcher-host: started `; nil when the log holds none. The log is the
    /// user's file and any worker's to write, so nothing vouches for the line (the review of S8c, 2026-11-16).
    public static func hostLogStart(_ log: String, pid: pid_t) -> String? {
        let opening = startLine + "\(pid) "
        return log.split(whereSeparator: \.isNewline).last { $0.hasPrefix(opening) }
            .map { String($0.dropFirst("vibeswitcher-host: started ".count)) }
    }

    /// The node's starts, stops and server restarts in `entries`: systemd's job lines for the node's unit
    /// (`JOB_TYPE=start|stop` with `JOB_RESULT=done`, its `UNIT` or `USER_UNIT` the node's), and the host's line for a
    /// server child that ended and is started again (stage 2's Task 8b). Ordered by time.
    ///
    /// Each start carries the host's start line as its `detail` (ST-D24). Every session is in the unit's cgroup, so a
    /// `logger -t vibeswitcher-host` from a worker lands under the unit too: a line counts only when journald's
    /// trusted fields say the host could have sent it: `_TRANSPORT` is `stdout` (the host's stderr, as the unit gives
    /// it), `_UID` is `uid`, the sender was in the node's unit (`_SYSTEMD_USER_UNIT`, else the last part of
    /// `_SYSTEMD_CGROUP`), its `_BOOT_ID` is its start's, and it came at its start or after (the host writes it after its
    /// start's job line). For the last start, also only when its trusted `_PID` is the unit's `mainPID` (`ExecMainPID`;
    /// a handover keeps the pid, so the newest such line is the build that runs now). The pid alone isn't enough: with
    /// `Restart=no` the unit's `ExecMainPID` names a dead pid once the host ends, which another process can be given,
    /// and the journal holds every boot's lines (the review of S5). An earlier start's pid can't be checked any more:
    /// the newest such line between it and the next start is shown, said "(not checked)". Without `mainPID` and `uid`,
    /// no line is taken.
    public static func events(_ entries: [JournalEntry], mainPID: Int32? = nil, uid: uid_t? = nil) -> [Event] {
        let found = entries.compactMap { entry -> (event: Event, boot: String?)? in
            guard let at = entry.time else { return nil }
            let unit = entry.fields["USER_UNIT"] ?? entry.fields["UNIT"]
            if unit == VoiceRule.nodeUnit, entry.fields["JOB_RESULT"] == "done" {
                switch entry.fields["JOB_TYPE"] {
                case "start": return (Event(kind: .start, at: at), entry.fields["_BOOT_ID"])
                case "stop": return (Event(kind: .stop, at: at), nil)
                default: return nil
                }
            }
            if let message = entry.message, message.hasPrefix("vibeswitcher-host: server child pid"), message.contains(" ended after ") {
                return (Event(kind: .serverRestart, at: at), nil)
            }
            return nil
        }.sorted { $0.event.at < $1.event.at }
        var events = found.map(\.event)
        guard let mainPID, let uid else { return events }
        let lines = entries.compactMap { entry -> (at: Date, pid: Int32?, boot: String?, text: String)? in
            guard entry.fields["_TRANSPORT"] == "stdout", entry.uid == uid,
                  (entry.fields["_SYSTEMD_USER_UNIT"] ?? entry.cgroup.map { ($0 as NSString).lastPathComponent }) == VoiceRule.nodeUnit,
                  let at = entry.time, let message = entry.message, message.hasPrefix(startLine) else { return nil }
            return (at, entry.fields["_PID"].flatMap { Int32($0) }, entry.fields["_BOOT_ID"],
                    String(message.dropFirst("vibeswitcher-host: started ".count)))
        }.sorted { $0.at < $1.at }
        let starts = events.indices.filter { events[$0].kind == .start }
        for (order, index) in starts.enumerated() {
            let from = events[index].at, boot = found[index].boot
            if order == starts.count - 1 {
                // The invocation that runs now (or ran last): its main pid's newest line from its start on.
                events[index].detail = lines.last { $0.pid == mainPID && $0.boot == boot && $0.at >= from }.map(\.text)
            } else {
                let until = events[starts[order + 1]].at
                events[index].detail = lines.last { $0.boot == boot && $0.at >= from && $0.at < until }.map { $0.text + " (not checked)" }
            }
        }
        return events
    }

    /// Whether `entry` counts: journald's `_UID` is the rule's user and its `_SYSTEMD_CGROUP` is one of the rule's
    /// terminal scopes (outside the user's manager and the node's unit).
    public static func passes(_ entry: JournalEntry, rule: VoiceRule) -> Bool {
        guard entry.uid == rule.uid, let cgroup = entry.cgroup, !rule.scopes.isEmpty else { return false }
        return rule.cgroupRefusal(["0::" + cgroup]) == nil
    }

    /// Whether `entry` is one of the user's uid that journald recorded no cgroup for: its writer had ended before
    /// journald read `/proc/<pid>/cgroup` (a command that exits right after its datagram, as `logger` does). It doesn't
    /// pass: nothing says where it came from, and any process of the user's can write one so.
    public static func hasNoCgroup(_ entry: JournalEntry, rule: VoiceRule) -> Bool {
        entry.uid == rule.uid && entry.cgroup == nil
    }

    /// What `status` and the command line say of such an entry.
    public static let noCgroupSaid = "journald recorded no cgroup (the writer ended first)"

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
    ///
    /// An entry of the user's uid with no `_SYSTEMD_CGROUP` (`hasNoCgroup`) is marked too, since it doesn't count, but
    /// as what it is, `noCgroupSaid`, never as "came from no cgroup, not a terminal's": and an accepted request whose
    /// only entry is such a one is said to have that entry, not none (once, not once for the request and again for
    /// the entry). The words vouch for nothing: who wrote such an entry can't be told.
    public static func marks(accepted: [(kind: String, action: String?, at: Date?)], epoch: String? = nil, entries: [JournalEntry],
                             rule: VoiceRule) -> [String] {
        var marks: [String] = []
        let recording = own(entries, rule: rule) { $0.event == "request" && (epoch == nil || $0.epoch == epoch) }
        let recorded = Set(recording.compactMap { entry in entry.action.flatMap { action in entry.kind.map { "\(action)|\($0)" } } })
        let uncounted = entries.filter {
            $0.identifier == identifier && hasNoCgroup($0, rule: rule) && $0.event == "request" && (epoch == nil || $0.epoch == epoch)
        }
        var said: [JournalEntry] = []
        for request in accepted where !(request.action.map { recorded.contains("\($0)|\(request.kind)") } ?? false) {
            let its = uncounted.filter { $0.action != nil && $0.action == request.action && $0.kind == request.kind }
            said += its
            marks.append("the server accepted \(ConfigSeal.inert(request.kind, limit: 40))"
                         + (request.at.map { " at \(NodeWire.dateText($0))" } ?? "")
                         + " (action \(ConfigSeal.inert(request.action ?? "none", limit: 40))) and "
                         + (its.isEmpty ? "the journal has no entry for it" : "its journal entry isn't counted as yours: \(noCgroupSaid)"))
        }
        for entry in entries where entry.identifier == identifier && !passes(entry, rule: rule) && !said.contains(entry) {
            let what = "a journal entry of the command line's (\(ConfigSeal.inert(entry.event ?? "?", limit: 40))"
                + (entry.time.map { " at \(NodeWire.dateText($0))" } ?? "") + ")"
            marks.append(hasNoCgroup(entry, rule: rule) ? what + " isn't counted as yours: \(noCgroupSaid)"
                         : what + " came from \(ConfigSeal.inert(entry.cgroup ?? "no cgroup", limit: 200)), not a terminal's")
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

    /// The field the command line names each entry it sends by: a nonce of its own, so it can find that entry again.
    public static let entryField = "VIBESWITCHER_ENTRY"

    /// The `journalctl` arguments that read the one entry sent with `nonce` (`NodeContext.writeJournal`, on the
    /// user's node): the user's journal, as JSON, matched on the nonce and the user's `_UID`.
    public static func entryArguments(nonce: String, uid: uid_t) -> [String] {
        ["--user", "-o", "json", "--no-pager", "\(entryField)=\(nonce)", "_UID=\(uid)"]
    }

    /// What became of an entry the command line sent.
    public enum Written: Equatable, Sendable {
        /// The journal holds it, with the cgroup journald read for its writer.
        case recorded
        /// The journal holds it, but journald recorded no cgroup for it: it will never count.
        case noCgroup
        /// The journal didn't show it within the wait.
        case missing
    }

    /// What `entries` say of the entry sent with `nonce`; nil while none of them is it.
    public static func written(nonce: String, in entries: [JournalEntry]) -> Written? {
        let sent = entries.filter { $0.fields[entryField] == nonce }
        guard !sent.isEmpty else { return nil }
        return sent.allSatisfy { $0.cgroup != nil } ? .recorded : .noCgroup
    }

    /// Waits until the journal holds the entry sent with `nonce`, so the command line is still there when journald
    /// reads its `/proc/<pid>/cgroup`: journald stamps `_SYSTEMD_CGROUP` as it takes the datagram, and a writer gone by
    /// then leaves an entry that never counts (the type's comment). `read` gives the journal's entries now (nil when
    /// it can't be read this time), and is asked again every `pause` until the entry is there or `patience` has
    /// passed on `awake` (seconds awake). A poll on what it waits for, never a fixed sleep: it returns as soon as the
    /// entry is read, and journald writes an entry once, so one found without a cgroup is not waited on.
    public static func awaitEntry(nonce: String, patience: TimeInterval, pause: TimeInterval, awake: () -> TimeInterval,
                                  sleep: (TimeInterval) -> Void, read: () -> [JournalEntry]?) -> Written {
        let deadline = awake() + patience
        while true {
            if let found = read().flatMap({ written(nonce: nonce, in: $0) }) { return found }
            guard awake() < deadline else { return .missing }
            sleep(pause)
        }
    }

    /// What the command line says when an entry it sent won't count (nil when it will): `event` is the entry's.
    public static func notCounted(_ written: Written, event: String, patience: TimeInterval) -> String? {
        switch written {
        case .recorded: return nil
        case .noCgroup:
            return "the journal entry for this (\(ConfigSeal.inert(event, limit: 40))) isn't counted as yours: \(noCgroupSaid)"
        case .missing:
            return "the journal entry for this (\(ConfigSeal.inert(event, limit: 40))) was sent, but the journal didn't show it within "
                + "\(Int(patience)) s, so it isn't taken as written"
        }
    }
}
