import Foundation
import VibeCore

/// What the host executes, and where its build's files are (the stage 2 plan's Task 9b, S2-D7; the security
/// architecture document's S6 and S9).
///
/// - **Its own sealed copy.** At its start the host reads its own image (`/proc/self/exe`, the inode this process runs,
///   which can't be written in place while it runs) once into a sealed copy (`Platform.ProcessSelf.sealedCopy`), and
///   every parser is started from that copy, and every session's launcher from a second copy of the same bytes made
///   from it, the launchers' own (`forSessions`, then `launching(_:environment:)`; hooks in `PTYSpawn.spawn` and one
///   in `ParserLink.start`): no launcher copy is written under `~/.vibeswitcher/host`, a file changed on disk after the
///   host loaded it is never what a session starts through, and the launcher and the parser, started from an image
///   they can't read, are non-dumpable from their exec. Each closes the copy as its first act
///   (`Platform.ProcessSelf.closeInheritedImage`), so a session's program never holds it; the launcher then makes
///   itself dumpable again and raises its `oom_score_adj` by 500 (`beforeProgram`), so that the kernel's OOM killer
///   picks a session's program before the host. Dumpable, its `/proc/<pid>/exe` lets any process of the user `chmod`
///   the copy it runs, which is why that copy is never the parsers' (`forSessions` says more). After a handover the
///   new image's own copy is the target's sealed copy the old image loaded and executed (Task 9c, `HandoverMemory`),
///   adopted from the descriptor it passes (a script stand-in's can't be: made afresh then, as at a fresh start); its
///   launchers' copy is always made afresh, never carried.
/// - **`build-info`.** With `--node-root FOLDER` (a build folder: `FOLDER/bin/…`, `FOLDER/build-info`), the own copy's
///   SHA-256, and the `--server` image's (loaded here, so the copy checked is the copy that runs), must be what
///   `FOLDER/build-info` records (`BuildInfo`), or the host doesn't start, saying which binary.
/// - **`--node`** marks the node's host, the user's: it needs `--node-root` and `--server`, takes `HOME` from the user
///   database and unsets `VIBESWITCHER_HOME` and `CFFIXED_USER_HOME` before anything reads a path, so that
///   `VibePaths.root` is never the environment's (`startAsNode`), and takes no `--server` but its build's own. The
///   account's own lock (`~/.vibeswitcher/host.lock`, by the user database) is held by a `--node` host and only by one
///   (`mayStart`): `ownsLaunchers` (the security rules) and `--node` (the install's) can't come apart on the real home.
/// - **The build's folders** (`folders(arguments:executable:)`): `vibeswitcher-mcp`, the command folder, the app's
///   default executable and the build id come from `--node-root`, else from `--image-path` (a scratch host started from
///   a copy, whose `/proc/self/exe` names `/memfd:…`), else from the executable, as before.
///
/// The Mac: none of it. Its launcher is the private copy `main` keeps under `~/.vibeswitcher/host`, its folders are
/// its executable's, and `--node`, `--node-root` and `--image-path` are not read.
public enum HostImages {
    public static let nodeFlag = "--node"
    public static let nodeRootFlag = "--node-root"
    public static let imagePathFlag = "--image-path"

    /// Why the host didn't start.
    public struct Refused: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: --node

    /// The environment a `--node` host runs with, from `environment`: `HOME` the account's own home (`accountHome`, from
    /// the user database), and neither `VIBESWITCHER_HOME` nor `CFFIXED_USER_HOME`, each of which would move
    /// `VibePaths.root` (and with it the lock `ownsLaunchers` compares) away from the account's.
    public static func nodeEnvironment(_ environment: [String: String], accountHome: String) -> [String: String] {
        var node = environment
        node["HOME"] = accountHome
        node["VIBESWITCHER_HOME"] = nil
        node["CFFIXED_USER_HOME"] = nil
        return node
    }

