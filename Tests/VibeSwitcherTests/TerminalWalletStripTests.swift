import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A shell session (no agent conversation, so no Chat view) has its wallet cards under its terminal; a session with a
/// chat has them in the chat only, never twice.
@MainActor
@Suite(.serialized)
struct TerminalWalletStripTests {
    static let now = Date()

    static func shell(_ id: UUID = WalletDeskTests.session) -> HostSession {
        HostSession(id: id, tty: "ttys071", childPID: 1, cwd: "/Users/you/dev/acme", command: "zsh", label: "Shell", agent: nil,
                    title: "Local fork test", startedAt: now - 600, cols: 80, rows: 24, exit: nil)
    }

    /// The agent running in a window session `host`, with its transcript.
    static func agent(in host: HostSession) -> Session {
        var session = Session(tty: host.tty, agent: .claude, pid: 2, startedAt: now - 300, cwd: host.cwd, project: "acme", task: nil,
                              status: .working, statusSince: now - 60, detail: nil, hasHooks: true, inTerminalApp: false)
        session.hostID = host.id
        session.agentSessionID = "agent-session"
        session.transcriptPath = "/Users/you/.claude/projects/acme/agent-session.jsonl"
        return session
    }

    static func model(sessions: [Session] = [], hosted: [HostSession]) -> WindowModel {
        let model = WindowModel()
        model.update(sessions: sessions, hosted: hosted, table: TableRead(at: now))
        model.selectedID = "host:\(hosted[0].id)"
        return model
    }

    @Test func aShellSessionHasItsCardsUnderTheTerminalAndAChatSessionInItsChat() throws {
        let shell = Self.shell()
        let plain = Self.model(hosted: [shell])
        #expect(plain.selectedRow?.hostID == shell.id)
        #expect(plain.chatPath(for: try #require(plain.selectedRow)) == nil)
        #expect(plain.walletUnderTerminal(for: plain.selectedRow) == shell.id)
        #expect(!plain.chatShown)

        // With an agent's conversation the cards are in its chat (Chat or Terminal chosen): never under the terminal too.
        let withChat = Self.model(sessions: [Self.agent(in: shell)], hosted: [shell])
        #expect(withChat.chatPath(for: try #require(withChat.selectedRow)) != nil)
        #expect(withChat.walletUnderTerminal(for: withChat.selectedRow) == nil)
        withChat.showsChat = false
        #expect(withChat.walletUnderTerminal(for: withChat.selectedRow) == nil)

        // Nothing selected (Home): nothing.
        #expect(plain.walletUnderTerminal(for: nil) == nil)
    }

    @Test func theShellsStripShowsItsCardAndItsSendSendsAsFromTheChat() async throws {
        // The desk's tests' setup (its fake passage lives in their scratch folder while `desks` does).
        let desks = WalletDeskTests()
        let s = try desks.setup()
        defer { s.desk.close(); _ = desks }
        let model = Self.model(hosted: [Self.shell()])
        let host = NSHostingView(rootView: TerminalWalletStrip(model: model, desk: s.desk) {}.frame(width: 640))
        host.sizingOptions = [.intrinsicContentSize]
        // Nothing filed: zero high, the terminal keeps its full height.
        host.layoutSubtreeIfNeeded()
        #expect(host.intrinsicContentSize.height <= 0.5)

        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        var refreshed = false
        s.desk.refresh { refreshed = true }
        _ = await until { refreshed }
        let session = try #require(model.walletUnderTerminal(for: model.selectedRow))
        let card = try #require(s.desk.cards(for: session).first)
        #expect(card.actions == [.send, .discard])
        #expect(await until {
            host.layoutSubtreeIfNeeded()
            return host.intrinsicContentSize.height > 40
        })

        // Send on the shell's card: the same desk action the chat's card takes.
        var sent = false
        s.desk.act(.send, on: card.id) { sent = true }
        _ = await until { sent }
        #expect(s.fake.sends.count == 1)
        #expect(s.fake.sends.first?.hasSuffix("--name wallet-request-\(request.id).json") == true)
        #expect(s.desk.cards.first?.state == .sent)
        // Sent, it leaves the strip (WalletStripTests).
        #expect(await until { s.desk.cards(for: session).isEmpty })
    }
}
