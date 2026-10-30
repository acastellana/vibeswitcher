import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// What a start found missing, installed on the user's click (`ToolInstaller`), with an injected runner, a fake session
/// and a fake look: no test runs an installer, starts a real session for one or touches the network.
@MainActor
struct ToolInstallerTests {
    static let noClaude = LaunchPreflight.Problem(missing: [.agent(program: "claude", shell: "/bin/zsh")])
    static let noTools = LaunchPreflight.Problem(missing: [.commandLineTools])

    /// What the installer did.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _ran: [[String]] = []
        private var _looks = 0
        var ran: [[String]] { lock.withLock { _ran } }
        var looks: Int { lock.withLock { _looks } }
        func run(_ command: [String]) { lock.withLock { _ran.append(command) } }
        /// One look; its number (1 for the first).
        func look() -> Int { lock.withLock { _looks += 1; return _looks } }

        var asked: [(title: String, text: String, buttons: [String])] = []
        var sessions: [SpawnRequest] = []
        var selected: [UUID] = []
        var waiting: [String] = []
        var dismissed = 0
        var retries = 0
        var stop: (() -> Void)?
        var ended: ((HostSession.Exit) -> Void)?
    }

    /// An installer whose alerts answer `button` (0: Install, 1: Cancel), its runner `status`, and whose looks are
    /// `looks(n)` for the n-th.
    func installer(_ calls: Calls, button: Int, status: Int32 = 0,
                   looks: @escaping @Sendable (Int) -> LaunchPreflight.Problem?) -> (ToolInstaller, () -> LaunchPreflight.Problem?) {
        let installer = ToolInstaller(host: nil)
        installer.confirm = { title, text, buttons in calls.asked.append((title, text, buttons)); return buttons.count == 1 ? 0 : button }
        installer.run = { command in
            #expect(!Thread.isMainThread, "the installer ran on the main thread")
            calls.run(command)
            return (status, status == 0 ? "" : "xcode-select: note: Command line tools are already installed.")
        }
        installer.startSession = { request, started in
            calls.sessions.append(request)
            started(.success(UUID()))
        }
        installer.select = { calls.selected.append($0) }
        installer.ended = { _, then in calls.ended = then }
        installer.waiting = { text, stop in
            calls.waiting.append(text)
            calls.stop = stop
            return { calls.dismissed += 1 }
        }
        installer.interval = 0
        let preflight: () -> LaunchPreflight.Problem? = {
            #expect(!Thread.isMainThread, "the look ran on the main thread")
            return looks(calls.look())
        }
        return (installer, preflight)
    }

    @Test func commandLineToolsRunXcodeSelectThenTheLookIsPolledUntilTheyreThereAndTheLeadStarts() async {
        let calls = Calls()
        // Apple's installer is done at the third look.
        let (installer, preflight) = installer(calls, button: 0) { $0 < 3 ? Self.noTools : nil }
        installer.resolve(Self.noTools, preflight: preflight) { calls.retries += 1 }
        #expect(calls.asked.first?.buttons == ["Install", "Cancel"])
        #expect(calls.asked.first?.text.contains("/usr/bin/xcode-select --install") == true)
        #expect(await until { calls.retries == 1 })
        #expect(calls.ran == [["/usr/bin/xcode-select", "--install"]])
        #expect(calls.waiting == ["Installing Apple's Command Line Tools…"])
        #expect(calls.looks == 3 && calls.dismissed == 1)
        #expect(calls.sessions.isEmpty && calls.asked.count == 1)
    }

    @Test func theToolsBeingThereIsEnoughWhileClaudeCodeIsStillMissingTheStartOffersItNext() async {
        let calls = Calls()
        let both = LaunchPreflight.Problem(missing: Self.noClaude.missing + [.commandLineTools])
        let (installer, preflight) = installer(calls, button: 0) { $0 < 2 ? both : Self.noClaude }
        installer.resolve(both, preflight: preflight) { calls.retries += 1 }
        #expect(await until { calls.retries == 1 })
        #expect(calls.looks == 2)
    }

    @Test func pollingIsBoundedAndStopWaitingStopsIt() async {
        let calls = Calls()
        let (installer, preflight) = installer(calls, button: 0) { _ in Self.noTools }
        installer.polls = 4
        installer.resolve(Self.noTools, preflight: preflight) { calls.retries += 1 }
        #expect(await until { calls.asked.count == 2 })
        #expect(calls.asked.last?.title == "Apple's Command Line Tools aren't there yet.")
        #expect(calls.looks == 4 && calls.dismissed == 1 && calls.retries == 0)

        // Stop Waiting: no more looks, no start.
        let stopped = Calls()
        let (waiting, look) = self.installer(stopped, button: 0) { _ in Self.noTools }
        waiting.interval = 3600
        waiting.resolve(Self.noTools, preflight: look) { stopped.retries += 1 }
        #expect(await until { stopped.stop != nil })
        stopped.stop?()
        #expect(await until { stopped.dismissed == 1 })
        #expect(stopped.looks == 0 && stopped.retries == 0 && stopped.asked.count == 1)
    }

    @Test func xcodeSelectRefusingIsSaidAndNothingIsWaitedOn() async {
        let calls = Calls()
        let (installer, preflight) = installer(calls, button: 0, status: 1) { _ in Self.noTools }
        installer.resolve(Self.noTools, preflight: preflight) { calls.retries += 1 }
        #expect(await until { calls.asked.count == 2 })
        #expect(calls.asked.last?.title == "Apple's installer didn't open.")
        #expect(calls.asked.last?.text.contains("already installed") == true)
        #expect(calls.waiting.isEmpty && calls.looks == 0 && calls.retries == 0)
    }

    @Test func claudeCodeInstallsInAVisibleSessionAndTheLeadStartsWhenItExitsZero() async {
        let calls = Calls()
        let (installer, preflight) = installer(calls, button: 0) { _ in nil }
        installer.resolve(Self.noClaude, preflight: preflight) { calls.retries += 1 }
        #expect(calls.asked.first?.text.contains("curl -fsSL https://claude.ai/install.sh | bash") == true)
        let request = calls.sessions.first
        #expect(calls.sessions.count == 1)
        #expect(request?.label == "Install Claude Code")
        #expect(request?.command == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(request?.keepShell == false && request?.agent == nil && request?.env.isEmpty == true)
        #expect(calls.selected.count == 1)
        #expect(calls.ran.isEmpty && calls.looks == 0)
        calls.ended?(HostSession.Exit(status: 0, at: Date()))
        #expect(await until { calls.retries == 1 })
        #expect(calls.looks == 1 && calls.asked.count == 1)
    }

    @Test func claudeCodeFailingLeavesItsSessionAndSaysSo() async {
        let calls = Calls()
        let (installer, preflight) = installer(calls, button: 0) { _ in Self.noClaude }
        installer.resolve(Self.noClaude, preflight: preflight) { calls.retries += 1 }
        calls.ended?(HostSession.Exit(status: 22, at: Date()))
        #expect(calls.asked.last?.title == "Claude Code's installer failed.")
        #expect(calls.asked.last?.text.contains("exited 22") == true)
        #expect(calls.asked.last?.text.contains("output stays in the “Install Claude Code” session") == true)
        #expect(calls.looks == 0 && calls.retries == 0)

        // Exit 0 (curl's failure piped into bash ends 0 too), and still no claude: said, no start.
        let quiet = Calls()
        let (again, look) = self.installer(quiet, button: 0) { _ in Self.noClaude }
        again.resolve(Self.noClaude, preflight: look) { quiet.retries += 1 }
        quiet.ended?(HostSession.Exit(status: 0, at: Date()))
        #expect(await until { quiet.asked.count == 2 })
        #expect(quiet.asked.last?.title == "Claude Code still isn't found.")
        #expect(quiet.looks == 1 && quiet.retries == 0)
    }

    @Test func aCancelledInstallChangesNothing() async {
        for problem in [Self.noTools, Self.noClaude] {
            let calls = Calls()
            let (installer, preflight) = installer(calls, button: 1) { _ in nil }
            installer.resolve(problem, preflight: preflight) { calls.retries += 1 }
            #expect(calls.asked.count == 1 && calls.asked.first?.buttons == ["Install", "Cancel"])
            #expect(calls.ran.isEmpty && calls.sessions.isEmpty && calls.waiting.isEmpty && calls.looks == 0 && calls.retries == 0)
        }
    }

    @Test func aPieceNoInstallFixesIsOnlyExplained() {
        let calls = Calls()
        let problem = LaunchPreflight.Problem(missing: [.helper(name: "vibeswitcher-mcp", path: "/App/vibeswitcher-mcp")])
        let (installer, preflight) = installer(calls, button: 0) { _ in nil }
        installer.resolve(problem, preflight: preflight) { calls.retries += 1 }
        #expect(calls.asked.count == 1 && calls.asked.first?.buttons == ["OK"])
        #expect(calls.asked.first?.text == "The lead wasn't started. " + problem.text)
        #expect(calls.ran.isEmpty && calls.sessions.isEmpty && calls.looks == 0 && calls.retries == 0)
    }

    @Test func outsideTheAppTheRealRunnerAndSessionRefuse() {
        // The test run has no bundle of its own: even the real runner and host spawn install nothing.
        #expect(ToolInstaller.runProgram(ToolInstall.commandLineToolsCommand).status != 0)
        let installer = ToolInstaller(host: HostClient(socketPath: "/nonexistent/h.sock", appKey: { nil }))
        var failed: String?
        installer.startSession(SpawnRequest(cwd: "/", command: ToolInstall.claudeCodeCommand, env: [:], cols: 80, rows: 24, keepShell: false,
                                            label: ToolInstall.claudeCodeSession, agent: nil)) {
            if case .failure(let error) = $0 { failed = error.message }
        }
        #expect(failed == "Only VibeSwitcher.app runs an installer.")
    }
}

/// A flag set on one thread and read on another.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
