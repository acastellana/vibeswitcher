import Foundation
import Testing
@testable import VibeCore

/// `vs-wallet request …` (`WalletAsk`): an agent in a session VibeSwitcher started files a transaction request, checked
/// by the Wallet Manager's own parser; what the format doesn't take is refused with the parser's reason, and nothing is filed.
/// And the courier's Discard (`forget`) and its word on every result taken (`onTaken`).
struct WalletAskTests {
    let scratch = Scratch()
    static let session = "11111111-2222-4333-8444-555555555555"
    static let environment = ["VIBESWITCHER_SESSION": session.uppercased()]
    static let now = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z

    static let valid = ["request", "--workspace", "example", "--from", "example-hardware", "--chain", "42424242",
                        "--to", "0x0000000000000000000000000000000000000001", "--amount", "1000000000000000000",
                        "--reason", "Pay the example invoice.", "--label", "Example agent"]

    func run(_ arguments: [String], environment: [String: String] = WalletAskTests.environment, peerChosen: Bool = true)
        -> (status: Int32, output: String, error: String, folder: URL) {
        let folder = scratch.url("asked")
        let ran = WalletAsk.run(arguments, environment: environment, cwd: "/work/example-project", peerChosen: peerChosen, folder: folder, now: Self.now)
        return (ran.status, ran.output, ran.error, folder)
    }

    func filed(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
    }

    /// `arguments` with `option`'s value replaced (or added).
    static func with(_ option: String, _ value: String, in arguments: [String] = valid) -> [String] {
        var arguments = arguments
        if let at = arguments.firstIndex(of: option) { arguments[at + 1] = value } else { arguments += [option, value] }
        return arguments
    }

    @Test func aValidRequestIsFiledPrivateAsTheWalletManagerWouldReadIt() throws {
        let ran = run(Self.valid)
        #expect(ran.status == 0, "\(ran.error)")
        #expect(ran.output.contains("nothing is sent until the user presses Send to Wallet Manager"))
        let (requests, refused) = WalletAsk.filed(in: ran.folder)
        #expect(refused.isEmpty)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.requestedBy == .init(project: "example-project", session: Self.session, label: "Example agent"))
        #expect(request.action == .transfer && request.asset == "native" && request.chainId == 42_424_242)
        #expect(request.createdAt == Self.now && request.expiresAt == Self.now.addingTimeInterval(86_400))
        #expect(ran.output.contains(request.id))
        let file = ran.folder.appendingPathComponent("\(request.id).json")
        #expect(try WalletRequest.parse(Data(contentsOf: file)) == request)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: ran.folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
    }

    @Test func calldataMakesItACallAndExpiresInSetsItsLifetime() throws {
        let arguments = Self.with("--expires-in", "3d", in: Self.with("--amount", "0", in: Self.with("--data", "0xa9059cbb")))
        let ran = run(arguments)
        #expect(ran.status == 0, "\(ran.error)")
        let request = try #require(WalletAsk.filed(in: ran.folder).requests.first)
        #expect(request.action == .call && request.data == "0xa9059cbb" && request.amount == "0")
        #expect(request.expiresAt == Self.now.addingTimeInterval(3 * 86_400))
    }

    @Test(arguments: [
        (WalletAskTests.with("--to", "0x12"), "to: must be 0x and 40 hex digits"),
        (WalletAskTests.with("--amount", "1.5"), "amount: must be base units as decimal digits"),
        (WalletAskTests.with("--workspace", "-bad"), "workspace: must be 1-64 of"),
        (WalletAskTests.with("--reason", "here: " + String(repeating: "ab", count: 32)), "reason looks like key material"),
        (WalletAskTests.with("--asset", "ETH"), "asset: must be native or 0x and 40 hex digits"),
        (WalletAskTests.with("--expires-in", "8d"), "expiresAt: must be after createdAt, by 7 days at most"),
        (WalletAskTests.with("--chain", "0"), "chainId: must be 1 to 2^53-1"),
        (WalletAskTests.with("--chain", "mainnet"), "chainId: must be 1 to 2^53-1"),
        (WalletAskTests.with("--data", "0x12"), "data: must be 0x and whole bytes of hex"),
        (Array(WalletAskTests.valid.dropLast(4)) + ["--label", "x"], "--reason is required"),
        (WalletAskTests.valid + ["--yes", "1"], "unknown option --yes"),
    ])
    func whatTheFormatDoesntTakeIsRefusedWithTheParsersReason(arguments: [String], reason: String) {
        let ran = run(arguments)
        #expect(ran.status == 1)
        #expect(ran.error.hasPrefix("vs-wallet: refused: "))
        #expect(ran.error.contains(reason), "\(ran.error)")
        #expect(filed(ran.folder).isEmpty)
    }

    @Test func refusedOutsideAVibeSwitcherSessionAndUntilAWalletManagerPeerIsChosen() {
        let outside = run(Self.valid, environment: [:])
        #expect(outside.status == 1 && outside.error.contains("isn't a session VibeSwitcher started"))
        let noPeer = run(Self.valid, peerChosen: false)
        #expect(noPeer.status == 1 && noPeer.error.contains("no Wallet Manager peer is chosen"))
        #expect(filed(noPeer.folder).isEmpty)
        let usage = run(["send"])
        #expect(usage.status == 2 && usage.error.contains("usage: vs-wallet request"))
        #expect(run(["help"]).status == 0)
    }

