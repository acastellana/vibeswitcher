import Foundation

/// A transaction VibeSwitcher asks the Wallet Manager to check, propose and have signed: wallet-request v1
/// (docs/protocol/wallet-request.md). VibeSwitcher only initiates: nothing here signs or holds a key.
public struct WalletRequest: Equatable, Sendable {
    public static let type = "vibeswitcher.wallet-request"
    public static let version: Int64 = 1
    /// How long a request stands by default: 24 hours.
    public static let defaultLifetime: TimeInterval = 24 * 3600
    /// The longest a request may stand: 7 days.
    public static let maxLifetime: TimeInterval = 7 * 24 * 3600
    /// The largest chain id the format takes: 2^53 − 1, exact in every JSON reader.
    public static let maxChainID: Int64 = 9_007_199_254_740_991
    /// The most calldata a call carries: 24 KiB, as 0x and 49 152 hex digits.
    public static let maxDataBytes = 24 * 1024

    public enum Action: String, Equatable, Sendable, CaseIterable {
        /// Moves `amount` of `asset` (the chain's own coin, or an ERC-20 token) to `to`.
        case transfer
        /// Calls the contract `to` with `data`, sending `amount` of the chain's own coin with it.
        case call
    }

    /// Who asked: the project and session VibeSwitcher started the request from, and a label for people.
    public struct Requester: Equatable, Sendable {
        public var project: String
        public var session: String
        public var label: String
        public init(project: String, session: String, label: String) {
            self.project = project
            self.session = session
            self.label = label
        }
    }

    /// A lower-case UUID: the request's name in every file and result.
    public var id: String
    public var createdAt: Date
    public var expiresAt: Date
    public var requestedBy: Requester
    /// Which of the Wallet Manager's workspaces to use: an opaque name the Wallet Manager knows.
    public var workspace: String
    /// The wallet to send from, in that workspace: its id there, or its 0x address. The Wallet Manager resolves its kind (a
    /// hardware wallet, a hot wallet whose encrypted key the Wallet Manager holds, or a Safe).
    public var from: String
    public var chainId: Int64
    public var action: Action
    public var to: String
    /// "native", or the 0x address of a token contract.
    public var asset: String
    /// In the asset's base units (wei for the chain's coin), as a decimal string.
    public var amount: String
    /// 0x calldata: only, and always, with `call`.
    public var data: String?
    /// Why, in the requester's words: shown to the person who signs.
    public var reason: String

