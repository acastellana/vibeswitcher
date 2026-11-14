import Foundation
import VibeCore

/// A host update that keeps every session: the running host re-executes itself, in place, as the new build.
///
/// Same process, so the sessions' programs stay its children (`waitpid` still reports how they end), and the PTYs, the
/// lock and the listening socket stay open across the exec (they're the descriptors the new image inherits). The rest
/// (each session's info, everything it printed, input not yet written) goes in a state file only this user can read,
/// which the new build reads and deletes; the screens are rebuilt from what each session printed. Clients lose their
/// connection and come back to the same socket. Secrets the host keeps in memory never touch the file: they go through
/// a socket whose reading end the new build inherits (see `SecretChannel`).
///
/// A build that can't take over never replaces the running one: it's run first as a probe that reads the state, and
/// the exec happens only when the probe says it can. If the new build then can't restore after all, it executes the
/// old build's own copy again (`--handover-fallback`), which restores it.
public enum HostHandover {
    /// Bumped whenever `State` changes shape: a build reads only its own.
    public static let format = 1
    /// What the probe prints when it can take over.
    static let probeAnswer = "vibeswitcher-host handover \(format) ok"

    public struct Session: Codable, Equatable {
        public var info: HostSession
        /// Nil: the PTY is closed already.
        public var masterFD: Int32?
        /// What the session printed (the replay): the new build's ring and screen start from it.
        public var output: Data
        public var pendingInput: Data
        /// An ended session's last screen, how it was drawn, and the lines above it (it has no replay any more).
        public var ended: Ended?
        /// The session whose process asked for this one (see `HostServer`'s kill rule); nil: the app or no session.
        public var startedBy: UUID?
        /// The app asked for it: one of the user's (see `HostServer`'s `openedByApp`). Nil from builds before that.
        public var openedByApp: Bool?
        /// Its program asked for focus events (see `FocusEvents`): a program asks once, and the replay seldom still
        /// holds it. Nil from builds before that: read off `output` then.
        public var focusEvents: Bool?

        public struct Ended: Codable, Equatable {
            public var screen: String
            public var runs: [ScreenRun]
            public var history: String
        }

        public init(info: HostSession, masterFD: Int32?, output: Data, pendingInput: Data, ended: Ended? = nil, startedBy: UUID? = nil) {
            self.info = info
            self.startedBy = startedBy
            self.masterFD = masterFD
            self.output = output
            self.pendingInput = pendingInput
            self.ended = ended
        }
    }

    public struct State: Codable, Equatable {
        public var format = HostHandover.format
        public var fromBuild: Int
        /// When the host (this process) first started.
        public var startedAt: Date
        public var lockFD: Int32
        public var listenFD: Int32
        /// The reading end of the secret channel, or nil when there's nothing secret.
        public var secretFD: Int32?
        /// In the order they were started.
        public var sessions: [Session]
        /// A scratch host's test stand-in for the app on Linux (see `TestAppPrincipal`), carried so the new image
        /// takes it again. Nil: none (every other host, the Mac's always), and from builds before it.
        public var testAppConnector: TestAppConnector?
        /// The server child, the app on Linux (see `ServerChild`), carried so the new image takes it again once it
        /// has checked it. Nil: none (the Mac's always, a host without `--server`), and from builds before it.
        public var serverChild: ServerChildRecord?
        /// What `hostNotes` counted so far (see V2/HostNotesAnswer.swift), so the counts run on across the handover as
        /// `startedAt` does. Nil: none kept (the Mac's always), and from builds before it.
        public var tally: Tally?
        /// The sealed images the exec carries (see V2/HandoverMemory.swift): the new image's own copy and the old one's
        /// for a fallback. Nil: none (the Mac's always), and from builds before it.
        public var images: HandoverImages?

        /// Every descriptor the new image must inherit.
        var descriptors: [Int32] {
            [lockFD, listenFD] + [secretFD, testAppConnector?.fd, serverChild?.connector, serverChild?.image].compactMap { $0 }
                + [images?.own, images?.fallback, images?.server].compactMap { $0 }
                + sessions.compactMap(\.masterFD)
        }
    }

