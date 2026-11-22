import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// Close Finished Shells on a node (`ShellRequests.swift`, the app's Close Finished Shells…): `shells` lists the node's
/// shell sessions and which are back at their prompt; `session.close-shells` (the user's voice, recorded) ends those of
/// the ones shown that still are, and leaves a busy shell, an agent's session and a lead's. Only scratch sessions start.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct CloseShellsTests {
    private let scratch = Scratch()

    @Test func onlyTheShellsBackAtTheirPromptAreClosed() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let started = try #require(await world.ask("session.new", ["folder": .string(world.repo), "agent": .string("shell")]))
        let idleID = try #require(started.result?["session"]?.string, "\(started)")
        // A shell running something in its foreground (job control on: the command holds the terminal).
        let busy = try await world.host.spawn("exec /bin/bash --norc -i -c 'sleep 600; true'", cwd: world.repo, label: "Shell")
        let lead = try await world.sleepingLead()
        let liveIDs = { world.queue.sync { Set(world.world.link.sessions.filter(\.isLive).map { NodeIds.session(host: $0.id) }) } }
        try #require(await eventually(timeout: 60) { liveIDs().isSuperset(of: [idleID, NodeIds.session(host: busy.id), NodeIds.session(host: lead.id)]) })
        // The busy shell running its command in the foreground before anything is listed: its sleep started and holding
        // the terminal. Before that a "not finished" can be its launcher's state (no terminal of its own yet, unreadable),
        // and the shell then holds its prompt's terminal a moment before it starts the sleep (the CI flake of 2026-11-22:
        // the listing read busy as not finished that early, and close-shells found it at its prompt).
        try #require(await eventually(timeout: 60) {
            !Platform.Processes.children(busy.childPID).isEmpty && ProcessTable.holdsForeground(pid: busy.childPID) == false
        }, "the busy shell's sleep never took the terminal")

        // Listed: the two shells (never the lead), the idle one finished once its prompt holds the terminal.
        var listed: [String: Bool] = [:]
        let deadline = MacTime.real.awake() + 60
        while MacTime.real.awake() < deadline {
            let reply = await world.ask("shells", action: nil)
            let shells = reply?.result?["shells"]?.array ?? []
            listed = Dictionary(shells.compactMap { shell in shell["session"]?.string.map { ($0, shell["finished"]?.bool == true) } }, uniquingKeysWith: { $1 })
            if listed[idleID] == true && listed[NodeIds.session(host: busy.id)] == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(listed[idleID] == true && listed[NodeIds.session(host: busy.id)] == false, "\(listed)")
        #expect(listed[NodeIds.session(host: lead.id)] == nil)

        // Asked for all three: only the idle shell ends; the busy one and the lead are left, and said.
        let action = UUID().uuidString.lowercased()
        let closed = try #require(await world.ask("session.close-shells", ["sessions": .array([idleID, NodeIds.session(host: busy.id), NodeIds.session(host: lead.id)].map(NodeWire.Value.string))],
                                                  action: action))
        #expect(closed.result?["ended"]?.array?.compactMap(\.string) == [idleID], "\(closed)")
        #expect(Set(closed.result?["left"]?.array?.compactMap(\.string) ?? []) == [NodeIds.session(host: busy.id), NodeIds.session(host: lead.id)], "\(closed)")
        #expect(!liveIDs().contains(idleID) && liveIDs().contains(NodeIds.session(host: busy.id)) && liveIDs().contains(NodeIds.session(host: lead.id)))
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["session.close-shells"])

        // None finished now: refused, nothing ended.
        let none = try #require(await world.ask("session.close-shells", ["sessions": .array([.string(NodeIds.session(host: busy.id))])]))
        #expect(none.error?.code == NodeWire.Code.refused.rawValue, "\(none)")
        #expect(liveIDs().contains(NodeIds.session(host: busy.id)))
    }
}