    @Test func aFiledFileThatDoesntParseOrIsntItsNamesIsRefused() throws {
        let folder = scratch.url("asked")
        try VibePaths.ensurePrivate(folder)
        let request = WalletRequestFormatTests.request()
        try request.encoded().write(to: folder.appendingPathComponent("00000000-0000-4000-8000-000000000009.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("00000000-0000-4000-8000-000000000008.json"))
        let (requests, refused) = WalletAsk.filed(in: folder)
        #expect(requests.isEmpty)
        #expect(refused.count == 2)
    }

    // MARK: The courier's Discard and its word on results

    @Test func forgettingARequestDropsItsRecordAndStopsListening() throws {
        let fake = try PassageLinkTests.FakePassage(scratch)
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let courier = WalletCourier(link: fake.link, store: store, log: { _ in }, now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { courier.close() }
        let request = PassageLinkTests.request()
        try fake.setSendExit(1)
        #expect(courier.send(request) == .passage(.failed("passage: fake exit 1")))
        #expect(courier.record(request.id)?.state == .unsure)
        #expect(courier.listenerPID != nil)
        #expect(courier.forget(request.id))
        #expect(courier.record(request.id) == nil)
        #expect(courier.outstanding.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file(request.id).path))
        #expect(courier.listenerPID == nil)
        #expect(!courier.forget(request.id))
        // Its results are no longer taken.
        try fake.receive(PassageLinkTests.result(request, .received, sequence: 1))
        #expect(courier.poll().isEmpty)
    }

    /// A record an earlier run left `sending` (it stopped mid-send) loads as `unsure`: outstanding, and it may be sent
    /// again under its id.
    @Test func aRecordLeftSendingLoadsAsUnsureAndMayBeResent() throws {
        let fake = try PassageLinkTests.FakePassage(scratch)
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let request = PassageLinkTests.request()
        try store.save(WalletRequestStore.Record(request: request, state: .sending))
        let courier = WalletCourier(link: fake.link, store: store, log: { _ in }, now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { courier.close() }
        #expect(courier.record(request.id)?.state == .unsure)
        #expect(store.load().first?.state == .unsure)
        #expect(courier.outstanding == [request])
        #expect(courier.send(request) == .passage(.sent))
        #expect(courier.record(request.id)?.state == .sent)
    }

    @Test func everyResultTakenIsHeard() throws {
        let fake = try PassageLinkTests.FakePassage(scratch)
        let courier = WalletCourier(link: fake.link, store: WalletRequestStore(folder: scratch.url("requests")), log: { _ in },
                                   now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { courier.close() }
        let heard = PassageLinkTests.Log()
        courier.onTaken { results in for result in results { heard.note("\(result.id) \(result.sequence)") } }
        let request = PassageLinkTests.request()
        #expect(courier.send(request) == .passage(.sent))
        try fake.receive(PassageLinkTests.result(request, .received, sequence: 1), second: 1)
        try fake.receive(PassageLinkTests.result(request, .proposed, sequence: 2), second: 2)
        #expect(courier.poll().count == 2)
        #expect(heard.lines == ["\(request.id) 1", "\(request.id) 2"])
        // Nothing new: nothing heard.
        #expect(courier.poll().isEmpty)
        #expect(heard.lines.count == 2)
    }

    // MARK: The vault-requests folder carried over

    @Test func theVaultRequestsFolderMovesWholeOnceAndKeepsItsModes() throws {
        let old = scratch.url("vault-requests"), new = scratch.url("wallet-requests")
        try VibePaths.ensurePrivate(old.appendingPathComponent("asked"))
        try VibePaths.writePrivate(Data("asked".utf8), to: old.appendingPathComponent("asked/a.json"))
        try VibePaths.writePrivate(Data("record".utf8), to: old.appendingPathComponent("b.json"))
        try WalletRequestStore.carryOver(from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try String(contentsOf: new.appendingPathComponent("asked/a.json"), encoding: .utf8) == "asked")
        #expect(try String(contentsOf: new.appendingPathComponent("b.json"), encoding: .utf8) == "record")
        let mode = try FileManager.default.attributesOfItem(atPath: new.appendingPathComponent("b.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Nothing left to carry: a second launch changes nothing.
        try WalletRequestStore.carryOver(from: old, to: new)
        #expect(try String(contentsOf: new.appendingPathComponent("b.json"), encoding: .utf8) == "record")
    }

    @Test func intoAnExistingFolderOnlyWhatItLacksMovesThenTheOldOneGoes() throws {
        let old = scratch.url("vault-requests"), new = scratch.url("wallet-requests")
        try VibePaths.ensurePrivate(old.appendingPathComponent("asked"))
        try VibePaths.writePrivate(Data("old a".utf8), to: old.appendingPathComponent("asked/a.json"))
        try VibePaths.writePrivate(Data("old c".utf8), to: old.appendingPathComponent("asked/c.json"))
        try VibePaths.writePrivate(Data("old b".utf8), to: old.appendingPathComponent("b.json"))
        try VibePaths.ensurePrivate(new.appendingPathComponent("asked"))
        try VibePaths.writePrivate(Data("new a".utf8), to: new.appendingPathComponent("asked/a.json"))
        try WalletRequestStore.carryOver(from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try String(contentsOf: new.appendingPathComponent("asked/a.json"), encoding: .utf8) == "new a")
        #expect(try String(contentsOf: new.appendingPathComponent("asked/c.json"), encoding: .utf8) == "old c")
        #expect(try String(contentsOf: new.appendingPathComponent("b.json"), encoding: .utf8) == "old b")
    }

    @Test func withNoVaultRequestsFolderNothingHappens() throws {
        let old = scratch.url("vault-requests"), new = scratch.url("wallet-requests")
        try WalletRequestStore.carryOver(from: old, to: new)
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }
}
