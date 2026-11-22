import Foundation

/// What a confined session's helpers are started as, from the session's record in the host (the session sandbox plan's
/// SB4; also `SpawnRequest.helper`, SB5): its role, its root (the lead's main checkout) and its task. Never read from
/// anything a box sent.
public struct SessionHelper: Codable, Equatable, Sendable {
    public var role: String
    public var root: String
    public var task: String?

    public init(role: String, root: String, task: String? = nil) {
        self.role = role
        self.root = root
        self.task = task
    }
}

/// The porter (the session sandbox plan's SB4): one process per confined session, outside its box, which the host
/// starts from a sealed copy of the tool server's image (`vibeswitcher-mcp --porter …`) with the session's door line
/// (the socket the box's init hands each door connection over), its connector, and sealed copies of the tool server's
/// and the hook's images.
///
/// For each door connection it reads the relay's one line (`DoorProtocol.Hello`) and the three descriptors that came
/// with it, checks the mode against the role the host gave it (`allowed`), and starts the real helper outside from
/// the mode's sealed copy, non-dumpable from its exec, with those descriptors as its stdin, stdout and stderr, the
/// session's connector kept, and arguments made from the role, root and task the host gave it (`command`), never
/// from the line. When the helper ends it answers its status; when the relay goes first (its connection closes, or it
/// says anything more), it ends the helper: SIGTERM to its group, SIGKILL after `endPatience`. A helper that died is
/// simply started again at the next connection. When the door line closes (the box has ended) the porter ends every
/// helper it runs and exits.
///
/// Its first statements are the server's (`PlatformLintTests`' order): the image it was started from closed,
/// hardened, a traced porter's exit 75, its inherited descriptors marked close-on-exec, then SIGPIPE settled.
public enum Porter {
    public static let flag = "--porter"
    /// How long a relay has to send its whole line once its connection reached the porter.
    public static let helloPatience: TimeInterval = 5
    /// How long a helper has to end after SIGTERM before SIGKILL.
    public static let endPatience: TimeInterval = 3
    /// The most connections a porter serves at once: a box that opens more is refused, not given a process each.
    public static let maxConnections = 32
    /// What a status line's helper is started with for a box: it runs no status line command of anyone's
    /// (`UsageStatusLine.run`'s `ownCommand`).
    public static let boxArgument = "--for-a-box"
    /// The agents whose name a hook's line may give: Claude Code alone. Codex's hooks come from its background daemon
    /// and find their session among every Codex terminal of the machine, by what the event says
    /// (`HookOwner.codexTerminal`): a box's event would choose its session. Codex workers are off (D15), and their
    /// hooks through a door are that later task's.
    public static let agents: Set<String> = [Agent.claude.rawValue]

    /// The modes each role's helpers have. A verifier has no permission hook through the door yet: its hook's folder
    /// is its audit checkout, which the host's record doesn't carry (`SessionHelper` names the task's worktree only).
    public static let modes: [String: Set<DoorProtocol.Mode>] = [
        LeadLaunch.Role.worker.rawValue: [.mcp, .hook, .statusLine, .permission],
        LeadLaunch.Role.lead.rawValue: [.mcp, .hook, .statusLine, .permission],
        LeadLaunch.Role.verifier.rawValue: [.mcp, .hook, .statusLine],
    ]

    /// Why `hello` gets no helper for a session `helper` describes; nil when it gets one. Pure.
    public static func allowed(_ hello: DoorProtocol.Hello, for helper: SessionHelper) -> String? {
        guard hello.v == 1 else { return "the hello's version \(hello.v) isn't 1" }
        guard let modes = modes[helper.role] else { return "the role \(helper.role) has no helpers" }
        guard modes.contains(hello.mode) else { return "the role \(helper.role) has no \(hello.mode.rawValue) helper" }
        guard helper.root.hasPrefix("/") else { return "the session's root isn't an absolute path" }
        if let task = helper.task, !isSlug(task) { return "the session's task isn't a task's name" }
        if helper.role == LeadLaunch.Role.worker.rawValue, helper.task == nil { return "a worker's session has no task" }
        if hello.mode == .hook {
            guard let agent = hello.args.first, agents.contains(agent) else { return "a hook names no agent this node knows" }
        }
        return nil
    }