    /// The server child as a handover carries it (see `ServerChild`): which process it is, the host's end of its
    /// connector and the sealed copy it was started from, both kept across the exec.
    public struct ServerChildRecord: Codable, Equatable {
        public var pid: Int32
        /// Its start time in clock ticks since boot (`Platform.Processes.link`): with the pid, the process itself.
        public var startTicks: UInt64
        /// The host's end of its connector.
        public var connector: Int32
        /// The sealed copy of its image, which a start again runs.
        public var image: Int32
        /// The `--server` path the copy was loaded from: never run, only said.
        public var path: String
        /// The SHA-256 of the image the running child was started from, when that isn't `image`'s bytes (Task 9d: a
        /// switch carried another build's server, and the child is still to be started again from it; empty when not
        /// known). Nil otherwise, on the Mac, and from builds before it.
        public var runningImageSHA256: String?

        public init(pid: Int32, startTicks: UInt64, connector: Int32, image: Int32, path: String, runningImageSHA256: String? = nil) {
            self.pid = pid
            self.startTicks = startTicks
            self.connector = connector
            self.image = image
            self.path = path
            self.runningImageSHA256 = runningImageSHA256
        }
    }

    /// The host's end of a test's app connector, and the test process it expects (see `TestAppPrincipal`).
    public struct TestAppConnector: Codable, Equatable {
        public var fd: Int32
        public var pid: Int32

        public init(fd: Int32, pid: Int32) {
            self.fd = fd
            self.pid = pid
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notExecutable(String)
        case write(Int32)
        case unreadable(String)
        case wrongFormat(Int)
        case badDescriptor(Int32)
        case probe(String)
        case secretTooLarge(Int)
        case exec(Int32)

        public var description: String {
            switch self {
            case .notExecutable(let path): return "\(path) isn't an executable"
            case .write(let error): return "couldn't write the state file: \(String(cString: strerror(error)))"
            case .unreadable(let why): return "couldn't read the state file: \(why)"
            case .wrongFormat(let format): return "the state file is format \(format); this build reads \(HostHandover.format)"
            case .badDescriptor(let fd): return "descriptor \(fd) didn't survive"
            case .probe(let why): return "the new build can't take over: \(why)"
            case .secretTooLarge(let size): return "\(size) bytes of secrets don't fit the channel"
            case .exec(let error): return "couldn't execute the new build: \(String(cString: strerror(error)))"
            }
        }
    }

