import Foundation
import Testing
@testable import VibeCore

/// One variable of the login shell (`LoginShellVariable`), read through a fake shell: a script in a scratch folder that
/// takes the session's `-l -i`, prints what a .zshrc might (a banner, an export, a wait, an early exit), then runs the
/// command with /bin/sh. Never the user's shell; the variable's name is made up, so nothing the test's own environment
/// holds can answer.
struct LoginShellVariableTests {
    static let name = "VIBESWITCHER_TEST_LOGIN_VARIABLE"
    /// The reads' timeout where the shell ends on its own: a ceiling, not a wait (its exit ends the read). The read's
    /// default, 5 s, is counted from the spawn, and on a loaded Mac the fake shell's three execs (sh, sh, printenv)
    /// took longer than that: a shell that would have answered was read as timed out.
    static let budget: TimeInterval = 120
    let scratch = Scratch()

    /// A fake `$SHELL` whose startup is `rc` (sh), then the command as a login shell would run it.
    func shell(_ rc: String) throws -> String {
        let folder = scratch.url("login-shell")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("fakesh").path
        let script = """
            #!/bin/sh
            [ "$1" = -l ] && [ "$2" = -i ] && [ "$3" = -c ] || exit 64
            shift 2
            unset \(Self.name)
            \(rc)
            exec /bin/sh "$@"
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    @Test func theArgumentsAreTheSessionsWithTheNameApart() {
        let argv = LoginShellVariable.arguments(shell: "/bin/zsh", name: Self.name)
        #expect(Array(argv.prefix(4)) == ["/bin/zsh", "-l", "-i", "-c"])
        #expect(argv.suffix(2) == ["zsh", Self.name])
        #expect(!argv[4].contains(Self.name))
    }

    @Test func aBannerBeforeTheValueIsLeftOut() throws {
        let shell = try shell("echo 'Welcome back!'; printf 'no newline'; \(Self.name)='sk_from_rc'; export \(Self.name)")
        #expect(LoginShellVariable.read(Self.name, shell: shell, timeout: Self.budget) == .found("sk_from_rc"))
    }

    @Test func unsetEmptyOrAnExitIsNotFound() throws {
        #expect(LoginShellVariable.read(Self.name, shell: try shell("echo hi"), timeout: Self.budget) == .unset)
        #expect(LoginShellVariable.read(Self.name, shell: try shell("\(Self.name)=; export \(Self.name)"), timeout: Self.budget) == .unset)
        // The startup files exit before the command: nothing after the marker.
        #expect(LoginShellVariable.read(Self.name, shell: try shell("echo bye; exit 3"), timeout: Self.budget) == .failed)
        #expect(LoginShellVariable.read(Self.name, shell: scratch.url("no-such-shell").path, timeout: Self.budget) == .failed)
        // A name that isn't one runs nothing.
        #expect(LoginShellVariable.read("A; touch x", shell: try shell("exit 9"), timeout: Self.budget) == .unset)
    }

    /// A .zshrc that waits (on a prompt, a network mount): stopped after the timeout, with what it started. The timeout
    /// is counted from the spawn, so it can end before the shell has started at all (on a loaded Mac that took over 5 s):
    /// then there's nothing of it to look for, and the read is tried again with twice the timeout, until the shell had
    /// written its pid when the timeout ended.
    @Test func aShellThatWaitsIsStopped() throws {
        let pidFile = scratch.url("shell-pid").path
        let shell = try shell("echo $$ > '\(pidFile)'; echo starting; /bin/sleep 600; \(Self.name)=late; export \(Self.name)")
        var timeout: TimeInterval = 1
        var pid: Int32?
        while pid == nil, timeout <= 64 {
            let started = Date()
            #expect(LoginShellVariable.read(Self.name, shell: shell, timeout: timeout) == .timedOut)
            // Stopped, not waited for: far under its sleep.
            #expect(Date().timeIntervalSince(started) < timeout + 60)
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            timeout *= 2
        }
        let shellPid = try #require(pid, "the fake shell never started within a 64 s timeout")
        // The shell and its sleep are gone.
        #expect(kill(shellPid, 0) != 0)
        #expect(!ProcessTable.snapshot().values.contains { $0.ppid == shellPid })
    }

    @Test func theOutcomeIsWhatFollowsTheMarker() {
        let marker = LoginShellVariable.marker
        #expect(LoginShellVariable.outcome(status: 0, output: "banner\n\(marker)sk_1\n") == .found("sk_1"))
        #expect(LoginShellVariable.outcome(status: 1, output: "banner\n\(marker)") == .unset)
        #expect(LoginShellVariable.outcome(status: 0, output: "sk_1") == .failed)
        #expect(LoginShellVariable.outcome(status: 2, output: "\(marker)sk_1") == .failed)
    }
}