    public init(id: String = UUID().uuidString.lowercased(), createdAt: Date, expiresAt: Date, requestedBy: Requester,
                workspace: String, from: String, chainId: Int64, action: Action, to: String, asset: String, amount: String,
                data: String? = nil, reason: String) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.requestedBy = requestedBy
        self.workspace = workspace
        self.from = from
        self.chainId = chainId
        self.action = action
        self.to = to
        self.asset = asset
        self.amount = amount
        self.data = data
        self.reason = reason
    }

    /// A new request made `now` (to the whole second), standing `lifetime`.
    public static func make(now: Date = Date(), lifetime: TimeInterval = defaultLifetime, requestedBy: Requester, workspace: String,
                            from: String, chainId: Int64, action: Action, to: String, asset: String, amount: String,
                            data: String? = nil, reason: String) -> WalletRequest {
        let created = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        return WalletRequest(createdAt: created, expiresAt: created.addingTimeInterval(lifetime), requestedBy: requestedBy,
                            workspace: workspace, from: from, chainId: chainId, action: action, to: to, asset: asset,
                            amount: amount, data: data, reason: reason)
    }

    /// The name the request travels under: `wallet-request-<id>.json`.
    public static func fileName(_ id: String) -> String { "wallet-request-\(id).json" }

    // MARK: Reading

    static let fields = ["type", "version", "id", "createdAt", "expiresAt", "requestedBy", "workspace", "from", "chainId",
                         "action", "to", "asset", "amount", "data", "reason"]

    /// Parses a request file, refusing anything the format doesn't allow (`WalletRequestFormat.Failure`).
    public static func parse(_ data: Data) throws -> WalletRequest {
        try read(WalletRequestFormat.document(data))
    }

    /// A request from its JSON value, checked field by field and then as a whole.
    public static func read(_ value: WalletRequestFormat.Value, path: String = "") throws -> WalletRequest {
        let fields = try WalletRequestFormat.Fields(value, path: path, allowed: Self.fields)
        guard try fields.string("type") == type else { throw WalletRequestFormat.Failure.invalid(fields.name("type"), "must be \(type)") }
        guard try fields.integer("version") == version else { throw WalletRequestFormat.Failure.invalid(fields.name("version"), "must be 1") }
        let id = try fields.string("id")
        guard WalletRequestFormat.isID(id) else { throw WalletRequestFormat.Failure.invalid(fields.name("id"), "must be a lower-case UUID") }
        let created = try WalletRequestFormat.date(fields.string("createdAt"), field: fields.name("createdAt"))
        let expires = try WalletRequestFormat.date(fields.string("expiresAt"), field: fields.name("expiresAt"))
        let lifetime = expires.timeIntervalSince(created)
        guard lifetime > 0, lifetime <= maxLifetime else {
            throw WalletRequestFormat.Failure.invalid(fields.name("expiresAt"), "must be after createdAt, by 7 days at most")
        }
        let by = try WalletRequestFormat.Fields(fields.value("requestedBy"), path: fields.name("requestedBy"), allowed: ["project", "session", "label"])
        let requester = Requester(project: try by.string("project"), session: try by.string("session"), label: try by.string("label"))
        try WalletRequestFormat.checkRequester(requester.project, field: by.name("project"), minimum: 1)
        try WalletRequestFormat.checkRequester(requester.session, field: by.name("session"), minimum: 1)
        try WalletRequestFormat.checkRequester(requester.label, field: by.name("label"), minimum: 0)
        let workspace = try fields.string("workspace")
        guard WalletRequestFormat.isName(workspace) else {
            throw WalletRequestFormat.Failure.invalid(fields.name("workspace"), "must be 1-64 of A-Z a-z 0-9 . _ - starting with a letter or digit")
        }
        let from = try fields.string("from")
        if from.lowercased().hasPrefix("0x") {
            guard WalletRequestFormat.isAddress(from) else { throw WalletRequestFormat.Failure.invalid(fields.name("from"), "must be 0x and 40 hex digits") }
        } else if !WalletRequestFormat.isName(from) {
            throw WalletRequestFormat.Failure.invalid(fields.name("from"), "must be a wallet id (1-64 of A-Z a-z 0-9 . _ -) or 0x and 40 hex digits")
        }
        let chain = try fields.integer("chainId")
        guard chain >= 1, chain <= maxChainID else { throw WalletRequestFormat.Failure.invalid(fields.name("chainId"), "must be 1 to 2^53-1") }
        guard let action = Action(rawValue: try fields.string("action")) else {
            throw WalletRequestFormat.Failure.invalid(fields.name("action"), "must be transfer or call")
        }
        let to = try fields.string("to")
        guard WalletRequestFormat.isAddress(to) else { throw WalletRequestFormat.Failure.invalid(fields.name("to"), "must be 0x and 40 hex digits") }
        let asset = try fields.string("asset")
        guard asset == "native" || WalletRequestFormat.isAddress(asset) else {
            throw WalletRequestFormat.Failure.invalid(fields.name("asset"), "must be native or 0x and 40 hex digits")
        }
        let amount = try fields.string("amount")
        guard isAmount(amount) else {
            throw WalletRequestFormat.Failure.invalid(fields.name("amount"), "must be base units as decimal digits, no leading zero, 60 digits at most")
        }
        let data = try fields.optionalString("data")
        switch action {
        case .transfer:
            guard data == nil else { throw WalletRequestFormat.Failure.invalid(fields.name("data"), "only a call carries data") }
            guard amount != "0" else { throw WalletRequestFormat.Failure.invalid(fields.name("amount"), "a transfer moves more than 0") }
        case .call:
            guard let data else { throw WalletRequestFormat.Failure.missingField(fields.name("data")) }
            guard isCalldata(data) else {
                throw WalletRequestFormat.Failure.invalid(fields.name("data"), "must be 0x and whole bytes of hex, 4 to \(maxDataBytes)")
            }
            guard asset == "native" else { throw WalletRequestFormat.Failure.invalid(fields.name("asset"), "a call sends only native") }
        }
        let reason = try fields.string("reason")
        try WalletRequestFormat.checkReason(reason, field: fields.name("reason"))
        let request = WalletRequest(id: id, createdAt: created, expiresAt: expires, requestedBy: requester, workspace: workspace,
                                   from: from, chainId: chain, action: action, to: to, asset: asset, amount: amount, data: data,
                                   reason: reason)
        try request.screen(path: path)
        return request
    }

    /// Refuses a request any of whose text fields (all but `data`, which is made of 32-byte words) looks like key material.
    func screen(path: String) throws {
        let texts: [(String, String)] = [("id", id), ("requestedBy.project", requestedBy.project),
                                         ("requestedBy.session", requestedBy.session), ("requestedBy.label", requestedBy.label),
                                         ("workspace", workspace), ("from", from), ("to", to), ("asset", asset), ("amount", amount),
                                         ("reason", reason)]
        for (field, text) in texts { try WalletRequestFormat.screen(text, field: WalletRequestFormat.name(field, in: path)) }
    }

    static func isAmount(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...60).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        return bytes.count == 1 || bytes[0] != UInt8(ascii: "0")
    }

    static func isCalldata(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let digits = bytes.count - 2
        return bytes.count >= 2 && bytes[0] == UInt8(ascii: "0") && bytes[1] == UInt8(ascii: "x") && digits % 2 == 0
            && (8...2 * maxDataBytes).contains(digits) && bytes[2...].allSatisfy(WalletRequestFormat.isHex)
    }

    // MARK: Writing

    /// The request as its JSON value, fields in the documented order.
    public var value: WalletRequestFormat.Value {
        var members: [WalletRequestFormat.Value.Member] = [
            .init("type", .string(Self.type)), .init("version", .integer(Self.version)), .init("id", .string(id)),
            .init("createdAt", .string(WalletRequestFormat.string(createdAt))), .init("expiresAt", .string(WalletRequestFormat.string(expiresAt))),
            .init("requestedBy", .object([.init("project", .string(requestedBy.project)), .init("session", .string(requestedBy.session)),
                                          .init("label", .string(requestedBy.label))])),
            .init("workspace", .string(workspace)), .init("from", .string(from)), .init("chainId", .integer(chainId)),
            .init("action", .string(action.rawValue)), .init("to", .string(to)), .init("asset", .string(asset)),
            .init("amount", .string(amount)),
        ]
        if let data { members.append(.init("data", .string(data))) }
        members.append(.init("reason", .string(reason)))
        return .object(members)
    }

    /// The request file's bytes, once they parse back to this very request: what doesn't is refused as the parser
    /// would refuse it (a bad field, key material, a time with a fraction of a second, over 64 KiB).
    public func encoded() throws -> Data {
        let data = value.encoded()
        let back = try Self.parse(data)
        guard back == self else { throw WalletRequestFormat.Failure.invalid("createdAt", "times are whole seconds") }
        return data
    }

    /// Past `expiresAt`: the Wallet Manager no longer acts on it.
    public func isExpired(now: Date) -> Bool { now >= expiresAt }

    /// How far ahead of this Mac's clock a `createdAt` may be (a clock a little off), and how far behind it.
    public static let maxAheadOfClock: TimeInterval = 5 * 60
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Why its `createdAt` isn't believable now: more than `maxAheadOfClock` in the future, or older than `maxAge`
    /// with its results window (`expiresAt` + `WalletCourier.resultGrace`) over too, so a 7-day request still takes
    /// a result in its last hour. Nil when it is. Such a request is refused when filed or sent, and its record isn't
    /// loaded.
    public func implausibleTime(now: Date) -> String? {
        if createdAt.timeIntervalSince(now) > Self.maxAheadOfClock {
            return "its createdAt \(WalletRequestFormat.string(createdAt)) is more than 5 minutes ahead of this Mac's clock"
        }
        if now.timeIntervalSince(createdAt) > Self.maxAge, now >= expiresAt.addingTimeInterval(WalletCourier.resultGrace) { return "its createdAt \(WalletRequestFormat.string(createdAt)) is more than 7 days ago" }
        return nil
    }
}

