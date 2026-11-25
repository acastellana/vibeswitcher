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
/// - **`--node`** marks the node's host, the user's: it needs `--node-root` and `--server`, takes `HOME`, `SHELL`,
///   `USER` and `LOGNAME` from the user database, drops a locale variable naming a path, and unsets
///   `VIBESWITCHER_HOME` and `CFFIXED_USER_HOME` before anything reads a path (`nodeEnvironment`), so that
///   `VibePaths.root` is never the environment's (`startAsNode`), and takes no `--server` but its build's own, opened
///   once, no link followed, compared by device and inode, and copied from that same descriptor (`openServer`). The
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
    /// the user database), no `CFFIXED_USER_HOME`, and `VIBESWITCHER_HOME` the node's root or nothing, never the
    /// environment's, each of which would move `VibePaths.root` (and with it the lock `ownsLaunchers` compares) away from
    /// the node's: on Linux the node's root is the account's `~/.vibeswitcher`, so `VIBESWITCHER_HOME` is unset; on the
    /// Mac it is `~/.vibeswitcher/v2/node` (`Platform.Service.nodeRoot`), beside the app's folder and never it, so
    /// `VIBESWITCHER_HOME` names it, and the host's lock, socket, log and vault are there.
    ///
    /// And what the host passes on to every session (`Platform.Tools.sessionEnvironmentNames`) fixed from the user
    /// database too, not taken from the user manager's environment, whose values `start` doesn't check and any worker
    /// can set (`systemctl --user set-environment`, the step 8 sweep): `SHELL` is `shell` (`accountShell`: the login
    /// shell when only root can change it), which Claude Code runs its Bash tool through; `USER` and `LOGNAME` are
    /// `accountName` (left out when there is none); and a `LANG`, `LANGUAGE` or `LC_*` whose value holds a `/` is left
    /// out (glibc reads such a locale name as a path, to a locale or message catalogue the worker wrote).
    public static func nodeEnvironment(_ environment: [String: String], accountHome: String, accountName: String?, shell: String) -> [String: String] {
        var node = environment
        node["HOME"] = accountHome
        node["VIBESWITCHER_HOME"] = Platform.Service.nodeRootIsTheAccountRoot ? nil : Platform.Service.nodeRoot(accountHome: accountHome)
        node["CFFIXED_USER_HOME"] = nil
        node["SHELL"] = shell
        node["USER"] = accountName
        node["LOGNAME"] = accountName
        for (name, value) in environment where (name == "LANG" || name == "LANGUAGE" || name.hasPrefix("LC_")) && value.contains("/") {
            node[name] = nil
        }
        return node
    }

    /// The account's name in the user database (`getpwuid`), nil when it has none.
    public static var accountName: String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }

    /// The account's login shell in the user database, its links resolved (`realpath`), when only root can change it
    /// (`Platform.Tools.trustedShell`); `/bin/bash` otherwise.
    public static var accountShell: String {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let resolved = shell.flatMap { path -> String? in
            guard path.hasPrefix("/"), let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        return Platform.Tools.trustedShell(resolved)
    }

    /// Why `--node` is refused on the Mac (`startAsNode`).
    public static let macNodeRefusal = "\(nodeFlag): the node's host isn't built for the Mac yet (its server beside it, the rule for the user's voice, its launchd agent); "
        + "its root would be ~/.vibeswitcher/v2/node, never the app's ~/.vibeswitcher"

    /// The account's own home, from the user database (`getpwuid`): never the environment's. Nil when it has none.
    public static var accountHome: String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        return home.hasPrefix("/") ? home : nil
    }

    /// `main`'s first act after hardening, Linux only, with `--node` in `arguments`: it needs `--node-root` and
    /// `--server`, and the server must be its build's own (`openServer`), whose descriptor is then held for `load`
    /// (`holdServer`), which copies the server from it; then this process's environment is made `nodeEnvironment`'s.
    /// Why it may not start, or nil. Without `--node`: nil, nothing done. On the Mac `--node` is refused
    /// (`macNodeRefusal`): the node's host isn't built there (the node on the Mac's design, 2026-11-19, steps 3 to 5).
    /// Its root there is already its own (`nodeEnvironment`: `~/.vibeswitcher/v2/node`, step 2), so once the refusal
    /// goes, a `--node` host never takes the app's `~/.vibeswitcher` lock and socket. The app never passes `--node`, so
    /// its host is unchanged.
    public static func startAsNode(arguments: [String]) -> String? {
        guard arguments.contains(nodeFlag) else { return nil }
        if Platform.CodeIdentity.isAvailable {
            // The Mac: refused until its node start is switched on; then checked (`macNodeStart`) before anything else.
            guard isCheckedMacNode else { return macNodeRefusal }
            let home = accountHome
            let lock = value(after: "--lock", in: arguments)
                ?? ((home.map { Platform.Service.nodeRoot(accountHome: $0) } ?? "/nonexistent") as NSString).appendingPathComponent("host.lock")
            switch macNodeStart(arguments: arguments, lockPath: lock, own: Platform.CodeIdentity.ownCdhash(), pins: NodePins.read(), accountHome: home) {
            case .failure(let why): return why.description
            case .success(let checked):
                checkedServerLock.withLock { checkedMacNode = checked }
            }
            guard let home else { return "the account has no home in the user database" }
            let given = ProcessInfo.processInfo.environment
            let wanted = checkedNodeEnvironment(nodeEnvironment(given, accountHome: home, accountName: accountName, shell: accountShell))
            for name in Set(given.keys).union(wanted.keys) where given[name] != wanted[name] {
                if let value = wanted[name] { setenv(name, value, 1) } else { unsetenv(name) }
            }
            return nil
        }
        guard let nodeRoot = value(after: nodeRootFlag, in: arguments), nodeRoot.hasPrefix("/") else {
            return "\(nodeFlag) needs \(nodeRootFlag) and an absolute folder after it"
        }
        guard let server = value(after: "--server", in: arguments) else { return "\(nodeFlag) needs --server" }
        let checked: Int32
        switch openServer(server: server, nodeRoot: nodeRoot) {
        case .failure(let why): return why.description
        case .success(let fd): checked = fd
        }
        guard let home = accountHome else {
            Sys.close(checked)
            return "the account has no home in the user database"
        }
        holdServer(checked)
        let given = ProcessInfo.processInfo.environment
        let wanted = nodeEnvironment(given, accountHome: home, accountName: accountName, shell: accountShell)
        for name in Set(given.keys).union(wanted.keys) where given[name] != wanted[name] {
            if let value = wanted[name] { setenv(name, value, 1) } else { unsetenv(name) }
        }
        return nil
    }

    /// `server` opened once, for reading, when it is the node's own server, `<nodeRoot>/bin/vibeswitcher-server`: its
    /// descriptor (close-on-exec), the caller's. `server` is opened with `O_NOFOLLOW` (a symbolic link as the server is
    /// refused, not followed) and `O_NONBLOCK` (a FIFO is refused at once, not waited on), must be a regular file, and
    /// is the node's own when that descriptor's device and inode are what the node's path names (`lstat`, a link there
    /// refused): a second spelling of it is it, and so is a hard link to it, the same file. What is checked is the
    /// descriptor, so the server's copy made from it (`serverCopy`) is of the file checked, whatever the path names
    /// by then. Otherwise why not, nothing left open. The server names the app's principal (S2-D1): the node's host
    /// takes none but its install's.
    static func openServer(server: String, nodeRoot: String) -> Result<Int32, Refused> {
        let own = (nodeRoot as NSString).appendingPathComponent("bin/" + BuildInfo.server)
        let fd = open(server, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ELOOP: return .failure(Refused("the server \(server) is a symbolic link"))
            case ENOENT, ENOTDIR: return .failure(Refused("the server \(server) isn't there"))
            default: return .failure(Refused("the server \(server) couldn't be opened (errno \(code))"))
            }
        }
        func refused(_ why: String) -> Result<Int32, Refused> {
            Sys.close(fd)
            return .failure(Refused(why))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return refused("the server \(server) couldn't be read (errno \(errno))") }
        guard info.st_mode & S_IFMT == S_IFREG else { return refused("the server \(server) isn't a regular file") }
        var ownInfo = stat()
        guard lstat(own, &ownInfo) == 0 else { return refused("the node's server \(own) isn't there") }
        guard ownInfo.st_mode & S_IFMT != S_IFLNK else { return refused("the node's server \(own) is a symbolic link") }
        guard ownInfo.st_dev == info.st_dev, ownInfo.st_ino == info.st_ino else {
            return refused("the server \(server) isn't the node's own (\(own))")
        }
        return .success(fd)
    }

    /// The node's server's descriptor `startAsNode` checked (`openServer`), held until `load` takes it (`serverCopy`).
    private static let checkedServerLock = NSLock()
    nonisolated(unsafe) private static var checkedServer: Int32?

    /// `fd`, the node's server as `openServer` checked it, held for `serverCopy`; one held before is closed.
    static func holdServer(_ fd: Int32) {
        checkedServerLock.lock()
        defer { checkedServerLock.unlock() }
        if let held = checkedServer, held != fd { Sys.close(held) }
        checkedServer = fd
    }

    /// The node's server's held descriptor, taken (no longer held), or nil when there is none.
    static func takeCheckedServer() -> Int32? {
        checkedServerLock.lock()
        defer { checkedServerLock.unlock() }
        defer { checkedServer = nil }
        return checkedServer
    }

    /// The `--server` image's sealed copy, for `load`. The node's host's (`node`) is made from the descriptor its
    /// check opened (`startAsNode`, `takeCheckedServer`), then closed: never from `path` again, so a file put at the
    /// path after the check is not what runs; without one it refuses. Any other host's from `path`, as before.
    static func serverCopy(path: String, node: Bool) -> Result<Platform.ProcessSelf.SealedCopy, Refused> {
        let made: Result<Platform.ProcessSelf.SealedCopy, Platform.Errno>
        if node {
            guard let checked = takeCheckedServer() else {
                return .failure(Refused("\(BuildInfo.server): \(path) wasn't checked as the node's own before it was loaded"))
            }
            made = Platform.ProcessSelf.sealedCopy(of: checked, name: BuildInfo.server)
            Sys.close(checked)
        } else {
            made = Platform.ProcessSelf.sealedCopy(of: path, name: BuildInfo.server)
        }
        return made.mapError { Refused("\(BuildInfo.server): \(path) couldn't be loaded into a sealed copy (errno \($0.code))") }
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

    /// Whether this host is the Mac's node host from a checked `--node` start. Never yet: the Mac reads no `--node`
    /// (above), and every anchor such a check could compare against (the builds folder, its `build-info`, the job's
    /// program) is the user's to write, so a session could make one (docs/process/v2-mac-tasks.md, "Before
    /// approvalMeasured flips", the review of 2026-11-21: an anchor a session can't write). Until it is built, no Mac
    /// host is a node host (`HostServer.isMacNodeHost`) and none but a scratch host runs a server child.
    public static let isCheckedMacNode = false

    /// What a checked Mac node start found (the node on the Mac's design, "The checked node start"): its own build's row
    /// in the node's record, and its `--server` file's cdhash, that row's server. Only a host holding one is a node host
    /// (`HostServer.isMacNodeHost`); `main` makes one only behind `isCheckedMacNode`, tests through `macNodeStart`.
    public struct CheckedNode: Equatable, Sendable {
        public var build: NodePins.Build
        /// The `--server` path checked, and its cdhash (the row's server): what every start of the child is checked by.
        public var serverPath: String
        public var server: Data
    }

    /// The arguments a checked node takes (after its executable), and whether each takes a value: its own (the unit's
    /// and the agent's form) and a switch's. Every other is refused (`macNodeStart`, step 0).
    public static let checkedNodeArguments: [String: Bool] = [nodeFlag: false, nodeRootFlag: true, "--server": true, "--handover": true,
                                                              MacHandoverKeeper.channelFlag: true, MacHandoverKeeper.pidFlag: true]

    /// The Mac's checked node start (the node on the Mac's design, "The checked node start"): what this `--node` host
    /// is, or why it may not start, checked in this order: its arguments only its own (`checkedNodeArguments`, each
    /// once); its `--node-root` an absolute folder, which names only where its `--server` must be (by device and inode:
    /// a link to the build's folder, or any folder holding a byte copy of the pinned server, passes, since the row is
    /// found by code, never by that path), and `lockPath`
    /// the node's data root's own `host.lock` (`Platform.Service.nodeRoot` of the user database's home, `accountHome`; by
    /// path or by file; a link refused); the record
    /// (`pins`, read once by the caller) taken; its own running code (`own`, the kernel's cdhash) a row's host; its
    /// `--server` opened once as the node root's own `bin/vibeswitcher-server` (`openServer`: no link, a regular file, by
    /// device and inode), and that file's cdhash (`cdhashOf`, this Mac's slice, read while the path still names the file
    /// opened) the row's server. `main` asks it only behind `isCheckedMacNode`; tests give the record, the code and the
    /// home. Each refusal is one plain line.
    public static func macNodeStart(arguments: [String], lockPath: String, own: Data?, pins: Result<NodePins, NodePins.Refused>,
                                    accountHome: String?,
                                    cdhashOf: (String) -> Data? = { Platform.CodeIdentity.cdhash(atPath: $0) }) -> Result<CheckedNode, Refused> {
        func refused(_ why: String) -> Result<CheckedNode, Refused> { .failure(Refused(why)) }
        guard let accountHome else { return refused("the account has no home in the user database, so the node's root can't be found") }
        // 0. Its arguments: its own and a handover's, each once, and nothing else (the review's F1 and N5): no argument
        // left that changes who the app is, where it logs, what it locks or listens on, or what it runs.
        var seen = Set<String>()
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard let takesValue = checkedNodeArguments[flag] else { return refused("a checked node takes no \(flag): refused") }
            guard seen.insert(flag).inserted else { return refused("a checked node takes \(flag) once: refused") }
            index += takesValue ? 2 : 1
        }
        let dataRoot = Platform.Service.nodeRoot(accountHome: accountHome)
        guard let nodeRoot = value(after: nodeRootFlag, in: arguments), nodeRoot.hasPrefix("/") else {
            return refused("\(nodeFlag) needs \(nodeRootFlag) and its build's absolute folder after it")
        }
        guard let server = value(after: "--server", in: arguments) else { return refused("\(nodeFlag) needs --server") }
        // 1. The lock: the node root's own, and only it.
        let ownLock = (dataRoot as NSString).appendingPathComponent("host.lock")
        // By its exact path alone (the review's F2): `main` takes the user's host by comparing this path
        // (`HostHardening.ownsLaunchers`), so another spelling or a hard link elsewhere would make a checked node it
        // took for a scratch host.
        var held = stat()
        if lstat(lockPath, &held) == 0, held.st_mode & S_IFMT == S_IFLNK { return refused("the lock \(lockPath) is a symbolic link") }
        guard lockPath == ownLock else {
            return refused("\(nodeFlag) takes only the node root's own lock (\(ownLock)), not \(lockPath)")
        }
        // 2. The record. 3. This host's own running code, a row's host.
        let record: NodePins
        switch pins {
        case .failure(let why): return refused(why.description)
        case .success(let read): record = read
        }
        guard let own else { return refused("this host's own code can't be read, so its build in the node's record can't be found") }
        guard let build = record.build(host: own) else {
            return refused("this host's code (\(NodePins.hex(own))) is no host the node's record pins: not an installed build's host; \(NodePins.remedy)")
        }
        // 4. Its --server, opened once: the node root's own file, whose cdhash is the row's server.
        let fd: Int32
        switch openServer(server: server, nodeRoot: nodeRoot) {
        case .failure(let why): return .failure(why)
        case .success(let opened): fd = opened
        }
        defer { Sys.close(fd) }
        var opened = stat(), named = stat()
        let cdhash = cdhashOf(server)
        guard fstat(fd, &opened) == 0, lstat(server, &named) == 0, named.st_mode & S_IFMT == S_IFREG,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            return refused("the server \(server) changed while it was checked")
        }
        guard let cdhash else { return refused("\(server) has no code signature to check it by (no cdhash)") }
        guard cdhash == build.server else {
            return refused("\(server) (\(NodePins.hex(cdhash))) isn't the server the node's record pins for this host's build \(build.commit)")
        }
        return .success(CheckedNode(build: build, serverPath: server, server: cdhash))
    }

    /// Why `main` refuses a checked start (`checked`) it doesn't take for the user's host (`ownsLaunchers`), or nil: a
    /// checked node is always the user's host (its vault from disk, no test arguments for its server), never a scratch
    /// one (the review's F2; `macNodeStart` takes the lock by its exact path too, so neither can drift).
    public static func checkedNodeRefusal(_ checked: CheckedNode?, ownsLaunchers: Bool) -> String? {
        guard checked != nil, !ownsLaunchers else { return nil }
        return "a checked node start on a lock this host doesn't take for the user's: refused"
    }

    /// Why this image doesn't take `state`, or nil (the review's F1 and N2): a checked node's state (`fromCheckedNode`)
    /// goes only to an image holding its own checked start (`checkedNode`: so a wrapper that runs the pinned code
    /// without `--node`, or with another argument, gets nothing), and a checked node takes state only through a keeper it
    /// proved (`viaKeeper`), never from `--handover PATH` and the descriptors whoever started it left open. `main` then
    /// exits, which closes every descriptor it was given.
    public static func mayTakeHandover(_ state: HostHandover.State, viaKeeper: Bool, checkedNode: CheckedNode?) -> String? {
        if state.fromCheckedNode == true, checkedNode == nil {
            return "a checked node's state goes only to an image holding its own checked start: nothing taken"
        }
        if checkedNode != nil, !viaKeeper {
            return "a checked node takes state only through a keeper it proved, never from --handover PATH: nothing taken"
        }
        return nil
    }

    /// A checked node's environment from `environment` (the review's F1): no variable of this program's but
    /// `VIBESWITCHER_HOME` (the start sets it) and the descriptor limit the host carries across its own exec
    /// (`descriptorCarriedVariable`), so nothing in it moves the host's log (`VIBESWITCHER_HOST_LOG`) or holds its
    /// launchers; and no `SWIFT_BACKTRACE`, which can name a program the runtime starts on a crash.
    public static func checkedNodeEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            name != "SWIFT_BACKTRACE" && (!name.hasPrefix("VIBESWITCHER_") || name == "VIBESWITCHER_HOME" || name == descriptorCarriedVariable)
        }
    }

    /// The checked start `startAsNode` made on the Mac (behind `isCheckedMacNode`), held until `main` puts it in the
    /// host's config (`takeCheckedMacNode`).
    nonisolated(unsafe) private static var checkedMacNode: CheckedNode?

    /// The Mac's checked start `startAsNode` made, taken (no longer held); nil when there is none.
    public static func takeCheckedMacNode() -> CheckedNode? {
        checkedServerLock.lock()
        defer { checkedServerLock.unlock() }
        defer { checkedMacNode = nil }
        return checkedMacNode
    }

    /// The Mac's node host's server child (the node on the Mac's design, "The anchor", check 2): the cdhash the child is
    /// started and checked by, or why not. The host finds its own build by the code it runs (`own`,
    /// `Platform.CodeIdentity.ownCdhash`), in the node's record (`pins`, root's to write): no row, no child. Its
    /// `--server` file (`server`, read by `cdhashOf`, this Mac's slice) must be that row's server; the child is then
    /// started only while the file still has that cdhash, and its connector answers only a child whose token runs it
    /// (`ServerChild.Image.checked`). Asked only by a checked Mac node start (`isCheckedMacNode`, never yet).
    public static func macServerPin(server: String, own: Data?, pins: Result<NodePins, NodePins.Refused>,
                                    cdhashOf: (String) -> Data? = { Platform.CodeIdentity.cdhash(atPath: $0) }) -> Result<Data, Refused> {
        let record: NodePins
        switch pins {
        case .failure(let why): return .failure(Refused(why.description))
        case .success(let read): record = read
        }
        guard let own else { return .failure(Refused("this host's own code can't be read, so its build in the node's record can't be found")) }
        guard let build = record.build(host: own) else {
            return .failure(Refused("this host's code (\(NodePins.hex(own))) is no host the node's record pins: not an installed build's host; \(NodePins.remedy)"))
        }
        guard let cdhash = cdhashOf(server) else { return .failure(Refused("\(server) has no code signature to check it by (no cdhash)")) }
        guard cdhash == build.server else {
            return .failure(Refused("\(server) (\(NodePins.hex(cdhash))) isn't the server the node's record pins for this host's build \(build.commit)"))
        }
        return .success(cdhash)
    }

    /// The Mac: why this host may not run a `--server` child, or nil. Its child's connections through the connector
    /// are the app's (`.app`), so a host given `--server PATH` by anyone would make PATH the app: refused for the user's
    /// host (`ownsLaunchers`) and for any host on the account's own locks (the app's `~/.vibeswitcher/host.lock` and the
    /// node's root's, by the user database's home, compared by path and by file), unless it is a checked node start
    /// (`isCheckedMacNode`, never yet). A scratch host (its own lock, its vault in memory) may: what it lets through is
    /// no more than a session could start itself. Linux: nil (its server child is checked as `HostImages.load` says).
    public static func macServerRefusal(lockPath: String, ownsLaunchers: Bool, accountHome: String? = accountHome) -> String? {
        guard Platform.CodeIdentity.isAvailable, !isCheckedMacNode else { return nil }
        if ownsLaunchers { return "the user's host on the Mac runs no server child until its node start is checked" }
        guard let accountHome else { return "the account's home can't be read, so this host's lock can't be told from the account's" }
        let locks = [(accountHome as NSString).appendingPathComponent(".vibeswitcher/host.lock"),
                     (Platform.Service.nodeRoot(accountHome: accountHome) as NSString).appendingPathComponent("host.lock")]
        var held = stat()
        let heldRead = stat(lockPath, &held) == 0
        for lock in locks {
            var other = stat()
            if (lockPath as NSString).standardizingPath == (lock as NSString).standardizingPath
                || (heldRead && stat(lock, &other) == 0 && other.st_dev == held.st_dev && other.st_ino == held.st_ino) {
                return "the lock \(lockPath) is the account's own (\(lock)): only a checked node start runs a server child on it"
            }
        }
        return nil
    }

    /// `main`'s start check (Linux; the Mac: nil): `mayStart` for the lock it takes (`lockPath`) and, for the user's host
    /// (`ownsLaunchers`, by its probe or by the state a handover carried), for the user's lock (`usersLock`, its
    /// `VibePaths.hostLock`) too, so that whatever made it the user's host it passes the user's host's checks: on the
    /// account's own home (`usersLock` the account's lock) it needs `--node`, and with `--node` its lock is the
    /// account's. A new image whose carried state says the user's host while its probe of its own `--lock` says scratch
    /// is refused without `--node` there, as a fresh host on the account's lock is. A scratch home's user's host (the
    /// tests') needs none, as before. Any host, first: refused without a git only root can change on its PATH, or
    /// without the branch shell (`toolsRefusal`).
    public static func mayStart(lockPath: String, usersLock: String, accountRoot: String, node: Bool, ownsLaunchers: Bool) -> String? {
        if let why = toolsRefusal(missing: Platform.Tools.missing()) { return why }
        if let why = mayStart(lockPath: lockPath, accountRoot: accountRoot, node: node) { return why }
        guard ownsLaunchers, let why = mayStart(lockPath: usersLock, accountRoot: accountRoot, node: node) else { return nil }
        return "the user's host: " + why
    }

    /// Why a host may not start for what this machine lacks (`Platform.Tools.missing()`), or nil (Linux; the Mac: nil,
    /// as before): no `git` on PATH in a folder only root can change (`Platform.Tools.git`; one the user's account
    /// could write is never run), or no branch shell (the security architecture document's S9).
    static func toolsRefusal(missing: [String]) -> String? {
        guard !Platform.CodeIdentity.isAvailable, !missing.isEmpty else { return nil }
        let named = missing.map { $0 == "git" ? "git (none on PATH in a folder owned by root that only root can write)" : $0 }
        return "this machine lacks " + named.joined(separator: " and ")
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
        /// The command folder put on the sessions' PATH (`TestLock.commandFolder`), when there is one: first on the
        /// Mac, last on Linux (`sessionEnvironment`).
        public var commandFolder: String?
        /// The app's executable beside it, the default `HostServer.Config.appExecutable` (the Mac's).
        public var appExecutable: String
    }

    /// The folders of the build this host is, on Linux from `--node-root` (`<root>/bin/vibeswitcher-host`), else from
    /// `--image-path`, else from `executable`; on the Mac from `executable`, as always.
    public static func folders(arguments: [String], executable: String) -> Folders {
        let nodeRoot = Platform.CodeIdentity.isAvailable ? nil : value(after: nodeRootFlag, in: arguments)
        // The Mac's node: its server child is told the build's folder (`--node-root`), as on Linux (the review's N3).
        let macNodeRoot = Platform.CodeIdentity.isAvailable && arguments.contains(nodeFlag) ? value(after: nodeRootFlag, in: arguments) : nil
        let image = Platform.CodeIdentity.isAvailable ? executable
            : nodeRoot.map { ($0 as NSString).appendingPathComponent("bin/" + BuildInfo.host) }
                ?? value(after: imagePathFlag, in: arguments) ?? executable
        let folder = URL(fileURLWithPath: image).deletingLastPathComponent()
        return Folders(image: image, installFolder: nodeRoot ?? macNodeRoot ?? folder.path,
                       toolServer: folder.appendingPathComponent("vibeswitcher-mcp").path,
                       commandFolder: TestLock.commandFolder(besideExecutable: image),
                       appExecutable: folder.appendingPathComponent("VibeSwitcher").path)
    }

    // MARK: The sessions' PATH

    /// The sessions' environment `base` with the command folder (`folder`, `Folders.commandFolder`: `vs-heavy`'s) on
    /// its PATH, once. The Mac: first, as always (`TestLock.sessionEnvironment`). Linux: last, after every folder of
    /// the unit's PATH: the folder is the install's `<prefix>/<commit>/Resources/bin`, which the user's account (so any
    /// worker) can write and `build-info` doesn't hash, and first it would put a `git`, `sh` or `node` dropped there
    /// ahead of root's for every session, the lead's included; the unit's rule is root's folders first (S9, S11 item
    /// 10; the step 8 sweep, 2026-11-17). `vs-heavy` is the only program there, and no root folder has one.
    public static func sessionEnvironment(_ base: [String: String], adding folder: String?) -> [String: String] {
        guard !Platform.CodeIdentity.isAvailable, let folder else { return TestLock.sessionEnvironment(base, adding: folder) }
        var environment = base
        let rest = (base["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init).filter { $0 != folder }
        environment["PATH"] = (rest + [folder]).joined(separator: ":")
        return environment
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
    /// `build-info` (`BuildInfo.mismatch`); the node's host's `--server` copy is made from the descriptor `startAsNode`
    /// checked, not from its path (`serverCopy`). Last, a second copy of its own (`Loaded.launcher`), which `forSessions`
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
        // The record both images matched: what the host's notes and start line name (`HostStartLine`, the start plan's S5).
        func checked(_ result: Result<Loaded, Refused>) -> Result<Loaded, Refused> {
            if case .success = result { HostStartLine.record(info) }
            return result
        }
        guard let path = value(after: "--server", in: arguments) else { return checked(loaded(server: nil)) }
        switch serverCopy(path: path, node: arguments.contains(nodeFlag)) {
        case .failure(let why):
            return refused(why.description, closing: [own])
        case .success(let server):
            if let mismatch = info.mismatch(of: server, as: BuildInfo.server) { return refused(mismatch, closing: [own, server]) }
            return checked(loaded(server: server))
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
        let limit = descriptorSoftBefore.get().map { ["\(descriptorLimitVariable)=\($0)"] } ?? []
        let prefix = "/proc/self/fd/"
        let unlimited = environment.filter { !$0.hasPrefix(descriptorLimitVariable + "=") }
        guard launcher.hasPrefix(prefix), let fd = Int32(launcher.dropFirst(prefix.count)), fd > STDERR_FILENO,
              fcntl(fd, F_GETFD) >= 0 else { return ([], unlimited + limit) }
        let variable = Platform.ProcessSelf.imageVariable
        let given = unlimited.filter { !$0.hasPrefix(variable + "=") && !$0.hasPrefix(launcherTestHoldVariable + "=") } + limit
        guard Platform.ProcessSelf.restoreMode(of: fd) else { return ([], given) }
        let hold = sessions { $0.launcher == launcher ? $0.hold : nil }
        return ([fd], given + ["\(variable)=\(fd)"] + (hold.map { ["\(launcherTestHoldVariable)=\($0)"] } ?? []))
    }

    /// The host's soft limit on open descriptors raised to its hard limit, at its start (the architecture review's row
    /// 4): it holds a descriptor per session, parser and client, and its server child (which inherits the limit) one per
    /// connection, where the usual soft 1,024 is reached long before the hard limit. A session's program gets the soft
    /// limit back (`beforeProgram`, through `descriptorLimitVariable`): it may use `select`, which can't take a
    /// descriptor past 1,023. Any system; once.
    ///
    /// The soft limit before is carried across a handover in the host's own environment (`descriptorCarriedVariable`,
    /// which both forms of the handover's exec pass on): the new image starts with the limit raised already, and would
    /// otherwise give its sessions the hard one. Taken only by an image a handover started (`handedOver`), and only
    /// within `carriedValue`'s bounds: a fresh start's environment is the user manager's, which any process of the user
    /// can set (`systemctl --user set-environment`), and a value of 0 would leave every session unable to open a file.
    /// A value refused is said on stderr; the variable is unset either way before this image sets its own.
    public static func raiseDescriptorLimit(handedOver: Bool) {
        guard descriptorSoftBefore.get() == nil else { return }
        let given = getenv(descriptorCarriedVariable).map { String(cString: $0) }
        unsetenv(descriptorCarriedVariable)
        let hard = Platform.ProcessSelf.descriptorLimits()?.hard
        switch carriedValue(given, handedOver: handedOver, hard: hard) {
        case .some(.success(let carried)):
            descriptorSoftBefore.set(carried)
            Platform.ProcessSelf.raiseDescriptorLimit()
            setenv(descriptorCarriedVariable, String(carried), 1)
            return
        case .some(.failure(let why)):
            Platform.Stdio.error("vibeswitcher-host: \(descriptorCarriedVariable) not taken: \(why)\n")
        case nil:
            break
        }
        guard let before = Platform.ProcessSelf.raiseDescriptorLimit() else { return }
        descriptorSoftBefore.set(before)
        setenv(descriptorCarriedVariable, String(before), 1)
    }

    /// The fewest open files a session is given back (`carriedValue`): the soft limit systemd and most systems start with.
    static let descriptorFloor: UInt64 = 1024

    /// What the carried soft limit `given` says: nil when there is none; the value, for an image a handover started
    /// (`handedOver`), from `descriptorFloor` to the hard limit (`hard`, when known); why it is refused otherwise.
    static func carriedValue(_ given: String?, handedOver: Bool, hard: UInt64?) -> Result<UInt64, Refused>? {
        guard let given else { return nil }
        guard handedOver else { return .failure(Refused("a fresh start takes none (only an image a handover started)")) }
        guard let value = UInt64(given) else { return .failure(Refused("\(ConfigSeal.inert(given, limit: 40)) isn't a number")) }
        guard value >= descriptorFloor else { return .failure(Refused("\(value) is under \(descriptorFloor)")) }
        if let hard, value > hard { return .failure(Refused("\(value) is over the hard limit, \(hard)")) }
        return .success(value)
    }

    /// The host's soft limit before it raised it, in its own environment, for the image a handover starts.
    static let descriptorCarriedVariable = "VIBESWITCHER_HOST_NOFILE_BEFORE"

    /// The soft limit the host had before `raiseDescriptorLimit`, nil when it raised none.
    static let descriptorSoftBefore = SoftLimit()
    /// How the soft limit before reaches a session's launcher: set by `launching`, read and unset by `beforeProgram`.
    static let descriptorLimitVariable = "VIBESWITCHER_LAUNCHER_NOFILE"

    final class SoftLimit: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64?
        func get() -> UInt64? { lock.withLock { value } }
        func set(_ new: UInt64?) { lock.withLock { value = new } }
    }

    /// The launcher's last act before it execs the session's program, after its terminal check (Linux; the Mac:
    /// nothing): dumpable again (started from an unreadable copy, its /proc entries are root's, and it holds nothing by
    /// now that the program won't hold a moment later; its image is the launchers' own copy, `forSessions`), then its
    /// `oom_score_adj` raised by `oomRaise` (at most 1000), which the program keeps. A failed write is said on the
    /// terminal (descriptor 2), and the launch goes on. Then, a scratch host's test only, held until the file its
    /// host named exists (`holdLaunchers(until:)`, at most a minute), the hold's variable gone from what the program
    /// gets.
    static func beforeProgram() {
        // The host's soft limit on descriptors before it raised it (`raiseDescriptorLimit`), given back, on any system.
        if let given = getenv(descriptorLimitVariable).flatMap({ UInt64(String(cString: $0)) }) { Platform.ProcessSelf.setDescriptorSoftLimit(given) }
        unsetenv(descriptorLimitVariable)
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
}
