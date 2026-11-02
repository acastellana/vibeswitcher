import Foundation

/// The requests VibeSwitcher has sent to the Wallet Manager, with the results it took for each: one `<id>.json` per request in
/// `folder` (0700), each written 0600 with `VibePaths.writePrivate`, so they outlive a restart. A record is written
/// before its request goes out (`sending`), and removed only when passage says it didn't go.
public final class WalletRequestStore: @unchecked Sendable {
    public enum State: String, Equatable, Sendable {
        /// Written just before `passage send`: kept as outstanding if the app stopped meanwhile, since it may have gone.
        case sending
        /// `passage send` said it was delivered.
        case sent
        /// `passage send` failed in a way that doesn't say whether the Wallet Manager has it (exit 1, a signal, out of time):
        /// still outstanding, and it may be sent again with the same id (the Wallet Manager acts on an id once).
        case unsure
    }

    public struct Record: Equatable, Sendable {
        public var request: WalletRequest
        public var state: State
        /// The results taken, in the order of their `sequence`.
        public var results: [WalletResult]
        /// The inbox files they came from (`passage inbox`'s paths), never read again.
        public var inboxFiles: [String]
        /// When `passage send` first said it was delivered (whole seconds), so "not picked up" outlives a restart. Nil
        /// before that, and in a record from before it was kept.
        public var sentAt: Date?

        public init(request: WalletRequest, state: State, results: [WalletResult] = [], inboxFiles: [String] = [], sentAt: Date? = nil) {
            self.request = request
            self.state = state
            self.results = results
            self.inboxFiles = inboxFiles
            self.sentAt = sentAt.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        }

        /// The Wallet Manager's last word was final: nothing more is taken for it.
        public var finished: Bool { results.last?.status.isFinal == true }
        public var lastSequence: Int64 { results.last?.sequence ?? 0 }
    }

    /// The most a record file may hold, as for the request and result files themselves: a request and its results
    /// are small. A record that would be larger isn't written (`save` throws), and a file larger isn't read.
    static let maxRecordBytes = WalletRequestFormat.maxFileBytes
    /// How long a record is kept after its request's results window (`expiresAt` + `WalletCourier.resultGrace`):
    /// `prune` removes it then.
    public static let keptAfterWindow: TimeInterval = 30 * 24 * 3600

    public let folder: URL

    public init(folder: URL = VibePaths.walletRequestsDir) {
        self.folder = folder
    }

    public func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// Every record in the folder, oldest request first. A file that isn't a record (a link, not a regular file, over
    /// 64 KiB, unreadable, not the format, a name that isn't `<id>.json` of its own request) is left where it is and
    /// named to `log`. With `now`, a record whose request's `createdAt` isn't believable then
    /// (`WalletRequest.implausibleTime`) is left out too, and named.
    public func load(now: Date? = nil, log: (String) -> Void = { _ in }) -> [Record] {
        var records: [Record] = []
        for (name, id) in recordFiles() {
            do {
                let record = try read(file(id))
                guard record.request.id == id else { throw WalletRequestFormat.Failure.invalid("request.id", "isn't the file's name") }
                if let now, let why = record.request.implausibleTime(now: now) {
                    log("left \(name) out: \(why)")
                    continue
                }
                records.append(record)
            } catch {
                log("kept \(name) aside: it isn't a request record (\(error))")
            }
        }
        return records.sorted { ($0.request.createdAt, $0.request.id) < ($1.request.createdAt, $1.request.id) }
    }

