import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The shell desk: a stamped request shows as a card in the asking session's chat and waits for Run (nothing starts
/// before); Run starts it once, Decline never; unanswered for 30 minutes it expires; the asker hears each outcome. With
/// Settings › Agents' setting on, a request starts at once and its card says so. A request the host didn't stamp, or
/// for a session it doesn't run, is never shown nor started. Fake sessions only: `launch` records, never spawns.
@MainActor
@Suite(.serialized)
struct ShellDeskTests {
    let temp = Scratch()
    static let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let shell = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
    /// Not the default 4 s, so these timers aren't mistaken for the "Not run" line's (`RunShown.lasts`).
    static let tidy: TimeInterval = 4.25
    static let created = Date(timeIntervalSince1970: 1_793_448_000)

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = ShellDeskTests.created.addingTimeInterval(5)
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return time }
            set { lock.lock(); time = newValue; lock.unlock() }
        }
    }

    final class Seen {
        var launched: [ShellRequest] = []
        /// The shells the user's Run started (`ShellDesk.userRan`), never one started at once.
        var userRan: [ShellRequest] = []
        var told: [(session: String, text: String)] = []
        var atOnce = false
        /// What the desk asked `later` to run, and when: tests fire these themselves, never wait.
        var timers: [(after: TimeInterval, run: () -> Void)] = []
        var names = [ShellDeskTests.session.uuidString.lowercased(): "Example agent"]
        /// The host's sessions, as the app's client has them.
        var sessions: [HostSession] = []
    }

    /// The Run card's shell as the host lists it: live, and how its command ended (nil: still running).
    static func shellSession(_ end: CommandEnd?, live: Bool = true, title: String = "") -> HostSession {
        var session = HostSession(id: shell, tty: "ttys009", childPID: 4242, cwd: "/work/example", command: "eval", label: "Shell: Local test",
                                  agent: nil, title: title, startedAt: created, cols: 120, rows: 36, exit: live ? nil : .init(status: 0, at: created))
        session.commandEnd = end
        return session
    }

    func desk(_ seen: Seen, clock: Clock, folder: URL) -> ShellDesk {
        let desk = ShellDesk(folder: folder, now: { clock.now }, log: { _ in })
        desk.sessionNames = { seen.names }
        desk.hostSessions = { seen.sessions }
        desk.verifyStamps = { try WalletTestStamps.verify($0) }
        desk.deliver = { session, text, then in
            seen.told.append((session, text))
            then(.delivered)
        }
        desk.atOnce = { seen.atOnce }
        desk.userRan = { request, _ in seen.userRan.append(request) }
        desk.later = { after, run in seen.timers.append((after, run)) }
        desk.fadeFor = { 0 }
        desk.tidyAfter = Self.tidy
        desk.launch = { request, then in
            seen.launched.append(request)
            then(.success((Self.shell, ShellAsk.sessionLabel(request))))
        }
        return desk
    }

    /// Files a request from the test's session with the test vault's stamp, as `vs-shell run` does.
    func file(_ folder: URL, command: String = "npm run local-test -- --workspace example", session: UUID = ShellDeskTests.session,
              stamped: Bool = true) throws -> ShellRequest {
        let request = ShellRequest(session: session.uuidString, cwd: "/work/example", command: command, label: "Local test", createdAt: Self.created)
        let digest = WalletStamp.digest(try request.encoded())
        let id = session.uuidString.lowercased()
        var stamp = WalletStamp(session: id, digest: digest, seal: String(repeating: "0", count: 64))
        if stamped, case .seal(let seal) = WalletTestStamps.book.answer(.sealWalletRequest(session: id, digest: digest), from: .session(id), userOpened: true) {
            stamp.seal = seal
        }
        try ShellAsk.file(request, stamp: stamp, in: folder)
        return request
    }

    func refreshed(_ desk: ShellDesk) async {
        var done = false
        desk.refresh { done = true }
        _ = await until { done }
    }

    func acted(_ desk: ShellDesk, _ action: ShellDesk.Action, _ id: String) async {
        var done = false
        desk.act(action, on: id) { done = true }
        _ = await until { done }
    }

    /// A card's Run through `ShellDesk.run`, as the card's button does: what came of it.
    func ran(_ desk: ShellDesk, _ id: String) async -> RunOutcome? {
        var outcome: RunOutcome?
        desk.run(id) { outcome = $0 }
        _ = await until { outcome != nil }
        return outcome
    }

    @Test func aRequestWaitsForRunThenStartsOnceAndTheAskerHearsTheName() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder)
        await refreshed(desk)
        let card = try #require(desk.cards(for: Self.session).first)
        #expect(card.asker == "Example agent" && card.request.command == "npm run local-test -- --workspace example")
        #expect(card.state == .waiting(until: Self.created.addingTimeInterval(30 * 60)))
        // Nothing starts before Run, whatever looks again.
        await refreshed(desk)
        #expect(seen.launched.isEmpty && seen.told.isEmpty)
        #expect(desk.cards(for: Self.shell).isEmpty)

        await acted(desk, .run, request.id)
        #expect(seen.launched == [request])
        #expect(seen.userRan == [request], "the user's Run vouches for what the shell does")
        #expect(desk.cards(for: Self.session).first?.state == .started(name: "Shell: Local test", auto: false))
        #expect(seen.told.count == 1 && seen.told.first?.session == Self.session.uuidString.lowercased())
        #expect(seen.told.first?.text.contains("the user pressed Run") == true)
        #expect(seen.told.first?.text.contains("\"Shell: Local test\" (session \(Self.shell.uuidString.lowercased()))") == true)
        // A second Run, a restart (a new desk on the same folder): it never starts again, and isn't told again.
        await acted(desk, .run, request.id)
        _ = await until { ShellAsk.answer(request.id, in: folder)?.told == true }
        let restarted = self.desk(seen, clock: clock, folder: folder)
        await refreshed(restarted)
        #expect(seen.launched.count == 1 && seen.told.count == 1, "\(seen.told.map(\.text))")
        #expect(restarted.cards.first?.state == .started(name: "Shell: Local test", auto: false))
        // Dismissed: gone, its files kept until its command's end is told; then they go too.
        await acted(restarted, .dismiss, request.id)
        #expect(restarted.cards.isEmpty)
        #expect(ShellAsk.filed(in: folder).requests.map(\.id) == [request.id])
        seen.sessions = [Self.shellSession(CommandEnd(ok: true, status: 0, startedAt: Self.created, at: Self.created, tail: "ok", cut: false))]
        await refreshed(restarted)
        // Told, then its files go at the next look.
        #expect(await until { seen.told.count == 2 })
        #expect(await until { ShellAsk.filed(in: folder).requests.isEmpty })
        #expect(restarted.cards.isEmpty && seen.told.count == 2)
    }

    /// Fires the oldest pending timer asked for `after` seconds, once.
    func fire(_ seen: Seen, after: TimeInterval) {
        guard let at = seen.timers.firstIndex(where: { $0.after == after }) else { Issue.record("no \(after)s timer pending"); return }
        seen.timers.remove(at: at).run()
    }

    @Test func aHandledCardLeavesByItselfAfterFourSeconds() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let ran = try file(folder, command: "make one"), declined = try file(folder, command: "make two")
        let waiting = try file(folder, command: "make three")
        await refreshed(desk)
        // Waiting for Run: nothing is scheduled, however often it looks.
        await refreshed(desk)
        #expect(seen.timers.isEmpty)
        await acted(desk, .run, ran.id)
        await acted(desk, .decline, declined.id)
        _ = await until { seen.timers.filter { $0.after == Self.tidy }.count == 2 }
        #expect(desk.cards.count == 3)
        fire(seen, after: Self.tidy); fire(seen, after: Self.tidy)
        _ = await until { desk.cards.count == 1 }
        #expect(desk.cards.map(\.id) == [waiting.id])
        // The waiting one never goes by itself; at its expiry it shows that, then goes too.
        clock.now = Self.created.addingTimeInterval(30 * 60)
        await refreshed(desk)
        #expect(desk.cards.first?.state == .expired)
        _ = await until { seen.timers.contains { $0.after == Self.tidy } }
        fire(seen, after: Self.tidy)
        _ = await until { desk.cards.isEmpty }
        #expect(desk.cards.isEmpty)
    }

    @Test func aFailedStartStaysUntilDismissed() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        desk.launch = { _, then in then(.failure(ShellAsk.Refusal("No such folder"))) }
        let request = try file(folder)
        await refreshed(desk)
        await acted(desk, .run, request.id)
        await refreshed(desk)
        #expect(seen.timers.filter { $0.after == Self.tidy }.isEmpty)
        #expect(desk.cards.first?.state == .failed("No such folder"))
    }

    @Test func aHeldCardStaysWhileThePointerOrFocusIsOnIt() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder)
        await refreshed(desk)
        await acted(desk, .run, request.id)
        _ = await until { seen.timers.contains { $0.after == Self.tidy } }
        desk.hold(request.id, true)
        fire(seen, after: Self.tidy)
        await refreshed(desk)
        #expect(desk.cards.count == 1, "held: it stays when its time is up")
        desk.hold(request.id, false)
        _ = await until { desk.cards.isEmpty }
        #expect(desk.cards.isEmpty, "let go: it goes")
    }

    @Test func aCardFadesBeforeItGoesAndDismissStillWorksAtAnyTime() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        desk.fadeFor = { 0.3 }
        let request = try file(folder), other = try file(folder, command: "make other")
        await refreshed(desk)
        await acted(desk, .run, request.id)
        await acted(desk, .run, other.id)
        _ = await until { seen.timers.filter { $0.after == Self.tidy }.count == 2 }
        fire(seen, after: Self.tidy)
        #expect(desk.leaving.count == 1 && desk.cards.count == 2, "fading, still there")
        let fading = try #require(desk.leaving.first)
        fire(seen, after: 0.3)
        _ = await until { desk.cards.count == 1 }
        #expect(desk.cards.map(\.id) == [fading == request.id ? other.id : request.id] && desk.leaving.isEmpty)
        // Dismissed before its time: gone at once, and its timer finds nothing.
        await acted(desk, .dismiss, desk.cards[0].id)
        #expect(desk.cards.isEmpty)
        fire(seen, after: Self.tidy)
        await refreshed(desk)
        #expect(desk.cards.isEmpty && desk.leaving.isEmpty)
    }

    @Test func declineStartsNothingAndUnansweredExpires() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let declined = try file(folder, command: "make serve")
        let ignored = try file(folder, command: "make watch")
        await refreshed(desk)
        await acted(desk, .decline, declined.id)
        // Run on a declined card does nothing.
        await acted(desk, .run, declined.id)
        #expect(desk.cards.first { $0.id == declined.id }?.state == .declined)
        #expect(seen.told.map(\.text).filter { $0.contains("declined by the user") }.count == 1)
        clock.now = Self.created.addingTimeInterval(30 * 60)
        await refreshed(desk)
        #expect(desk.cards.first { $0.id == ignored.id }?.state == .expired)
        #expect(seen.told.map(\.text).filter { $0.contains("expired after 30 minutes") && $0.contains(ignored.id) }.count == 1)
        await acted(desk, .run, ignored.id)
        #expect(seen.launched.isEmpty)
    }

    @Test func withTheSettingOnARequestStartsAtOnceAndTheCardSaysSo() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        seen.atOnce = true
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder)
        await refreshed(desk)
        _ = await until { desk.cards.first?.state == .started(name: "Shell: Local test", auto: true) }
        #expect(desk.cards.first?.state == .started(name: "Shell: Local test", auto: true))
        #expect(seen.launched == [request])
        #expect(seen.userRan.isEmpty, "nobody pressed Run: a shell started at once vouches for nothing it commits")
        #expect(seen.told.first?.text.contains("at once") == true)
        // One filed long before it was first seen (the app was closed) waits for the click even so.
        clock.now = Self.created.addingTimeInterval(20 * 60)
        let late = try file(folder, command: "make late")
        let other = self.desk(seen, clock: clock, folder: folder)
        await refreshed(other)
        #expect(other.cards.first { $0.id == late.id }?.state == .waiting(until: late.expiresAt))
        #expect(seen.launched.count == 1)
    }

    @Test func unstampedOrForAnotherSessionIsNeverShownNorStarted() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        seen.atOnce = true
        let desk = desk(seen, clock: clock, folder: folder)
        _ = try file(folder, command: "forged", stamped: false)
        // Stamped for a session the host doesn't run (or that ended): no card, and nothing starts.
        _ = try file(folder, command: "elsewhere", session: UUID())
        // Dated ahead of the app's clock, so it would never expire: not shown either.
        let ahead = ShellRequest(session: Self.session.uuidString, cwd: "/work/example", command: "later", label: "", createdAt: Self.created.addingTimeInterval(86_400 * 365))
        let digest = WalletStamp.digest(try ahead.encoded()), id = Self.session.uuidString.lowercased()
        guard case .seal(let seal) = WalletTestStamps.book.answer(.sealWalletRequest(session: id, digest: digest), from: .session(id), userOpened: true) else {
            Issue.record("no seal"); return
        }
        try ShellAsk.file(ahead, stamp: WalletStamp(session: id, digest: digest, seal: seal), in: folder)
        await refreshed(desk)
        await refreshed(desk)
        #expect(desk.cards.isEmpty)
        #expect(seen.launched.isEmpty)
    }

    @Test func aRunThatCantStartSaysWhy() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        desk.launch = { _, then in then(.failure(ShellAsk.Refusal("No such folder: /work/example"))) }
        let request = try file(folder)
        await refreshed(desk)
        await acted(desk, .run, request.id)
        #expect(desk.cards.first?.state == .failed("No such folder: /work/example"))
        #expect(seen.told.first?.text.contains("didn't start (No such folder: /work/example)") == true)
    }

    /// The user's report (2026-11-12): the lead only heard "started" while the command had failed. Once the host shows
    /// the command ended, the asking session gets one message with the request's id, the exit status and the output's
    /// last lines; never again, whatever looks again, a restart included.
    @Test func aFailedCommandIsToldToTheAskerOnceWithItsStatusAndLastLines() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder, command: "bash -c git log -1 --oneline && scripts/build-app.sh --install")
        await refreshed(desk)
        await acted(desk, .run, request.id)
        #expect(await until { ShellAsk.answer(request.id, in: folder)?.told == true })
        #expect(seen.told.count == 1)
        // Running: nothing more.
        seen.sessions = [Self.shellSession(nil)]
        await refreshed(desk)
        #expect(seen.told.count == 1)

        let usage = "usage: git [-v | --version] [-h | --help] [-C <path>]\n           <command> [<args>]"
        seen.sessions = [Self.shellSession(CommandEnd(ok: false, status: 1, startedAt: Self.created, at: Self.created.addingTimeInterval(1),
                                                      tail: usage, cut: false))]
        await refreshed(desk)
        #expect(await until { ShellAsk.answer(request.id, in: folder)?.endTold == true })
        #expect(seen.told.count == 2, "\(seen.told.map(\.text))")
        let told = try #require(seen.told.last)
        #expect(told.session == Self.session.uuidString.lowercased())
        #expect(told.text.contains("Shell request \(request.id)") && told.text.contains("FAILED: the command exited with status 1"), "\(told.text)")
        #expect(told.text.contains(usage), "\(told.text)")
        for _ in 0..<3 { await refreshed(desk) }
        await refreshed(self.desk(seen, clock: clock, folder: folder))
        #expect(seen.told.count == 2)
    }

    /// Exit 0: one message saying it succeeded. The shell then stays open as an interactive shell (its title changes,
    /// it's used): nothing more is sent. And the card leaving by itself before the end doesn't lose it.
    @Test func aSucceededCommandIsToldOnceAndTheOpenShellAfterSendsNothing() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder)
        await refreshed(desk)
        await acted(desk, .run, request.id)
        #expect(await until { seen.timers.contains { $0.after == Self.tidy } })
        fire(seen, after: Self.tidy)
        #expect(await until { desk.cards.isEmpty })
        #expect(desk.cards.isEmpty && seen.told.count == 1)

        let end = CommandEnd(ok: true, status: 0, startedAt: Self.created, at: Self.created.addingTimeInterval(95), tail: "42 passed", cut: false)
        seen.sessions = [Self.shellSession(end)]
        await refreshed(desk)
        #expect(await until { seen.told.count == 2 })
        #expect(seen.told.last?.text.contains("succeeded: the command exited with status 0 after 1m") == true, "\(seen.told.map(\.text))")
        #expect(seen.told.last?.text.contains("42 passed") == true)
        #expect(await until { ShellAsk.filed(in: folder).requests.isEmpty })
        for title in ["vim notes.txt", "zsh", ""] {
            seen.sessions = [Self.shellSession(end, title: title)]
            await refreshed(desk)
        }
        seen.sessions = [Self.shellSession(end, live: false)]
        await refreshed(desk)
        #expect(seen.told.count == 2 && desk.cards.isEmpty)
    }

    /// Fail closed: the shell ended before its command said how it ended (it ran `exit`, or was closed), or isn't the
    /// host's any more: the asker hears that its status and output weren't captured. A shell the host doesn't list yet
    /// just after it started isn't called gone.
    @Test func aShellThatEndedFirstSaysNothingWasCaptured() async throws {
        let folder = temp.url("shells"), seen = Seen(), clock = Clock()
        let desk = desk(seen, clock: clock, folder: folder)
        let request = try file(folder), other = try file(folder, command: "make gone")
        seen.sessions = [Self.shellSession(nil)]
        await refreshed(desk)
        await acted(desk, .run, request.id)
        #expect(await until { seen.told.count == 1 })
        seen.sessions = [Self.shellSession(nil, live: false)]
        await refreshed(desk)
        #expect(await until { seen.told.count == 2 })
        #expect(seen.told.last?.text.contains("ended (its shell exited with status 0) before the command said how it ended") == true)
        #expect(seen.told.last?.text.contains("weren't captured") == true)

        desk.launch = { _, then in then(.success((UUID(), "Shell: Local test"))) }
        await acted(desk, .run, other.id)
        #expect(await until { seen.told.count == 3 })
        await refreshed(desk)
        #expect(seen.told.count == 3, "not listed yet just after it started: not gone")
        clock.now = clock.now.addingTimeInterval(ShellDesk.startingFor + 1)
        await refreshed(desk)
        #expect(await until { seen.told.count == 4 })
        #expect(seen.told.last?.text.contains("is gone from VibeSwitcher") == true, "\(seen.told.map(\.text))")
    }
}

