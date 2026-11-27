import Foundation
import VibeCore

/// The journal's acknowledgment as a kind (`journal.ack`, the no-terminal inventory's C9, decision N6; group G3 of
/// v2-remaining): the entry `vibeswitcher status --ack` writes (`JournalAck.entry`), written by the node's server through
/// the same writer the command line uses (`JournalWriter`), after the user's voice, the typed code and the vault's record
/// of the action.
///
/// **It doesn't clear the marks yet, by design.** An acknowledgment counts only when journald stamps it with a terminal
/// scope's cgroup (`NodeJournal.passes`, `acknowledged`): any process of the user's can write an entry, and only
/// journald's own fields say who sent it. The server's entry comes from the node's unit, so today's reader doesn't count
/// it, and `status` marks it "not a terminal's". What would make a page's acknowledgment count (the vault's record of
/// the action, made under the device's key with a biometric of its own, N6) is the device keys track's slices 14 and 15,
/// with the reader's change and its security review; until then `vibeswitcher status --ack` in a terminal is the one
/// that clears them, and the reply says so.
///
/// **A guarded change, not a page's yet** (`KindSpec`: `.terminalOnly`): it clears marks that say a start or a request
/// nobody explained.
extension WireKinds {
    public enum JournalAck: WireChangeKind {
        public static let kind = "journal.ack"
        public typealias Args = WireNoArgs
        /// `written`: what the journal shows of the entry (`recorded`); `counts`: whether `status` counts it as an
        /// acknowledgment (false for the server's, above); `said`: that, in words.
        public struct Result: Codable, Sendable, Equatable {
            public var written: String?
            public var counts: Bool?
            public var said: String?
            public init(written: String, counts: Bool, said: String) {
                self.written = written
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

    /// What the server's reply says of the entry it wrote.
    public static let serverSaid = "written to the journal by the node's server; `vibeswitcher status` counts only an acknowledgment from a terminal "
        + "(journald names the writer's cgroup), so the marks stay until `vibeswitcher status --ack` in a terminal: a page's acknowledgment "
        + "is the device keys track's (slices 14 and 15)"
}

/// Writes an entry to the journal and stays until the journal holds it (`NodeJournal.awaitEntry`): journald stamps
/// `_SYSTEMD_CGROUP` as it takes the datagram, and a writer gone by then leaves an entry that never counts. The entry
/// carries a nonce (`NodeJournal.entryField`) and is looked for again every `pause`, up to `patience`. The command
/// line's (`NodeContext.writeJournal`) and the server's (`Requests.journalWriter`); `send` and `read` are the system's
/// journal there, a scratch journal in a test.
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

    /// The user's node's: the system's journal socket, read back with `journalctl --user` on the nonce (`journalctl`, by
    /// its fixed path, with the node's tools' environment).
    public static func system(journalctl: String, uid: uid_t = getuid()) -> JournalWriter {
        let environment = NodeStarter.environment(runtimeFolder: NodeFolders.runtimeFolder(uid: uid))
        return JournalWriter(send: { Platform.Journal.send($0) }, read: { nonce in
            NodeStarter.run(journalctl, NodeJournal.entryArguments(nonce: nonce, uid: uid), environment: environment, timeout: 5)
                .map { NodeJournal.entries(json: $0.output) }
        }, patience: 5, pause: 0.02)
    }
}

extension Requests {
    /// `journal.ack`: the acknowledgment's entry under this request's action, through `journalWriter` (off `queue`, it
    /// waits for the journal). On `queue`.
    func journalAck(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let action = request.action?.lowercased() else {
            return reply(.init(re: request.id, error: .init(.badArgs, "journal.ack needs an action id (a UUID)")))
        }
        guard let writer = journalWriter else {
            return reply(.init(re: request.id, error: .init(.refused, "this server has no journal to write to: `vibeswitcher status --ack` in a terminal acknowledges")))
        }
        let queue = self.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let written = writer.write(JournalAck.entry(action: action))
            queue.async {
                switch written {
                case nil:
                    reply(.init(re: request.id, error: .init(.internal, "the acknowledgment couldn't be sent to the journal")))
                case .recorded?:
                    reply(.init(re: request.id, typed: WireKinds.JournalAck.Result(written: "recorded", counts: false, said: JournalAck.serverSaid)))
                case let other?:
                    let why = NodeJournal.notCounted(other, event: "ack", patience: writer.patience) ?? "the journal didn't take it"
                    reply(.init(re: request.id, error: .init(.internal, why)))
                }
            }
        }
    }
}
