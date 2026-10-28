import AppKit
import CryptoKit
import Foundation
import SwiftTerm
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// OSC 52 (a program setting the clipboard) is untrusted output: it reaches the clipboard only from the pane you're
/// looking at and typing in, live. On a named pasteboard, never the user's clipboard, and a scratch host (its own socket,
/// lock and key; never the user's) running a scratch program.
@MainActor
@Suite(.serialized)
struct TerminalClipboardSecurityTests {
    @Test func aTerminalOutsideThePaneNeverReachesTheClipboard() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("original-synthetic-selection", forType: .string)
        let revision = clipboard.changeCount
        let pane = TerminalPaneController(host: HostClient(socketPath: "/unused-audit-socket"), clipboard: clipboard)
        let view = HostTerminalView(frame: .zero, font: nil, options: TerminalOptions())
        view.terminalDelegate = pane
        let payload = Data("SYNTHETIC_CLIPBOARD".utf8).base64EncodedString()
        for _ in 0..<3 { view.feed(text: "\u{1b}]52;c;\(payload)\u{7}") }
        #expect(clipboard.changeCount == revision)
        #expect(clipboard.string(forType: .string) == "original-synthetic-selection")
    }

    final class Scene {
        let temp = VibeSwitcherTests.Scratch()
        let socket: String
        let server: HostServer
        let host: HostClient
        let pane: TerminalPaneController
        let clipboard = NSPasteboard.withUniqueName()
        let window = Window(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 600), styleMask: [.borderless],
                            backing: .buffered, defer: false)

        @MainActor
        init() throws {
            let launcher = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
            socket = try temp.shortFolder("vsh-osc52") + "/h.sock"
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
            pane = TerminalPaneController(host: host, clipboard: clipboard)
            window.isReleasedWhenClosed = false
            window.contentView = pane.view
            window.makeKeyAndOrderFront(nil)
            clipboard.setString("before", forType: .string)
        }

        deinit {
            MainActor.assumeIsolated {
                pane.detachAll()
                window.close()
            }
            clipboard.releaseGlobally()
            server.stop(terminateSessions: true)
            unlink(socket + ".lock")
        }

        /// A program that sets the clipboard to `REPLAYED` as it starts (before any view is attached), then for each line
        /// `<base64> <marker>` it reads, sets it to that and prints the marker: the marker on screen says the sequence
        /// went through the view's parser.
        @MainActor
        func spawn(_ name: String) async throws -> UUID {
            if host.state != .connected {
                host.connectIfRunning()
                #expect(await until { self.host.state == .connected })
            }
            let replayed = Data("REPLAYED".utf8).base64EncodedString()
            var result: Result<HostSession, HostClientError>?
            host.spawn(SpawnRequest(cwd: scratchRoot.path,
                                    command: "stty -echo; printf '\\033]52;c;\(replayed)\\007'; echo '\(name) ready'; "
                                        + "while read b m; do printf '\\033]52;c;%s\\007%s\\n' \"$b\" \"$m\"; done",
                                    env: [:], cols: 100, rows: 30, keepShell: false, label: name, agent: nil)) { result = $0 }
            #expect(await until { result != nil })
            return try #require(result).get().id
        }

        /// The program sets the clipboard to `text`; returns once its marker reached the session's view.
        @MainActor
        func programCopies(_ text: String, in id: UUID, marker: String) async {
            host.send(id, bytes: Data("\(Data(text.utf8).base64EncodedString()) \(marker)\r".utf8), reply: false)
            #expect(await until { self.pane.screenLines(id).contains(marker) }, "\(marker) never reached its view")
        }

        /// Returns once the host's own screen of `id` shows `text` (read from the host, not a view): output the host
        /// took before any view attached.
        @MainActor
        func hostShows(_ text: String, in id: UUID) async -> Bool {
            let deadline = Date().addingTimeInterval(hangGuard)
            while Date() < deadline {
                var screen: String??
                host.screen(id) { screen = .some($0) }
                _ = await until { screen != nil }
                if screen??.contains(text) == true { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        var copied: String? { clipboard.string(forType: .string) }
    }

    /// A borderless window off screen that's key when the test says (the test process isn't the active app, so none of
    /// its windows is otherwise).
    final class Window: NSWindow {
        var key = true
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { key }
    }

    final class Anchor {}

    @Test func onlyTheFocusedVisiblePaneSetsTheClipboardLive() async throws {
        let scene = try Scene()
        let first = try await scene.spawn("first")
        scene.pane.show(hostID: first)
        let view = try #require(scene.pane.terminalView(first))
        #expect(await until { scene.pane.screenLines(first).contains("first ready") })
        #expect(scene.window.firstResponder === view)
        // Focused, on screen, in the key window, live.
        await scene.programCopies("LIVE", in: first, marker: "live")
        #expect(scene.copied == "LIVE")

        // Focus elsewhere in the window.
        scene.window.makeFirstResponder(nil)
        await scene.programCopies("UNFOCUSED", in: first, marker: "unfocused")
        #expect(scene.copied == "LIVE")
        scene.pane.focus()

        // The window isn't the key one (another app's or window's in front).
        scene.window.key = false
        await scene.programCopies("BACKGROUND-WINDOW", in: first, marker: "background-window")
        #expect(scene.copied == "LIVE")
        scene.window.key = true

        // Hidden behind the chat.
        scene.pane.covered = true
        await scene.programCopies("COVERED", in: first, marker: "covered")
        #expect(scene.copied == "LIVE")
        scene.pane.covered = false
        scene.pane.focus()

        // Another session shown: this one's view is off screen, still reading its session.
        let second = try await scene.spawn("second")
        scene.pane.show(hostID: second)
        #expect(await until { scene.pane.screenLines(second).contains("second ready") })
        await scene.programCopies("BACKGROUND-PANE", in: first, marker: "background-pane")
        #expect(scene.copied == "LIVE")
        #expect(scene.pane.terminalView(first) === view)

        // Shown and focused again: it's taken again.
        scene.pane.show(hostID: first)
        await scene.programCopies("AGAIN", in: first, marker: "again")
        #expect(scene.copied == "AGAIN")
    }

    /// A view attached to a session that set the clipboard earlier gets that in its replay: refused, though focused.
    @Test func aReplayNeverSetsTheClipboard() async throws {
        let scene = try Scene()
        let id = try await scene.spawn("replayed")
        // The program set the clipboard before the view attached: its marker, printed after, is on the host's screen.
        #expect(await scene.hostShows("replayed ready", in: id))
        let revision = scene.clipboard.changeCount
        scene.pane.show(hostID: id)
        #expect(await until { scene.pane.screenLines(id).contains("replayed ready") })
        #expect(scene.window.firstResponder === scene.pane.terminalView(id))
        // Live output after it: the replay is over by then.
        await scene.programCopies("LIVE", in: id, marker: "live")
        #expect(scene.copied == "LIVE")
        #expect(scene.clipboard.changeCount == revision + 1, "the replay set it too")
    }
}
