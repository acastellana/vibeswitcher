import Foundation
import Testing
@testable import VibeCore

/// The wallet request plumbing under bursts, crashes and odd input: one `passage inbox` at a time, records read safely
/// and bounded, and a `passage listen` a crash orphaned ended at the next launch. Fake passages in a scratch folder,
/// never the real one.
struct WalletRobustnessTests {
    let scratch = Scratch()
    typealias Fake = PassageLinkTests.FakePassage

    func courier(_ fake: Fake, store: WalletRequestStore? = nil, log: PassageLinkTests.Log = .init(),
                 now: Date = PassageLinkTests.created.addingTimeInterval(30)) -> WalletCourier {
        WalletCourier(link: fake.link, store: store ?? WalletRequestStore(folder: scratch.url("requests")), log: { [log] in log.note($0) },
                      now: { now })
    }

    func inboxRuns(_ fake: Fake) -> Int { fake.calls.filter { $0.hasPrefix("inbox ") }.count }

    // MARK: One poll at a time

    /// Listen lines (and another poll asked) while `passage inbox` runs start no second process: they ask the running
    /// poll to run once more when it's done, once however many asked.
    @Test func listenLinesDuringAPollAskForOneMoreRunNotAnotherProcess() async throws {
        let fake = try Fake(scratch)
        let courier = courier(fake)
        defer { courier.close() }
        FileManager.default.createFile(atPath: fake.file("inbox-hold").path, contents: nil)
        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = courier.poll(); first.signal() }
        #expect(await eventually { FileManager.default.fileExists(atPath: fake.file("inbox-started").path) })
        for _ in 0..<5 { courier.heardListenLine() }
        let second = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = courier.poll(); second.signal() }
        #expect(await eventually { courier.pollsPending == 7 })
        #expect(inboxRuns(fake) == 1)
        try FileManager.default.removeItem(at: fake.file("inbox-hold"))
        FileManager.default.createFile(atPath: fake.file("inbox-go").path, contents: nil)
        #expect(await offPool { first.wait(timeout: .now() + hangGuard) } == .success)
        #expect(await offPool { second.wait(timeout: .now() + hangGuard) } == .success)
        #expect(inboxRuns(fake) == 2)
        #expect(courier.pollsPending == 0)
        // Nothing running: a listen line starts one poll of its own.
        courier.heardListenLine()
        #expect(await eventually { courier.pollsPending == 0 && inboxRuns(fake) == 3 })
    }

    // MARK: Records read safely

    /// A record file is opened without following a link, only as a regular file, and only up to 64 KiB (its size
    /// checked before it's read): a link, a folder, a FIFO (which would block a plain read) or a big file named
    /// `<id>.json` is kept aside and logged; nothing is read through the link.
    @Test func recordFilesAreReadOnlyAsSmallRegularFilesWithNoLinkFollowed() throws {
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let good = WalletRequestStore.Record(request: PassageLinkTests.request(1), state: .sent)
        try store.save(good)
        // A link to a valid record elsewhere.
        let elsewhere = WalletRequestStore(folder: scratch.url("elsewhere"))
        try elsewhere.save(WalletRequestStore.Record(request: PassageLinkTests.request(2), state: .sent))
        try FileManager.default.createSymbolicLink(at: store.file(PassageLinkTests.request(2).id), withDestinationURL: elsewhere.file(PassageLinkTests.request(2).id))
        try FileManager.default.createDirectory(at: store.file(PassageLinkTests.request(3).id), withIntermediateDirectories: true)
        #expect(mkfifo(store.file(PassageLinkTests.request(4).id).path, 0o600) == 0)
        // Over 64 KiB, though it parses as far as it goes.
        var big = WalletRequestStore.encode(WalletRequestStore.Record(request: PassageLinkTests.request(5), state: .sent))
        big.append(Data(repeating: 0x20, count: WalletRequestFormat.maxFileBytes))
        try big.write(to: store.file(PassageLinkTests.request(5).id))
        let log = PassageLinkTests.Log()
        #expect(store.load(log: log.note) == [good])
        for number in 2...5 {
            #expect(log.lines.contains { $0.hasPrefix("kept \(PassageLinkTests.request(number).id).json aside") }, "\(number)")
        }
        #expect(log.lines.contains { $0.contains(PassageLinkTests.request(5).id) && $0.contains("over the 65536-byte limit") })
        // Nothing was changed or removed.
        #expect(FileManager.default.fileExists(atPath: elsewhere.file(PassageLinkTests.request(2).id).path))
    }

    /// A record that would be over 64 KiB isn't written: `save` throws and the file stays as it was; a result that
    /// would make it so is ignored, and logged.
    @Test func aRecordOver64KiBIsNeverWritten() throws {
        let fake = try Fake(scratch)
        let log = PassageLinkTests.Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = PassageLinkTests.request()
        #expect(courier.send(request) == .passage(.sent))
        let before = try Data(contentsOf: courier.store.file(request.id))
        // Results are at most 2000 characters of message each: 40 of them make a record over 64 KiB.
        let results = (1...40).map { sequence -> WalletResult in
            var result = PassageLinkTests.result(request, .received, sequence: Int64(sequence))
            result.message = String(repeating: "x", count: 1900)
            return result
        }
        var record = try #require(courier.record(request.id))
        record.results = results
        #expect(throws: WalletRequestFormat.Failure.self) { try courier.store.save(record) }
        #expect(try Data(contentsOf: courier.store.file(request.id)) == before)
        // From the inbox: those that fit are taken, the rest ignored and logged.
        for result in results { try fake.receive(result, second: Int(result.sequence)) }
        let taken = courier.poll().map(\.sequence)
        #expect(!taken.isEmpty && taken.count < 40 && taken == Array(1...Int64(taken.count)))
        #expect(log.lines.contains { $0.contains("record would be") && $0.contains("over the 65536-byte limit") })
        #expect(courier.record(request.id)?.results.map(\.sequence) == taken)
        #expect(courier.store.load() == [try #require(courier.record(request.id))])
    }

    // MARK: Times, caps and pruning

    @Test func aCreatedAtAheadOfTheClockOrOverAWeekOldIsntBelieved() {
        var request = PassageLinkTests.request()
        let now = request.createdAt
        #expect(request.implausibleTime(now: now) == nil)
        #expect(request.implausibleTime(now: now.addingTimeInterval(-300)) == nil)
        #expect(request.implausibleTime(now: now.addingTimeInterval(-301))?.contains("more than 5 minutes ahead") == true)
        #expect(request.implausibleTime(now: now.addingTimeInterval(7 * 86_400)) == nil)
        #expect(request.implausibleTime(now: now.addingTimeInterval(7 * 86_400 + 1))?.contains("more than 7 days ago") == true)
        // A 7-day request in its results window's last hour is still believed: a final result then still lands.
        var week = request
        week.expiresAt = week.createdAt.addingTimeInterval(WalletRequest.maxLifetime)
        #expect(week.implausibleTime(now: now.addingTimeInterval(7 * 86_400 + 1800)) == nil)
        #expect(week.implausibleTime(now: week.expiresAt.addingTimeInterval(WalletCourier.resultGrace)) != nil)
        // Sent from a clock 10 minutes ahead: refused, nothing run.
        request.createdAt = PassageLinkTests.created.addingTimeInterval(30 + 600)
        request.expiresAt = request.createdAt.addingTimeInterval(3600)
        let fake = try? Fake(scratch)
        if let fake {
            let courier = courier(fake)
            defer { courier.close() }
            #expect(courier.send(request) == .refused(request.implausibleTime(now: PassageLinkTests.created.addingTimeInterval(30))!))
            #expect(fake.calls.isEmpty)
        }
    }

    /// A record whose request's createdAt is over 5 minutes ahead, or over 7 days old, isn't loaded: not
    /// outstanding, not listened for. Its file stays (pruned with its window).
    @Test func recordsWithUnbelievableTimesArentLoaded() throws {
        let fake = try Fake(scratch)
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let now = PassageLinkTests.created.addingTimeInterval(30)
        var ahead = PassageLinkTests.request(1)
        ahead.createdAt = now.addingTimeInterval(400)
        ahead.expiresAt = ahead.createdAt.addingTimeInterval(86_400)
        var old = PassageLinkTests.request(2)
        old.createdAt = now.addingTimeInterval(-8 * 86_400)
        old.expiresAt = old.createdAt.addingTimeInterval(7 * 86_400)
        let fine = PassageLinkTests.request(3)
        for request in [ahead, old, fine] { try store.save(.init(request: request, state: .sent)) }
        let log = PassageLinkTests.Log()
        #expect(store.load(now: now, log: log.note).map(\.request.id) == [fine.id])
        #expect(log.lines.contains { $0.hasPrefix("left \(ahead.id).json out") })
        #expect(log.lines.contains { $0.hasPrefix("left \(old.id).json out") })
        let courier = courier(fake, store: store, now: now)
        defer { courier.close() }
        #expect(courier.outstanding == [fine])
        #expect(courier.record(ahead.id) == nil && courier.record(old.id) == nil)
        #expect(FileManager.default.fileExists(atPath: store.file(ahead.id).path))
    }

    /// At launch the records past their results window by 30 days go; younger ones, and files that aren't records, stay.
    @Test func recordsPastTheirWindowBy30DaysArePruned() throws {
        let store = WalletRequestStore(folder: scratch.url("requests"))
        let gone = PassageLinkTests.request(1)
        var young = PassageLinkTests.request(2)
        young.expiresAt = young.expiresAt.addingTimeInterval(1)
        for request in [gone, young] { try store.save(.init(request: request, state: .sent)) }
        let other = store.folder.appendingPathComponent("00000000-0000-4000-8000-000000000009.json")
        try Data("not a record".utf8).write(to: other)
        let end = gone.expiresAt.addingTimeInterval(WalletCourier.resultGrace + WalletRequestStore.keptAfterWindow)
        #expect(store.prune(now: end.addingTimeInterval(-1)).isEmpty)
        let log = PassageLinkTests.Log()
        #expect(store.prune(now: end, log: log.note) == [gone.id])
        #expect(!FileManager.default.fileExists(atPath: store.file(gone.id).path))
        #expect(FileManager.default.fileExists(atPath: store.file(young.id).path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(log.lines == ["removed \(gone.id).json: its results window ended over 30 days ago"])
    }

    /// The courier forgets, in memory, a record once its results window is over (finished or not), and remembers only
    /// the inbox paths the inbox still lists: what it keeps stays bounded over a long run.
    @Test func theCourierForgetsRecordsPastTheirWindowAndInboxPathsNoLongerListed() throws {
        let fake = try Fake(scratch)
        let clock = Clock(PassageLinkTests.created.addingTimeInterval(30))
        let courier = WalletCourier(link: fake.link, store: WalletRequestStore(folder: scratch.url("requests")), log: { _ in }, now: { clock.now })
        defer { courier.close() }
        let request = PassageLinkTests.request(1)
        #expect(courier.send(request) == .passage(.sent))
        try fake.receive(PassageLinkTests.result(request, .rejected, sequence: 1), second: 1)
        try fake.receive(Data("{}".utf8), name: "notes.txt", second: 2)
        #expect(courier.poll().count == 1)
        #expect(courier.kept.records == 1 && courier.kept.handled == 2)
        // The inbox no longer lists them: forgotten at the next poll.
        try FileManager.default.removeItem(at: fake.file("inbox.jsonl"))
        _ = courier.poll()
        #expect(courier.kept.handled == 0)
        // Past its results window: gone from memory, its file still there for the store's pruning.
        clock.now = request.expiresAt.addingTimeInterval(WalletCourier.resultGrace)
        #expect(courier.outstanding.isEmpty)
        #expect(courier.kept.records == 0 && courier.record(request.id) == nil)
        #expect(FileManager.default.fileExists(atPath: courier.store.file(request.id).path))
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }

    // MARK: A listener a crash left

    /// A stand-in `passage listen` (the fake's, a child of this test, never Passage) recorded as a crashed run would
    /// have left it: ended at the next launch, by its pid. A record whose start time or command line don't match
    /// the process at that pid ends nothing.
    @Test func aListenerACrashLeftIsEndedAtTheNextLaunch() async throws {
        let fake = try Fake(scratch)
        let folder = scratch.url("requests")
        let listen = Process()
        listen.executableURL = URL(fileURLWithPath: fake.executable)
        listen.arguments = ["listen"]
        try listen.run()
        defer { if listen.isRunning { kill(listen.processIdentifier, SIGKILL); waitForEnd(listen) } }
        #expect(await eventually { fake.text("listen.pid") != nil })
        let pid = listen.processIdentifier
        typealias Record = WalletCourier.ListenRecord
        Record.save(pid: pid, executable: fake.executable, in: folder, log: { _ in })
        let saved = try #require(Record.read(in: folder))
        #expect(saved.pid == pid && saved.executable == fake.executable)
        let mode = try FileManager.default.attributesOfItem(atPath: Record.file(in: folder).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Another start time (the pid used again by another process since): left alone, and the record goes.
        var wrongStart = saved
        wrongStart.start.microseconds += 1
        try write(wrongStart, in: folder)
        #expect(!Record.endOrphan(in: folder, log: { _ in }))
        #expect(!FileManager.default.fileExists(atPath: Record.file(in: folder).path))
        // Another program's: left alone.
        var otherProgram = saved
        otherProgram.executable = "/opt/example/bin/passage"
        try write(otherProgram, in: folder)
        #expect(!Record.endOrphan(in: folder, log: { _ in }))
        #expect(listen.isRunning && fake.text("listen.stopped") == nil)
        // The very process: ended (SIGTERM to its pid).
        try write(saved, in: folder)
        let log = PassageLinkTests.Log()
        #expect(Record.endOrphan(in: folder, log: log.note))
        #expect(await exited(listen), "passage listen outlived its SIGTERM")
        #expect(fake.text("listen.stopped")?.hasPrefix("TERM") == true)
        #expect(log.lines == ["ended passage listen (pid \(pid)) an earlier run left running"])
        #expect(!FileManager.default.fileExists(atPath: Record.file(in: folder).path))
        // Its pid now names no process (or a zombie): nothing to end.
        try write(saved, in: folder)
        #expect(!Record.endOrphan(in: folder, log: { _ in }))
    }

    /// The courier keeps the record while its listener runs, and clears it when it stops it.
    @Test func theCourierKeepsItsListenersPidWhileItRuns() throws {
        let fake = try Fake(scratch)
        let courier = courier(fake)
        let request = PassageLinkTests.request()
        #expect(courier.send(request) == .passage(.sent))
        let pid = try #require(courier.listenerPID)
        let saved = try #require(WalletCourier.ListenRecord.read(in: courier.store.folder))
        #expect(saved.pid == pid && saved.executable == fake.executable && WalletCourier.ListenRecord.start(of: pid) == saved.start)
        courier.close()
        #expect(WalletCourier.ListenRecord.read(in: courier.store.folder) == nil)
    }

    func write(_ saved: WalletCourier.ListenRecord.Saved, in folder: URL) throws {
        try VibePaths.writePrivate(Data("\(saved.pid) \(saved.start.seconds) \(saved.start.microseconds)\n\(saved.executable)\n".utf8),
                                   to: WalletCourier.ListenRecord.file(in: folder))
    }
}
