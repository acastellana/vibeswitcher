import Foundation
import Testing
@testable import VibeCore

/// VibeSwitcher's Passage link to the Wallet Manager's Mac, against a fake `passage` script in a scratch folder (never the real
/// one, its Keychain, pairings or inbox): what `passage send` is run with and how each exit code reads, which inbox
/// results are taken, `passage listen` running only while a request is outstanding, and the records surviving a
/// restart.
struct PassageLinkTests {
    let scratch = Scratch()
    static let peer = "0a1b2c3d"
    static let otherPeer = "0d0d0d0d"

    /// A folder holding the fake `passage`, its inbox, and what each call left: `calls` (one line of arguments per
    /// run), `sent-<name>` (the file `send` was given), `listen.pid` and `listen.stopped`. `send-exit` sets send's exit
    /// code, `send-signal` a signal it ends by instead; with `send-hold`, send makes `send-started` and waits for
    /// `send-go`. `inbox.jsonl` is what `inbox` prints.
    struct FakePassage {
        let folder: URL
        /// `passage` in `folder`, or with `app`, the binary of a fake `Passage.app` there.
        let executable: String
        /// How the link runs it: Passage.app's binary with `cli` first.
        let command: PassageCommand
        var inbox: URL { folder.appendingPathComponent("inbox", isDirectory: true) }

