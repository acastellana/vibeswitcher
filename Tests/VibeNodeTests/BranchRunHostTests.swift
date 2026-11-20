import Foundation
import Testing
@testable import VibeCore

/// A branch run in its box (the session sandbox plan's SB6), end to end: the real callers (`Worktrees.rebaseAndTest`,
/// `auditRun`, their `init_command`) and the built tool server as a verifier's shell prefix, each starting the built
/// tool server as its launcher, which enters a real box.
///
/// Every box is planned over scratch folders: a scratch account home shaped like a node's (a key, a package cache, the
/// node's folder with the merges' scratch space in it), a scratch repository in it, a second worktree. What a probe
/// writes, signals or connects to is a decoy of this test's: a listener at the scratch node's host socket, a listener on
/// loopback, a `sleep` standing for a verifier's agent, a file in the scratch checkout. The machine's own fixed paths
/// are only looked at.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && RealBox.unavailable == nil,
                "needs a box: \(RealBox.unavailable ?? "the Mac has none")"), .timeLimit(.minutes(10)))
struct BranchRunHostTests {
    private let scratch = Scratch()

    /// What a probe prints, one fact a line.
    static let probe = #"""
        import os, socket, sys
        def unix(path):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(path)
                s.close()
                return "reached"
            except OSError as e:
                return "no (%s)" % e.strerror
        def tcp(port):
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(10)
            try:
                s.connect(("127.0.0.1", port))
                s.close()
                return "reached"
            except OSError as e:
                return "no (%s)" % e.strerror
        def write(path):
            try:
                with open(path, "w") as f:
                    f.write("planted\n")
                return "wrote"
            except OSError as e:
                return "no (%s)" % e.strerror
        def held(fd):
            try:
                os.fstat(fd)
                return True
            except OSError:
                return False
        def terminal():
            try:
                os.close(os.open("/dev/tty", os.O_RDWR))
                return "yes"
            except OSError as e:
                return "no (%s)" % e.strerror
        args = sys.argv[1:]
        print("hostname=" + open("/proc/sys/kernel/hostname").read().strip())
        print("door=" + ("yes" if os.path.lexists("/run/vibeswitcher/door") else "no"))
        print("env=" + ",".join(sorted(os.environ)))
        print("home=" + os.environ.get("HOME", ""))
        print("tmpdir=" + os.environ.get("TMPDIR", ""))
        print("pids=" + ",".join(sorted((n for n in os.listdir("/proc") if n.isdigit()), key=int)))
        print("fds=" + ",".join(str(fd) for fd in range(3, 64) if held(fd)))
        print("tty=" + terminal())
        print("ttynr=" + open("/proc/self/stat").read().rsplit(")", 1)[1].split()[4])
        print("looked=" + ",".join(p for p in ["/run/user/%d/bus" % os.getuid(), "/run/user/%d/systemd/private" % os.getuid(),
                                                "/run/systemd/journal/socket", "/run/WSL", "/init", "/mnt/c"] if os.path.lexists(p)))
        print("overlays=" + ",".join(sorted(l.split()[1] for l in open("/proc/mounts") if l.split()[2] == "overlay")))
        while args:
            what, value = args[0], args[1]
            args = args[2:]
            if what == "--unix": print("socket=" + unix(value))
            if what == "--port": print("network=" + tcp(int(value)))
            if what == "--write": print("write " + value + "=" + write(value))
            if what == "--exists": print("exists " + value + "=" + ("yes" if os.path.lexists(value) else "no"))
            if what == "--pid":
                try:
                    os.kill(int(value), 0)
                    print("seen=yes")
                except OSError as e:
                    print("seen=no (%s)" % e.strerror)
        sys.stdout.flush()
        """#

    /// The facts a probe printed.
    static func facts(_ output: String) -> [String: String] {
        var facts: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            facts[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return facts
    }

    /// The scratch node: an account's home, its project with a branch to test and a second worktree, the merges'
    /// scratch space in the node's folder, and the decoys.
    final class World: @unchecked Sendable {
        let base: String
        let account: String
        let root: String
        let other: String
        let area: String
        let sessionTemp: String
        let commit: String
        let hostSocket: String
        let port: UInt16
        private let listeners: [Int32]
        /// Kept, so its folders go only after this world's `deinit` took what `Scratch` can't.
        private let scratch: Scratch
        let launcher = RealBox.products + "/vibeswitcher-mcp"

        init(_ scratch: Scratch) throws {
            self.scratch = scratch
            let files = FileManager.default
            base = SandboxPolicy.resolved(try scratch.shortFolder("br").path)
            account = base + "/home"
            root = account + "/projects/app"
            other = root + "/.vibeswitcher/worktrees/other"
            area = account + "/.vibeswitcher/lead/scratch/0123456789abcdef0123"
            sessionTemp = base + "/session-tmp"
            for folder in [account + "/.ssh", account + "/.cache/org.swift.swiftpm", root, area, sessionTemp] {
                try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try "a key\n".write(toFile: account + "/.ssh/id_ed25519", atomically: true, encoding: .utf8)
            try "cached\n".write(toFile: account + "/.cache/org.swift.swiftpm/manifest", atomically: true, encoding: .utf8)
            hostSocket = account + "/.vibeswitcher/host.sock"
            let host = try UnixSocket.listen(path: hostSocket)
            let loopback = try Platform.TCP.listenOnLoopback().get()
            port = loopback.port
            listeners = [host, loopback.fd]

            func git(_ arguments: [String], in folder: String) throws {
                let ran = Git.run(arguments, in: folder)
                guard ran.ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments): \(ran.error)"]) }
            }
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
                try git(arguments, in: root)
            }
            try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
            try git(["add", "a.txt"], in: root)
            try git(["commit", "-q", "-m", "first"], in: root)
            try git(["checkout", "-q", "-b", "agent/add-b"], in: root)
            let lines = BranchRunHostTests.probe.split(separator: "\n", omittingEmptySubsequences: false)
            let indent = lines.first.map { $0.prefix { $0 == " " }.count } ?? 0
            try lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
                .write(toFile: root + "/probe.py", atomically: true, encoding: .utf8)
            try files.copyItem(atPath: packageFolder.appendingPathComponent("Resources/bin/vs-heavy").path, toPath: root + "/vs-heavy")
            try git(["add", "probe.py", "vs-heavy"], in: root)
            try git(["commit", "-q", "-m", "add b"], in: root)
            commit = Git.run(["rev-parse", "HEAD"], in: root).output
            try git(["checkout", "-q", "main"], in: root)
            try git(["worktree", "add", "-q", "-b", "agent/other", other, "main"], in: root)
        }

        /// The last run's layers stay beside its home for the next run to take (`BranchRun.sweep`), and a layer's work
        /// folder is the kernel's, mode 000: no next run comes here, so the world takes them, or its `Scratch` couldn't
        /// remove the folder and the run would leave it in its TMPDIR. Before the `Scratch` removes it, whichever is
        /// let go of last: a run's thread can hold this world a moment longer than its test does (under load the
        /// `Scratch` went first, 3 runs in 50, and the folder stayed), so the world holds its `Scratch`.
        deinit {
            listeners.forEach { Sys.close($0) }
            BranchRun.sweep(area + "/" + BranchRun.runsFolder)
        }

        /// This process told its launcher: the built tool server, planning over the scratch account.
        var scope: BranchRun.Scope { BranchRun.Scope(launcher: launcher, accountHome: account) }

        /// The probe's command line, with what it should try.
        func probe(_ tries: [(String, String)] = []) -> String {
            (["python3", "-I", "probe.py", "--unix", hostSocket, "--port", String(port)] + tries.flatMap { [$0.0, $0.1] })
                .map(FakeClaude.quoted).joined(separator: " ")
        }

        /// A merge's test of the branch, as the lead's tool server runs one: in a scratch worktree and home in the
        /// node's folder. `boxed`: with the launcher told; else as a process that has none runs it, under the wrapper.
        func merge(_ name: String, setup: String? = nil, test: String?, boxed: Bool, scope given: BranchRun.Scope? = nil,
                   timeout: TimeInterval = 300, lock: TestLock? = nil) async -> (check: Worktrees.Check, output: String) {
            let scope = boxed ? (given ?? self.scope) : nil
            let place = URL(fileURLWithPath: area + "/merge-" + name)
            return await offPool { [root, commit] in
                var passing = ""
                let check = BranchRun.with(scope) {
                    Worktrees.rebaseAndTest(root: root, commit: commit, onto: "main", setup: setup, test: test, scratch: place,
                                            timeout: timeout, lock: lock, tested: { passing = $0 })
                }
                switch check {
                case .failed(let output), .hung(_, _, let output, _): return (check, output)
                default: return (check, passing)
                }
            }
        }

        /// The verifier's audit checkout: a worktree of the project at the branch's commit.
        func checkout(_ name: String) throws -> String {
            let path = root + "/.vibeswitcher/worktrees/" + name
            let added = Git.run(["worktree", "add", "-q", "--detach", path, commit], in: root)
            guard added.ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: added.error]) }
            return path
        }

        /// A verifier's command, as its Claude Code starts one: the built tool server as the shell prefix
        /// (`BranchCode.prefixEnvironment`), given the command line as one argument, in the verifier's checkout, with
        /// the verifier's environment (the account's home, its session's TMPDIR). Its pid; its output goes to
        /// `<checkout>.out` and `<checkout>.err`.
        func startPrefix(_ command: String, in checkout: String, extra: [String: String] = [:], keep: [Int32] = [],
                         terminal: String? = nil) throws -> pid_t {
            var environment = ProcessInfo.processInfo.environment
            for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "CLAUDE_CODE_SHELL"] { environment[key] = nil }
            environment.merge(["HOME": account, "CFFIXED_USER_HOME": account, "VIBESWITCHER_HOME": account + "/.vibeswitcher",
                               "TMPDIR": sessionTemp + "/", "SHELL": "/bin/bash", BranchCode.prefixVariable: "1"]) { $1 }
            environment.merge(extra) { $1 }
            var spawn = Platform.Spawn(executable: launcher, arguments: [launcher, command])
            spawn.environment = environment.map { "\($0.key)=\($0.value)" }
            spawn.directory = checkout
            spawn.keep = keep
            if let terminal {
                // A session of its own whose terminal this is, as an agent's Bash tool's shell could be given one.
                spawn.group = .ownSession
                spawn.stdin = .path(terminal, flags: O_RDWR)
            } else {
                spawn.group = .ownGroup
                spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            }
            spawn.stdout = .path(checkout + ".out", flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
            spawn.stderr = .path(checkout + ".err", flags: O_WRONLY | O_CREAT | O_TRUNC, mode: 0o600)
            return try spawn.start().get()
        }

        /// A verifier's command run to its end: its wait status, and what it wrote.
        func prefix(_ command: String, in checkout: String, extra: [String: String] = [:], keep: [Int32] = [],
                    terminal: String? = nil) async throws -> (raw: Int32?, output: String, errors: String) {
            let pid = try startPrefix(command, in: checkout, extra: extra, keep: keep, terminal: terminal)
            let raw = await offPool { collected(pid, by: MacTime.real.awake() + 120) }
            return (raw, text(checkout + ".out"), text(checkout + ".err"))
        }

        func text(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

        /// The processes whose arguments hold `marker`, as the machine numbers them.
        func processes(_ marker: String) -> [pid_t] {
            (ProcessTable.allPids() ?? []).filter { pid in ProcessTable.commandLine(pid: pid).contains { $0.contains(marker) } }
        }
    }

    static func exit(_ raw: Int32?) -> Int32? { raw.flatMap { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : nil } }

    static func passed(_ check: Worktrees.Check) -> Bool {
        if case .passed = check { return true }
        return false
    }

    @Test func aMergesTestsRunWithNoDoorNoHostSocketAndNoNetwork() async throws {
        let world = try World(scratch)
        // Under the wrapper alone the probe reaches both decoys: it proves something.
        let plain = await world.merge("plain", test: world.probe(), boxed: false)
        let open = Self.facts(plain.output)
        #expect(Self.passed(plain.check), "\(plain)")
        #expect(open["socket"] == "reached" && open["network"] == "reached", "\(plain.output)")

        let boxed = await world.merge("boxed", test: world.probe(), boxed: true)
        #expect(Self.passed(boxed.check), "\(boxed)")
        let facts = Self.facts(boxed.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(boxed.output)")
        // No door, by path or by name.
        #expect(facts["door"] == "no")
        let names = Set((facts["env"] ?? "").split(separator: ",").map(String.init))
        #expect(names.isDisjoint(with: [DoorProtocol.variable, DoorProtocol.connectorVariable, DoorProtocol.hostSocketVariable]))
        // No host socket: the node's folder isn't there.
        #expect(facts["socket"]?.hasPrefix("no") == true, "\(boxed.output)")
        // No network: the listener on the machine's loopback isn't on the box's.
        #expect(facts["network"]?.hasPrefix("no") == true, "\(boxed.output)")
        // The user's manager, bus and journal, and the Windows side, looked at only: none is there.
        #expect(facts["looked"] == "", "\(boxed.output)")
        // The run's home and TMPDIR are its scratch ones.
        #expect(facts["home"] == world.area + "/merge-boxed-home" && facts["tmpdir"] == world.area + "/merge-boxed-home/tmp")
    }

    @Test func anAuditsRunCantWriteTheCheckoutOrAnotherWorktree() async throws {
        let world = try World(scratch)
        let targets = [world.root + "/planted", world.root + "/.git/hooks/planted", world.root + "/.git/config.planted",
                       world.other + "/planted", world.root + "/.vibeswitcher/planted"]
        func audit(_ name: String, boxed: Bool) async -> (run: Worktrees.AuditRun, log: String) {
            let logs = URL(fileURLWithPath: world.area + "/audit-\(name)-logs")
            let test = world.probe(targets.map { ("--write", $0) } + [("--write", "its-own")])
            let run = await offPool {
                BranchRun.with(boxed ? world.scope : nil) {
                    Worktrees.auditRun(root: world.root, commit: world.commit, setup: nil, test: test,
                                       scratch: URL(fileURLWithPath: world.area + "/audit-" + name),
                                       home: URL(fileURLWithPath: world.area + "/audit-\(name)-home"), logs: logs, lock: nil)
                }
            }
            return (run, world.text(logs.appendingPathComponent("test.log").path))
        }
        // Under the wrapper alone every one of them is written.
        let plain = await audit("plain", boxed: false)
        #expect(plain.run.outcome == .passed, "\(plain)")
        for target in targets {
            #expect(FileManager.default.fileExists(atPath: target), "the probe didn't write \(target): \(plain.log)")
            try? FileManager.default.removeItem(atPath: target)
        }

        let boxed = await audit("boxed", boxed: true)
        #expect(boxed.run.outcome == .passed, "\(boxed)")
        let facts = Self.facts(boxed.log)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(boxed.log)")
        // None was written. The repository's git folder is there read-only and says so; the other worktree and the
        // checkout's own folder aren't there. (The checkout's top folder exists inside only as the path to its git
        // folder, in the box's own memory: here that is the box's /tmp, since this scratch project is under /tmp, so
        // a file can be made there, and goes with the box.)
        for target in targets {
            #expect(!FileManager.default.fileExists(atPath: target), "an audit's run wrote \(target)")
        }
        for target in targets.dropFirst() {
            #expect(facts["write " + target]?.hasPrefix("no") == true, "\(target): \(boxed.log)")
        }
        #expect(facts["write " + targets[1]]?.contains("Read-only") == true, "\(boxed.log)")
        // Its own scratch worktree is its to write.
        #expect(facts["write its-own"] == "wrote", "\(boxed.log)")
    }

    @Test func initCommandsWritesStayInItsScratchWorktreeAndHome() async throws {
        let world = try World(scratch)
        let home = world.area + "/merge-init-home"
        // Every write is aimed at a scratch folder of this test's: its account, the merges' scratch space, its base.
        let outside = [world.account + "/planted", world.account + "/.ssh/planted", world.area + "/beside", world.base + "/planted",
                       world.sessionTemp + "/planted"]
        let setup = world.probe([("--write", home + "/in-home"), ("--write", "in-worktree"),
                                 ("--write", home + "/.cache/org.swift.swiftpm/in-cache")]
                                + outside.map { ("--write", $0) })
        // The test command, in a box of its own after init_command's: what that wrote in the worktree and the home is
        // there (the real folders), what it wrote in the package cache went with its box, and a scratch folder
        // nobody named isn't there.
        let test = world.probe([("--exists", home + "/in-home"), ("--exists", "in-worktree"), ("--exists", world.sessionTemp),
                                ("--exists", home + "/.cache/org.swift.swiftpm/in-cache"),
                                ("--exists", home + "/.cache/org.swift.swiftpm/manifest"),
                                ("--exists", world.account + "/.ssh/id_ed25519")])
        let run = await world.merge("init", setup: setup, test: test, boxed: true)
        #expect(Self.passed(run.check), "\(run)")
        let facts = Self.facts(run.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(run.output)")
        #expect(facts["exists \(home)/in-home"] == "yes" && facts["exists in-worktree"] == "yes", "\(run.output)")
        #expect(facts["exists \(world.sessionTemp)"] == "no" && facts["exists \(home)/.cache/org.swift.swiftpm/in-cache"] == "no",
                "\(run.output)")
        // The cache is read through a layer of the run's own, where its tools look for it: under the run's home, its
        // HOME (a fresh build folder resolves its packages from it, with no network); the key isn't there at all.
        #expect(facts["exists \(home)/.cache/org.swift.swiftpm/manifest"] == "yes")
        #expect((facts["overlays"] ?? "").split(separator: ",").contains(Substring(home + "/.cache/org.swift.swiftpm")), "\(run.output)")
        #expect(facts["exists \(world.account)/.ssh/id_ed25519"] == "no")
        // Nothing outside its worktree and home was written, the real cache included.
        for path in outside + [world.account + "/.cache/org.swift.swiftpm/in-cache"] {
            #expect(!FileManager.default.fileExists(atPath: path), "init_command wrote \(path)")
        }
        // The caller could remove the worktree and the home when the run was over (a layer's work folder isn't in
        // them), and of the runs' layers at most the last one's is left, for the next run beside it to take.
        #expect(!FileManager.default.fileExists(atPath: home) && !FileManager.default.fileExists(atPath: world.area + "/merge-init"))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: world.area + "/.branch-runs")) ?? []
        #expect(left.count <= 1, "\(left)")
    }

    @Test func aVerifiersCommandCantSeeTheVerifiersProcesses() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-a")
        // What stands for the verifier's agent: a process of this test's.
        var agent = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "600"])
        agent.stdin = .path("/dev/null", flags: O_RDONLY)
        agent.stdout = .path("/dev/null", flags: O_WRONLY)
        agent.stderr = .path("/dev/null", flags: O_WRONLY)
        let decoy = try agent.start().get()
        defer {
            Sys.kill(decoy, SIGKILL)
            _ = collected(decoy, by: MacTime.real.awake() + 10)
        }
        // Under the wrapper alone it is seen.
        let plain = await offPool {
            Shell.run(executable: "/usr/bin/python3", args: ["-I", "probe.py", "--pid", String(decoy)], in: checkout, timeout: 120, branchCode: true)
        }
        #expect(Self.facts(plain.output)["seen"] == "yes", "\(plain.output) \(plain.error)")

        let run = try await world.prefix(world.probe([("--pid", String(decoy))]), in: checkout)
        #expect(Self.exit(run.raw) == 0, "\(run)")
        let facts = Self.facts(run.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(run)")
        #expect(facts["seen"]?.hasPrefix("no") == true, "\(run.output)")
        // Its own processes only, numbered from its box's init: neither the decoy nor this test is among them.
        let pids = (facts["pids"] ?? "").split(separator: ",").compactMap { Int32($0) }
        #expect(pids.first == 1 && pids.count <= 8 && !pids.contains(decoy) && !pids.contains(getpid()), "\(pids)")
        // Its home is a folder of the run's own in the verifier's TMPDIR, never the account's.
        #expect(facts["home"] == world.sessionTemp + "/branch-run-home", "\(run.output)")
        // Its package cache came through a layer of the run's own, in the session's TMPDIR, and the prefix took that
        // layer away when the command ended: the session's TMPDIR can be removed whole when the session is.
        #expect((facts["overlays"] ?? "").split(separator: ",").contains(Substring(world.sessionTemp + "/branch-run-home/.cache/org.swift.swiftpm")), "\(run.output)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: world.sessionTemp + "/.branch-runs")) ?? []).isEmpty)
        #expect(throws: Never.self) { try FileManager.default.removeItem(atPath: world.sessionTemp) }
    }

    /// What a verifier's session carries its project's settings in (`BranchRun.policyVariable`), spelled out so this
    /// compiles without it, and `policy` as it carries them.
    static let policyVariable = "VIBESWITCHER_BRANCH_RUN_POLICY"
    static func carrying(_ policy: SandboxPolicy) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "{\"policy\":" + String(decoding: try encoder.encode(policy), as: UTF8.self) + "}"
    }

    /// The project's settings a verifier was started with (`LeadLaunch.prepare`'s, read as the user accepted them):
    /// its shell prefix boxes each of its commands by them, and a refusal among them starts nothing.
    @Test func aVerifiersCommandIsBoxedByTheSettingsItWasStartedWith() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-p")
        let shared = world.account + "/shared"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try "shared secret\n".write(toFile: shared + "/notes.txt", atomically: true, encoding: .utf8)
        let command = "cat " + FakeClaude.quoted(shared + "/notes.txt")
        // Started with none (a verifier started before this build): the standard box, which doesn't show it.
        let standard = try await world.prefix(command, in: checkout)
        #expect(Self.exit(standard.raw) != 0 && !standard.output.contains("shared secret"), "\(standard)")
        let carried = try await world.prefix(command, in: checkout, extra: [Self.policyVariable: try Self.carrying(SandboxPolicy(read: [shared]))])
        #expect(Self.exit(carried.raw) == 0 && carried.output.contains("shared secret"), "\(carried)")
        // Settings refused when it was started, or that can't be read: nothing runs, saying why.
        let refusal = #"{"refusal":{"key":"sandbox_read","reason":"is, holds or is under ~/.ssh, which no box shows","value":"~/.ssh"}}"#
        for (given, said) in [(refusal, "sandbox_read"), ("not json", Self.policyVariable)] {
            let refused = try await world.prefix("touch ran.txt", in: checkout, extra: [Self.policyVariable: given])
            #expect(Self.exit(refused.raw) == 126 && refused.errors.contains("wasn't started") && refused.errors.contains(said), "\(refused)")
            #expect(!FileManager.default.fileExists(atPath: checkout + "/ran.txt"))
        }
    }

    /// Nothing a verifier's command does inside its box widens it: the settings live in the verifier's environment and
    /// settings file, outside the box, and a prefix the command starts itself with wider ones can show no more than the
    /// box it is in.
    @Test func aCommandInsideCantWidenTheSettingsItsPrefixWasGiven() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-w")
        let shared = world.account + "/shared"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try "shared secret\n".write(toFile: shared + "/notes.txt", atomically: true, encoding: .utf8)
        let wider = try Self.carrying(SandboxPolicy(read: [shared]))
        let inner = ["env", "\(Self.policyVariable)=\(wider)", "\(BranchCode.prefixVariable)=1", world.launcher, "cat " + FakeClaude.quoted(shared + "/notes.txt")]
        let command = "cat \(FakeClaude.quoted(shared + "/notes.txt")); export \(Self.policyVariable)=\(FakeClaude.quoted(wider)); "
            + inner.map(FakeClaude.quoted).joined(separator: " ") + "; echo done"
        let run = try await world.prefix(command, in: checkout)
        #expect(run.output.contains("done") && !run.output.contains("shared secret") && !run.errors.contains("shared secret"), "\(run)")
    }

    @Test func aVerifiersCommandHasNoTerminal() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-t")
        let terminal = try Platform.Terminals.open(rows: 24, cols: 80).get()
        defer { [terminal.master, terminal.slave].forEach { Sys.close($0) } }
        // The prefix leads a session whose terminal is the pty, its stdin: the most a verifier's command could inherit.
        let run = try await world.prefix(world.probe(), in: checkout, terminal: terminal.devicePath)
        #expect(Self.exit(run.raw) == 0, "\(run)")
        let facts = Self.facts(run.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(run)")
        #expect(facts["tty"]?.hasPrefix("no") == true, "\(run.output)")
        #expect(facts["ttynr"] == "0", "\(run.output)")
    }

    @Test func branchCodeHasNoConnector() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-c")
        // What stands for a session's connector: a socket the command's starter holds open across its exec, named in
        // its environment, as a helper's is before it takes it.
        guard let pair = Platform.Sockets.pair(type: Platform.Sockets.stream) else { throw Platform.Errno(code: errno) }
        defer { [pair.0, pair.1].forEach { Sys.close($0) } }
        let run = try await world.prefix(world.probe(), in: checkout, extra: ["DECOY_CONNECTOR": String(pair.1), "DECOY_SECRET": "x"],
                                         keep: [pair.1])
        #expect(Self.exit(run.raw) == 0, "\(run)")
        let facts = Self.facts(run.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(run)")
        // Descriptors 0, 1 and 2 and nothing else.
        #expect(facts["fds"] == "", "\(run.output)")
        // No name of a connector, a door or a host socket, nor anything else nobody listed.
        let names = Set((facts["env"] ?? "").split(separator: ",").map(String.init))
        #expect(names.isDisjoint(with: ["DECOY_CONNECTOR", "DECOY_SECRET", DoorProtocol.variable, DoorProtocol.connectorVariable,
                                        DoorProtocol.hostSocketVariable, BranchCode.prefixVariable, "VIBESWITCHER_HOME"]), "\(names)")
        #expect(facts["door"] == "no" && facts["socket"]?.hasPrefix("no") == true, "\(run.output)")
    }

    @Test func theRunsExitStatusOutputAndTimeoutAreItsCommands() async throws {
        let world = try World(scratch)
        // A merge's test command that fails: its output, both streams, and its failure.
        let failing = await world.merge("fails", test: world.probe() + "; echo to-out; echo to-err >&2; exit 7", boxed: true)
        guard case .failed(let output) = failing.check else { Issue.record("\(failing)"); return }
        #expect(output.contains("to-out") && output.contains("to-err") && Self.facts(output)["hostname"] == SandboxPlanner.hostname, "\(output)")

        // A verifier's command: its own status, and its two streams apart.
        let checkout = try world.checkout("audit-s")
        let seven = try await world.prefix("echo to-out; echo to-err >&2; cat /proc/sys/kernel/hostname; exit 7", in: checkout)
        #expect(Self.exit(seven.raw) == 7, "\(seven)")
        #expect(seven.output == "to-out\n\(SandboxPlanner.hostname)\n" && seven.errors == "to-err\n", "\(seven)")
        // One a signal ended is the shell's 128 and its number, as under the wrapper alone.
        let signalled = try await world.prefix("cat /proc/sys/kernel/hostname; kill -TERM $$", in: checkout)
        #expect(Self.exit(signalled.raw) == 128 + SIGTERM && signalled.output == SandboxPlanner.hostname + "\n", "\(signalled)")

        // A run past its time is stopped as hung, with what it wrote, and nothing of it is left: not even what left
        // its process group and ignores the stop. The run's clock is this test's: it passes the limit once the stray
        // is up (its file, in the worktree), never before.
        let marker = "branch-run-stray-\(UUID().uuidString.prefix(8))"
        let stray = "import signal, time\nfor s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(s, signal.SIG_IGN)\n"
            + "open('stray-ready', 'w').close()\ntime.sleep(3600)\n"
        let script = world.probe() + "; setsid nohup python3 -I -c \(FakeClaude.quoted(stray)) \(marker) > /dev/null 2>&1 & "
            + "while [ ! -f stray-ready ]; do sleep 0.05; done; sleep 3600"
        defer { world.processes(marker).forEach { Sys.kill($0, SIGKILL) } }
        let place = world.area + "/merge-hangs"
        #expect(Git.run(["worktree", "add", "-q", "--detach", place, world.commit], in: world.root).ok)
        let leaping = MacTime(wall: Date.init, awake: {
            MacTime.real.awake() + (FileManager.default.fileExists(atPath: place + "/stray-ready") ? 100_000 : 0)
        })
        let hung = await offPool {
            BranchRun.with(world.scope) {
                Worktrees.runChecks(setup: nil, test: script, in: place, home: place + "-home", timeout: 3_600, time: leaping)
            }
        }
        guard case .hung(let command, let after, let said, _)? = hung.stopped else { Issue.record("\(hung)"); return }
        #expect(command == "test command" && after == 3_600)
        #expect(Self.facts(said)["hostname"] == SandboxPlanner.hostname, "\(said)")
        #expect(await eventually(timeout: 60) { world.processes(marker).isEmpty }, "left running: \(world.processes(marker))")

        // A run whose box can't be planned fails, saying so first, and runs nothing: never the command under the
        // wrapper alone. (Here the scratch worktree is the account's whole home, which no box shows.)
        let refused = await world.merge("refused", test: "echo it-ran; touch \(FakeClaude.quoted(world.area + "/it-ran"))", boxed: true,
                                        scope: BranchRun.Scope(launcher: world.launcher, accountHome: world.area + "/merge-refused"))
        guard case .failed(let why) = refused.check else { Issue.record("\(refused)"); return }
        #expect(why.contains("branch run") && why.contains("box") && !why.contains("it-ran"), "\(why)")
        #expect(why.contains("vibeswitcher: this branch run wasn't started"), "\(why)")
        #expect(!FileManager.default.fileExists(atPath: world.area + "/it-ran"))
    }

    @Test func anInterruptEndsEveryProcessOfARun() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("audit-i")
        let marker = "branch-run-stray-\(UUID().uuidString.prefix(8))"
        // The command starts something that leaves its session and its process group and ignores every signal a stop
        // sends, then waits: what a double fork under the wrapper alone leaves running for good.
        let stray = "import signal, time\nfor s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(s, signal.SIG_IGN)\n"
            + "open('stray-ready', 'w').close()\ntime.sleep(3600)\n"
        let command = "cat /proc/sys/kernel/hostname; setsid nohup python3 -I -c \(FakeClaude.quoted(stray)) \(marker) > /dev/null 2>&1 & "
            + "while [ ! -f stray-ready ]; do sleep 0.05; done; echo started; sleep 3600"
        defer { world.processes(marker).forEach { Sys.kill($0, SIGKILL) } }
        // First, with no interrupt at all: a command that starts the same thing and returns leaves nothing behind
        // either (under the wrapper alone, that one runs on, in a session of its own, no session's to end).
        let returned = try await world.prefix("setsid nohup python3 -I -c \(FakeClaude.quoted(stray)) \(marker) > /dev/null 2>&1 & "
            + "while [ ! -f stray-ready ]; do sleep 0.05; done; rm stray-ready; cat /proc/sys/kernel/hostname", in: checkout)
        #expect(Self.exit(returned.raw) == 0 && returned.output == SandboxPlanner.hostname + "\n", "\(returned)")
        #expect(await eventually(timeout: 60) { world.processes(marker).isEmpty }, "left running: \(world.processes(marker))")

        let pid = try world.startPrefix(command, in: checkout)
        var collectedAlready = false
        defer { if !collectedAlready { Sys.kill(pid, SIGKILL); _ = collected(pid, by: MacTime.real.awake() + 10) } }
        // The stray is up (its file, in the checkout), and the command said so.
        #expect(await eventually(timeout: 120) { FileManager.default.fileExists(atPath: checkout + "/stray-ready") && world.text(checkout + ".out").contains("started") },
                "\(world.text(checkout + ".out")) \(world.text(checkout + ".err"))")
        #expect(world.text(checkout + ".out").hasPrefix(SandboxPlanner.hostname + "\n"), "the command didn't run in a box")
        let running = world.processes(marker)
        #expect(running.count >= 2, "\(running)")

        // The interrupt, as the prefix gets it.
        Sys.kill(pid, SIGINT)
        let raw = await offPool { collected(pid, by: MacTime.real.awake() + 60) }
        collectedAlready = true
        #expect(raw != nil && Self.exit(raw) != 0, "\(String(describing: raw))")
        #expect(await eventually(timeout: 60) { world.processes(marker).isEmpty }, "left running: \(world.processes(marker))")
    }

    @Test func aScriptInsideARunSeesTheSlotItsRunHolds() async throws {
        let world = try World(scratch)
        let slots = world.area + "/slots"
        try FileManager.default.createDirectory(atPath: slots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = TestLock(directory: slots, slots: 1)
        // The test command, through its login shell: it is told the slot its run holds and its width, and a script of
        // the branch's that takes a slot itself (`vs-heavy`) runs at once under it, rather than wait for a slot held
        // outside, which it can't see.
        let test = world.probe([("--exists", slots)]) + "; echo slot=$\(TestLock.heldVariable); echo cores=$\(TestLock.coresVariable); "
            + "\(TestLock.directoryVariable)=\(FakeClaude.quoted(slots)) bash ./vs-heavy --as probe echo ran-under-the-slot"
        let run = await world.merge("slot", test: test, boxed: true, lock: lock)
        #expect(Self.passed(run.check), "\(run)")
        let facts = Self.facts(run.output)
        #expect(facts["hostname"] == SandboxPlanner.hostname, "\(run.output)")
        #expect(facts["slot"] == slots + "/test-build.lock", "\(run.output)")
        #expect(facts["cores"] == String(TestLock.coreBudget(slots: 1)), "\(run.output)")
        #expect(facts["exists " + slots] == "no", "\(run.output)")
        #expect(run.output.contains("ran-under-the-slot"), "\(run.output)")
    }

    /// What an ended run left in its layers is the next launcher's to take before it enters. A tree thousands of
    /// folders deep (a run can make one, through its cache's layer) goes through a few descriptors: the launcher, held
    /// here to 64, takes it all and starts its run.
    @Test func aRunStartsBesideALayerTreeTooDeepToWalk() async throws {
        let world = try World(scratch)
        let checkout = try world.checkout("deep")
        let home = world.sessionTemp + "/" + BranchRun.verifierHome
        // A run whose launcher is gone: no process has this number.
        let left = world.sessionTemp + "/" + BranchRun.runsFolder + "/\(Int32.max)-left"
        try FileManager.default.createDirectory(atPath: left + "/layers/0/upper", withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var fd = open(left + "/layers/0/upper", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        for _ in 0..<5000 {
            try #require(mkdirat(fd, "d", 0o700) == 0)
            let next = openat(fd, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Sys.close(fd)
            fd = next
            try #require(fd >= 0)
        }
        Sys.close(fd)

        let launcher = BranchRun.command(BranchCode.wrapper + ["/bin/sh", "-c", "echo ran"], cwd: checkout, home: home, policy: .standard,
                                         server: world.launcher, facts: Platform.Sandbox.probe(), accountHome: world.account, onTheMac: false)
        #expect(launcher.executable == world.launcher)
        let run = await offPool {
            Shell.run(executable: "/bin/sh", args: ["-c", "ulimit -n 64 && exec \"$@\"", "sh"] + launcher.arguments, in: checkout, timeout: 120)
        }
        let swept = !FileManager.default.fileExists(atPath: left)
        // This run's own layers, as whoever started a launcher takes them when it has ended.
        BranchRun.sweep(after: launcher.arguments)
        #expect(run.ok && run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ran", "\(run.status) \(run.output) \(run.error)")
        #expect(swept, "the tree an ended run left was still there when its launcher's run had ended")
    }
}
