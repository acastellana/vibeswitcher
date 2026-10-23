import AppKit
import CryptoKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// Memory audit 2026-10-22, finding 2: the window's terminal views each hold their scrollback (about 30 MB at 10,000
/// lines) and parse their session's output on the main thread, shown or not. The pane keeps the view on screen and the
/// last two shown, and lets a view go once it's been off screen for its lifetime (run here when the test says, through
/// `afterParked`); a session shown again after that is drawn from the host's replay. On a scratch host (its own socket,
/// lock and key; never the user's) running scratch shells.
@MainActor
@Suite(.serialized)
struct TerminalPaneReleaseTests {
    final class Pane {
        let temp = VibeSwitcherTests.Scratch()
        let socket: String
        let server: HostServer
        let host: HostClient
        let pane: TerminalPaneController
        /// The releases the pane asked for, in order, waiting for the test to run them.
        var releases: [() -> Void] = []

        @MainActor
        init() throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-pane") + "/h.sock"
            let key = SymmetricKey(size: .bits256)
            var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: launcher,
                                           baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                           hostBuild: HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path))
            config.idleExit = nil
            config.appKey = key
            config.appExecutable = HostServer.executable(of: getpid())
            server = HostServer(config: config)
            try server.start()
            host = HostClient(socketPath: socket, appKey: { key })
            pane = TerminalPaneController(host: host)
            pane.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
            pane.afterParked = { [unowned self] release in self.releases.append(release) }
        }

        deinit {
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }

        /// A session that prints `lines` numbered lines, then its name, and waits.
        @MainActor
        func spawn(_ name: String, lines: Int = 0) async throws -> UUID {
            if host.state != .connected {
                host.connectIfRunning()
                #expect(await until { self.host.state == .connected })
            }
            var result: Result<HostSession, HostClientError>?
            let numbered = lines > 0 ? "/usr/bin/awk 'BEGIN { for (i = 1; i <= \(lines); i++) printf \"line %d\\n\", i }'; " : ""
            host.spawn(SpawnRequest(cwd: scratchRoot.path, command: "\(numbered)echo '\(name) ready'; exec /bin/cat", env: [:], cols: 100, rows: 30,
                                    keepShell: false, label: name, agent: nil)) { result = $0 }
            #expect(await until { result != nil })
            return try #require(result).get().id
        }

        /// Shows the session and waits until its screen ends with its name.
        @MainActor
        func show(_ id: UUID, _ name: String) async {
            pane.show(hostID: id, focus: false)
            #expect(await until { self.pane.screenLines(id).contains("\(name) ready") }, "\(name) never reached its view")
        }

        /// Runs every release asked for so far: their lifetime is up.
        func timePasses() {
            let due = releases
            releases = []
            due.forEach { $0() }
        }

        /// The whole text of the session's view, scrollback included.
        func text(_ id: UUID) -> String {
            guard let terminal = pane.terminalView(id) else { return "" }
            return String(decoding: terminal.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
        }
    }

    final class Anchor {}

    @Test func aViewOffScreenIsLetGoWhenItsTimeIsUpAndShownAgainFromTheHost() async throws {
        let p = try Pane()
        let a = try await p.spawn("alpha"), b = try await p.spawn("beta")
        await p.show(a, "alpha")
        await p.show(b, "beta")
        // Off screen, still attached until its time is up: switching back now is instant.
        #expect(Set(p.pane.attachedIDs) == [a, b])
        #expect(p.releases.count == 1)
        p.timePasses()
        #expect(p.pane.attachedIDs == [b])
        #expect(p.pane.current == b)
        // Shown again: a new view, drawn from the host's replay.
        await p.show(a, "alpha")
        #expect(Set(p.pane.attachedIDs) == [a, b])
        #expect(p.pane.current == a)
    }

    @Test func aViewShownAgainInTimeKeepsItsScrollback() async throws {
        let p = try Pane()
        let a = try await p.spawn("alpha", lines: 3_000), b = try await p.spawn("beta")
        await p.show(a, "alpha")
        let view = try #require(p.pane.terminalView(a))
        #expect(p.text(a).contains("line 1\n"))
        await p.show(b, "beta")
        await p.show(a, "alpha")
        // Its release was asked for when it left, and is void now that it's back; beta's is the live one.
        p.timePasses()
        #expect(p.pane.terminalView(a) === view)
        #expect(p.text(a).contains("line 1\n") && p.text(a).contains("line 3000\n"))
        #expect(p.pane.attachedIDs == [a])
    }

    @Test func theSessionOnScreenIsNeverLetGoEvenUnderTheChat() async throws {
        let p = try Pane()
        let a = try await p.spawn("alpha"), b = try await p.spawn("beta")
        await p.show(a, "alpha")
        await p.show(b, "beta")
        p.pane.covered = true
        p.timePasses()
        #expect(p.pane.attachedIDs == [b])
        // Still read under the chat (its screen is what the chat reads its menus from).
        p.host.send(b, bytes: Data("typed under the chat\n".utf8), reply: false)
        #expect(await until { p.pane.screenLines(b).contains("typed under the chat") })
        p.pane.covered = false
        #expect(p.pane.attachedIDs == [b])
    }

    @Test func aPlaceholderLetsEveryViewGoInTime() async throws {
        let p = try Pane()
        let a = try await p.spawn("alpha")
        await p.show(a, "alpha")
        p.pane.show(placeholder: AnyView(EmptyView()))
        #expect(p.pane.attachedIDs == [a])
        p.timePasses()
        #expect(p.pane.attachedIDs.isEmpty)
        await p.show(a, "alpha")
        #expect(p.pane.attachedIDs == [a])
    }

    @Test func atMostTheSessionOnScreenAndTheLastTwoStayAttached() async throws {
        let p = try Pane()
        var ids: [UUID] = []
        for index in 0..<5 {
            let id = try await p.spawn("s\(index)")
            ids.append(id)
            await p.show(id, "s\(index)")
        }
        #expect(TerminalPaneController.keepAttached == 3)
        #expect(Set(p.pane.attachedIDs) == Set(ids.suffix(3)))
        #expect(p.pane.current == ids.last)
    }
}
