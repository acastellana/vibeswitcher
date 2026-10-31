import Foundation

/// How an agent in a session VibeSwitcher started asks for a transaction: `vs-vault request …` (Resources/bin, on every
/// session's PATH; it runs `vibeswitcher-mcp --request-transaction …`). The request is checked by the same strict parser
/// the vault uses and filed, 0600, in `folder`; the app shows it as a card in the asking session's chat, and nothing
/// goes to the vault until the user presses Send to vault there. The vault's answer comes back to the session as a
/// message. Nothing here sends, signs or reads a key.
public enum VaultAsk {
    /// Where filed requests wait for the user: `~/.vibeswitcher/vault-requests/asked/<id>.json`, each the request's own
    /// bytes (vault-request v1).
    public static var folder: URL { VibePaths.vaultRequestsDir.appendingPathComponent("asked", isDirectory: true) }

    public static let usage = """
        usage: vs-vault request --workspace NAME --from WALLET --chain ID --to ADDRESS --amount BASE_UNITS --reason TEXT
                                [--asset native|TOKEN_ADDRESS] [--data 0xCALLDATA] [--expires-in 24h] [--label TEXT]

        Files a transaction request from this session. It shows as a card in this session's chat in VibeSwitcher;
        nothing is sent until the user presses Send to vault there. The vault Mac checks it and the user signs it
        there; VibeSwitcher never signs. The vault's answers come back to this session as messages.

          --workspace   the vault's workspace the wallet is in
          --from        the wallet to send from: its id in that workspace, or its 0x address
          --chain       the chain id (1 Ethereum, 42424242 GenLayer, 4221 GenLayer testnet)
          --to          the recipient (a transfer) or the contract called (with --data): 0x and 40 hex digits
          --amount      in the asset's base units (wei for the native coin), decimal digits
          --asset       native (the default) or a token contract's 0x address (an ERC-20 transfer)
          --data        calldata: makes it a contract call (its asset native; its amount the value sent, 0 allowed)
          --reason      why, in your words: shown to the person who signs (up to 1000 characters)
          --expires-in  how long it stands if not acted on: 90m, 24h (the default), 3d; 7d at most
          --label       a label for people (the session's name, say)
        Never put a key, seed or recovery phrase in any field: such text is refused.
        """

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The request the arguments (after `request`) ask for, made `now` in the session `environment` names; refused with
    /// the parser's reason (the field and its rule) for anything the format doesn't take.
    public static func request(_ arguments: [String], environment: [String: String], cwd: String, now: Date = Date()) throws -> VaultRequest {
        guard let session = environment["VIBESWITCHER_SESSION"], let id = UUID(uuidString: session) else {
            throw Refusal("this isn't a session VibeSwitcher started (no VIBESWITCHER_SESSION): run it from the agent's session in VibeSwitcher")
        }
        var values: [String: String] = [:]
        let known = ["--workspace", "--from", "--chain", "--to", "--amount", "--asset", "--data", "--reason", "--expires-in", "--label"]
        var words = arguments.makeIterator()
        while let word = words.next() {
            guard known.contains(word) else { throw Refusal("unknown option \(word)\n\n\(usage)") }
            guard let value = words.next() else { throw Refusal("\(word) needs a value") }
            guard values[word] == nil else { throw Refusal("\(word) is given twice") }
            values[word] = value
        }
        for required in ["--workspace", "--from", "--chain", "--to", "--amount", "--reason"] where values[required] == nil {
            throw Refusal("\(required) is required\n\n\(usage)")
        }
        guard let chain = Int64(values["--chain"]!), String(chain) == values["--chain"] else {
            throw Refusal("chainId: must be 1 to 2^53-1 (--chain takes the chain id's digits)")
        }
        let lifetime = try values["--expires-in"].map(duration) ?? VaultRequest.defaultLifetime
        let data = values["--data"]
        let project = (cwd as NSString).lastPathComponent
        let request = VaultRequest.make(now: now, lifetime: lifetime,
                                        requestedBy: .init(project: project.isEmpty ? "/" : project, session: id.uuidString.lowercased(),
                                                           label: values["--label"] ?? ""),
                                        workspace: values["--workspace"]!, from: values["--from"]!, chainId: chain,
                                        action: data == nil ? .transfer : .call, to: values["--to"]!, asset: values["--asset"] ?? "native",
                                        amount: values["--amount"]!, data: data, reason: values["--reason"]!)
        // The very checks the vault makes: the bytes filed are the bytes that go.
        do {
            _ = try request.encoded()
        } catch let failure as VaultFormat.Failure {
            throw Refusal(failure.description)
        }
        return request
    }

