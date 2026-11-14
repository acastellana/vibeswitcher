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
            // -p: bash then takes no function from the environment and ignores SHELLOPTS, BASHOPTS, BASH_ENV and ENV
            // there, the ways an environment makes a bash run something before its command (zsh -f has none).
            return ["/bin/bash", "--noprofile", "--norc", "-p"]
            #endif
        }

        /// The variables of an environment through which a bash runs something before its command, or as it traces
        /// one: `BASH_ENV` and `ENV` name a file it reads, `SHELLOPTS` and `BASHOPTS` turn options on (xtrace among
        /// them), and under xtrace `PS4` is expanded, commands in it run, before each command, to `BASH_XTRACEFD`.
        /// `branchShell` ignores them itself (`-p`); they are taken out as well so that a bash the branch's code starts
        /// in turn doesn't get them from here. The Mac: none (zsh `-f` has no such variable).
        public static var branchShellStartupVariables: [String] {
            #if canImport(Darwin)
            return []
            #else
            return ["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4", "BASH_XTRACEFD"]
            #endif
        }

        /// Those of `branchShellStartupVariables` a shell script can `unset` in whatever shell `/bin/sh` is: not
        /// `SHELLOPTS` and `BASHOPTS`, which are read-only in a bash, where unsetting one is an error that ends a
        /// script run as sh. Left in, those two can only turn options on in a bash started further down; with `PS4`
        /// and `BASH_XTRACEFD` gone, tracing runs nothing and writes to stderr.
        public static var branchShellVariablesAScriptUnsets: [String] {
            branchShellStartupVariables.filter { $0 != "SHELLOPTS" && $0 != "BASHOPTS" }
        }

        /// What the name of an exported bash function starts with in an environment (`BASH_FUNC_name%%`): a bash
        /// that isn't started with `-p` defines each as it starts, and one named as a command the branch's code runs
        /// would run in its place. The Mac: nil.
        public static var branchShellFunctionPrefix: String? {
            #if canImport(Darwin)
            return nil
            #else
            return "BASH_FUNC_"
            #endif
        }

        /// The environment a branch's code is started with, made of `environment`: the same without
        /// `branchShellStartupVariables` and without exported functions (`branchShellFunctionPrefix`). The Mac:
        /// `environment` as it is.
        public static func branchEnvironment(_ environment: [String: String]) -> [String: String] {
            let dropped = branchShellStartupVariables
            let functions = branchShellFunctionPrefix
            if dropped.isEmpty && functions == nil { return environment }
            return environment.filter { entry in
                !dropped.contains(entry.key) && !(functions.map { entry.key.hasPrefix($0) } ?? false)
            }
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

        // MARK: Sessions

        /// The variables of the host's own environment a session's program is started with (the security
        /// architecture document's S10). The Mac: what a fresh Terminal session would inherit from launchd, the login
        /// shell adding the rest, as always (`SSH_AUTH_SOCK` among them). Linux: what an agent and the user's tools
        /// need, and not the user's keys to other systems: no `SSH_AUTH_SOCK` (the gpg-agent's ssh socket),
        /// `WSL_INTEROP`, `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `PULSE_SERVER` or
        /// `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` (`sessionEnvironmentNever`), and no `XDG_RUNTIME_DIR` either, which
        /// points at the gpg-agent, the bus and WSLg's sockets and which no agent needs. Leaving them out stops a slip
        /// only: each of those sockets is found by a fixed path too.
        public static var sessionEnvironmentNames: [String] {
            #if canImport(Darwin)
            return ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK",
                    "__CF_USER_TEXT_ENCODING"]
            #else
            return ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE"]
            #endif
        }

        /// The names a session never gets from the host, and that a spawn other than the app's may not add
        /// (`spawnEnvironmentRefused`). The Mac: none.
        public static var sessionEnvironmentNever: [String] {
            #if canImport(Darwin)
            return []
            #else
            return ["SSH_AUTH_SOCK", "WSL_INTEROP", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY", "PULSE_SERVER",
                    "VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"]
            #endif
        }

        /// Variables every session's program, and every parser, is started with whatever the host's environment
        /// says; a spawn other than the app's may not set them (`spawnEnvironmentRefused`). The Mac: none. Linux:
        /// `SWIFT_BACKTRACE=enable=no`, so a Swift program that crashes there doesn't start the backtracer, which
        /// reads the crashed process's memory.
        public static var sessionEnvironmentFixed: [String: String] {
            #if canImport(Darwin)
            return [:]
            #else
            return ["SWIFT_BACKTRACE": "enable=no"]
            #endif
        }

        /// A session's `LANG` when the host's environment has none. The Mac: `en_US.UTF-8`, as always. Linux:
        /// `C.UTF-8`, which glibc always has (`en_US.UTF-8` is often not installed: `locale -a` here lists C, C.utf8
        /// and POSIX).
        public static var defaultLocale: String {
            #if canImport(Darwin)
            return "en_US.UTF-8"
            #else
            return "C.UTF-8"
            #endif
        }

        /// The program a session runs and its arguments, its first word the program: `command` given to a shell, then
        /// that shell kept, interactive, where `keepShell`; with no command, the shell alone.
        ///
        /// The Mac: `$SHELL -l -i [-c command]`, as always: an interactive login shell reads both `.zprofile` and
        /// `.zshrc`, so the agent gets the PATH it has in Terminal (nvm, Homebrew…); kept, `exec '$SHELL' -l -i`.
        ///
        /// Linux: `/bin/bash --noprofile --norc [-c command]`, whatever `shell` names: a plain shell, which runs none of
        /// the user's startup files (a login, interactive bash runs `.profile` and `.bashrc` and whatever they source:
        /// tools that read per-folder config from the worktree among them). The PATH is the host's, which holds what
        /// workers build with (the security architecture document's S10). Kept, `exec /bin/bash --noprofile --norc
        /// -i`; with no command, `/bin/bash --noprofile --norc -i`.
        public static func sessionShellArguments(shell: String, command: String?, keepShell: Bool) -> [String] {
            #if canImport(Darwin)
            guard let command else { return [shell, "-l", "-i"] }
            let line = keepShell ? "\(command); exec \(quoted(shell)) -l -i" : command
            return [shell, "-l", "-i", "-c", line]
            #else
            let plain = ["/bin/bash", "--noprofile", "--norc"]
            guard let command else { return plain + ["-i"] }
            let line = keepShell ? "\(command); exec \(plain.joined(separator: " ")) -i" : command
            return plain + ["-c", line]
            #endif
        }

        /// Those of `names` that a spawn from a caller other than the app may not set in a session's environment
        /// (`SpawnRequest.env`), in `names`' order: the loader's (`LD_*`, `GCONV_PATH`, `GLIBC_TUNABLES`), those
        /// through which a bash runs something before or around its command (`branchShellStartupVariables`,
        /// `PROMPT_COMMAND`, exported functions, and the prompts `PS0`, `PS1` and `PS2`, whose `$(…)` an interactive
        /// bash runs, `--norc` or not: a session with no command, or a kept shell, is one), `sessionEnvironmentNever`,
        /// and `sessionEnvironmentFixed`'s names (the request's `env` goes on top of the host's). The Mac: none, as
        /// always.
        ///
        /// A guard against a slip in `env` only: the same caller's `command` is a bash line, which can set any of
        /// these itself (`LD_PRELOAD=… claude`, `export …`), so this is no limit on what a session can have the host
        /// start.
        public static func spawnEnvironmentRefused(_ names: [String]) -> [String] {
            #if canImport(Darwin)
            return []
            #else
            let refused = Set(branchShellStartupVariables + sessionEnvironmentNever + Array(sessionEnvironmentFixed.keys)
                              + ["GCONV_PATH", "GLIBC_TUNABLES", "PROMPT_COMMAND", "PS0", "PS1", "PS2"])
            return names.filter { name in
                refused.contains(name) || name.hasPrefix("LD_") || branchShellFunctionPrefix.map { name.hasPrefix($0) } == true
            }
            #endif
        }

        // MARK: Roles' launch

        /// Claude Code permission rules every role's session is refused on this system, the lead's included, on top
        /// of the rules `LeadLaunch.deny` gives on both (the security architecture document's S10). The Mac: none.
        /// Linux: the tracers (`strace`, `ltrace`, `gdbserver`, `perf`); the user's manager and timers (`systemctl
        /// --user`, `systemd-run`, `loginctl`, `crontab`, `at`): an agent "restarting the node to test it" would end
        /// every session and the vault; Windows' programs (`wsl.exe`, `cmd.exe`, `powershell.exe`); `gh` and git's
        /// credential helpers; edits under the user's units and the manager's environment, and under the node's own
        /// folders (`~/.vibeswitcher/v2`, `~/.vibeswitcher/lead`); and reads and edits under `/mnt/c` (as `//mnt/c`:
        /// a rule's path that starts with one `/` is taken from the settings file's folder, `//` from the root).
        ///
        /// They stop a slip, not a worker that tries: a rule binds the tool it names, and a shell reaches each of these
        /// in other spellings.
        public static var roleDenyRules: [String] {
            #if canImport(Darwin)
            return []
            #else
            let commands = ["strace", "ltrace", "gdbserver", "perf", "systemctl --user", "systemd-run", "loginctl", "crontab", "at",
                            "wsl.exe", "cmd.exe", "powershell.exe", "gh", "git credential"]
            var rules = commands.map { "Bash(\($0):*)" } + ["Bash(git -c credential*)"]
            for folder in ["~/.config/systemd", "~/.config/environment.d", "~/.vibeswitcher/v2", "~/.vibeswitcher/lead"] {
                rules += ["Edit(\(folder)/**)", "Write(\(folder)/**)"]
            }
            return rules + ["Read(//mnt/c/**)", "Edit(//mnt/c/**)", "Write(//mnt/c/**)"]
            #endif
        }

        /// Whether the lead's session is refused the debuggers too (`LeadLaunch.debuggers`, which workers and
        /// verifiers always are). The Mac: no, as always (its debuggers ask for the user's password in a dialog, which
        /// a lead's own runs don't reach). Linux: yes, with no Yama any process of the user may trace another.
        public static var leadGetsTracerRules: Bool {
            #if canImport(Darwin)
            return false
            #else
            return true
            #endif
        }

        /// Whether a role's launch settings (its `--settings` and `--mcp-config`) go to `claude` as JSON on its command
        /// line, and its prompt too while the command fits one argument, rather than as files in its run folder,
        /// which a worker could rewrite between their writing and `claude`'s read. The Mac: no, files as always.
        /// Linux: yes (the security architecture document's S10).
        public static var roleSettingsInline: Bool {
            #if canImport(Darwin)
            return false
            #else
            return true
            #endif
        }

        /// `text` as one word for a POSIX shell, in single quotes.
        static func quoted(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        /// What a shell command runs right after `command -v "$1"` so that its exit status says a name the shell
        /// doesn't know as 1. POSIX lets that lookup exit with any status but 0: zsh and bash say 1, and dash
        /// (Ubuntu's /bin/sh) 127, the status a shell with no `command` at all ends with too. The Mac: nothing (its
        /// login shell is zsh, and 1 is missing, any other status not known). Linux: when the lookup fails and the
        /// shell has `command` (`command -v command` answers), it exits 1; otherwise with the status it had.
        public static var commandLookupEnd: String {
            #if canImport(Darwin)
            return ""
            #else
            return " || { command -v command >/dev/null 2>&1 && exit 1; }"
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
            // Close-on-exec from its making on Linux (pipe2); the Mac's is pipe, then FD_CLOEXEC, as it always was.
            guard !command.isEmpty, Sys.pipeClosedOnExec(&ends) == 0 else { return .failed }
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