    /// The helper's argv (its program's name first) for `hello` in a session `helper` describes, whose relay is
    /// `caller` (as the porter numbers it), once `allowed` said yes. Pure. Nothing in it comes from `hello.args` but a
    /// hook's agent name, out of `agents`:
    ///
    /// - the tool server: `--role R --root ROOT [--task T]`, the host's;
    /// - the hook: `<agent> --for-pid <caller>` (the porter adds `--caller-socket N`, the process it holds and the
    ///   box's init, `HookCaller`);
    /// - the status line: `--status-line --user-settings-only --for-a-box` whatever the role: it keeps the usage the
    ///   input carries and shows it, and runs no status line command, not a project's (its settings are in a folder
    ///   the box writes) and not the user's own either (`boxArgument`): that command would run outside, as the user,
    ///   on input the box wrote, and a status line that asks git about the folder its input names would run git
    ///   there, with that folder's config and hooks (the plan's "No program is run outside in a folder a box can
    ///   write");
    /// - the permission hook: `--read-only-permission --root <the worker's worktree, or the root> [--worker]`.
    public static func command(_ hello: DoorProtocol.Hello, helper: SessionHelper, caller: pid_t) -> [String] {
        switch hello.mode {
        case .mcp:
            return ["vibeswitcher-mcp", "--role", helper.role, "--root", helper.root] + (helper.task.map { ["--task", $0] } ?? [])
        case .hook:
            let agent = hello.args.first.flatMap { agents.contains($0) ? $0 : nil } ?? Agent.claude.rawValue
            return ["vibeswitcher-hook", agent, HookCaller.pidFlag, String(caller)]
        case .statusLine:
            return ["vibeswitcher-mcp", UsageStatusLine.argument, UsageStatusLine.userOnlyArgument, boxArgument]
        case .permission:
            let worker = helper.role == LeadLaunch.Role.worker.rawValue
            let folder = worker ? helper.task.map { Worktrees.path(root: helper.root, slug: $0) } ?? helper.root : helper.root
            return ["vibeswitcher-mcp", ReadOnlyCommand.hookArgument, ReadOnlyCommand.rootArgument, folder]
                + (worker ? [ReadOnlyCommand.workerArgument] : [])
        }
    }

