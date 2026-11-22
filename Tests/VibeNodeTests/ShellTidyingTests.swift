import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The node's Run-card shell tidier (`ShellTidying.swift`, the app's `ShellTidier`, the feature review of 2026-11-22):
/// a Run card's shell whose command went well, ten minutes ago and back at its prompt, untouched and leaving nothing
/// running, is ended by itself; one typed into after its command ended (the link tells), one whose command failed, and
/// a plain shell aren't; the record of typed-into shells survives the server. Only scratch sessions start; the clock and
/// the process-table reads are the test's.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ShellTidyingTests {
    private let scratch = Scratch()

    private func runCard(_ world: CardWorld, _ command: String) async throws -> HostSession {
        let request = ShellAsk.spawnRequest(ShellRequest(session: UUID().uuidString, cwd: world.repo, command: command, label: "", createdAt: Date()))
        let socket = world.host.socket
        let reply = try await offPool { try HostCall.request(.spawn(request), socket: socket, appKey: nil, timeout: 60) }
        guard case .spawned(let session) = reply else { throw HostCall.Failure(description: "not started: \(reply)") }
        return session
    }

    @Test func aFinishedUntouchedRunCardShellEndsByItselfAndNoOtherDoes() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (engine, link) = (world.engine, world.world.link)
        let good = try await runCard(world, "true")
        let typed = try await runCard(world, "true")
        let failed = try await runCard(world, "false")
        let plain = try await world.host.spawn("exec /bin/bash --norc -i", cwd: world.repo, label: "Shell", keepShell: true)
        // Each Run card's command has ended, as the host captured it.
        let ending = { (id: UUID) in world.queue.sync { link.sessions.first { $0.id == id }.flatMap(ShellTidy.ending(of:)) } }
        try #require(await eventually(timeout: 60) { ending(good.id)?.ok == true && ending(typed.id)?.ok == true && ending(failed.id)?.ok == false })
        // Typed into after its command ended: the link tells the engine, which keeps it.
        link.type([HostInput.Write(bytes: Array("echo mine\r".utf8), delay: 0)], into: typed.id)
        try #require(await eventually(timeout: 30) { engine.queue.sync { engine.shellUsed.contains(typed.id) } })
        let record = try #require(try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: engine.shellUsedFile)))
        #expect(record == [typed.id])

        // Before ten minutes: nothing ends.
        let early = Locked<[UUID]?>(nil)
        engine.queue.async { engine.tidyShells(idle: { _ in true }, leftRunning: { _, _ in false }) { early.value = $0 } }
        try #require(await eventually(timeout: 30) { early.value != nil })
        #expect(early.value == [])
        // Ten minutes on, at their prompts, nothing left running: only the untouched one that went well.
        engine.queue.sync { engine.shellNow = { Date().addingTimeInterval(ShellTidy.idleFor + 5) } }
        let ended = Locked<[UUID]?>(nil)
        engine.queue.async { engine.tidyShells(idle: { _ in true }, leftRunning: { _, _ in false }) { ended.value = $0 } }
        try #require(await eventually(timeout: 30) { ended.value != nil })
        #expect(ended.value == [good.id])
        let live = { world.queue.sync { Set(link.sessions.filter(\.isLive).map(\.id)) } }
        try #require(await eventually(timeout: 30) { !live().contains(good.id) })
        #expect(live().isSuperset(of: [typed.id, failed.id, plain.id]))
        // One that left something running, or isn't at its prompt, stays.
        let busy = try await runCard(world, "true")
        try #require(await eventually(timeout: 60) { ending(busy.id)?.ok == true })
        for (idle, left) in [(false, false), (true, true)] {
            let none = Locked<[UUID]?>(nil)
            engine.queue.async { engine.tidyShells(idle: { _ in idle }, leftRunning: { _, _ in left }) { none.value = $0 } }
            try #require(await eventually(timeout: 30) { none.value != nil })
            #expect(none.value == [], "idle \(idle), left running \(left)")
        }
        // The record survives the server: a fresh read of the file gives it back.
        engine.queue.sync {
            engine.shellUsedLoaded = false
            engine.shellUsed = []
            engine.loadShellUsed()
        }
        #expect(engine.queue.sync { engine.shellUsed.contains(typed.id) })
    }
}
