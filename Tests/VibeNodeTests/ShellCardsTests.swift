import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Shell requests on a node (`ShellCards.swift`, the app's `ShellDesk`): a request the scratch host stamped for a session
/// it runs is a `shell` card showing the folder and the exact command; nothing runs until `answer CARD run` (the user's
/// voice, the card's code), which starts a shell session in that folder; `decline` declines it; unanswered it expires;
/// a request the host didn't stamp is never shown. Everything on a scratch host, its sessions running `sleep`.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ShellCardsTests {
    private let scratch = Scratch()

    /// A session of the scratch host to ask from, and a request filed for it as `vs-shell run` files one, stamped by the
    /// host's own book for that session.
    private func file(_ world: CardWorld, command: [String] = ["echo", "shell-card-ran"], label: String = "probe",
                      at: Date = Date()) async throws -> (asker: HostSession, request: ShellRequest) {
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        let session = asker.id.uuidString.lowercased()
        let vault = world.host.book.vault(folder: scratch.url("asker-vault"), as: { .session(session) }, userOpened: true)
        let folder = world.engine.shellFolder
        let filed = await offPool { ShellAsk.run(["run", "--label", label, "--"] + command, cwd: world.repo, folder: folder, now: at, vault: vault) }
        try #require(filed.status == 0, "\(filed)")
        let request = try #require(ShellAsk.filed(in: folder).requests.first { $0.session == session })
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.link.sessions.contains { $0.id == asker.id && $0.isLive } } })
        return (asker, request)
    }

    private func look(_ world: CardWorld, at now: Date? = nil) async {
        let done = Locked(false)
        world.queue.async {
            if let now { world.engine.shellNow = { now } }
            world.engine.lookAtShellRequests { done.value = true }
        }
        _ = await eventually(timeout: 60) { done.value }
    }

    private func shellCard(_ world: CardWorld, _ request: ShellRequest) -> CardStore.Card? {
        world.queue.sync { world.engine.cards.cards.values.first { $0.shell?.request.id == request.id } }
    }

    @Test func aStampedRequestIsACardAndRunStartsItsShell() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (_, request) = try await file(world)
        await look(world)
        let card = try #require(shellCard(world, request))
        #expect(card.kind == .shell && card.isOpen && !card.isBlocking && card.root == world.repo)
        #expect(WireSchema.check(card.value, as: "card") == nil, "\(card.value)")
        // The command line shows the folder and the exact command, whole.
        let lines = CardText.lines(card.value)
        #expect(lines.contains("  in the folder: \(world.repo)"), "\(lines)")
        #expect(lines.contains("    | echo shell-card-ran"), "\(lines)")
        // `status` says one waits and the line that answers it.
        let status = try #require(await world.ask("status", action: nil))
        let notices = status.result?["notices"]?.array?.compactMap(\.string) ?? []
        #expect(notices.contains { $0.contains("a shell request waits for you") && $0.contains("vibeswitcher answer \(card.id) run") }, "\(notices)")

        // Only run or decline, and only with the card's code.
        let other = try #require(await world.answer(card, "maybe"))
        #expect(other.error?.code == NodeWire.Code.badArgs.rawValue, "\(other)")
        let wrong = try #require(await world.answer(card, "run", code: "ZZZZ"))
        #expect(wrong.error?.code == NodeWire.Code.voice.rawValue, "\(wrong)")
        #expect(ShellAsk.answer(request.id, in: world.engine.shellFolder) == nil, "nothing was started")

        let ran = try #require(await world.answer(card, "run"))
        #expect(ran.ok && ran.result?["outcome"]?.string == "started", "\(ran)")
        let answer = try #require(ShellAsk.answer(request.id, in: world.engine.shellFolder))
        #expect(answer.state == .started && answer.endTold == false)
        let shell = try #require(answer.shell.flatMap(UUID.init(uuidString:)))
        let started = try #require(try world.host.sessions().first { $0.id == shell })
        #expect(started.label == "Shell: probe" && started.cwd == world.repo, "\(started)")
        // The card closed, saying so; a second answer is refused and starts nothing.
        let closed = try #require(shellCard(world, request))
        #expect(!closed.isOpen && closed.closed?.contains("started in a new shell session") == true, "\(String(describing: closed.closed))")
        let again = try #require(await world.answer(closed, "run"))
        #expect(!again.ok, "\(again)")
        #expect(try world.host.sessions().filter { $0.label == "Shell: probe" }.count == 1)
        // The asking session is told it started (recorded once it reached it), at a look.
        let folder = world.engine.shellFolder
        var told = false
        for _ in 0..<300 where !told {
            await look(world)
            told = await eventually(timeout: 0.2) { ShellAsk.answer(request.id, in: folder)?.told == true }
        }
        #expect(told, "\(String(describing: ShellAsk.answer(request.id, in: folder)))")
    }

    @Test func declineRunsNothingAndAnUnansweredOneExpires() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let (asker, first) = try await file(world, label: "declined")
        await look(world)
        let card = try #require(shellCard(world, first))
        let declined = try #require(await world.answer(card, "decline"))
        #expect(declined.ok && declined.result?["outcome"]?.string == "declined", "\(declined)")
        #expect(ShellAsk.answer(first.id, in: world.engine.shellFolder)?.state == .declined)
        #expect(shellCard(world, first)?.isOpen == false)
        #expect(try world.host.sessions().allSatisfy { $0.label != "Shell: declined" })

        // Another, from the same session, left unanswered past its 30 minutes: expired, its card closed.
        let session = asker.id.uuidString.lowercased()
        let vault = world.host.book.vault(folder: scratch.url("asker-vault-2"), as: { .session(session) }, userOpened: true)
        let folder = world.engine.shellFolder
        let filed = await offPool { ShellAsk.run(["run", "--label", "late", "--", "true"], cwd: world.repo, folder: folder, vault: vault) }
        try #require(filed.status == 0)
        let second = try #require(ShellAsk.filed(in: folder).requests.first { $0.label == "late" })
        await look(world)
        #expect(shellCard(world, second)?.isOpen == true)
        await look(world, at: second.expiresAt.addingTimeInterval(1))
        #expect(ShellAsk.answer(second.id, in: folder)?.state == .expired)
        #expect(shellCard(world, second)?.isOpen == false)
        let expired = try #require(shellCard(world, second))
        let late = try #require(await world.answer(expired, "run"))
        #expect(!late.ok, "\(late)")
    }

    /// A request written into the folder without the host's stamp for its bytes and session is never shown, nor run.
    @Test func aRequestTheHostDidntStampIsNeverShown() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let asker = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Asker")
        let request = ShellRequest(session: asker.id.uuidString, cwd: world.repo, command: "echo forged", label: "forged", createdAt: Date())
        let bytes = try request.encoded()
        let forged = WalletStamp(session: request.session, digest: WalletStamp.digest(bytes), seal: String(repeating: "0", count: 64))
        try ShellAsk.file(request, stamp: forged, in: world.engine.shellFolder)
        try #require(await eventually(timeout: 60) { world.queue.sync { world.engine.link.sessions.contains { $0.id == asker.id && $0.isLive } } })
        await look(world)
        #expect(shellCard(world, request) == nil)
        #expect(world.queue.sync { world.engine.shellNotices }.isEmpty)
    }
}