    /// "90m", "24h", "3d", "3600s" (or bare seconds), up to 7 days.
    static func duration(_ text: String) throws -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
        let unit = text.last.flatMap { units[$0] }
        let digits = unit == nil ? text : String(text.dropLast())
        guard let count = Int(digits), count > 0, String(count) == digits else {
            throw Refusal("--expires-in: a whole number of s, m, h or d (90m, 24h, 3d)")
        }
        let seconds = TimeInterval(count) * (unit ?? 1)
        guard seconds <= VaultRequest.maxLifetime else { throw Refusal("expiresAt: must be after createdAt, by 7 days at most") }
        return seconds
    }

    /// Files `request` for the app: `<folder>/<id>.json`, 0600 in a 0700 folder.
    public static func file(_ request: VaultRequest, in folder: URL = VaultAsk.folder) throws {
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(request.encoded(), to: folder.appendingPathComponent("\(request.id).json"))
    }

    /// The requests filed in `folder`, oldest first, each checked again by the strict parser (the folder is a file
    /// anyone's shell can write). One that doesn't parse, or whose id isn't its name's, is named in `refused`.
    public static func filed(in folder: URL = VaultAsk.folder) -> (requests: [VaultRequest], refused: [(file: URL, why: String)]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var requests: [VaultRequest] = []
        var refused: [(URL, String)] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name)
            do {
                let data = try read(file)
                let request = try VaultRequest.parse(data)
                guard "\(request.id).json" == name else { throw Refusal("its id \(request.id) isn't its name's") }
                requests.append(request)
            } catch {
                refused.append((file, "\(error)"))
            }
        }
        return (requests.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }, refused)
    }

    /// A regular file's bytes (no link followed), 64 KiB at most.
    static func read(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Refusal("can't open \(file.lastPathComponent): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Refusal("\(file.lastPathComponent) isn't a regular file") }
        guard info.st_size <= VaultFormat.maxFileBytes else { throw VaultFormat.Failure.tooLarge(Int(info.st_size)) }
        return try handle.read(upToCount: VaultFormat.maxFileBytes + 1) ?? Data()
    }

    /// Removes a filed request (sent, discarded, or refused), and its expiry note's marker.
    public static func remove(_ id: String, in folder: URL = VaultAsk.folder) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: expiryMarker(id, in: folder))
    }

    /// Beside a filed request that expired unsent, once its agent was told (`.<id>.expired`: `filed` reads no
    /// dot-file), so a restarted app doesn't tell it again.
    static func expiryMarker(_ id: String, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(id).expired")
    }

    /// Whether the asking agent was told that request `id` expired unsent.
    public static func toldExpired(_ id: String, in folder: URL = VaultAsk.folder) -> Bool {
        FileManager.default.fileExists(atPath: expiryMarker(id, in: folder).path)
    }

    /// Records that the asking agent was told that request `id` expired unsent. False when it couldn't be recorded.
    @discardableResult
    public static func markToldExpired(_ id: String, in folder: URL = VaultAsk.folder) -> Bool {
        (try? VibePaths.writePrivate(Data(), to: expiryMarker(id, in: folder))) != nil
    }

    /// What the asking session hears when its request reached its expiry without the user sending it.
    public static func expiredUnsent(_ request: VaultRequest) -> String {
        "Vault request \(request.id) expired at \(VaultFormat.string(request.expiresAt)) without being sent: the user didn't "
            + "click Send to vault on its card, so it never reached the vault and nothing was signed. If the transaction is "
            + "still needed, tell the user, or file a new request with vs-vault request."
    }

    /// `vs-vault request …`, as the CLI runs it: what to print, and the exit status (0 filed, 1 refused, 2 usage).
    /// `peerChosen`: whether Settings › Vault names the vault peer (until then requests are refused).
    public static func run(_ arguments: [String], environment: [String: String], cwd: String, peerChosen: Bool,
                           folder: URL = VaultAsk.folder, now: Date = Date()) -> (status: Int32, output: String, error: String) {
        guard let command = arguments.first, command == "request" else {
            return arguments.first.map { ["help", "--help", "-h"].contains($0) } == true ? (0, usage, "") : (2, "", usage)
        }
        guard peerChosen else {
            return (1, "", "vs-vault: refused: no vault peer is chosen in VibeSwitcher's Settings › Vault, so vault requests are refused. Ask the user to choose one.")
        }
        do {
            let request = try request(Array(arguments.dropFirst()), environment: environment, cwd: cwd, now: now)
            try file(request, in: folder)
            return (0, "Filed vault request \(request.id): it waits on its card in this session's chat in VibeSwitcher, and nothing is sent "
                       + "until the user presses Send to vault there. It expires at \(VaultFormat.string(request.expiresAt)). "
                       + "The vault's answers will come to this session as messages; don't file it again.", "")
        } catch let refusal as Refusal {
            return (1, "", "vs-vault: refused: \(refusal.description)")
        } catch {
            return (1, "", "vs-vault: refused: \(error)")
        }
    }
}
