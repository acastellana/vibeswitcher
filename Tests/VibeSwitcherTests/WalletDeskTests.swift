import CryptoKit
import Foundation
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// A fake `passage` in a scratch folder (never the real one, its Keychain, pairings or inbox): `calls` holds one line
/// of arguments per run; `send-exit` sets send's exit code; `inbox.jsonl` is what `inbox` prints, `peers.jsonl` what
/// `peers` prints; `listen` sleeps until it's stopped.
struct WalletFakePassage {
    static let peer = "0a1b2c3d"
    let folder: URL
    /// `passage` in `folder`, or with `app`, the binary of a fake `Passage.app` there.
    let executable: String
    var inbox: URL { folder.appendingPathComponent("inbox", isDirectory: true) }
    /// The fake app bundle (with `app`).
    var app: URL { folder.appendingPathComponent("Passage.app", isDirectory: true) }

    /// With `app`, it's Passage.app's binary: it acts only when its first argument is `cli` (logged with the rest), and
    /// otherwise says it would open its window and exits 70, as the real one would open it.
    init(_ scratch: Scratch, name: String = "passage", app: Bool = false) throws {
        folder = scratch.url(name)
        executable = app ? folder.appendingPathComponent("Passage.app/Contents/MacOS/Passage").path : folder.appendingPathComponent("passage").path
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (executable as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let cli = app ? #"if [ "$1" = cli ]; then shift; else echo "Passage: would open its window" >&2; exit 70; fi"# : ""
        let script = """
            #!/bin/bash
            here="\(folder.path)"
            printf '%s\\n' "$*" >> "$here/calls"
            \(cli)
            case "$1" in
            send)
                code=$(cat "$here/send-exit" 2>/dev/null || echo 0)
                cp "$3" "$here/sent-$5"
                if [ "$code" = 0 ]; then printf 'sent\\t%s\\t%s\\t%s\\n' "$2" "$5" "$(wc -c < "$3" | tr -d ' ')"; else echo "passage: fake exit $code" >&2; fi
                exit "$code" ;;
            inbox) cat "$here/inbox.jsonl" 2>/dev/null; exit 0 ;;
            peers) cat "$here/peers.jsonl" 2>/dev/null; exit 0 ;;
            listen)
                trap 'kill $! 2>/dev/null; exit 0' TERM
                /bin/sleep 3600 &
                wait $!
                exit 0 ;;
            esac
            exit 2
            """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        chmod(executable, 0o755)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    var calls: [String] { ((try? String(contentsOf: file("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var sends: [String] { calls.filter { $0.hasPrefix("send ") } }
    func setSendExit(_ code: Int32) throws { try "\(code)\n".write(to: file("send-exit"), atomically: true, encoding: .utf8) }

    /// Puts `result` in the inbox from the Wallet Manager peer, as passage would, and lists it in `inbox.jsonl`.
    func receive(_ result: WalletResult, second: Int) throws {
        let data = try result.encoded()
        let name = WalletResult.fileName(result.id)
        let dir = inbox.appendingPathComponent(Self.peer, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(format: "20261031T1201%02dZ", second)
        let path = dir.appendingPathComponent("\(stamp)-\(name)").path
        try data.write(to: URL(fileURLWithPath: path))
        let line = WalletRequestFormat.Value.object([.init("peerID", .string(Self.peer)), .init("name", .string(name)),
                                             .init("size", .integer(Int64(data.count))), .init("receivedAt", .string(stamp)),
                                             .init("path", .string(path))]).encoded()
        let list = file("inbox.jsonl")
        let before = (try? Data(contentsOf: list)) ?? Data()
        try (before + line + Data("\n".utf8)).write(to: list)
    }
}

/// The Wallet Manager desk: requests agents filed show as cards that wait for Send to Wallet Manager (nothing goes before the click);
/// Send, Retry and Discard; the Wallet Manager's results update the card and go to the asking session.
@MainActor
@Suite(.serialized)
struct WalletDeskTests {
    let temp = Scratch()
    static let created = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z
    static let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    /// The name the window gives the test's session.
    static let sessionName = "Example session"

    /// The sessions the session host runs, as the desk reads them: the test's own, and `others`.
    static func names(_ others: UUID...) -> [String: String] {
        var names = [session.uuidString.lowercased(): sessionName]
        for other in others { names[other.uuidString.lowercased()] = "Harness session" }
        return names
    }

    final class Told: @unchecked Sendable {
        var messages: [(session: String, text: String)] = []
    }

    struct Setup {
        let fake: WalletFakePassage
        let desk: WalletDesk
        let asked: URL
        let store: WalletRequestStore
        let told: Told
    }

    /// The desk's clock. `hold()` makes the next reading of it (on the desk's queue) wait until `release()`, so a test
    /// can line something up behind what the desk is doing at that instant.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = WalletDeskTests.created.addingTimeInterval(30)
        private var gate: DispatchSemaphore?
        /// The gate a reading waits on now.
        private var holding: DispatchSemaphore?

        var now: Date {
            get {
                lock.lock()
                let (gate, time) = (self.gate, self.time)
                if gate != nil {
                    self.gate = nil
                    holding = gate
                }
                lock.unlock()
                gate?.wait()
                return time
            }
            set {
                lock.lock()
                time = newValue
                lock.unlock()
            }
        }

        func hold() {
            lock.lock()
            gate = DispatchSemaphore(value: 0)
            lock.unlock()
        }

        /// The desk is waiting on a reading `hold` armed.
        var held: Bool {
            lock.lock()
            defer { lock.unlock() }
            return holding != nil
        }

        func release() {
            lock.lock()
            let gate = holding
            holding = nil
            lock.unlock()
            gate?.signal()
        }
    }

    func setup(peer: String = WalletFakePassage.peer, clock: Clock = Clock(), peers: WalletBrowserDeskTests.Peer? = nil) throws -> Setup {
        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox,
                             config: { WalletDesk.Config(passage: fake.executable, peer: peers?.id ?? peer) }, now: { clock.now }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        desk.findPassage = { nil }
        let told = Told()
        desk.deliver = { session, text in told.messages.append((session, text)) }
        return Setup(fake: fake, desk: desk, asked: asked, store: store, told: told)
    }

    /// A filed request names a session; only one the session host runs gets a card, named as the window names it. With no
    /// sessions known (the default, or the host not answered yet), no card at all.
    @Test func aRequestFromASessionTheHostDoesntRunGetsNoCard() async throws {
        let s = try setup()
        let stranger = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        try WalletAsk.file(Self.request(2, session: stranger), in: s.asked)
        try WalletAsk.file(Self.request(1), in: s.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.map(\.id) == [Self.request(1).id])
        // Nothing can be done to a request without a card.
        var done = false
        s.desk.act(.discard, on: Self.request(2).id) { done = true }
        _ = await until { done }
        #expect(FileManager.default.fileExists(atPath: s.asked.appendingPathComponent("\(Self.request(2).id).json").path))
        // Once the host runs it, its card shows, by the window's name.
        s.desk.sessionNames = { Self.names(stranger) }
        await refreshed(s.desk)
        #expect(s.desk.cards(for: stranger).map(\.requestedBy) == ["Harness session"])
        // Fail closed: a desk that knows no sessions shows nothing.
        s.desk.sessionNames = { [:] }
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        #expect(s.fake.sends.isEmpty)
    }

    /// The session on a card is the one the host stamped the request for, from the filing process: a request written
    /// into the folder by hand (naming a session the host runs), one stamped for another session than it names (a
    /// session its filer started, say), one whose seal isn't the host's, or one rewritten after filing gets no card,
    /// and goes. While the host can't be asked, no card either, and nothing goes.
    @Test func onlyARequestTheHostStampedForTheSessionItNamesGetsACard() async throws {
        let s = try setup()
        let child = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
        s.desk.sessionNames = { Self.names(child) }
        let stamped = Self.request(1)
        try WalletAsk.file(stamped, in: s.asked)
        // By hand: the bytes, no stamp.
        let byHand = Self.request(2)
        try VibePaths.writePrivate(try byHand.encoded(), to: s.asked.appendingPathComponent("\(byHand.id).json"))
        // Filed from the session that started `child`, naming `child`: the host seals it for its own session only.
        let fromParent = Self.request(3, session: child)
        let parentStamp = try WalletTestStamps.stamp(Self.request(3))
        try VibePaths.writePrivate(try fromParent.encoded(), to: s.asked.appendingPathComponent("\(fromParent.id).json"))
        try VibePaths.writePrivate(JSONEncoder().encode(WalletStamp(session: child.uuidString.lowercased(), digest: WalletStamp.digest(try fromParent.encoded()),
                                                                  seal: parentStamp.seal)), to: WalletAsk.stampFile(fromParent.id, in: s.asked))
        // A seal made up for the right session and bytes.
        let forged = Self.request(4)
        try VibePaths.writePrivate(try forged.encoded(), to: s.asked.appendingPathComponent("\(forged.id).json"))
        try VibePaths.writePrivate(JSONEncoder().encode(WalletStamp(session: Self.session.uuidString.lowercased(), digest: WalletStamp.digest(try forged.encoded()),
                                                                  seal: String(repeating: "ab", count: 32))), to: WalletAsk.stampFile(forged.id, in: s.asked))
        // Stamped, then rewritten (another amount) under its stamp.
        let rewritten = Self.request(5)
        try WalletAsk.file(rewritten, in: s.asked)
        var changed = rewritten
        changed.amount = "999"
        try VibePaths.writePrivate(try changed.encoded(), to: s.asked.appendingPathComponent("\(rewritten.id).json"))

        await refreshed(s.desk)
        #expect(s.desk.cards.map(\.id) == [stamped.id])
        for gone in [byHand, fromParent, forged, rewritten] {
            #expect(!FileManager.default.fileExists(atPath: s.asked.appendingPathComponent("\(gone.id).json").path), "\(gone.id)")
            #expect(!FileManager.default.fileExists(atPath: WalletAsk.stampFile(gone.id, in: s.asked).path), "\(gone.id)")
        }

        // The host can't be asked: a new request waits with no card, and stays filed; once it answers, its card shows.
        struct Down: Error {}
        s.desk.verifyStamps = { _ in throw Down() }
        let later = Self.request(6)
        try WalletAsk.file(later, in: s.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.map(\.id) == [stamped.id])
        #expect(FileManager.default.fileExists(atPath: s.asked.appendingPathComponent("\(later.id).json").path))
        s.desk.verifyStamps = WalletTestStamps.verify
        await refreshed(s.desk)
        #expect(s.desk.cards.map(\.id) == [stamped.id, later.id])
        #expect(s.fake.sends.isEmpty && s.told.messages.isEmpty)
    }

    /// A request as `vs-wallet request` files it from the session `session`.
    static func request(_ number: Int = 1, session: UUID = WalletDeskTests.session) -> WalletRequest {
        WalletRequest(id: String(format: "00000000-0000-4000-8000-%012d", number), createdAt: created, expiresAt: created.addingTimeInterval(86_400),
                     requestedBy: .init(project: "example-project", session: session.uuidString.lowercased(), label: "Example agent"),
                     workspace: "example", from: "example-hardware", chainId: 42_424_242, action: .transfer,
                     to: "0x0000000000000000000000000000000000000001", asset: "native", amount: "1250000000000000000",
                     reason: "Pay the example invoice.")
    }

    static func result(_ request: WalletRequest, _ status: WalletResult.Status, sequence: Int64) -> WalletResult {
        var result = WalletResult(id: request.id, sequence: sequence, createdAt: created.addingTimeInterval(60), status: status,
                                 checks: [.init(name: "balance", ok: true, detail: "covers it")], message: "The Wallet Manager says \(status.rawValue).")
        if status == .submitted {
            result.txHash = "0x" + String(repeating: "ab", count: 32)
            result.explorerURL = "https://explorer.example/tx/" + result.txHash!
        }
        return result
    }

    func refreshed(_ desk: WalletDesk) async {
        var done = false
        desk.refresh { done = true }
        _ = await until { done }
    }

    func acted(_ desk: WalletDesk, _ action: WalletCardModel.Action, _ id: String) async {
        var done = false
        desk.act(action, on: id) { done = true }
        _ = await until { done }
    }

    func polled(_ desk: WalletDesk) async {
        var done = false
        desk.poll { done = true }
        _ = await until { done }
    }

    @Test func aFiledRequestWaitsForTheClickAndNothingIsSentBefore() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        let card = try #require(s.desk.cards(for: Self.session).first)
        #expect(card.state == .waiting)
        #expect(card.actions == [.send, .discard])
        #expect(card.workspace == "example")
        #expect(card.amount == "1.25" && card.asset == "GEN")
        // Named as the window names the session; the agent's own label beside it.
        #expect(card.requestedBy == Self.sessionName && card.requestedByLabel == "Example agent")
        #expect(card.requestedByText == "Example session (the agent's label: Example agent)")
        // Another session's chat doesn't show it.
        #expect(s.desk.cards(for: UUID()).isEmpty)
        // Looked at again, and a poll: still nothing sent.
        await refreshed(s.desk)
        await polled(s.desk)
        #expect(s.fake.sends.isEmpty, "\(s.fake.calls)")
        #expect(s.desk.cards.first?.state == .waiting)
        // The click sends it, once, under its name, never with --yes.
        await acted(s.desk, .send, request.id)
        #expect(s.fake.sends.count == 1)
        let sent = try #require(s.fake.sends.first)
        #expect(sent.hasPrefix("send \(WalletFakePassage.peer) ") && sent.hasSuffix("--name wallet-request-\(request.id).json"))
        #expect(!sent.contains("--yes"))
        #expect(try Data(contentsOf: s.fake.file("sent-wallet-request-\(request.id).json")) == request.encoded())
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.desk.cards.first?.actions == [])
        // A second Send isn't offered once it went.
        await acted(s.desk, .send, request.id)
        #expect(s.fake.sends.count == 1)
    }

    @Test func theWalletManagersAnswersUpdateTheCardAndGoToTheAskingSession() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        try s.fake.receive(Self.result(request, .received, sequence: 1), second: 1)
        await polled(s.desk)
        _ = await until { s.told.messages.count == 1 }
        #expect(s.desk.cards.first?.state == .received)
        #expect(s.desk.cards.first?.checks == [.init(name: "balance", ok: true, detail: "covers it")])
        try s.fake.receive(Self.result(request, .submitted, sequence: 2), second: 2)
        await polled(s.desk)
        _ = await until { s.told.messages.count == 2 }
        let hash = "0x" + String(repeating: "ab", count: 32)
        #expect(s.desk.cards.first?.state == .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)))
        #expect(s.told.messages.map(\.session) == [Self.session.uuidString.lowercased(), Self.session.uuidString.lowercased()])
        #expect(s.told.messages[0].text.contains("the Wallet Manager says received: The Wallet Manager says received."))
        #expect(s.told.messages[1].text.contains("submitted") && s.told.messages[1].text.contains(hash))
        #expect(s.told.messages[1].text.contains("This request is finished."))
        // Each answer once.
        await polled(s.desk)
        #expect(s.told.messages.count == 2)
    }

    /// The shared vector for a request that failed the format (docs/protocol/vectors), answered for `request`.
    static func formatRejection(_ request: WalletRequest) throws -> WalletResult {
        let vectors = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/protocol/vectors", isDirectory: true)
        var result = try WalletResult.parse(Data(contentsOf: vectors.appendingPathComponent("result-valid-rejected-format.json")))
        result.id = request.id
        return result
    }

    /// A request the Wallet Manager couldn't parse is answered rejected, its only check `format` (wallet-request.md, "The
    /// format check"): the card shows it rejected with that check's detail, the session is told once, and a second
    /// answer for the id is ignored, as after any final result.
    @Test func aRequestTheWalletManagerCouldntParseShowsRejectedWithTheFormatCheck() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        let rejection = try Self.formatRejection(request)
        let check = try #require(rejection.checks.first)
        try s.fake.receive(rejection, second: 1)
        await polled(s.desk)
        _ = await until { s.told.messages.count == 1 }
        #expect(s.desk.cards.first?.state == .rejected(reason: rejection.message))
        #expect(s.desk.cards.first?.checks == [.init(name: "format", ok: false, detail: check.detail)])
        #expect(s.told.messages.first?.text.contains("Failed checks: format (\(check.detail)).") == true)
        #expect(s.told.messages.first?.text.contains("This request is finished.") == true)

        // A second answer for the same id (a later sequence, another detail) changes nothing.
        var second = rejection
        second.sequence = 2
        second.checks = [.init(name: "format", ok: false, detail: "notJSON: a second answer")]
        second.message = "A second answer."
        try s.fake.receive(second, second: 2)
        await polled(s.desk)
        #expect(s.told.messages.count == 1)
        #expect(s.desk.cards.first?.state == .rejected(reason: rejection.message))
        #expect(s.desk.cards.first?.checks == [.init(name: "format", ok: false, detail: check.detail)])
        #expect(s.store.load().first { $0.request.id == request.id }?.results == [rejection])
    }

    @Test func retryResendsAfterPassageCouldntReachTheWalletManager() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        try s.fake.setSendExit(4)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .unreachable(message: "passage: fake exit 4"))
        #expect(s.desk.cards.first?.actions == [.retry, .discard])
        try s.fake.setSendExit(0)
        await acted(s.desk, .retry, request.id)
        #expect(s.fake.sends.count == 2)
        #expect(s.desk.cards.first?.state == .sent)
    }

    @Test func aSendThatMayHaveArrivedSaysSoAndMayBeRetried() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        try s.fake.setSendExit(1)
        await acted(s.desk, .send, request.id)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .unsure(message: "passage: fake exit 1"))
        #expect(card.detail.contains("may have reached the Wallet Manager"))
        #expect(card.actions == [.retry, .discard])
        // The same request again, under its id.
        try s.fake.setSendExit(0)
        await acted(s.desk, .retry, request.id)
        #expect(s.fake.sends.count == 2)
        #expect(s.desk.cards.first?.state == .sent)
    }

    @Test func discardDropsTheRequestAndTellsTheSession() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let waiting = Self.request(1), unsure = Self.request(2)
        try WalletAsk.file(waiting, in: s.asked)
        try WalletAsk.file(unsure, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .discard, waiting.id)
        #expect(s.desk.cards.map(\.id) == [unsure.id])
        #expect(!FileManager.default.fileExists(atPath: s.asked.appendingPathComponent("\(waiting.id).json").path))
        #expect(s.fake.sends.isEmpty)
        _ = await until { s.told.messages.count == 1 }
        #expect(s.told.messages.first?.text.contains("discarded by the user") == true)
        #expect(s.told.messages.first?.text.contains("It was not sent") == true)
        // An unsure one: forgotten, so its answers aren't listened for.
        try s.fake.setSendExit(1)
        await acted(s.desk, .send, unsure.id)
        #expect(FileManager.default.fileExists(atPath: s.store.file(unsure.id).path))
        await acted(s.desk, .discard, unsure.id)
        #expect(s.desk.cards.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.store.file(unsure.id).path))
        _ = await until { s.told.messages.count == 2 }
        #expect(s.told.messages.last?.text.contains("may have reached the Wallet Manager") == true)
        // Not shown again on the next look.
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
    }

    /// No peer chosen: the card still shows, without Send; a wallet id (not 0x) can't go to the browser wallet either,
    /// so it says it needs the Wallet Manager and offers Discard and Open Settings. Nothing runs Passage.
    @Test func withoutAWalletManagerPeerAWalletIdCardNeedsItAndOffersSettings() async throws {
        let s = try setup(peer: "")
        defer { s.desk.close() }
        var opened = 0
        s.desk.openSettings = { opened += 1 }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .waiting)
        #expect(card.actions == [.discard, .settings])
        #expect(card.setupNeeded == "No Wallet Manager chosen: choose its Mac in Settings › Wallet")
        #expect(card.detail.contains("It needs the Wallet Manager: a browser wallet can't use a wallet id."))
        await acted(s.desk, .send, request.id)
        await acted(s.desk, .browser, request.id)
        #expect(s.fake.calls.isEmpty)
        #expect(s.desk.cards.first?.state == .waiting)
        await acted(s.desk, .settings, request.id)
        #expect(opened == 1)
    }

    @Test func anUnsentRequestExpiresAndCantBeSent() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        clock.now = request.expiresAt.addingTimeInterval(1)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .expired)
        #expect(s.desk.cards.first?.actions == [])
        await acted(s.desk, .send, request.id)
        #expect(s.fake.sends.isEmpty)
        // Past the time any answer could come, its card goes.
        clock.now = request.expiresAt.addingTimeInterval(WalletCourier.resultGrace + 1)
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
    }

    @Test func anUnsentRequestThatExpiresTellsItsSessionOnce() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        #expect(s.told.messages.isEmpty)
        clock.now = request.expiresAt
        await refreshed(s.desk)
        // The delivery was queued on the main thread before the refresh's `then`.
        #expect(s.told.messages.count == 1)
        let told = try #require(s.told.messages.first)
        #expect(told.session == Self.session.uuidString.lowercased())
        #expect(told.text.contains(request.id) && told.text.contains("expired") && told.text.contains("without being sent"))
        #expect(told.text.contains("expired at 2026-11-01T12:00:00"))
        #expect(s.fake.sends.isEmpty)
        // Looked at again, and by an app started again (a desk of its own on the same folder): not told again.
        await refreshed(s.desk)
        let again = WalletDesk(folder: s.asked, store: s.store, inbox: s.fake.inbox,
                              config: { WalletDesk.Config(passage: s.fake.executable, peer: WalletFakePassage.peer) },
                              now: { clock.now }, log: { _ in })
        again.sessionNames = { WalletDeskTests.names() }
        again.verifyStamps = WalletTestStamps.verify
        again.findPassage = { nil }
        again.deliver = { session, text in s.told.messages.append((session, text)) }
        await refreshed(again)
        again.close()
        #expect(s.told.messages.count == 1)
        // Its card goes past the time any answer could come, and its marker with it.
        clock.now = request.expiresAt.addingTimeInterval(WalletCourier.resultGrace + 1)
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        #expect(!WalletAsk.toldExpired(request.id, in: s.asked))
        #expect(s.told.messages.count == 1)
    }

    @Test func aRequestThatExpiredWhileTheAppWasntRunningIsStillTold() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        clock.now = request.expiresAt.addingTimeInterval(WalletCourier.resultGrace + 1)
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        #expect(s.told.messages.count == 1)
        #expect(s.told.messages.first?.text.contains("without being sent") == true)
        await refreshed(s.desk)
        #expect(s.told.messages.count == 1)
    }

    @Test func aRequestPassageCouldntDeliverIsToldAsUnsentWhenItExpires() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        try s.fake.setSendExit(4)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .unreachable(message: "passage: fake exit 4"))
        clock.now = request.expiresAt
        await refreshed(s.desk)
        #expect(s.told.messages.count == 1)
        let text = try #require(s.told.messages.first?.text)
        #expect(text.contains("without being sent") && text.contains("never reached the Wallet Manager"))
        // The user did press Send: the message mustn't say they didn't.
        #expect(text.contains("or Passage couldn't deliver it") && !text.contains("didn't click"))
    }

    @Test func aSentRequestThatExpiresIsntToldAsUnsent() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let sent = Self.request(1), unsure = Self.request(2)
        try WalletAsk.file(sent, in: s.asked)
        try WalletAsk.file(unsure, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, sent.id)
        try s.fake.setSendExit(1)
        await acted(s.desk, .send, unsure.id)
        #expect(s.desk.cards.map(\.state) == [.sent, .unsure(message: "passage: fake exit 1")])
        clock.now = sent.expiresAt
        await refreshed(s.desk)
        clock.now = sent.expiresAt.addingTimeInterval(WalletCourier.resultGrace + 1)
        await refreshed(s.desk)
        #expect(s.told.messages.isEmpty, "\(s.told.messages)")
    }

    @Test func aFiledFileThatIsntARequestIsRefused() async throws {
        let s = try setup()
        defer { s.desk.close() }
        try VibePaths.ensurePrivate(s.asked)
        let bad = s.asked.appendingPathComponent("\(Self.request().id).json")
        try Data(#"{"type":"vibeswitcher.wallet-request"}"#.utf8).write(to: bad)
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    /// Blind check #3: the card shows what was sent, and a button sends only the request its card showed.
    @Test func theCardShowsWhatWasSentAndSendGoesOnlyWithWhatTheCardShowed() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let first = Self.request(1), second = Self.request(2)
        try WalletAsk.file(first, in: s.asked)
        try WalletAsk.file(second, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, first.id)
        // Rewritten under the same id after it went: the card still shows what was sent.
        var changed = first
        changed.amount = "9000000000000000000"
        try WalletAsk.file(changed, in: s.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.first { $0.id == first.id }?.amount == "1.25")
        // Rewritten while its card shows the old one: the click sends nothing; the card then shows the new one, waiting.
        var swapped = second
        swapped.to = "0x00000000000000000000000000000000000000ff"
        try WalletAsk.file(swapped, in: s.asked)
        s.desk.refresh()
        await acted(s.desk, .send, second.id)
        #expect(s.fake.sends.count == 1)
        let card = try #require(s.desk.cards.first { $0.id == second.id })
        #expect(card.to == swapped.to && card.state == .waiting)
    }

    /// Blind check #4: Discard forgets a record of an earlier run even with no courier now (no peer chosen).
    @Test func discardForgetsAnEarlierRunsRecordWithoutACourier() async throws {
        let s = try setup(peer: "")
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        try s.store.save(WalletRequestStore.Record(request: request, state: .unsure))
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .unsure(message: nil))
        await acted(s.desk, .discard, request.id)
        #expect(!FileManager.default.fileExists(atPath: s.store.file(request.id).path))
        _ = await until { s.told.messages.count == 1 }
        #expect(s.told.messages.first?.text.contains("may have reached the Wallet Manager") == true)
    }

    /// Blind check #2: a send an earlier run was in the middle of (`sending`) shows as unsure and may be sent again.
    @Test func aSendCutOffByAnEarlierRunMayBeRetried() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        try s.store.save(WalletRequestStore.Record(request: request, state: .sending))
        await refreshed(s.desk)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .unsure(message: nil))
        #expect(card.actions == [.retry, .discard])
        await acted(s.desk, .retry, request.id)
        #expect(s.fake.sends.count == 1)
        #expect(s.desk.cards.first?.state == .sent)
    }

    /// Review finding 1: Retry on an unsure card after the request expired doesn't pin Expired over its record: the
    /// Wallet Manager's answer to the earlier send, arriving later, still shows (submitted, with its hash).
    @Test func aRetryAfterExpiryLeavesTheRecordToDecide() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        try s.fake.setSendExit(1)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .unsure(message: "passage: fake exit 1"))
        clock.now = request.expiresAt.addingTimeInterval(1)
        await acted(s.desk, .retry, request.id)
        #expect(s.fake.sends.count == 1)
        #expect(s.desk.cards.first?.state == .unsure(message: "passage: fake exit 1"))
        try s.fake.receive(Self.result(request, .submitted, sequence: 1), second: 1)
        await polled(s.desk)
        let hash = "0x" + String(repeating: "ab", count: 32)
        #expect(await until { s.desk.cards.first?.state == .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)) })
        #expect(s.told.messages.count == 1)
    }

    /// Review finding 1: Retry on an unsure card when no courier can be made (the peer was cleared in Settings since
    /// the card was drawn) doesn't pin Not reachable over its record: the answer that arrives later still shows.
    @Test func aRetryWithNoCourierLeavesTheRecordToDecide() async throws {
        let peers = WalletBrowserDeskTests.Peer()
        let s = try setup(peers: peers)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        try s.fake.setSendExit(1)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.actions == [.retry, .discard])
        peers.id = ""
        await acted(s.desk, .retry, request.id)
        #expect(s.fake.sends.count == 1)
        #expect(s.desk.cards.first?.state == .unsure(message: "passage: fake exit 1"))
        peers.id = WalletFakePassage.peer
        try s.fake.receive(Self.result(request, .submitted, sequence: 1), second: 1)
        await polled(s.desk)
        let hash = "0x" + String(repeating: "ab", count: 32)
        #expect(await until { s.desk.cards.first?.state == .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)) })
        #expect(s.told.messages.count == 1)
    }

    /// wallet-request-fallback:F2: the "not picked up" hint counts from the send the record keeps, so a restart doesn't
    /// start its 5 minutes again.
    @Test func notPickedUpSurvivesARestart() async throws {
        let clock = Clock()
        let s = try setup(clock: clock)
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent && s.desk.cards.first?.notPickedUp == false)
        s.desk.close()
        // The app restarts 5 minutes later.
        clock.now = clock.now.addingTimeInterval(WalletCardModel.notPickedUpAfter)
        let later = WalletDesk(folder: s.asked, store: s.store, inbox: s.fake.inbox,
                               config: { WalletDesk.Config(passage: s.fake.executable, peer: WalletFakePassage.peer) },
                               now: { clock.now }, log: { _ in })
        later.sessionNames = { WalletDeskTests.names() }
        later.verifyStamps = WalletTestStamps.verify
        defer { later.close() }
        await refreshed(later)
        #expect(later.cards.first?.state == .sent)
        #expect(later.cards.first?.notPickedUp == true)
    }

    // MARK: Requests and results on the card
    // MARK: Requests and results on the card

    @Test func amountsAndResultsReadAsTheWalletManagerSaidThem() throws {
        #expect(WalletCardModel.units("1000000000000000000", decimals: 18) == "1")
        #expect(WalletCardModel.units("250000000000000000", decimals: 18) == "0.25")
        #expect(WalletCardModel.units("1", decimals: 18) == "0.000000000000000001")
        #expect(WalletCardModel.units("0", decimals: 18) == "0")
        var request = Self.request()
        request.asset = "0x00000000000000000000000000000000000000aa"
        request.amount = "1000"
        let token = WalletCardModel(request: request, requestedBy: "x", state: .waiting)
        #expect(token.amount == "1000" && token.asset == "base units of token 0x000000…00aa")
        request.chainId = 5
        request.asset = "native"
        #expect(WalletCardModel(request: request, requestedBy: "x", state: .waiting).asset == "(the chain's native coin)")
        var call = Self.request()
        call.action = .call
        call.data = "0xa9059cbb"
        call.amount = "0"
        #expect(WalletCardModel(request: call, requestedBy: "x", state: .waiting).calldataBytes == 4)

        let base = Self.request()
        #expect(WalletCardModel.state(Self.result(base, .signed, sequence: 3)) == .signedNotSubmitted)
        var rejected = Self.result(base, .rejected, sequence: 2)
        rejected.message = ""
        rejected.checks = [.init(name: "recipient", ok: false, detail: "not in the address book")]
        #expect(WalletCardModel.state(rejected) == .rejected(reason: "failed recipient"))
        var proposed = Self.result(base, .proposed, sequence: 2)
        proposed.safeTxHash = "0x" + String(repeating: "cd", count: 32)
        let record = WalletRequestStore.Record(request: base, state: .sent, results: [Self.result(base, .received, sequence: 1), proposed])
        let read = WalletCardModel.state(of: record, unsure: nil, now: Self.created)
        #expect(read.state == .proposed(safeTxHash: proposed.safeTxHash) && read.wallet == .safe)
    }

    /// Blind check #1: the list is read again when asked (the tab showing, the path changing), and the latest read wins.
    @Test func thePeerListIsReadAgainAndTheLatestReadWins() async throws {
        let fake = try WalletFakePassage(temp)
        let release = DispatchSemaphore(value: 0)
        let list = WalletPeerList(load: { path in
            if path == "slow" { release.wait() }
            let passage = PassageCommand(executable: fake.executable)
            return WalletPeerList.Read(passage: passage, peers: WalletPeerChoice.list(passage: passage))
        })
        try (#"{"peerID":"0a1b2c3d","name":"Example Wallet Manager Mac"}"# + "\n").write(to: fake.file("peers.jsonl"), atomically: true, encoding: .utf8)
        var shown = 0
        list.reload(passagePath: "slow") { shown += 1 }
        list.reload(passagePath: fake.executable) { shown += 10 }
        #expect(await until { shown == 10 })
        #expect(list.peers.map(\.peerID) == ["0a1b2c3d"])
        // Paired since: read again, it's there.
        try (#"{"peerID":"0a1b2c3d","name":"Example Wallet Manager Mac"}"# + "\n" + #"{"peerID":"0d0d0d0d","name":"Example laptop"}"# + "\n")
            .write(to: fake.file("peers.jsonl"), atomically: true, encoding: .utf8)
        list.reload(passagePath: fake.executable) { shown += 100 }
        #expect(await until { shown == 110 })
        #expect(list.peers.map(\.peerID) == ["0a1b2c3d", "0d0d0d0d"])
        // The slow first read, finishing last, changes nothing.
        release.signal()
        list.reload(passagePath: fake.executable) { shown += 1000 }
        #expect(await until { shown == 1110 })
        #expect(list.peers.map(\.peerID) == ["0a1b2c3d", "0d0d0d0d"])
    }

    // MARK: Settings › Wallet's peers
    // MARK: Finding Passage

    /// A desk on a fake Passage.app (never the real one): `passage` is the path setting.
    func appSetup(passage: (WalletFakePassage) -> String) throws -> (fake: WalletFakePassage, desk: WalletDesk, asked: URL) {
        let fake = try WalletFakePassage(temp, app: true)
        let asked = temp.url("asked")
        let setting = passage(fake)
        let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: temp.url("requests")), inbox: fake.inbox,
                             config: { WalletDesk.Config(passage: setting, peer: WalletFakePassage.peer) },
                             now: { WalletDeskTests.created.addingTimeInterval(30) }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        // No passage on the PATH; Passage.app where /Applications would be (one missing before it, as ~/Applications may be).
        desk.findPassage = { PassageCommand.resolve(setting: "", onPath: { nil }, apps: [self.temp.url("missing/Passage.app"), fake.app]) }
        return (fake, desk, asked)
    }

    @Test(arguments: ["", "  "])
    func withNoPathSetPassageAppIsFoundAndRunAsItsCLI(setting: String) async throws {
        let (fake, desk, asked) = try appSetup { _ in setting }
        defer { desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: asked)
        await refreshed(desk)
        await acted(desk, .send, request.id)
        #expect(desk.cards.first?.state == .sent)
        let sends = fake.calls.filter { $0.hasPrefix("cli send ") }
        #expect(sends.count == 1)
        #expect(sends.first?.hasPrefix("cli send \(WalletFakePassage.peer) /") == true)
        #expect(sends.first?.hasSuffix(" --name \(WalletRequest.fileName(request.id))") == true)
        // Every run had `cli` first: none would have opened Passage's window.
        #expect(!fake.calls.isEmpty && fake.calls.allSatisfy { $0.hasPrefix("cli ") })
        try fake.receive(Self.result(request, .received, sequence: 1), second: 1)
        await polled(desk)
        #expect(desk.cards.first?.state == .received)
        #expect(fake.calls.contains("cli inbox \(WalletFakePassage.peer) --json"))
    }

    @Test(arguments: [false, true])
    func aPathToPassageAppOrItsBinaryIsRunAsItsCLI(binary: Bool) async throws {
        let (fake, desk, asked) = try appSetup { binary ? $0.executable : $0.app.path }
        defer { desk.close() }
        desk.findPassage = { Issue.record("a path is set: nothing is looked for"); return nil }
        let request = Self.request()
        try WalletAsk.file(request, in: asked)
        await refreshed(desk)
        await acted(desk, .send, request.id)
        #expect(desk.cards.first?.state == .sent)
        #expect(fake.sends.isEmpty && fake.calls.filter { $0.hasPrefix("cli send ") }.count == 1)
        #expect(fake.calls.allSatisfy { $0.hasPrefix("cli ") })
    }

    @Test func aPathToAPassageLinkIsRunAsIs() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.fake.sends.count == 1 && !s.fake.calls.contains { $0.hasPrefix("cli") })
    }

    @Test func withNoPassageFoundTheCardSaysWhereToSetIt() async throws {
        let (fake, desk, asked) = try appSetup { _ in "" }
        defer { desk.close() }
        desk.findPassage = { nil }
        let request = Self.request()
        try WalletAsk.file(request, in: asked)
        await refreshed(desk)
        // Held back: no Send, the line says where to set it.
        #expect(desk.cards.first?.state == .waiting)
        #expect(desk.cards.first?.setupNeeded == "Passage isn't found: set its path in Settings › Wallet")
        #expect(desk.cards.first?.actions == [.discard, .settings])
        await acted(desk, .send, request.id)
        #expect(fake.calls.isEmpty)
        // Found later: Send is back.
        desk.findPassage = { PassageCommand(executable: fake.executable, leading: ["cli"]) }
        await refreshed(desk)
        #expect(desk.cards.first?.setupNeeded == nil)
        #expect(desk.cards.first?.actions == [.send, .discard])
    }

    @Test func settingsSaysWhichPassageItFoundAndListsPeersThroughIt() async throws {
        let fake = try WalletFakePassage(temp, app: true)
        try (#"{"peerID":"0a1b2c3d","name":"Example Wallet Manager Mac"}"# + "\n").write(to: fake.file("peers.jsonl"), atomically: true, encoding: .utf8)
        let apps = [temp.url("missing/Passage.app"), fake.app]
        let list = WalletPeerList(load: { WalletPeerList.read($0, onPath: { nil }, apps: apps) })
        #expect(WalletSettingsTab.using(list.passage, read: list.read, path: "") == nil)
        var shown = 0
        list.reload(passagePath: "") { shown += 1 }
        #expect(await until { shown == 1 })
        #expect(list.peers.map(\.peerID) == ["0a1b2c3d"])
        #expect(list.passage == PassageCommand(executable: fake.executable, leading: ["cli"]))
        #expect(WalletSettingsTab.using(list.passage, read: list.read, path: "") == "Using \(fake.app.path)")
        #expect(fake.calls == ["cli peers --no-discovery --json"])
        // The app's path set in Settings: the same.
        list.reload(passagePath: fake.app.path) { shown += 1 }
        #expect(await until { shown == 2 })
        #expect(WalletSettingsTab.using(list.passage, read: list.read, path: fake.app.path) == "Using \(fake.app.path)")
        #expect(list.peers.map(\.peerID) == ["0a1b2c3d"])
        // Nothing found: said so, and no peers.
        let none = WalletPeerList(load: { WalletPeerList.read($0, onPath: { nil }, apps: [self.temp.url("missing/Passage.app")]) })
        none.reload(passagePath: "") { shown += 1 }
        #expect(await until { shown == 3 })
        #expect(none.peers.isEmpty && none.passage == nil)
        #expect(WalletSettingsTab.using(none.passage, read: none.read, path: "")?.hasPrefix("Passage not found") == true)
    }

    // MARK: Settings › Wallet's peers

    @Test func settingsListsThePeersPassageNames() throws {
        let fake = try WalletFakePassage(temp)
        let lines = [#"{"peerID":"0a1b2c3d","name":"Example Wallet Manager Mac","reachable":null,"pairedAt":"2026-10-01T00:00:00Z"}"#,
                     #"{"peerID":"not-a-peer","name":"Odd"}"#,
                     #"{"peerID":"0d0d0d0d","name":"","reachable":null}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: fake.file("peers.jsonl"), atomically: true, encoding: .utf8)
        let peers = try #require(WalletPeerChoice.list(passage: PassageCommand(executable: fake.executable)))
        #expect(peers == [WalletPeerChoice(peerID: "0a1b2c3d", name: "Example Wallet Manager Mac (0a1b2c3d)"),
                          WalletPeerChoice(peerID: "0d0d0d0d", name: "(unnamed)")])
        #expect(fake.calls == ["peers --no-discovery --json"])
        #expect(WalletPeerChoice.list(passage: PassageCommand(executable: "relative/passage")) == nil)
    }
}

