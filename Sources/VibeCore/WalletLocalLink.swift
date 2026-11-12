import Foundation

/// How wallet requests reach the Wallet Manager and its results come back, as `WalletCourier` uses it: `PassageLink`
/// (the Wallet Manager's Mac, through the `passage` command line) or `WalletLocalLink` (a Wallet Manager on this Mac,
/// through a folder pair). The courier's rules (its records, the strict parser, results in `sequence` order, nothing
/// after a final status, each file looked at once) are the same over either: a transport only carries bytes.
public protocol WalletTransport: Sendable {
    /// Where requests go, for the log.
    var destination: String { get }
    /// What listens for results, for the log ("passage listen").
    var listening: String { get }
    /// Why a request can't go now, when that's known without sending (then nothing is recorded or written); nil: send.
    func notReachable() -> String?
    /// Whether a failure of `arrivals` that repeats the last one is logged once, not at every look (the folder pair,
    /// looked at every few seconds while the Wallet Manager isn't there).
    var logsARepeatedFailureOnce: Bool { get }
    /// Whether a look the listener asks for runs on a queue of the courier's own, not on GCD's shared utility queue.
    /// That one gives a look no thread while the rest of the process keeps every core busy, and a `poll` asked
    /// meanwhile (the desk's, on its queue) waits behind the look: for the folder pair, whose watch asks for a look
    /// at every file, that held results back for as long as the process stayed busy.
    var looksOnAQueueOfItsOwn: Bool { get }
    /// Sends `file` (the request's own bytes) as request `id`'s.
    func deliver(file: URL, id: String) -> PassageLink.SendOutcome
    /// What the Wallet Manager has sent, oldest first.
    func arrivals() -> Result<[PassageLink.InboxEntry], PassageLink.InboxFailure>
    /// The request id `entry` is a result for, by where it is and its name; throws why it isn't one.
    func requestID(of entry: PassageLink.InboxEntry) throws -> String
    /// The bytes of `entry`, for the strict parser: a regular file of at most 64 KiB, no link followed.
    func bytes(of entry: PassageLink.InboxEntry) throws -> Data
    /// Starts listening: `heard` is called (on a thread of its own) when something may have arrived.
    func watch(heard: @escaping @Sendable () -> Void) throws -> any WalletListening
}

extension WalletTransport {
    public func notReachable() -> String? { nil }
    public var logsARepeatedFailureOnce: Bool { false }
    public var looksOnAQueueOfItsOwn: Bool { false }
}

/// What a transport listens with while a request is outstanding: `passage listen`, or a watch on a folder.
public protocol WalletListening: AnyObject, Sendable {
    /// Its process and program, when it is one (`passage listen`): recorded, so one a crash orphans is ended at the
    /// next launch.
    var process: (pid: Int32, executable: String)? { get }
    var isRunning: Bool { get }
    /// How it ended, once it has (a process's exit code or signal).
    var exitStatus: Int32? { get }
    /// Stops it; returns once it has stopped.
    func stop(grace: TimeInterval)
}

/// VibeSwitcher's side of the transport on one Mac (docs/protocol/wallet-request.md, "Transport on one Mac"): an
/// owner-only folder pair the Wallet Manager makes when it's started with its local transport, never VibeSwitcher.
/// Requests are written to `to-wm/wallet-request-<id>.json` (their own bytes, 0600, under a dot-name and renamed, never
/// over a file with other bytes); results are read from `from-wm/wallet-result-<id>-<seq>.json`. Files only: no
/// socket, no program run.
///
/// It fails closed. A folder that isn't a real directory of this user's all the way down from the home folder, or
/// that anyone else can use, and a `to-wm` without the Wallet Manager's `.listening` (`listener`), is unreachable; a
/// result that isn't a regular file of this user's, named and numbered as its content says, is ignored. Any process
/// of this user can write these folders, as it can run `passage send` or write Passage's inbox folder: a file here
/// proves nothing about who made it, and the Wallet Manager's own checks and the hardware wallet are the boundary.
public struct WalletLocalLink: WalletTransport {
    /// The home folder the pair is under.
    public let home: String

    public static let toName = "to-wm"
    public static let fromName = "from-wm"
    /// In `to-wm` while the Wallet Manager takes requests from this Mac: its process id, in decimal.
    public static let listeningName = ".listening"
    /// The most a `.listening` file holds: a process id and a line end fit many times over.
    static let maxListeningBytes = 32

    /// The user the folders and files must be owned by: this one (a test gives another, for what isn't this user's).
    let owner: uid_t

    public init(home: String = VibePaths.home) { self.init(home: home, owner: getuid()) }

    init(home: String, owner: uid_t) {
        self.home = home
        self.owner = owner
    }

