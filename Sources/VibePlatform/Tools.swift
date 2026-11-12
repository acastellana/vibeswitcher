import Foundation

extension Platform {
    /// The programs the shared code runs by a path of its own choosing, where the systems keep them: the Mac has its
    /// git and its zsh at fixed paths; a Linux machine has git wherever its PATH says, and bash for zsh.
    public enum Tools {
        /// The git VibeSwitcher runs. The Mac: `/usr/bin/git`. Linux: the first `git` on this process's PATH (`find`),
        /// looked for until it is found and the same from then on, whatever PATH becomes; while there is none,
        /// `/usr/bin/git`, where it usually is: run, that fails with ENOENT, and `missing()` lists it.
        public static var git: String {
            #if canImport(Darwin)
            return "/usr/bin/git"
            #else
            return foundGit.path { find("git", path: nil) } ?? absentGit
            #endif
        }

        /// The shell a branch's code is run under, with the options that keep it from reading a startup file: argv's
        /// start, `-c` and the command after it. The Mac: zsh `-f` (it reads /etc/zshenv, the system's, and nothing of
        /// the user's). Linux: bash `--noprofile --norc`, which reads neither a profile nor ~/.bashrc (Ubuntu's bash
        /// reads that one even for a `-c` when it thinks it was started over ssh). bash still reads the file the
        /// environment's `BASH_ENV` names, when it has one: nothing on its command line turns that off but `-p`,
        /// which changes more.
        ///
        /// The wrapper around a branch's code (`BranchCode.wrapper`) and the check that knows it by its arguments
        /// (`isRunner`) are both made of this one value, so a process the wrapper started is known on either system.
        public static var branchShell: [String] {
            #if canImport(Darwin)
            return ["/bin/zsh", "-f"]
            #else
            return ["/bin/bash", "--noprofile", "--norc"]
            #endif
        }

        /// The variables of an environment that name a file `branchShell` reads as it starts, whatever its options.
        /// The Mac: none (zsh `-f` reads no file a variable names). Linux: `BASH_ENV`, whose file bash reads before a
        /// `-c` command, and `ENV`, the same for a bash started as sh.
        public static var branchShellStartupVariables: [String] {
            #if canImport(Darwin)
            return []
            #else
            return ["BASH_ENV", "ENV"]
            #endif
        }

        /// The environment a branch's code is started with, made of `environment`: the same without
        /// `branchShellStartupVariables`, so the branch shell reads no startup file there either. The Mac: `environment`
        /// as it is. What the shell starts has the same environment, so none of it reads such a file.
        public static func branchEnvironment(_ environment: [String: String]) -> [String: String] {
            let dropped = branchShellStartupVariables
            return dropped.isEmpty ? environment : environment.filter { !dropped.contains($0.key) }
        }

        /// The login shell for a user whose `SHELL` isn't set. As a login shell (`-l`) zsh reads ~/.zprofile, and
        /// bash ~/.bash_profile or ~/.profile: not ~/.bashrc, unless one of those reads it.
        public static var loginShell: String {
            #if canImport(Darwin)
            return "/bin/zsh"
            #else
            return "/bin/bash"
            #endif
        }

        /// Where the program `name` is: the first folder of `path` (folders with ":" between them, as PATH has them;
        /// nil: this process's PATH) that holds a file of that name this process may run, as that folder and the
        /// name. A folder that isn't an absolute path is passed over (PATH's empty entry is the working directory:
        /// never looked in). A `name` that is itself an absolute path is that path when it can be run; one with a
        /// slash in it otherwise is nil, and so is an empty one. A link counts as the file it leads to.
        public static func find(_ name: String, path: String? = nil) -> String? {
            guard !name.isEmpty else { return nil }
            guard !name.contains("/") else { return name.hasPrefix("/") && isExecutableFile(name) ? name : nil }
            let folders = path ?? getenv("PATH").map { String(cString: $0) } ?? pathWhenUnset
            for folder in folders.split(separator: ":").map(String.init) where folder.hasPrefix("/") {
                let candidate = folder.hasSuffix("/") ? folder + name : folder + "/" + name
                if isExecutableFile(candidate) { return candidate }
            }
            return nil
        }

        /// What a node can't work without and this machine doesn't have, checked as it starts: `git` when none is
        /// on PATH (the Mac: at /usr/bin/git), and the branch shell, by its path, when it isn't there. Empty: both
        /// are there.
        public static func missing() -> [String] {
            missing(git: git, shell: branchShell[0])
        }

