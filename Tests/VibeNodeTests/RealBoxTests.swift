import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A real box for the tests of this target: the shim's own (`Platform.Sandbox.enter`), entered by this test binary in
/// its launcher mode. That mode is VibePlatformTests' (`ShimBox`, SandboxShimTests.swift: every test target is one
/// binary on Linux, and the launcher runs before any test of it): started again with `requestVariable` naming a
/// request file, it enters the plan the file holds and runs its program. The file's lines are written here as
/// `ShimBox.Request.lines` writes them: tab-separated fields, each in hex.
enum RealBox {
    /// `ShimBox.requestVariable`.
    static let requestVariable = "VIBE_SANDBOX_TEST_REQUEST"

    /// Why no box can be built here; nil when one can.
    static let unavailable: String? = Platform.Sandbox.probe().why

    /// The folder of the Swift runtime's libraries this binary runs on (a toolchain's `usr/lib/swift/linux`), which the
    /// built tool server and hook need inside a box too; nil when this binary's map doesn't show one.
    static let runtime: String? = {
        // Read with libc to its end: Foundation's whole-file reads take the size `stat` gives, which is 0 in /proc.
        let fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += chunk[0..<count]
        }
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where line.hasSuffix("/libswiftCore.so") {
            guard let slash = line.firstIndex(of: "/") else { continue }
            return SandboxPolicy.resolved((String(line[slash...]) as NSString).deletingLastPathComponent)
        }
        return nil
    }()

    /// The built products' folder, its links followed (`.build/debug` is one).
    static let products = SandboxPolicy.resolved(builtProducts.path)

    /// A plan over `folder` (read-write, where the program starts): the machine's `/usr` and `/etc` read-only, the
    /// box's own `/proc`, `/dev` and `/tmp`, the built products and the Swift runtime read-only at their own paths,
    /// and a door when `door`.
    static func plan(_ folder: String, door: Bool, network: Platform.Sandbox.Network = .shared, terminal: Platform.Sandbox.Terminal = .none,
                     environment: [String] = []) -> Platform.Sandbox.Plan {
        var mounts: [Platform.Sandbox.Mount] = [
            .init("/usr", .readOnly(source: "/usr")), .init("/etc", .readOnly(source: "/etc")),
            .init("/bin", .link(to: "usr/bin")), .init("/lib", .link(to: "usr/lib")),
            .init("/lib64", .link(to: "usr/lib64")), .init("/sbin", .link(to: "usr/sbin")),
            .init("/proc", .proc), .init("/dev", .empty(mode: 0o755)),
        ]
        mounts += ["null", "zero", "full", "random", "urandom", "tty"].map { .init("/dev/\($0)", .device($0)) }
        mounts += [.init("/dev/pts", .devpts), .init("/dev/ptmx", .link(to: "pts/ptmx")), .init("/tmp", .empty(mode: 0o1777))]
        if door { mounts.append(.init(SandboxPlanner.doorFolder, .empty(mode: 0o700))) }
        mounts.append(.init(folder, .readWrite(source: folder)))
        mounts.append(.init(products, .readOnly(source: products)))
        if let runtime { mounts.append(.init(runtime, .readOnly(source: runtime))) }
        return Platform.Sandbox.Plan(mounts: mounts, network: network, hostname: "box", directory: folder,
                                     environment: ["PATH=/usr/bin:/bin", "HOME=\(folder)", "LANG=C.UTF-8", "TMPDIR=/tmp"]
                                         + (door ? ["\(DoorProtocol.variable)=\(SandboxPlanner.door)"] : []) + environment,
                                     door: door ? SandboxPlanner.door : nil, terminal: terminal, nesting: false)
    }

    /// The request file's text for `plan`, `program` and the descriptors, as `ShimBox.Request.lines` writes it. Only
    /// the mounts `plan(_:door:)` makes are written.
    static func request(_ plan: Platform.Sandbox.Plan, _ program: [String], doorLine: Int32?, proxyOut: Int32?) -> String {
        func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
        var lines: [[String]] = []
        for mount in plan.mounts {
            switch mount.kind {
            case .readOnly(let source): lines.append(["ro", mount.target, source])
            case .readWrite(let source): lines.append(["rw", mount.target, source])
            case .empty(let mode): lines.append(["empty", mount.target, String(mode)])
            case .proc: lines.append(["proc", mount.target])
            case .devpts: lines.append(["devpts", mount.target])
            case .device(let name): lines.append(["device", mount.target, name])
            case .link(let text): lines.append(["link", mount.target, text])
            case .overlay, .sysfs, .file, .binfmt: preconditionFailure("not a mount RealBox.plan makes")
            }
        }
        switch plan.network {
        case .shared: lines.append(["network", "shared"])
        case .none: lines.append(["network", "none"])
        case .proxied(let port): lines.append(["network", "proxied", String(port)])
        }
        lines.append(["hostname", plan.hostname])
        lines.append(["directory", plan.directory])
        lines += plan.environment.map { ["env", $0] }
        if let door = plan.door { lines.append(["door", door]) }
        lines.append(["terminal", plan.terminal.rawValue])
        lines.append(["nesting", plan.nesting ? "1" : "0"])
        lines += program.map { ["program", $0] }
        if let doorLine { lines.append(["doorLine", String(doorLine)]) }
        if let proxyOut { lines.append(["proxyOut", String(proxyOut)]) }
        return lines.map { $0.map(hex).joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// A launcher started on `plan` with `program`: its pid, and what it writes on stdout and stderr together, in
    /// `output` (a file). `terminal`: a pty's slave to give it as its three descriptors, in a session of its own whose
    /// terminal that becomes; nil: no terminal, and `/dev/null` as its input.
    static func launch(_ plan: Platform.Sandbox.Plan, _ program: [String], in scratch: URL, output: URL, doorLine: Int32? = nil,
                       proxyOut: Int32? = nil, terminal: String? = nil) throws -> pid_t {
        try #require(getenv(requestVariable) == nil)
        let file = scratch.appendingPathComponent("request-\(UUID().uuidString.prefix(8)).txt")
        try Data(request(plan, program, doorLine: doorLine, proxyOut: proxyOut).utf8).write(to: file)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(requestVariable)=\(file.path)"]
        spawn.keep = [doorLine, proxyOut].compactMap { $0 }
        if let terminal {
            spawn.group = .ownSession
            spawn.stdin = .path(terminal, flags: O_RDWR)
            spawn.stdout = .sameAsStdin
            spawn.stderr = .sameAsStdin
        } else {
            spawn.group = .ownGroup
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            spawn.stdout = .path(output.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
            spawn.stderr = .path(output.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        }
        return try spawn.start().get()
    }
}

/// The two lanes joined (the session sandbox plan's SB1 with SB4 and SB9): a real box in place of the stand-ins the
/// door's and the proxy's own tests use. The door a relay finds inside is the one the shim's init bound, each
/// connection goes whole over the door line to a real porter, which learns the box's init from the line itself; a
/// hook run under the agent finds it, and its session's terminal, across the box's pid namespace; and the listener a
/// box makes in its own network namespace is served by the real proxy, under its session's rules.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && RealBox.unavailable == nil,
                "needs a box: \(RealBox.unavailable ?? "the Mac has none")"), .timeLimit(.minutes(5)))
struct RealBoxTests {
    private let scratch = Scratch()
    static let worker = SessionHelper(role: "worker", root: "/r/main", task: "t1")

    /// A box's folder (its links followed: the shim refuses a source with a link along it) and the launcher's output.
    func folders(_ name: String) throws -> (box: URL, outside: URL, output: URL) {
        let outside = URL(fileURLWithPath: SandboxPolicy.resolved(try scratch.shortFolder(name).path))
        let box = outside.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        return (box, outside, outside.appendingPathComponent("launcher.out"))
    }

    func text(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    @Test func aRelayInARealBoxIsAnsweredByItsPorterOutside() async throws {
        let (box, outside, output) = try folders("rb-door")
        let rig = try PorterRig(scratch, helper: Self.worker, environment: testBuildEnvironment("outside"))
        let mcp = RealBox.products + "/vibeswitcher-mcp"
        // The status line's relay, its input the box's own: the helper outside keeps the usage and shows it.
        let input = #"{"rate_limits": {"five_hour": {"used_percentage": 12}}}"#
        let script = "printf '%s' '\(input)' | \(FakeClaude.quoted(mcp)) \(UsageStatusLine.argument); echo; echo status $?; test -S \(SandboxPlanner.door) && echo door"
        let launcher = try RealBox.launch(RealBox.plan(box.path, door: true), ["/bin/sh", "-c", script], in: outside, output: output,
                                          doorLine: rig.doorLine)
        let status = await offPool { collected(launcher, by: MacTime.real.awake() + 120) }
        #expect(status == 0, "\(text(output)) \(rig.log)")
        let lines = text(output).split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("5h 12%") == true && lines.contains("status 0") && lines.contains("door"), "\(text(output)) \(rig.log)")
        // The porter was told which process the box's init is by the door line, never by the box.
        #expect(!rig.log.contains("refused"), "\(rig.log)")
    }

    /// A hook run under the agent in a real box: the helper outside finds the agent and the session's terminal from
    /// the relay's ancestors as the machine numbers them, up to the box's init and no further, and writes the state
    /// file of the terminal the session was given, the one its keeper leads.
    @Test func aHookInARealBoxWritesTheStateOfItsSessionsTerminal() async throws {
        let (box, outside, output) = try folders("rb-hook")
        let home = try scratch.shortFolder("rb-out")
        let rig = try PorterRig(scratch, helper: Self.worker, environment: ["VIBESWITCHER_HOME": home.path])
        let terminal = try Platform.Terminals.open(rows: 24, cols: 80).get()
        defer { [terminal.master, terminal.slave].forEach { Sys.close($0) } }
        let name = "tty" + terminal.devicePath.dropFirst("/dev/".count).replacingOccurrences(of: "/", with: "")
        // The agent: a shell named for Claude Code, on the session's terminal, which runs the hook as Claude Code does.
        try FileManager.default.createSymbolicLink(atPath: box.appendingPathComponent("claude").path, withDestinationPath: "/bin/sh")
        let event: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "real-box", "prompt": "hi", "cwd": box.path]
        try JSONSerialization.data(withJSONObject: event).write(to: box.appendingPathComponent("event.json"))
        let hook = RealBox.products + "/vibeswitcher-hook"
        try "\(FakeClaude.quoted(hook)) claude < event.json > out 2> err; echo $? > status.tmp; mv status.tmp status\n"
            .write(to: box.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
        let launcher = try RealBox.launch(RealBox.plan(box.path, door: true, terminal: .foreground),
                                          [box.appendingPathComponent("claude").path, box.appendingPathComponent("agent.sh").path],
                                          in: outside, output: output, doorLine: rig.doorLine, terminal: terminal.devicePath)
        let status = await offPool { collected(launcher, by: MacTime.real.awake() + 120) }
        #expect(status == 0, "\(rig.log)")
        #expect(text(box.appendingPathComponent("status")).trimmingCharacters(in: .whitespacesAndNewlines) == "0", "\(text(box.appendingPathComponent("err"))) \(rig.log)")
        let written = try #require(HookState.load(from: home.appendingPathComponent("state/\(name).json")), "\(rig.log)")
        #expect(written.lastEvent == "UserPromptSubmit" && written.tty == name)
        // The agent as the machine numbers it: a process under the launcher, not pid 2 of the box.
        let agent = try #require(written.agentPid)
        #expect(agent > 2)
        // Nothing else was written: no state for a terminal number of the box's own making.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("state").path))?.filter { $0.hasSuffix(".json") } == ["\(name).json"])
    }

    /// A box on its own network hands its listener out, and the real proxy serves it under the session's rules: a
    /// request for a host off the list is refused inside, by name, with nothing resolved.
    @Test func aRealBoxsListenerIsServedByTheProxyUnderItsSessionsRules() async throws {
        let (box, outside, output) = try folders("rb-proxy")
        guard let pair = Platform.Sockets.pair(type: Platform.Sockets.stream) else { throw Platform.Errno(code: errno) }
        defer { Sys.close(pair.0) }
        let asked = LockedList()
        let dialer = EgressProxy.Dialer(resolve: { name in
            asked.add(name)
            return nil
        }, connect: { _, _, _ in nil })
        let server = EgressProxy.Server(dialer: dialer, log: { _ in })
        defer { withExtendedLifetime(server) {} }
        let session = UUID()
        let rules = EgressRules.session(role: .worker, policy: SandboxPolicy(hosts: ["listed.example"]), agent: nil)
        let probe = """
            import socket
            for host in ["off-the-list.example", "listed.example", "127.0.0.1"]:
                connection = socket.create_connection(("127.0.0.1", 3128), timeout=30)
                connection.sendall(("CONNECT %s:443 HTTP/1.1\\r\\nHost: %s:443\\r\\n\\r\\n" % (host, host)).encode())
                print(host, connection.recv(200).decode().split("\\r\\n")[0], flush=True)
                connection.close()
            """
        let launcher = try RealBox.launch(RealBox.plan(box.path, door: false, network: .proxied(port: 3128)),
                                          ["/usr/bin/python3", "-I", "-c", probe], in: outside, output: output, proxyOut: pair.1)
        Sys.close(pair.1)
        // The listener, as init hands it out: one message carrying it.
        let listener = try #require(await offPool { Platform.Sockets.receiveDescriptor(over: pair.0) }, "\(text(output))")
        server.add(listener: listener, session: session, rules: rules)
        let status = await offPool { collected(launcher, by: MacTime.real.awake() + 120) }
        #expect(status == 0, "\(text(output))")
        let lines = text(output).split(separator: "\n").map(String.init)
        #expect(lines.contains("off-the-list.example HTTP/1.1 403 Forbidden"), "\(lines)")
        #expect(lines.contains("127.0.0.1 HTTP/1.1 403 Forbidden"), "\(lines)")
        // The listed name was let through to the resolver (which here knows nothing: 403, it doesn't resolve).
        #expect(lines.contains("listed.example HTTP/1.1 403 Forbidden"), "\(lines)")
        #expect(asked.all == ["listed.example"])
    }

    final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }
}
