import Foundation
import Testing
@testable import VibePlatform

#if os(Linux)
// Linux only: the shim's box is Linux's: on the Mac `Platform.Sandbox` builds none (`SandboxPlanCodingTests.theMacHasNoSandbox`).

/// The test binary's launcher mode, for `ShimBox`: started again with `ShimBox.requestVariable` naming a request file
/// (a plan, its program and the descriptors to hand it, in `ShimBox.Request`'s lines), this binary enters the plan
/// before any test of its own, while it has one thread, as a session's launcher does. It never returns from a plan that
/// ran; for one that couldn't be applied it writes "sandbox failure: STEP: CODE" to stderr and exits 127. 126: the
/// request couldn't be read.
private func enterIfAsked() {
    guard let path = getenv(ShimBox.requestVariable) else { return }
    guard let request = ShimBox.Request.read(path) else { _exit(126) }
    if request.thread {
        // A second thread, as a launcher must never have (`aProcessWithThreadsIsRefused`).
        var thread = pthread_t()
        _ = pthread_create(&thread, nil, { _ in sleep(600); return nil }, nil)
    }
    let failure = Platform.Sandbox.enter(request.plan, doorLine: request.doorLine, proxyOut: request.proxyOut, program: request.program)
    let line = "sandbox failure: \(failure.step): \(failure.code)\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    _exit(127)
}

// Before every other initializer of this binary (the lowest priority number runs first): VibeCoreTests' zombie watch
// starts a libdispatch timer as the bundle loads, and the thread that runs it would make this a process with two. The
// runtime hasn't registered this binary's types yet either, so nothing here may look one up by name: the request is
// lines of hex read with libc (`Request.read`), never JSON's Codable.
@_used @_section(".init_array.00200")
private let enterWhenAsked: @convention(c) () -> Void = { enterIfAsked() }

/// Boxes for the shim's tests: a plan over a scratch folder, entered by this test binary in its launcher mode, its
/// program a shell or `python3 -I` with the probe a test gives. Nothing here confines the test process itself: every
/// box is a child's.
enum ShimBox {
    static let requestVariable = "VIBE_SANDBOX_TEST_REQUEST"

    /// What the launcher mode is asked: written by the test as lines of tab-separated hex fields (`lines`), read in
    /// the launcher with libc alone (`read`), before the runtime knows this binary's types.
    struct Request {
        var plan: Platform.Sandbox.Plan
        var program: [String]
        var doorLine: Int32?
        var proxyOut: Int32?
        var thread = false

        static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }

