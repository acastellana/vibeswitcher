import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The app's side of shells that tidy themselves away (`ShellTidier`): which sessions it ends at each look, what it
/// keeps of the shells typed into, and the sidebar's Close Finished Shells…. Made-up sessions and a clock the test
/// moves; `end` only records. The last test runs it on the app's own client and a scratch session host.
@MainActor
@Suite(.serialized)
struct ShellTidierTests {
    let temp = Scratch()
    static let start = Date(timeIntervalSince1970: 1_794_300_000)
    /// The launch line of a Run card's shell, and the one before it said how the command ended.
    static let runLine = ShellAsk.spawnRequest(ShellRequest(session: UUID().uuidString, cwd: "/work/example", command: "npm ci", label: "", createdAt: start)).command ?? ""
    static let oldRunLine = "eval \"$VIBESWITCHER_SHELL_COMMAND\""

    final class Seen {
        var now = ShellTidierTests.start
        var sessions: [HostSession] = []
        var busy: Set<UUID> = []
        var ended: [UUID] = []
        var asked: [ShellTidier.Question] = []
        var answer = true
    }

    /// A session as the host lists it. `state`: what its launch line reported `ago` before the test's start (nil:
    /// nothing, the command still runs).
    static func session(_ label: String, command: String? = runLine, state: ProgramStatus.State? = .done, app: String? = ShellTidy.app,
                        ago: TimeInterval = 0, agent: String? = nil, exit: HostSession.Exit? = nil) -> HostSession {
        HostSession(id: UUID(), tty: "ttys900", childPID: 1, cwd: "/work/example", command: command, label: label, agent: agent, title: "",
                    startedAt: start.addingTimeInterval(-ago - 60), cols: 80, rows: 24, exit: exit,
                    programStatus: state.map { ProgramStatus(state: $0, app: app, since: start.addingTimeInterval(-ago)) })
    }

    func tidier(_ seen: Seen, file: URL? = nil) -> ShellTidier {
        let tidier = ShellTidier(file: file ?? temp.url("used").appendingPathComponent("used.json"), now: { seen.now }, log: { _ in })
        tidier.sessions = { seen.sessions }
        tidier.idle = { !seen.busy.contains($0.id) }
        tidier.end = { seen.ended.append($0) }
        tidier.ask = { question in
            seen.asked.append(question)
            return seen.answer
        }
        return tidier
    }

    static func rows(_ sessions: [HostSession], project: String = "example") -> [WindowRow] {
        sessions.map { WindowRow(content: .hosted($0), project: project) }
    }

    @Test func aFinishedShellNobodyTouchedEndsTenMinutesAfterItsCommandWentWell() {
        let seen = Seen()
        let shell = Self.session("Shell: Install")
        seen.sessions = [shell]
        let tidier = tidier(seen)
        seen.now = Self.start.addingTimeInterval(599)
        #expect(tidier.look().isEmpty && seen.ended.isEmpty)
        seen.now = Self.start.addingTimeInterval(600)
        #expect(tidier.look() == [shell.id] && seen.ended == [shell.id])
    }

    /// Hours on, each of these is still there: a failed command's shell, one typed into after its command ended, one
    /// running a program now, one whose command still runs, and every session no Run card started, whatever it says.
    @Test func whatFailedIsUsedOrWasNotOpenedByARunCardIsNeverEnded() {
        let seen = Seen()
        let failed = Self.session("Shell: Backup", state: .error)
        let typedInto = Self.session("Shell: Query")
        let busy = Self.session("Shell: Server")
        let running = Self.session("Shell: Migrate", state: nil)
        let byHand = Self.session("Shell", command: nil, state: .done)
        let preset = Self.session("Dev shell", command: "printf '\\033]7501;state=done:app=vs-shell\\007'", state: .done)
        let agent = Self.session("Claude", state: .done, agent: "claude")
        // Another program's report in a Run-card shell (an agent the user started there) isn't the command's end.
        let anothers = Self.session("Shell: Tools", state: .done, app: "claude-code")
        let legacy = Self.session("Shell: Old", command: Self.oldRunLine, state: nil)
        seen.sessions = [failed, typedInto, busy, running, byHand, preset, agent, anothers, legacy]
        seen.busy = [busy.id]
        let tidier = tidier(seen)
        tidier.typed(typedInto.id)
        seen.now = Self.start.addingTimeInterval(26 * 3600)
        #expect(tidier.look().isEmpty && seen.ended.isEmpty)
        // The row of the failed one says so, and the finished one's that it finished.
        #expect(Self.rows([failed, typedInto]).map { $0.state(now: seen.now).text } == ["command failed", "command finished"])
        #expect(Self.rows([failed, typedInto, running, byHand]).map(\.commandFailed) == [true, false, false, false])
        // Back at its prompt, the busy one goes.
        seen.busy = []
        #expect(tidier.look() == [busy.id])
    }