/// What the Wallet Manager says about a request: wallet-result v1 (docs/protocol/wallet-request.md). A
/// request gets several, numbered by `sequence`, until one with a final status.
public struct WalletResult: Equatable, Sendable {
    public static let type = "vibeswitcher.wallet-result"
    public static let version: Int64 = 1
    public static let maxChecks = 64
    public static let maxSequence: Int64 = 1000

    public enum Status: String, Equatable, Sendable, CaseIterable {
        /// The Wallet Manager has the request and it parsed; checks are under way.
        case received
        /// Refused: a check failed, or the person declined. Final.
        case rejected
        /// Built and shown to the person for signing.
        case proposed
        /// Signed on the hardware wallet, not yet submitted.
        case signed
        /// Sent to the chain: `txHash` says which transaction. Final.
        case submitted
        /// Something went wrong after it was accepted (the signing, the submission, a reverted transaction). Final.
        case failed

        /// After this one nothing more comes for the request.
        public var isFinal: Bool { self == .rejected || self == .submitted || self == .failed }
    }

    /// One check the Wallet Manager ran on the request.
    public struct Check: Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String
        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    /// The request's id.
    public var id: String
    /// 1 for the Wallet Manager's first result on the request, then one more for each.
    public var sequence: Int64
    public var createdAt: Date
    public var status: Status
    public var checks: [Check]
    public var txHash: String?
    public var safeTxHash: String?
    public var explorerURL: String?
    public var message: String

