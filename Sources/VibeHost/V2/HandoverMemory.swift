import Foundation
import VibeCore

/// The sealed images a handover carries across the exec (S2-D8, S2-D7): the new image's own copy, the old image's own
/// copy for a fallback, and with an install root the new build's server (Task 9d). Each a descriptor the exec keeps.
public struct HandoverImages: Codable, Equatable {
    /// The target's sealed copy, what the exec runs: the new image's own copy, which it adopts.
    public var own: Int32
    /// The handing-over image's own sealed copy, which a fallback runs: nil where it had none (a host in a test runner).
    public var fallback: Int32?
    /// The new build's server's sealed copy (Task 9d); nil: none travels, and the server child runs on.
    public var server: Int32?

    public init(own: Int32, fallback: Int32?, server: Int32? = nil) {
        self.own = own
        self.fallback = fallback
        self.server = server
    }
}

/// The handover through sealed memory on Linux, writing no file (the stage 2 plan's Task 9c; S2-D8; the security
/// architecture document's S8).
///
/// - **The target** is read once into a sealed copy (`Platform.ProcessSelf.sealedCopy`) before anything else; the probe
///   and the exec run that copy, never the file again, so a file renamed over or rewritten after the load is never
///   what runs, and the probe and the new image, started from a copy they can't read, are non-dumpable from their exec.
///   The probe closes the copy as its first act and hardens (`startProbe`).
/// - **The state** (`HostHandover.State`, every session's output and pending input among it) is written into a sealed
///   memfd (`Platform.ProcessSelf.sealedMemory`: all four seals, `0400`, close-on-exec) and named to the probe and the
///   new image as `/proc/self/fd/<n>`, `n` kept across the exec: `HostHandover.read(from:)` reads that path unchanged,
///   and each reopen starts at the beginning, so the probe, the new image and a fallback read the same bytes. The probe
///   gets a state of its own, written before it runs; the exec's is written after it, with the secrets' descriptor.
/// - **The secrets** (the vault) go into a second sealed memfd, named by `State.secretFD`, read from offset 0 (`pread`,
///   `secrets(from:)`) and closed only once the restore succeeded (`finish`), so a fallback after a failed restore
///   still has them. No size limit short of memory; no hash: nobody can change sealed memory, and only non-dumpable
///   processes hold it.
/// - **The fallback** is the old image's own sealed copy (`HostImages.ownCopy`), kept across the exec and named by
///   `--handover-fallback /proc/self/fd/<n>`, with the image's path (never executed: its build id and folders) by
///   `--handover-fallback-image`: `goBack` executes it with the same descriptors and the same `--handover` path.
/// - **A traced new image** goes back without reading the secrets, leaving them for the build before; the fallback,
///   traced too, ends, and with it every descriptor (`main`). A scratch host's test makes a new image take itself for
///   traced (`--handover-test-traced`, `testTracer`).
/// - **Once restored** (`finish`) the state's and the secrets' memfds and every carried image copy but its own are
///   closed (never unlinked: there is no file), and every other descriptor the state names that this image still holds
///   as inherited is made close-on-exec (`keep:` cleared the flag for the exec).
/// - **A fresh host** that holds the lock removes a stale `host.lock.handover` and its `.partial` (the Mac's format, a
///   scratch host's from before), saying so (`removeStaleStateFiles`).
///
/// The Mac: none of it. `HostServer.handOver(to:)` keeps its state file and secret channel, `secrets(from:)` reads
/// nothing (no sealed memory there), and every hook here is nil or does nothing.
public enum HandoverMemory {
    /// The handing-over image's path, given to the new image with its fallback copy: what a fallback names itself by.
    public static let fallbackImageFlag = "--handover-fallback-image"
    /// A scratch host's test: a new image after a handover takes itself for traced (the user's host refuses it).
    public static let tracedTestFlag = "--handover-test-traced"
    /// A scratch host's test: the bytes of this file are what it hands over as its secrets.
    public static let secretFileTestFlag = "--handover-test-secret-file"
    /// A scratch host's test (Linux): the image it hands over to is given `--handover-fail-restore`, so that an ELF
    /// target (an installed build, which no script may stand in for) fails its restore and goes back.
    public static let failNextTestFlag = "--handover-test-fail-next"
    /// A scratch host's test (Linux): `--handover-test-hold PATH` holds each handover once its target is loaded (and,
    /// with an install root, checked) and "handing over to" is said, before the probe: it waits (at most a minute) for
    /// `PATH` to exist, so a test can change the target's file then.
    public static let holdTestFlag = "--handover-test-hold"
    /// The handing-over image's own `--node-root` and `--server`, given to the new image for its fallback (Task 9d,
    /// S2-D7): `goBack` gives them back as `--node-root` and `--server`, so the old build serves again with its own.
    public static let fallbackNodeRootFlag = "--handover-fallback-node-root"
    public static let fallbackServerFlag = "--handover-fallback-server"

