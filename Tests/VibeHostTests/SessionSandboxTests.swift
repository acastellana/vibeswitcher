import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Boxes for the session host's tests: a plan over a scratch folder, and what a test sees of a box from outside.
/// Nothing here confines the test process: every box is entered by a session's launcher (`vibeswitcher-host
/// --pty-exec`), a child.
enum SessionBox {
    /// Why no box can be built here; nil when one can (`Platform.Sandbox.probe()`: never on the Mac, nor where the
    /// kernel refuses an unprivileged user namespace, as GitHub's hosted runner does).
    static let unavailable: String? = Platform.Sandbox.probe().why
    static let can = unavailable == nil
    static let skip = "needs a box: \(unavailable ?? "")"

    /// How a test run both ways starts its session, as its `confined` argument: plain, and in a box where one can be
    /// built. Where none can (the Mac; a kernel that refuses), the confined case isn't made: `SessionSandboxTests`
    /// says why there.
    static let kinds: [Bool] = can ? [false, true] : [false]

    /// The name a box of these tests gives its machine: what its program prints for `hostname`.
    static let hostname = "vsbox"

    /// A new folder of `scratch`, made, its path with every link followed (a plan's source may have none along it).
    static func folder(_ scratch: Scratch) throws -> String {
        let url = scratch.url("box")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    /// A plan whose only folder of the test's is `folder`, read-write, where the program starts: `/usr` and `/etc`
    /// read-only with the usual links, the box's own `/proc` and `/dev`, no network but loopback, and the session's
    /// terminal as the program's. (No temporary folder inside: these programs need none.)
    static func plan(_ folder: String, extra: [Platform.Sandbox.Mount] = []) -> Platform.Sandbox.Plan {
        var mounts: [Platform.Sandbox.Mount] = [
            .init("/usr", .readOnly(source: "/usr")),
            .init("/etc", .readOnly(source: "/etc")),
            .init("/bin", .link(to: "usr/bin")), .init("/lib", .link(to: "usr/lib")),
            .init("/lib64", .link(to: "usr/lib64")), .init("/sbin", .link(to: "usr/sbin")),
            .init("/proc", .proc),
            .init("/dev", .empty(mode: 0o755)),
        ]
        mounts += ["null", "zero", "full", "random", "urandom", "tty"].map { .init("/dev/\($0)", .device($0)) }
        mounts += [.init("/dev/pts", .devpts), .init("/dev/ptmx", .link(to: "pts/ptmx"))]
        mounts.append(.init(folder, .readWrite(source: folder)))
        return Platform.Sandbox.Plan(mounts: mounts + extra, network: .none, hostname: hostname, directory: folder,
                                     environment: ["PATH=/usr/bin:/bin", "HOME=\(folder)", "LANG=C.UTF-8", "TERM=xterm-256color"],
                                     door: nil, terminal: .foreground, nesting: false)
    }

    static func launch(_ folder: String, extra: [Platform.Sandbox.Mount] = []) -> SessionSandbox.Launch {
        SessionSandbox.Launch(plan: plan(folder, extra: extra))
    }

    /// A `/bin/sh` session running `command` in `folder`, in `sandbox`'s box or, with none, plain.
    static func start(_ command: String, in folder: String, sandbox: SessionSandbox.Launch?, launcher: String = hostLauncher,
                      probe: SessionProbe) throws -> HostedSession {
        let request = SpawnRequest(cwd: folder, command: command, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: launcher, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                                  ringCapacity: 1 << 20, queue: probe.queue, sandbox: sandbox)
            probe.attach(session)
            return session
        }
    }

    // MARK: A box seen from outside

    // A pid a boxed program prints is the box's own numbering: a test never signals or looks up one. It finds a
    // process of a box as the host does, by the machine's numbers: under the session's program (the keeper).

    /// Every process under `pid` that runs now, its children's children too.
    static func under(_ pid: pid_t) -> [pid_t] {
        var found: [pid_t] = [], next = [pid], seen: Set<pid_t> = [pid]
        while let parent = next.popLast() {
            for child in Platform.Processes.children(parent) where seen.insert(child).inserted {
                found.append(child)
                next.append(child)
            }
        }
        return found
    }

