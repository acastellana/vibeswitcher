import Foundation

/// VibeSwitcher's side of the Passage link to the Wallet Manager's Mac: the `passage` CLI (Passage's README, "Command line"),
/// run as a program, never through a shell. Sends a request file to the Wallet Manager peer, lists what the Wallet Manager peer sent
/// (`passage inbox <peer> --json`) and runs `passage listen` while there's something to hear. Inbox files are
/// untrusted data: read only as bytes for the strict parser, never opened or run.
public struct PassageLink: Sendable {
    /// How passage is run: the program (an absolute path) and what comes before each command (`cli` for the app's binary).
    public let command: PassageCommand
    /// The `passage` executable, an absolute path.
    public var executable: String { command.executable }
    /// The Wallet Manager's Mac's peer ID: 8 lower-case hex digits (a name could match another peer).
    public let walletPeer: String
    /// Passage's inbox folder, holding one folder per peer ID.
    public let inboxFolder: URL

    /// Where Passage keeps what it receives: `~/Library/Application Support/app.passage.Passage/inbox`.
    public static var defaultInbox: URL {
        URL(fileURLWithPath: VibePaths.home).appendingPathComponent("Library/Application Support/app.passage.Passage/inbox", isDirectory: true)
    }

    /// Nil unless `executable` is an absolute path and `walletPeer` a peer ID.
    public init?(executable: String, walletPeer: String, inboxFolder: URL = PassageLink.defaultInbox) {
        self.init(command: PassageCommand(executable: executable), walletPeer: walletPeer, inboxFolder: inboxFolder)
    }

    /// Nil unless `command`'s executable is an absolute path and `walletPeer` a peer ID.
    public init?(command: PassageCommand, walletPeer: String, inboxFolder: URL = PassageLink.defaultInbox) {
        let peer = Array(walletPeer.utf8)
        guard command.executable.hasPrefix("/"), peer.count == 8,
              peer.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        self.command = command
        self.walletPeer = walletPeer
        self.inboxFolder = inboxFolder.standardizedFileURL
    }

    // MARK: Sending

    /// How a `passage send` went, by its exit code (Passage's README, "Exit codes"), each with what it said on stderr.
    public enum SendOutcome: Equatable, Sendable {
        /// 0, and it printed `sent<TAB><Wallet Manager peer><TAB><name><TAB><bytes>`.
        case sent
        /// 1: the connection, the handshake, the file, the inbox or the Keychain failed.
        case failed(String)
        /// 2: passage didn't take the command line.
        case usage(String)
        /// 3: no paired peer is the Wallet Manager peer.
        case noSuchPeer(String)
        /// 4: the Wallet Manager peer is paired but no `passage listen` answered for it.
        case peerNotListening(String)
        /// 5: passage refused the content as looking like a secret (it's never confirmed: no --yes, no terminal).
        case refusedAsSecret(String)
        /// Any other end: another exit code, a signal, past the time limit, couldn't start, or exit 0 without the line.
        case unexpected(String)

        /// Whether the Wallet Manager may have the file all the same: passage gave up after connecting (1), or ended in a way
        /// that says nothing (`unexpected`). The others (2–5) end before anything is sent.
        public var mayHaveArrived: Bool {
            switch self {
            case .sent, .failed, .unexpected: true
            case .usage, .noSuchPeer, .peerNotListening, .refusedAsSecret: false
            }
        }
    }