    /// What `main` leaves out of `config.arguments` besides its own handover flags (each with its value), because a
    /// handover appends its own (`folderArguments`): on Linux the build's `--node-root` and `--server`, and the
    /// fallback's two. The Mac: only the fallback's two, which it is never given (its `config.arguments` as before).
    public static var handoverFlags: [String: Bool] {
        var flags = [fallbackNodeRootFlag: true, fallbackServerFlag: true]
        if !Platform.CodeIdentity.isAvailable {
            flags[HostImages.nodeRootFlag] = true
            flags["--server"] = true
        }
        return flags
    }

    private static let prefix = "/proc/self/fd/"

    /// `/proc/self/fd/<fd>`: how the state is named to the probe and the new image.
    public static func path(of fd: Int32) -> String { prefix + String(fd) }

    /// The descriptor a `/proc/self/fd/<n>` path names, or nil for any other path (the Mac's state file).
    public static func descriptor(named path: String) -> Int32? {
        guard path.hasPrefix(prefix), let fd = Int32(path.dropFirst(prefix.count)), fd > STDERR_FILENO else { return nil }
        return fd
    }

    // MARK: Sealed memory

    /// `data` in a new sealed memfd named `name`: its descriptor, close-on-exec. Throws `HostHandover.Failure.write`.
    static func seal(_ data: Data, name: String) throws -> Int32 {
        let made = data.withUnsafeBytes { Platform.ProcessSelf.sealedMemory($0, name: name) }
        switch made {
        case .success(let fd): return fd
        case .failure(let error): throw HostHandover.Failure.write(error.code)
        }
    }