    public init(id: String, sequence: Int64, createdAt: Date, status: Status, checks: [Check] = [], txHash: String? = nil,
                safeTxHash: String? = nil, explorerURL: String? = nil, message: String) {
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.status = status
        self.checks = checks
        self.txHash = txHash
        self.safeTxHash = safeTxHash
        self.explorerURL = explorerURL
        self.message = message
    }

    /// The name a result travels under: `wallet-result-<id>.json`.
    public static func fileName(_ id: String) -> String { "wallet-result-\(id).json" }

    /// The id in a result file's name, or nil when the name isn't `wallet-result-<id>.json`.
    public static func id(fromFileName name: String) -> String? {
        guard name.hasPrefix("wallet-result-"), name.hasSuffix(".json") else { return nil }
        let id = String(name.dropFirst("wallet-result-".count).dropLast(".json".count))
        return WalletRequestFormat.isID(id) ? id : nil
    }

    static let fields = ["type", "version", "id", "sequence", "createdAt", "status", "checks", "txHash", "safeTxHash",
                         "explorerURL", "message"]

    /// Parses a result file, refusing anything the format doesn't allow (`WalletRequestFormat.Failure`).
    public static func parse(_ data: Data) throws -> WalletResult {
        try read(WalletRequestFormat.document(data))
    }

