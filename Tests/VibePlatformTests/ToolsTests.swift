import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Tools`: where git and the shells are on this system, and that the branch shell is what its users take it
/// for. Each child is read to the end of its output and reaped (`SpawnTests.output`); files are the test's own, in
/// the run's scratch folder, and none of them is run as a program itself (a script is given to /bin/sh): a file just
/// written can be "busy" to exec while another test's child is starting.
struct ToolsTests {
    static func write(_ text: String, to file: URL, mode: mode_t = 0o644) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try #require(chmod(file.path, mode) == 0)
    }

    // MARK: git

    @Test func gitIsAnAbsolutePathToAnExecutable() throws {
        let git = Platform.Tools.git
        #expect(git.hasPrefix("/"))
        #expect(Platform.Tools.isExecutableFile(git), "\(git)")
        #expect(FileManager.default.isExecutableFile(atPath: git))
        #expect(Platform.Tools.git == git)
        #if os(Linux)
        // The first on PATH in a folder only root can write.
        #expect(git == Platform.Tools.trustedGit(path: ProcessInfo.processInfo.environment["PATH"] ?? Platform.Tools.pathWhenUnset,
                                                 status: Platform.Tools.fileStatus))
        #else
        #expect(git == "/usr/bin/git")
        #endif
        // And it is git.
        let version = try SpawnTests.output(of: Platform.Spawn(executable: git, arguments: ["git", "--version"]))
        #expect(version.exit == 0)
        #expect(version.output.hasPrefix("git version"), "\(version.output)")
    }

    /// With no git on PATH, `git` is a path with nothing at it: `missing()` lists it, and running it fails as a
    /// program that isn't there does.
    @Test func aToolThatIsNotThereIsListedAndFailsToStart() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Platform.Tools.missing() == [])
        let nowhere = folder.appendingPathComponent("usr/bin/git").path
        #expect(Platform.Tools.missing(git: nowhere, shell: Platform.Tools.branchShell[0]) == ["git"])
        #expect(Platform.Tools.missing(git: nowhere, shell: "/bin/no-such-shell") == ["git", "/bin/no-such-shell"])
        #expect(Platform.Tools.missing(git: Platform.Tools.git, shell: "/bin/no-such-shell") == ["/bin/no-such-shell"])
        // A folder isn't a program, whatever its mode says.
        #expect(Platform.Tools.missing(git: folder.path, shell: "/bin/sh") == ["git"])
        #expect(Platform.Spawn(executable: nowhere, arguments: ["git", "--version"]).start() == .failure(Platform.Errno(code: ENOENT)))
        // What `git` is while none is found: an absolute path, so a spawn fails rather than looks around.
        #expect(Platform.Tools.absentGit.hasPrefix("/"))
    }

    /// The node's git is never one the user's account could have written (the security architecture document's S9):
    /// `trustedGit` passes over a folder of the user's, a root's folder anyone may write (a sticky one, as the system's
    /// temporary folder is), a root's folder below one of the user's, a folder that is a link, a `git` of the user's in
    /// a root's folder, a `git` that is a link or that nobody may run, and PATH's entries that aren't absolute or that
    /// name `..`, and resolves to the first `git` only root can change. Given only
    /// the user's folders, there is none. A table stands in for `lstat`: the real `git` is cached, read once with this
    /// process's PATH, so changing PATH here would prove nothing.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rule; the Mac's git is /usr/bin/git"))
    func theNodesGitIsNeverFromAFolderTheUserCanWrite() {
        let user: uid_t = 1000
        let folder = S_IFDIR, file = S_IFREG, link = S_IFLNK
        let table: [String: Platform.Tools.FileStatus] = [
            "/": (0, folder | 0o755, false),
            "/home": (0, folder | 0o755, false),
            "/home/u": (user, folder | 0o750, false),
            "/home/u/bin": (user, folder | 0o755, false),
            "/home/u/bin/git": (user, file | 0o755, true),
            "/home/u/root-owned": (0, folder | 0o755, false),
            "/home/u/root-owned/git": (0, file | 0o755, true),
            "/everyones": (0, folder | 0o1777, false),
            "/everyones/git": (0, file | 0o755, true),
            "/opt": (0, folder | 0o755, false),
            "/opt/shared": (0, folder | 0o775, false),
            "/opt/shared/git": (0, file | 0o755, true),
            "/opt/users-git": (0, folder | 0o755, false),
            "/opt/users-git/git": (user, file | 0o755, true),
            "/opt/writable-git": (0, folder | 0o755, false),
            "/opt/writable-git/git": (0, file | 0o777, true),
            "/opt/linked-git": (0, folder | 0o755, false),
            "/opt/linked-git/git": (0, link | 0o777, false),
            "/opt/plain": (0, folder | 0o755, false),
            "/opt/plain/git": (0, file | 0o644, true),
            "/bin": (0, link | 0o777, false),
            "/bin/git": (0, file | 0o755, true),
            "/usr": (0, folder | 0o755, false),
            "/usr/bin": (0, folder | 0o755, false),
            "/usr/bin/git": (0, file | 0o755, true),
            "/usr/local": (0, folder | 0o755, false),
            "/usr/local/bin": (0, folder | 0o755, false),
            "/usr/local/bin/git": (0, file | 0o755, true),
        ]
        var asked: [String] = []
        func status(_ path: String) -> Platform.Tools.FileStatus? {
            asked.append(path)
            return table[path]
        }
        let usersFirst = ["/home/u/bin", "/home/u/root-owned", "/everyones", "/opt/shared", "/opt/users-git", "/opt/writable-git",
                          "/opt/linked-git", "/opt/plain", "/bin", "bin", "", ".", "/usr/bin/../../home/u/bin", "/usr/bin/", "/usr/local/bin"]
        #expect(Platform.Tools.trustedGit(path: usersFirst.joined(separator: ":"), status: status) == "/usr/bin/git")
        // Each folder from the root down was read, without following links.
        #expect(asked.contains("/home/u") && asked.contains("/"))
        #expect(Platform.Tools.trustedGit(path: "/home/u/bin", status: status) == nil)
        #expect(Platform.Tools.trustedGit(path: "/home/u/bin:/home/u/root-owned:/everyones:/opt/shared:/bin", status: status) == nil)
        #expect(Platform.Tools.trustedGit(path: "", status: status) == nil)
        #expect(Platform.Tools.trustedGit(path: "/usr/local/bin:/usr/bin", status: status) == "/usr/local/bin/git")
        // Nothing to read is nothing trusted.
        #expect(Platform.Tools.trustedGit(path: "/usr/bin", status: { _ in nil }) == nil)
        // The real one, on this machine, is in such a folder too, and `missing()` would list it otherwise.
        #expect(Platform.Tools.trustedGit(path: "/usr/bin:/bin", status: Platform.Tools.fileStatus) == "/usr/bin/git")
        #expect(!Platform.Tools.isExecutableFile(Platform.Tools.absentGit))
    }

    /// The Mac's git is today's.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's form"))
    func theMacsGitIsStillUsrBinGit() {
        #expect(Platform.Tools.git == "/usr/bin/git")
        #expect(!Platform.Tools.branchCodeGetsOwnSession)
    }

    /// A path is looked for until it is found, and never again after.
    @Test func aPathIsFoundOnce() {
        let found = Platform.Tools.Found()
        var asked = 0
        #expect(found.path { asked += 1; return nil } == nil)
        #expect(found.path { asked += 1; return nil } == nil)
        #expect(found.path { asked += 1; return "/first/git" } == "/first/git")
        #expect(found.path { asked += 1; return "/second/git" } == "/first/git")
        #expect(asked == 3)
    }

    // MARK: find

    @Test func findReturnsNilForAToolThatIsNowhere() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "vibeswitcher-no-such-tool-\(UUID().uuidString.prefix(8))"
        #expect(Platform.Tools.find(name, path: nil) == nil)
        #expect(Platform.Tools.find(name) == nil)
        #expect(Platform.Tools.find(name, path: "\(folder.path):/usr/bin:/bin") == nil)
        #expect(Platform.Tools.find("sh", path: "") == nil)
        #expect(Platform.Tools.find("sh", path: folder.path) == nil)
        #expect(Platform.Tools.find("", path: nil) == nil)
        #expect(Platform.Tools.find("/no/such/folder/\(name)", path: nil) == nil)
        // A name with a slash is a path, never looked for on PATH; only an absolute one is taken.
        #expect(Platform.Tools.find("bin/sh", path: "/") == nil)
        // An entry that isn't absolute (the working directory's, the empty one) is never looked in.
        try Self.write("#!/bin/sh\n", to: folder.appendingPathComponent("here/tool"), mode: 0o755)
        #expect(Platform.Tools.find("tool", path: "here::.:\(folder.lastPathComponent)/here") == nil)
        #expect(Platform.Tools.find("tool", path: "here::\(folder.path)/here") == folder.path + "/here/tool")
    }

    @Test func findPrefersTheFirstOnThePathAndSkipsNonExecutables() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        func place(_ name: String) -> String { folder.appendingPathComponent(name).path }
        // In PATH's order: a file nobody may run, a folder of the tool's name, then two that can be run.
        try Self.write("#!/bin/sh\n", to: URL(fileURLWithPath: place("plain/tool")), mode: 0o644)
        try FileManager.default.createDirectory(atPath: place("folder/tool"), withIntermediateDirectories: true)
        try Self.write("#!/bin/sh\n", to: URL(fileURLWithPath: place("second/tool")), mode: 0o755)
        try Self.write("#!/bin/sh\n", to: URL(fileURLWithPath: place("third/tool")), mode: 0o700)
        try Self.write("#!/bin/sh\n", to: URL(fileURLWithPath: place("third/other")), mode: 0o755)
        let path = [place("absent"), place("plain"), place("folder"), place("second"), place("third")].joined(separator: ":")

        #expect(Platform.Tools.find("tool", path: path) == place("second/tool"))
        #expect(Platform.Tools.find("other", path: path) == place("third/other"))
        #expect(Platform.Tools.find("tool", path: [place("third") + "/", place("second")].joined(separator: ":")) == place("third/tool"))
        #expect(Platform.Tools.find("tool", path: [place("plain"), place("folder")].joined(separator: ":")) == nil)
        // An absolute name is checked as it is, whatever the path says.
        #expect(Platform.Tools.find(place("third/tool"), path: place("second")) == place("third/tool"))
        #expect(Platform.Tools.find(place("plain/tool"), path: path) == nil)
        #expect(Platform.Tools.find(place("folder/tool"), path: path) == nil)
        // A link is the file it leads to.
        try FileManager.default.createDirectory(atPath: place("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: place("links/tool"), withDestinationPath: place("third/tool"))
        try FileManager.default.createSymbolicLink(atPath: place("links/other"), withDestinationPath: place("nothing"))
        #expect(Platform.Tools.find("tool", path: place("links")) == place("links/tool"))
        #expect(Platform.Tools.find("other", path: place("links")) == nil)
        // The process's own PATH, when none is given.
        #expect(Platform.Tools.find("sh") == Platform.Tools.find("sh", path: ProcessInfo.processInfo.environment["PATH"]))
        #expect(Platform.Tools.find("sh")?.hasSuffix("/sh") == true)
    }

    // MARK: The shells

    /// The branch shell runs a command without reading a startup file: under a home whose every startup file prints
    /// "polluted", and with what makes Ubuntu's bash read ~/.bashrc for a plain `bash -c` (`SSH_CLIENT`: it takes
    /// itself for a command run over ssh), the output is the command's alone.
    @Test func branchShellStartsAShellThatReadsNoStartupFile() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        for file in [".bashrc", ".profile", ".bash_profile", ".bash_login", ".zshenv", ".zshrc", ".zprofile", ".zlogin"] {
            try Self.write("echo polluted\n", to: home.appendingPathComponent(file))
        }
        let shell = Platform.Tools.branchShell
        #expect(Platform.Tools.isExecutableFile(shell[0]), "\(shell[0])")
        let pipe = try SpawnTests.newPipe()
        var spawn = Platform.Spawn(executable: shell[0], arguments: shell + ["-c", "echo ok"])
        spawn.environment = ["HOME=\(home.path)", "ZDOTDIR=\(home.path)", "PATH=/usr/bin:/bin", "SSH_CLIENT=192.0.2.1 50000 22"]
        spawn.directory = home.path
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        // Whatever a startup file would say, on either output.
        spawn.stderr = .descriptor(pipe.writing)
        let ended = try SpawnTests.output(of: spawn) { spawn in
            defer { close(pipe.writing) }
            return spawn.start()
        }
        let errors = SpawnTests.everything(from: pipe.reading)
        close(pipe.reading)
        #expect(ended.output == "ok\n")
        #expect(errors == "")
        #expect(ended.exit == 0)
    }

    /// The wrapper around a branch's code is the branch shell running `"$@"; exit $?`: the shell stays, as the parent
    /// of what it runs (it never becomes the command), with the arguments it was given, which is how it is known
    /// (`BranchCode.isRunner`); and it ends as its command did.
    @Test func theBranchShellStaysTheParentOfItsCommandAndIsKnownByItsArguments() throws {
        let wrapper = Platform.Tools.branchShell + ["-c", "\"$@\"; exit $?", "vibeswitcher-branch-code"]
        // The command says who started it, then waits to be let go.
        let release = try SpawnTests.newPipe(), said = try SpawnTests.newPipe()
        var spawn = Platform.Spawn(executable: wrapper[0], arguments: wrapper + ["/bin/sh", "-c", "echo $PPID; read line; exit 7"])
        spawn.stdin = .descriptor(release.reading)
        spawn.stdout = .descriptor(said.writing)
        let started = spawn.start()
        close(release.reading)
        close(said.writing)
        defer { close(said.reading) }
        guard case .success(let pid) = started else {
            close(release.writing)
            Issue.record("the wrapper didn't start: \(started)")
            return
        }
        // One line: the command's parent.
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(said.reading, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        let parent = Int32(String(decoding: line, as: UTF8.self))
        let arguments = Platform.Processes.arguments(pid)
        close(release.writing)
        let ended = SpawnTests.ended(pid, output: said.reading)

        #expect(parent == pid, "the command's parent is \(String(describing: parent)), the wrapper \(pid)")
        #expect(arguments.starts(with: wrapper), "\(arguments)")
        #expect(arguments == wrapper + ["/bin/sh", "-c", "echo $PPID; read line; exit 7"])
        #expect(ended.exit == 7)
    }

    /// bash reads the file `BASH_ENV` names before a `-c` command, whatever its options: the environment a branch's
    /// code is started with names none on Linux, and is the caller's own on the Mac, whose zsh -f reads no such file.
    @Test func theBranchEnvironmentNamesNoStartupFile() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        let startup = folder.appendingPathComponent("startup")
        try Self.write("echo polluted\n", to: startup)
        let environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "BASH_ENV": startup.path, "ENV": startup.path, "KEPT": "1"]
        let passed = Platform.Tools.branchEnvironment(environment)
        #if os(Linux)
        #expect(passed == ["HOME": folder.path, "PATH": "/usr/bin:/bin", "KEPT": "1"])
        #else
        #expect(passed == environment)
        #endif
        #expect(Set(environment.keys).subtracting(passed.keys).isSubset(of: Set(Platform.Tools.branchShellStartupVariables)))
        #expect(Platform.Tools.branchEnvironment([:]) == [:])

        func said(in environment: [String: String]) throws -> String {
            let shell = Platform.Tools.branchShell
            var spawn = Platform.Spawn(executable: shell[0], arguments: shell + ["-c", "echo ok"])
            spawn.environment = environment.map { "\($0.key)=\($0.value)" }
            spawn.directory = folder.path
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            spawn.stderr = .path("/dev/null", flags: O_WRONLY)
            return try SpawnTests.output(of: spawn).output
        }
        #expect(try said(in: passed) == "ok\n")
        // The branch shell itself ignores the variable too (bash -p), filtered or not.
        #expect(try said(in: environment) == "ok\n")
    }

    /// Every way an environment makes a bash run something before its command, or in a command's place: a startup
    /// file (`BASH_ENV`), xtrace turned on from outside with a `PS4` that runs a command (`SHELLOPTS`), and an
    /// exported function named as the command (`BASH_FUNC_echo%%`). The branch shell takes none of them, and the
    /// branch's environment carries none on to a bash started below it. The last check is why: a bash without -p,
    /// given the same environment, runs all three.
    @Test func noVariableMakesTheBranchShellRunSomethingElse() throws {
        let folder = try TestScriptLinuxTests.scratch("tools-hostile")
        defer { try? FileManager.default.removeItem(at: folder) }
        let startup = folder.appendingPathComponent("startup")
        try Self.write("touch \(folder.path)/by-startup\n", to: startup)
        let hostile = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "KEPT": "1",
                       "BASH_ENV": startup.path, "ENV": startup.path,
                       "SHELLOPTS": "xtrace", "PS4": "$(touch \(folder.path)/by-trace)+ ",
                       "BASHOPTS": "extdebug", "BASH_XTRACEFD": "2",
                       "BASH_FUNC_echo%%": "() { touch \(folder.path)/by-function; builtin echo hijacked; }"]
        func run(_ arguments: [String], in environment: [String: String]) throws -> String {
            var spawn = Platform.Spawn(executable: arguments[0], arguments: arguments)
            spawn.environment = environment.map { "\($0.key)=\($0.value)" }
            spawn.directory = folder.path
            spawn.stdin = .path("/dev/null", flags: O_RDONLY)
            spawn.stderr = .path("/dev/null", flags: O_WRONLY)
            return try SpawnTests.output(of: spawn).output
        }
        func left() -> [String] {
            ["by-startup", "by-trace", "by-function"].filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
        let passed = Platform.Tools.branchEnvironment(hostile)
        #if os(Linux)
        #expect(passed == ["HOME": folder.path, "PATH": "/usr/bin:/bin", "KEPT": "1"])
        // The branch shell, even with the environment as it came.
        #expect(try run(Platform.Tools.branchShell + ["-c", "echo ok"], in: hostile) == "ok\n")
        #expect(left() == [])
        // A plain bash below it, with the branch's environment.
        #expect(try run(["/bin/bash", "-c", "echo ok"], in: passed) == "ok\n")
        #expect(left() == [])
        // Why: a plain bash with the environment as it came.
        #expect(try run(["/bin/bash", "-c", "echo ok"], in: hostile) == "hijacked\n")
        #expect(left() == ["by-startup", "by-trace", "by-function"])
        #else
        #expect(passed == hostile)
        #endif
    }

    /// The hook shim unsets these in a `/bin/sh` script, and on some systems sh is bash, where unsetting a read-only
    /// variable (SHELLOPTS, BASHOPTS) is an error that ends the script: the list holds neither, and a bash run as sh
    /// gets past the line.
    @Test func theVariablesAScriptUnsetsDontEndABashRunAsSh() throws {
        let names = Platform.Tools.branchShellVariablesAScriptUnsets
        #expect(!names.contains("SHELLOPTS") && !names.contains("BASHOPTS"))
        #if os(Linux)
        #expect(names == ["BASH_ENV", "ENV", "PS4", "BASH_XTRACEFD"])
        var spawn = Platform.Spawn(executable: "/bin/bash", arguments: ["/bin/bash", "--posix", "-c", "unset \(names.joined(separator: " ")); echo past"])
        spawn.environment = ["PATH=/usr/bin:/bin", "SHELLOPTS=posix"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stderr = .path("/dev/null", flags: O_WRONLY)
        #expect(try SpawnTests.output(of: spawn).output == "past\n")
        #else
        #expect(names == [])
        #endif
    }

    @Test func theLoginShellIsAShellOfThisSystem() {
        let shell = Platform.Tools.loginShell
        #expect(Platform.Tools.isExecutableFile(shell), "\(shell)")
        #if os(Linux)
        #expect(shell == "/bin/bash")
        #expect(Platform.Tools.branchShell == ["/bin/bash", "--noprofile", "--norc", "-p"])
        #else
        #expect(shell == "/bin/zsh")
        #expect(Platform.Tools.branchShell == ["/bin/zsh", "-f"])
        #endif
    }

    // MARK: Sessions

    /// The Mac's sessions get today's names, locale, login shell and spawns (`vibeswitcher-host/main.swift`'s list and
    /// `HostedSession.arguments` at `47636aaf`): nothing changes there.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's form"))
    func theMacsListIsTodays() {
        #expect(Platform.Tools.sessionEnvironmentNames == ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE",
                                                           "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"])
        #expect(Platform.Tools.sessionEnvironmentNever == [])
        #expect(Platform.Tools.sessionEnvironmentFixed == [:])
        #expect(Platform.Tools.defaultLocale == "en_US.UTF-8")
        #expect(Platform.Tools.sessionShellArguments(shell: "/bin/zsh", command: "claude", keepShell: false)
                == ["/bin/zsh", "-l", "-i", "-c", "claude"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/bin/zsh", command: nil, keepShell: false) == ["/bin/zsh", "-l", "-i"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/bin/zsh", command: "codex", keepShell: true)
                == ["/bin/zsh", "-l", "-i", "-c", "codex; exec '/bin/zsh' -l -i"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/opt/it's/sh", command: "x", keepShell: true)
                == ["/opt/it's/sh", "-l", "-i", "-c", "x; exec '/opt/it'\\''s/sh' -l -i"])
        #expect(Platform.Tools.spawnEnvironmentRefused(["LD_PRELOAD", "BASH_ENV", "SSH_AUTH_SOCK", "PS1", "SWIFT_BACKTRACE", "PATH"]) == [])
    }

    /// Linux's sessions: no agent socket, interop, bus, display, audio, runtime folder or test config folder; a
    /// backtracer-free fixed part; a plain bash whatever `SHELL` names.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's form"))
    func linuxSessionsGetNoAgentsAndAPlainBash() {
        let names = Platform.Tools.sessionEnvironmentNames
        #expect(names == ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE"])
        for never in Platform.Tools.sessionEnvironmentNever + ["XDG_RUNTIME_DIR"] { #expect(!names.contains(never), "\(never)") }
        #expect(Set(Platform.Tools.sessionEnvironmentNever) == ["SSH_AUTH_SOCK", "WSL_INTEROP", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY",
                                                                 "WAYLAND_DISPLAY", "PULSE_SERVER", "VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR"])
        #expect(Platform.Tools.sessionEnvironmentFixed == ["SWIFT_BACKTRACE": "enable=no"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/bin/sh", command: "claude", keepShell: false)
                == ["/bin/bash", "--noprofile", "--norc", "-c", "claude"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/usr/bin/zsh", command: nil, keepShell: false)
                == ["/bin/bash", "--noprofile", "--norc", "-i"])
        #expect(Platform.Tools.sessionShellArguments(shell: "/bin/sh", command: "codex", keepShell: true)
                == ["/bin/bash", "--noprofile", "--norc", "-c", "codex; exec /bin/bash --noprofile --norc -i"])
    }

    /// What a spawn other than the app's may not add, on Linux: the loader's variables, a bash's startup ones, its
    /// prompts and exported functions, the names never passed, and the fixed part's. Anything else may be added.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's form"))
    func aSpawnMayNotAddLoaderStartupOrNeverPassedVariables() {
        let refused = ["LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "GCONV_PATH", "GLIBC_TUNABLES", "BASH_ENV", "ENV", "SHELLOPTS",
                       "BASHOPTS", "PS4", "BASH_XTRACEFD", "PROMPT_COMMAND", "PS0", "PS1", "PS2", "BASH_FUNC_git%%", "SWIFT_BACKTRACE"]
            + Platform.Tools.sessionEnvironmentNever
        let allowed = ["PATH", "VIBESWITCHER_ROLE", "CLAUDE_CONFIG_DIR", "LANG", "TERM", "OLD_PWD", "XLD_PRELOAD", "PS3"]
        #expect(Platform.Tools.spawnEnvironmentRefused(allowed + refused) == refused)
        #expect(Platform.Tools.spawnEnvironmentRefused(allowed) == [])
    }

    /// The `LANG` a session gets when the host has none is a locale this system has: its codeset compared as glibc
    /// normalises one (lowercased, `-` and `_` dropped), so `C.UTF-8` is `locale -a`'s `C.utf8`.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "glibc's locales; the Mac's en_US.UTF-8 is always there"))
    func theLocaleASessionGetsIsInstalled() throws {
        func normalised(_ locale: String) -> (name: String, codeset: String) {
            let parts = locale.split(separator: ".", maxSplits: 1).map(String.init)
            let codeset = parts.count > 1 ? parts[1].lowercased().filter { $0 != "-" && $0 != "_" } : ""
            return (parts[0], codeset)
        }
        let locale = try #require(Platform.Tools.find("locale", path: "/usr/bin:/bin"))
        let listed = try SpawnTests.output(of: Platform.Spawn(executable: locale, arguments: ["locale", "-a"]))
        #expect(listed.exit == 0)
        let installed = listed.output.split(whereSeparator: \.isNewline).map { normalised(String($0)) }
        let wanted = normalised(Platform.Tools.defaultLocale)
        #expect(wanted.codeset == "utf8")
        #expect(installed.contains { $0 == wanted }, "\(Platform.Tools.defaultLocale) not in \(listed.output)")
    }

    // MARK: The developer tools

    @Test func developerToolsAreAskedOnlyOfAMac() {
        #if os(Linux)
        #expect(Platform.Tools.hasDeveloperTools() == nil)
        #expect(!Platform.Tools.developerToolsApply)
        #else
        #expect(Platform.Tools.hasDeveloperTools() != nil)
        #expect(Platform.Tools.developerToolsApply)
        #endif
    }

    /// The check itself, on stand-ins for `xcode-select -p`: one that names a folder, one that names none (as on a
    /// Mac without the tools: an error and status 2), one that prints nothing, one that isn't there, and one that
    /// never answers.
    @Test func aToolThatNamesAFolderIsThereAndASilentOneIsNotKnown() throws {
        let folder = try TestScriptLinuxTests.scratch("tools")
        defer { try? FileManager.default.removeItem(at: folder) }
        func standIn(_ name: String, _ script: String) throws -> [String] {
            let file = folder.appendingPathComponent(name)
            try Self.write(script, to: file)
            return ["/bin/sh", file.path, "-p"]
        }
        let names = try standIn("names", "[ \"$1\" = -p ] && echo /Library/Developer/CommandLineTools\n")
        let none = try standIn("none", "echo 'xcode-select: error: unable to get active developer directory' >&2\nexit 2\n")
        let silent = try standIn("silent", "exit 0\n")
        let hangs = try standIn("hangs", "exec tail -f /dev/null\n")
        #expect(Platform.Tools.namesAFolder(names, timeout: 60) == true)
        #expect(Platform.Tools.namesAFolder(none, timeout: 60) == false)
        #expect(Platform.Tools.namesAFolder(silent, timeout: 60) == false)
        #expect(Platform.Tools.namesAFolder([folder.appendingPathComponent("absent").path, "-p"], timeout: 60) == false)
        #expect(Platform.Tools.namesAFolder([folder.path, "-p"], timeout: 60) == false)
        #expect(Platform.Tools.namesAFolder(hangs, timeout: 0.2) == nil)

        #expect(Platform.Tools.run(names, timeout: 60) == .ended(status: 0, output: "/Library/Developer/CommandLineTools\n"))
        #expect(Platform.Tools.run(none, timeout: 60) == .ended(status: 2, output: ""))
        #expect(Platform.Tools.run(["/bin/sh", "-c", "printf partial; kill -TERM $$"], timeout: 60) == .ended(status: 128 + SIGTERM, output: "partial"))
        #expect(Platform.Tools.run(["/no/such/tool"], timeout: 60) == .failed)
        #expect(Platform.Tools.run([], timeout: 60) == .failed)
        // One that writes and then hangs is ended too, and what it started with it.
        #expect(Platform.Tools.run(["/bin/sh", "-c", "echo started; tail -f /dev/null & wait"], timeout: 0.2) == .timedOut)
    }
}
