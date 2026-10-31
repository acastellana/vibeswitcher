import Foundation

/// The requests VibeSwitcher has sent to the vault, with the results it took for each: one `<id>.json` per request in
/// `folder` (0700), each written 0600 with `VibePaths.writePrivate`, so they outlive a restart. A record is written
/// before its request goes out (`sending`), and removed only when passage says it didn't go.
public final class VaultStore: @unchecked Sendable {
    public enum State: String, Equatable, Sendable {
        /// Written just before `passage send`: kept as outstanding if the app stopped meanwhile, since it may have gone.
        case sending
        /// `passage send` said it was delivered.
        case sent
        /// `passage send` failed in a way that doesn't say whether the vault has it (exit 1, a signal, out of time):
        /// still outstanding, and it may be sent again with the same id (the vault acts on an id once).
        case unsure
    }

    public struct Record: Equatable, Sendable {
        public var request: VaultRequest
        public var state: State
        /// The results taken, in the order of their `sequence`.
        public var results: [VaultResult]
        /// The inbox files they came from (`passage inbox`'s paths), never read again.
        public var inboxFiles: [String]

        public init(request: VaultRequest, state: State, results: [VaultResult] = [], inboxFiles: [String] = []) {
            self.request = request
            self.state = state
            self.results = results
            self.inboxFiles = inboxFiles
        }

        /// The vault's last word was final: nothing more is taken for it.
        public var finished: Bool { results.last?.status.isFinal == true }
        public var lastSequence: Int64 { results.last?.sequence ?? 0 }
    }

    /// The most a record file may hold: results are small, and a request gets at most `VaultResult.maxSequence`.
    static let maxRecordBytes = 4 * 1024 * 1024

    public let folder: URL

    public init(folder: URL = VibePaths.vaultRequestsDir) {
        self.folder = folder
    }

    public func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// Every record in the folder, oldest request first. A file that isn't a record (unreadable, not the format, a
    /// name that isn't `<id>.json` of its own request) is left where it is and named to `log`.
    public func load(log: (String) -> Void = { _ in }) -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var records: [Record] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let id = String(name.dropLast(".json".count))
            guard VaultFormat.isID(id) else { continue }
            do {
                let record = try read(file(id))
                guard record.request.id == id else { throw VaultFormat.Failure.invalid("request.id", "isn't the file's name") }
                records.append(record)
            } catch {
                log("kept \(name) aside: it isn't a request record (\(error))")
            }
        }
        return records.sorted { ($0.request.createdAt, $0.request.id) < ($1.request.createdAt, $1.request.id) }
    }

    public func save(_ record: Record) throws {
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(Self.encode(record), to: file(record.request.id))
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    // MARK: The file

    static func encode(_ record: Record) -> Data {
        VaultFormat.Value.object([
            .init("request", record.request.value), .init("state", .string(record.state.rawValue)),
            .init("results", .array(record.results.map(\.value))), .init("inboxFiles", .array(record.inboxFiles.map { .string($0) })),
        ]).encoded()
    }

    func read(_ url: URL) throws -> Record {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxRecordBytes else { throw VaultFormat.Failure.tooLarge(data.count) }
        let fields = try VaultFormat.Fields(VaultFormat.Value.parse(data), path: "", allowed: ["request", "state", "results", "inboxFiles"])
        let request = try VaultRequest.read(fields.value("request"), path: "request")
        guard let state = State(rawValue: try fields.string("state")) else { throw VaultFormat.Failure.invalid("state", "sending, sent or unsure") }
        let results = try fields.array("results").enumerated().map { try VaultResult.read($0.element, path: "results[\($0.offset)]") }
        let files = try fields.array("inboxFiles").map { value -> String in
            guard case let .string(path) = value else { throw VaultFormat.Failure.wrongType("inboxFiles", "strings") }
            return path
        }
        return Record(request: request, state: state, results: results, inboxFiles: files)
    }
}