/// A shell card's Run follows the chat's one Run rule: it ends in ran or in a "Not run: …" line from `RunRefusal`
/// (the card shows it, `ShellDesk.refused`), and a pressed Run starts its shell exactly once, a double press included.
/// Its command is never typed: `launch` gets the request, nothing else.
@MainActor
@Suite(.serialized)
struct ShellCardRunTests {
    let base = ShellDeskTests()

    @Test func aRunStartsOnceAndAnswersRanAndASecondPressSaysWhyNot() async throws {
        let folder = base.temp.url("shells"), seen = ShellDeskTests.Seen(), clock = ShellDeskTests.Clock()
        let desk = base.desk(seen, clock: clock, folder: folder)
        let request = try base.file(folder)
        await base.refreshed(desk)
        // Pressed twice before the first one's shell is up: one start; the second press says it was answered.
        var outcomes: [RunOutcome] = []
        desk.run(request.id) { outcomes.append($0) }
        desk.run(request.id) { outcomes.append($0) }
        _ = await until { outcomes.count == 2 }
        #expect(seen.launched == [request])
        #expect(outcomes.contains(.ran))
        #expect(outcomes.contains(.refused(RunRefusal.shellAnswered)))
        #expect(desk.cards.first?.state == .started(name: "Shell: Local test", auto: false))
        // Once started, Run again: refused with the same words, nothing starts.
        #expect(await base.ran(desk, request.id) == .refused(RunRefusal.shellAnswered))
        #expect(seen.launched.count == 1)
    }