    /// `<home>/Library/Application Support/wallet-manager/local-transport/to-wm`.
    public var toFolder: URL { VibePaths.walletLocalTransport(home: home).appendingPathComponent(Self.toName, isDirectory: true) }
    /// `<home>/Library/Application Support/wallet-manager/local-transport/from-wm`.
    public var fromFolder: URL { VibePaths.walletLocalTransport(home: home).appendingPathComponent(Self.fromName, isDirectory: true) }

    public var destination: String { "the Wallet Manager on this Mac" }
    public var listening: String { "the watch on \(Self.fromName)" }
    public var logsARepeatedFailureOnce: Bool { true }
    public var looksOnAQueueOfItsOwn: Bool { true }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// What the cards and the log say when the folders aren't there as the Wallet Manager makes them.
    static func notRunning(_ why: String) -> String { "The Wallet Manager isn't running with its local transport on this Mac (\(why))" }
    /// What they say when the folders are there and the Wallet Manager isn't taking requests.
    static func notAccepting(_ why: String) -> String {
        "The Wallet Manager on this Mac isn't accepting requests (\(why)): start it with its local transport and accept this Mac's requests there"
    }

    // MARK: The folders

    /// An open folder of the pair, closed with it.
    final class Folder {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }

    /// Opens `to-wm` or `from-wm`, each folder on the way down from the home folder opened in the one before with no
    /// link followed: every one a directory of this user's that no one else can write, and the last with no group or
    /// other permission at all (0700). Throws what's wrong, in a few words.
    func open(_ name: String, events: Bool = false) throws -> Folder {
        var current = Sys.open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Failure(description: "the home folder can't be opened") }
        let parts = VibePaths.walletLocalTransportParts + [name]
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            let next = openat(current, part, (last && events ? Platform.Files.eventsOnly : O_RDONLY) | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            let problem = errno
            close(current)
            guard next >= 0 else {
                throw Failure(description: problem == ENOENT ? "\(name) is missing"
                              : problem == ELOOP || problem == ENOTDIR ? "\(part) isn't a real folder" : "\(part) can't be opened: \(String(cString: strerror(problem)))")
            }
            current = next
            var info = stat()
            guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                close(current)
                throw Failure(description: "\(part) isn't a real folder")
            }
            guard info.st_uid == owner else {
                close(current)
                throw Failure(description: "\(part) isn't this user's")
            }
            guard info.st_mode & (last ? 0o077 : 0o022) == 0 else {
                close(current)
                throw Failure(description: last ? "\(part) isn't owner-only (0700)" : "\(part) can be written by others")
            }
        }
        return Folder(current)
    }

    /// The bytes of `name` in `folder`: a regular file of this user's (no link followed), of at most `limit` bytes.
    static func read(_ name: String, in folder: Folder, limit: Int, owner: uid_t) throws -> Data {
        let descriptor = openat(folder.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure(description: "can't open \(name): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure(description: "\(name) isn't a regular file") }
        guard info.st_uid == owner else { throw Failure(description: "\(name) isn't this user's") }
        guard info.st_size <= limit else { throw Failure(description: "\(name) is \(info.st_size) bytes, over the \(limit)-byte limit") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        // Grown since it was looked at: still no more than the limit.
        guard data.count <= limit else { throw Failure(description: "\(name) is over the \(limit)-byte limit") }
        return data
    }

    // MARK: Liveness

    /// The one liveness rule: the Wallet Manager keeps `to-wm/.listening`, holding its process id in decimal, while it
    /// takes requests from this Mac (it's removed on Stop and on exit; a crash can leave one). Returns that process id
    /// only when the file is a small regular file of this user's holding one, and that process runs; throws why not.
    static func listener(in to: Folder, owner: uid_t) throws -> Int32 {
        let data: Data
        do {
            data = try read(listeningName, in: to, limit: maxListeningBytes, owner: owner)
        } catch {
            throw Failure(description: "no readable \(listeningName) in \(toName)")
        }
        var digits = Array(data)
        if digits.last == 0x0a { digits.removeLast() }
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), digits[0] != 0x30,
              let pid = Int32(String(decoding: digits, as: UTF8.self)), pid > 1 else {
            throw Failure(description: "\(listeningName) doesn't hold a process id")
        }
        // Running (not a zombie) as this user, by the process table: a process id used again by someone else's isn't it.
        guard case .record(let info) = Platform.Processes.record(pid), info.state != .zombie, info.uid == owner else {
            throw Failure(description: "the process \(listeningName) names, \(pid), isn't running")
        }
        return pid
    }

    /// `to-wm`, open, once the folder checks and the liveness rule pass; throws what the card says otherwise.
    private func reachable() throws -> Folder {
        let to: Folder
        do { to = try open(Self.toName) } catch { throw Failure(description: Self.notRunning("\(error)")) }
        do { _ = try Self.listener(in: to, owner: owner) } catch { throw Failure(description: Self.notAccepting("\(error)")) }
        return to
    }

    public func notReachable() -> String? {
        do {
            _ = try reachable()
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Sending

    /// Writes the bytes of `file` to `to-wm/wallet-request-<id>.json`: 0600, under a dot-name in that folder, then
    /// renamed, never over a file already there. The same bytes already there count as delivered; other bytes there,
    /// and anything that isn't a request's own bytes, are refused (`notSent`). Unreachable (`peerNotListening`) when
    /// the folder checks or the liveness rule fail: nothing is written then.
    public func deliver(file: URL, id: String) -> PassageLink.SendOutcome { deliver(file: file, id: id, beforeRename: { _ in }) }

    /// `beforeRename` (a test's look) is given the dot-name once the bytes are written under it, before the rename.
    func deliver(file: URL, id: String, beforeRename: (String) -> Void) -> PassageLink.SendOutcome {
        guard WalletRequestFormat.isID(id) else { return .notSent("\(id) isn't a request id") }
        let bytes: Data
        do {
            bytes = try WalletAsk.read(file)
            guard try WalletRequest.parse(bytes).id == id else { return .notSent("the file isn't request \(id)") }
        } catch {
            return .notSent("the request file can't be sent: \(error)")
        }
        let to: Folder
        do { to = try reachable() } catch { return .peerNotListening("\(error)") }
        let name = WalletRequest.fileName(id)
        let temporary = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(to.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .peerNotListening(Self.notRunning("can't write in \(Self.toName): \(String(cString: strerror(errno)))")) }
        var written = fchmod(descriptor, 0o600) == 0
        if written {
            written = bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }
        let problem = errno
        close(descriptor)
        guard written else {
            unlinkat(to.descriptor, temporary, 0)
            return .peerNotListening(Self.notRunning("can't write in \(Self.toName): \(String(cString: strerror(problem)))"))
        }
        beforeRename(temporary)
        // Renamed only where nothing has the name: never over another file.
        if Platform.Files.renameExclusive(in: to.descriptor, from: temporary, to: name) == 0 { return .sent }
        let why = errno
        unlinkat(to.descriptor, temporary, 0)
        guard why == EEXIST else { return .peerNotListening(Self.notRunning("can't rename in \(Self.toName): \(String(cString: strerror(why)))")) }
        guard let there = try? Self.read(name, in: to, limit: WalletRequestFormat.maxFileBytes, owner: owner), there == bytes else {
            return .notSent("\(Self.toName) already holds a \(name) that isn't this request")
        }
        return .sent
    }

    // MARK: Results

    /// Every file in `from-wm` (dot-names apart: a result on its way in is one until it's renamed), by name, each
    /// named as it is there; `requestID(of:)` and `bytes(of:)` say which are results. Fails when `from-wm` doesn't pass
    /// the folder checks.
    public func arrivals() -> Result<[PassageLink.InboxEntry], PassageLink.InboxFailure> {
        let from: Folder
        do { from = try open(Self.fromName) } catch { return .failure(.init(description: "\(Self.fromName) can't be read: \(error)")) }
        // The listing is of the folder that passed the checks: a descriptor of its own, which closedir closes.
        let copy = dup(from.descriptor)
        guard copy >= 0, let listing = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return .failure(.init(description: "\(Self.fromName) can't be listed: \(String(cString: strerror(errno)))"))
        }
        defer { closedir(listing) }
        var names: [String] = []
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(PATH_MAX)) { String(cString: $0) } }
            if !name.hasPrefix(".") { names.append(name) }
        }
        let folder = fromFolder
        // By request and then by number (not "10" before "2"); the courier orders results by `sequence` again.
        let entries = names.map { (name: $0, parts: Self.parts(ofResultName: $0)) }
            .sorted { ($0.parts?.id ?? "", $0.parts?.sequence ?? 0, $0.name) < ($1.parts?.id ?? "", $1.parts?.sequence ?? 0, $1.name) }
        return .success(entries.map { PassageLink.InboxEntry(peerID: "", name: $0.name, path: folder.appendingPathComponent($0.name).path) })
    }

    /// The id and sequence in `wallet-result-<id>-<seq>.json`: `<id>` a request id, `<seq>` 1 to 1000 in decimal with
    /// no padding. Nil for any other name.
    static func parts(ofResultName name: String) -> (id: String, sequence: Int64)? {
        let (prefix, suffix) = ("wallet-result-", ".json")
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.utf8.count > prefix.count + suffix.count + 37 else { return nil }
        let middle = Array(name.utf8.dropFirst(prefix.count).dropLast(suffix.count))
        let id = String(decoding: middle.prefix(36), as: UTF8.self)
        let digits = middle.dropFirst(37)
        guard WalletRequestFormat.isID(id), middle[36] == UInt8(ascii: "-"), digits.count <= 4, digits.first != UInt8(ascii: "0"),
              digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let sequence = Int64(String(decoding: digits, as: UTF8.self)),
              sequence >= 1, sequence <= WalletResult.maxSequence else { return nil }
        return (id, sequence)
    }

    /// `entry`'s name, when it is a file directly in `from-wm` as `arrivals` lists them.
    private func name(of entry: PassageLink.InboxEntry) throws -> String {
        let folder = fromFolder.path + "/"
        guard entry.peerID.isEmpty, entry.path == folder + entry.name, !entry.name.contains("/"), !entry.name.hasPrefix(".") else {
            throw PassageLink.InboxFailure(description: "\(entry.path) isn't a file in \(Self.fromName)")
        }
        return entry.name
    }

    public func requestID(of entry: PassageLink.InboxEntry) throws -> String {
        guard let parts = Self.parts(ofResultName: try name(of: entry)) else {
            throw PassageLink.InboxFailure(description: "not a wallet result (\(entry.name))")
        }
        return parts.id
    }

    /// The bytes of a result in `from-wm`: a regular file of this user's (no link followed) of at most 64 KiB, in a
    /// `from-wm` that passes the folder checks, whose content is a result with the id and the sequence its name has.
    public func bytes(of entry: PassageLink.InboxEntry) throws -> Data {
        let name = try name(of: entry)
        guard let parts = Self.parts(ofResultName: name) else { throw PassageLink.InboxFailure(description: "not a wallet result (\(name))") }
        let data = try Self.read(name, in: open(Self.fromName), limit: WalletRequestFormat.maxFileBytes, owner: owner)
        let result = try WalletResult.parse(data)
        guard result.id == parts.id else { throw PassageLink.InboxFailure(description: "its id \(result.id) isn't its name's \(parts.id)") }
        guard result.sequence == parts.sequence else {
            throw PassageLink.InboxFailure(description: "its sequence \(result.sequence) isn't its name's \(parts.sequence)")
        }
        return data
    }

    // MARK: Listening

    /// Watches `from-wm` (which must pass the folder checks): `heard` is called when its entries change, at most once
    /// a second. It ends by itself when the folder is removed or renamed; the courier then starts another.
    public func watch(heard: @escaping @Sendable () -> Void) throws -> any WalletListening {
        let folder = try open(Self.fromName, events: true)
        let descriptor = dup(folder.descriptor)
        guard descriptor >= 0 else { throw Failure(description: "\(Self.fromName) can't be watched: \(String(cString: strerror(errno)))") }
        guard let watch = WalletFolderWatch(descriptor: descriptor, heard: heard) else { throw Failure(description: "\(Self.fromName) can't be watched") }
        return watch
    }
}

