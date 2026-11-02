import Foundation
import VibeCore

/// The wallet desk's messages for asking sessions that haven't reached them yet: one file per request, `<id>.json`
/// (0600) in `folder` (0700), each the request's messages in the order they were told. A message is written here before
/// it's handed to the session (so a quit, a crash or a session that isn't live loses nothing) and removed once
/// `LeadController.tell` says it reached the agent's inbox; the desk tries the rest again at each look. Beside the
/// requests' records (`WalletRequestStore`), not in the folder agents file requests into.
///
/// Any process of the user's can write here, so each entry carries the session host's seal (`seal`, the vault's key
/// that outlives restarts, over `sealed(for:)`): the desk hands over an entry read from disk only once the host
/// confirms it, and removes one it says no to. A message told in this run is trusted from memory (sealed as soon as
/// the host can be asked), never from its file.
struct WalletOutbox {
    struct Entry: Codable, Equatable {
        /// Unique among the request's messages ("expired", "no-answer", "result-2", …): the same message told again (an
        /// expiry noticed again at the next look, before the first telling went) is kept once.
        var key: String
        /// The asking session's id, lower case.
        var session: String
        var text: String
        /// The request's results window ends (`expiresAt` + `WalletCourier.resultGrace`): past this, with its session
        /// found ended, it's dropped (one that couldn't go yet stays until it goes).
        var until: Date
        /// What's recorded once it reached the agent (never before: a message that didn't go is told again).
        var marker: Marker?
        /// It was handed to the session at least once.
        var tried = false
        /// The last try found its session ended: its card says the agent didn't get it.
        var ended = false
        /// The session host's seal on `sealed(for:)`; nil until the host could be asked.
        var seal: String?

        /// What the host seals for this entry of request `id`: VibeSwitcher's own message ("wallet outbox", never a
        /// sender a session's messages use) whose id names the request and key, whose time is the window's end, and
        /// whose text holds the session, the marker and the message. Moving it to another request, key or session,
        /// or changing any of these, breaks the seal. `tried` and `ended` are left out: they change at each try.
        func sealed(for id: String) -> SteerMessage {
            let fields = [session, marker?.rawValue ?? "", text]
            let body = (try? JSONEncoder().encode(fields)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return SteerMessage(id: "wallet-outbox/\(id)/\(key)", text: body, from: .system(WalletOutbox.sender), agentPid: 0,
                                at: until.timeIntervalSince1970)
        }
    }

    /// The sender an outbox entry is sealed as.
    static let sender = "wallet outbox"


    enum Marker: String, Codable {
        /// `WalletAsk.markToldExpired`: the request expired unsent.
        case toldExpired
        /// The browser mark's `noAnswer`: no answer came back from the browser wallet.
        case noAnswer
    }

    /// The most one request's file holds (a few messages of a few KiB each).
    static let maxFileBytes = 1 << 20

    let folder: URL

    func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// Every request's messages, by id. A file that isn't one (a name that isn't a request id, a link, too big, not
    /// the format) is left where it is and named to `log`.
    func load(log: (String) -> Void = { _ in }) -> [String: [Entry]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var all: [String: [Entry]] = [:]
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(".json".count))
            guard WalletRequestFormat.isID(id) else { continue }
            do {
                let entries = try read(file(id))
                if !entries.isEmpty { all[id] = entries }
            } catch {
                log("kept undelivered/\(name) aside: \(error)")
            }
        }
        return all
    }

    /// Writes a request's messages, or removes its file when there are none left.
    func save(_ entries: [Entry], for id: String) throws {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: file(id))
            return
        }
        try VibePaths.ensurePrivate(folder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try VibePaths.writePrivate(encoder.encode(entries), to: file(id))
    }

    private func read(_ url: URL) throws -> [Entry] {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WalletAsk.Refusal("can't open it: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WalletAsk.Refusal("it isn't a regular file") }
        guard info.st_size <= Self.maxFileBytes else { throw WalletAsk.Refusal("it's \(info.st_size) bytes") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = try decoder.decode([Entry].self, from: try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data())
        guard entries.allSatisfy({ UUID(uuidString: $0.session) != nil }) else { throw WalletAsk.Refusal("a session isn't a session id") }
        return entries
    }
}
