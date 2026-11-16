import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A Run card's shell, started as the app starts it (`ShellAsk.spawnRequest`) in a scratch session host: when its
/// command ends, the host has its exit status and the last lines it printed (`HostSession.commandEnd`), and the asking
/// session's message is made from that (`ShellAsk.ending`). Only the command's own output: what's typed into the shell
/// that stays open afterwards (an end report forged there too) changes nothing.
@Suite(hostTestLimit)
struct ShellOutcomeHostTests {
    static let asker = "aaaaaaaa-2222-4333-8444-555555555555"

    static func request(_ command: String) -> ShellRequest {
        ShellRequest(session: asker, cwd: String(cString: realpath(NSHomeDirectory(), nil)), command: command, label: "Install", createdAt: Date())
    }

    /// The user's report (2026-11-12): `bash -c git log -1 --oneline && …` printed git's usage and exited 1, and the lead
    /// only heard "started". Now the asker hears the status and the output's last lines.
    @Test func aFailedCommandsStatusAndLastLinesReachTheMessage() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let request = Self.request("echo usage: git log [options]; echo '   or: git show'; false")
        let seq = app.send(.spawn(ShellAsk.spawnRequest(request, cols: 80, rows: 24)))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .spawned(let shell)? = app.reply(to: seq) else { Issue.record("not spawned"); return }
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.latest(shell.id)?.commandEnd != nil }, "\(app.screen(shell.id) ?? "")")
        let end = try #require(app.latest(shell.id)?.commandEnd)
        #expect(!end.ok && end.status == 1, "\(end)")
        #expect(end.tail == "usage: git log [options]\n   or: git show" && !end.cut, "\(end)")
        #expect(end.startedAt != nil && end.startedAt! <= end.at)
        #expect(app.latest(shell.id)?.isLive == true)

        let answer = ShellAsk.Answer(state: .started, at: Date(), shell: shell.id.uuidString.lowercased(), name: "Shell: Install", endTold: false)
        let message = try #require(ShellAsk.ending(request, answer, session: app.latest(shell.id)))
        #expect(message.contains("Shell request \(request.id)") && message.contains("FAILED: the command exited with status 1"), "\(message)")
        #expect(message.contains("usage: git log [options]\n   or: git show"), "\(message)")
    }

    /// Exit 0: the end says so. The shell then stays open as an interactive shell, and what's typed there (a forged end
    /// report included) never changes what the host recorded of the command.
    @Test func aSucceededCommandsEndIsRecordedOnceAndWhatsTypedAfterIsNotTheCommands() async throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let request = Self.request("echo built-$((40 + 2))")
        let seq = app.send(.spawn(ShellAsk.spawnRequest(request, cols: 80, rows: 24)))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .spawned(let shell)? = app.reply(to: seq) else { Issue.record("not spawned"); return }
        defer { app.send(.kill(id: shell.id)) }
        #expect(await eventually { app.latest(shell.id)?.commandEnd != nil }, "\(app.screen(shell.id) ?? "")")
        let end = try #require(app.latest(shell.id)?.commandEnd)
        #expect(end.ok && end.status == 0 && end.tail == "built-42", "\(end)")
        let answer = ShellAsk.Answer(state: .started, at: Date(), shell: shell.id.uuidString.lowercased(), name: "Shell: Install", endTold: false)
        #expect(ShellAsk.ending(request, answer, session: app.latest(shell.id))?.contains("succeeded: the command exited with status 0") == true)

        // Typed into the shell afterwards: a command of the user's, and an end report that says otherwise.
        app.send(.input(id: shell.id, bytes: Data("echo typed-$((6 * 7)); printf '\\033]7501;state=error:app=vs-shell:exit=9\\007'; echo after-$((1 + 1))\r".utf8), reply: false))
        #expect(await eventually { app.screen(shell.id)?.contains("after-2") == true }, "\(app.screen(shell.id) ?? "")")
        #expect(app.latest(shell.id)?.commandEnd == end)
        #expect(app.latest(shell.id)?.isLive == true)
    }
}
