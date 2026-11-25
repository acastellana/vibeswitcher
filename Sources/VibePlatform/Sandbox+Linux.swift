#if os(Linux)
import Foundation

// Linux's forms of `Platform.Sandbox`: the shim's `vibe_sandbox_enter` (shim_sandbox.c, shim_seccomp.c), and a probe
// that tries the namespaces in a child. Only libc and the shim, on glibc and on musl.
extension Platform.Sandbox {
    enum System {
        /// util-linux's unshare(1), which makes the namespaces a box needs in a child of its own: the probe's way of
        /// asking the kernel without this process unsharing anything, and without a fork here.
        static let unshare = "/usr/bin/unshare"

        static func probe() -> Facts {
            let overlay = vibe_sandbox_overlay_known() == 1
            let landlock = Int(vibe_sandbox_landlock_abi())
            let vsock = vibe_sandbox_vsock_opens() == 1
            let why = refusal()
            return Facts(userNamespaces: why == nil, overlay: overlay, landlockABI: landlock, vsock: vsock,
                         binfmt: why == nil ? binfmt() : .unknown, why: why)
        }

        /// util-linux's mount(8), which the binfmt probe mounts with.
        static let mount = "/usr/bin/mount"

        /// The binfmt probe's command: mount(8) mounts a binfmt_misc, as the root of a user namespace of unshare(1)'s
        /// child's own, over the /tmp of a mount namespace of its own.
        static let binfmtProbe = [unshare, "--user", "--map-root-user", "--mount", mount, "-t", "binfmt_misc", "binfmt_misc", "/tmp"]

        /// Whether a user namespace gets a binfmt_misc of its own (measured on 6.18; 6.7 in the kernel's history), as
        /// `command` (`binfmtProbe`) finds, given `bound` microseconds: `.own` when it exits 0; `.none` only when the
        /// kernel answered no, mount(8)'s exit 32 (its mount failed: measured on 6.18 for a file system the kernel
        /// refuses a user namespace, sysfs with the machine's network, and for one it doesn't have); `.unknown` for every
        /// other end (no mount(8), unshare(1) not started or failing, 126 or 127 from its exec, a signal, a child hung past
        /// `bound` or lost), which is no answer and so never reads as "nothing to hide" (`SandboxPlanner.hidesInterpreters`).
        static func binfmt(_ command: [String] = binfmtProbe, mount: String = mount, bound: useconds_t = 10_000_000) -> Binfmt {
            guard access(mount, X_OK) == 0 else { return .unknown }
            switch run(command, bound: bound) {
            case .exited(0): return .own
            case .exited(32): return .none
            default: return .unknown
            }
        }

        /// Why the kernel refuses this user a box's namespaces; nil when a child made them.
        private static func refusal() -> String? {
            if let limit = number(at: "/proc/sys/user/max_user_namespaces"), limit == 0 {
                return "user namespaces are off (user.max_user_namespaces is 0)"
            }
            if let restricted = number(at: "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"), restricted != 0 {
                return "AppArmor refuses unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns is \(restricted))"
            }
            guard access(unshare, X_OK) == 0 else { return "no \(unshare) to try the namespaces with" }
            switch run([unshare, "--user", "--map-current-user", "--mount", "--pid", "--ipc", "--uts", "--cgroup", "--net", "--fork", "/bin/true"]) {
            case .exited(0): return nil
            case .exited(let code): return "the kernel refused an unprivileged user namespace (unshare: exit \(code))"
            case .signaled(let signal): return "the kernel refused an unprivileged user namespace (unshare: signal \(signal))"
            case .failed(let why): return why
            }
        }

        /// How a probe's child ended.
        enum Ran: Equatable {
            case exited(Int32)
            case signaled(Int32)
            /// It didn't start, was lost, or hung (killed after its bound): why.
            case failed(String)
        }

