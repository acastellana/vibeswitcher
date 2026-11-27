import Foundation
import Testing
import VibeCore
@testable import VibeNode

// The independent review of v2-node-kinds' C5, C7 and C8 (2026-11-27): its four findings with a failing test, copied
// from the review's ReviewKindsAttackTests.swift (`ReviewKindsFindingTests`, with the helpers they use). Each failed on
// 62b39b11 and on v2-project-new-fix2 (c32aaf04); each passes with its fix: N-C5-1 (`SessionReplyTicks.shows` holds the
// options' words), N-C8-1 (a log that isn't a regular file is refused), P-C8-1 (a private key over several lines is
// masked whole), P-C5-3 (a wrong form of the shown question is `bad-args`).

/// A host that is never there: the requests' checks that come before any session is looked up.
private struct NoHost: HostDialer {
    struct Gone: Error {}
    func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw Gone() }
}

private func requests(_ scratch: Scratch) -> Requests {
    let link = HostLink(dialer: NoHost(), root: scratch.url("link"), queue: DispatchQueue(label: "review-engine"))
    let root = scratch.url("node-root")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Requests(link: link, sessions: nil, rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a review's"),
                    root: root, hostSocket: "/nonexistent", commit: "test", hostPID: 1)
}

private func answer(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value],
                    _ call: @escaping (Requests, NodeWire.Request, @escaping (NodeWire.Reply) -> Void) -> Void) async -> NodeWire.Reply? {
    let reply = Locked<NodeWire.Reply?>(nil)
    let request = NodeWire.Request(id: "r1", kind: kind, args: args)
    requests.queue.async { call(requests, request) { answer in reply.mutate { $0 = answer } } }
    _ = await eventually(timeout: 60) { reply.value != nil }
    return reply.value
}

/// Claude's multi-select as SessionReplyTicksTests models it, with labels and question a test may change mid-answer.
private struct Multi {
    var question = "Which toppings?"
    var labels = ["Cream", "Nuts", "Sprinkles"]
    var checked: Set<Int> = [0]
    var focus = 4
    var typed = ""
    var submitted: [String]?
    var rows: Int { labels.count + 1 }
    var screen: [String] {
        var lines = ["←   ☐ Toppings  ✔ Submit   →", "", question, ""]
        for index in 0..<rows {
            let label = index == labels.count ? (typed.isEmpty ? "Type something" : typed) : labels[index]
            lines.append((focus == index ? "❯ " : "  ") + "\(index + 1). [\(checked.contains(index) ? "✔" : " ")] \(label)")
        }
        lines += [(focus == rows ? "❯ " : "  ") + "   Submit", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
        return lines
    }
    var menu: ScreenMenu? { ScreenMenu.parse(screen) }
    mutating func take(_ bytes: [UInt8]) {
        switch bytes {
        case [27, 91, 65]: focus = max(0, focus - 1)
        case [27, 91, 66]: focus = min(rows, focus + 1)
        case [13]:
            if focus == rows { submitted = checked.sorted().map { $0 == labels.count ? typed : labels[$0] } } else { checked.formSymmetricDifference([focus]) }
        default:
            guard focus == labels.count else { return }
            typed += String(decoding: bytes, as: UTF8.self)
            if !typed.isEmpty { checked.insert(focus) }
        }
    }
    /// The plan's keys as the node's gate lets them in; `meanwhile(step, &self)` runs before each key.
    mutating func run(_ plan: SessionReplyTicks.Plan, from menu: ScreenMenu, meanwhile: (Int, inout Multi) -> Void = { _, _ in }) -> Bool {
        for (index, write) in plan.writes.enumerated() {
            meanwhile(index, &self)
            if index == 0, self.menu != menu { return false }
            if let check = plan.checks[index], !SessionReplyTicks.shows(self.menu, check, of: menu) { return false }
            take(write.bytes)
        }
        return true
    }
}

struct ReviewKindsFindingTests {
    private let scratch = Scratch()

    /// N-C8-1: a FIFO in the session log's place (any process of the uid can make one in the node's folder) holds the
    /// read forever: `open` without O_NONBLOCK waits for a writer, a global queue's thread with it, each Refresh another.
    /// Asked: the read returns (refused: not a regular file) without a writer.
    @Test func aFifoInTheLogsPlaceDoesNotHoldTheRead() throws {
        let folder = try scratch.shortFolder("fifo")
        let fifo = folder.appendingPathComponent("host.log").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Result<[String], NodeFacts.Failure>?>(nil)
        Thread.detachNewThread {
            result.mutate { $0 = NodeLogs.tail(fifo, lines: 10) }
            done.signal()
        }
        // A bound on the hang only: a read that doesn't block returns in microseconds.
        let returned = done.wait(timeout: .now() + 20) == .success
        if !returned {
            // Let the stuck read go: a writer opens and closes, the reader sees its end.
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 20)
        }
        #expect(returned, "the read waited for a writer on a FIFO")
    }