    /// The process whose first argument is `marker` (a scratch program started with `exec -a`), wherever it is.
    static func process(named marker: String) -> pid_t? {
        Platform.Processes.allPids()?.first { Platform.Processes.arguments($0).first == marker }
    }

    /// When `pid` started: with its number, which process it is.
    static func start(of pid: pid_t) -> UInt64? { Platform.Processes.link(pid)?.startTicks }

    /// Whether the process that was `pid`, started at `ticks`, is still there (a pid given again is another).
    static func runs(_ pid: pid_t, startedAt ticks: UInt64) -> Bool { start(of: pid) == ticks }

    /// The pid namespace `pid` is in, as /proc names it ("pid:[4026531836]"); nil when it can't be read.
    static func pidNamespace(_ pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/ns/pid")
    }

    /// `pid`'s numbers in each pid namespace it is in, outermost first (/proc's `NSpid`): one for a process outside
    /// every box, two for one inside a box.
    static func numbers(_ pid: pid_t) -> [pid_t] {
        guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) else { return [] }
        for line in status.split(separator: "\n") where line.hasPrefix("NSpid:") {
            return line.dropFirst("NSpid:".count).split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { pid_t($0) }
        }
        return []
    }

    /// A number /proc gives of `pid` in the file `name`; nil when it can't be read.
    static func number(_ name: String, of pid: pid_t) -> Int? {
        (try? String(contentsOfFile: "/proc/\(pid)/\(name)", encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether `keeper`, a session's program as the host knows it, keeps a box: its child is pid 1 of a pid namespace
    /// inside this one.
    static func keepsABox(_ keeper: pid_t) -> Bool {
        Platform.Processes.children(keeper).first.map { numbers($0) == [$0, 1] } == true
    }

    /// A confined session's box, once its program runs: its keeper (the session's program as the host knows it), its
    /// init (the keeper's only child) and its program (init's first child).
    static func processes(of session: HostedSession, probe: SessionProbe) async -> (keeper: pid_t, initial: pid_t, program: pid_t)? {
        let keeper = probe.queue.sync { session.info.childPID }
        var found: (pid_t, pid_t, pid_t)?
        // Its program has said something by now, so the three are there: a short wait is enough.
        _ = await eventually(timeout: 30) {
            guard let initial = Platform.Processes.children(keeper).first, let program = Platform.Processes.children(initial).first else { return false }
            found = (keeper, initial, program)
            return true
        }
        return found.map { (keeper: $0.0, initial: $0.1, program: $0.2) }
    }
}

extension TestHost {
    /// Every session this host starts from now on is started in a box over `folder` (`SessionBox.plan`), whatever
    /// asks: the host's own way of deciding who is confined is SB5's (`SessionSandbox.testLaunch`).
    func confine(to folder: String) {
        server.queue.setSpecific(key: SessionSandbox.testLaunch, value: SessionBox.launch(folder))
    }
}

/// A session whose spawn carries a sandbox plan is started in that plan's box by its launcher, which stays outside as
/// the box's keeper and its terminal's leader; one with no plan starts as it always did; a plan that can't be applied
/// starts nothing (the session sandbox plan's Task SB3, SB-D2). Scratch `/bin/sh` sessions only, each box over a
/// scratch folder. They run where `Platform.Sandbox.probe()` says a box can be built, and say why they skip elsewhere.
///
/// The sessions are `HostedSession`s of this process, as the host's own are, without a server: until the host decides
/// who is confined (SB5) nothing routes a plan from a spawn request to `HostedSession.spawn`. The handover is the
/// session's own half of one (`saved()`, then `restore`), for the same reason: a scratch host process can't be told
/// to confine yet.
@Suite(hostTestLimit) struct SessionSandboxTests {
    let scratch = Scratch()

    /// Reads lines until its terminal closes: `size` prints the terminal's size, `bye` exits 7, anything else is
    /// said back.
    static let talker = """
        echo host:$(hostname); while IFS= read -r line; do case $line in size) echo size:$(stty size | tr ' ' x);; bye) exit 7;; \
        *) echo got:$line;; esac; done
        """

    /// What a session running `talker` showed and how it ended, plain or in a box: its machine's name, its screen
    /// once it said a line back, its terminal's size after a resize, its exit.
    private func talk(sandbox: Bool) async throws -> (host: String?, screen: String, size: String?, exit: Int32?) {
        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start(Self.talker, in: folder, sandbox: sandbox ? SessionBox.launch(folder) : nil, probe: probe)
        defer { probe.end(session) }
        func line(_ prefix: String) -> String? {
            probe.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        #expect(await eventually { line("host:") != nil }, "\(probe.diagnosis(session))")
        probe.queue.sync { _ = session.write(Data("hi\r".utf8)) }
        #expect(await eventually { line("got:") != nil }, "\(probe.diagnosis(session))")
        var screen = ""
        #expect(await eventually {
            screen = probe.queue.sync { session.screenText() }
            return screen.contains("got:hi")
        }, "\(screen.debugDescription)")
        probe.queue.sync {
            session.resize(cols: 100, rows: 30)
            _ = session.write(Data("size\r".utf8))
        }
        #expect(await eventually { line("size:") != nil }, "\(probe.diagnosis(session))")
        probe.queue.sync { _ = session.write(Data("bye\r".utf8)) }
        #expect(await eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
        return (line("host:"), screen, line("size:"), probe.lastChange?.exit?.status)
    }

    /// A confined session's output reaches its screen, its input its program, a resize its terminal, and its
    /// program's exit status the host, exactly as a plain session's do: the same program run both ways gives the same
    /// answers, but for the machine's name, which is the box's inside.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aConfinedSessionsScreenInputResizeAndExitAreAsBefore() async throws {
        let plain = try await talk(sandbox: false)
        let confined = try await talk(sandbox: true)
        #expect(plain.host != nil && plain.host != SessionBox.hostname)
        #expect(confined.host == SessionBox.hostname, "not in its box: \(confined)")
        for said in [plain, confined] {
            #expect(said.screen.contains("got:hi"), "\(said)")
            #expect(said.size == "30x100", "\(said)")
            #expect(said.exit == 7, "\(said)")
        }
    }

    /// The host knows a confined session by its keeper: the launcher, which kept its pid, stayed outside the box's
    /// pid namespace and leads the session's terminal, so the session holds its identity as a plain one does. The
    /// program is inside (pid 2 of the box's own numbering, under its init), is the terminal's foreground group in the
    /// keeper's session, and it and what it starts are the session's by ancestry, as the host numbers them.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aConfinedSessionHoldsItsIdentityWhileItsKeeperLeadsItsTerminal() async throws {
        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start("sleep 3600 & echo ready; wait", in: folder, sandbox: SessionBox.launch(folder), probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
        let box = try #require(await SessionBox.processes(of: session, probe: probe), "\(probe.diagnosis(session))")
        let (info, master) = probe.queue.sync { (session.info, session.saved().masterFD) }
        #expect(box.keeper == info.childPID)

        // The keeper: outside, the launcher still (its arguments are the launcher's), the leader of the terminal.
        #expect(SessionBox.pidNamespace(box.keeper) == SessionBox.pidNamespace(getpid()))
        #expect(SessionBox.numbers(box.keeper) == [box.keeper])
        #expect(Platform.Processes.arguments(box.keeper).dropFirst().first == "--pty-exec")
        #expect(Platform.Terminals.session(ofMaster: try #require(master)) == box.keeper)
        #expect(getsid(box.keeper) == box.keeper)
        #expect(probe.queue.sync { session.holdsIdentity })

        // The program: inside, pid 2 there, the terminal's foreground group in the keeper's session.
        #expect(SessionBox.numbers(box.initial) == [box.initial, 1])
        #expect(SessionBox.numbers(box.program) == [box.program, 2])
        #expect(SessionBox.pidNamespace(box.program) != nil && SessionBox.pidNamespace(box.program) != SessionBox.pidNamespace(getpid()))
        #expect(getsid(box.program) == box.keeper)
        #expect(tcgetpgrp(try #require(master)) == box.program)
        #expect(ProcessTable.info(pid: box.program)?.tty == info.tty)

        // Whose they are: the session's, each by its ancestry, the keeper matched by its token.
        let inside = SessionBox.under(box.program)
        #expect(!inside.isEmpty, "the program started nothing: \(probe.diagnosis(session))")
        let sessions = probe.queue.sync { [session] }
        for pid in [box.keeper, box.initial, box.program] + inside {
            let found = probe.queue.sync {
                SessionIdentityChecks.session(of: pid, among: sessions, reading: Platform.Processes.link, note: { _ in })
            }
            #expect(found == info.id.uuidString, "pid \(pid)")
        }
    }

    /// Ending a confined session as the host ends any (`terminate`: SIGHUP to its groups, its strays asked to end)
    /// ends its keeper, its init, its program and everything the program started, a process that left its group and
    /// its session included.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func endingAConfinedSessionEndsEveryProcessInIt() async throws {
        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start("sleep 3600 & sleep 3600 & (setsid sleep 3600 &); echo ready; wait", in: folder,
                                           sandbox: SessionBox.launch(folder), probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
        let keeper = probe.queue.sync { session.info.childPID }
        // Init, the shell and its three sleeps.
        var inside: [pid_t] = []
        #expect(await eventually {
            inside = SessionBox.under(keeper)
            return inside.count >= 5 && inside.filter { Platform.Processes.arguments($0).first == "sleep" }.count == 3
        }, "\(inside.map { Platform.Processes.arguments($0) })")
        let started = inside.compactMap { pid in SessionBox.start(of: pid).map { (pid: pid, ticks: $0) } }
        #expect(started.count == inside.count)

        probe.queue.sync { session.terminate() }
        #expect(await eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
        #expect(await eventually { started.allSatisfy { !SessionBox.runs($0.pid, startedAt: $0.ticks) } },
                "still running: \(started.filter { SessionBox.runs($0.pid, startedAt: $0.ticks) }.map { Platform.Processes.arguments($0.pid) })")
        #expect(SessionBox.under(keeper).isEmpty)
    }

    /// The shell line that starts `marker`, a process that leaves its program's tree: in a session of its own, its
    /// parent gone (a double fork), deaf to SIGHUP; then says `ready`, and ends 0 at its first line of input.
    static func leaver(_ marker: String) -> String {
        "(setsid nohup bash -c 'exec -a \(marker) sleep 3600' >/dev/null 2>&1 &); echo ready; read line; exit 0"
    }

    /// A process that left its program's tree (a double fork, `setsid`, `nohup`) is still in the box: when the
    /// program ends, on its own, the box's init ends and the kernel ends that process with it. Outside a box the same
    /// process outlives its session, which is what the box changes (the test ends that one itself).
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aProcessThatLeftTheProgramsTreeInsideDiesWithIt() async throws {
        for confined in [false, true] {
            let folder = try SessionBox.folder(scratch)
            let marker = "vs-leaver-\(UUID().uuidString.prefix(8))"
            let probe = SessionProbe()
            let session = try SessionBox.start(Self.leaver(marker), in: folder, sandbox: confined ? SessionBox.launch(folder) : nil, probe: probe)
            defer { probe.end(session) }
            #expect(await eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
            var leaver: pid_t?
            #expect(await eventually {
                leaver = SessionBox.process(named: marker)
                return leaver != nil
            }, "\(probe.diagnosis(session))")
            let pid = try #require(leaver)
            let ticks = try #require(SessionBox.start(of: pid))
            // Found by its name alone, it is this test's own, by the machine's number: ended whatever happens next.
            defer { if SessionBox.runs(pid, startedAt: ticks) { kill(pid, SIGKILL) } }
            let keeper = probe.queue.sync { session.info.childPID }
            // It left: a session of its own, and no longer the program's child.
            #expect(getsid(pid) != keeper)
            if confined {
                let box = try #require(await SessionBox.processes(of: session, probe: probe))
                #expect(await eventually { Platform.Processes.link(pid)?.parent == box.initial }, "\(String(describing: Platform.Processes.link(pid)))")
            } else {
                #expect(await eventually { Platform.Processes.link(pid).map { $0.parent != keeper } == true })
            }

            probe.queue.sync { _ = session.write(Data("\r".utf8)) }
            #expect(await eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
            #expect(probe.lastChange?.exit?.status == 0)
            if confined {
                #expect(await eventually { !SessionBox.runs(pid, startedAt: ticks) }, "the process outlived its box: \(Platform.Processes.arguments(pid))")
            } else {
                #expect(SessionBox.runs(pid, startedAt: ticks), "a plain session's leaver ended with it: the confined case proves nothing")
            }
        }
    }

    /// A confined session is carried across a handover as any session is: what the old image saves of it and the new
    /// image restores is its terminal and its program's pid, the keeper's, which the new image still parents. The box
    /// lives on meanwhile, the restored session holds its identity, its input and output go on, and ending it ends
    /// the box. (The session's half of a handover, in this process: `saved()`, the old object closed without ending
    /// its program, then `restore` over a copy of the terminal's descriptor, as an exec would leave it.)
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aConfinedSessionSurvivesAHandover() async throws {
        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start(Self.talker, in: folder, sandbox: SessionBox.launch(folder), probe: probe)
        var old: HostedSession? = session
        defer { if let old { probe.end(old) } }
        #expect(await eventually { probe.text.contains("host:\(SessionBox.hostname)") }, "\(probe.diagnosis(session))")
        probe.queue.sync { _ = session.write(Data("before\r".utf8)) }
        #expect(await eventually { probe.text.contains("got:before") }, "\(probe.diagnosis(session))")
        let box = try #require(await SessionBox.processes(of: session, probe: probe))
        let started = try #require(SessionBox.start(of: box.program))

        // The old image's last act, and the new one's first.
        var saved = probe.queue.sync { session.saved() }
        let master = fcntl(try #require(saved.masterFD), F_DUPFD_CLOEXEC, 3)
        try #require(master >= 0)
        saved.masterFD = master
        probe.queue.sync { session.close() }
        old = nil
        let after = SessionProbe()
        let restored = after.queue.sync {
            let restored = HostedSession.restore(saved, launcher: hostLauncher, parser: ParserOptions(), ringCapacity: 1 << 20, queue: after.queue)
            after.attach(restored)
            return restored
        }
        defer { after.end(restored) }

        // The same box, the same program in it, and the session its keeper's still.
        #expect(SessionBox.runs(box.program, startedAt: started))
        #expect(after.queue.sync { restored.info.isLive && restored.info.childPID == box.keeper })
        #expect(after.queue.sync { restored.holdsIdentity })
        let sessions = after.queue.sync { [restored] }
        let found = after.queue.sync {
            SessionIdentityChecks.session(of: box.program, among: sessions, reading: Platform.Processes.link, note: { _ in })
        }
        #expect(found == saved.info.id.uuidString)
        // What it showed before is on its screen, and it goes on.
        var screen = ""
        #expect(await eventually {
            screen = after.queue.sync { restored.screenText() }
            return screen.contains("got:before")
        }, "\(screen.debugDescription)")
        after.queue.sync { _ = restored.write(Data("after\r".utf8)) }
        #expect(await eventually { after.text.contains("got:after") }, "\(after.diagnosis(restored))")
        // Its end is the box's.
        after.queue.sync { restored.terminate() }
        #expect(await eventually { after.lastChange?.exit != nil }, "\(after.diagnosis(restored))")
        #expect(await eventually { !SessionBox.runs(box.program, startedAt: started) })
    }

    /// The links of this process's descriptors that are a session's plan (/proc names a memfd by its name).
    static func plansHeld() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []).compactMap {
            try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")
        }.filter { $0.contains("memfd:\(SessionSandbox.planName)") }
    }

    /// The plan reaches the launcher in sealed memory (every seal, `0400`, close-on-exec in the host), named to it by
    /// its descriptor's number alone; the door line and the proxy's descriptor the same way. No argument and no
    /// variable of the launcher names a path of the plan, the launcher reads back the plan it was given, and the host
    /// holds the memory no longer once the launcher started.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func thePlanTravelsInSealedMemoryAndNoArgumentNamesAPath() async throws {
        let folder = try SessionBox.folder(scratch)
        let plan = SessionBox.plan(folder)

        // What the host makes for a spawn.
        let made = SessionSandbox.launching(SessionSandbox.Launch(plan: plan, doorLine: 71, proxyOut: 72))
        var closed = false
        func closeMade() {
            if !closed { made.close.forEach { Sys.close($0) } }
            closed = true
        }
        defer { closeMade() }
        try #require(made.flags.count == 6, "\(made)")
        let memory = try #require(Int32(made.flags[1]), "\(made)")
        #expect(made.flags == [SessionSandbox.planFlag, "\(memory)", SessionSandbox.doorLineFlag, "71", SessionSandbox.proxyFlag, "72"])
        #expect(made.keep == [memory, 71, 72])
        // Its own to close: the plan's memory, never the launch's descriptors.
        #expect(made.close == [memory])
        #expect(Platform.ProcessSelf.isSealed(memory))
        var info = stat()
        #expect(fstat(memory, &info) == 0 && info.st_mode & 0o7777 == 0o400)
        #expect(fcntl(memory, F_GETFD) & FD_CLOEXEC != 0)
        var byte: UInt8 = 0
        #expect(pwrite(memory, &byte, 1, 0) < 0, "the plan's memory can be written")
        #expect(SessionSandbox.plan(from: memory) == plan)
        // The same bytes in anything but sealed memory are no plan: a file anyone could have written.
        let file = folder + "/plan"
        try JSONEncoder().encode(plan).write(to: URL(fileURLWithPath: file))
        let unsealed = open(file, O_RDONLY | O_CLOEXEC)
        try #require(unsealed > STDERR_FILENO)
        #expect(SessionSandbox.plan(from: unsealed) == nil, "a plan was read from a file")
        Sys.close(unsealed)
        #expect(!made.flags.contains { $0.contains("/") })
        closeMade()
        // Nothing for a spawn with no plan.
        let none = SessionSandbox.launching(nil)
        #expect(none.flags.isEmpty && none.keep.isEmpty && none.close.isEmpty)

        // What a launcher was started with: the flag and a number, and no path of the plan.
        let probe = SessionProbe()
        let session = try SessionBox.start("echo ready; exec sleep 3600", in: folder, sandbox: SessionSandbox.Launch(plan: plan), probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("ready") }, "\(probe.diagnosis(session))")
        let keeper = probe.queue.sync { session.info.childPID }
        let arguments = Platform.Processes.arguments(keeper)
        try #require(arguments.count > 4, "\(arguments)")
        #expect(arguments[1] == "--pty-exec" && arguments[2] == SessionSandbox.planFlag && Int32(arguments[3]) != nil, "\(arguments)")
        #expect(arguments[4] == "/bin/bash" || arguments[4] == "/bin/sh", "\(arguments)")
        #expect(!arguments.contains { $0.contains(folder) }, "\(arguments)")
        let environment = try #require(Platform.Processes.environment(keeper))
        #expect(!environment.contains { $0.contains(folder) }, "\(environment)")
        // The host's copy went with the spawn (another test's spawn may hold its own for a moment).
        #expect(await eventually { Self.plansHeld().isEmpty }, "\(Self.plansHeld())")
    }

    /// A launcher started on a terminal of its own with `flags` before its program: what it wrote there and how it
    /// ended (its wait status), or nil when it didn't end.
    private func launcher(flags: [String], running command: String, in folder: String) async throws -> (status: Int32?, said: String) {
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        var code: Int32 = 0
        let child = try #require(PTYSpawn.spawn(launcher: hostLauncher, executable: "/bin/sh", args: ["/bin/sh", "-c", command],
                                                env: ["PATH=/usr/bin:/bin"], directory: folder, size: &size, failure: &code, launcherFlags: flags))
        defer { Sys.close(child.masterFD) }
        _ = fcntl(child.masterFD, F_SETFL, fcntl(child.masterFD, F_GETFL) | O_NONBLOCK)
        var said = Data(), status: Int32 = 0, ended = false
        func drain() {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(child.masterFD, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                said.append(contentsOf: chunk[0..<count])
            }
        }
        _ = await eventually {
            drain()
            if !ended { ended = waitpid(child.pid, &status, WNOHANG) == child.pid }
            return ended
        }
        drain()
        if !ended {
            kill(child.pid, SIGKILL)
            _ = eventuallyBlocking { waitpid(child.pid, &status, WNOHANG) != 0 }
        }
        return (ended ? status : nil, String(decoding: said, as: UTF8.self))
    }

    /// A plan that can't be applied starts nothing: the launcher says which step failed on the session's terminal
    /// and exits 127, the program never run and no process left. So does a launcher given a flag and no plan it can
    /// read: no descriptor (what the host gives when it couldn't seal the plan), one that isn't open, one that isn't
    /// sealed memory's number, a line's flag without the plan's. None of them runs its program plain.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aLauncherThatCantBuildItsBoxExits127AndSaysWhy() async throws {
        let folder = try SessionBox.folder(scratch)
        let ran = folder + "/ran"
        // A mount whose source isn't there.
        let probe = SessionProbe()
        let missing = SessionBox.launch(folder, extra: [.init("/missing", .readOnly(source: folder + "/missing"))])
        let session = try SessionBox.start("touch '\(ran)'; echo it-ran", in: folder, sandbox: missing, probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
        #expect(probe.lastChange?.exit?.status == 127, "\(probe.diagnosis(session))")
        #expect(probe.text.contains("VibeSwitcher: this session's sandbox couldn't be built: mount /missing"), "\(probe.text.debugDescription)")
        #expect(!probe.text.contains("it-ran"))
        #expect(!FileManager.default.fileExists(atPath: ran))
        #expect(SessionBox.under(probe.queue.sync { session.info.childPID }).isEmpty)

        // A step that fails last of all, in the box, the program's process already the terminal's foreground group:
        // its shell isn't there to run (no /bin inside). The launcher still says so and ends.
        var shellless = SessionBox.plan(folder)
        shellless.mounts.removeAll { $0.target == "/bin" }
        let late = SessionProbe()
        let unstarted = try SessionBox.start("touch '\(ran)'; echo it-ran", in: folder, sandbox: SessionSandbox.Launch(plan: shellless), probe: late)
        defer { late.end(unstarted) }
        #expect(await eventually { late.lastChange?.exit != nil }, "\(late.diagnosis(unstarted))")
        #expect(late.lastChange?.exit?.status == 127, "\(late.diagnosis(unstarted))")
        #expect(late.text.contains("VibeSwitcher: this session's sandbox couldn't be built: exec"), "\(late.text.debugDescription)")
        #expect(!late.text.contains("it-ran"))
        #expect(!FileManager.default.fileExists(atPath: ran))

        // A flag, and no plan behind it.
        let unreadable: [[String]] = [[SessionSandbox.planFlag, "-1"], [SessionSandbox.planFlag, "999"], [SessionSandbox.planFlag, "0"],
                                      [SessionSandbox.planFlag, "plan"], [SessionSandbox.doorLineFlag, "5"], [SessionSandbox.proxyFlag, "5"],
                                      [SessionSandbox.planFlag]]
        for flags in unreadable {
            let ended = try await launcher(flags: flags, running: "touch '\(ran)'; echo it-ran", in: folder)
            let status = try #require(ended.status, "\(flags): it didn't end; it said \(ended.said.debugDescription)")
            #expect(status & 0x7f == 0 && (status >> 8) & 0xff == 127, "\(flags): status \(status), \(ended.said.debugDescription)")
            #expect(ended.said.contains("VibeSwitcher: this session's sandbox couldn't be built: "), "\(flags): \(ended.said.debugDescription)")
            #expect(!ended.said.contains("it-ran"), "\(flags)")
            #expect(!FileManager.default.fileExists(atPath: ran), "\(flags): the program ran")
        }
    }

    /// A confined session's program has the `oom_score_adj` every session's has, the host's plus 500 (at most 1000):
    /// its launcher raised its own before it built the box, and its init and its program were made from it. Read
    /// inside (the box's own /proc) and from outside.
    @Test(.enabled(if: SessionBox.can, "\(SessionBox.skip)"))
    func aConfinedProgramIsStillTheOOMKillersFirstPick() async throws {
        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start("printf 'oom=%s\\n' \"$(cat /proc/self/oom_score_adj)\"; exec sleep 3600", in: folder,
                                           sandbox: SessionBox.launch(folder), probe: probe)
        defer { probe.end(session) }
        // The host is this process.
        let hosts = try #require(SessionBox.number("oom_score_adj", of: getpid()))
        let raised = min(1000, hosts + HostImages.oomRaise)
        // The whole line, its end too: a read of the terminal can fall between the value and the line's end.
        #expect(await eventually { probe.text.contains("oom=\(raised)\r") }, "\(probe.text.debugDescription) \(probe.diagnosis(session))")
        #expect(!probe.text.contains("wasn't raised"), "\(probe.text.debugDescription)")
        let box = try #require(await SessionBox.processes(of: session, probe: probe))
        #expect(SessionBox.number("oom_score_adj", of: box.program) == raised)
        #expect(SessionBox.number("oom_score_adj", of: box.keeper) == raised)
    }

    /// A spawn with no plan is what it was: its launcher is given no flag and no descriptor, runs its program in its
    /// own place (the session's program is the shell, in this process's namespaces, under no init), and a launcher's
    /// arguments with none of the flags first are left as they are, whatever comes later in them.
    @Test func aSessionWithNoPlanStartsAsBefore() async throws {
        let none = SessionSandbox.launching(nil)
        #expect(none.flags.isEmpty && none.keep.isEmpty && none.close.isEmpty)
        let given = ["/bin/sh", "-c", "echo \(SessionSandbox.planFlag) 3", SessionSandbox.planFlag, "3"]
        var program = given
        SessionSandbox.enterIfAsked(&program)
        #expect(program == given)

        let folder = try SessionBox.folder(scratch)
        let probe = SessionProbe()
        let session = try SessionBox.start("echo host:$(hostname); exec sleep 3600", in: folder, sandbox: nil, probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.text.contains("host:") }, "\(probe.diagnosis(session))")
        #expect(!probe.text.contains("host:\(SessionBox.hostname)"))
        let pid = probe.queue.sync { session.info.childPID }
        // The launcher became the program: `sleep`, with nothing of the launcher's left in its arguments.
        #expect(await eventually { Platform.Processes.arguments(pid).first == "sleep" }, "\(Platform.Processes.arguments(pid))")
        #expect(Platform.Processes.children(pid).isEmpty)
        #expect(probe.queue.sync { session.info.isLive })
        guard !Platform.CodeIdentity.isAvailable else { return }
        #expect(SessionBox.pidNamespace(pid) == SessionBox.pidNamespace(getpid()))
        #expect(SessionBox.numbers(pid) == [pid])
    }

    /// The Mac builds no box, and nothing there gives a spawn a plan. One given a plan all the same starts nothing:
    /// its launcher says so on the terminal and exits 127, as on Linux where a box can't be built. A spawn with no
    /// plan runs as always.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac has no box; Linux's tests are the rest of this suite"))
    func theMacStartsNoBox() async throws {
        #expect(!Platform.Sandbox.probe().userNamespaces)
        #expect(Platform.Sandbox.probe().why == "macOS")
        let none = SessionSandbox.launching(nil)
        #expect(none.flags.isEmpty && none.keep.isEmpty && none.close.isEmpty)

        let folder = try SessionBox.folder(scratch)
        let ran = folder + "/ran"
        let probe = SessionProbe()
        let session = try SessionBox.start("touch '\(ran)'", in: folder, sandbox: SessionBox.launch(folder), probe: probe)
        defer { probe.end(session) }
        #expect(await eventually { probe.lastChange?.exit != nil }, "\(probe.diagnosis(session))")
        #expect(probe.lastChange?.exit?.status == 127, "\(probe.diagnosis(session))")
        #expect(probe.text.contains("VibeSwitcher: this session's sandbox couldn't be built"), "\(probe.text.debugDescription)")
        #expect(!FileManager.default.fileExists(atPath: ran))

        let plain = SessionProbe()
        let other = try SessionBox.start("touch '\(ran)'", in: folder, sandbox: nil, probe: plain)
        defer { plain.end(other) }
        #expect(await eventually { plain.lastChange?.exit != nil }, "\(plain.diagnosis(other))")
        #expect(plain.lastChange?.exit?.status == 0, "\(plain.diagnosis(other))")
        #expect(FileManager.default.fileExists(atPath: ran))
    }
}