    @Test func aRunThatCantGoSaysWhyInTheChatsWordsOnTheCard() async throws {
        let folder = base.temp.url("shells"), seen = ShellDeskTests.Seen(), clock = ShellDeskTests.Clock()
        let desk = base.desk(seen, clock: clock, folder: folder)
        var refuse = true
        let launch = desk.launch
        desk.launch = { request, then in
            refuse ? then(.failure(ShellAsk.Refusal("No such folder: /work/example"))) : launch(request, then)
        }
        let failing = try base.file(folder, command: "make serve")
        let declined = try base.file(folder, command: "make watch")
        let late = try base.file(folder, command: "make late")
        await base.refreshed(desk)

        // The session didn't start: the card's state and its line say the same "Not run: …".
        let notStarted = RunRefusal.shellNotStarted("No such folder: /work/example")
        #expect(await base.ran(desk, failing.id) == .refused(notStarted))
        #expect(desk.refused[failing.id] == notStarted)
        let card = try #require(desk.cards.first { $0.id == failing.id })
        #expect(card.state == .failed("No such folder: /work/example"))
        #expect(ShellCard.title(card.state) == "Not run" && ShellCard.detail(card) == notStarted)
        // The detail already says it: no second line.
        #expect(ShellCard.notice(desk.refused[failing.id], card) == nil)

        // Declined, then Run: refused, and the card's line says why.
        refuse = false
        await base.acted(desk, .decline, declined.id)
        #expect(await base.ran(desk, declined.id) == .refused(RunRefusal.shellAnswered))
        let declinedCard = try #require(desk.cards.first { $0.id == declined.id })
        #expect(ShellCard.notice(desk.refused[declined.id], declinedCard) == RunRefusal.shellAnswered)

        // A Run that goes answers ran, and its card shows no "Not run" line.
        let fine = try base.file(folder, command: "make fine")
        await base.refreshed(desk)
        #expect(await base.ran(desk, fine.id) == .ran)
        #expect(desk.refused[fine.id] == nil)

        // Past its 30 minutes but not yet redrawn as expired: refused as expired, and the card then says Expired.
        clock.now = late.expiresAt
        #expect(await base.ran(desk, late.id) == .refused(RunRefusal.shellExpired))
        #expect(desk.cards.first { $0.id == late.id }?.state == .expired)

        // A request that's gone.
        #expect(await base.ran(desk, "no-such-request") == .refused(RunRefusal.shellGone))

        #expect(seen.launched == [fine])
        for reason in [notStarted, RunRefusal.shellAnswered, RunRefusal.shellExpired, RunRefusal.shellGone] {
            #expect(reason.hasPrefix("Not run: "), "\(reason)")
        }
    }

