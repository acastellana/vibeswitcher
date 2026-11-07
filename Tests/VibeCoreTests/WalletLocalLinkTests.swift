import Foundation
import Testing
@testable import VibeCore

/// The transport on one Mac (`WalletLocalLink`, docs/protocol/wallet-request.md "Transport on one Mac"), against a
/// stand-in for the Wallet Manager's side in a scratch home (never the real ~/Library/Application Support): the bytes
/// and mode of a sent request, its write under a dot-name and rename, what makes it unreachable, which result files
/// are ignored, and that results go through the courier's own rules, the ones Passage's results go through.
struct WalletLocalLinkTests {
    let scratch = Scratch()

    /// The Wallet Manager's side: the folder pair it makes when started with its local transport, its `.listening`
    /// while it takes requests from this Mac, and its results, each written under a dot-name and renamed.
    struct Manager {
        let home: URL
        var link: WalletLocalLink { WalletLocalLink(home: home.path) }
        var transport: URL { VibePaths.walletLocalTransport(home: home.path) }
        var to: URL { transport.appendingPathComponent("to-wm", isDirectory: true) }
        var from: URL { transport.appendingPathComponent("from-wm", isDirectory: true) }
        var listening: URL { to.appendingPathComponent(".listening") }

        /// A scratch home; with `started`, the pair is there (0700); with `accepting` too, `.listening` names this
        /// process.
        init(_ scratch: Scratch, started: Bool = true, accepting: Bool = true) throws {
            home = scratch.url("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if started { try start() }
            if started, accepting { try accept() }
        }

        func start() throws {
            for folder in [to, from] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                chmod(folder.path, 0o700)
            }
        }

        func accept(_ content: String = "\(getpid())\n") throws {
            try Data(content.utf8).write(to: listening)
            chmod(listening.path, 0o600)
        }

        /// A file in `from-wm`, as the Wallet Manager writes one: under a dot-name, then renamed. Its path.
        @discardableResult
        func put(_ data: Data, as name: String) throws -> String {
            let temporary = from.appendingPathComponent(".\(name).tmp")
            try data.write(to: temporary)
            chmod(temporary.path, 0o600)
            let file = from.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temporary, to: file)
            return file.path
        }

        @discardableResult
        func answer(_ result: WalletResult) throws -> String {
            try put(result.encoded(), as: "wallet-result-\(result.id)-\(result.sequence).json")
        }

        func request(_ id: String) -> URL { to.appendingPathComponent("wallet-request-\(id).json") }

