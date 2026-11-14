import Foundation
import VibeCore

/// The host keeps its path (the stage 2 plan's Task 8b, the security architecture document's S2): a worker can put its
/// own socket at the host's socket path (renamed over it), or another file at its lock path, and sessions' tool
/// servers and hooks would reach that socket, and a second host could take that lock. The user's host
/// (`HostServer.Config.watchesItsPath`) watches the folders of both paths (`Platform.FolderWatch`) and, at each change
/// there and at each housekeeping interval, checks that each path still names what it bound and what it locked: the
/// device and inode recorded when it began serving (the socket's file by `lstat` just after its bind, or, after a
/// handover, as the path named it when this image began; the lock by its descriptor's `fstat`).
///
/// - The socket path naming something else, or nothing: what is there is removed, a fresh listener bound there
///   (`UnixSocket.listen`, its senders passed before its first accept), swapped in for the accept source, and the old
///   listener closed. Clients that connected to what was there stay its; the next ones are the host's.
/// - The lock path naming something else, or nothing: the file there is locked again and held beside the first lock,
///   or, when another process holds it, that is said.
///
/// Each is a line in the host's log and on its stderr (the user journal, through the unit), and each path taken back
/// is counted for `hostNotes` (`HostTally`). Not on the Mac (`watchesItsPath` is false there), and not in a scratch
/// host unless its test sets it. On the host's queue throughout.
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

    private weak var server: HostServer?
    let socketPath: String
    let lockPath: String
    /// What the socket path should name: the listener's file. Nil: nothing could be read there.
    private var socketFile: FileIdentity?
    /// What the lock path should name: the file the newest lock is on.
    private var lockFile: FileIdentity?
    /// The locks taken at the path again (the first is the server's own, closed by it).
    private var heldLocks: [Int32] = []
    /// The last line said about each path while it stays wrong, so a change nearby doesn't say it again.
    private var said: [String: String] = [:]
    private var folders: [Platform.FolderWatch] = []
    private var timer: DispatchSourceTimer?
    private var stopped = false

    private init(server: HostServer, socketPath: String, lockPath: String) {
        self.server = server
        self.socketPath = socketPath
        self.lockPath = lockPath
    }

    /// The watch for `server`, which serves now on `config.socketPath` holding `lockFD` (its lock at
    /// `config.lockPath`): what both name recorded, their folders watched, and a check at each
    /// `config.housekeepingInterval`. `HostServer.serve`'s hook, for `config.watchesItsPath`.
    static func start(for server: HostServer, config: HostServer.Config, lockFD: Int32) -> HostPathWatch {
        let watch = HostPathWatch(server: server, socketPath: config.socketPath, lockPath: config.lockPath)
        watch.socketFile = identity(atPath: config.socketPath)
        var info = stat()
        if fstat(lockFD, &info) == 0 { watch.lockFile = FileIdentity(info) }
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
        timer.setEventHandler { [weak watch] in watch?.check() }
        timer.resume()
        watch.timer = timer
        return watch
    }

    /// Both paths checked, and each taken back that names something else. On the host's queue.
    func check() {
        guard !stopped, let server, server.listenFD >= 0 else { return }
        checkSocket(server)
        checkLock(server)
    }

    /// No more checks; the locks taken again released. On the host's queue (`HostServer.stop`).
    func stop() {
        guard !stopped else { return }
        stopped = true
        folders.forEach { $0.stop() }
        folders = []
        timer?.cancel()
        timer = nil
        heldLocks.forEach { Sys.close($0) }
        heldLocks = []
    }

    private func checkSocket(_ server: HostServer) {
        let now = Self.identity(atPath: socketPath)
        if let now, now == socketFile {
            said[socketPath] = nil
            return
        }
        let what = now == nil ? "nothing" : "another file"
        do {
            let fresh = try UnixSocket.listen(path: socketPath)
            Platform.Sockets.enableCredentials(fresh)
            socketFile = Self.identity(atPath: socketPath)
            server.replaceListener(fresh)
            server.tally.replaced(socketPath)
            said[socketPath] = nil
            Self.say(server, "socket path \(socketPath) named \(what): bound a fresh listener there")
        } catch {
            sayOnce(server, socketPath, "socket path \(socketPath) names \(what), and binding it again failed: \(error)")
        }
    }

    private func checkLock(_ server: HostServer) {
        let now = Self.identity(atPath: lockPath)
        if let now, now == lockFile {
            said[lockPath] = nil
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
        lockFile = FileIdentity(info)
        heldLocks.append(fd)
        server.tally.replaced(lockPath)
        said[lockPath] = nil
        Self.say(server, "lock path \(lockPath) named \(what): locked the file there again, holding both")
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
