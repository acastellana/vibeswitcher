import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Shells that Run cards opened tidy themselves away (`ShellTidy`), on a scratch session host with the shells a Run
/// starts (`ShellAsk.spawnRequest`): real shells, scratch programs, and a clock the test moves (the 10 minutes and the
/// hours are `now`, handed to `ShellTidy.due`, never waited). What the app does each time it looks is `tidy` here: ask
/// `ShellTidy.due`, and end those sessions as End Session does (`HostRequest.kill`).
@Suite(hostTestLimit)
struct ShellTidyHostTests {
    static let asker = "aaaaaaaa-2222-4333-8444-555555555555"

    /// A Run card's shell for `command`, started as the app starts it.
    static func runShell(_ command: String, on app: TestClient, label: String = "Install") async throws -> HostSession {
        let request = ShellRequest(session: asker, cwd: String(cString: realpath(NSHomeDirectory(), nil)), command: command, label: label, createdAt: Date())
        let seq = app.send(.spawn(ShellAsk.spawnRequest(request, cols: 80, rows: 24)))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .spawned(let shell)? = app.reply(to: seq) else { throw CancellationError() }
        return shell
    }

    /// The app's look at `now`: ends what's due. The sessions it ended.
    @discardableResult
    static func tidy(_ sessions: [HostSession], on app: TestClient, used: Set<UUID> = [], now: Date) -> [UUID] {
        let due = ShellTidy.due(sessions.map { app.latest($0.id) ?? $0 }, used: used, now: now)
        due.forEach { app.send(.kill(id: $0.id)) }
        return due.map(\.id)
    }

    /// The sidebar's rows for these sessions, as it folds them: the live ones, and those under Ended.
    static func sidebar(_ sessions: [HostSession], on app: TestClient) -> (live: [UUID], ended: [UUID]) {
        let rows = sessions.map { WindowRow(content: .hosted(app.latest($0.id) ?? $0), project: "example") }
        let folded = WindowGroups.foldEnded([WindowSection(project: "example", rows: rows)])
        return (folded.sections.flatMap(\.rows).compactMap(\.hostID), folded.ended.compactMap(\.hostID))
    }