    /// A shell that was ended for the user (tidied away, or End Session) reads "ended" under Ended, not as a failure,
    /// though an interactive zsh at its prompt exits 1 on the hangup; one that exited 1 by itself still reads so.
    @Test func aTidiedShellReadsEndedNotFailed() {
        let tidied = Self.session("Shell: Install", exit: .init(status: 1, at: Self.start, killedBy: 4242, killedByName: "VibeSwitcher"))
        let failed = Self.session("Shell: Backup", exit: .init(status: 1, at: Self.start))
        let rows = Self.rows([tidied, failed])
        #expect(rows.map { $0.state(now: Self.start).text } == ["ended", "exit 1"])
        #expect(rows.map { $0.end?.isFailure } == [false, true])
        #expect(SessionEnd(exit: .init(status: 0, at: Self.start, killedBy: 4242)).text == "finished")
    }

    /// Typing counts from the command's end (what's typed before is the command's: a password, an answer), is kept
    /// across a restart of the app, and is forgotten with the session.
    @Test func aShellTypedIntoAfterItsCommandEndedIsKeptAcrossARestart() throws {
        let seen = Seen()
        let file = temp.url("used").appendingPathComponent("shell-requests/used.json")
        var shell = Self.session("Shell: Install", state: nil)
        let other = Self.session("Shell: Other")
        seen.sessions = [shell, other]
        var tidier = tidier(seen, file: file)
        tidier.typed(shell.id)
        #expect(tidier.used.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        shell.programStatus = ProgramStatus(state: .done, app: ShellTidy.app, since: Self.start)
        seen.sessions = [shell, other]
        tidier.typed(shell.id)
        #expect(tidier.used == [shell.id])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        // The app restarted, a day on: the one typed into stays, the other goes.
        tidier = self.tidier(seen, file: file)
        seen.now = Self.start.addingTimeInterval(24 * 3600)
        #expect(tidier.used == [shell.id])
        #expect(tidier.look() == [other.id])
        // While the host's sessions aren't known, nothing is forgotten; once this one ended, it is.
        seen.sessions = []
        tidier.look()
        #expect(tidier.used == [shell.id])
        shell.exit = .init(status: 129, at: seen.now)
        seen.sessions = [shell]
        tidier.look()
        #expect(tidier.used.isEmpty && self.tidier(seen, file: file).used.isEmpty)
    }