        /// Every path under the home, with each file's size: what a send that didn't go must leave as it was.
        var everything: [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: home.path)) ?? []).sorted().map { path in
                var info = stat()
                lstat(home.appendingPathComponent(path).path, &info)
                return "\(path) \(info.st_mode) \(info.st_size)"
            }
        }
    }

    typealias Log = PassageLinkTests.Log
    static func request(_ number: Int = 1) -> WalletRequest { PassageLinkTests.request(number) }
    static func result(_ request: WalletRequest, _ status: WalletResult.Status, sequence: Int64) -> WalletResult {
        PassageLinkTests.result(request, status, sequence: sequence)
    }

    func courier(_ manager: Manager, log: Log = Log(), store: WalletRequestStore? = nil) -> WalletCourier {
        WalletCourier(link: manager.link, store: store ?? WalletRequestStore(folder: scratch.url("requests")), log: { [log] in log.note($0) },
                      now: { PassageLinkTests.created.addingTimeInterval(30) })
    }

    /// The files a store holds (its records; the outbox a send writes through is emptied again).
    func stored(_ store: WalletRequestStore) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: store.folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    static func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : 0
    }

    static func inode(_ path: String) -> UInt64 {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : 0
    }

    /// The request's bytes in a scratch file, as the courier hands them to a link.
    func file(of request: WalletRequest) throws -> URL {
        let file = scratch.url("request.json")
        try request.encoded().write(to: file)
        return file
    }

    // MARK: Sending

    @Test func aSentRequestIsItsOwnBytesMode0600UnderItsName() throws {
        let manager = try Manager(scratch)
        let courier = courier(manager)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let sent = manager.request(request.id)
        #expect(sent.lastPathComponent == WalletRequest.fileName(request.id))
        #expect(try Data(contentsOf: sent) == request.encoded())
        #expect(Self.mode(sent.path) == 0o600)
        // Nothing else is left in to-wm: the dot-name it was written under is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.to.path).sorted() == [".listening", sent.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.from.path).isEmpty)
        #expect(courier.record(request.id)?.state == .sent)
        #expect(courier.outstanding == [request])
        #expect(courier.link.destination == "the Wallet Manager on this Mac")
    }

    /// Written whole under a dot-name in to-wm, 0600, while nothing has the request's name; then that very file is
    /// renamed (the same inode), not copied.
    @Test func theRequestIsWrittenUnderADotNameInTheFolderAndRenamed() throws {
        let manager = try Manager(scratch)
        let request = Self.request()
        let bytes = try request.encoded()
        var seen: (name: String, inode: UInt64)?
        let outcome = manager.link.deliver(file: try file(of: request), id: request.id) { temporary in
            let path = manager.to.appendingPathComponent(temporary).path
            #expect(temporary.hasPrefix(".wallet-request-\(request.id).json.") && !temporary.contains("/"))
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == bytes)
            #expect(Self.mode(path) == 0o600)
            #expect(!FileManager.default.fileExists(atPath: manager.request(request.id).path))
            seen = (temporary, Self.inode(path))
        }
        #expect(outcome == .sent)
        let temporary = try #require(seen)
        #expect(!FileManager.default.fileExists(atPath: manager.to.appendingPathComponent(temporary.name).path))
        #expect(Self.inode(manager.request(request.id).path) == temporary.inode && temporary.inode != 0)
    }

    /// The same bytes already under the name count as delivered, and the file there is left as it is; other bytes
    /// there are never written over: not sent, and no record stays.
    @Test func theSameBytesThereCountAsDeliveredAndOtherBytesAreNeverWrittenOver() throws {
        let manager = try Manager(scratch)
        let request = Self.request()
        let link = manager.link
        #expect(link.deliver(file: try file(of: request), id: request.id) == .sent)
        let first = Self.inode(manager.request(request.id).path)
        #expect(link.deliver(file: try file(of: request), id: request.id) == .sent)
        #expect(Self.inode(manager.request(request.id).path) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.to.path).sorted() == [".listening", "wallet-request-\(request.id).json"])

        // Another request's bytes under this one's name (someone else's file): refused, left as it was.
        let other = Self.request(2)
        var planted = other
        planted.amount = "999"
        try planted.encoded().write(to: manager.request(other.id))
        let log = Log()
        let courier = courier(manager, log: log)
        defer { courier.close() }
        let outcome = courier.send(other)
        #expect(outcome == .passage(.notSent("to-wm already holds a wallet-request-\(other.id).json that isn't this request")))
        #expect(try Data(contentsOf: manager.request(other.id)) == planted.encoded())
        #expect(courier.record(other.id) == nil && courier.outstanding.isEmpty)
        #expect(stored(courier.store).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: manager.to.path).count == 3)
        // A link is given a request's own bytes under its own id, or it sends nothing.
        #expect(link.deliver(file: try file(of: request), id: Self.request(3).id) == .notSent("the file isn't request \(Self.request(3).id)"))
        #expect(!FileManager.default.fileExists(atPath: manager.request(Self.request(3).id).path))
    }

    /// A send that can't go is unreachable, and writes nothing anywhere: not in the home, not a record.
    func expectUnreachable(_ manager: Manager, says: String, link: WalletLocalLink? = nil, _ comment: Comment) throws {
        let log = Log()
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let courier = WalletCourier(link: link ?? manager.link, store: store, log: { [log] in log.note($0) },
                                    now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { courier.close() }
        let before = manager.everything
        let request = Self.request()
        let outcome = courier.send(request)
        guard case .passage(.peerNotListening(let why)) = outcome else {
            Issue.record("\(comment): \(outcome)")
            return
        }
        #expect(why.contains(says), "\(comment): \(why)")
        #expect(manager.everything == before, "\(comment)")
        #expect(stored(store).isEmpty && courier.record(request.id) == nil && courier.outstanding.isEmpty, "\(comment)")
        #expect(!courier.isListening, "\(comment)")
        // The link itself, given the file, says the same and writes nothing.
        guard case .peerNotListening = (link ?? manager.link).deliver(file: try file(of: request), id: request.id) else {
            Issue.record("\(comment): the link sent it")
            return
        }
        #expect(manager.everything == before, "\(comment)")
    }

    static let notRunning = "The Wallet Manager isn't running with its local transport on this Mac"
    static let notAccepting = "The Wallet Manager on this Mac isn't accepting requests"

    @Test func aMissingFolderIsUnreachableAndVibeSwitcherNeverMakesIt() throws {
        // No Wallet Manager ever ran here: nothing under the home.
        let never = try Manager(scratch, started: false)
        try expectUnreachable(never, says: Self.notRunning + " (to-wm is missing)", "nothing there")
        #expect(never.everything.isEmpty)
        // local-transport without its to-wm.
        let half = try Manager(scratch, started: false)
        try FileManager.default.createDirectory(at: half.from, withIntermediateDirectories: true)
        chmod(half.from.path, 0o700)
        try expectUnreachable(half, says: Self.notRunning + " (to-wm is missing)", "no to-wm")
        #expect(!FileManager.default.fileExists(atPath: half.to.path))
    }

    @Test func aFolderThatIsntARealDirectoryIsUnreachable() throws {
        // to-wm itself a link to a real, owner-only folder with a live .listening.
        let linked = try Manager(scratch)
        let real = scratch.url("elsewhere")
        try FileManager.default.moveItem(at: linked.to, to: real)
        try FileManager.default.createSymbolicLink(at: linked.to, withDestinationURL: real)
        try expectUnreachable(linked, says: Self.notRunning + " (to-wm isn't a real folder)", "to-wm a link")
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path) == [".listening"])

        // A link on the way down from the home: each folder above to-wm in turn.
        for part in VibePaths.walletLocalTransportParts {
            let manager = try Manager(scratch)
            var folder = manager.home
            for name in VibePaths.walletLocalTransportParts {
                folder.appendPathComponent(name, isDirectory: true)
                if name == part { break }
            }
            let moved = scratch.url("moved")
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
            // Through the link everything is there, as the Wallet Manager left it.
            #expect(FileManager.default.fileExists(atPath: manager.listening.path))
            try expectUnreachable(manager, says: Self.notRunning + " (\(part) isn't a real folder)", "\(part) a link")
        }

        // A file where to-wm should be.
        let file = try Manager(scratch, started: false)
        try FileManager.default.createDirectory(at: file.transport, withIntermediateDirectories: true)
        try Data("\(getpid())\n".utf8).write(to: file.to)
        try expectUnreachable(file, says: Self.notRunning + " (to-wm isn't a real folder)", "to-wm a file")
    }

    @Test func aFolderOthersCanUseOrThatIsntThisUsersIsUnreachable() throws {
        // Any group or other permission bit on to-wm.
        for mode in [0o750, 0o705, 0o701, 0o710, 0o770, 0o777, 0o755] as [mode_t] {
            let manager = try Manager(scratch)
            chmod(manager.to.path, mode)
            try expectUnreachable(manager, says: Self.notRunning + " (to-wm isn't owner-only (0700))", "to-wm \(String(mode, radix: 8))")
        }
        // A folder above it that others can write.
        let open = try Manager(scratch)
        chmod(open.transport.path, 0o777)
        try expectUnreachable(open, says: Self.notRunning + " (local-transport can be written by others)", "local-transport 777")
        // Not this user's: as another user sees the very same folders.
        let manager = try Manager(scratch)
        try expectUnreachable(manager, says: Self.notRunning + " (Library isn't this user's)",
                              link: WalletLocalLink(home: manager.home.path, owner: getuid() + 1), "another user's")
        // As they are, for this user: reachable.
        #expect(manager.link.notReachable() == nil)
    }

    /// The liveness rule: to-wm/.listening, a small regular file of this user's holding the process id of a process
    /// that runs. Anything else is unreachable.
    @Test func withoutALiveListeningFileItIsUnreachable() throws {
        // A process that has ended (reaped: its id names nothing now).
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        #expect(waitForEnd(ended))

        let missing = try Manager(scratch, accepting: false)
        try expectUnreachable(missing, says: Self.notAccepting + " (no readable .listening in to-wm)", "no .listening")
        #expect(missing.link.notReachable()?.hasSuffix(": start it with its local transport and accept this Mac's requests there") == true)

        let contents: [(String, String)] = [
            ("", ".listening doesn't hold a process id"), ("\n", ".listening doesn't hold a process id"), ("abc\n", ".listening doesn't hold a process id"),
            ("12 34\n", ".listening doesn't hold a process id"), (" \(getpid())\n", ".listening doesn't hold a process id"), ("\(getpid())\n\n", ".listening doesn't hold a process id"),
            ("-\(getpid())\n", ".listening doesn't hold a process id"), ("0\(getpid())\n", ".listening doesn't hold a process id"), ("0\n", ".listening doesn't hold a process id"),
            ("\(getpid()).0\n", ".listening doesn't hold a process id"), ("99999999999\n", ".listening doesn't hold a process id"),
            // launchd runs, as root: not a Wallet Manager of this user's.
            ("1\n", ".listening doesn't hold a process id"),
            ("\(ended.processIdentifier)\n", "the process .listening names, \(ended.processIdentifier), isn't running"),
            // Over its size limit, though it starts with a live process id.
            ("\(getpid())\n" + String(repeating: " ", count: 40), "no readable .listening in to-wm"),
        ]
        for (content, why) in contents {
            let manager = try Manager(scratch, accepting: false)
            try manager.accept(content)
            try expectUnreachable(manager, says: Self.notAccepting + " (\(why))", "\(content.debugDescription)")
        }

        // A link to a file that holds a live process id; a folder; a file of another user's.
        let linked = try Manager(scratch, accepting: false)
        let real = scratch.url("listening")
        try Data("\(getpid())\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: linked.listening, withDestinationURL: real)
        try expectUnreachable(linked, says: Self.notAccepting + " (no readable .listening in to-wm)", "a link")
        let folder = try Manager(scratch, accepting: false)
        try FileManager.default.createDirectory(at: folder.listening, withIntermediateDirectories: false)
        try expectUnreachable(folder, says: Self.notAccepting + " (no readable .listening in to-wm)", "a folder")
        let manager = try Manager(scratch)
        let to = try manager.link.open("to-wm")
        #expect(throws: WalletLocalLink.Failure.self) { try WalletLocalLink.listener(in: to, owner: getuid() + 1) }

        // This process's id, with a line end or without: listening.
        #expect(try WalletLocalLink.listener(in: to, owner: getuid()) == getpid())
        try manager.accept("\(getpid())")
        #expect(try WalletLocalLink.listener(in: to, owner: getuid()) == getpid())
        #expect(manager.link.notReachable() == nil)
        // Accepted again after a refusal: the same request goes.
        let courier = courier(missing)
        defer { courier.close() }
        try missing.accept()
        #expect(courier.send(Self.request()) == .passage(.sent))
    }

    // MARK: Results

    @Test func onlyNamesOfTheResultFormAreResults() {
        let id = Self.request().id
        func parts(_ name: String) -> String? { WalletLocalLink.parts(ofResultName: name).map { "\($0.id) \($0.sequence)" } }
        #expect(parts("wallet-result-\(id)-1.json") == "\(id) 1")
        #expect(parts("wallet-result-\(id)-27.json") == "\(id) 27")
        #expect(parts("wallet-result-\(id)-1000.json") == "\(id) 1000")
        #expect(parts("wallet-result-abcdef00-0000-4000-8000-000000000001-1.json") == "abcdef00-0000-4000-8000-000000000001 1")
        for name in ["wallet-result-\(id).json", "wallet-result-\(id)-.json", "wallet-result-\(id)-0.json", "wallet-result-\(id)-1001.json",
                     "wallet-result-\(id)-01.json", "wallet-result-\(id)-1.json.tmp", "wallet-result-\(id)-1.JSON", "wallet-result-\(id)-+1.json",
                     "wallet-result-\(id)-1 .json", "wallet-result-\(id)-1-2.json", "wallet-result-\(id)_1.json", "wallet-result-\(id)--1.json",
                     "wallet-result-ABCDEF00-0000-4000-8000-000000000001-1.json", "wallet-result-\(id.dropLast())-1.json", "wallet-result-\(id)x-1.json",
                     "wallet-request-\(id)-1.json", "Wallet-result-\(id)-1.json", " wallet-result-\(id)-1.json", "wallet-result-\(id)-١.json",
                     "wallet-result-\(id)-10000.json", "note.txt", ""] {
            #expect(parts(name) == nil, "\(name)")
        }
    }

    /// Each kind of file in from-wm that isn't a result as the interface has it is ignored (and logged once); the one
    /// that is, beside them, is taken.
    @Test func eachUnusualResultFileIsIgnored() throws {
        let manager = try Manager(scratch)
        let log = Log()
        let courier = courier(manager, log: log)
        defer { courier.close() }
        let requests = (1...9).map { Self.request($0) }
        for request in requests { #expect(courier.send(request) == .passage(.sent)) }
        func name(_ request: WalletRequest, _ sequence: Int = 1) -> String { "wallet-result-\(request.id)-\(sequence).json" }
        func received(_ request: WalletRequest, sequence: Int64 = 1) throws -> Data { try Self.result(request, .received, sequence: sequence).encoded() }

        // 1: a link to a result that is all it should be, kept elsewhere.
        let elsewhere = scratch.url("result.json")
        try received(requests[0]).write(to: elsewhere)
        let linked = manager.from.appendingPathComponent(name(requests[0])).path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: elsewhere.path)
        // 2: over 64 KiB.
        let large = try manager.put(try received(requests[1]) + Data(repeating: 0x20, count: WalletRequestFormat.maxFileBytes), as: name(requests[1]))
        // 3: a folder under a result's name.
        let folder = manager.from.appendingPathComponent(name(requests[2])).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        // 4: Passage's name for a result (no sequence), and others that aren't the form.
        let unnumbered = try manager.put(try received(requests[3]), as: "wallet-result-\(requests[3].id).json")
        let padded = try manager.put(try received(requests[3]), as: "wallet-result-\(requests[3].id)-01.json")
        let beyond = try manager.put(try received(requests[3]), as: "wallet-result-\(requests[3].id)-1001.json")
        let note = try manager.put(Data("hello".utf8), as: "note.txt")
        // 5: its content's id is another request's.
        let wrongID = try manager.put(try received(requests[5]), as: name(requests[4]))
        // 6: its content's sequence isn't its name's.
        let wrongSequence = try manager.put(try received(requests[5], sequence: 2), as: name(requests[5], 3))
        // 7: not a result at all, by the strict parser.
        let broken = try manager.put(Data("{not json".utf8), as: name(requests[6]))
        // 8: a dot-name (one on its way in, or left by a writer that stopped): not looked at.
        try received(requests[7]).write(to: manager.from.appendingPathComponent("." + name(requests[7])))
        // 9: as it should be.
        try manager.answer(Self.result(requests[8], .received, sequence: 1))

        // A look that covers them all (the watch on the folder may have taken the one already).
        courier.poll()
        for request in requests.dropLast() { #expect(courier.record(request.id)?.results.isEmpty == true, "\(request.id)") }
        #expect(courier.record(requests[8].id)?.results.map(\.sequence) == [1])
        #expect(log.lines.contains { $0.hasPrefix("ignored \(linked): refused: can't open") })
        #expect(log.lines.contains { $0.hasPrefix("ignored \(large): refused:") && $0.contains("over the 65536-byte limit") })
        #expect(log.lines.contains("ignored \(folder): refused: wallet-result-\(requests[2].id)-1.json isn't a regular file"))
        for path in [unnumbered, padded, beyond, note] {
            #expect(log.lines.contains("ignored \(path): not a wallet result (\((path as NSString).lastPathComponent))"))
        }
        #expect(log.lines.contains("ignored \(wrongID): refused: its id \(requests[5].id) isn't its name's \(requests[4].id)"))
        #expect(log.lines.contains("ignored \(wrongSequence): refused: its sequence 2 isn't its name's 3"))
        #expect(log.lines.contains { $0.hasPrefix("ignored \(broken): refused: not JSON") })
        #expect(!log.lines.contains { $0.contains("/." + name(requests[7])) })
        // Each looked at once: nothing more is taken or logged at the next look.
        let ignored = log.lines.filter { $0.hasPrefix("ignored ") }.count
        #expect(ignored == 10)
        courier.poll()
        #expect(log.lines.filter { $0.hasPrefix("ignored ") }.count == ignored)

        // A file of another user's: the same read, as another user makes it.
        let from = try manager.link.open("from-wm")
        #expect(throws: WalletLocalLink.Failure(description: "\(name(requests[8])) isn't this user's")) {
            try WalletLocalLink.read(name(requests[8]), in: from, limit: WalletRequestFormat.maxFileBytes, owner: getuid() + 1)
        }
    }

    /// from-wm gets the folder checks to-wm gets: while it fails one, nothing in it is read.
    @Test func resultsInAFromFolderThatFailsTheFolderChecksAreNotRead() throws {
        let manager = try Manager(scratch)
        let log = Log()
        let courier = courier(manager, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        // Group-readable before the result is there: the watch's own look may come at any time.
        chmod(manager.from.path, 0o750)
        try manager.answer(Self.result(request, .received, sequence: 1))
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("from-wm can't be read: from-wm isn't owner-only (0700)"))
        // Still not owner-only while it's moved, so no look finds the result in a folder that passes.
        let real = scratch.url("from")
        try FileManager.default.moveItem(at: manager.from, to: real)
        try FileManager.default.createSymbolicLink(at: manager.from, withDestinationURL: real)
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("from-wm can't be read: from-wm isn't a real folder"))
        // The watch's own look, heard as from-wm was moved, may have found it missing before the link was there: that
        // look is over now (`poll` waits for one under way), so "missing" is counted from here.
        let missing = { log.lines.filter { $0 == "from-wm can't be read: from-wm is missing" }.count }
        let before = missing()
        try FileManager.default.removeItem(at: manager.from)
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("from-wm can't be read: from-wm is missing"))
        // Said once while it stays so, however often it's looked at.
        #expect(courier.poll().isEmpty)
        #expect(courier.poll().isEmpty)
        #expect(missing() == before + 1)
        #expect(courier.record(request.id)?.results.isEmpty == true)
        // Put back as the Wallet Manager makes it: the result is taken.
        chmod(real.path, 0o700)
        try FileManager.default.moveItem(at: real, to: manager.from)
        courier.poll()
        #expect(courier.record(request.id)?.results.map(\.sequence) == [1])
    }

    /// The courier's rules, the ones Passage's results go through (PassageLinkTests): in `sequence` order, nothing
    /// after a final status, each file once, only for a request that's outstanding. Its own log lines say which.
    @Test func resultsGoThroughTheCouriersRulesAsPassagesDo() throws {
        let manager = try Manager(scratch)
        let log = Log()
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let courier = courier(manager, log: log, store: store)
        defer { courier.close() }
        let taken = Taken()
        courier.onTaken { taken.add($0) }
        let request = Self.request(), other = Self.request(2)
        // There before the requests go, so one look finds them together (the watch on the folder starts with the send).
        // Written 10, then 2, then 1: taken 1, 2, 10 (by number, not by name or by when).
        try manager.answer(Self.result(request, .signed, sequence: 10))
        try manager.answer(Self.result(request, .proposed, sequence: 2))
        try manager.answer(Self.result(request, .received, sequence: 1))
        // A final status ends it: what comes after is ignored, in the same look or a later one.
        try manager.answer(Self.result(other, .rejected, sequence: 1))
        let second = try manager.answer(Self.result(other, .submitted, sequence: 2))
        #expect(courier.send(request) == .passage(.sent))
        #expect(courier.send(other) == .passage(.sent))
        // `poll` returns once a look that covers it is done, whoever took them (it, or the watch's own look).
        courier.poll()
        #expect(taken.all.filter { $0.id == request.id }.map(\.status) == [.received, .proposed, .signed])
        #expect(courier.record(request.id)?.results.map(\.sequence) == [1, 2, 10])
        #expect(taken.all.filter { $0.id == other.id }.map(\.status) == [.rejected])
        #expect(log.lines.contains("ignored \(second): a second result for request \(other.id), already finished (rejected)"))
        // Each once.
        courier.poll()
        #expect(taken.all.count == 4)
        // One that isn't after the last taken.
        let late = try manager.answer(Self.result(request, .proposed, sequence: 3))
        courier.poll()
        #expect(log.lines.contains("ignored \(late): result 3 for request \(request.id) isn't after 10"))
        let third = try manager.answer(Self.result(other, .submitted, sequence: 3))
        courier.poll()
        #expect(log.lines.contains("ignored \(third): a result for request \(other.id), already finished (rejected)"))
        #expect(courier.outstanding == [request])
        // A request this courier never sent.
        let unknown = try manager.answer(Self.result(Self.request(3), .received, sequence: 1))
        courier.poll()
        #expect(log.lines.contains("ignored \(unknown): a result for an unknown request id \(Self.request(3).id)"))
        #expect(taken.all.count == 4)

        // A courier made again over the same records (a restart) takes none of them twice, and the next one once.
        courier.close()
        let again = WalletCourier(link: manager.link, store: store, log: { [log] in log.note($0) }, now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { again.close() }
        again.onTaken { taken.add($0) }
        again.poll()
        #expect(taken.all.count == 4)
        #expect(again.record(request.id)?.results.map(\.sequence) == [1, 2, 10])
        try manager.answer(Self.result(request, .submitted, sequence: 11))
        again.poll()
        #expect(taken.all.count == 5 && taken.all.last?.status == .submitted)
        #expect(again.record(request.id)?.results.map(\.sequence) == [1, 2, 10, 11])
        #expect(again.outstanding.isEmpty)
    }

    // MARK: Listening

    /// While a request is outstanding from-wm is watched, and a result is taken as its file appears, with no one
    /// asking; once none is outstanding the watch stops. No process is started for it.
    @Test func aResultIsTakenAsItsFileAppearsWhileARequestIsOutstanding() async throws {
        let manager = try Manager(scratch)
        let log = Log()
        let courier = courier(manager, log: log)
        defer { courier.close() }
        let taken = Taken()
        courier.onTaken { taken.add($0) }
        #expect(!courier.isListening)
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        #expect(courier.isListening && courier.listenerPID == nil)
        #expect(log.lines.contains("the watch on from-wm started: 1 request(s) outstanding"))
        #expect(!FileManager.default.fileExists(atPath: WalletCourier.ListenRecord.file(in: courier.store.folder).path))

        try manager.answer(Self.result(request, .received, sequence: 1))
        #expect(await eventually { taken.all.map(\.sequence) == [1] })
        // Several at once: all are taken, in order.
        try manager.answer(Self.result(request, .proposed, sequence: 2))
        try manager.answer(Self.result(request, .signed, sequence: 3))
        try manager.answer(Self.result(request, .submitted, sequence: 4))
        #expect(await eventually { taken.all.map(\.sequence) == [1, 2, 3, 4] })
        #expect(courier.record(request.id)?.finished == true)
        #expect(await eventually { !courier.isListening })
        #expect(log.lines.contains("the watch on from-wm stopped: no request outstanding"))
    }

    /// The look the watch asks for runs on a queue of the courier's own, not on GCD's shared utility queue: that one
    /// gave it no thread while the rest of the process kept every core busy (a full test run does), and every `poll`
    /// asked meanwhile waited behind the look. A courier over Passage looks where it always did.
    @Test func aLookTheWatchAsksForRunsOnTheCouriersOwnQueue() async throws {
        let manager = try Manager(scratch)
        let courier = courier(manager)
        defer { courier.close() }
        let ran = Log()
        courier.onTaken { _ in ran.note(String(cString: __dispatch_queue_get_label(nil))) }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        try manager.answer(Self.result(request, .received, sequence: 1))
        #expect(await eventually { !ran.lines.isEmpty })
        #expect(ran.lines == [WalletCourier.looksLabel])

        let passage = WalletCourier(link: try PassageLinkTests.FakePassage(scratch).link, store: WalletRequestStore(folder: scratch.url("passage-requests")),
                                    log: { _ in }, now: { PassageLinkTests.created.addingTimeInterval(30) })
        defer { passage.close() }
        #expect(passage.looks == nil)
    }

    /// The watch ends when from-wm itself goes (the Wallet Manager made the pair again): the folder that has the name
    /// now is not the one that was watched.
    @Test func theWatchEndsWhenTheFolderIsReplaced() async throws {
        let manager = try Manager(scratch)
        let heard = Taken()
        let watch = try manager.link.watch { heard.add([]) }
        defer { watch.stop(grace: 0) }
        #expect(watch.isRunning && watch.process == nil)
        try FileManager.default.moveItem(at: manager.from, to: scratch.url("old-from"))
        #expect(await eventually { !watch.isRunning })
        // No watch on a from-wm that fails the folder checks.
        #expect(throws: WalletLocalLink.Failure(description: "from-wm is missing")) { _ = try manager.link.watch {} }
    }

    /// A retired courier (Settings › Wallet no longer has the Wallet Manager on this Mac chosen) stops its watch, starts
    /// none again and reads nothing more from from-wm, though its request is still outstanding; its record stays, and
    /// a courier made over it later takes what waited.
    @Test func aRetiredCourierNeitherWatchesNorReadsAgain() async throws {
        let manager = try Manager(scratch)
        let log = Log()
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let courier = courier(manager, log: log, store: store)
        defer { courier.close() }
        let taken = Taken()
        courier.onTaken { taken.add($0) }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        #expect(courier.isListening)

        courier.retire()
        #expect(!courier.isListening)
        try manager.answer(Self.result(request, .received, sequence: 1))
        // Asked to look, by the desk or by a watch's last word, and to listen again: it does neither.
        #expect(courier.poll().isEmpty)
        courier.syncListener()
        #expect(!courier.isListening)
        courier.heardListenLine()
        #expect(await eventually { courier.pollsPending == 0 })
        #expect(taken.all.isEmpty)
        #expect(courier.outstanding == [request])
        #expect(store.load().first?.results.isEmpty == true)
        #expect(!log.lines.contains { $0.hasPrefix("result ") || $0.hasPrefix("ignored ") })
        #expect(log.lines.filter { $0.hasPrefix("the watch on from-wm started") }.count == 1)

        // Chosen again: a new courier over the same records takes it.
        let again = self.courier(manager, log: log, store: store)
        defer { again.close() }
        #expect(again.poll().map(\.sequence) == [1])
    }

    final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [WalletResult] = []
        private var count = 0
        func add(_ more: [WalletResult]) { lock.withLock { results += more; count += 1 } }
        var all: [WalletResult] { lock.withLock { results } }
        var calls: Int { lock.withLock { count } }
    }
}
