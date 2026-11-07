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
        var told: [(session: String, text: String)] = []
        var atOnce = false
        var names = [ShellDeskTests.session.uuidString.lowercased(): "Example agent"]
    }

    func desk(_ seen: Seen, clock: Clock, folder: URL) -> ShellDesk {
        let desk = ShellDesk(folder: folder, now: { clock.now }, log: { _ in })
        desk.sessionNames = { seen.names }
        desk.verifyStamps = { try WalletTestStamps.verify($0) }
        desk.deliver = { session, text, then in
            seen.told.append((session, text))
            then(.delivered)
        }
        desk.atOnce = { seen.atOnce }
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
        // Dismissed: gone.
        await acted(restarted, .dismiss, request.id)
        #expect(restarted.cards.isEmpty)
        #expect(ShellAsk.filed(in: folder).requests.isEmpty)
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