    /// The user's report (2026-11-10: 11 idle shells in 3 projects, some a day old): a shell an agent's Run card opened,
    /// whose command exited 0 and that nobody touched, isn't a live session in the sidebar hours later. It's under
    /// Ended, with what it printed still there to read.
    @Test func aRunShellWhoseCommandWentWellIsNotLeftInTheSidebar() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let shell = try await Self.runShell("echo installed-$((40 + 2))", on: app)
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.screen(shell.id)?.contains("installed-42") == true })
        // Hours later, at each of the app's looks (the first may come before the shell is back at its prompt).
        let hoursLater = Date().addingTimeInterval(3 * 3600)
        var ended: [UUID] = []
        #expect(await eventually {
            if ended.isEmpty { ended = Self.tidy([shell], on: app, now: hoursLater) }
            return app.latest(shell.id)?.isLive == false
        }, "still a live session hours later: \(String(describing: app.latest(shell.id)))")
        #expect(Self.sidebar([shell], on: app) == (live: [], ended: [shell.id]))
        // Ended, not removed: its output is still the session's.
        #expect(app.screen(shell.id)?.contains("installed-42") == true)
    }

    /// Ten minutes after the command finished, not before; and by the command's end, not the session's start.
    @Test func itEndsTenMinutesAfterItsCommandFinished() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let shell = try await Self.runShell("true", on: app)
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.latest(shell.id).flatMap(ShellTidy.ending(of:))?.ok == true },
                "its command's end isn't known: \(String(describing: app.latest(shell.id)))")
        let finished = try #require(app.latest(shell.id).flatMap(ShellTidy.ending(of:))).at
        #expect(finished >= shell.startedAt)
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == true })
        #expect(Self.tidy([shell], on: app, now: finished.addingTimeInterval(ShellTidy.idleFor - 1)).isEmpty)
        #expect(Self.sidebar([shell], on: app) == (live: [shell.id], ended: []))
        #expect(Self.tidy([shell], on: app, now: finished.addingTimeInterval(ShellTidy.idleFor)) == [shell.id])
        #expect(await eventually { app.latest(shell.id)?.isLive == false })
    }

    /// A command that failed, or was killed, leaves its shell where it is, however long ago: its row says it failed.
    /// (`exit_with`, not `exit-with`: Ubuntu's /bin/sh is dash, which refuses a function name with a hyphen.)
    @Test(arguments: ["echo tried; exit_with() { return $1; }; exit_with 3", "sh -c 'kill -TERM $$'"])
    func aRunShellWhoseCommandFailedStays(command: String) async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let shell = try await Self.runShell(command, on: app)
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.latest(shell.id).flatMap(ShellTidy.ending(of:))?.ok == false },
                "not known to have failed: \(String(describing: app.latest(shell.id)))")
        // Back at its prompt, and still not ended.
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == true })
        #expect(Self.tidy([shell], on: app, now: Date().addingTimeInterval(24 * 3600)).isEmpty)
        let now = try #require(app.latest(shell.id))
        #expect(now.isLive)
        #expect(WindowRow(content: .hosted(now), project: "example").state(now: Date()).text == "command failed")
        // Close Finished Shells… does take it: it's back at its prompt.
        #expect(ShellTidy.finished([now]).map(\.id) == [shell.id])
    }

    /// A shell that runs a program in the foreground right now is never ended, though its first command went well long
    /// ago; back at its prompt, it is.
    @Test func aShellRunningAProgramIsNotEnded() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let shell = try await Self.runShell("true", on: app)
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.latest(shell.id).flatMap(ShellTidy.ending(of:))?.ok == true })
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == true })
        // A program started in it (a scratch shell on a scratch host: nothing of the user's is typed into).
        app.send(.input(id: shell.id, bytes: Data("echo began-$((40 + 2)); sleep 3600\r".utf8), reply: false))
        #expect(await eventually { app.screen(shell.id)?.contains("began-42") == true })
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == false })
        let later = Date().addingTimeInterval(24 * 3600)
        // The app's record of the typing aside (`used`): the program alone keeps it.
        #expect(Self.tidy([shell], on: app, now: later).isEmpty)
        #expect(ShellTidy.finished([try #require(app.latest(shell.id))]).isEmpty)
        #expect(app.latest(shell.id)?.isLive == true)
        // The program ended (Control-C): the shell is at its prompt again.
        app.send(.input(id: shell.id, bytes: Data([3]), reply: false))
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == true })
        // Typed into since its command ended: never ended by itself.
        #expect(Self.tidy([shell], on: app, used: [shell.id], now: later).isEmpty)
        #expect(ShellTidy.finished([try #require(app.latest(shell.id))]).map(\.id) == [shell.id])
    }

    /// A command still running in the launch line's own shell (two servers and a `wait`) holds the terminal as a
    /// prompt does: Close Finished Shells… doesn't take it for finished, nor is it ended by itself.
    @Test func aCommandStillWaitingIsNotFinished() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let shell = try await Self.runShell("echo up-$((40 + 2)); sleep 3600 & wait", on: app)
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.screen(shell.id)?.contains("up-42") == true })
        #expect(ShellTidy.finished([app.latest(shell.id) ?? shell]).isEmpty)
        #expect(Self.tidy([shell], on: app, now: Date().addingTimeInterval(24 * 3600)).isEmpty)
        #expect((app.latest(shell.id) ?? shell).isLive)
    }

    /// A shell whose command left a job running isn't ended by itself, however long ago it went well: ending it would
    /// end the job. Close Finished Shells… takes it, and ending it ends that session's own processes and nothing else
    /// (the 2026-10-23 decision on ending sessions): another session, its program, and the user's own processes run on.
    @Test func aShellThatLeftAJobStaysAndClosingItLeavesOtherSessionsAndTheUsersProcessesAlone() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        // The Run card's command left a job behind, in a group of its own that ignores SIGHUP: the session's own, which
        // only ending the session's processes reaches.
        let shell = try await Self.runShell("perl -e 'setpgrp(0, 0); $SIG{HUP} = q(IGNORE); $|=1; print qq(b=$$\\n); sleep 300' & true", on: app)
        // Another session, with a program of its own; and a shell the user opened by hand (File › New Shell).
        let other = try await app.spawn("perl -e '$|=1; print qq(o=$$\\n); sleep 300'; \(keepRunning)")
        let seq = app.send(.spawn(SpawnRequest(cwd: NSHomeDirectory(), command: nil, env: [:], cols: 80, rows: 24, keepShell: false, label: "Shell", agent: nil)))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .spawned(let byHand)? = app.reply(to: seq) else { Issue.record("no shell"); return }
        await app.attach(shell.id)
        await app.attach(other.id)
        #expect(await eventually { EndingASessionTests.pid("b", in: app.text(shell.id)) != nil && EndingASessionTests.pid("o", in: app.text(other.id)) != nil })
        let job = try #require(EndingASessionTests.pid("b", in: app.text(shell.id)))
        let program = try #require(EndingASessionTests.pid("o", in: app.text(other.id)))
        // The user's own processes: one from another session, one from none, and Apple's sleep.
        let (elsewhere, elsewhereInput) = try EndingASessionTests.waiter(environment: ["VIBESWITCHER_SESSION": UUID().uuidString])
        let (none, noneInput) = try EndingASessionTests.waiter(environment: [:])
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["300"]
        try sleep.run()
        let spared = [elsewhere, none, sleep]
        defer {
            spared.forEach { $0.terminate() }
            [elsewhereInput, noneInput].forEach { try? $0.fileHandleForWriting.close() }
            [job, program].forEach { kill($0, SIGKILL) }
            [shell, other, byHand].forEach { app.send(.kill(id: $0.id)) }
        }
        #expect(await eventually { app.latest(shell.id).flatMap(ShellTidy.ending(of:))?.ok == true })
        #expect(await eventually { app.latest(shell.id).map(ShellTidy.idle) == true && ShellTidy.idle(byHand) })

        // A day later nothing is ended by itself: the Run card's shell has its job, the others are never looked at.
        let all = [shell, other, byHand]
        #expect(Self.tidy(all, on: app, now: Date().addingTimeInterval(24 * 3600)).isEmpty)
        #expect(ShellTidy.leftRunning(try #require(app.latest(shell.id)), try #require(app.latest(shell.id).flatMap(ShellTidy.ending(of:)))))
        // Close Finished Shells… finds the Run card's shell alone, and ends it as End Session does.
        let finished = ShellTidy.finished(all.map { app.latest($0.id) ?? $0 })
        #expect(finished.map(\.id) == [shell.id])
        let ended = Date()
        finished.forEach { app.send(.kill(id: $0.id)) }
        #expect(await eventually(timeout: 60) { app.latest(shell.id)?.isLive == false && kill(job, 0) != 0 },
                "shell live \(String(describing: app.latest(shell.id)?.isLive)), its job \(kill(job, 0) == 0)")
        // Past the 5 s mark too (when what didn't end on being asked is killed), the others run.
        await pause(max(0, ended.addingTimeInterval(6).timeIntervalSinceNow))
        #expect(app.latest(other.id)?.isLive != false && app.latest(byHand.id)?.isLive != false)
        #expect(kill(program, 0) == 0 && kill(other.childPID, 0) == 0 && kill(byHand.childPID, 0) == 0)
        for process in spared { #expect(process.isRunning, "\(process.executableURL?.path ?? "") was signalled") }
        #expect(Self.sidebar(all, on: app) == (live: [other.id, byHand.id], ended: [shell.id]))
    }
}