        /// With `app`, it's Passage.app's binary: it acts only when its first argument is `cli` (logged with the
        /// rest), and otherwise says it would open its window and exits 70.
        init(_ scratch: Scratch, app: Bool = false) throws {
            folder = scratch.url("passage")
            executable = app ? folder.appendingPathComponent("Passage.app/Contents/MacOS/Passage").path : folder.appendingPathComponent("passage").path
            command = try #require(PassageCommand.forPath(app ? folder.appendingPathComponent("Passage.app").path : executable))
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
                    if [ -e "$here/send-signal" ]; then kill -s "$(cat "$here/send-signal")" $$; fi
                    if [ -e "$here/send-hold" ]; then
                        touch "$here/send-started"
                        for _ in $(seq 1 15000); do [ -e "$here/send-go" ] && break; /bin/sleep 0.02; done
                    fi
                    code=$(cat "$here/send-exit" 2>/dev/null || echo 0)
                    cp "$3" "$here/sent-$5"
                    if [ "$code" = 0 ]; then
                        if [ ! -e "$here/send-quiet" ]; then printf 'sent\\t%s\\t%s\\t%s\\n' "$2" "$5" "$(wc -c < "$3" | tr -d ' ')"; fi
                    else
                        echo "passage: fake exit $code" >&2
                    fi
                    exit "$code" ;;
                inbox)
                    cat "$here/inbox.jsonl" 2>/dev/null
                    exit 0 ;;
                listen)
                    trap 'echo TERM > "$here/listen.stopped"; kill $! 2>/dev/null; exit 0' TERM
                    /bin/sleep 3600 &
                    echo $$ > "$here/listen.pid"
                    if [ -e "$here/listen-line" ]; then cat "$here/listen-line"; fi
                    wait $!
                    exit 0 ;;
                esac
                exit 2
                """
            try script.write(toFile: executable, atomically: true, encoding: .utf8)
            chmod(executable, 0o755)
        }

        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        func text(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }
        var calls: [String] { (text("calls") ?? "").split(separator: "\n").map(String.init) }

        func setSendExit(_ code: Int32) throws { try "\(code)\n".write(to: file("send-exit"), atomically: true, encoding: .utf8) }

        /// Puts `data` in the inbox as `name` from `peer`, as passage would, and lists it in `inbox.jsonl`.
        @discardableResult
        func receive(_ data: Data, name: String, from peer: String = PassageLinkTests.peer, second: Int = 0) throws -> String {
            let dir = inbox.appendingPathComponent(peer, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = String(format: "20261031T1201%02dZ", second)
            let path = dir.appendingPathComponent("\(stamp)-\(name)").path
            try data.write(to: URL(fileURLWithPath: path))
            let line = WalletRequestFormat.Value.object([.init("peerID", .string(peer)), .init("name", .string(name)),
                                                 .init("size", .integer(Int64(data.count))), .init("receivedAt", .string(stamp)),
                                                 .init("path", .string(path))]).encoded()
            let handle = try FileHandle(forWritingTo: file("inbox.jsonl").creatingIfMissing())
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
            return path
        }

        @discardableResult
        func receive(_ result: WalletResult, from peer: String = PassageLinkTests.peer, second: Int = 0) throws -> String {
            try receive(result.encoded(), name: WalletResult.fileName(result.id), from: peer, second: second)
        }

        var link: PassageLink { PassageLink(command: command, walletPeer: PassageLinkTests.peer, inboxFolder: inbox)! }
    }

    /// What a courier logged.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func note(_ line: String) {
            lock.lock()
            all.append(line)
            lock.unlock()
        }
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }
    }

    static let created = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z

    static func request(_ number: Int = 1) -> WalletRequest {
        var request = WalletRequestFormatTests.request()
        request.id = String(format: "00000000-0000-4000-8000-%012d", number)
        return request
    }

    static func result(_ request: WalletRequest, _ status: WalletResult.Status, sequence: Int64) -> WalletResult {
        var result = WalletResult(id: request.id, sequence: sequence, createdAt: created.addingTimeInterval(60), status: status,
                                 checks: [.init(name: "format", ok: true, detail: "")], message: status.rawValue)
        if status == .submitted { result.txHash = "0x" + String(repeating: "ab", count: 32) }
        return result
    }

    func courier(_ fake: FakePassage, log: Log, store: WalletRequestStore? = nil) -> WalletCourier {
        WalletCourier(link: fake.link, store: store ?? WalletRequestStore(folder: scratch.url("requests")), log: { [log] in log.note($0) },
                     now: { Self.created.addingTimeInterval(30) })
    }

    // MARK: Sending

    @Test func sendRunsPassageSendWithTheRequestsNameAndNeverYes() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let send = try #require(fake.calls.first { $0.hasPrefix("send ") })
        let file = courier.store.folder.appendingPathComponent("outbox/wallet-request-\(request.id).json").path
        #expect(send == "send \(Self.peer) \(file) --name wallet-request-\(request.id).json")
        #expect(!fake.calls.joined().contains("--yes"))
        // What went is the request's own checked file, and the copy sent isn't left behind.
        #expect(try WalletRequest.parse(Data(contentsOf: fake.file("sent-wallet-request-\(request.id).json"))) == request)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(courier.outstanding == [request])
        #expect(courier.record(request.id)?.state == .sent)
    }

    /// 2–5 end before anything went: the record goes. 1 and the rest may have reached the Wallet Manager: it stays, unsure.
    @Test(arguments: [(Int32(1), PassageLink.SendOutcome.failed("passage: fake exit 1"), true),
                      (2, .usage("passage: fake exit 2"), false), (3, .noSuchPeer("passage: fake exit 3"), false),
                      (4, .peerNotListening("passage: fake exit 4"), false), (5, .refusedAsSecret("passage: fake exit 5"), false),
                      (7, .unexpected("passage send exited 7: passage: fake exit 7"), true)])
    func eachExitCodeHasItsOwnOutcome(_ code: Int32, _ expected: PassageLink.SendOutcome, _ mayHaveArrived: Bool) throws {
        let fake = try FakePassage(scratch)
        try fake.setSendExit(code)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(expected))
        #expect(expected.mayHaveArrived == mayHaveArrived)
        if mayHaveArrived {
            #expect(courier.outstanding == [request])
            #expect(courier.record(request.id)?.state == .unsure)
            #expect(courier.listenerPID != nil)
        } else {
            // Not sent: not outstanding, no record, and listening has stopped.
            #expect(courier.outstanding.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: courier.store.file(request.id).path))
            #expect(courier.listenerPID == nil)
        }
    }

    /// A signal's number isn't an exit code: ended by SIGHUP (1) or SIGINT (2) is unexpected, not failed or usage.
    @Test(arguments: [SIGHUP, SIGINT])
    func aSignalIsntReadAsAnExitCode(_ signal: Int32) throws {
        let fake = try FakePassage(scratch)
        try "\(signal)\n".write(to: fake.file("send-signal"), atomically: true, encoding: .utf8)
        let file = scratch.url("request.json")
        try WalletRequestFormatTests.request().encoded().write(to: file)
        let outcome = fake.link.send(file: file, id: WalletRequestFormatTests.request().id)
        #expect(outcome == .unexpected("passage send was ended by signal \(signal)"))
    }

    /// Unsure: it takes the Wallet Manager's results, and the very same request may go again under its id; another may not.
    @Test func anUnsureRequestIsTrackedAndMayBeResent() throws {
        let fake = try FakePassage(scratch)
        try fake.setSendExit(1)
        let courier = courier(fake, log: Log())
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.failed("passage: fake exit 1")))
        try fake.receive(Self.result(request, .received, sequence: 1))
        #expect(courier.poll().map(\.id) == [request.id])
        #expect(courier.record(request.id)?.state == .unsure)
        // Sent again: once more under its id, keeping what was taken; a different request under that id is refused.
        try fake.setSendExit(0)
        #expect(courier.send(request) == .passage(.sent))
        #expect(fake.calls.filter { $0.hasPrefix("send ") }.count == 2)
        #expect(courier.record(request.id)?.state == .sent)
        #expect(courier.record(request.id)?.results.map(\.sequence) == [1])
        var other = request
        other.reason = "Another reason."
        guard case .refused = courier.send(other) else {
            Issue.record("sent a different request under a taken id")
            return
        }
        // A resend that doesn't go (here: 4) leaves an unsure record unsure, never removed.
        let second = Self.request(2)
        try fake.setSendExit(1)
        #expect(courier.send(second) == .passage(.failed("passage: fake exit 1")))
        try fake.setSendExit(4)
        #expect(courier.send(second) == .passage(.peerNotListening("passage: fake exit 4")))
        #expect(courier.record(second.id)?.state == .unsure)
    }

    /// A result taken while passage send still runs (the listener heard it) is kept when the send returns.
    @Test func resultsTakenDuringASendAreKept() throws {
        let fake = try FakePassage(scratch)
        try Data().write(to: fake.file("send-hold"))
        let courier = courier(fake, log: Log())
        defer { courier.close() }
        let request = Self.request()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: WalletCourier.SendOutcome?
        Thread.detachNewThread {
            outcome = courier.send(request)
            done.signal()
        }
        #expect(eventually { FileManager.default.fileExists(atPath: fake.file("send-started").path) })
        try fake.receive(Self.result(request, .rejected, sequence: 1))
        #expect(courier.poll().map(\.status) == [.rejected])
        try Data().write(to: fake.file("send-go"))
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        #expect(outcome == .passage(.sent))
        #expect(courier.record(request.id)?.results.map(\.status) == [.rejected])
        #expect(courier.record(request.id)?.state == .sent)
        #expect(try courier.store.read(courier.store.file(request.id)).results.map(\.status) == [.rejected])
        #expect(courier.outstanding.isEmpty)
        #expect(courier.listenerPID == nil)
    }

    @Test func exitZeroIsSentOnlyWithPassagesLine() throws {
        let fake = try FakePassage(scratch)
        let link = fake.link
        let file = scratch.url("request.json")
        try WalletRequestFormatTests.request().encoded().write(to: file)
        #expect(link.send(file: file, id: WalletRequestFormatTests.request().id) == .sent)
        try Data().write(to: fake.file("send-quiet"))
        guard case .unexpected = link.send(file: file, id: WalletRequestFormatTests.request().id) else {
            Issue.record("exit 0 without the sent line counted as sent")
            return
        }
    }

    @Test func aRequestHoldingKeyMaterialIsNeverSent() throws {
        let fake = try FakePassage(scratch)
        let courier = courier(fake, log: Log())
        defer { courier.close() }
        let request = WalletRequestFormatTests.request(reason: "key " + WalletRequestFormatTests.hex64)
        guard case let .refused(why) = courier.send(request) else {
            Issue.record("sent a request holding key material")
            return
        }
        #expect(why.contains("looks like key material"))
        #expect(fake.calls.isEmpty)
    }

    // MARK: Results

    @Test func aResultForAnOutstandingRequestIsTaken() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        // Two at once, the later one first: taken in sequence order.
        try fake.receive(Self.result(request, .proposed, sequence: 2), second: 1)
        try fake.receive(Self.result(request, .received, sequence: 1), second: 2)
        #expect(courier.poll().map(\.status) == [.received, .proposed])
        #expect(fake.calls.contains("inbox \(Self.peer) --json"))
        #expect(courier.record(request.id)?.results.map(\.sequence) == [1, 2])
        // Seen once: a second poll takes nothing again.
        #expect(courier.poll().isEmpty)
        try fake.receive(Self.result(request, .submitted, sequence: 3), second: 3)
        #expect(courier.poll().map(\.status) == [.submitted])
        #expect(courier.outstanding.isEmpty)
    }

    @Test func aResultForAnUnknownIDIsIgnoredAndLogged() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        #expect(courier.send(Self.request(1)) == .passage(.sent))
        let path = try fake.receive(Self.result(Self.request(2), .received, sequence: 1))
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("ignored \(path): a result for an unknown request id \(Self.request(2).id)"))
        #expect(courier.record(Self.request(1).id)?.results.isEmpty == true)
        // Logged once, not at every poll.
        courier.poll()
        #expect(log.lines.filter { $0.hasPrefix("ignored \(path)") }.count == 1)
    }

    @Test func aResultFromAnotherPeerIsIgnoredAndLogged() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let path = try fake.receive(Self.result(request, .received, sequence: 1), from: Self.otherPeer)
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("ignored \(path): from peer \(Self.otherPeer), not the Wallet Manager peer \(Self.peer)"))
        #expect(courier.record(request.id)?.results.isEmpty == true)
    }

    @Test func aSecondResultForAFinishedRequestIsIgnoredAndLogged() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        try fake.receive(Self.result(request, .rejected, sequence: 1))
        #expect(courier.poll().map(\.status) == [.rejected])
        let path = try fake.receive(Self.result(request, .proposed, sequence: 2), second: 1)
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains("ignored \(path): a result for request \(request.id), already finished (rejected)"))
        #expect(courier.record(request.id)?.results.map(\.status) == [.rejected])
        // Two in one listing: the one after the final result is ignored too.
        let other = Self.request(2)
        #expect(courier.send(other) == .passage(.sent))
        try fake.receive(Self.result(other, .failed, sequence: 1), second: 2)
        let late = try fake.receive(Self.result(other, .submitted, sequence: 2), second: 3)
        #expect(courier.poll().map(\.status) == [.failed])
        #expect(log.lines.contains("ignored \(late): a second result for request \(other.id), already finished (failed)"))
    }

    @Test func aResultThatDoesntParseOrIsntItsNamesIsIgnored() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let name = WalletResult.fileName(request.id)
        let broken = try fake.receive(Data("{\"type\":".utf8), name: name)
        let wrongID = try fake.receive(Self.result(Self.request(2), .received, sequence: 1).encoded(), name: name, second: 1)
        let note = try fake.receive(Data("hello".utf8), name: "note.txt", second: 2)
        #expect(courier.poll().isEmpty)
        #expect(log.lines.contains { $0.hasPrefix("ignored \(broken): refused: not JSON") })
        #expect(log.lines.contains("ignored \(wrongID): its id \(Self.request(2).id) isn't its name's \(request.id)"))
        #expect(log.lines.contains("ignored \(note): not a wallet result (note.txt)"))
    }

    // MARK: Listening

    /// A line `passage listen` prints is heard as it's printed, while passage keeps running: not once 4 KiB have piled
    /// up or it ends (FileHandle's read(upToCount:) waits on a pipe for both; found by scripts/e2e/loop-passage).
    @Test func aListenLineIsHeardWhilePassageRuns() throws {
        let fake = try FakePassage(scratch)
        try "\(Self.peer)\twallet-result-x.json\t/made/up/path\n".write(to: fake.file("listen-line"), atomically: true, encoding: .utf8)
        let link = try #require(PassageLink(command: fake.command, walletPeer: Self.peer, inboxFolder: fake.inbox))
        let heard = DispatchSemaphore(value: 0)
        let listener = try link.listen { heard.signal() }
        defer { listener.stop() }
        #expect(heard.wait(timeout: .now() + hangGuard) == .success)
        #expect(listener.isRunning)
    }

    @Test func passageListenRunsOnlyWhileARequestIsOutstanding() throws {
        let fake = try FakePassage(scratch)
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        // Nothing outstanding: nothing listens.
        #expect(courier.listenerPID == nil)
        #expect(!fake.calls.contains("listen"))
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let pid = try #require(courier.listenerPID)
        // The script it started is the one with that pid.
        #expect(eventually { fake.text("listen.pid") != nil })
        #expect(fake.text("listen.pid")?.trimmingCharacters(in: .whitespacesAndNewlines) == "\(pid)")
        #expect(kill(pid, 0) == 0)
        // A final result: nothing outstanding, and it's stopped by its pid (TERM), reaped.
        try fake.receive(Self.result(request, .submitted, sequence: 1))
        #expect(courier.poll().count == 1)
        #expect(courier.listenerPID == nil)
        #expect(fake.text("listen.stopped")?.hasPrefix("TERM") == true)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(log.lines.contains("passage listen (pid \(pid)) stopped: no request outstanding"))
        #expect(fake.calls.filter { $0 == "listen" }.count == 1)
    }

    /// Passage.app's binary runs as its CLI only with `cli` first: send, inbox and listen all put it there.
    @Test func passageAppsBinaryIsRunWithCliFirst() throws {
        let fake = try FakePassage(scratch, app: true)
        #expect(fake.command == PassageCommand(executable: fake.executable, leading: ["cli"]))
        let log = Log()
        let courier = courier(fake, log: log)
        defer { courier.close() }
        let request = Self.request()
        #expect(courier.send(request) == .passage(.sent))
        let pid = try #require(courier.listenerPID)
        #expect(eventually { fake.text("listen.pid") != nil })
        #expect(fake.text("listen.pid")?.trimmingCharacters(in: .whitespacesAndNewlines) == "\(pid)")
        try fake.receive(Self.result(request, .submitted, sequence: 1))
        #expect(courier.poll().count == 1)
        #expect(courier.listenerPID == nil)
        let file = courier.store.folder.appendingPathComponent("outbox/wallet-request-\(request.id).json").path
        #expect(fake.calls.contains("cli send \(Self.peer) \(file) --name wallet-request-\(request.id).json"))
        #expect(fake.calls.contains("cli listen"))
        #expect(fake.calls.contains("cli inbox \(Self.peer) --json"))
        #expect(fake.calls.allSatisfy { $0.hasPrefix("cli ") })
    }

    // MARK: Records

    @Test func outstandingRequestsSurviveARestartAsPrivateFiles() throws {
        let fake = try FakePassage(scratch)
        // The app's own folder, under VibeSwitcher's home (a scratch one in a test run).
        let store = WalletRequestStore()
        #expect(store.folder == VibePaths.root.appendingPathComponent("wallet-requests"))
        let request = Self.request(Int.random(in: 100...999_999))
        defer { store.remove(request.id) }
        let log = Log()
        let first = courier(fake, log: log, store: store)
        #expect(first.send(request) == .passage(.sent))
        let sentAt = try #require(first.record(request.id)?.sentAt)
        first.close()

        var info = stat()
        #expect(stat(store.file(request.id).path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(store.folder.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)

        // A new courier over a new store on the same folder: the app after a restart.
        let second = courier(fake, log: log, store: WalletRequestStore())
        defer { second.close() }
        #expect(second.outstanding.contains(request))
        // The record comes back as it was, with when it was sent ("not picked up" counts from there).
        #expect(second.record(request.id) == WalletRequestStore.Record(request: request, state: .sent, sentAt: sentAt))
        // Still outstanding, so it listens again.
        #expect(second.listenerPID != nil)
        try fake.receive(Self.result(request, .received, sequence: 1))
        #expect(second.poll().map(\.id) == [request.id])
        // The result is kept too, and its inbox file isn't taken twice after another restart.
        let third = courier(fake, log: log, store: WalletRequestStore())
        defer { third.close() }
        #expect(third.record(request.id)?.results.map(\.status) == [.received])
        #expect(third.poll().isEmpty)
    }

    @Test func aRecordThatIsntOneIsKeptAsideAndLogged() throws {
        let folder = scratch.url("requests")
        try VibePaths.ensurePrivate(folder)
        let id = Self.request().id
        try VibePaths.writePrivate(Data("{}".utf8), to: folder.appendingPathComponent("\(id).json"))
        let log = Log()
        #expect(WalletRequestStore(folder: folder).load(log: log.note).isEmpty)
        #expect(log.lines.contains { $0.hasPrefix("kept \(id).json aside") })
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).json").path))
    }
}

private extension URL {
    /// This file, made empty first if it isn't there.
    func creatingIfMissing() throws -> URL {
        if !FileManager.default.fileExists(atPath: path) { try Data().write(to: self) }
        return self
    }
}
