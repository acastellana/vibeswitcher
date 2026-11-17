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
            return Facts(userNamespaces: why == nil, overlay: overlay, landlockABI: landlock, vsock: vsock, why: why)
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
            var child = Platform.Spawn(executable: unshare, arguments: ["unshare", "--user", "--map-current-user", "--mount", "--pid",
                                                                       "--ipc", "--uts", "--cgroup", "--net", "--fork", "/bin/true"])
            child.stdin = .path("/dev/null", flags: O_RDONLY)
            child.stdout = .path("/dev/null", flags: O_WRONLY)
            child.stderr = .path("/dev/null", flags: O_WRONLY)
            child.keep = []
            guard case .success(let pid) = child.start() else { return "\(unshare) didn't start" }
            var status: Int32 = 0
            // Bounded: a hung child is killed after 10 s and counts as a refusal.
            var waited: useconds_t = 0
            while true {
                let found = waitpid(pid, &status, WNOHANG)
                if found == pid { break }
                if found < 0, errno != EINTR { return "the probe's child was lost" }
                if waited >= 10_000_000 {
                    kill(pid, SIGKILL)
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    return "the probe's child hung"
                }
                usleep(2_000)
                waited += 2_000
            }
            let exited = status & 0x7f == 0
            return exited && (status >> 8) & 0xff == 0 ? nil : "the kernel refused an unprivileged user namespace (unshare: status \(status))"
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