    /// Writes `state` to `path`, readable by this user only, replacing what was there.
    static func write(_ state: State, to path: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do { data = try encoder.encode(state) } catch { throw Failure.write(EINVAL) }
        let partial = path + ".partial"
        unlink(partial)
        let fd = open(partial, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.write(errno) }
        var written = 0
        let failure: Int32? = data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = Sys.write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 { if errno == EINTR { continue }; return errno }
                written += count
            }
            return fsync(fd) == 0 ? nil : errno
        }
        Sys.close(fd)
        if let failure {
            unlink(partial)
            throw Failure.write(failure)
        }
        guard rename(partial, path) == 0 else {
            let error = errno
            unlink(partial)
            throw Failure.write(error)
        }
    }

    public static func read(from path: String) throws -> State {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw Failure.unreadable(error.localizedDescription) }
        // The format first: a state of another shape wouldn't decode, and that should say why.
        struct Header: Decodable { var format: Int }
        guard let header = try? PropertyListDecoder().decode(Header.self, from: data) else { throw Failure.unreadable("not a state file") }
        guard header.format == format else { throw Failure.wrongFormat(header.format) }
        do { return try PropertyListDecoder().decode(State.self, from: data) } catch { throw Failure.unreadable("\(error)") }
    }

    /// `--handover-probe PATH`: whether this build can take over from the state at `path`. Call first thing in `main`.
    public static func probeIfAsked(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--handover-probe"), arguments.indices.contains(index + 1) else { return }
        // On Linux: its sealed copy closed, then hardened (V2/HandoverMemory.swift); the Mac: nothing.
        HandoverMemory.startProbe()
        do {
            _ = try read(from: arguments[index + 1])
            print(probeAnswer)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("vibeswitcher-host: handover probe: \(error)\n".utf8))
            exit(1)
        }
    }

    /// How long the probe may take to answer. On a loaded Mac most of it is the system's check of the new build's first
    /// exec (amfid, one new binary at a time for the whole Mac), before any of its code runs: on 2026-10-19 amfid
    /// answered nothing for 108 s at load 200, and the 15 s once given here refused good builds. The sessions carry on
    /// meanwhile (the probe runs off the server's queue); this only ends a build that hangs.
    static let probeLimit: TimeInterval = 180

    /// Runs `executable --handover-probe path` and waits (up to `timeout`) for it to say it can take over. Blocks: not on
    /// the server's queue.
    static func probe(_ executable: String, statePath: String, timeout: TimeInterval = probeLimit) throws {
        var pipe: [Int32] = [-1, -1]
        guard Sys.pipeClosedOnExec(&pipe) == 0 else { throw Failure.probe("no pipe") }
        defer { Sys.close(pipe[0]) }
        // Every signal at its default and none blocked, as at a fresh start; nothing but its stdin, stdout and stderr.
        var spawn = Platform.Spawn(executable: executable, arguments: [executable, "--handover-probe", statePath])
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .descriptor(pipe[1])
        spawn.stderr = .inherit
        spawn.keep = []
        // On Linux the target's sealed copy and the state's sealed memory kept (V2/HandoverMemory.swift).
        HandoverMemory.probing(&spawn, statePath: statePath)
        let spawned = spawn.start()
        Sys.close(pipe[1])
        let pid: pid_t
        switch spawned {
        case .success(let started): pid = started
        case .failure(let error): throw Failure.probe(String(cString: strerror(error.code)))
        }

        _ = fcntl(pipe[0], F_SETFL, fcntl(pipe[0], F_GETFL) | O_NONBLOCK)
        var output = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while waitpid(pid, &status, WNOHANG) == 0 {
            guard Date() < deadline else {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                throw Failure.probe("it didn't answer")
            }
            output.append(drain(pipe[0]))
            usleep(10_000)
        }
        output.append(drain(pipe[0]))
        let answer = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, answer.hasSuffix(probeAnswer) else {
            throw Failure.probe(answer.isEmpty ? "it exited with status \(status)" : "it said \(answer.suffix(200))")
        }
    }

    private static func drain(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Sys.read(fd, &buffer, buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// Replaces this process's image with `executable`, keeping its pid. `inherit`: the descriptors the new image gets
    /// (besides 0–2); nil keeps every descriptor not marked close-on-exec. Returns only when that failed, with
    /// nothing changed.
    public static func exec(_ executable: String, arguments: [String], inherit: [Int32]?) -> Failure {
        // Default handling and an empty mask, as at a fresh start (the host ignores SIGPIPE and SIGHUP, and its queue's
        // threads block most signals; `main` sets up its own). A descriptor it keeps is handed on even when it is
        // marked close-on-exec (`Platform.Spawn.replaceProcess` unmarks it, and marks it again if the exec fails).
        var spawn = Platform.Spawn(executable: executable, arguments: [executable] + arguments)
        spawn.keep = inherit
        return .exec(spawn.replaceProcess())
    }

    /// The secrets the build before handed over (`HostServer.secretsForHandover`), exactly the bytes it gave; nil when
    /// it gave none. Read once: the channel is closed and `state` no longer names it, so `HostServer.start(restoring:)`
    /// returns nil for them after this. On Linux they are sealed memory, left open until the restore succeeded, so a
    /// fallback reads them again (`HandoverMemory.finish` closes them).
    public static func takeSecrets(from state: inout State) -> Data? {
        guard let fd = state.secretFD else { return nil }
        state.secretFD = nil
        // On Linux sealed memory, read from its start and left open for a fallback (V2/HandoverMemory.swift).
        if let kept = HandoverMemory.secrets(from: fd) { return kept }
        return isOpen(fd) ? SecretChannel.take(fd) : nil
    }

    /// Whether `fd` is an open descriptor.
    static func isOpen(_ fd: Int32) -> Bool { fd >= 0 && fcntl(fd, F_GETFD) != -1 }

    /// Carries secrets to the new image without writing them anywhere: they're written into a local socket before the
    /// exec, and the new build reads them from the end it inherits, then closes it.
    enum SecretChannel {
        /// The reading end, holding `secret` and then end-of-file.
        static func make(_ secret: Data) throws -> Int32 {
            guard let (reader, writer) = Platform.Sockets.pair(type: Platform.Sockets.stream) else { throw Failure.secretTooLarge(secret.count) }
            var room = Int32(min(secret.count + 65_536, 8 << 20))
            setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(reader, SOL_SOCKET, SO_RCVBUF, &room, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
            var written = 0
            secret.withUnsafeBytes { raw in
                while written < raw.count {
                    let count = Sys.write(writer, raw.baseAddress! + written, raw.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return }
                    written += count
                }
            }
            Sys.close(writer)
            guard written == secret.count else {
                Sys.close(reader)
                throw Failure.secretTooLarge(secret.count)
            }
            return reader
        }

        /// Everything in the channel; closes it.
        static func take(_ fd: Int32) -> Data {
            defer { Sys.close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Sys.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return data }
                data.append(contentsOf: buffer[0..<count])
            }
        }
    }
}