        static func unhex(_ text: Substring) -> String {
            var bytes: [UInt8] = []
            var index = text.startIndex
            while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
                bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
                index = next
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        var lines: String {
            var lines: [[String]] = []
            for mount in plan.mounts {
                switch mount.kind {
                case .readOnly(let source): lines.append(["ro", mount.target, source])
                case .readWrite(let source): lines.append(["rw", mount.target, source])
                case .overlay(let lower, let upper, let work): lines.append(["overlay", mount.target, lower, upper, work])
                case .empty(let mode): lines.append(["empty", mount.target, String(mode)])
                case .proc: lines.append(["proc", mount.target])
                case .devpts: lines.append(["devpts", mount.target])
                case .sysfs: lines.append(["sysfs", mount.target])
                case .device(let name): lines.append(["device", mount.target, name])
                case .link(let text): lines.append(["link", mount.target, text])
                case .file(let contents, let mode): lines.append(["file", mount.target, String(decoding: contents, as: UTF8.self), String(mode)])
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
            if thread { lines.append(["thread", "1"]) }
            return lines.map { $0.map(Self.hex).joined(separator: "\t") }.joined(separator: "\n") + "\n"
        }

        /// The request at `path`; nil when it can't be read.
        static func read(_ path: UnsafePointer<CChar>) -> Request? {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Sys.read(fd, &chunk, chunk.count)
                if count <= 0 { break }
                bytes += chunk[0..<count]
            }
            close(fd)
            var plan = Platform.Sandbox.Plan(mounts: [], network: .none, hostname: "", directory: "/", environment: [], door: nil,
                                             terminal: .none, nesting: false)
            var request = Request(plan: plan, program: [], doorLine: nil, proxyOut: nil)
            for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unhex($0) }
                guard let key = fields.first else { continue }
                let rest = Array(fields.dropFirst())
                func field(_ index: Int) -> String { index < rest.count ? rest[index] : "" }
                switch key {
                case "ro": plan.mounts.append(.init(field(0), .readOnly(source: field(1))))
                case "rw": plan.mounts.append(.init(field(0), .readWrite(source: field(1))))
                case "overlay": plan.mounts.append(.init(field(0), .overlay(lower: field(1), upper: field(2), work: field(3))))
                case "empty": plan.mounts.append(.init(field(0), .empty(mode: UInt32(field(1)) ?? 0o755)))
                case "proc": plan.mounts.append(.init(field(0), .proc))
                case "devpts": plan.mounts.append(.init(field(0), .devpts))
                case "sysfs": plan.mounts.append(.init(field(0), .sysfs))
                case "device": plan.mounts.append(.init(field(0), .device(field(1))))
                case "link": plan.mounts.append(.init(field(0), .link(to: field(1))))
                case "file": plan.mounts.append(.init(field(0), .file(contents: Data(field(1).utf8), mode: UInt32(field(2)) ?? 0o644)))
                case "network":
                    switch field(0) {
                    case "shared": plan.network = .shared
                    case "proxied": plan.network = .proxied(port: UInt16(field(1)) ?? 0)
                    default: plan.network = .none
                    }
                case "hostname": plan.hostname = field(0)
                case "directory": plan.directory = field(0)
                case "env": plan.environment.append(field(0))
                case "door": plan.door = field(0)
                case "terminal": plan.terminal = field(0) == "foreground" ? .foreground : .none
                case "nesting": plan.nesting = field(0) == "1"
                case "program": request.program.append(field(0))
                case "doorLine": request.doorLine = Int32(field(0))
                case "proxyOut": request.proxyOut = Int32(field(0))
                case "thread": request.thread = true
                default: return nil
                }
            }
            request.plan = plan
            return request
        }
    }

    /// Why no box can be built here; nil when one can.
    static let unavailable: String? = Platform.Sandbox.probe().why

    /// Whether `python3` is there for the probes that need a system call a shell can't make.
    static let python = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

    /// The base of every plan: `/usr` and `/etc` read-only with the usual links, the box's own `/proc`, `/dev` and
    /// `/tmp`, and `folder` read-write, where the program starts.
    static func plan(_ folder: String, extra: [Platform.Sandbox.Mount] = [], network: Platform.Sandbox.Network = .none,
                     terminal: Platform.Sandbox.Terminal = .none, door: String? = nil, nesting: Bool = false,
                     environment: [String] = []) -> Platform.Sandbox.Plan {
        var mounts: [Platform.Sandbox.Mount] = [
            .init("/usr", .readOnly(source: "/usr")),
            .init("/etc", .readOnly(source: "/etc")),
            .init("/bin", .link(to: "usr/bin")), .init("/lib", .link(to: "usr/lib")),
            .init("/lib64", .link(to: "usr/lib64")), .init("/sbin", .link(to: "usr/sbin")),
            .init("/proc", .proc),
            .init("/dev", .empty(mode: 0o755)),
        ]
        mounts += ["null", "zero", "full", "random", "urandom", "tty"].map { .init("/dev/\($0)", .device($0)) }
        mounts += [.init("/dev/pts", .devpts), .init("/dev/ptmx", .link(to: "pts/ptmx")), .init("/tmp", .empty(mode: 0o1777))]
        if let door { mounts.append(.init((door as NSString).deletingLastPathComponent, .empty(mode: 0o700))) }
        mounts.append(.init(folder, .readWrite(source: folder)))
        return Platform.Sandbox.Plan(mounts: mounts + extra, network: network, hostname: "box", directory: folder,
                                     environment: ["PATH=/usr/bin:/bin", "HOME=\(folder)", "LANG=C.UTF-8", "TMPDIR=/tmp"] + environment,
                                     door: door, terminal: terminal, nesting: nesting)
    }

    /// A launcher started on `plan`, and what it wrote.
    final class Launched: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private let readers = DispatchGroup()

        init(pid: pid_t, output: Int32?, errors: Int32?) {
            self.pid = pid
            for (fd, isOutput) in [(output, true), (errors, false)] {
                guard let fd else { continue }
                readers.enter()
                Thread { [self] in
                    var chunk = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = read(fd, &chunk, chunk.count)
                        if count < 0, errno == EINTR { continue }
                        if count <= 0 { break }
                        lock.lock()
                        if isOutput { out.append(contentsOf: chunk[0..<count]) } else { err.append(contentsOf: chunk[0..<count]) }
                        lock.unlock()
                    }
                    close(fd)
                    readers.leave()
                }.start()
            }
        }

        var output: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: out, as: UTF8.self)
        }

        var errors: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: err, as: UTF8.self)
        }

        /// The launcher's end, waited for (a bounded wait: killed after `limit`), and its pipes read to their end.
        func ended(limit: TimeInterval = 120) -> SpawnTests.Ended {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(limit)
            var killed = false
            while true {
                let found = waitpid(pid, &status, WNOHANG)
                if found == pid { break }
                if found < 0, errno != EINTR { break }
                if Date() > deadline, !killed {
                    kill(pid, SIGKILL)
                    killed = true
                }
                usleep(2_000)
            }
            _ = readers.wait(timeout: .now() + 30)
            var ended = SpawnTests.Ended()
            if status & 0x7f == 0 { ended.exit = (status >> 8) & 0xff } else { ended.signal = status & 0x7f }
            ended.output = output
            return ended
        }

        /// Whether it is still running (not yet collected).
        var running: Bool { kill(pid, 0) == 0 }
    }

    /// Starts this test binary in its launcher mode on `plan` with `program`. Its stdout and stderr are pipes the
    /// result reads, unless `terminal` names a pty slave to give it as all three (in a session of its own, whose
    /// terminal that becomes).
    static func launch(_ plan: Platform.Sandbox.Plan, _ program: [String], in folder: URL, doorLine: Int32? = nil,
                       proxyOut: Int32? = nil, keep: [Int32] = [], thread: Bool = false, terminal: String? = nil,
                       group: Platform.Spawn.Group = .ownGroup) throws -> Launched {
        try #require(getenv(requestVariable) == nil)
        let request = Request(plan: plan, program: program, doorLine: doorLine, proxyOut: proxyOut, thread: thread)
        let file = folder.deletingLastPathComponent().appendingPathComponent("request-\(UUID().uuidString.prefix(8)).txt")
        try Data(request.lines.utf8).write(to: file)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(requestVariable)=\(file.path)"]
        spawn.keep = keep + [doorLine, proxyOut].compactMap { $0 }
        var output: (reading: Int32, writing: Int32)?, errors: (reading: Int32, writing: Int32)?
        if let terminal {
            spawn.group = .ownSession
            spawn.stdin = .path(terminal, flags: O_RDWR)
            spawn.stdout = .sameAsStdin
            spawn.stderr = .sameAsStdin
        } else {
            spawn.group = group
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            output = try SpawnTests.newPipe()
            errors = try SpawnTests.newPipe()
            spawn.stdout = .descriptor(output!.writing)
            spawn.stderr = .descriptor(errors!.writing)
        }
        let started = spawn.start()
        if let output { close(output.writing) }
        if let errors { close(errors.writing) }
        let pid = try started.get()
        return Launched(pid: pid, output: output?.reading, errors: errors?.reading)
    }

    /// Runs `program` in a box of `plan` to its end.
    static func run(_ plan: Platform.Sandbox.Plan, _ program: [String], in folder: URL, doorLine: Int32? = nil,
                    proxyOut: Int32? = nil, keep: [Int32] = [], thread: Bool = false) throws -> (ended: SpawnTests.Ended, errors: String) {
        let launched = try launch(plan, program, in: folder, doorLine: doorLine, proxyOut: proxyOut, keep: keep, thread: thread)
        let ended = launched.ended()
        return (ended, launched.errors)
    }

    /// `sh -c script` in a box of `plan`: its exit, its output and its errors.
    static func shell(_ script: String, _ plan: Platform.Sandbox.Plan, in folder: URL) throws -> (ended: SpawnTests.Ended, errors: String) {
        try run(plan, ["/bin/sh", "-c", script], in: folder)
    }

    /// `python3 -I -c source` in a box of `plan`.
    static func python(_ source: String, _ plan: Platform.Sandbox.Plan, in folder: URL) throws -> (ended: SpawnTests.Ended, errors: String) {
        try run(plan, ["/usr/bin/python3", "-I", "-c", source], in: folder)
    }

    /// A scratch folder for one test: `box/` inside it is the box's read-write folder (made), and the rest is the
    /// test's own, outside the box.
    static func scratch(_ name: String) throws -> (root: URL, box: URL) {
        let root = try ProcessesTests.scratch(name).resolvingSymlinksInPath()
        let box = root.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        return (root, box)
    }

    /// The lines of `text`.
    static func lines(_ text: String) -> [String] { text.split(separator: "\n").map(String.init) }

    /// The children of `pid`, from /proc (`Platform.Processes.children`).
    static func children(of pid: pid_t) -> [pid_t] { Platform.Processes.children(pid) }

    /// The pids of the processes whose command line holds `marker`, from /proc.
    static func processes(holding marker: String) -> [pid_t] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }.filter { pid in
            guard pid != getpid() else { return false }
            return procText("/proc/\(pid)/cmdline").contains(marker)
        }
    }

    /// A /proc file's text, read with libc to its end ("" when it can't be opened): Foundation's whole-file reads take
    /// the size `stat` gives, which is 0 there, and a file that grew while it read once crashed the run
    /// ("UnsafeMutablePointer.initialize overlapping range" in `contents(atPath:)`).
    static func procText(_ path: String) -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            bytes += chunk[0..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Polls `condition` every 10 ms for up to `timeout` seconds.
    static func eventually(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}

/// `Platform.Sandbox.enter`, over scratch folders: what a program in a box sees and holds, how the box ends, and that a
/// plan that can't be applied starts nothing. Each runs where `probe()` says a box can be built, and says why it skips
/// elsewhere (GitHub's hosted runner refuses unprivileged user namespaces: SB-D15).
@Suite(.serialized) struct SandboxShimTests {
    static let skip = "needs a box: \(ShimBox.unavailable ?? "")"
    static let can = ShimBox.unavailable == nil

    @Test(.enabled(if: can, "\(skip)"))
    func theProgramSeesOnlyWhatThePlanMounts() throws {
        let (root, box) = try ShimBox.scratch("shim-sees")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        let beside = root.appendingPathComponent("beside")
        try Data("decoy".utf8).write(to: beside)
        let script = """
            ls -A /
            for path in "\(account)" /run /mnt /init /sys /home "\(beside.path)"; do [ -e "$path" ] && echo "present $path" || echo "absent $path"; done
            echo "hostname $(cat /proc/sys/kernel/hostname)"
            touch /made 2>/dev/null && echo "root writable" || echo "root read-only"
            awk '{ for (i = 7; $i != "-"; i++) if ($i ~ /^(shared|master|propagate_from):/) print "propagates " $5 }' /proc/self/mountinfo
            """
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = ShimBox.lines(ended.output)
        let top = Array(lines.prefix { !$0.hasPrefix("absent") && !$0.hasPrefix("present") })
        #expect(Set(top) == ["bin", "dev", "etc", "lib", "lib64", "proc", "sbin", "tmp", "usr"], "\(ended.output)")
        for path in [account, "/run", "/mnt", "/init", "/sys", "/home", beside.path] {
            #expect(lines.contains("absent \(path)"), "\(ended.output)")
        }
        #expect(lines.contains("hostname box"), "\(ended.output)")
        #expect(lines.contains("root read-only"), "\(ended.output)")
        // No mount inside takes part in a peer group outside: nothing mounted outside later shows up inside.
        #expect(!lines.contains { $0.hasPrefix("propagates") }, "\(ended.output)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aReadOnlyMountRefusesWritesAndKeepsItsLockedFlags() throws {
        let (root, box) = try ShimBox.scratch("shim-ro")
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = root.appendingPathComponent("shown")
        try FileManager.default.createDirectory(at: shown, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: shown.appendingPathComponent("file"))
        let plan = ShimBox.plan(box.path, extra: [.init(shown.path, .readOnly(source: shown.path))])
        let script = """
            cat "\(shown.path)/file"; echo
            echo changed > "\(shown.path)/file" 2>/dev/null && echo "wrote file" || echo "file refused"
            touch "\(shown.path)/new" 2>/dev/null && echo "made new" || echo "new refused"
            awk '{ print $5, $6 }' /proc/self/mountinfo
            """
        let (ended, errors) = try ShimBox.shell(script, plan, in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = ShimBox.lines(ended.output)
        #expect(lines.first == "kept" && lines.contains("file refused") && lines.contains("new refused"), "\(ended.output)")
        #expect(String(data: try Data(contentsOf: shown.appendingPathComponent("file")), encoding: .utf8) == "kept")
        #expect(!FileManager.default.fileExists(atPath: shown.appendingPathComponent("new").path))
        // Every mount below a read-only one is read-only, nosuid and nodev, with the atime flag the machine's has
        // (which the kernel locks): /usr's own mounts on WSL among them.
        let inside = Dictionary(lines.compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { $1 })
        let options = { (point: String) in Set((inside[point] ?? "").split(separator: ",").map(String.init)) }
        #expect(options(shown.path).isSuperset(of: ["ro", "nosuid", "nodev"]), "\(inside)")
        let outside = ShimBox.procText("/proc/self/mountinfo")
        var checked = 0
        for line in outside.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count > 5, parts[4] == "/usr" || parts[4].hasPrefix("/usr/") else { continue }
            let point = String(parts[4]), machine = Set(parts[5].split(separator: ",").map(String.init))
            let box = options(point)
            #expect(box.isSuperset(of: ["ro", "nosuid", "nodev"]), "\(point): \(box)")
            for flag in ["noatime", "relatime", "noexec"] where machine.contains(flag) { #expect(box.contains(flag), "\(point): \(box) vs \(machine)") }
            checked += 1
        }
        #expect(checked >= 1)
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aPrivateMountKeepsWritesOutOfTheRealFolder() throws {
        let (root, box) = try ShimBox.scratch("shim-private")
        let real = root.appendingPathComponent("cache"), upper = root.appendingPathComponent("layer/upper")
        let work = root.appendingPathComponent("layer/work")
        // overlayfs leaves `work/work` with no permission at all (mode 000): opened up first, or it can't be removed.
        defer {
            chmod(work.appendingPathComponent("work").path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        for folder in [real, upper, work] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("real".utf8).write(to: real.appendingPathComponent("kept"))
        let plan = ShimBox.plan(box.path, extra: [.init(real.path, .overlay(lower: real.path, upper: upper.path, work: work.path))])
        let script = """
            cat "\(real.path)/kept"; echo
            echo changed > "\(real.path)/kept" && echo made > "\(real.path)/new" && rm "\(real.path)/kept" && echo "wrote"
            ls "\(real.path)"
            """
        let (ended, errors) = try ShimBox.shell(script, plan, in: box)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["real", "wrote", "new"], "\(ended.output)")
        // The real folder is as it was; what the box wrote is in its layer.
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path) == ["kept"])
        #expect(String(data: try Data(contentsOf: real.appendingPathComponent("kept")), encoding: .utf8) == "real")
        #expect(FileManager.default.fileExists(atPath: upper.appendingPathComponent("new").path))
    }

    @Test(.enabled(if: can, "\(skip)"))
    func theProgramIsTheUsersUidWithNoCapabilityAndNoNewPrivileges() throws {
        let (root, box) = try ShimBox.scratch("shim-uid")
        defer { try? FileManager.default.removeItem(at: root) }
        let (ended, errors) = try ShimBox.shell("grep -E '^(Uid|Gid|Cap[A-Za-z]+|NoNewPrivs|Seccomp):' /proc/self/status | tr -s '\\t ' ' '",
                                                ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = Set(ShimBox.lines(ended.output))
        let uid = getuid(), gid = getgid()
        #expect(lines.contains("Uid: \(uid) \(uid) \(uid) \(uid)") && lines.contains("Gid: \(gid) \(gid) \(gid) \(gid)"), "\(ended.output)")
        for set in ["CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"] { #expect(lines.contains("\(set): 0000000000000000"), "\(ended.output)") }
        #expect(lines.contains("NoNewPrivs: 1") && lines.contains("Seccomp: 2"), "\(ended.output)")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func theProgramSeesOnlyItsOwnProcesses() throws {
        let (root, box) = try ShimBox.scratch("shim-processes")
        defer { try? FileManager.default.removeItem(at: root) }
        let decoy = try SpawnTests.held(.ownGroup)
        defer {
            close(decoy.release)
            _ = SpawnTests.ended(decoy.pid)
        }
        let script = """
            set -- /proc/[0-9]*; echo "processes $#"
            kill -0 \(decoy.pid) 2>/dev/null && echo "decoy signalled" || echo "decoy unknown"
            [ -e /proc/\(decoy.pid) ] && echo "decoy listed" || echo "decoy unlisted"
            echo "init $(cat /proc/1/comm)"
            """
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        let lines = ShimBox.lines(ended.output)
        // init and the shell, which counts with a glob of its own.
        let count = lines.first.flatMap { Int($0.dropFirst("processes ".count)) } ?? 99
        #expect(count == 2, "\(ended.output)")
        #expect(lines.contains("decoy unknown") && lines.contains("decoy unlisted"), "\(ended.output)")
        #expect(kill(decoy.pid, 0) == 0)
    }

    @Test(.enabled(if: can, "\(skip)"))
    func everyProcessEndsWithTheProgram() throws {
        let (root, box) = try ShimBox.scratch("shim-ends")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "600.\(UInt32.random(in: 100_000...999_999))"
        defer { ShimBox.processes(holding: marker).forEach { kill($0, SIGKILL) } }
        // A double fork, setsid and nohup: each would outlive a shell that ends.
        let script = """
            setsid sleep \(marker) &
            (sleep \(marker) &)
            nohup sleep \(marker) >/dev/null 2>&1 &
            sleep 0.2
            echo "started $(ls /proc | grep -c '^[0-9]*$')"
            exit 0
            """
        let (ended, errors) = try ShimBox.shell(script, ShimBox.plan(box.path), in: box)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ended.output.hasPrefix("started "), "\(ended.output)")
        #expect(ShimBox.eventually { ShimBox.processes(holding: marker).isEmpty }, "left: \(ShimBox.processes(holding: marker))")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aKilledKeeperEndsTheNamespace() throws {
        let (root, box) = try ShimBox.scratch("shim-keeper")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "600.\(UInt32.random(in: 100_000...999_999))"
        defer { ShimBox.processes(holding: marker).forEach { kill($0, SIGKILL) } }
        let launched = try ShimBox.launch(ShimBox.plan(box.path), ["/bin/sh", "-c", "sleep \(marker) & echo ready; wait"], in: box)
        try #require(ShimBox.eventually { launched.output.contains("ready") }, "\(launched.errors)")
        // The sleep, and the shell whose command line names it.
        try #require(!ShimBox.processes(holding: marker).isEmpty)
        kill(launched.pid, SIGKILL)
        let ended = launched.ended()
        #expect(ended.signal == SIGKILL)
        #expect(ShimBox.eventually { ShimBox.processes(holding: marker).isEmpty }, "left: \(ShimBox.processes(holding: marker))")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func theProgramsExitStatusAndItsSignalComeThrough() throws {
        let (root, box) = try ShimBox.scratch("shim-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ShimBox.plan(box.path)
        #expect(try ShimBox.shell("exit 7", plan, in: box).ended.exit == 7)
        #expect(try ShimBox.shell("exit 0", plan, in: box).ended.exit == 0)
        #expect(try ShimBox.shell("kill -TERM $$", plan, in: box).ended.signal == SIGTERM)
        #expect(try ShimBox.shell("kill -KILL $$", plan, in: box).ended.signal == SIGKILL)
        // A signal to the keeper comes on to the program.
        let launched = try ShimBox.launch(plan, ["/bin/sh", "-c", "echo ready; exec sleep 600"], in: box)
        try #require(ShimBox.eventually { launched.output.contains("ready") })
        // The shell has become sleep once init's child shows it.
        try #require(ShimBox.eventually {
            ShimBox.children(of: launched.pid).flatMap { ShimBox.children(of: $0) }.contains { pid in
                ShimBox.procText("/proc/\(pid)/comm").hasPrefix("sleep")
            }
        })
        kill(launched.pid, SIGTERM)
        #expect(launched.ended().signal == SIGTERM)
    }

    @Test(.enabled(if: can, "\(skip)"))
    func theProgramHoldsNoDescriptorButItsThree() throws {
        let (root, box) = try ShimBox.scratch("shim-descriptors")
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = try SpawnTests.extraDescriptors(3)
        defer { extra.forEach { close($0) } }
        var line: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &line) == 0)
        defer { line.forEach { close($0) } }
        let plan = ShimBox.plan(box.path, door: "/run/vibeswitcher/door")
        let (ended, errors) = try ShimBox.run(plan, ["/bin/sh", "-c", "ls /proc/$$/fd"], in: box, doorLine: line[1], keep: extra)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ended.descriptors == [0, 1, 2], "\(ended.output)")
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func initIsNotDumpableAndCantBeTracedOrReadFromInside() throws {
        let (root, box) = try ShimBox.scratch("shim-init")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = """
            import ctypes, errno, os, sys
            libc = ctypes.CDLL(None, use_errno=True)
            for path in ["/proc/1/environ", "/proc/1/mem", "/proc/1/maps"]:
                try:
                    open(path, "rb").read(1); print(path, "read")
                except OSError as error:
                    print(path, errno.errorcode[error.errno])
            result = libc.ptrace(16, 1, 0, 0)
            print("ptrace", "attached" if result == 0 else errno.errorcode[ctypes.get_errno()])
            fd = libc.syscall(434, 1, 0)
            got = libc.syscall(438, fd, 0, 0) if fd >= 0 else -1
            print("pidfd_getfd", "took" if got >= 0 else errno.errorcode[ctypes.get_errno()])
            print("ready", flush=True)
            import time; time.sleep(60)
            """
        let plan = ShimBox.plan(box.path)
        let launched = try ShimBox.launch(plan, ["/usr/bin/python3", "-I", "-c", probe], in: box)
        defer {
            kill(launched.pid, SIGKILL)
            _ = launched.ended()
        }
        try #require(ShimBox.eventually { launched.output.contains("ready") }, "\(launched.errors)")
        let lines = Set(ShimBox.lines(launched.output))
        for path in ["/proc/1/environ", "/proc/1/mem", "/proc/1/maps"] {
            #expect(lines.contains("\(path) EACCES") || lines.contains("\(path) EPERM"), "\(launched.output)")
        }
        #expect(lines.contains("ptrace EPERM"), "\(launched.output)")
        #expect(lines.contains("pidfd_getfd EPERM"), "\(launched.output)")
        // From outside, by the user who owns the box's namespaces: init's environment and memory are root's alone.
        let boxInit = try #require(ShimBox.children(of: launched.pid).first)
        for entry in ["environ", "mem"] {
            let fd = open("/proc/\(boxInit)/\(entry)", O_RDONLY | O_CLOEXEC)
            let code = errno
            if fd >= 0 { close(fd) }
            #expect(fd < 0 && code == EACCES, "/proc/\(boxInit)/\(entry) opened from outside")
        }
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aPlanThatCantBeAppliedStartsNothingAndSaysWhich() throws {
        let (root, box) = try ShimBox.scratch("shim-fails")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = box.appendingPathComponent("ran").path
        let missing = root.appendingPathComponent("missing").path
        var line: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &line) == 0)
        defer { line.forEach { close($0) } }
        let base = ShimBox.plan(box.path)
        var outsideDirectory = base
        outsideDirectory.directory = missing
        var linkedTarget = base
        try FileManager.default.createSymbolicLink(atPath: box.appendingPathComponent("link").path, withDestinationPath: root.path)
        linkedTarget.mounts.append(.init(box.appendingPathComponent("link/inner").path, .empty(mode: 0o755)))
        // A mount point that is itself a link, to a folder and to a file outside.
        let secret = root.appendingPathComponent("secret")
        try Data("decoy".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(atPath: box.appendingPathComponent("folder-link").path, withDestinationPath: root.path)
        try FileManager.default.createSymbolicLink(atPath: box.appendingPathComponent("file-link").path, withDestinationPath: secret.path)
        let shown = root.appendingPathComponent("shown")
        try Data("shown".utf8).write(to: shown)
        var doorInReadOnly = base
        doorInReadOnly.door = "/usr/door"
        let cases: [(String, Platform.Sandbox.Plan, Int32?, [String], String, Int32)] = [
            ("a missing source", ShimBox.plan(box.path, extra: [.init("/gone", .readOnly(source: missing))]), nil, [],
             "mount /gone", ENOENT),
            ("a target with ..", ShimBox.plan(box.path, extra: [.init("/dev/../etc/x", .empty(mode: 0o755))]), nil, [],
             "mount /dev/../etc/x", EINVAL),
            ("a target through a link", linkedTarget, nil, [], "mount \(box.path)/link/inner", ENOTDIR),
            ("a source through a link", ShimBox.plan(box.path, extra: [.init("/linked", .readOnly(source: box.appendingPathComponent("link").path))]), nil, [],
             "mount /linked", ELOOP),
            ("a folder mount point that is a link", ShimBox.plan(box.path, extra: [.init(box.appendingPathComponent("folder-link").path, .empty(mode: 0o755))]),
             nil, [], "mount \(box.path)/folder-link", ELOOP),
            ("a file mount point that is a link", ShimBox.plan(box.path, extra: [.init(box.appendingPathComponent("file-link").path, .readOnly(source: shown.path))]),
             nil, [], "mount \(box.path)/file-link", ELOOP),
            ("a device that is a path", ShimBox.plan(box.path, extra: [.init("/dev/sda", .device("../sda"))]), nil, [], "mount /dev/sda", EINVAL),
            ("sysfs in the machine's network", ShimBox.plan(box.path, extra: [.init("/sys", .sysfs)], network: .shared), nil, [],
             "mount /sys", EPERM),
            ("a door where nothing can be written", doorInReadOnly, line[1], [], "door", EROFS),
            ("a folder that isn't there", outsideDirectory, nil, [], "directory", ENOENT),
            ("a program that isn't there", base, nil, ["/usr/bin/no-such-program-here"], "exec", ENOENT),
            ("a proxied network with no way out", ShimBox.plan(box.path, network: .proxied(port: 3128)), nil, [], "plan", EINVAL),
            ("a foreground terminal that isn't one", ShimBox.plan(box.path, terminal: .foreground), nil, [], "terminal", ENOTTY),
        ]
        for (what, plan, doorLine, program, step, code) in cases {
            let (ended, errors) = try ShimBox.run(plan, program.isEmpty ? ["/usr/bin/touch", marker] : program, in: box, doorLine: doorLine)
            #expect(ended.exit == 127, "\(what): \(ended) \(errors)")
            #expect(errors.contains("sandbox failure: \(step): \(code)"), "\(what): \(errors)")
            #expect(!FileManager.default.fileExists(atPath: marker), "\(what): the program ran")
        }
        // Nothing was mounted over the decoy the links lead to.
        #expect(String(data: try Data(contentsOf: secret), encoding: .utf8) == "decoy")
    }

    @Test(.enabled(if: can, "\(skip)"))
    func aProcessWithThreadsIsRefused() throws {
        let (root, box) = try ShimBox.scratch("shim-threads")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = box.appendingPathComponent("ran").path
        let (ended, errors) = try ShimBox.run(ShimBox.plan(box.path), ["/usr/bin/touch", marker], in: box, thread: true)
        #expect(ended.exit == 127, "\(ended)")
        #expect(errors.contains("sandbox failure: threads: \(EINVAL)"), "\(errors)")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func theDoorHandsEachConnectionToItsLine() throws {
        let (root, box) = try ShimBox.scratch("shim-door")
        defer { try? FileManager.default.removeItem(at: root) }
        var line: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &line) == 0)
        let porterEnd = line[0]
        defer { close(porterEnd) }
        // Outside: each connection taken off the line, answered, closed.
        let answered = SpawnTests.Box(0)
        let porter = Thread {
            while true {
                let connection = vibe_receive_descriptor(porterEnd)
                guard connection >= 0 else { return }
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = read(connection, &bytes, bytes.count)
                let reply = "outside got " + String(decoding: bytes.prefix(max(count, 0)), as: UTF8.self)
                _ = reply.withCString { write(connection, $0, strlen($0)) }
                close(connection)
                answered.value += 1
            }
        }
        porter.start()
        let probe = """
            import os, socket, stat
            print("door", oct(stat.S_IMODE(os.stat("/run/vibeswitcher/door").st_mode)))
            for word in ["one", "two"]:
                connection = socket.socket(socket.AF_UNIX)
                connection.connect("/run/vibeswitcher/door")
                connection.sendall(word.encode())
                print(connection.recv(100).decode())
                connection.close()
            """
        let plan = ShimBox.plan(box.path, door: "/run/vibeswitcher/door")
        let (ended, errors) = try ShimBox.run(plan, ["/usr/bin/python3", "-I", "-c", probe], in: box, doorLine: line[1])
        close(line[1])
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["door 0o700", "outside got one", "outside got two"], "\(ended.output)")
        #expect(answered.value == 2)
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func aListenerMadeInsideIsServedFromOutside() throws {
        let (root, box) = try ShimBox.scratch("shim-proxy")
        defer { try? FileManager.default.removeItem(at: root) }
        var out: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Platform.Sockets.stream, 0, &out) == 0)
        let proxyEnd = out[0]
        defer { close(proxyEnd) }
        let listener = SpawnTests.Box(Int32(-1))
        let served = Thread {
            let fd = vibe_receive_descriptor(proxyEnd)
            listener.value = fd
            guard fd >= 0 else { return }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            _ = "from outside\n".withCString { write(connection, $0, strlen($0)) }
            close(connection)
        }
        served.start()
        let probe = """
            import socket
            print(open("/proc/net/dev").read().split("\\n")[2:-1] and [line.split(":")[0].strip() for line in open("/proc/net/dev").read().split("\\n")[2:] if line])
            connection = socket.create_connection(("127.0.0.1", 3128), 5)
            print(connection.recv(100).decode().strip())
            """
        let plan = ShimBox.plan(box.path, network: .proxied(port: 3128))
        let (ended, errors) = try ShimBox.run(plan, ["/usr/bin/python3", "-I", "-c", probe], in: box, proxyOut: out[1])
        close(out[1])
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["['lo']", "from outside"], "\(ended.output)")
        // The listener the test holds is bound to 127.0.0.1:3128 of the box's network, not this one's.
        let fd = listener.value
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        #expect(named == 0 && UInt16(bigEndian: address.sin_port) == 3128 && address.sin_addr.s_addr == UInt32(0x7f00_0001).bigEndian)
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func theProgramIsItsTerminalsForegroundGroupAndTheKeeperItsLeader() throws {
        let (root, box) = try ShimBox.scratch("shim-terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        let master = vibe_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        try #require(master >= 0)
        defer { close(master) }
        var name = [CChar](repeating: 0, count: 128)
        try #require(vibe_ptsname_r(master, &name, name.count) == 0)
        let slave = String(cString: name)
        let probe = """
            import os
            print("pgrp", os.getpgrp() == os.getpid(), "foreground", os.tcgetpgrp(0) == os.getpgrp(), "sid", os.getsid(0), "isatty", os.isatty(0))
            try:
                print("ttyname", os.ttyname(0))
            except OSError as error:
                print("ttyname", error.errno)
            print("ready", flush=True)
            os.read(0, 1)
            """
        let launched = try ShimBox.launch(ShimBox.plan(box.path, terminal: .foreground), ["/usr/bin/python3", "-I", "-c", probe],
                                          in: box, terminal: slave)
        defer {
            kill(launched.pid, SIGKILL)
            _ = launched.ended()
        }
        var drawn = Data()
        let found = ShimBox.eventually {
            var chunk = [UInt8](repeating: 0, count: 4096)
            var watched = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&watched, 1, 10) > 0 {
                let count = read(master, &chunk, chunk.count)
                if count > 0 { drawn.append(contentsOf: chunk[0..<count]) }
            }
            return String(decoding: drawn, as: UTF8.self).contains("ready")
        }
        let text = String(decoding: drawn, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        try #require(found, "\(text)")
        #expect(text.contains("pgrp True foreground True sid 0 isatty True"), "\(text)")
        #expect(text.contains("ttyname \(ENODEV)"), "\(text)")
        // Outside: the keeper leads the terminal's session; the terminal's foreground group is the program's.
        let fields = { (pid: pid_t) -> [String] in
            let stat = ShimBox.procText("/proc/\(pid)/stat")
            return stat.split(separator: ")").last.map { $0.split(separator: " ").map(String.init) } ?? []
        }
        let keeper = fields(launched.pid)
        let program = try #require(ShimBox.children(of: launched.pid).flatMap { ShimBox.children(of: $0) }.first)
        // After the command: state, ppid, pgrp, session, tty_nr, tpgid.
        #expect(keeper.count > 5 && keeper[3] == String(launched.pid), "\(keeper)")
        #expect(keeper.count > 5 && keeper[5] == String(program), "\(keeper) vs \(program)")
        _ = "\n".withCString { write(master, $0, 1) }
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func aRunWithNoTerminalHasNone() throws {
        let (root, box) = try ShimBox.scratch("shim-no-terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = """
            import errno, os
            print("own session", os.getsid(0) == os.getpid())
            try:
                os.open("/dev/tty", os.O_RDWR); print("tty opened")
            except OSError as error:
                print("tty", errno.errorcode[error.errno])
            print("tty_nr", open("/proc/self/stat").read().rsplit(")", 1)[1].split()[4])
            """
        let (ended, errors) = try ShimBox.run(ShimBox.plan(box.path), ["/usr/bin/python3", "-I", "-c", probe], in: box)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["own session True", "tty ENXIO", "tty_nr 0"], "\(ended.output)")
    }

    @Test(.enabled(if: can && ShimBox.python, "\(skip), and python3"))
    func anEmptyNetworkHasLoopbackAndNothingElse() throws {
        let (root, box) = try ShimBox.scratch("shim-network")
        defer { try? FileManager.default.removeItem(at: root) }
        // A decoy listener on this network's loopback.
        let decoy = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        defer { close(decoy) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(decoy, $0, length) == 0 && getsockname(decoy, $0, &length) == 0 }
        }
        try #require(bound && listen(decoy, 4) == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let probe = """
            import errno, socket
            print([line.split(":")[0].strip() for line in open("/proc/net/dev").read().split("\\n")[2:] if line])
            try:
                socket.create_connection(("127.0.0.1", \(port)), 2); print("decoy reached")
            except OSError as error:
                print("decoy", errno.errorcode[error.errno])
            own = socket.socket(); own.bind(("127.0.0.1", 0)); own.listen(1)
            socket.create_connection(own.getsockname(), 2); print("own loopback works")
            """
        let (ended, errors) = try ShimBox.run(ShimBox.plan(box.path), ["/usr/bin/python3", "-I", "-c", probe], in: box)
        #expect(ended.exit == 0, "\(errors)")
        #expect(ShimBox.lines(ended.output) == ["['lo']", "decoy ECONNREFUSED", "own loopback works"], "\(ended.output)")
    }
}
#endif
