import Foundation

/// How an agent in a session VibeSwitcher started asks for a transaction: `vs-wallet request …` (Resources/bin, on every
/// session's PATH; it runs `vibeswitcher-mcp --wallet-request …`). The request is checked by the same strict parser
/// the Wallet Manager uses and filed, 0600, in `folder`, with the session host's stamp for the session the filing process
/// runs in (`WalletStamp`); the app shows it as a card in that session's chat (and only a request the host stamped), and nothing
/// goes until the user presses Send to Wallet Manager there, or Sign in browser wallet (from an 0x address; it works with no
/// Wallet Manager set up). The answer comes back to the session as a message. Nothing here sends, signs or reads a key.
public enum WalletAsk {
    /// Where filed requests wait for the user: `~/.vibeswitcher/wallet-requests/asked/<id>.json`, each the request's own
    /// bytes (wallet-request v1).
    public static var folder: URL { VibePaths.walletRequestsDir.appendingPathComponent("asked", isDirectory: true) }

    public static let usage = """
        usage: vs-wallet request --workspace NAME --from WALLET --chain ID --to ADDRESS --amount BASE_UNITS --reason TEXT
                                [--asset native|TOKEN_ADDRESS] [--data 0xCALLDATA] [--expires-in 24h] [--label TEXT]

        Files a transaction request from this session. It shows as a card in this session's chat in VibeSwitcher;
        nothing is sent until the user presses Send to Wallet Manager there. The Wallet Manager's Mac checks it and the user signs it
        there; VibeSwitcher never signs. The Wallet Manager's answers come back to this session as messages.
        From an 0x address, the card also offers Sign in browser wallet: the browser's wallet extension signs it, without the
        Wallet Manager's checks. It works with no Wallet Manager set up; a wallet id (not 0x) needs the Wallet Manager.
        A request whose reason's first line is LOCAL FORK ONLY is never offered the browser wallet: it needs the Wallet Manager.

          --workspace   the Wallet Manager's workspace the wallet is in
          --from        the wallet to send from: its id in that workspace, or its 0x address
          --chain       the chain id (1 Ethereum, 11155111 Sepolia, 8453 Base, 84532 Base Sepolia,
                        42424242 GenLayer, 4221 GenLayer Testnet)
          --to          the recipient (a transfer) or the contract called (with --data): 0x and 40 hex digits
          --amount      in the asset's base units (wei for the native coin), decimal digits
          --asset       native (the default) or a token contract's 0x address (an ERC-20 transfer)
          --data        calldata: makes it a contract call (its asset native; its amount the value sent, 0 allowed)
          --reason      why, in your words: shown, quoted as yours, to the person who signs (up to 1000 characters, 8 lines)
          --expires-in  how long it stands if not acted on: 90m, 24h (the default), 3d; 7d at most
          --label       a label for people (the card names the session as VibeSwitcher knows it, and shows this beside it)
        Never put a key, seed or recovery phrase in any field: such text is refused.
        """

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The request the arguments (after `request`) ask for, made `now` from `session` (the session the host tells
    /// the filing process runs in: `LeadVault.walletSession`); refused with the parser's reason (the field and its
    /// rule) for anything the format doesn't take.
    public static func request(_ arguments: [String], session: String, cwd: String, now: Date = Date()) throws -> WalletRequest {
        guard let id = UUID(uuidString: session) else { throw Refusal("the session host named no session (\(session))") }
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
        let lifetime = try values["--expires-in"].map(duration) ?? WalletRequest.defaultLifetime
        let data = values["--data"]
        let project = (cwd as NSString).lastPathComponent
        let request = WalletRequest.make(now: now, lifetime: lifetime,
                                        requestedBy: .init(project: project.isEmpty ? "/" : project, session: id.uuidString.lowercased(),
                                                           label: values["--label"] ?? ""),
                                        workspace: values["--workspace"]!, from: values["--from"]!, chainId: chain,
                                        action: data == nil ? .transfer : .call, to: values["--to"]!, asset: values["--asset"] ?? "native",
                                        amount: values["--amount"]!, data: data, reason: values["--reason"]!)
        // The very checks the Wallet Manager makes: the bytes filed are the bytes that go.
        do {
            _ = try request.encoded()
        } catch let failure as WalletRequestFormat.Failure {
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
        guard seconds <= WalletRequest.maxLifetime else { throw Refusal("expiresAt: must be after createdAt, by 7 days at most") }
        return seconds
    }

    /// Files `request` for the app with the session host's `stamp` on its bytes: `<folder>/<id>.seal`, then
    /// `<folder>/<id>.json`, each 0600 in a 0700 folder. Refused when the stamp isn't for these bytes and the session
    /// the request names.
    public static func file(_ request: WalletRequest, stamp: WalletStamp, in folder: URL = WalletAsk.folder) throws {
        let bytes = try request.encoded()
        guard stamp.session == request.requestedBy.session.lowercased(), stamp.digest == WalletStamp.digest(bytes) else {
            throw Refusal("the session host's stamp isn't for this request")
        }
        try VibePaths.ensurePrivate(folder)
        // The stamp first: the app never sees the request without it.
        try VibePaths.writePrivate(JSONEncoder().encode(stamp), to: stampFile(request.id, in: folder))
        try VibePaths.writePrivate(bytes, to: folder.appendingPathComponent("\(request.id).json"))
    }

    /// Beside a filed request: the session host's stamp on it (see `WalletStamp`).
    public static func stampFile(_ id: String, in folder: URL = WalletAsk.folder) -> URL {
        folder.appendingPathComponent("\(id).seal")
    }

    /// The requests filed in `folder`, oldest first, each checked again by the strict parser (the folder is a file
    /// anyone's shell can write), with the stamp filed beside each (`stamps`, by id; the app asks the session host
    /// whether it's the host's). One that doesn't parse, whose id isn't its name's, or with no stamp for its bytes and
    /// the session it names, is named in `refused`.
    public static func filed(in folder: URL = WalletAsk.folder)
        -> (requests: [WalletRequest], stamps: [String: WalletStamp], refused: [(file: URL, why: String)]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var requests: [WalletRequest] = []
        var stamps: [String: WalletStamp] = [:]
        var refused: [(URL, String)] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name)
            do {
                let data = try read(file)
                let request = try WalletRequest.parse(data)
                guard "\(request.id).json" == name else { throw Refusal("its id \(request.id) isn't its name's") }
                guard let stamp = try? JSONDecoder().decode(WalletStamp.self, from: read(stampFile(request.id, in: folder))) else {
                    throw Refusal("it has no session host stamp (vs-wallet request files one; this was written some other way)")
                }
                guard stamp.digest == WalletStamp.digest(data), stamp.session == request.requestedBy.session.lowercased() else {
                    throw Refusal("its session host stamp is for other bytes or another session")
                }
                requests.append(request)
                stamps[request.id] = stamp
            } catch {
                refused.append((file, "\(error)"))
            }
        }
        return (requests.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }, stamps, refused)
    }

    /// A regular file's bytes (no link followed), 64 KiB at most.
    static func read(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Refusal("can't open \(file.lastPathComponent): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Refusal("\(file.lastPathComponent) isn't a regular file") }
        guard info.st_size <= WalletRequestFormat.maxFileBytes else { throw WalletRequestFormat.Failure.tooLarge(Int(info.st_size)) }
        let data = try handle.read(upToCount: WalletRequestFormat.maxFileBytes + 1) ?? Data()
        // Grown since it was looked at: still no more than the limit.
        guard data.count <= WalletRequestFormat.maxFileBytes else { throw WalletRequestFormat.Failure.tooLarge(data.count) }
        return data
    }

    /// Removes a filed request (sent, discarded, or refused), its expiry note's marker and its browser wallet mark.
    public static func remove(_ id: String, in folder: URL = WalletAsk.folder) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: stampFile(id, in: folder))
        try? FileManager.default.removeItem(at: expiryMarker(id, in: folder))
        try? FileManager.default.removeItem(at: WalletBrowser.markFile(id, in: folder))
    }

    /// Beside a filed request that expired unsent, once its agent was told (`.<id>.expired`: `filed` reads no
    /// dot-file), so a restarted app doesn't tell it again.
    static func expiryMarker(_ id: String, in folder: URL) -> URL {
        folder.appendingPathComponent(".\(id).expired")
    }

    /// Whether the asking agent was told that request `id` expired unsent.
    public static func toldExpired(_ id: String, in folder: URL = WalletAsk.folder) -> Bool {
        FileManager.default.fileExists(atPath: expiryMarker(id, in: folder).path)
    }

    /// Records that the asking agent was told that request `id` expired unsent. False when it couldn't be recorded.
    @discardableResult
    public static func markToldExpired(_ id: String, in folder: URL = WalletAsk.folder) -> Bool {
        (try? VibePaths.writePrivate(Data(), to: expiryMarker(id, in: folder))) != nil
    }

    /// What the asking session hears when its request reached its expiry without the user sending it.
    public static func expiredUnsent(_ request: WalletRequest) -> String {
        "Wallet request \(request.id) expired at \(WalletRequestFormat.string(request.expiresAt)) without being sent: it never "
            + "reached the Wallet Manager (the user didn't send it from its card, or Passage couldn't deliver it), so nothing was "
            + "signed. If the transaction is still needed, tell the user, or file a new request with vs-wallet request."
    }

    /// Whether the Wallet Manager can be reached from here, as Settings › Wallet has it: requests are filed either way;
    /// without it, the browser wallet is the way to sign one (from an 0x address).
    public enum WalletManager: Equatable {
        case ready
        /// No Wallet Manager peer is chosen in Settings › Wallet.
        case noPeer
        /// No Passage: none found with no path set, or the path set isn't absolute.
        case noPassage

        /// Why it isn't set up, in a few words; nil when ready.
        public var why: String? {
            switch self {
            case .ready: return nil
            case .noPeer: return "no Wallet Manager peer is chosen in VibeSwitcher's Settings › Wallet"
            case .noPassage: return "Passage isn't found (set its path in VibeSwitcher's Settings › Wallet)"
            }
        }

        /// As the app's defaults have it: the peer chosen (`walletPeerID`) and Passage (`walletPassagePath`; empty:
        /// `passage` on `path`, the session's PATH, else Passage.app in `apps`).
        public static func from(peer: String, passagePath: String, path: String?, apps: [URL] = PassageCommand.appLocations) -> WalletManager {
            guard !peer.isEmpty else { return .noPeer }
            let found = PassageCommand.resolve(setting: passagePath, onPath: { onPath("passage", path: path) }, apps: apps)
            return found == nil ? .noPassage : .ready
        }

        /// The first executable `name` in the folders of `path` (a PATH value), as an absolute path.
        static func onPath(_ name: String, path: String?) -> String? {
            for folder in (path ?? "").split(separator: ":") where folder.hasPrefix("/") {
                let file = (String(folder) as NSString).appendingPathComponent(name)
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file, isDirectory: &directory), !directory.boolValue,
                   FileManager.default.isExecutableFile(atPath: file) { return file }
            }
            return nil
        }
    }

    /// `vs-wallet request …`, as the CLI runs it: what to print, and the exit status (0 filed, 1 refused, 2 usage).
    /// `walletManager`: whether Settings › Wallet has the Wallet Manager set up. Filed either way; without it the output
    /// says the browser wallet is the way to sign it (or, for a wallet id or a request marked LOCAL FORK ONLY, that it
    /// waits for the Wallet Manager).
    /// `vault`: the session host's (`LeadVault.standard` in the CLI; the sandbox's own there). It says which session the
    /// calling process runs in, from that process (never from what it says, VIBESWITCHER_SESSION included), and stamps
    /// the request's bytes for that session; the app shows only a request the host stamped. Refused when it can't be
    /// asked, or places the process in no session.
    public static func run(_ arguments: [String], cwd: String, walletManager: WalletManager, folder: URL = WalletAsk.folder,
                           now: Date = Date(), vault: LeadVault) -> (status: Int32, output: String, error: String) {
        guard let command = arguments.first, command == "request" else {
            return arguments.first.map { ["help", "--help", "-h"].contains($0) } == true ? (0, usage, "") : (2, "", usage)
        }
        do {
            let session: String
            do {
                session = try vault.walletSession()
            } catch {
                throw Refusal("VibeSwitcher's session host didn't say which of its sessions this process runs in (\(error)): "
                              + "run it from the agent's own session in VibeSwitcher, with VibeSwitcher running")
            }
            let request = try request(Array(arguments.dropFirst()), session: session, cwd: cwd, now: now)
            let digest = WalletStamp.digest(try request.encoded())
            let seal: String
            do {
                seal = try vault.sealWallet(session: session, digest: digest)
            } catch {
                throw Refusal("VibeSwitcher's session host didn't stamp the request (\(error))")
            }
            try file(request, stamp: WalletStamp(session: session, digest: digest, seal: seal), in: folder)
            let expires = "It expires at \(WalletRequestFormat.string(request.expiresAt))."
            guard let why = walletManager.why else {
                return (0, "Filed wallet request \(request.id): it waits on its card in this session's chat in VibeSwitcher, and nothing is sent "
                           + "until the user presses Send to Wallet Manager there. \(expires) "
                           + "The Wallet Manager's answers will come to this session as messages; don't file it again.", "")
            }
            let card = "Filed wallet request \(request.id): its card is up in this session's chat in VibeSwitcher. "
                + "The Wallet Manager isn't set up yet (\(why)), "
            if WalletBrowser.isLocalForkOnly(request) {
                return (0, card + "and the browser wallet can't sign a request marked \(WalletBrowser.localForkMarker): it waits on its card "
                           + "until the user sets up the Wallet Manager in Settings › Wallet and sends it. \(expires)", "")
            }
            guard WalletBrowser.canSign(request) else {
                return (0, card + "and a browser wallet can't sign for a wallet id (--from \(request.from)): it waits on its card until the "
                           + "user sets up the Wallet Manager in Settings › Wallet and sends it. To use the browser wallet instead, ask the user "
                           + "to discard it and file it again from the wallet's 0x address. \(expires)", "")
            }
            return (0, card + "so the browser wallet is the way to sign: nothing is sent until the user presses Sign in browser wallet on "
                       + "the card and confirms it in the wallet's own popup (without the Wallet Manager's checks). \(expires) "
                       + "What happens will come to this session as a message; don't file it again.", "")
        } catch let refusal as Refusal {
            return (1, "", "vs-wallet: refused: \(refusal.description)")
        } catch {
            return (1, "", "vs-wallet: refused: \(error)")
        }
    }
}
