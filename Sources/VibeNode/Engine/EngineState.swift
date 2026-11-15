import Foundation
import VibeCore

/// The check a held `.user` message passes after a server restart (the engine plan's EN-D9): whether the vault's record
/// of the user's actions (EN-D11) holds the action that made it with the message's digest. E6 gives the vault's; until
/// then nothing passes it (`NoUserActions`).
public protocol UserActions: Sendable {
    /// Whether the record holds `action` with `digest` (`EngineState.digest`); nil when it can't be asked.
    func holds(action: String, digest: String) -> Bool?
}

/// No record of the user's actions: no held `.user` message is vouched for after a restart.
public struct NoUserActions: UserActions {
    public init() {}
    public func holds(action: String, digest: String) -> Bool? { nil }
}

/// The engine's own state file, `<root>/v2/engine.json` (format 1; the engine plan's EN-D9): what isn't the user's and
/// what a restarted server needs not to repeat itself. E5 keeps the held messages there; E8 adds the rest. Nothing in it
/// is taken as the user's: a worker of the user's uid can write it, so a held `.user` message goes as the user's after a
/// restart only when the vault's record of the user's actions holds the action id it carries with the digest of its
/// text as it is now (`restored`); otherwise it goes as VibeSwitcher's, saying it couldn't be vouched for.
public struct EngineState: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    /// A message held for a project's lead (`LeadStore.Held`), with the root it is for.
    public struct Held: Codable, Equatable, Sendable {
        public var root: String
        /// Its place among what was sent: held messages go in this order.
        public var order: Int
        public var text: String
        public var from: SteerMessage.Sender
        /// The action id of the user's request that made it (a `.user` message's), as the command line sent it.
        public var action: String?

        public init(root: String, order: Int, text: String, from: SteerMessage.Sender, action: String? = nil) {
            self.root = root
            self.order = order
            self.text = text
            self.from = from
            self.action = action
        }
    }

    public var format: Int
    /// In the order sent.
    public var held: [Held]

    public init(held: [Held] = []) {
        format = Self.currentFormat
        self.held = held
    }

    /// `<root>/v2/engine.json`.
    public static func url(root: URL) -> URL {
        root.appendingPathComponent("v2", isDirectory: true).appendingPathComponent("engine.json")
    }

    /// The state at `root`, and what was wrong with the file when it couldn't be taken (none: missing or read): a
    /// file that doesn't read, or of another format, is an empty state, and the problem says what was lost.
    public static func load(root: URL) -> (state: EngineState, problem: String?) {
        let url = url(root: root)
        guard let data = try? Data(contentsOf: url) else {
            let missing = !FileManager.default.fileExists(atPath: url.path)
            return (EngineState(), missing ? nil : "\(url.path) doesn't read: what it held is lost")
        }
        guard let state = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return (EngineState(), "\(url.path) isn't an engine state: what it held is lost")
        }
        guard state.format == currentFormat else {
            return (EngineState(), "\(url.path) is of format \(state.format), not \(currentFormat): what it held is lost")
        }
        return (state, nil)
    }

    /// Writes it at `root` (0600, in a 0700 `v2` folder), whole and renamed into place. A root that isn't there (its
    /// node removed) is never made again for it: that throws.
    public func save(root: URL) throws {
        let url = Self.url(root: root)
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path]) }
        try VibePaths.ensurePrivate(url.deletingLastPathComponent(), within: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try VibePaths.writePrivate(try encoder.encode(self), to: url)
    }

    /// A message's digest, as the vault's record of user actions keeps it: SHA-256 of its text, in hex.
    public static func digest(_ text: String) -> String { BuildInfo.sha256(of: Data(text.utf8)) }

    /// Who a held message that was marked as the user's but can't be vouched for goes as.
    public static let notVouchedSender = SteerMessage.Sender.system("vibeswitcher")

    /// What such a message says before its text.
    public static let notVouchedPrefix = "Held for you before this node's server restarted, marked as the user's, but it couldn't be "
        + "vouched for (no record of the user's request with this text), so it is not the user's word: "

    /// The held messages as they may go after a restart, in order: each `.user` one stays the user's only when
    /// `actions` holds its action with its text's digest now; any other goes as VibeSwitcher's (`notVouchedSender`),
    /// saying so, its action dropped. `notVouched`: how many went that way.
    public static func restored(_ held: [Held], actions: UserActions) -> (held: [Held], notVouched: Int) {
        var notVouched = 0
        let restored = held.sorted { $0.order < $1.order }.map { message -> Held in
            guard message.from == .user else { return message }
            if let action = message.action, actions.holds(action: action, digest: digest(message.text)) == true { return message }
            notVouched += 1
            return Held(root: message.root, order: message.order, text: notVouchedPrefix + message.text, from: notVouchedSender)
        }
        return (restored, notVouched)
    }
}
