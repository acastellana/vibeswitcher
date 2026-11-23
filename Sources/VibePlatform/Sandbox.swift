import Foundation

extension Platform {
    /// The session sandbox's box: what a session sees, made from the kernel's namespaces and a seccomp filter by the
    /// session's launcher (the session sandbox plan, docs/superpowers/plans/2026-11-17-v2-session-sandbox.md). A
    /// `Plan` names everything inside: the root is built from nothing, so a path the plan doesn't name isn't there.
    /// `enter` applies one and runs a program in it, or says which step failed and starts nothing.
    ///
    /// The process that enters becomes the box's keeper: outside its pid namespace, the leader of its terminal, exiting
    /// as the program did. Its child is the box's init (pid 1 inside, non-dumpable), which builds the root, starts the
    /// program, passes door connections on and reaps; when the program ends, init ends, and the kernel ends every
    /// process left inside. The program holds descriptors 0, 1 and 2, the user's own uid, no capability, no_new_privs
    /// and the filter; every mount is nosuid and nodev (a device's nosuid and noexec).
    ///
    /// The Mac has no box: `probe()` says so and `enter` fails with ENOTSUP, starting nothing (the plan's "The Mac").
    /// The systems' own calls are in Sandbox+Linux.swift (with the shim's shim_sandbox.c and shim_seccomp.c) and
    /// Sandbox+Darwin.swift.
    public enum Sandbox {
        /// What this machine's kernel gives a box.
        public struct Facts: Equatable, Sendable {
            /// Whether an unprivileged process can make a user, mount and pid namespace (the box's first step).
            public var userNamespaces: Bool
            /// Whether the kernel has overlayfs (a `private` mount).
            public var overlay: Bool
            /// Landlock's ABI, 0 where it is off (not used for boxes on ABI 1: SB-D1).
            public var landlockABI: Int
            /// Whether an `AF_VSOCK` socket opens here (Hyper-V sockets: the filter refuses them in a box).
            public var vsock: Bool
            /// Whether a user namespace gets a binfmt_misc of its own here (measured on 6.18; 6.7 in the kernel's history), so a box can hide the
            /// machine's entries behind an empty one (`Mount.Kind.binfmt`). Where it can't, a box tries the machine's:
            /// WSL's interop entry among them, whose interpreter (`/init`) the kernel holds open when it carries the F
            /// flag, so the box's missing `/init` doesn't stop it; only the missing `/run/WSL` and the filter's refusal of
            /// `AF_VSOCK` then keep a Windows program from the Windows side.
            public var binfmt: Bool
            /// Why no box can be built here; nil when one can.
            public var why: String?

            public init(userNamespaces: Bool, overlay: Bool, landlockABI: Int, vsock: Bool, binfmt: Bool = false, why: String?) {
                self.userNamespaces = userNamespaces
                self.overlay = overlay
                self.landlockABI = landlockABI
                self.vsock = vsock
                self.binfmt = binfmt
                self.why = why
            }
        }

        /// This machine's facts, found once: the namespaces are tried in a child `Platform.Spawn` starts, never in
        /// this process.
        public static func probe() -> Facts { probed }

        private static let probed: Facts = System.probe()

        /// One mount of a plan, at `target` inside (absolute, with no `..` and no link along it).
        public struct Mount: Codable, Equatable, Sendable {
            public enum Kind: Codable, Equatable, Sendable {
                /// The real folder or file at `source`, read-only, with every mount below it.
                case readOnly(source: String)
                /// The real folder or file at `source`, with every mount below it.
                case readWrite(source: String)
                /// Reads `lower`; writes go to `upper` (with `work` beside it, on the same file system), never to it.
                case overlay(lower: String, upper: String, work: String)
                /// A fresh folder in memory, of `mode`, thrown away with the box.
                case empty(mode: UInt32)
                /// The box's own /proc.
                case proc
                /// A devpts of the box's own.
                case devpts
                /// sysfs, read-only; only in a box with a network of its own (the kernel's rule).
                case sysfs
                /// The machine's device node /dev/`name`, a bare name.
                case device(String)
                /// A symbolic link whose text is `to`.
                case link(to: String)
                /// A file of `contents` and `mode`, in the root's own memory (read-only once the box is built).
                case file(contents: Data, mode: UInt32)
                /// A binfmt_misc of the box's own, empty and read-only: the kernel tries a program's entries in the
                /// nearest user namespace that has one, so the machine's go untried inside. Only where `Facts.binfmt`.
                case binfmt
            }

            public var target: String
            public var kind: Kind

            public init(_ target: String, _ kind: Kind) {
                self.target = target
                self.kind = kind
            }
        }

        /// The box's network.
        public enum Network: Codable, Equatable, Sendable {
            /// The machine's (slice 1's worker, SB-D6).
            case shared
            /// A namespace of its own with loopback alone.
            case none
            /// A namespace of its own, with a listener on `127.0.0.1:port` that init makes there and sends out on the
            /// proxy's descriptor, for the node's proxy to serve (SB-D7).
            case proxied(port: UInt16)
        }

        /// The program's terminal.
        public enum Terminal: String, Codable, Equatable, Sendable {
            /// Descriptor 0 is its terminal (the keeper's controlling one), and the program's process group is its
            /// foreground group.
            case foreground
            /// A session of its own, with no terminal.
            case none
        }

        public struct Plan: Codable, Equatable, Sendable {
            /// In order: a mount under another comes after it.
            public var mounts: [Mount]
            public var network: Network
            public var hostname: String
            /// Where the program starts, inside.
            public var directory: String
            /// The program's environment, "NAME=value" each: nothing else reaches it.
            public var environment: [String]
            /// Where init binds the door, inside (in a folder the plan makes writable, such as an `empty` one); nil
            /// for no door.
            public var door: String?
            public var terminal: Terminal
            /// Whether the program may make user namespaces and mounts of its own (a project's `sandbox_nesting`,
            /// SB-D10).
            public var nesting: Bool

            public init(mounts: [Mount], network: Network, hostname: String, directory: String, environment: [String],
                        door: String?, terminal: Terminal, nesting: Bool) {
                self.mounts = mounts
                self.network = network
                self.hostname = hostname
                self.directory = directory
                self.environment = environment
                self.door = door
                self.terminal = terminal
                self.nesting = nesting
            }
        }

        /// The step that failed (as the shim names it: "threads", "unshare", "uid map", "mount /usr", "filter",
        /// "exec", …) and its error number. Nothing of the plan was started.
        public struct Failure: Error, Equatable, CustomStringConvertible {
            public var step: String
            public var code: Int32

            public init(step: String, code: Int32) {
                self.step = step
                self.code = code
            }

            public var description: String { "\(step): \(String(cString: strerror(code)))" }
        }

        /// Enters `plan` and runs `program` (its path inside, then its other arguments) in it: for a process
        /// `Platform.Spawn` started for that, as its last act, while it has one thread. It returns only when nothing
        /// was started, naming the step that failed; otherwise this process is the box's keeper, and exits as the
        /// program did. `doorLine`: the descriptor each door connection is sent on, whole (needed with a door).
        /// `proxyOut`: the descriptor the proxy's listener is sent on (needed with `.proxied`). Both are closed in
        /// the keeper. The Mac: ENOTSUP.
        public static func enter(_ plan: Plan, doorLine: Int32?, proxyOut: Int32?, program: [String]) -> Failure {
            System.enter(plan, doorLine: doorLine, proxyOut: proxyOut, program: program)
        }
    }
}