    /// Sends `file` as `wallet-request-<id>.json` to the Wallet Manager peer, waiting up to `timeout` for passage to finish. Never
    /// with --yes: if passage's secret check fires the request isn't sent (5). It runs in a session of its own, with no
    /// terminal to ask on. Blocks: call it off the main thread.
    public func send(file: URL, id: String, timeout: TimeInterval = 120) -> SendOutcome {
        let name = WalletRequest.fileName(id)
        let result = Shell.run(executable: executable, args: command.arguments(["send", walletPeer, file.path, "--name", name]), in: "/",
                               timeout: timeout, ownSession: true)
        let said = Self.brief(result.error)
        if result.timedOut || result.cancelled { return .unexpected("passage send was stopped: \(result.timedOut ? "out of time" : "cancelled")") }
        // A signal's number isn't an exit code: SIGTRAP (5, a crash) isn't passage refusing a secret.
        if result.signaled { return .unexpected("passage send was ended by signal \(result.status)" + (said.isEmpty ? "" : ": \(said)")) }
        switch result.status {
        case 0:
            let line = result.output.split(separator: "\n").first { $0.hasPrefix("sent\t") }.map(String.init)
            let fields = line?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) ?? []
            guard fields.count == 4, fields[1] == walletPeer, fields[2] == name else {
                return .unexpected("passage send exited 0 without saying it sent \(name) to \(walletPeer)")
            }
            return .sent
        case 1: return .failed(said)
        case 2: return .usage(said)
        case 3: return .noSuchPeer(said)
        case 4: return .peerNotListening(said)
        case 5: return .refusedAsSecret(said)
        default: return .unexpected("passage send exited \(result.status)" + (said.isEmpty ? "" : ": \(said)"))
        }
    }

    /// stderr, trimmed and cut to 500 characters.
    static func brief(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
    }

    // MARK: The inbox

    /// One line of `passage inbox --json`.
    public struct InboxEntry: Equatable, Sendable {
        /// The peer it came from.
        public var peerID: String
        /// What the sender called it (without the inbox's timestamp).
        public var name: String
        public var path: String
    }

    public struct InboxFailure: Error, Equatable, Sendable, CustomStringConvertible {
        public var description: String
    }

    /// What the Wallet Manager peer has sent, oldest first: `passage inbox <Wallet Manager peer> --json`. Any line that isn't an object
    /// with string `peerID`, `name` and `path` fails the whole listing.
    public func inbox(timeout: TimeInterval = 60) -> Result<[InboxEntry], InboxFailure> {
        let result = Shell.run(executable: executable, args: command.arguments(["inbox", walletPeer, "--json"]), in: "/", timeout: timeout, ownSession: true)
        guard result.ok else {
            let why = result.timedOut ? "out of time" : result.cancelled ? "cancelled" : "exit \(result.status)"
            let said = Self.brief(result.error)
            return .failure(InboxFailure(description: "passage inbox failed (\(why))" + (said.isEmpty ? "" : ": \(said)")))
        }
        var entries: [InboxEntry] = []
        for (number, line) in result.output.split(separator: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard case let .object(members)? = try? WalletRequestFormat.Value.parse(Data(line.utf8)) else {
                return .failure(InboxFailure(description: "passage inbox: line \(number + 1) isn't a JSON object"))
            }
            func text(_ key: String) -> String? {
                guard case let .string(value)? = members.first(where: { $0.key == key })?.value else { return nil }
                return value
            }
            guard let peer = text("peerID"), let name = text("name"), let path = text("path") else {
                return .failure(InboxFailure(description: "passage inbox: line \(number + 1) lacks peerID, name or path"))
            }
            entries.append(InboxEntry(peerID: peer, name: name, path: path))
        }
        return .success(entries)
    }

    /// The bytes of an inbox file the Wallet Manager peer sent: only a regular file (no link followed) directly in
    /// `<inbox>/<Wallet Manager peer>/`, named `<timestamp>-<name>`, of at most 64 KiB.
    public func read(_ entry: InboxEntry) throws -> Data {
        let folder = inboxFolder.appendingPathComponent(walletPeer, isDirectory: true).path + "/"
        guard entry.peerID == walletPeer, entry.path.hasPrefix(folder) else {
            throw InboxFailure(description: "\(entry.path) isn't in the Wallet Manager peer's inbox folder")
        }
        let file = String(entry.path.dropFirst(folder.count))
        guard !file.contains("/"), file.hasSuffix("-" + entry.name), !file.hasPrefix(".") else {
            throw InboxFailure(description: "\(entry.path) isn't named as the inbox names \(entry.name)")
        }
        let descriptor = open(entry.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw InboxFailure(description: "can't open \(entry.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw InboxFailure(description: "\(entry.path) isn't a regular file")
        }
        guard info.st_size <= WalletRequestFormat.maxFileBytes else { throw WalletRequestFormat.Failure.tooLarge(Int(info.st_size)) }
        let data = try handle.read(upToCount: WalletRequestFormat.maxFileBytes + 1) ?? Data()
        guard data.count <= WalletRequestFormat.maxFileBytes else { throw WalletRequestFormat.Failure.tooLarge(data.count) }
        return data
    }

    // MARK: Listening

    /// Starts `passage listen`: `heard` is called (on a thread of its own) for each line it prints, an item received.
    public func listen(heard: @escaping @Sendable () -> Void) throws -> PassageListener {
        try PassageListener(command: command, heard: heard)
    }
}

/// A running `passage listen`, a child of this process in a session of its own. Ended by its own pid (`stop`), never
/// by name; reaped here, so the pid stays its own until then.
public final class PassageListener: @unchecked Sendable {
    public let pid: Int32
    private let process: Shell.Spawned

    init(command: PassageCommand, heard: @escaping @Sendable () -> Void) throws {
        let out = try ShellPipe(), err = try ShellPipe()
        process = try Shell.Spawned([command.executable] + command.arguments(["listen"]), in: "/", environment: ProcessInfo.processInfo.environment,
                                    output: out, errors: err, session: true)
        pid = process.processIdentifier
        // Each line as it comes: read(2) returns what the pipe holds. FileHandle's read(upToCount:) waits on a pipe for
        // the whole count or the end, so a line went unheard until 4 KiB had piled up or passage ended.
        Thread.detachNewThread {
            let reading = out.reading
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(reading.fileDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for _ in 0..<buffer[..<count].filter({ $0 == 0x0a }).count { heard() }
            }
        }
        // Its log (addresses, peer IDs) isn't kept; read so it can't fill the pipe.
        Thread.detachNewThread {
            let reading = err.reading
            while let chunk = try? reading.read(upToCount: 4096), !chunk.isEmpty {}
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// How it ended (the exit code, or the signal), once it has.
    public var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    /// Asks it to stop (SIGTERM to its pid), and kills it (SIGKILL) if it's still running after `grace`; returns once
    /// it's reaped.
    public func stop(grace: TimeInterval = 5) {
        guard process.isRunning else { return }
        kill(pid, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < end { usleep(20_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }

    deinit { stop() }
}
