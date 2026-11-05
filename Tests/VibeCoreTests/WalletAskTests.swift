import Foundation
import Testing
@testable import VibeCore

/// `vs-wallet request …` (`WalletAsk`): an agent in a session VibeSwitcher started files a transaction request, checked
/// by the Wallet Manager's own parser; what the format doesn't take is refused with the parser's reason, and nothing is filed.
/// And the courier's Discard (`forget`) and its word on every result taken (`onTaken`).
struct WalletAskTests {
    let scratch = Scratch()
    static let session = "11111111-2222-4333-8444-555555555555"
    static let now = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z

    /// The session host's vault as the tests have it, asked by a process it places in `caller` (`session` unless said).
    func vault(_ caller: LeadVault.Caller = .session(WalletAskTests.session.uppercased()),
               ask: (@Sendable (LeadVault.Request) throws -> LeadVault.Reply)? = nil) -> LeadVault {
        let book = WalletTestStamps.book
        return LeadVault(folder: scratch.url("vault")) { request in try ask?(request) ?? book.answer(request, from: caller, userOpened: true) }
    }

    static let valid = ["request", "--workspace", "example", "--from", "example-hardware", "--chain", "42424242",
                        "--to", "0x0000000000000000000000000000000000000001", "--amount", "1000000000000000000",
                        "--reason", "Pay the example invoice.", "--label", "Example agent"]

    func run(_ arguments: [String], walletManager: WalletAsk.WalletManager = .ready,
             vault: LeadVault? = nil) -> (status: Int32, output: String, error: String, folder: URL) {
        let folder = scratch.url("asked")
        let ran = WalletAsk.run(arguments, cwd: "/work/example-project", walletManager: walletManager,
                                folder: folder, now: Self.now, vault: vault ?? self.vault())
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
        let (requests, stamps, refused) = WalletAsk.filed(in: ran.folder)
        #expect(refused.isEmpty)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        // Stamped by the host for the session it placed the process in, and the stamp is the host's.
        let stamp = try #require(stamps[request.id])
        let bytes = try Data(contentsOf: ran.folder.appendingPathComponent("\(request.id).json"))
        #expect(stamp.session == Self.session && stamp.digest == WalletStamp.digest(bytes))
        #expect(try WalletTestStamps.verify([stamp]) == [true])
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

    @Test func refusedOutsideAVibeSwitcherSession() {
        // A process the host places in no session (VIBESWITCHER_SESSION or not: it isn't read), or a host that can't be
        // asked, or one that won't stamp: refused, nothing filed.
        let outside = run(Self.valid, vault: vault(.unknown))
        #expect(outside.status == 1 && outside.error.contains("didn't say which of its sessions this process runs in")
                && outside.error.contains("isn't in any session"), "\(outside.error)")
        #expect(filed(outside.folder).isEmpty)
        struct Down: Error, CustomStringConvertible { var description: String { "The session host didn't answer in time." } }
        let down = run(Self.valid, vault: vault(ask: { _ in throw Down() }))
        #expect(down.status == 1 && down.error.contains("didn't answer in time"), "\(down.error)")
        #expect(filed(down.folder).isEmpty)
        let unstamped = run(Self.valid, vault: vault(ask: { request in
            if case .walletSession = request { return .session(Self.session) }
            return .refused("A wallet request is sealed only for the session its process runs in.")
        }))
        #expect(unstamped.status == 1 && unstamped.error.contains("didn't stamp the request"), "\(unstamped.error)")
        #expect(filed(unstamped.folder).isEmpty)
        // The session the request names is the host's answer, whatever the process's environment says.
        let other = run(Self.valid, vault: vault(.session("AAAAAAAA-2222-4333-8444-555555555555")))
        #expect(other.status == 0, "\(other.error)")
        #expect(WalletAsk.filed(in: other.folder).requests.first?.requestedBy.session == "aaaaaaaa-2222-4333-8444-555555555555")
        let usage = run(["send"])
        #expect(usage.status == 2 && usage.error.contains("usage: vs-wallet request"))
        #expect(run(["help"]).status == 0)
    }