        /// `command` (its program's path, then its arguments) run with its output thrown away, killed after `bound`
        /// microseconds.
        static func run(_ command: [String], bound: useconds_t = 10_000_000) -> Ran {
            guard let program = command.first else { return .failed("no program") }
            var child = Platform.Spawn(executable: program, arguments: command)
            child.stdin = .path("/dev/null", flags: O_RDONLY)
            child.stdout = .path("/dev/null", flags: O_WRONLY)
            child.stderr = .path("/dev/null", flags: O_WRONLY)
            child.keep = []
            guard case .success(let pid) = child.start() else { return .failed("\(program) didn't start") }
            var status: Int32 = 0
            // Bounded: a hung child is killed after `bound`.
            var waited: useconds_t = 0
            while true {
                let found = waitpid(pid, &status, WNOHANG)
                if found == pid { break }
                if found < 0, errno != EINTR { return .failed("the probe's child was lost") }
                if waited >= bound {
                    kill(pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    return .failed("the probe's child hung")
                }
                usleep(2_000)
                waited += 2_000
            }
            return status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signaled(status & 0x7f)
        }

        /// The number a /proc/sys file holds; nil when it isn't there.
        private static func number(at path: String) -> Int? {
            guard case .success(let bytes) = Platform.Processes.System.contents(path) else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        static func enter(_ plan: Plan, doorLine: Int32?, proxyOut: Int32?, program: [String]) -> Failure {
            guard let path = program.first else { return Failure(step: "plan", code: EINVAL) }
            // Every string the C side reads, copied once and kept until it returns (it returns only on a failure).
            var owned: [UnsafeMutablePointer<CChar>] = []
            var blobs: [UnsafeMutableRawPointer] = []
            defer {
                owned.forEach { free($0) }
                blobs.forEach { free($0) }
            }
            func copy(_ text: String?) -> UnsafePointer<CChar>? {
                guard let text, let made = strdup(text) else { return nil }
                owned.append(made)
                return UnsafePointer(made)
            }
            func list(_ texts: [String]) -> [UnsafeMutablePointer<CChar>?] {
                texts.map { text -> UnsafeMutablePointer<CChar>? in
                    let made = strdup(text)
                    if let made { owned.append(made) }
                    return made
                } + [nil]
            }

            var mounts: [vibe_sandbox_mount] = []
            for mount in plan.mounts {
                var made = vibe_sandbox_mount()
                made.target = copy(mount.target)
                switch mount.kind {
                case .readOnly(let source):
                    made.kind = Int32(VIBE_MOUNT_READ_ONLY)
                    made.source = copy(source)
                case .readWrite(let source):
                    made.kind = Int32(VIBE_MOUNT_READ_WRITE)
                    made.source = copy(source)
                case .overlay(let lower, let upper, let work):
                    made.kind = Int32(VIBE_MOUNT_OVERLAY)
                    made.source = copy(lower)
                    made.upper = copy(upper)
                    made.work = copy(work)
                case .empty(let mode):
                    made.kind = Int32(VIBE_MOUNT_EMPTY)
                    made.mode = mode
                case .proc:
                    made.kind = Int32(VIBE_MOUNT_PROC)
                case .devpts:
                    made.kind = Int32(VIBE_MOUNT_DEVPTS)
                case .sysfs:
                    made.kind = Int32(VIBE_MOUNT_SYSFS)
                case .device(let name):
                    made.kind = Int32(VIBE_MOUNT_DEVICE)
                    made.source = copy(name)
                case .link(let text):
                    made.kind = Int32(VIBE_MOUNT_LINK)
                    made.source = copy(text)
                case .binfmt:
                    made.kind = Int32(VIBE_MOUNT_BINFMT)
                case .file(let contents, let mode):
                    made.kind = Int32(VIBE_MOUNT_FILE)
                    let room = malloc(max(contents.count, 1))!
                    blobs.append(room)
                    contents.withUnsafeBytes { if let base = $0.baseAddress { memcpy(room, base, contents.count) } }
                    made.contents = UnsafeRawPointer(room)
                    made.length = contents.count
                    made.mode = mode
                }
                mounts.append(made)
            }
            var environment = list(plan.environment)
            var arguments = list(program)

            var cPlan = vibe_sandbox_plan()
            switch plan.network {
            case .shared: cPlan.network = Int32(VIBE_NETWORK_SHARED)
            case .none: cPlan.network = Int32(VIBE_NETWORK_NONE)
            case .proxied(let port):
                cPlan.network = Int32(VIBE_NETWORK_PROXIED)
                cPlan.proxy_port = port
            }
            cPlan.hostname = copy(plan.hostname)
            cPlan.directory = copy(plan.directory)
            cPlan.door = copy(plan.door)
            cPlan.terminal = plan.terminal == .foreground ? Int32(VIBE_TERMINAL_FOREGROUND) : Int32(VIBE_TERMINAL_NONE)
            cPlan.nesting = plan.nesting ? 1 : 0
            cPlan.path = copy(path)
            cPlan.door_line = doorLine ?? -1
            cPlan.proxy_out = proxyOut ?? -1
            var failure = vibe_sandbox_failure()
            _ = mounts.withUnsafeBufferPointer { mountsPointer in
                environment.withUnsafeMutableBufferPointer { environmentPointer in
                    arguments.withUnsafeMutableBufferPointer { argumentsPointer in
                        cPlan.mounts = mountsPointer.baseAddress
                        cPlan.mount_count = mountsPointer.count
                        cPlan.environment = UnsafePointer(environmentPointer.baseAddress)
                        cPlan.arguments = UnsafePointer(argumentsPointer.baseAddress)
                        return vibe_sandbox_enter(&cPlan, &failure)
                    }
                }
            }
            let step = withUnsafeBytes(of: failure.step) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Failure(step: step.isEmpty ? "unknown" : step, code: failure.code)
        }
    }
}
#endif