        /// Whether Apple's developer tools are installed, as `xcode-select -p` tells: it names a developer folder
        /// (true), or it names none or isn't there (false). nil: not known (it didn't answer in 10 seconds), and on
        /// Linux always: there is no such thing there, and a caller passes its check over. It is asked with this
        /// process's environment, `DEVELOPER_DIR` included, as /usr/bin/git's stub is. Blocks while it asks.
        public static func hasDeveloperTools() -> Bool? {
            #if canImport(Darwin)
            return namesAFolder(["/usr/bin/xcode-select", "-p"], timeout: 10)
            #else
            return nil
            #endif
        }

        /// Whether this system has such tools to ask after at all: the Mac. false on Linux, where
        /// `hasDeveloperTools()` is always nil. For a caller that asks `xcode-select` itself, at a path and with a
        /// time of its own (`LaunchPreflight`): it knows without starting anything that its check is passed over.
        public static var developerToolsApply: Bool {
            #if canImport(Darwin)
            return true
            #else
            return false
            #endif
        }

        // MARK: Internals

        /// What `git` is while none is found.
        static let absentGit = "/usr/bin/git"
        /// The folders looked in when the process has no PATH at all.
        static let pathWhenUnset = "/usr/local/bin:/usr/bin:/bin"

        /// Whether `path` is a file (not a folder) this process may run.
        static func isExecutableFile(_ path: String) -> Bool {
            var info = stat()
            return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
        }

        static func missing(git: String, shell: String) -> [String] {
            var missing: [String] = []
            if !isExecutableFile(git) { missing.append("git") }
            if !isExecutableFile(shell) { missing.append(shell) }
            return missing
        }

        /// A path found once: asked again only while the answer is "nowhere".
        final class Found: @unchecked Sendable {
            private let lock = NSLock()
            private var found: String?

            func path(_ look: () -> String?) -> String? {
                lock.lock()
                defer { lock.unlock() }
                if found == nil { found = look() }
                return found
            }
        }

        private static let foundGit = Found()

        /// How a tool run by `run` came out.
        enum Ran: Equatable {
            /// It ended by itself: its exit status (128 and the signal's number for one a signal ended), and what
            /// it wrote to its stdout.
            case ended(status: Int32, output: String)
            /// It was still writing, or silent, after the time it was given, and was ended.
            case timedOut
            /// It couldn't be started.
            case failed
        }

        /// Runs `command` (a path, then its arguments) with this process's environment, nothing on its stdin and
        /// its stderr dropped, and waits for it: until its output ends, for `timeout` seconds at most (then it and
        /// its process group are killed).
        static func run(_ command: [String], timeout: TimeInterval) -> Ran {
            var ends: [Int32] = [-1, -1]
            guard !command.isEmpty, pipe(&ends) == 0 else { return .failed }
            for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            var spawn = Platform.Spawn(executable: command[0], arguments: command)
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            spawn.stdout = .descriptor(ends[1])
            spawn.stderr = .path("/dev/null", flags: O_WRONLY)
            spawn.group = .ownGroup
            let started = spawn.start()
            close(ends[1])
            defer { close(ends[0]) }
            guard case .success(let pid) = started else { return .failed }

            // The clock runs while the output is read; once that has ended the child is only waited for.
            let reading = Reading()
            let late = DispatchWorkItem { reading.endIfStillReading { kill(-pid, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: late)
            var output = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4_096)
            while true {
                let got = read(ends[0], &chunk, chunk.count)
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { break }
                output.append(contentsOf: chunk[0..<got])
            }
            let timedOut = reading.finish()
            late.cancel()
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            if timedOut { return .timedOut }
            let signal = status & 0x7f
            return .ended(status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, output: String(decoding: output, as: UTF8.self))
        }

        /// Whether the time ran out while a tool's output was read: the one that ends it does so only before the
        /// reading finished, so never once the child may have been waited for and its pid given to another.
        private final class Reading: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            private var ended = false

            func endIfStillReading(_ end: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                ended = true
                end()
            }

            /// The reading is over; true when the tool was ended for its time.
            func finish() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                finished = true
                return ended
            }
        }

        /// Whether `command` (`xcode-select -p`, or a test's stand-in) names a folder: it is there, exits 0 and
        /// prints something. nil when it doesn't answer in `timeout` seconds.
        static func namesAFolder(_ command: [String], timeout: TimeInterval) -> Bool? {
            guard let program = command.first, isExecutableFile(program) else { return false }
            switch run(command, timeout: timeout) {
            case .timedOut: return nil
            case .failed: return false
            case .ended(let status, let output):
                return status == 0 && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
}