    /// The account's own home, from the user database (`getpwuid`): never the environment's. Nil when it has none.
    public static var accountHome: String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        return home.hasPrefix("/") ? home : nil
    }

    /// `main`'s first act after hardening, Linux only, with `--node` in `arguments`: it needs `--node-root` and
    /// `--server`, and the server must be its build's own (`serverRefusal`); then this process's environment is made
    /// `nodeEnvironment`'s. Why it may not start, or nil. Without `--node`, and on the Mac: nil, nothing done.
    public static func startAsNode(arguments: [String]) -> String? {
        guard !Platform.CodeIdentity.isAvailable, arguments.contains(nodeFlag) else { return nil }
        guard let nodeRoot = value(after: nodeRootFlag, in: arguments), nodeRoot.hasPrefix("/") else {
            return "\(nodeFlag) needs \(nodeRootFlag) and an absolute folder after it"
        }
        guard let server = value(after: "--server", in: arguments) else { return "\(nodeFlag) needs --server" }
        if let why = serverRefusal(server: server, nodeRoot: nodeRoot) { return why }
        guard let home = accountHome else { return "the account has no home in the user database" }
        let wanted = nodeEnvironment(ProcessInfo.processInfo.environment, accountHome: home)
        setenv("HOME", home, 1)
        for name in ["VIBESWITCHER_HOME", "CFFIXED_USER_HOME"] where wanted[name] == nil { unsetenv(name) }
        return nil
    }

    /// Why `server` isn't the node's own server, `<nodeRoot>/bin/vibeswitcher-server`, or nil when it is: compared once
    /// both are resolved (`realpath`), so a second spelling of it is it; a symbolic link as the server (`lstat`) is
    /// refused, as is a server that isn't there. The server names the app's principal (S2-D1): the node's host takes
    /// none but its install's.
    public static func serverRefusal(server: String, nodeRoot: String) -> String? {
        let own = (nodeRoot as NSString).appendingPathComponent("bin/" + BuildInfo.server)
        var info = stat()
        guard lstat(server, &info) == 0 else { return "the server \(server) isn't there" }
        guard info.st_mode & S_IFMT != S_IFLNK else { return "the server \(server) is a symbolic link" }
        guard let given = realPath(server), let expected = realPath(own) else { return "the node's server \(own) isn't there" }
        guard given == expected else { return "the server \(server) isn't the node's own (\(own))" }
        var ownInfo = stat()
        guard lstat(own, &ownInfo) == 0, ownInfo.st_mode & S_IFMT != S_IFLNK else { return "the node's server \(own) is a symbolic link" }
        return nil
    }

    /// Why a host told to take `lockPath` may not start, or nil (Linux; the Mac: nil): the account's own lock
    /// (`<accountRoot>/host.lock`, `accountRoot` the account's own `~/.vibeswitcher` from the user database) is taken
    /// by the node's host (`node`) and only by it, whatever the lock's spelling (by identity, as `HostHardening.lock`),
    /// and the node's host takes no other. A symbolic link as the lock is refused, as `HostHardening.ownsLaunchers`
    /// refuses it. A scratch home's lock is not the
    /// account's.
    public static func mayStart(lockPath: String, accountRoot: String, node: Bool) -> String? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        let accountLock = (accountRoot as NSString).appendingPathComponent("host.lock")
        let lock = HostHardening.lock(lockPath, usersLock: accountLock)
        guard lock != .link else { return "the lock \(lockPath) is a symbolic link" }
        let isAccounts = lock == .users || (lockPath as NSString).standardizingPath == (accountLock as NSString).standardizingPath
        switch (isAccounts, node) {
        case (true, false):
            return "the lock \(lockPath) is the account's own: only the node's host (\(nodeFlag) \(nodeRootFlag) FOLDER --server PATH) takes it"
        case (false, true):
            return "\(nodeFlag) takes only the account's own lock (\(accountLock)), not \(lockPath)"
        default:
            return nil
        }
    }

    // MARK: The build's folders

    /// Where a host's build's files are.
    public struct Folders: Equatable, Sendable {
        /// The host's image as its build names it, never executed by this: its build id (`HostBuild.id`), the folder
        /// of the rest, and the name a fallback is given (`HandoverMemory.fallbackImageFlag`; its sealed copy is what runs).
        public var image: String
        /// The install folder the server child is told (`--node-root`): `--node-root`'s, else the image's folder.
        public var installFolder: String
        /// The tool server beside it (`HostServer.Config.toolServer`).
        public var toolServer: String
        /// The command folder put first on the sessions' PATH (`TestLock.commandFolder`), when there is one.
        public var commandFolder: String?
        /// The app's executable beside it, the default `HostServer.Config.appExecutable` (the Mac's).
        public var appExecutable: String
    }

    /// The folders of the build this host is, on Linux from `--node-root` (`<root>/bin/vibeswitcher-host`), else from
    /// `--image-path`, else from `executable`; on the Mac from `executable`, as always.
    public static func folders(arguments: [String], executable: String) -> Folders {
        let nodeRoot = Platform.CodeIdentity.isAvailable ? nil : value(after: nodeRootFlag, in: arguments)
        let image = Platform.CodeIdentity.isAvailable ? executable
            : nodeRoot.map { ($0 as NSString).appendingPathComponent("bin/" + BuildInfo.host) }
                ?? value(after: imagePathFlag, in: arguments) ?? executable
        let folder = URL(fileURLWithPath: image).deletingLastPathComponent()
        return Folders(image: image, installFolder: nodeRoot ?? folder.path,
                       toolServer: folder.appendingPathComponent("vibeswitcher-mcp").path,
                       commandFolder: TestLock.commandFolder(besideExecutable: image),
                       appExecutable: folder.appendingPathComponent("VibeSwitcher").path)
    }

    // MARK: The sealed copies

    /// The copies a host runs from: its own (the parsers'), the sessions' launchers' (a second copy of the same bytes,
    /// `launcher`), and with `--node-root` its server's (nil otherwise: `ServerChild` loads it then, as before). All nil
    /// on the Mac.
    public struct Loaded {
        public var own: Platform.ProcessSelf.SealedCopy?
        public var server: Platform.ProcessSelf.SealedCopy?
        /// The copy sessions' launchers start from (`forSessions`), never a parser, never carried across a handover.
        public var launcher: Platform.ProcessSelf.SealedCopy?

        public init(own: Platform.ProcessSelf.SealedCopy?, server: Platform.ProcessSelf.SealedCopy?,
                    launcher: Platform.ProcessSelf.SealedCopy? = nil) {
            self.own = own
            self.server = server
            self.launcher = launcher
        }
    }

    /// The name of the sessions' launchers' copy (`/memfd:vibeswitcher-launcher` in /proc's links).
    static let launcherCopyName = "vibeswitcher-launcher"

    /// What `forSessions` and `launching` read: the own copy's path, the launchers' copy's, and the test hold.
    private struct Sessions {
        var own: String?
        /// The own copy itself: a handover's fallback (Task 9c, `HandoverMemory`).
        var ownCopy: Platform.ProcessSelf.SealedCopy?
        var launcher: String?
        var hold: String?
    }

    private static let sessionsLock = NSLock()
    nonisolated(unsafe) private static var sessionsState = Sessions()

    private static func sessions<T>(_ body: (inout Sessions) -> T) -> T {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return body(&sessionsState)
    }

    /// On Linux: the sealed copy this process was started from (`VIBESWITCHER_IMAGE_FD`, a test's now, a handover's from
    /// Task 9c) adopted as its own when it is one (`Platform.ProcessSelf.adopt`: all four seals, mode `0111`), since
    /// `/proc/self/exe` then names an image this process can't read; otherwise that descriptor closed and its own image
    /// read into a fresh sealed copy. With `--node-root`, that copy and the `--server` image's are checked against its
    /// `build-info` (`BuildInfo.mismatch`). Last, a second copy of its own (`Loaded.launcher`), which `forSessions`
    /// gives sessions' launchers from then on. The Mac: nothing loaded. Fails, nothing left open, saying why.
    public static func load(arguments: [String]) -> Result<Loaded, Refused> {
        guard !Platform.CodeIdentity.isAvailable else { return .success(Loaded(own: nil, server: nil)) }
        let own: Platform.ProcessSelf.SealedCopy
        let inherited = Platform.ProcessSelf.takeInheritedImage()
        if let inherited, let adopted = Platform.ProcessSelf.adopt(inherited) {
            own = adopted
        } else {
            if let inherited { Sys.close(inherited) }
            switch Platform.ProcessSelf.sealedCopy(of: "/proc/self/exe", name: BuildInfo.host) {
            case .success(let copy): own = copy
            case .failure(let error): return .failure(Refused("its own image couldn't be loaded into a sealed copy (errno \(error.code))"))
            }
        }
        func refused(_ why: String, closing copies: [Platform.ProcessSelf.SealedCopy]) -> Result<Loaded, Refused> {
            for copy in copies { Sys.close(copy.fd) }
            return .failure(Refused(why))
        }
        // The sessions' launchers' own copy, made last, once the rest is checked.
        func loaded(server: Platform.ProcessSelf.SealedCopy?) -> Result<Loaded, Refused> {
            switch Platform.ProcessSelf.sealedCopy(of: own, name: launcherCopyName) {
            case .failure(let error):
                return refused("its launchers' sealed copy couldn't be made (errno \(error.code))", closing: [own] + (server.map { [$0] } ?? []))
            case .success(let launcher):
                sessions { $0.own = own.path; $0.ownCopy = own; $0.launcher = launcher.path }
                return .success(Loaded(own: own, server: server, launcher: launcher))
            }
        }
        guard let nodeRoot = value(after: nodeRootFlag, in: arguments) else { return loaded(server: nil) }
        let info: BuildInfo
        switch BuildInfo.read(buildFolder: nodeRoot) {
        case .success(let read): info = read
        case .failure(let why): return refused("its build-info: \(why)", closing: [own])
        }
        if let mismatch = info.mismatch(of: own, as: BuildInfo.host) { return refused(mismatch, closing: [own]) }
        guard let path = value(after: "--server", in: arguments) else { return loaded(server: nil) }
        switch Platform.ProcessSelf.sealedCopy(of: path, name: BuildInfo.server) {
        case .failure(let error):
            return refused("\(BuildInfo.server): \(path) couldn't be loaded into a sealed copy (errno \(error.code))", closing: [own])
        case .success(let server):
            if let mismatch = info.mismatch(of: server, as: BuildInfo.server) { return refused(mismatch, closing: [own, server]) }
            return loaded(server: server)
        }
    }

    // MARK: The launcher and the parsers

    /// This host's own sealed copy (`load`), which a handover carries for its fallback (`HandoverMemory`); nil before
    /// it is loaded, on the Mac, and in a host that isn't a process of its own (a test runner's).
    static var ownCopy: Platform.ProcessSelf.SealedCopy? { sessions { $0.ownCopy } }

    /// The image `PTYSpawn.spawn` starts a session's launcher from, for the host's `launcher`: on Linux, when it is the
    /// host's own copy, the launchers' own copy (`Loaded.launcher`); otherwise `launcher` as given (the Mac's launcher
    /// copy, a test's in-process host's, a host not loaded yet).
    ///
    /// **Why a copy of their own** (the 9b review, 2026-11-14): a launcher makes itself dumpable before it execs the
    /// session's program (`beforeProgram`), and from then until its exec any process of the user may resolve
    /// `/proc/<launcher>/exe`, the copy it was started from, and `chmod` it readable (the seals don't stop a `chmod`;
    /// a non-dumpable process's link is refused to all but root). A copy that is readable starts dumpable children,
    /// so were it the parsers' copy, every parser after it would be reachable from its exec until it hardens. The
    /// launchers' copy is started by launchers only, which make themselves dumpable anyway and hold nothing by then that
    /// the session's program won't; `launching` puts its mode back before each start all the same.
    static func forSessions(_ launcher: String) -> String {
        sessions { $0.own == launcher ? $0.launcher : nil } ?? launcher
    }

    /// What `PTYSpawn.spawn` and `ParserLink.start` start their child with, for `launcher` and the child's
    /// `environment`: when `launcher` is a sealed copy this process holds (`/proc/self/fd/N`, on Linux the host's own
    /// for a parser and the launchers' for a session), its mode put back if anything changed it
    /// (`Platform.ProcessSelf.restoreMode`), N kept in the child (else its path is gone before the exec resolves it)
    /// and named to it in `VIBESWITCHER_IMAGE_FD`, so that its first act closes it; a scratch host's test hold named
    /// to a session's launcher (`holdLaunchers(until:)`), and to nothing else. Otherwise nothing kept and the
    /// environment as given (the Mac's launcher, a test's in-process host's). A copy whose mode can't be put back is
    /// not kept, so the child isn't started from it.
    static func launching(_ launcher: String, environment: [String]) -> (keep: [Int32], environment: [String]) {
        let prefix = "/proc/self/fd/"
        guard launcher.hasPrefix(prefix), let fd = Int32(launcher.dropFirst(prefix.count)), fd > STDERR_FILENO,
              fcntl(fd, F_GETFD) >= 0 else { return ([], environment) }
        let variable = Platform.ProcessSelf.imageVariable
        let given = environment.filter { !$0.hasPrefix(variable + "=") && !$0.hasPrefix(launcherTestHoldVariable + "=") }
        guard Platform.ProcessSelf.restoreMode(of: fd) else { return ([], given) }
        let hold = sessions { $0.launcher == launcher ? $0.hold : nil }
        return ([fd], given + ["\(variable)=\(fd)"] + (hold.map { ["\(launcherTestHoldVariable)=\($0)"] } ?? []))
    }

    /// The launcher's last act before it execs the session's program, after its terminal check (Linux; the Mac:
    /// nothing): dumpable again (started from an unreadable copy, its /proc entries are root's, and it holds nothing by
    /// now that the program won't hold a moment later; its image is the launchers' own copy, `forSessions`), then its
    /// `oom_score_adj` raised by `oomRaise` (at most 1000), which the program keeps. A failed write is said on the
    /// terminal (descriptor 2), and the launch goes on. Then, a scratch host's test only, held until the file its
    /// host named exists (`holdLaunchers(until:)`, at most a minute), the hold's variable gone from what the program
    /// gets.
    static func beforeProgram() {
        guard !Platform.CodeIdentity.isAvailable else { return }
        let hold = getenv(launcherTestHoldVariable).map { String(cString: $0) }
        unsetenv(launcherTestHoldVariable)
        _ = Platform.ProcessSelf.makeDumpable()
        if let why = raiseOOMScore(by: oomRaise) {
            let said = "VibeSwitcher: this session's oom_score_adj wasn't raised: \(why)\r\n"
            _ = said.withCString { write(2, $0, strlen($0)) }
        }
        if let hold {
            for _ in 0..<6_000 where access(hold, F_OK) != 0 { usleep(10_000) }
        }
    }

    /// A scratch host's test flag (Linux; refused by the user's host, `HostHardening.testFlags`): its sessions'
    /// launchers wait after `beforeProgram`, dumpable and still running the launchers' copy, until the file after it
    /// exists, so a test can reach them there (`HostHardeningTests.aLaunchersImageChangedFromOutsideNeverReachesTheParsers`).
    public static let launcherTestHoldFlag = "--launcher-test-hold"
    /// How the hold reaches a launcher: set by `launching` alone, for a session's launcher of a host told to hold.
    static let launcherTestHoldVariable = "VIBESWITCHER_LAUNCHER_TEST_HOLD"

    /// Sessions' launchers started from now on are held until the file at `path` exists (`launcherTestHoldFlag`).
    static func holdLaunchers(until path: String) {
        sessions { $0.hold = path }
    }

    /// How much a session's program's `oom_score_adj` is above the host's.
    static let oomRaise = 500

    /// This process's `oom_score_adj` raised by `amount` (to at most 1000): nil when it was, else why not.
    static func raiseOOMScore(by amount: Int) -> String? {
        let fd = open("/proc/self/oom_score_adj", O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { Sys.close(fd) }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, let now = Int(String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "its value couldn't be read"
        }
        let raised = Array("\(min(1000, now + amount))".utf8)
        guard lseek(fd, 0, SEEK_SET) == 0, write(fd, raised, raised.count) == raised.count else { return String(cString: strerror(errno)) }
        return nil
    }

    // MARK: Arguments

    /// The argument after `flag` in `arguments`, as `main`'s `value(after:)` reads it: nil without one.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `path` resolved (`realpath`), or nil when it can't be.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