/// The Wallet Manager's answer reaches the asking session's agent as a message, through the steering path the lead's messages
/// take (its steer inbox, handed over by its hook): on the chat harness's fake Claude on a scratch pty, through a
/// scratch session host; never a real session.
@MainActor
@Suite(.serialized)
struct WalletDeliveryTests {
    let temp = Scratch()

    @Test func theWalletManagersAnswerReachesTheAskingSessionsAgent() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let stateDir = temp.url("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let controller = LeadController(host: h.host, store: store, vault: LeadVault.Book().vault(folder: temp.url("vault"), as: { .app }),
                                        inbox: h.steerRoot, home: h.chat.home) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        // Working: the message is steered, handed over at its next step.
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }

        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: temp.url("requests")), inbox: fake.inbox,
                             config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) },
                             now: { WalletDeskTests.created.addingTimeInterval(30) }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names(h.session.id) }
        desk.verifyStamps = WalletTestStamps.verify
        defer { desk.close() }
        desk.deliver = { session, text in
            controller.tell(text, from: .system("from the Wallet Manager"), session: UUID(uuidString: session)!)
        }
        let request = WalletDeskTests.request(session: h.session.id)
        try WalletAsk.file(request, in: asked)
        var done = false
        desk.refresh { done = true }
        #expect(await until { done })
        #expect(desk.cards(for: h.session.id).first?.state == .waiting)
        done = false
        desk.act(.send, on: request.id) { done = true }
        #expect(await until { done })
        try fake.receive(WalletDeskTests.result(request, .received, sequence: 1), second: 1)
        done = false
        desk.poll { done = true }
        #expect(await until { done })

        let pending = { SteerInbox.pending(tty: h.session.tty, root: h.steerRoot).filter { $0.text.contains(request.id) } }
        try await h.waitFor { pending().count == 1 }
        let message = try #require(pending().first)
        #expect(message.from == .system("from the Wallet Manager"))
        #expect(message.text.contains("the Wallet Manager says received"))
        // Its hook hands it over at the agent's next step: in the agent's transcript, as added context.
        h.hookTakes()
        #expect(pending().isEmpty)
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains(request.id) && transcript.contains("the Wallet Manager says received"))
    }

    @Test func anUnsentRequestsExpiryReachesTheAskingSessionsAgent() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let stateDir = temp.url("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let controller = LeadController(host: h.host, store: store, vault: LeadVault.Book().vault(folder: temp.url("vault"), as: { .app }),
                                        inbox: h.steerRoot, home: h.chat.home) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }

        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let request = WalletDeskTests.request(session: h.session.id)
        let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: temp.url("requests")), inbox: fake.inbox,
                             config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) },
                             now: { request.expiresAt.addingTimeInterval(1) }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names(h.session.id) }
        desk.verifyStamps = WalletTestStamps.verify
        defer { desk.close() }
        desk.deliver = { session, text in
            controller.tell(text, from: .system("from the Wallet Manager"), session: UUID(uuidString: session)!)
        }
        try WalletAsk.file(request, in: asked)
        var done = false
        desk.refresh { done = true }
        #expect(await until { done })
        #expect(desk.cards(for: h.session.id).first?.state == .expired)
        #expect(fake.calls.isEmpty)

        let pending = { SteerInbox.pending(tty: h.session.tty, root: h.steerRoot).filter { $0.text.contains(request.id) } }
        try await h.waitFor { pending().count == 1 }
        let message = try #require(pending().first)
        #expect(message.from == .system("from the Wallet Manager"))
        #expect(message.text.contains("without being sent"))
        h.hookTakes()
        #expect(pending().isEmpty)
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains(request.id) && transcript.contains("without being sent"))
        // Looked at again: once only.
        done = false
        desk.refresh { done = true }
        #expect(await until { done })
        #expect(pending().isEmpty)
    }
}
