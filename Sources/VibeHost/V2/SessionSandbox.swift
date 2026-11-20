import Foundation
import VibeCore

/// A session started inside a box (the session sandbox plan's Task SB3, SB-D2;
/// docs/superpowers/plans/2026-11-17-v2-session-sandbox.md).
///
/// The host never forks, and never unshares anything of its own. A spawn that carries a plan (`Launch`) gives its
/// launcher, the `--pty-exec` child `PTYSpawn.spawn` starts, the plan in sealed memory and that memory's descriptor
/// number in a flag (`launching`). The launcher, a fresh process with one thread, takes its terminal and is made
/// dumpable as every launcher is (`SessionIdentityChecks.takeTerminal`, `HostImages.beforeProgram`), then reads the
/// plan and enters it (`enterIfAsked`, `Platform.Sandbox.enter`): it stays outside as the box's keeper, with the pid
/// the host knows, the leader of the session's terminal, and exits as the program did; the program is the terminal's
/// foreground group inside. So the host's own view of a session (its terminal's session, its program's token, its
/// exit, `terminate`'s signals to its groups) holds for a confined one unchanged.
///
/// **It fails closed, both sides.** A launcher whose first argument is one of the flags below either enters its plan
/// or says which step failed on the session's terminal and exits 127: it never runs its program plain. A host that
/// can't put the plan in sealed memory still gives the flag, naming no descriptor, so that launcher refuses too.
///
/// **Nothing of the plan is in an argument or a variable.** The flags carry descriptor numbers. The plan's bytes are
/// in memory nobody can change (every seal), `0400`, close-on-exec in the host, which closes it once the launcher
/// started; the launcher reads it only from sealed memory, then closes it, and the box's init and program hold no
/// descriptor the launcher was given (`Platform.Sandbox`).
///
/// **The program's environment is the plan's**, whole: nothing of the launcher's own reaches it, the session's id
/// (`VIBESWITCHER_SESSION`) included, unless whoever made the plan put it there.
///
/// A spawn with no plan gets no flag, no descriptor and no other change: its launcher runs today's path.
///
/// The Mac has no box (`Platform.Sandbox.probe()`) and no sealed memory: nothing there gives a spawn a plan, and one
/// given a plan anyway starts nothing, as on Linux when a box can't be built.
public enum SessionSandbox {
    /// Before the program in the launcher's arguments, after `SessionIdentityChecks.launcherFlags`: the descriptor
    /// number of the sealed memory that holds the session's plan. Always the first of the three.
    static let planFlag = "--pty-sandbox"
    /// The descriptor number each of the box's door connections is sent on (`Launch.doorLine`).
    static let doorLineFlag = "--pty-door-line"
    /// The descriptor number the box's proxy listener is sent on (`Launch.proxyOut`).
    static let proxyFlag = "--pty-proxy-out"

    private static let flags: Set<String> = [planFlag, doorLineFlag, proxyFlag]

    /// What a confined spawn carries: the box's plan, and this process's descriptors the box hands its door
    /// connections and its proxy listener out on (`Platform.Sandbox.enter`'s `doorLine` and `proxyOut`).
    ///
    /// **Whose descriptors.** `doorLine` and `proxyOut` stay their maker's: the spawn keeps them open in the launcher
    /// under the same numbers and closes neither here. Whoever made them closes its own copies once the spawn
    /// returned, started or not (the launcher's are closed by the box's keeper and its init).
    public struct Launch: Sendable {
        public var plan: Platform.Sandbox.Plan
        public var doorLine: Int32?
        public var proxyOut: Int32?

        public init(plan: Platform.Sandbox.Plan, doorLine: Int32? = nil, proxyOut: Int32? = nil) {
            self.plan = plan
            self.doorLine = doorLine
            self.proxyOut = proxyOut
        }
    }

    // MARK: The host's side

    /// The name of the sealed memory a plan travels in, as /proc shows it among its holder's descriptors.
    static let planName = "vibeswitcher-sandbox-plan"

    /// What the flag names when the plan couldn't be put in sealed memory: no descriptor, so the launcher refuses.
    static let noPlan = "-1"

    /// A scratch host's tests only: the launch every spawn made on a queue that carries this key is given when it has
    /// none of its own, so a test's `HostServer` can start confined sessions before the host decides itself who is
    /// confined (SB5's `SessionConfinement`, which replaces this). Only code in this process can set it, on a queue it
    /// holds; it can add a box, never take one away.
    static let testLaunch = DispatchSpecificKey<Launch>()