    /// A task's name as the board gives one: letters, digits, `.`, `_` and `-`, not `.` or `..`, and no longer than
    /// 128 characters.
    static func isSlug(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The porter's arguments, after `flag`.
    public struct Arguments: Equatable, Sendable {
        public var session: UUID
        public var helper: SessionHelper
        public var doorLine: Int32
        public var connector: Int32
        public var hostSocket: String
        public var toolServerImage: Int32
        public var hookImage: Int32

        public init(session: UUID, helper: SessionHelper, doorLine: Int32, connector: Int32, hostSocket: String,
                    toolServerImage: Int32, hookImage: Int32) {
            self.session = session
            self.helper = helper
            self.doorLine = doorLine
            self.connector = connector
            self.hostSocket = hostSocket
            self.toolServerImage = toolServerImage
            self.hookImage = hookImage
        }

        /// The words after `flag`, as `parse` reads them.
        public var words: [String] {
            ["--session", session.uuidString, "--role", helper.role, "--root", helper.root] + (helper.task.map { ["--task", $0] } ?? [])
                + ["--door-line", String(doorLine), "--host-connector", String(connector), "--host-socket", hostSocket,
                   "--tool-server-image", String(toolServerImage), "--hook-image", String(hookImage)]
        }
    }

    /// `words` (what follows `flag`) read: each flag once, with its value; every one but `--task` needed; descriptors
    /// above 2. Why not, otherwise.
    public static func parse(_ words: [String]) -> Result<Arguments, DoorProtocol.Refusal> {
        var values: [String: String] = [:]
        let known: Set<String> = ["--session", "--role", "--root", "--task", "--door-line", "--host-connector", "--host-socket",
                                  "--tool-server-image", "--hook-image"]
        var index = 0
        while index < words.count {
            let word = words[index]
            guard known.contains(word) else { return .failure(DoorProtocol.Refusal("unknown argument \(word)")) }
            guard values[word] == nil else { return .failure(DoorProtocol.Refusal("\(word) given twice")) }
            guard index + 1 < words.count else { return .failure(DoorProtocol.Refusal("\(word) needs a value")) }
            values[word] = words[index + 1]
            index += 2
        }
        func descriptor(_ flag: String) -> Int32? { values[flag].flatMap(Int32.init).flatMap { $0 > STDERR_FILENO ? $0 : nil } }
        guard let session = values["--session"].flatMap(UUID.init(uuidString:)) else { return .failure(DoorProtocol.Refusal("--session needs a session's id")) }
        guard let role = values["--role"], let root = values["--root"] else { return .failure(DoorProtocol.Refusal("--role and --root are needed")) }
        guard let doorLine = descriptor("--door-line"), let connector = descriptor("--host-connector"),
              let toolServer = descriptor("--tool-server-image"), let hook = descriptor("--hook-image") else {
            return .failure(DoorProtocol.Refusal("--door-line, --host-connector, --tool-server-image and --hook-image each need a descriptor above 2"))
        }
        guard let socket = values["--host-socket"], socket.hasPrefix("/") else { return .failure(DoorProtocol.Refusal("--host-socket needs an absolute path")) }
        return .success(Arguments(session: session, helper: SessionHelper(role: role, root: root, task: values["--task"]),
                                  doorLine: doorLine, connector: connector, hostSocket: socket, toolServerImage: toolServer, hookImage: hook))
    }

    /// A line on the porter's stderr (the host's log).
    static func say(_ line: String) {
        Platform.Stdio.error("vibeswitcher-porter: \(line)\n")
    }

    /// `vibeswitcher-mcp --porter …`: the porter, which never returns. Anything else: returns at once.
    public static func runIfAsked(_ arguments: [String]) {
        guard arguments.count >= 2, arguments[1] == flag else { return }
        Platform.ProcessSelf.closeInheritedImage()
        _ = Platform.ProcessSelf.harden()
        if !Platform.CodeIdentity.isAvailable, Platform.ProcessSelf.tracer() != 0 { _exit(75) }
        let words = Array(arguments.dropFirst(2))
        markDescriptors(words)
        signal(SIGPIPE, SIG_IGN)
        guard !Platform.CodeIdentity.isAvailable else {
            say("not started: this system has no session sandbox")
            exit(69)
        }
        switch parse(words) {
        case .failure(let why):
            say("not started: \(why.description)")
            exit(64)
        case .success(let parsed):
            Serving(parsed).run()
        }
    }

    /// Every descriptor `words` name, made close-on-exec: they arrive kept, so inheritable, and no helper may hold one
    /// it isn't given.
    static func markDescriptors(_ words: [String]) {
        for flag in ["--door-line", "--host-connector", "--tool-server-image", "--hook-image"] {
            guard let at = words.firstIndex(of: flag), at + 1 < words.count, let fd = Int32(words[at + 1]), fd > STDERR_FILENO else { continue }
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }
}

extension Porter {
    /// The porter at work.
    final class Serving: @unchecked Sendable {
        let arguments: Porter.Arguments
        let environment: [String]
        private let lock = NSLock()
        /// The helpers running now, by pid (each its group's leader).
        private var helpers: Set<pid_t> = []
        private var connections = 0
        private var ending = false

        init(_ arguments: Porter.Arguments) {
            self.arguments = arguments
            let dropped: Set<String> = [DoorProtocol.variable, DoorProtocol.connectorVariable, DoorProtocol.hostSocketVariable,
                                        Platform.ProcessSelf.imageVariable]
            environment = ProcessInfo.processInfo.environment.filter { !dropped.contains($0.key) }.map { "\($0.key)=\($0.value)" }
                + ["\(DoorProtocol.connectorVariable)=\(arguments.connector)", "\(DoorProtocol.hostSocketVariable)=\(arguments.hostSocket)"]
        }

        func say(_ line: String) { Porter.say("session \(arguments.session.uuidString): \(line)") }

        func run() -> Never {
            guard let toolServer = Platform.ProcessSelf.adopt(arguments.toolServerImage),
                  let hook = Platform.ProcessSelf.adopt(arguments.hookImage) else {
                say("not started: the tool server's or the hook's image isn't a sealed copy")
                exit(78)
            }
            say("serving \(arguments.helper.role) at \(arguments.helper.root)" + (arguments.helper.task.map { ", task \($0)" } ?? ""))
            // Each message on the door line comes with its sender, the box's init, as the kernel names it here. The
            // host sets this on the line as it makes it (SB5), so a connection handed over before this statement has
            // its sender too; one that came with none gets no hook (`serve`).
            Platform.Sockets.enableCredentials(arguments.doorLine)
            while true {
                guard let (connection, boxInit) = Platform.Sockets.receiveDescriptorAndSender(over: arguments.doorLine) else {
                    // A message that carried no descriptor, or more than one: refused, and the line kept.
                    if errno == EBADMSG { continue }
                    break
                }
                let admitted: Bool = lock.withLock {
                    guard connections < Porter.maxConnections else { return false }
                    connections += 1
                    return true
                }
                guard admitted else {
                    say("refused: more than \(Porter.maxConnections) requests at once")
                    answer(connection, DoorProtocol.refusedLine("too many requests at once"))
                    Sys.close(connection)
                    continue
                }
                let thread = Thread { [self] in
                    serve(connection, boxInit: boxInit, toolServer: toolServer, hook: hook)
                    lock.withLock { connections -= 1 }
                }
                thread.name = "porter.connection"
                thread.start()
            }
            endEverything()
        }

        /// The door line has closed: every helper ended (SIGTERM, then SIGKILL after `endPatience`), then the exit.
        private func endEverything() -> Never {
            let running: Set<pid_t> = lock.withLock {
                ending = true
                return helpers
            }
            say("the door line closed: ending \(running.count) helper(s)")
            for pid in running { kill(-pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(Porter.endPatience)
            while Date() < deadline, !lock.withLock({ helpers.isEmpty }) { usleep(20_000) }
            for pid in lock.withLock({ helpers }) { kill(-pid, SIGKILL) }
            let collected = Date().addingTimeInterval(Porter.endPatience)
            while Date() < collected, !lock.withLock({ helpers.isEmpty }) { usleep(20_000) }
            exit(0)
        }

        /// Writes `line` to `connection`, whole or not at all (a relay gone fails it).
        private func answer(_ connection: Int32, _ line: String) {
            let bytes = Array(line.utf8)
            var sent = 0
            while sent < bytes.count {
                let count = bytes[sent...].withUnsafeBytes { Platform.Sockets.send(connection, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN {
                    var waiting = pollfd(fd: connection, events: Int16(POLLOUT), revents: 0)
                    guard poll(&waiting, 1, 1_000) > 0 else { return }
                    continue
                }
                guard count > 0 else { return }
                sent += count
            }
        }

        /// The relay's line and its three descriptors, within `helloPatience`; or why not, every descriptor that came
        /// closed.
        private func readHello(_ connection: Int32) -> Result<(DoorProtocol.Hello, [Int32]), DoorProtocol.Refusal> {
            let deadline = Date().addingTimeInterval(Porter.helloPatience)
            var line: [UInt8] = []
            var descriptors: [Int32]?
            func refuse(_ why: String) -> Result<(DoorProtocol.Hello, [Int32]), DoorProtocol.Refusal> {
                descriptors?.forEach { Sys.close($0) }
                return .failure(DoorProtocol.Refusal(why))
            }
            while true {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return refuse("no whole request within \(Int(Porter.helloPatience)) s") }
                var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                let ready = poll(&waiting, 1, Int32((left * 1_000).rounded(.up)))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { continue }
                // Room for one descriptor more than a hello carries, so that a fourth is seen, and refused.
                guard let got = Platform.Sockets.receive(over: connection, count: DoorProtocol.maxHello - line.count,
                                                         room: DoorProtocol.descriptors + 1) else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return refuse("the request couldn't be read (errno \(errno))")
                }
                if descriptors == nil {
                    descriptors = got.descriptors
                    if got.cut { return refuse("the request carried more descriptors than it may") }
                } else if !got.descriptors.isEmpty || got.cut {
                    got.descriptors.forEach { Sys.close($0) }
                    return refuse("descriptors came after the request's first bytes")
                }
                guard !got.bytes.isEmpty else { return refuse("the relay left before its request was whole") }
                line += got.bytes
                if let end = line.firstIndex(of: UInt8(ascii: "\n")) {
                    guard end == line.count - 1 else { return refuse("bytes came after the request's line") }
                    line.removeLast()
                    break
                }
                guard line.count < DoorProtocol.maxHello else { return refuse("the request is longer than \(DoorProtocol.maxHello) bytes") }
            }
            guard let taken = descriptors, taken.count == DoorProtocol.descriptors else {
                return refuse("a request carries exactly \(DoorProtocol.descriptors) descriptors, this one \(descriptors?.count ?? 0)")
            }
            switch DoorProtocol.hello(line) {
            case .failure(let refusal): return refuse(refusal.description)
            case .success(let hello): return .success((hello, taken))
            }
        }

        /// One door connection, from its line to its answer; the connection closed at the end. `boxInit`: the process
        /// that handed it over on the door line (the box's init), 0 when the kernel didn't say.
        private func serve(_ connection: Int32, boxInit: pid_t, toolServer: Platform.ProcessSelf.SealedCopy, hook: Platform.ProcessSelf.SealedCopy) {
            defer { Sys.close(connection) }
            // The relay's process, held from before its line is read: a relay may take `helloPatience` over its line
            // and leave meanwhile, its connection kept open by another process of its box, and its pid alone would
            // then name whichever process was given it next (`HookCaller`).
            let relay = Platform.Sockets.peerPID(connection)
            let held = relay.flatMap { Platform.ProcessExit.hold($0) }
            defer { if let held { Sys.close(held) } }
            let hello: DoorProtocol.Hello
            var stdio: [Int32]
            switch readHello(connection) {
            case .failure(let refusal):
                say("refused: \(refusal.description)")
                answer(connection, DoorProtocol.refusedLine(refusal.description))
                return
            case .success(let read):
                (hello, stdio) = read
            }
            // The relay's three, held until the helper has its own copies (or nothing starts).
            defer { stdio.forEach { Sys.close($0) } }
            func refuse(_ why: String) {
                say("refused a \(hello.mode.rawValue) request: \(why)")
                answer(connection, DoorProtocol.refusedLine(why))
            }
            if let why = Porter.allowed(hello, for: arguments.helper) { return refuse(why) }
            guard let caller = relay else { return refuse("the relay's process can't be named") }
            let image = hello.mode == .hook ? hook : toolServer
            var argv = Porter.command(hello, helper: arguments.helper, caller: caller)
            var keep = [image.fd, arguments.connector]
            if hello.mode == .hook {
                guard let held else { return refuse("the relay's process has gone") }
                guard boxInit > 1 else { return refuse("the door line didn't say which process is this box's init") }
                argv += [HookCaller.socketFlag, String(connection), HookCaller.heldFlag, String(held), HookCaller.boxFlag, String(boxInit)]
                keep += [connection, held]
            }
            // Something that reached the copy may have made it readable, and a helper started from a readable image is
            // dumpable from its exec.
            guard Platform.ProcessSelf.restoreMode(of: image.fd) else { return refuse("the helper's image isn't sealed") }
            var spawn = Platform.Spawn(executable: image.path, arguments: argv)
            spawn.environment = environment + ["\(Platform.ProcessSelf.imageVariable)=\(image.fd)"]
            spawn.stdin = .descriptor(stdio[0])
            spawn.stdout = .descriptor(stdio[1])
            spawn.stderr = .descriptor(stdio[2])
            spawn.keep = keep
            spawn.group = .ownGroup
            let pid: pid_t? = lock.withLock {
                guard !ending else { return nil }
                switch spawn.start() {
                case .failure: return nil
                case .success(let child):
                    helpers.insert(child)
                    return child
                }
            }
            guard let pid else { return refuse("the helper didn't start") }
            stdio.forEach { Sys.close($0) }
            stdio = []
            let status = watch(pid, connection: connection)
            lock.withLock { _ = helpers.remove(pid) }
            if let status { answer(connection, DoorProtocol.exitLine(status)) }
        }

        /// Waits until the helper `pid` ends (its status, 128 plus its signal for one a signal ended) or the relay goes
        /// or speaks again on `connection` (the helper's group ended, and nil).
        private func watch(_ pid: pid_t, connection: Int32) -> Int32? {
            let woke = DispatchSemaphore(value: 0)
            let queue = DispatchQueue(label: "porter.watch")
            let exitWatch = Platform.ProcessExit.watch(pid, queue: queue) { woke.signal() }
            let relay = DispatchSource.makeReadSource(fileDescriptor: connection, queue: queue)
            // Ready again and again until cancelled just below: the first wakes the wait.
            relay.setEventHandler { woke.signal() }
            relay.resume()
            woke.wait()
            relay.cancel()
            exitWatch.cancel()
            var status: Int32 = 0
            var collected = waitpid(pid, &status, WNOHANG)
            while collected < 0, errno == EINTR { collected = waitpid(pid, &status, WNOHANG) }
            if collected == pid { return Self.status(status) }
            // The relay went first: its helper goes too.
            kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(Porter.endPatience)
            while Date() < deadline {
                collected = waitpid(pid, &status, WNOHANG)
                if collected == pid || (collected < 0 && errno != EINTR) { return nil }
                usleep(20_000)
            }
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            return nil
        }

        /// A wait status as a shell gives it: the exit status, or 128 plus the signal.
        static func status(_ status: Int32) -> Int32 {
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
    }
}