    /// The `<id>.json` files in the folder, by name, with their ids.
    private func recordFiles() -> [(name: String, id: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(".json".count))
            return WalletRequestFormat.isID(id) ? (name, id) : nil
        }
    }

    /// Removes the records past their request's results window by `keptAfterWindow` (at launch), and returns their
    /// ids. A file that isn't a record is left as it is.
    @discardableResult
    public func prune(now: Date, log: (String) -> Void = { _ in }) -> [String] {
        var removed: [String] = []
        for (name, id) in recordFiles() {
            guard let record = try? read(file(id)), record.request.id == id else { continue }
            let end = record.request.expiresAt.addingTimeInterval(WalletCourier.resultGrace + Self.keptAfterWindow)
            guard now >= end else { continue }
            remove(id)
            removed.append(id)
            log("removed \(name): its results window ended over 30 days ago")
        }
        return removed
    }

    /// Writes the record (0600, in the 0700 folder). Throws, writing nothing, when it would be over 64 KiB.
    public func save(_ record: Record) throws {
        let data = Self.encode(record)
        guard data.count <= Self.maxRecordBytes else { throw WalletRequestFormat.Failure.tooLarge(data.count) }
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(data, to: file(record.request.id))
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    // MARK: The former folder

    /// Carries the requests over from `old` (`~/.vibeswitcher/vault-requests`, the folder's name while the feature
    /// was called vault requests) to `new`, their former `type`s renamed (`renameTypes`), then removes `old`: the
    /// whole folder in one move when `new` isn't there yet, else entry by entry, keeping what `new` already has. Nothing to do once `old` is gone, so it runs once.
    /// On a failure `old` stays (what was moved stays moved) for the next launch, and the error is thrown.
    public static func carryOver(from old: URL = VibePaths.formerVaultRequestsDir,
                                 to new: URL = VibePaths.walletRequestsDir) throws {
        guard kind(old) != nil else { return }
        try renameTypes(in: old)
        try move(old, into: new)
    }

    /// The `type`s the formats had while they were vault-request and vault-result v1, and theirs now.
    static let formerTypes = ["vibeswitcher.vault-request": WalletRequest.type, "vibeswitcher.vault-result": WalletResult.type]

    /// Every `.json` file under `folder` (a filed request, or a record with its request and results) written again
    /// with the former `type`s renamed, and nothing else changed, so the readers, which take only the new ones, read
    /// it as before. A file that isn't JSON, or holds no former type, is left as it is.
    private static func renameTypes(in folder: URL) throws {
        if kind(folder) == .typeDirectory {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                try renameTypes(in: folder.appendingPathComponent(name))
            }
        } else if kind(folder) == .typeRegular, folder.pathExtension == "json",
                  let data = try? Data(contentsOf: folder), data.count <= maxRecordBytes,
                  let value = try? WalletRequestFormat.Value.parse(data) {
            let renamed = renameTypes(value)
            if renamed != value { try VibePaths.writePrivate(renamed.encoded(), to: folder) }
        }
    }

    static func renameTypes(_ value: WalletRequestFormat.Value) -> WalletRequestFormat.Value {
        switch value {
        case .object(let members):
            return .object(members.map { member in
                if member.key == "type", case let .string(type) = member.value, let now = formerTypes[type] {
                    return .init(member.key, .string(now))
                }
                return .init(member.key, renameTypes(member.value))
            })
        case .array(let values): return .array(values.map(renameTypes))
        default: return value
        }
    }

    private static func move(_ old: URL, into new: URL) throws {
        let manager = FileManager.default
        guard let existing = kind(new) else { return try manager.moveItem(at: old, to: new) }
        if existing == .typeDirectory, kind(old) == .typeDirectory {
            for name in try manager.contentsOfDirectory(atPath: old.path) {
                try move(old.appendingPathComponent(name), into: new.appendingPathComponent(name))
            }
        }
        try manager.removeItem(at: old)
    }

    /// The item's type, without following a link; nil when there's nothing there.
    private static func kind(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    // MARK: The file

    static func encode(_ record: Record) -> Data {
        var members: [WalletRequestFormat.Value.Member] = [
            .init("request", record.request.value), .init("state", .string(record.state.rawValue)),
            .init("results", .array(record.results.map(\.value))), .init("inboxFiles", .array(record.inboxFiles.map { .string($0) })),
        ]
        if let sentAt = record.sentAt { members.append(.init("sentAt", .string(WalletRequestFormat.string(sentAt)))) }
        return WalletRequestFormat.Value.object(members).encoded()
    }

    /// A record file: opened without following a link (O_NOFOLLOW), only a regular file, its size checked before
    /// anything is read (64 KiB at most), then the strict parser.
    func read(_ url: URL) throws -> Record {
        let data = try WalletAsk.read(url)
        let fields = try WalletRequestFormat.Fields(WalletRequestFormat.Value.parse(data), path: "", allowed: ["request", "state", "results", "inboxFiles", "sentAt"])
        let request = try WalletRequest.read(fields.value("request"), path: "request")
        guard let state = State(rawValue: try fields.string("state")) else { throw WalletRequestFormat.Failure.invalid("state", "sending, sent or unsure") }
        let results = try fields.array("results").enumerated().map { try WalletResult.read($0.element, path: "results[\($0.offset)]") }
        let files = try fields.array("inboxFiles").map { value -> String in
            guard case let .string(path) = value else { throw WalletRequestFormat.Failure.wrongType("inboxFiles", "strings") }
            return path
        }
        let sentAt = try fields.optionalString("sentAt").map { try WalletRequestFormat.date($0, field: "sentAt") }
        return Record(request: request, state: state, results: results, inboxFiles: files, sentAt: sentAt)
    }
}