    /// `state` as `HostHandover.write` encodes it (a binary property list), which `HostHandover.read(from:)` reads.
    static func encoded(_ state: HostHandover.State) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do { return try encoder.encode(state) } catch { throw HostHandover.Failure.write(EINVAL) }
    }

    /// Every byte of the sealed memory `fd`, read from offset 0 (`pread`: the descriptor's offset is left alone, and it
    /// is not closed); nil when `fd` isn't sealed memory (the Mac's secret channel, any other descriptor).
    public static func secrets(from fd: Int32) -> Data? {
        guard Platform.ProcessSelf.isSealed(fd) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        var bytes = Data(count: Int(info.st_size))
        var done = 0
        let complete = bytes.withUnsafeMutableBytes { raw -> Bool in
            while done < raw.count {
                let count = pread(fd, raw.baseAddress! + done, raw.count - done, off_t(done))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                done += count
            }
            return true
        }
        return complete ? bytes : nil
    }

    // MARK: The probe and the exec

    /// The environment a child or new image started from `copy` gets: this process's, with the copy named in
    /// `VIBESWITCHER_IMAGE_FD` (so that its first act closes it, or adopts it as its own) and no launcher test hold.
    static func environment(image copy: Int32) -> [String] {
        let variable = Platform.ProcessSelf.imageVariable
        return ProcessInfo.processInfo.environment
            .filter { $0.key != variable && $0.key != HostImages.launcherTestHoldVariable }
            .map { "\($0.key)=\($0.value)" } + ["\(variable)=\(copy)"]
    }

    /// `HostHandover.probe`'s hook: when the probe's executable is a sealed copy this process holds and its state is
    /// sealed memory (`/proc/self/fd/<n>` each, Linux), both kept in the probe and the copy named to it, its mode put
    /// back first. Otherwise (the Mac's file and state file) nothing changed.
    static func probing(_ spawn: inout Platform.Spawn, statePath: String) {
        guard let copy = descriptor(named: spawn.executable), let state = descriptor(named: statePath),
              Platform.ProcessSelf.restoreMode(of: copy) else { return }
        spawn.keep = [copy, state]
        spawn.environment = environment(image: copy)
    }

    /// The probe's first acts (`HostHandover.probeIfAsked`), once it knows it is one: the copy it was started from
    /// closed, then hardened as a parser is (it reads the state, every session's output); refused, it ends (exit 1),
    /// and the handover with it. The Mac: nothing.
    static func startProbe() {
        Platform.ProcessSelf.closeInheritedImage()
        if case .refused(let why) = HostHardening.atStart(mode: .parser) {
            FileHandle.standardError.write(Data("vibeswitcher-host: handover probe: not started: \(why)\n".utf8))
            exit(1)
        }
    }

    /// This process replaced by `copy` (Linux), named `argumentZero` (the path it was loaded from, which its `cmdline`
    /// then shows), keeping `keep` and the copy; returns only when the exec failed, with nothing changed.
    static func exec(_ copy: Platform.ProcessSelf.SealedCopy, argumentZero: String, arguments: [String], keep: [Int32]) -> HostHandover.Failure {
        _ = Platform.ProcessSelf.restoreMode(of: copy.fd)
        var spawn = Platform.Spawn(executable: copy.path, arguments: [argumentZero] + arguments)
        spawn.environment = environment(image: copy.fd)
        var kept: [Int32] = []
        for fd in keep + [copy.fd] where !kept.contains(fd) { kept.append(fd) }
        spawn.keep = kept
        return .exec(spawn.replaceProcess())
    }

    /// `main`'s `goBack` on Linux: `fallback` is the old image's sealed copy (`/proc/self/fd/<n>`), executed with every
    /// descriptor this image still holds as inherited (`keep: nil`: nothing it made is, and the copy it adopted as its
    /// own goes), named `image` (its path, from `--handover-fallback-image`) and given `--image-path image`, so its
    /// build is the old build's. Returns only when the exec failed. Nil when `fallback` is a path (the Mac's), or isn't
    /// a sealed copy this image holds: `main` executes it by its path then, as always.
    /// The old build's own `--node-root` and `--server` go back to it too (`fallbackArguments`, from `started`: what
    /// this image was started with).
    public static func goBack(to fallback: String, image: String?, arguments: [String],
                              started: [String] = CommandLine.arguments) -> HostHandover.Failure? {
        guard !Platform.CodeIdentity.isAvailable, let fd = descriptor(named: fallback), Platform.ProcessSelf.restoreMode(of: fd) else {
            return nil
        }
        var spawn = Platform.Spawn(executable: fallback, arguments: [image ?? fallback] + arguments
                                       + (image.map { [HostImages.imagePathFlag, $0] } ?? []) + fallbackArguments(started: started))
        spawn.environment = environment(image: fd)
        spawn.keep = nil
        return .exec(spawn.replaceProcess())
    }

    // MARK: The build's folders across the exec

    /// What the exec appends for the new image's folders (S2-D7), and its fallback's: with a checked `build` (an install
    /// root), `--node-root` its folder and, when this image runs a server child (`started` holds `--server`), `--server`
    /// its own `bin/vibeswitcher-server` (whose copy travels in `State.images.server`), and no `--image-path`; without one
    /// (a scratch host), this image's own `--node-root` and `--server` as `started` names them, and `--image-path
    /// target` for an ELF target (a script stand-in execs a file that names itself). Then this image's own two again,
    /// as `fallbackNodeRootFlag` and `fallbackServerFlag`, for a fallback (`goBack`). `started`: what this image was
    /// started with (`CommandLine.arguments`), from which `main` dropped the two (`handoverFlags`).
    public static func folderArguments(build: HandoverTarget.Build?, target: String, isScript: Bool, started: [String]) -> [String] {
        let nodeRoot = HostImages.value(after: HostImages.nodeRootFlag, in: started)
        let server = HostImages.value(after: "--server", in: started)
        var arguments: [String] = []
        if let build {
            arguments += [HostImages.nodeRootFlag, build.folder]
            if server != nil { arguments += ["--server", build.binary(BuildInfo.server)] }
        } else {
            if let nodeRoot { arguments += [HostImages.nodeRootFlag, nodeRoot] }
            if let server { arguments += ["--server", server] }
            if !isScript { arguments += [HostImages.imagePathFlag, target] }
        }
        if let nodeRoot { arguments += [fallbackNodeRootFlag, nodeRoot] }
        if let server { arguments += [fallbackServerFlag, server] }
        return arguments
    }

    /// What `goBack` appends for the old build's own folders: the `--node-root` and `--server` the handing-over image
    /// named for its fallback in `started` (`folderArguments`), as `--node-root` and `--server`. Empty without them.
    public static func fallbackArguments(started: [String]) -> [String] {
        var arguments: [String] = []
        if let nodeRoot = HostImages.value(after: fallbackNodeRootFlag, in: started) { arguments += [HostImages.nodeRootFlag, nodeRoot] }
        if let server = HostImages.value(after: fallbackServerFlag, in: started) { arguments += ["--server", server] }
        return arguments
    }

    // MARK: The new image

    /// `main`'s hook once a new image (or a fallback) has restored and taken its server child and test stand-in again:
    /// on Linux the state's memfd (`statePath`), the secrets' (`state.secretFD`) and each carried image copy that isn't
    /// this image's own (`state.images.fallback` in the new image; `state.images.own` in a fallback, which holds it
    /// still when the new image went back before adopting it) closed when still held as inherited;
    /// every other descriptor `state` names that is still held as inherited made close-on-exec. A scratch host says
    /// what it found (`reports`). The Mac: nothing.
    public static func finish(_ state: HostHandover.State, statePath: String, server: HostServer) {
        guard !Platform.CodeIdentity.isAvailable else { return }
        let own = HostImages.ownCopy?.fd
        let stateFD = descriptor(named: statePath)
        var closing = [stateFD, state.secretFD].compactMap { $0 }
        // Each image carried that isn't this image's own: the old image's copy in the new image, and in a fallback the
        // new build's copy, which it never adopted when its start was refused before `HostImages.load` (the 9c review).
        // The server's copy (Task 9d) is `ServerChild`'s to take.
        for image in [state.images?.fallback, state.images?.own].compactMap({ $0 }) where image != own { closing.append(image) }
        if reports {
            var lines: [String] = []
            if let stateFD { lines.append("state fd \(stateFD) " + described(stateFD)) }
            if let secretFD = state.secretFD { lines.append("secrets fd \(secretFD) " + described(secretFD)) }
            say(server, "handover memory taken: " + lines.joined(separator: "; "))
        }
        for fd in closing where isInherited(fd) { Sys.close(fd) }
        var kept: [String] = []
        for fd in Set(state.descriptors + (stateFD.map { [$0] } ?? [])).sorted() {
            if isInherited(fd) { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            let flags = fcntl(fd, F_GETFD)
            kept.append("\(fd) " + (flags < 0 ? "closed" : flags & FD_CLOEXEC != 0 ? "close-on-exec" : "inheritable"))
        }
        if reports { say(server, "handover memory kept: " + kept.joined(separator: ", ")) }
    }

    /// Whether `fd` is open, above 2, and not close-on-exec: inherited across the exec (`keep:` unmarks what it keeps),
    /// as nothing this image made is.
    static func isInherited(_ fd: Int32) -> Bool {
        guard fd > STDERR_FILENO else { return false }
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC == 0
    }

    /// For a scratch host's report: whether `fd` is sealed, its size and its bytes' SHA-256.
    static func described(_ fd: Int32) -> String {
        guard let bytes = secrets(from: fd) else { return "not sealed" }
        return "sealed, \(bytes.count) bytes, sha256 \(BuildInfo.sha256(of: bytes))"
    }

    /// Whether the image this host hands over to is told to fail its restore (`failNextTestFlag`): a scratch host on
    /// Linux given the flag (set by `HostHardening.afterConfig`); never the user's host.
    static var failsNext: Bool {
        get { reportLock.withLock { failsNextFlag } }
        set { reportLock.withLock { failsNextFlag = newValue } }
    }
    nonisolated(unsafe) private static var failsNextFlag = false

    /// Where a scratch host's handovers are held before their probe (`holdTestFlag`, set by `HostHardening.afterConfig`);
    /// nil: none, the user's host's always.
    static var holdBeforeProbe: String? {
        get { reportLock.withLock { holdPath } }
        set { reportLock.withLock { holdPath = newValue } }
    }
    nonisolated(unsafe) private static var holdPath: String?

    /// The hold `holdBeforeProbe` names, if any: off the host's queue.
    static func holdIfAsked() {
        guard let hold = holdBeforeProbe else { return }
        for _ in 0..<6_000 where access(hold, F_OK) != 0 { usleep(10_000) }
    }

    /// Whether this host says what its handovers wrote and took (`finish`, `HostServer.handOverThroughMemory`): a scratch
    /// host on Linux (set by `HostHardening.afterConfig`), for its tests; never the user's host.
    static var reports: Bool {
        get { reportLock.withLock { reportsFlag } }
        set { reportLock.withLock { reportsFlag = newValue } }
    }
    private static let reportLock = NSLock()
    nonisolated(unsafe) private static var reportsFlag = false

    /// A line in the host's log and on its stderr.
    static func say(_ server: HostServer, _ line: String) {
        server.note("host: " + line)
        FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
    }

    // MARK: Test flags, stale files

    /// Where `--handover-fail-restore` (a test's new image that can't restore) fails: on Linux once the state and the
    /// secrets were read and the vault made from them, just before the restore, so that the fallback must read them
    /// again from their sealed memory; on the Mac before the state is read, as always.
    public static var failsRestoreLate: Bool { !Platform.CodeIdentity.isAvailable }

    /// A scratch host's `--handover-test-traced` (Linux) in a new image after a handover: refused as if a tracer were
    /// named, so it goes back as a traced image does. Nil otherwise: without the flag or a handover, for the user's host
    /// (`ownsLaunchers`, which refuses the flag), and on the Mac.
    public static func testTracer(arguments: [String], ownsLaunchers: Bool) -> HostHardening.Start? {
        guard !Platform.CodeIdentity.isAvailable, !ownsLaunchers, arguments.contains(tracedTestFlag),
              HostHardening.handover(in: arguments) != nil else { return nil }
        return .refused("traced by pid \(getppid()) (\(tracedTestFlag))")
    }

    /// A scratch host's `--handover-test-secret-file PATH` (Linux): the file's bytes, what it hands over as its secrets
    /// (more than an argument can hold). Nil without it, when it can't be read, for the user's host, and on the Mac.
    public static func testSecret(arguments: [String], ownsLaunchers: Bool) -> Data? {
        guard !Platform.CodeIdentity.isAvailable, !ownsLaunchers,
              let path = HostImages.value(after: secretFileTestFlag, in: arguments) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// A fresh host (not restoring) holding the lock at `lockPath`, on Linux: a `host.lock.handover` beside it and its
    /// `.partial` (a state file of the Mac's format, or a scratch host's from before sealed memory) removed, each said.
    /// The Mac: nothing (its handover still writes the file, and reads and removes it).
    public static func removeStaleStateFiles(lockPath: String, server: HostServer) {
        guard !Platform.CodeIdentity.isAvailable else { return }
        let path = lockPath + ".handover"
        for stale in [path, path + ".partial"] where unlink(stale) == 0 {
            say(server, "removed a stale handover state file: \(stale)")
        }
    }
}

extension HostServer {
    /// With an install root (`Config.installRoot`), `target` (loaded from `path`) checked as an installed build
    /// (`HandoverTarget.check`, the sessions' working folders refused), and, when this image runs a server child (it
    /// was started with `--server`), that build's server loaded and checked (`HandoverTarget.server(of:)`): both, or
    /// why not. Nil without an install root: any target, as before.
    func installedTarget(_ target: Platform.ProcessSelf.SealedCopy, path: String)
        -> Result<(build: HandoverTarget.Build, server: Platform.ProcessSelf.SealedCopy?)?, HandoverTarget.Refused> {
        guard let installRoot = config.installRoot else { return .success(nil) }
        let build: HandoverTarget.Build
        switch HandoverTarget.check(target, path: path, installRoot: installRoot.path, sessionFolders: sessions.values.map(\.info.cwd)) {
        case .failure(let why): return .failure(why)
        case .success(let checked): build = checked
        }
        guard HostImages.value(after: "--server", in: CommandLine.arguments) != nil else { return .success((build, nil)) }
        return HandoverTarget.server(of: build).map { (build, $0) }
    }

    /// `handOver(to:)` on Linux (its one hook): the target loaded into a sealed copy before anything else, probed from
    /// that copy with a state of its own in sealed memory, then, on the queue, the secrets and the state written into
    /// sealed memory and the process replaced by the copy, keeping both, the images and every session's descriptor.
    /// No file is written. Anything failing before the exec leaves this host as it was, and closes what it made.
    func handOverThroughMemory(to executable: String, reply: @escaping (HostEvent) -> Void) {
        let target: Platform.ProcessSelf.SealedCopy
        switch Platform.ProcessSelf.sealedCopy(of: executable, name: BuildInfo.host) {
        case .success(let copy): target = copy
        case .failure(let error):
            return reply(.error("Couldn't hand over: \(executable) couldn't be loaded (\(String(cString: strerror(error.code))))."))
        }
        // With an install root (the user's host), only an installed build this host checked, on the copy that runs,
        // and its server, checked against the same record (V2/HandoverTarget.swift). Before any probe.
        let build: HandoverTarget.Build?
        let serverCopy: Platform.ProcessSelf.SealedCopy?
        switch installedTarget(target, path: executable) {
        case .failure(let why):
            Sys.close(target.fd)
            log("handover to \(executable) refused: \(why)")
            return reply(.error("Couldn't hand over: \(why)."))
        case .success(let checked):
            (build, serverCopy) = (checked?.build, checked?.server)
        }
        handingOver = true
        let fail: (Error) -> Void = { [weak self] error in
            Sys.close(target.fd)
            if let serverCopy { Sys.close(serverCopy.fd) }
            self?.handingOver = false
            self?.log("handover to \(executable) failed: \(error)")
            reply(.error("Couldn't hand over: \(error)."))
        }
        let probeState: Int32
        do {
            probeState = try HandoverMemory.seal(HandoverMemory.encoded(handoverState(secretFD: nil)), name: "vibeswitcher-handover-probe")
        } catch {
            return fail(error)
        }
        log("handing over to \(executable) (its sealed copy\(build.map { ", the installed build \($0.folder)" } ?? ""))")
        DispatchQueue.global().async { [weak self] in
            do {
                defer { Sys.close(probeState) }
                HandoverMemory.holdIfAsked()
                try HostHandover.probe(target.path, statePath: HandoverMemory.path(of: probeState))
            } catch {
                self?.queue.async { fail(error) }
                return
            }
            self?.queue.async {
                guard let self else { return }
                var made: [Int32] = []
                var parsersStopped = false
                do {
                    let secrets: Data? = self.secretsForHandover?()
                    let secretFD = try secrets.map { try HandoverMemory.seal($0, name: "vibeswitcher-handover-secrets") }
                    if let secretFD { made.append(secretFD) }
                    // A session that just ended is saved as ended, with the screen its parser showed last.
                    self.sessions.values.forEach { $0.finishNow() }
                    let fallback = HostImages.ownCopy
                    var state = self.handoverState(secretFD: secretFD)
                    state.images = HandoverImages(own: target.fd, fallback: fallback?.fd, server: serverCopy?.fd)
                    if let bad = state.descriptors.first(where: { !HostHandover.isOpen($0) }) { throw HostHandover.Failure.badDescriptor(bad) }
                    let bytes = try HandoverMemory.encoded(state)
                    let stateFD = try HandoverMemory.seal(bytes, name: "vibeswitcher-handover-state")
                    made.append(stateFD)
                    if HandoverMemory.reports {
                        HandoverMemory.say(self, "handover memory written: state fd \(stateFD) \(HandoverMemory.described(stateFD))"
                                           + (secretFD.map { "; secrets fd \($0) \(HandoverMemory.described($0))" } ?? ""))
                    }
                    reply(.ok)
                    // The new build starts its own parsers, from the replays; none of these is left running.
                    self.sessions.values.forEach { $0.suspendParser() }
                    parsersStopped = true
                    // The fallback: this image's own sealed copy, named by its path (never executed); without one (a
                    // host in a test runner), its file, as on the Mac.
                    var arguments = self.config.arguments + ["--handover", HandoverMemory.path(of: stateFD), "--handover-fallback",
                                                             fallback?.path ?? self.config.fallback ?? self.config.launcher]
                    if fallback != nil, let image = self.config.fallback { arguments += [HandoverMemory.fallbackImageFlag, image] }
                    if let app = self.config.appExecutable { arguments += ["--handover-fallback-app", app] }
                    // Its build and folders (S2-D7): the installed build's, or by the target's path (its /proc/self/exe
                    // names the memfd); this image's own for its fallback.
                    arguments += HandoverMemory.folderArguments(build: build, target: executable, isScript: target.isScript,
                                                                started: CommandLine.arguments)
                    if HandoverMemory.failsNext { arguments.append("--handover-fail-restore") }
                    throw HandoverMemory.exec(target, argumentZero: executable, arguments: arguments, keep: state.descriptors + [stateFD])
                } catch {
                    if parsersStopped { self.sessions.values.forEach { $0.resumeParser() } }
                    made.forEach { Sys.close($0) }
                    fail(error)
                    // Answered ok already when the exec itself failed: clients waiting for the new build come back to
                    // this one's welcome.
                    if case HostHandover.Failure.exec = error { self.clients.values.forEach { $0.close() } }
                }
            }
        }
    }
}