/// A watch on a folder's entries (a file made, renamed or removed in it): `heard` is called for a change at once, and
/// for the changes within `pause` of it once more, at the end of that time. No process, nothing polled.
final class WalletFolderWatch: WalletListening, @unchecked Sendable {
    static let pause: TimeInterval = 1
    private let queue = DispatchQueue(label: "dev.vibeswitcher.wallet-folder-watch", qos: .utility)
    private let source: Platform.FolderWatch
    // On `queue`:
    private var last: DispatchTime?
    private var pending = false
    private let lock = NSLock()
    private var running: Bool

    /// Takes over `descriptor` (a folder opened for events), closed when the watch stops; nil (and closed) when it
    /// can't be watched.
    init?(descriptor: Int32, heard: @escaping @Sendable () -> Void) {
        guard let source = Platform.FolderWatch(descriptor: descriptor) else { return nil }
        self.source = source
        running = true
        source.deliver(on: queue) { [weak self] change in
            guard let self else { return }
            // The folder itself gone or moved: what's watched is no longer `from-wm`.
            if change.contains(.folderGone) {
                self.lock.withLock { self.running = false }
                source.stop()
                return heard()
            }
            let now = DispatchTime.now()
            if let last = self.last, now < last + Self.pause {
                guard !self.pending else { return }
                self.pending = true
                self.queue.asyncAfter(deadline: last + Self.pause) { [weak self] in
                    guard let self, self.pending else { return }
                    self.pending = false
                    self.last = .now()
                    if self.isRunning { heard() }
                }
            } else {
                self.last = now
                heard()
            }
        }
    }

    var process: (pid: Int32, executable: String)? { nil }
    var isRunning: Bool { lock.withLock { running } }
    var exitStatus: Int32? { nil }

    func stop(grace: TimeInterval) {
        let was = lock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        if was { source.stop() }
    }

    deinit { stop(grace: 0) }
}