    /// No Wallet Manager peer chosen, or no Passage found: filed all the same, and the output says the card is up and the
    /// browser wallet is the way to sign (from an 0x address); a wallet id waits for the Wallet Manager.
    @Test(arguments: [WalletAsk.WalletManager.noPeer, .noPassage])
    func filedWithoutAWalletManagerTheBrowserWalletIsTheWay(walletManager: WalletAsk.WalletManager) throws {
        let address = Self.with("--from", "0x00000000000000000000000000000000000000aa")
        let ran = run(address, walletManager: walletManager)
        #expect(ran.status == 0, "\(ran.error)")
        #expect(filed(ran.folder).count == 1)
        #expect(ran.output.contains("its card is up in this session's chat"), "\(ran.output)")
        #expect(ran.output.contains("The Wallet Manager isn't set up yet (\(walletManager.why!))"), "\(ran.output)")
        #expect(ran.output.contains("so the browser wallet is the way to sign"), "\(ran.output)")
        #expect(ran.output.contains("Sign in browser wallet"))
        #expect(walletManager == .noPeer ? walletManager.why!.contains("no Wallet Manager peer is chosen")
                : walletManager.why!.contains("Passage isn't found"))
        // A wallet id: filed, and it says a browser wallet can't sign for it.
        let id = run(Self.valid, walletManager: walletManager)
        #expect(id.status == 0, "\(id.error)")
        #expect(filed(id.folder).contains { id.output.contains("Filed wallet request \($0.dropLast(5))") }, "\(id.output)")
        #expect(id.output.contains("The Wallet Manager isn't set up yet"))
        #expect(id.output.contains("a browser wallet can't sign for a wallet id (--from example-hardware)"), "\(id.output)")
        #expect(!id.output.contains("is the way to sign"))
        // Set up: as before.
        let ready = run(address)
        #expect(ready.output.contains("until the user presses Send to Wallet Manager") && !ready.output.contains("isn't set up"))
    }

    /// A request marked LOCAL FORK ONLY (its reason's first line), from an 0x address, with no Wallet Manager set up:
    /// filed like any other, and the output says the browser wallet can't sign it and that it waits for the Wallet
    /// Manager. Never that the browser wallet is the way.
    @Test(arguments: [WalletAsk.WalletManager.noPeer, .noPassage])
    func aMarkedRequestWithoutAWalletManagerWaitsForItNeverTheBrowserWallet(walletManager: WalletAsk.WalletManager) throws {
        let address = Self.with("--from", "0x00000000000000000000000000000000000000aa")
        for reason in ["LOCAL FORK ONLY", "LOCAL FORK ONLY\nDeploy the example contract to the fork.", " local fork only "] {
            let ran = run(Self.with("--reason", reason, in: address), walletManager: walletManager)
            #expect(ran.status == 0, "\(ran.error)")
            // Filed as it was asked: the marker is the reason's, untouched.
            let request = try #require(WalletAsk.filed(in: ran.folder).requests.first { $0.reason == reason })
            #expect(request.from == "0x00000000000000000000000000000000000000aa")
            #expect(ran.output.contains("Filed wallet request \(request.id): its card is up in this session's chat"), "\(ran.output)")
            #expect(ran.output.contains("The Wallet Manager isn't set up yet (\(walletManager.why!))"), "\(ran.output)")
            #expect(ran.output.contains("the browser wallet can't sign a request marked LOCAL FORK ONLY"), "\(ran.output)")
            #expect(ran.output.contains("it waits on its card until the user sets up the Wallet Manager in Settings › Wallet and sends it"),
                    "\(ran.output)")
            #expect(!ran.output.contains("is the way to sign") && !ran.output.contains("Sign in browser wallet"), "\(ran.output)")
            #expect(ran.output.contains("It expires at "))
        }
        // The marker on line 2 isn't one: the browser wallet is the way, as for any request from an 0x address.
        let unmarked = run(Self.with("--reason", "Deploy the example contract.\nLOCAL FORK ONLY", in: address), walletManager: walletManager)
        #expect(unmarked.status == 0 && unmarked.output.contains("so the browser wallet is the way to sign"), "\(unmarked.output)")
        // Set up: filed and worded as any other, for Send to Wallet Manager.
        let ready = run(Self.with("--reason", "LOCAL FORK ONLY", in: address))
        #expect(ready.status == 0 && ready.output.contains("until the user presses Send to Wallet Manager"), "\(ready.output)")
        #expect(!ready.output.contains("browser wallet"), "\(ready.output)")
        // The help says so.
        #expect(run(["help"]).output.contains("A request whose reason's first line is LOCAL FORK ONLY is never offered the browser wallet"))
    }

    /// Settings › Wallet as the CLI reads it: no peer; a peer and a Passage (on the PATH, an absolute path set, Passage.app);
    /// a peer and none.
    @Test func theWalletManagerIsReadyWithAPeerAndAPassage() throws {
        let bin = scratch.url("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let passage = bin.appendingPathComponent("passage")
        try "#!/bin/sh\n".write(to: passage, atomically: true, encoding: .utf8)
        chmod(passage.path, 0o755)
        let none = [scratch.url("missing/Passage.app")]
        typealias Manager = WalletAsk.WalletManager
        #expect(Manager.from(peer: "", passagePath: "", path: bin.path, apps: none) == .noPeer)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "", path: "/nowhere:" + bin.path, apps: none) == .ready)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "", path: "/nowhere", apps: none) == .noPassage)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "", path: nil, apps: none) == .noPassage)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: passage.path, path: nil, apps: none) == .ready)
        // A path set that names nothing that can run: the app wouldn't run it either.
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "/opt/example/passage", path: nil, apps: none) == .noPassage)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "passage", path: bin.path, apps: none) == .noPassage)
        // A folder named passage on the PATH isn't it.
        let dirs = scratch.url("dirs")
        try FileManager.default.createDirectory(at: dirs.appendingPathComponent("passage"), withIntermediateDirectories: true)
        #expect(Manager.from(peer: "0a1b2c3d", passagePath: "", path: dirs.path, apps: none) == .noPassage)
    }

    /// vs-wallet's help and the session note say the browser wallet works without a Wallet Manager.
    @Test func helpAndTheSessionNoteSayTheBrowserWalletWorksWithoutAWalletManager() {
        #expect(run(["help"]).output.contains("It works with no Wallet Manager set up; a wallet id (not 0x) needs the Wallet Manager."))
        #expect(SessionNote.text.contains("Sign in browser wallet, which works without a Wallet Manager"))
    }

    @Test func aFiledFileThatDoesntParseOrIsntItsNamesIsRefused() throws {
        let folder = scratch.url("asked")
        try VibePaths.ensurePrivate(folder)
        let request = WalletRequestFormatTests.request()
        try request.encoded().write(to: folder.appendingPathComponent("00000000-0000-4000-8000-000000000009.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("00000000-0000-4000-8000-000000000008.json"))
        let (requests, _, refused) = WalletAsk.filed(in: folder)
        #expect(requests.isEmpty)
        #expect(refused.count == 2)
    }

    /// The vault seals a wallet request only for the caller's own session, and only while that session is the user's
    /// (the host tells: `userOpened`), so not from inside a session another one started or typed into; never from
    /// the app or outside every session.
    @Test func theVaultSealsAWalletRequestOnlyForTheCallersOwnSession() {
        let book = LeadVault.Book()
        let mine = Self.session, theirs = "aaaaaaaa-2222-4333-8444-555555555555"
        let digest = WalletStamp.digest(Data("bytes".utf8))
        func refused(_ reply: LeadVault.Reply) -> Bool { if case .refused = reply { return true } else { return false } }
        #expect(book.answer(.walletSession, from: .session(mine.uppercased())) == .session(mine))
        for caller in [LeadVault.Caller.app, .unknown] {
            #expect(refused(book.answer(.walletSession, from: caller)))
            #expect(refused(book.answer(.sealWalletRequest(session: mine, digest: digest), from: caller)))
        }
        #expect(refused(book.answer(.sealWalletRequest(session: theirs, digest: digest), from: .session(mine), userOpened: true)))
        #expect(refused(book.answer(.sealWalletRequest(session: mine, digest: "not a digest"), from: .session(mine), userOpened: true)))
        // Its own session, but one another session started or last typed into (the host says it isn't the user's).
        #expect(refused(book.answer(.sealWalletRequest(session: mine, digest: digest), from: .session(mine))))
        guard case .seal(let seal) = book.answer(.sealWalletRequest(session: mine, digest: digest), from: .session(mine.uppercased()), userOpened: true) else {
            Issue.record("no seal"); return
        }
        #expect(book.answer(.verifyWalletRequests([WalletStamp(session: mine, digest: digest, seal: seal),
                                                   WalletStamp(session: theirs, digest: digest, seal: seal),
                                                   WalletStamp(session: mine, digest: digest, seal: "zz")]), from: .unknown)
                == .verified([true, false, false]))
        // A seal that isn't 64 ASCII hex digits (a stamp file is anyone's to write) is no seal, and doesn't crash the host:
        // 62 digits and an é (64 bytes, 63 characters), signs that Int's parser takes, an odd count of digits.
        let odd = [String(seal.prefix(62)) + "é", "+f" + String(seal.dropFirst(2)), "-0" + String(seal.dropFirst(2)), String(seal.dropLast())]
        #expect(book.answer(.verifyWalletRequests(odd.map { WalletStamp(session: mine, digest: digest, seal: $0) }), from: .unknown)
                == .verified([false, false, false, false]))
        #expect(book.answer(.verifyWalletRequests([WalletStamp(session: mine, digest: digest, seal: seal.uppercased())]), from: .unknown) == .verified([true]))
        // Another vault's key makes other seals.
        #expect(WalletTestStamps.book.answer(.verifyWalletRequests([WalletStamp(session: mine, digest: digest, seal: seal)]), from: .app) == .verified([false]))
    }

    /// A request written into the folder some other way than through the host has no stamp for its bytes and the
    /// session it names: refused when read. (Whether a stamp's seal is the host's, the app asks the host: `WalletDesk`.)
    @Test func aFiledRequestWithoutTheHostsStampForItsBytesAndSessionIsRefused() throws {
        let folder = scratch.url("asked")
        let request = WalletRequestFormatTests.request()
        let bytes = try request.encoded()
        let stamp = try WalletTestStamps.stamp(request)
        // No stamp at all: written by hand.
        try VibePaths.ensurePrivate(folder)
        try VibePaths.writePrivate(bytes, to: folder.appendingPathComponent("\(request.id).json"))
        #expect(WalletAsk.filed(in: folder).refused.first?.why.contains("no session host stamp") == true)
        // A stamp for other bytes (the file rewritten after it was filed), or for another session.
        for wrong in [WalletStamp(session: stamp.session, digest: WalletStamp.digest(bytes + Data(" ".utf8)), seal: stamp.seal),
                      WalletStamp(session: "aaaaaaaa-2222-4333-8444-555555555555", digest: stamp.digest, seal: stamp.seal)] {
            try VibePaths.writePrivate(JSONEncoder().encode(wrong), to: WalletAsk.stampFile(request.id, in: folder))
            let filed = WalletAsk.filed(in: folder)
            #expect(filed.requests.isEmpty && filed.refused.first?.why.contains("stamp is for other bytes or another session") == true)
        }
        // Filing checks the same.
        #expect(throws: WalletAsk.Refusal.self) {
            try WalletAsk.file(request, stamp: WalletStamp(session: "aaaaaaaa-2222-4333-8444-555555555555", digest: stamp.digest, seal: stamp.seal), in: folder)
        }
        try WalletAsk.file(request, stamp: stamp, in: folder)
        #expect(WalletAsk.filed(in: folder).stamps == [request.id: stamp])
        WalletAsk.remove(request.id, in: folder)
        #expect(!FileManager.default.fileExists(atPath: WalletAsk.stampFile(request.id, in: folder).path))
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

    /// What an earlier version filed and recorded, in the formats' former `type`s: read as before once carried over.
    @Test func carriedOverRequestsAndRecordsStillReadWithTheirFormerTypesRenamed() throws {
        let old = scratch.url("vault-requests"), new = scratch.url("wallet-requests")
        func former(_ data: Data) -> Data {
            Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\"vibeswitcher.wallet-request\"", with: "\"vibeswitcher.vault-request\"")
                .replacingOccurrences(of: "\"vibeswitcher.wallet-result\"", with: "\"vibeswitcher.vault-result\"").utf8)
        }
        let asked = try WalletAsk.request(Array(Self.valid.dropFirst()), session: Self.session, cwd: "/work/example-project", now: Self.now)
        let sent = try WalletAsk.request(Array(Self.with("--amount", "2").dropFirst()), session: Self.session, cwd: "/work/example-project", now: Self.now)
        let result = WalletResult(id: sent.id, sequence: 1, createdAt: Self.now.addingTimeInterval(60), status: .received,
                                  checks: [.init(name: "balance", ok: true, detail: "covers it")], message: "")
        let record = WalletRequestStore.Record(request: sent, state: .sent, results: [result])
        try VibePaths.ensurePrivate(old.appendingPathComponent("asked"))
        try VibePaths.writePrivate(former(try asked.encoded()), to: old.appendingPathComponent("asked/\(asked.id).json"))
        try VibePaths.writePrivate(former(WalletRequestStore.encode(record)), to: old.appendingPathComponent("\(sent.id).json"))
        // As the earlier version wrote them, today's readers refuse them.
        #expect(WalletAsk.filed(in: old.appendingPathComponent("asked")).requests.isEmpty)
        #expect(WalletRequestStore(folder: old).load().isEmpty)

        try WalletRequestStore.carryOver(from: old, to: new)
        let carried = new.appendingPathComponent("asked/\(asked.id).json")
        #expect(try WalletRequest.parse(Data(contentsOf: carried)) == asked)
        // It carries no session host stamp (filed before stamps): it never gets a card.
        #expect(WalletAsk.filed(in: new.appendingPathComponent("asked")).requests.isEmpty)
        #expect(WalletRequestStore(folder: new).load() == [record])
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