    @Test func aCardsNotRunLineGoesInItsTimeWhateverOtherCardsDo() async throws {
        let folder = base.temp.url("shells"), seen = ShellDeskTests.Seen(), clock = ShellDeskTests.Clock()
        let desk = base.desk(seen, clock: clock, folder: folder)
        var clears: [() -> Void] = []
        desk.later = { after, clear in if after != ShellDeskTests.tidy { clears.append(clear) } }
        let refused = try base.file(folder, command: "make serve")
        let other = try base.file(folder, command: "make watch")
        await base.refreshed(desk)
        await base.acted(desk, .decline, refused.id)
        #expect(await base.ran(desk, refused.id) == .refused(RunRefusal.shellAnswered))
        // Another card's Runs before this one's line has shown its time: they don't keep it up.
        #expect(await base.ran(desk, other.id) == .ran)
        #expect(await base.ran(desk, other.id) == .refused(RunRefusal.shellAnswered))
        #expect(desk.refused[refused.id] == RunRefusal.shellAnswered)
        clears.first?()
        #expect(desk.refused[refused.id] == nil)
        #expect(desk.refused[other.id] == RunRefusal.shellAnswered)
        // A later refusal of the same card outlives an earlier one's time.
        #expect(await base.ran(desk, refused.id) == .refused(RunRefusal.shellAnswered))
        clears[1]()
        #expect(desk.refused[refused.id] == RunRefusal.shellAnswered)
        clears.last?()
        #expect(desk.refused[refused.id] == nil)
    }