    /// P-C8-1 (pre-existing in the command line, now reaching a page): each line is masked alone, so a private key
    /// written over several lines leaves its body: only its BEGIN line is masked. Asked: no key body leaves.
    @Test func aKeyOverSeveralLinesIsMaskedWhole() throws {
        let body = (0..<4).map { index in String(repeating: "MIIEv\(index)QIBADANBgkqhkiG9w0BAQEFAASC", count: 2).prefix(64) }.map(String.init)
        let key = ["-----BEGIN " + "PRIVATE KEY-----"] + body + ["-----END " + "PRIVATE KEY-----"]
        let folder = scratch.url("pem")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("host.log")
        try (["a hook printed:"] + key + ["done"]).joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        // Masked whole, the text hides it.
        #expect(!Redaction.secrets(in: key.joined(separator: "\n")).contains(body[1]))
        let read = try NodeLogs.read(.init(lines: 50, sessions: true), root: folder, place: .file("/nowhere"), scratch: true) { _, _, _ in nil }.get()
        let text = (read.lines ?? []).joined(separator: "\n")
        #expect(!body.contains { text.contains($0) }, "the key's body left: \(read.lines ?? [])")
    }

    /// P-C5-3 (as `choice` before it): `question` and `options` are what bind a reply to the question the page showed,
    /// and a wrong form of either is taken as none given (no check), not `bad-args`: no typed-args check runs before
    /// `replySession`. Asked: a wrong form refused before any session is looked up. (Here no host: `gone` shows it went on.)
    @Test func aWrongFormOfTheShownQuestionIsRefused() async throws {
        let requests = requests(scratch)
        for wrong: [String: NodeWire.Value] in [["question": .int(5)], ["options": .string("Cream, Nuts")], ["options": .object([:])]] {
            var args: [String: NodeWire.Value] = ["session": .string(UUID().uuidString), "choices": .array([.int(1)])]
            args.merge(wrong) { $1 }
            let reply = try #require(await answer(requests, "session.reply", args) { $0.replySession($1, reply: $2) })
            #expect(reply.error?.code == NodeWire.Code.badArgs.rawValue, "\(wrong): \(reply.error?.code ?? "ok")")
        }
    }

    /// N-C5-1: the checks between keys compare the question by its words, tabs and count of options (`sameQuestion`),
    /// not the options' words: options replaced by others of the same count while the keys go in are ticked and
    /// submitted, and the reply names the old options' words. Asked: the checks hold the options as read.
    @Test func optionsReplacedUnderTheKeysAreNotSubmitted() throws {
        var model = Multi()
        let menu = try #require(model.menu)
        let plan = try SessionReplyTicks.plan(menu, choices: [2, 3], text: nil).get()
        let ran = model.run(plan, from: menu) { step, model in if step == 1 { model.labels = ["Delete all", "Push --force", "Keep"] } }
        #expect(!ran || model.submitted == nil, "submitted \(model.submitted ?? []) while the reply says \(plan.words)")
    }
}

/// N-C8-3, closed with the four: `logs` reads under way are capped per node (`NodeLogs.readsInFlight`), one past them
/// refused with nothing read; each read's end frees its place.
struct LogsReadsInFlightTests {
    private let scratch = Scratch()

    @Test func onePastTheReadsInFlightIsRefused() async throws {
        let requests = requests(scratch)
        // The journal's stand-in for this scratch node: each read holds until `go` is there (or its 10 s run ends).
        let test = requests.root.appendingPathComponent("v2/test")
        try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
        let go = test.appendingPathComponent("go").path
        let standIn = test.appendingPathComponent("journalctl")
        try "#!/bin/sh\nwhile [ ! -e '\(go)' ]; do /bin/sleep 0.05; done\necho '{\"MESSAGE\":\"read\",\"SYSLOG_IDENTIFIER\":\"vibeswitcher-node\"}'\n"
            .write(to: standIn, atomically: true, encoding: .utf8)
        #expect(chmod(standIn.path, 0o700) == 0)
        defer { FileManager.default.createFile(atPath: go, contents: Data()) }
        let replies = Locked<[String: NodeWire.Reply]>([:])
        let count = NodeLogs.readsInFlight + 1
        // In order on the requests' queue: the first `readsInFlight` take their places before the last is asked.
        for index in 0..<count {
            let request = NodeWire.Request(id: "r\(index)", kind: "logs", args: [:])
            requests.queue.async { requests.logs(request) { reply in replies.mutate { $0[request.id] = reply } } }
        }
        _ = await eventually(timeout: 60) { replies.value["r\(count - 1)"] != nil }
        let past = try #require(replies.value["r\(count - 1)"])
        #expect(past.error?.code == NodeWire.Code.refused.rawValue && past.error?.message.contains("under way") == true, "\(past)")
        #expect(replies.value.count == 1, "a read answered before its stand-in was let go: \(replies.value.keys.sorted())")
        FileManager.default.createFile(atPath: go, contents: Data())
        _ = await eventually(timeout: 60) { replies.value.count == count }
        for index in 0..<(count - 1) {
            #expect(replies.value["r\(index)"]?.error == nil, "r\(index): \(String(describing: replies.value["r\(index)"]))")
        }
        // Their places are free again: the next read is taken.
        let next = NodeWire.Request(id: "next", kind: "logs", args: [:])
        requests.queue.async { requests.logs(next) { reply in replies.mutate { $0[next.id] = reply } } }
        _ = await eventually(timeout: 60) { replies.value["next"] != nil }
        #expect(replies.value["next"]?.error == nil, "\(String(describing: replies.value["next"]))")
    }
}