    /// The host's side, for `PTYSpawn.spawn`: what the launcher of a spawn that carries `launch` is given before its
    /// program (`flags`), the descriptors of this process it keeps (`keep`), and the ones this made, which the
    /// spawner closes once the launcher started or couldn't (`close`: the plan's memory, never the launch's own
    /// descriptors). With no launch: nothing of each.
    ///
    /// A launch whose plan can't be put in sealed memory (no memfd left; the Mac, which has none) still gets the
    /// plan's flag, with `noPlan`: its launcher then starts nothing, where no flag would start the program plain.
    static func launching(_ launch: Launch?) -> (flags: [String], keep: [Int32], close: [Int32]) {
        guard let launch = launch ?? DispatchQueue.getSpecific(key: testLaunch) else { return ([], [], []) }
        guard let encoded = try? JSONEncoder().encode(launch.plan),
              case .success(let memory) = encoded.withUnsafeBytes({ Platform.ProcessSelf.sealedMemory($0, name: planName) }) else {
            return ([planFlag, noPlan], [], [])
        }
        var flags = [planFlag, String(memory)], keep = [memory]
        for (flag, descriptor) in [(doorLineFlag, launch.doorLine), (proxyFlag, launch.proxyOut)] {
            guard let descriptor else { continue }
            flags += [flag, String(descriptor)]
            keep.append(descriptor)
        }
        return (flags, keep, [memory])
    }

    // MARK: The launcher's side

    /// The most a plan's memory may hold: far above any plan (its `file` mounts are a few small files), and a bound
    /// on what a launcher reads.
    static let maxPlanBytes = 16 << 20

    /// The plan in the sealed memory `fd`, read from its beginning (`pread`: `fd` is left open, its offset alone); nil
    /// when `fd` isn't sealed memory (a file, a pipe, a memfd someone can still write, a closed descriptor, anything
    /// on the Mac) or doesn't hold a plan.
    static func plan(from fd: Int32) -> Platform.Sandbox.Plan? {
        guard fd > STDERR_FILENO, Platform.ProcessSelf.isSealed(fd) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= off_t(maxPlanBytes) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var done = 0
        while done < bytes.count {
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, $0.count - done, off_t(done)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            done += count
        }
        return try? JSONDecoder().decode(Platform.Sandbox.Plan.self, from: Data(bytes))
    }

    /// The launcher's side, `program` its arguments after the launcher's own flags (`SessionIdentityChecks.takeTerminal`
    /// gave them), called once it has its terminal and is dumpable (`HostImages.beforeProgram`), while it has one
    /// thread. With none of this file's flags first it returns at once, `program` as it was: a plain session.
    ///
    /// Otherwise it never returns. It takes the flags off the front (each once, each with a descriptor's number above
    /// 2; nothing after the program's own first argument is read as a flag), reads the plan from its sealed memory,
    /// closes that, and enters the plan (`Platform.Sandbox.enter`): this process is then the box's keeper and exits
    /// as the program did. When any of that fails it writes "VibeSwitcher: this session's sandbox couldn't be built:
    /// <step>" to the terminal (descriptor 2) and exits 127, its program never run.
    static func enterIfAsked(_ program: inout [String]) {
        guard let first = program.first, flags.contains(first) else { return }
        var numbers: [String: Int32] = [:]
        var rest = program[...]
        while let flag = rest.first, flags.contains(flag) {
            guard rest.count >= 2, numbers[flag] == nil, let number = Int32(rest[rest.startIndex + 1]), number > STDERR_FILENO else {
                refuse("its launcher was given no descriptor with \(flag)", program: nil)
            }
            numbers[flag] = number
            rest = rest.dropFirst(2)
        }
        program = Array(rest)
        guard let memory = numbers[planFlag] else { refuse("its launcher was given no plan", program: program.first) }
        guard !program.isEmpty else { refuse("its launcher was given no program", program: nil) }
        guard let plan = plan(from: memory) else { refuse("its plan couldn't be read from sealed memory", program: program.first) }
        close(memory)
        let failure = Platform.Sandbox.enter(plan, doorLine: numbers[doorLineFlag], proxyOut: numbers[proxyFlag], program: program)
        refuse(failure.description, program: program.first)
    }

    /// Says on the session's terminal that its box couldn't be built and at which `step`, and ends this launcher 127.
    /// The host has read it before this ends (`tcdrain`, as `PTYSpawn.execIfLaunched` does for a program that isn't
    /// there).
    private static func refuse(_ step: String, program: String?) -> Never {
        let said = "VibeSwitcher: this session's sandbox couldn't be built: \(step). \(program ?? "Its program") wasn't started.\r\n"
        _ = said.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _ = tcdrain(STDERR_FILENO)
        _exit(127)
    }
}