    @Test func theCardsRunButtonShowsWhatTheChatsShows() {
        #expect(RunShown(.ran) == .sent && RunShown(.refused("Not run: x")) == .refused("Not run: x"))
        #expect(RunShown.ready.label == "Run" && RunShown.refused("Not run: x").label == "Not run")
        #expect(RunShown.refused("Not run: x").reason == "Not run: x" && RunShown.ready.reason == nil)
    }
}

/// Settings › Agents › Let agents open shells without asking: off until the user turns it on, kept once on, and its
/// help line says what it allows.
struct ShellSettingTests {
    let temp = Scratch()

    @Test func offByDefaultKeptOnceOnAndSaidPlainly() {
        let defaults = temp.defaults("shell-setting")
        let presets = temp.url("presets").appendingPathComponent("presets.json")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        #expect(preferences.letAgentsOpenShells == false)
        preferences.letAgentsOpenShells = true
        #expect(Preferences(defaults: defaults, presetsFile: presets).letAgentsOpenShells)
        // The key vs-shell reads to say it starts at once.
        #expect(defaults.bool(forKey: "letAgentsOpenShells"))
        let help = AgentsSettings.openShellsHelp
        #expect(help.contains("nothing runs until you press Run") && help.contains("running any command as you, with no click"))
    }
}
