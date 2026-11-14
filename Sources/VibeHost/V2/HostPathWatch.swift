import Foundation
import VibeCore

/// The host keeps its path (the stage 2 plan's Task 8b, the security architecture document's S2): a worker can put its
/// own socket at the host's socket path (renamed over it), or another file at its lock path, and sessions' tool
/// servers and hooks would reach that socket, and a second host could take that lock. The user's host
/// (`HostServer.Config.watchesItsPath`) watches the folders of both paths (`Platform.FolderWatch`) and, at each change
/// there, at each housekeeping interval and once as it begins, checks that each path still names what it bound and
/// what it locked.
///
/// - The socket path: what it names is recorded only once a connection made through it reached a listener of this
///   process (`SO_PEERCRED` on the connecting end names the process that listened) and it named the same socket file
///   (`lstat`, no link followed) before and after (`verifiedIdentity`), so a socket renamed over the path just after
///   the bind is never recorded as the host's. As the watch begins (a fresh start or a handover) the same is asked of
///   what the path names then. Each housekeeping also connects through it (`leadsHere`), so a file that names the host's
///   socket at one look and another's at the next is found then at the latest.
/// - The socket path naming something else, nothing, or a listener not the host's: what is there is removed, a fresh
///   listener bound there (`UnixSocket.listen`, its senders passed before its first accept), checked as above (up to
///   `bindAttempts` times, each losing listener closed), swapped in for the accept source, and the old listener
///   closed. Clients that connected to what was there stay its; the next ones are the host's. When every attempt
///   loses, the next attempt is at the next housekeeping, not at the folder's next change (the binds are changes).
/// - The lock path naming another file: the file there is locked again and held beside the host's own lock (at most
///   one such: the one taken before is released, its file no longer at the path), or, when another process holds it,
///   that is said. The host's own lock file put back there is held already (its lock is this process's): the lock
///   taken again is released. A handover carries the newest (`lockToCarry`), so the next image holds the lock the path
///   names.
///
/// Each is a line in the host's log and on its stderr (the user journal, through the unit), and each path taken back
/// is counted for `hostNotes` (`HostTally`). Not on the Mac (`watchesItsPath` is false there), and not in a scratch
/// host unless its test sets it. On the host's queue throughout, but for `start`.
final class HostPathWatch {
    /// What a path names: its file's device and inode.
    struct FileIdentity: Equatable {
        var device: UInt64
        var inode: UInt64

        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = Platform.Files.inode(info)
        }
    }

    /// The most fresh listeners bound in one check before it waits for the next housekeeping.
    static let bindAttempts = 3

    private weak var server: HostServer?
    let socketPath: String
    let lockPath: String
    /// What the socket path should name: the listener's file, checked (`verifiedIdentity`). Nil: nothing checked yet.
    private var socketFile: FileIdentity?
    /// Every attempt of the last rebind lost: the folder's changes don't start another, the next housekeeping does.
    private var rebindAtHousekeeping = false
    /// The file the server's own lock is on (its descriptor's `fstat`, as the watch began).
    private var firstLock: FileIdentity?
    /// What the lock path should name: the file the newest lock is on (the server's own, or `retakenLock`'s).
    private var lockFile: FileIdentity?
    /// The lock taken at the path again, on the file the path named then; -1: none. At most one: a newer one releases
    /// it. The server's own lock is the server's to close.
    private(set) var retakenLock: Int32 = -1
    /// The last line said about each path while it stays wrong, so a change nearby doesn't say it again.
    private var said: [String: String] = [:]
    private var folders: [Platform.FolderWatch] = []
    private var timer: DispatchSourceTimer?
    private var stopped = false
    /// Tests only: run just after each fresh listener is bound, before it is checked. On the host's queue.
    var afterBind: (() -> Void)?

    private init(server: HostServer, socketPath: String, lockPath: String) {
        self.server = server
        self.socketPath = socketPath
        self.lockPath = lockPath
    }

    /// The watch for `server`, which serves now on `config.socketPath` holding `lockFD` (its lock at
    /// `config.lockPath`): what both name recorded (the socket's only once checked), their folders watched, a check at
    /// each `config.housekeepingInterval`, and a first check at once (on the host's queue), so a path changed before
    /// this image began (during a handover's exec) is taken back now. `HostServer.serve`'s hook, for
    /// `config.watchesItsPath`.
    static func start(for server: HostServer, config: HostServer.Config, lockFD: Int32) -> HostPathWatch {
        let watch = HostPathWatch(server: server, socketPath: config.socketPath, lockPath: config.lockPath)
        watch.socketFile = verifiedIdentity(of: config.socketPath)
        var info = stat()
        if fstat(lockFD, &info) == 0 {
            watch.firstLock = FileIdentity(info)
            watch.lockFile = watch.firstLock
        }
        let queue = server.queue
        let folderPaths = Set([config.socketPath, config.lockPath].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for path in folderPaths.sorted() {
            guard let folder = Platform.FolderWatch(path: path) else {
                say(server, "can't watch \(path) for its paths: checked at each housekeeping only")
                continue
            }
            folder.deliver(on: queue) { [weak watch] _ in watch?.check() }
            watch.folders.append(folder)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.housekeepingInterval, repeating: config.housekeepingInterval)
        timer.setEventHandler { [weak watch] in watch?.check(atHousekeeping: true) }
        timer.resume()
        watch.timer = timer
        queue.async { [weak watch] in watch?.check() }
        return watch
    }

    /// Both paths checked, and each taken back that names something else. `atHousekeeping`: the socket path is also
    /// connected through (`leadsHere`), and a rebind that lost every attempt is tried again. On the host's queue.
    func check(atHousekeeping: Bool = false) {
        guard !stopped, let server, server.listenFD >= 0 else { return }
        if atHousekeeping || !rebindAtHousekeeping { checkSocket(server, probing: atHousekeeping) }
        checkLock(server)
    }

    /// The lock a handover carries in place of the server's own: the one taken at the path again, when there is one
    /// (`HostServer.handoverState`). On the host's queue.
    var lockToCarry: Int32? { retakenLock >= 0 ? retakenLock : nil }

    /// No more checks; the lock taken again released. On the host's queue (`HostServer.stop`).
    func stop() {
        guard !stopped else { return }
        stopped = true
        folders.forEach { $0.stop() }
        folders = []
        timer?.cancel()
        timer = nil
        releaseRetakenLock()
    }

    private func checkSocket(_ server: HostServer, probing: Bool) {
        let now = Self.identity(atPath: socketPath)
        let what: String
        if let now, now == socketFile {
            guard probing, !Self.leadsHere(socketPath) else {
                said[socketPath] = nil
                return
            }
            what = "a socket that didn't lead to the host"
        } else {
            what = now == nil ? "nothing" : "another file"
        }
        rebind(server, what)
    }

    /// A fresh listener at the socket path, kept only once checked (`verifiedIdentity`); up to `bindAttempts` times.
    private func rebind(_ server: HostServer, _ what: String) {
        var failure = "no listener bound there led to the host after \(Self.bindAttempts) tries"
        for _ in 0..<Self.bindAttempts {
            let fresh: Int32
            do {
                fresh = try UnixSocket.listen(path: socketPath)
            } catch {
                failure = "binding it again failed: \(error)"
                break
            }
            Platform.Sockets.enableCredentials(fresh)
            afterBind?()
            guard let bound = Self.verifiedIdentity(of: socketPath) else {
                Sys.close(fresh)
                continue
            }
            socketFile = bound
            rebindAtHousekeeping = false
            server.replaceListener(fresh)
            server.tally.replaced(socketPath)
            said[socketPath] = nil
            Self.say(server, "socket path \(socketPath) named \(what): bound a fresh listener there")
            return
        }
        socketFile = nil
        rebindAtHousekeeping = true
        sayOnce(server, socketPath, "socket path \(socketPath) names \(what), and \(failure): tried again at the next housekeeping")
    }

    private func checkLock(_ server: HostServer) {
        let now = Self.identity(atPath: lockPath)
        if let now, now == lockFile {
            said[lockPath] = nil
            return
        }
        if let now, now == firstLock {
            // The server's own lock file, put back: held already. A second open of it here would be refused by that
            // very lock (a lock belongs to the open file), and be said to be another process's.
            releaseRetakenLock()
            lockFile = firstLock
            said[lockPath] = nil
            Self.say(server, "lock path \(lockPath) names the host's own lock file again: holding that one only")
            return
        }
        let what = now == nil ? "nothing" : "another file"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return sayOnce(server, lockPath, "lock path \(lockPath) names \(what), and it can't be opened (errno \(errno))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Sys.close(fd)
            return sayOnce(server, lockPath, "lock path \(lockPath) names \(what), which another process holds locked (errno \(code))")
        }
        var info = stat()
        _ = fstat(fd, &info)
        let hadOne = retakenLock >= 0
        releaseRetakenLock()
        retakenLock = fd
        lockFile = FileIdentity(info)
        server.tally.replaced(lockPath)
        said[lockPath] = nil
        Self.say(server, "lock path \(lockPath) named \(what): locked the file there again, holding it beside the host's own"
                 + (hadOne ? " (the one locked again before released: it is no longer there)" : ""))
    }

    private func releaseRetakenLock() {
        guard retakenLock >= 0 else { return }
        Sys.close(retakenLock)
        retakenLock = -1
    }

    /// `line` said, unless it is what was said last about `path` while it stays wrong.
    private func sayOnce(_ server: HostServer, _ path: String, _ line: String) {
        guard said[path] != line else { return }
        said[path] = line
        Self.say(server, line)
    }

    /// What `path` names itself (a link not followed); nil when nothing can be read there.
    static func identity(atPath path: String) -> FileIdentity? {
        var info = stat()
        return lstat(path, &info) == 0 ? FileIdentity(info) : nil
    }

    /// What `path` names, when it is a socket file (not a link) that led to a listener of this process
    /// (`leadsHere`) and named the same file before and after; nil otherwise.
    static func verifiedIdentity(of path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, leadsHere(path) else { return nil }
        let before = FileIdentity(info)
        return identity(atPath: path) == before ? before : nil
    }

    /// Whether a connection made through `path` now (not waiting: a full backlog is a no) reaches a listener of this
    /// process: the connecting end's `SO_PEERCRED` names the process that listened. The connection is closed at once;
    /// the host's listener, when it was that, accepts it and sees it end.
    static func leadsHere(_ path: String) -> Bool {
        guard var address = Platform.Sockets.unixAddress(path) else { return false }
        let fd = Platform.Sockets.makeSocket(type: Platform.Sockets.stream)
        guard fd >= 0 else { return false }
        defer { Sys.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return connected == 0 && Platform.Sockets.peerPID(fd) == getpid()
    }

    /// A line in the host's log and on its stderr.
    private static func say(_ server: HostServer, _ line: String) {
        server.note("host: " + line)
        FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
    }
}

extension HostServer {
    /// `fd`, a listener bound at the socket's path, accepted from from now on in place of the one before, which is
    /// closed once its accept source has stopped. On `queue`.
    func replaceListener(_ fd: Int32) {
        let old = listenFD
        let oldSource = acceptSource
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source
        if let oldSource {
            oldSource.setCancelHandler { Sys.close(old) }
            oldSource.cancel()
        } else if old >= 0 {
            Sys.close(old)
        }
    }
}
