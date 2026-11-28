import Foundation
import VibeCore

/// The journal's acknowledgment as a kind (`journal.ack`, the no-terminal inventory's C9, decision N6; group G3 of
/// v2-remaining): the user's voice, the typed code, then the vault's record of the action (`Requests.voiced`, before the
/// act), which is the acknowledgment's record: N6's "recorded in the vault as the user's". The act writes nothing more.
///
/// **It writes no journal entry, and doesn't clear the marks yet, by design** (the blind check of G3, 2026-11-27). An
/// acknowledgment in the journal counts only when journald stamps it with a terminal scope's cgroup
/// (`NodeJournal.passes`, `acknowledged`): any process of the user's can write an entry, and only journald's own fields
/// say who sent it. An entry the server wrote would come from the node's unit, so it would never count, and
/// `NodeJournal.marks` would say on every `status` that an entry of the command line's came from a cgroup not a
/// terminal's (the forged-entry alarm of the 2026-11-17 review), a line no ack clears. So the server never writes one.
/// What makes this record count is the device keys track's slices 14 and 15: the reader (`NodeJournal.acknowledged`,
/// `status`) taking the vault's record of a `journal.ack` made under the device's key with a biometric of its own, with
/// its security review. Until then `vibeswitcher status --ack` in a terminal clears the marks, and the reply says so.
///
/// **A guarded change, not a page's yet** (`KindSpec`: `.terminalOnly`): it clears marks that say a start or a request
/// nobody explained.
extension WireKinds {
    public enum JournalAck: WireChangeKind {
        public static let kind = "journal.ack"
        public typealias Args = WireNoArgs
        /// `recorded`: where the acknowledgment is kept (`vault`); `counts`: whether `status` counts it yet (false until
        /// slices 14–15, above); `said`: that, in words.
        public struct Result: Codable, Sendable, Equatable {
            public var recorded: String?
            public var counts: Bool?
            public var said: String?
            public init(recorded: String, counts: Bool, said: String) {
                self.recorded = recorded
                self.counts = counts
                self.said = said
            }
        }
    }
}

/// The acknowledgment's entry, the command line's and the server's alike.
public enum JournalAck {
    /// The journal entry of an acknowledgment under `action`: ids only (`NodeJournal.entry`).
    public static func entry(action: String) -> [(name: String, value: String)] { NodeJournal.entry(event: "ack", action: action) }

    /// What the typed code acknowledges.
    public static let what = "This acknowledges the starts, stops and restarts the journal shows."

    /// What the server's reply says.
    public static let serverSaid = "recorded in the vault as yours; `vibeswitcher status` doesn't count it yet (the device keys track's slices 14 and 15 "
        + "change its reader), so the marks stay until `vibeswitcher status --ack` in a terminal"
}

/// Writes an entry to the journal and stays until the journal holds it (`NodeJournal.awaitEntry`): journald stamps
/// `_SYSTEMD_CGROUP` as it takes the datagram, and a writer gone by then leaves an entry that never counts. The entry
/// carries a nonce (`NodeJournal.entryField`) and is looked for again every `pause`, up to `patience`. The command
/// line's (`NodeContext.writeJournal`, `status --ack` among its entries); never the server's (`journal.ack` above).
public struct JournalWriter: Sendable {
    /// Sends one datagram of `fields`: true when it went.
    public var send: @Sendable ([(name: String, value: String)]) -> Bool
    /// The journal's entries that carry the nonce, as it holds them now; nil when it can't be read this time.
    public var read: @Sendable (String) -> [JournalEntry]?
    public var patience: TimeInterval
    public var pause: TimeInterval

    public init(send: @escaping @Sendable ([(name: String, value: String)]) -> Bool, read: @escaping @Sendable (String) -> [JournalEntry]?,
                patience: TimeInterval, pause: TimeInterval) {
        self.send = send
        self.read = read
        self.patience = patience
        self.pause = pause
    }

    /// What became of `fields` once sent; nil when the datagram didn't go.
    public func write(_ fields: [(name: String, value: String)]) -> NodeJournal.Written? {
        let nonce = UUID().uuidString.lowercased()
        guard send(fields + [(NodeJournal.entryField, nonce)]) else { return nil }
        return NodeJournal.awaitEntry(nonce: nonce, patience: patience, pause: pause, awake: MacTime.real.awake,
                                      sleep: { usleep(useconds_t($0 * 1_000_000)) }, read: { read(nonce) })
    }
}

extension Requests {
    /// `journal.ack`: its record, the vault's, made already (`voiced`); answered with where it is kept and that `status`
    /// doesn't count it yet. No journal entry is written (the type's comment). On `queue`.
    func journalAck(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        reply(.init(re: request.id, typed: WireKinds.JournalAck.Result(recorded: "vault", counts: false, said: JournalAck.serverSaid)))
    }
}