    /// The sidebar's Close Finished Shells…: one confirmation that lists them, then every Run-card shell of the project
    /// that is back at its prompt is ended: the failed one, the one typed into and one from before launch lines said
    /// how the command ended too. Never one running a program, one the user opened, or another project's.
    @Test func closeFinishedShellsEndsTheProjectsRunCardShellsAtTheirPromptAfterOneConfirmation() {
        let seen = Seen()
        let fine = Self.session("Shell: Install", ago: 2 * 3600)
        let failed = Self.session("Shell: Backup", state: .error, ago: 26 * 3600)
        let typedInto = Self.session("Shell: Query", ago: 300)
        let legacy = Self.session("Shell: Old", command: Self.oldRunLine, state: nil)
        let busy = Self.session("Shell: Server")
        let byHand = Self.session("Shell", command: nil, state: nil)
        let agent = Self.session("Claude", command: "claude", state: .done, app: "claude-code", agent: "claude")
        let gone = Self.session("Shell: Gone", exit: .init(status: 0, at: Self.start))
        let elsewhere = Self.session("Shell: Elsewhere")
        seen.sessions = [fine, failed, typedInto, legacy, busy, byHand, agent, gone, elsewhere]
        seen.busy = [busy.id]
        let tidier = tidier(seen)
        tidier.typed(typedInto.id)
        let rows = Self.rows([fine, failed, typedInto, legacy, busy, byHand, agent, gone])
        // What the sidebar counts to offer it at all.
        #expect(EndedSnapshots.actions.agentShells(rows) == 5 && EndedSnapshots.actions.agentShells(Self.rows([byHand, agent, gone])) == 0)

        // Cancelled: asked once, nothing ended.
        seen.answer = false
        #expect(tidier.close(project: "example", rows: rows).isEmpty && seen.ended.isEmpty && seen.asked.count == 1)
        let question = seen.asked[0]
        #expect(question.message == "Close 4 finished shells in “example”?" && question.button == "Close 4 Shells")
        #expect(question.detail.hasPrefix("""
            Shell: Install: command finished 2h ago
            Shell: Backup: command failed 1d 2h ago
            Shell: Query: command finished 5m ago
            Shell: Old: at its prompt

            """), "\(question.detail)")
        #expect(question.detail.contains("under Ended"))

        // Confirmed: those four, once.
        seen.answer = true
        #expect(tidier.close(project: "example", rows: rows) == [fine, failed, typedInto, legacy].map(\.id))
        #expect(seen.ended == [fine, failed, typedInto, legacy].map(\.id) && seen.asked.count == 2)
    }

    /// One that started a program while the question was up isn't ended; with nothing to close, that's said and
    /// nothing is ended.
    @Test func closeFinishedShellsEndsOnlyWhatIsStillFinishedAndSaysWhenThereIsNothing() {
        let seen = Seen()
        let one = Self.session("Shell: Install"), two = Self.session("Shell: Backup")
        seen.sessions = [one, two]
        let tidier = tidier(seen)
        tidier.ask = { question in
            seen.asked.append(question)
            seen.busy = [two.id]
            return true
        }
        #expect(tidier.close(project: "example", rows: Self.rows([one, two])) == [one.id])
        #expect(seen.asked.map(\.button) == ["Close 2 Shells"])

        seen.sessions = [two]
        #expect(tidier.close(project: "example", rows: Self.rows([two])).isEmpty)
        #expect(seen.asked.last == ShellTidier.Question(message: "No finished shells in “example”",
                                                         detail: "The one shell an agent opened here is running a program. Shells you opened yourself are never closed by this.",
                                                         button: nil))
        #expect(seen.ended == [one.id])
    }

    /// On the app's own client and a scratch session host, wired as the app wires it: of two Run-card shells whose
    /// command went well, the one typed into (through the client, as the terminal view types) stays and the other is
    /// ended by the tidier's look, hours later by its clock; it's then an ended session of the client's.
    @Test func typingThroughTheAppsClientKeepsAShellAndTheOtherIsEnded() async throws {
        let scratch = try PasteDeliveryTests.Scratch()
        let host = scratch.host
        host.connectIfRunning()
        #expect(await until { host.state == .connected })
        let seen = Seen()
        let tidier = tidier(seen)
        tidier.sessions = { host.sessions }
        tidier.idle = ShellTidy.idle
        tidier.end = { host.kill($0) }
        host.onInput = { tidier.typed($0) }
        defer { tidier.close() }
        var shells: [HostSession] = []
        for label in ["Kept", "Left"] {
            let request = ShellRequest(session: UUID().uuidString, cwd: String(cString: realpath("/tmp", nil)), command: "echo ran-$((40 + 2))",
                                       label: label, createdAt: Date())
            var result: Result<HostSession, HostClientError>?
            host.spawn(ShellAsk.spawnRequest(request, cols: 80, rows: 24)) { result = $0 }
            #expect(await until { result != nil })
            shells.append(try #require(result).get())
        }
        let kept = shells[0].id, left = shells[1].id
        func now(_ id: UUID) -> HostSession? { host.sessions.first { $0.id == id } }
        #expect(await until { shells.allSatisfy { now($0.id).flatMap(ShellTidy.ending(of:))?.ok == true } })
        #expect(await until { shells.allSatisfy { now($0.id).map(ShellTidy.idle) == true } })
        // The terminal's own answer to a query isn't typing; a key is.
        host.send(left, bytes: Data("\u{1b}[1;1R".utf8), reply: true)
        host.send(kept, bytes: Data(" ".utf8), reply: false)
        #expect(tidier.used == [kept])

        seen.now = Date().addingTimeInterval(5 * 3600)
        #expect(tidier.look() == [left])
        #expect(await until { now(left)?.isLive == false })
        #expect(now(kept)?.isLive == true)
        let folded = WindowGroups.foldEnded([WindowSection(project: "example", rows: Self.rows(host.sessions.filter { [kept, left].contains($0.id) }))])
        #expect(folded.sections.flatMap(\.rows).compactMap(\.hostID) == [kept] && folded.ended.compactMap(\.hostID) == [left])
        host.kill(kept)
        #expect(await until { now(kept)?.isLive == false })
    }
}