    public static func read(_ value: WalletRequestFormat.Value, path: String = "") throws -> WalletResult {
        let fields = try WalletRequestFormat.Fields(value, path: path, allowed: Self.fields)
        guard try fields.string("type") == type else { throw WalletRequestFormat.Failure.invalid(fields.name("type"), "must be \(type)") }
        guard try fields.integer("version") == version else { throw WalletRequestFormat.Failure.invalid(fields.name("version"), "must be 1") }
        let id = try fields.string("id")
        guard WalletRequestFormat.isID(id) else { throw WalletRequestFormat.Failure.invalid(fields.name("id"), "must be a lower-case UUID") }
        let sequence = try fields.integer("sequence")
        guard sequence >= 1, sequence <= maxSequence else { throw WalletRequestFormat.Failure.invalid(fields.name("sequence"), "must be 1 to 1000") }
        let created = try WalletRequestFormat.date(fields.string("createdAt"), field: fields.name("createdAt"))
        guard let status = Status(rawValue: try fields.string("status")) else {
            throw WalletRequestFormat.Failure.invalid(fields.name("status"), "must be one of " + Status.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let list = try fields.array("checks")
        guard list.count <= maxChecks else { throw WalletRequestFormat.Failure.invalid(fields.name("checks"), "more than \(maxChecks) checks") }
        var checks: [Check] = []
        for (index, item) in list.enumerated() {
            let check = try WalletRequestFormat.Fields(item, path: fields.name("checks[\(index)]"), allowed: ["name", "ok", "detail"])
            let entry = Check(name: try check.string("name"), ok: try check.bool("ok"), detail: try check.string("detail"))
            try WalletRequestFormat.checkText(entry.name, field: check.name("name"), limit: 100)
            try WalletRequestFormat.checkText(entry.detail, field: check.name("detail"), minimum: 0, limit: 1000, multiline: true)
            checks.append(entry)
        }
        let tx = try fields.optionalString("txHash")
        let safeTx = try fields.optionalString("safeTxHash")
        for (key, hash) in [("txHash", tx), ("safeTxHash", safeTx)] {
            if let hash, !WalletRequestFormat.isHash(hash) { throw WalletRequestFormat.Failure.invalid(fields.name(key), "must be 0x and 64 hex digits") }
        }
        if status == .submitted, tx == nil { throw WalletRequestFormat.Failure.missingField(fields.name("txHash")) }
        if tx != nil, status != .submitted, status != .failed {
            throw WalletRequestFormat.Failure.invalid(fields.name("txHash"), "only submitted or failed carry a transaction hash")
        }
        if safeTx != nil, status == .received || status == .rejected {
            throw WalletRequestFormat.Failure.invalid(fields.name("safeTxHash"), "not before proposed")
        }
        let explorer = try fields.optionalString("explorerURL")
        if let explorer {
            guard tx != nil || safeTx != nil else { throw WalletRequestFormat.Failure.invalid(fields.name("explorerURL"), "only with a hash") }
            try checkExplorer(explorer, field: fields.name("explorerURL"), hashes: [tx, safeTx].compactMap { $0 })
        }
        let message = try fields.string("message")
        try WalletRequestFormat.checkText(message, field: fields.name("message"), minimum: 0, limit: 2000, multiline: true)
        let result = WalletResult(id: id, sequence: sequence, createdAt: created, status: status, checks: checks, txHash: tx,
                                 safeTxHash: safeTx, explorerURL: explorer, message: message)
        // Key material in any text but the hashes; the link is checked against them above.
        try WalletRequestFormat.screen(message, field: fields.name("message"))
        for (index, check) in checks.enumerated() {
            try WalletRequestFormat.screen(check.name, field: fields.name("checks[\(index)].name"))
            try WalletRequestFormat.screen(check.detail, field: fields.name("checks[\(index)].detail"))
        }
        return result
    }

    /// An https link of at most 2000 characters, with a host and no user or password, no whitespace or control
    /// character; any run of 64 hex digits in it is one of `hashes` (the link names the transaction).
    static func checkExplorer(_ link: String, field: String, hashes: [String]) throws {
        guard link.utf8.count <= 2000, link.hasPrefix("https://"), link.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
              let parts = URLComponents(string: link), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else {
            throw WalletRequestFormat.Failure.invalid(field, "must be an https link with a host, no user or password, printable ASCII, 2000 characters at most")
        }
        if link.contains("-----BEGIN") { throw WalletRequestFormat.Failure.keyMaterial(field, "a -----BEGIN block") }
        let known = Set(hashes.map { $0.dropFirst(2).lowercased() })
        var run: [UInt8] = []
        for byte in Array(link.utf8) + [0] {
            if WalletRequestFormat.isHex(byte) { run.append(byte); continue }
            if run.count >= 64, !known.contains(String(decoding: run, as: UTF8.self).lowercased()) {
                throw WalletRequestFormat.Failure.keyMaterial(field, "64 or more hex digits in a row that are neither hash")
            }
            run = []
        }
    }

    public var value: WalletRequestFormat.Value {
        var members: [WalletRequestFormat.Value.Member] = [
            .init("type", .string(Self.type)), .init("version", .integer(Self.version)), .init("id", .string(id)),
            .init("sequence", .integer(sequence)), .init("createdAt", .string(WalletRequestFormat.string(createdAt))),
            .init("status", .string(status.rawValue)),
            .init("checks", .array(checks.map { .object([.init("name", .string($0.name)), .init("ok", .bool($0.ok)),
                                                         .init("detail", .string($0.detail))]) })),
        ]
        if let txHash { members.append(.init("txHash", .string(txHash))) }
        if let safeTxHash { members.append(.init("safeTxHash", .string(safeTxHash))) }
        if let explorerURL { members.append(.init("explorerURL", .string(explorerURL))) }
        members.append(.init("message", .string(message)))
        return .object(members)
    }

    /// The result file's bytes, once they parse back to this very result.
    public func encoded() throws -> Data {
        let data = value.encoded()
        guard try Self.parse(data) == self else { throw WalletRequestFormat.Failure.invalid("createdAt", "times are whole seconds") }
        return data
    }
}
