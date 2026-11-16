import Foundation
import Testing
@testable import VibeCore

/// The lead's tool server's post of a question to the node's server (`NodeQuestionPost`, the engine plan's EN-D10):
/// nothing without a server socket, nothing on the Mac, and on Linux one line carrying the question and the host's
/// `.lead` seal over the post's digest.
struct NodeQuestionPostTests {
    private let scratch = Scratch()

    /// A vault that counts what it's asked and seals with a fixed word.
    private final class Counting: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [LeadVault.Request] = []
        var requests: [LeadVault.Request] { lock.withLock { asked } }
        func vault(_ folder: URL) -> LeadVault {
            LeadVault(folder: folder) { [self] request in
                lock.withLock { asked.append(request) }
                return .seal("sealed")
            }
        }
    }

    /// A listener at `path` that records each line it reads and answers each request `ok`, until it's stopped. Its
    /// thread closes the socket as it ends, never `stop`: closed under a thread still about to poll it (one started
    /// late on a loaded machine), its number went to the next test's listener, whose post the old thread then took,
    /// answered and recorded in the wrong test (linux CI 43840361847: the post answered, `listener.lines` `[]`).
    private final class Listener: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var got: [String] = []
        private var stopped = false
        var lines: [String] { lock.withLock { got } }

        init(path: String) throws {
            fd = try UnixSocket.listen(path: path)
            let thread = Thread { [self] in serve() }
            thread.start()
        }

        private func serve() {
            defer { Sys.close(fd) }
            while !lock.withLock({ stopped }) {
                // Looks every 50 ms whether it's been stopped (a shut-down listening socket may not wake a poll).
                var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let woke = poll(&watched, 1, 50)
                if woke == 0 || (woke < 0 && errno == EINTR) { continue }
                guard woke > 0, watched.revents & Int16(POLLIN) != 0 else { return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { if errno == EAGAIN || errno == EINTR { continue } else { return } }
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                _ = "{\"kind\":\"hello\",\"v\":1}\n".withCString { Sys.write(client, $0, strlen($0)) }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var pending = Data()
                while true {
                    let count = Sys.read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        lock.withLock { got.append(line) }
                        let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? String ?? ""
                        _ = "{\"v\":1,\"re\":\"\(id)\",\"ok\":true,\"result\":{}}\n".withCString { Sys.write(client, $0, strlen($0)) }
                    }
                }
                Sys.close(client)
            }
        }

        /// Ends its thread, which closes the socket.
        func stop() {
            lock.withLock { stopped = true }
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    private var question: LeadQuestion { LeadQuestion(text: "Blue or red?", options: ["Blue", "Red"]) }

    /// A folder short enough for a socket's path (it goes with the test's `Scratch`).
    private func shortFolder() throws -> URL {
        var folder = scratch.url("nqp")
        if folder.path.utf8.count + 8 >= 100 {
            folder = scratch.adopt(URL(fileURLWithPath: "\(Platform.Files.sharedTemporaryRoot)/vs-nqp-\(UUID().uuidString.prefix(8))"))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func withNoServerSocketNothingIsSentAndNothingWaits() {
        let counting = Counting()
        let socket = scratch.url("none").appendingPathComponent("server.sock").path
        #expect(!NodeQuestionPost.post(question, op: .post, root: "/r", vault: counting.vault(scratch.url("vault")), socket: socket, enabled: true))
        // Nothing waited on: not even the host was asked for a seal (which the tool's caller would wait on).
        #expect(counting.requests.isEmpty)
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the post's wire")) func aPostCarriesTheQuestionAndTheLeadsSeal() throws {
        let folder = try shortFolder()
        let socket = folder.appendingPathComponent("s.sock").path
        let listener = try Listener(path: socket)
        defer { listener.stop() }
        let counting = Counting()
        let question = question
        #expect(NodeQuestionPost.post(question, op: .withdraw, root: "/r/proj", vault: counting.vault(folder), socket: socket, limit: 5))
        let line = try #require(listener.lines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "question.withdraw")
        let args = try #require(object["args"] as? [String: Any])
        #expect(args["root"] as? String == "/r/proj")
        let text = try #require(args["question"] as? String)
        #expect(try JSONDecoder().decode(LeadQuestion.self, from: Data(text.utf8)) == question)
        let seal = try #require(args["seal"] as? [String: Any])
        #expect(seal["seal"] as? String == "sealed" && seal["name"] as? String == "lead of proj")
        // What the vault sealed: a `.lead` line for no agent whose text is the post's digest.
        guard case .seal(let message)? = counting.requests.first else { Issue.record("no seal asked: \(counting.requests)"); return }
        #expect(message.from == .lead("lead of proj") && message.agentPid == 0 && message.id == seal["id"] as? String)
        #expect(message.text == "question post " + NodeQuestionPost.digest(op: .withdraw, root: "/r/proj", question: Data(text.utf8)))
        #expect(String(message.at) == seal["at"] as? String)
    }

    /// The engine sweep's review: a revision's post carries what `revise_question` was given (the text, the options,
    /// nil when unchanged, and the note), never the board's question, which any session can write; posting one as a
    /// question sends nothing.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux: the post's wire")) func aRevisionCarriesWhatTheLeadGaveAlone() throws {
        let folder = try shortFolder()
        let socket = folder.appendingPathComponent("s.sock").path
        let listener = try Listener(path: socket)
        defer { listener.stop() }
        let counting = Counting()
        #expect(!NodeQuestionPost.post(question, op: .revise, root: "/r/proj", vault: counting.vault(folder), socket: socket, limit: 5))
        #expect(counting.requests.isEmpty)
        #expect(NodeQuestionPost.revise("q1", text: "Blue, red or green?", options: nil, note: "green too", root: "/r/proj",
                                        vault: counting.vault(folder), socket: socket, limit: 5))
        let line = try #require(listener.lines.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "question.revise")
        let text = try #require((object["args"] as? [String: Any])?["question"] as? String)
        #expect(try JSONDecoder().decode(NodeQuestionPost.Revision.self, from: Data(text.utf8))
                == NodeQuestionPost.Revision(id: "q1", text: "Blue, red or green?", options: nil, note: "green too"))
        guard case .seal(let message)? = counting.requests.first else { Issue.record("no seal asked: \(counting.requests)"); return }
        #expect(message.text == "question post " + NodeQuestionPost.digest(op: .revise, root: "/r/proj", question: Data(text.utf8)))
    }

    @Test func switchedOffItPostsNothing() throws {
        let folder = try shortFolder()
        let socket = folder.appendingPathComponent("s.sock").path
        let listener = try Listener(path: socket)
        defer { listener.stop() }
        let counting = Counting()
        #expect(!NodeQuestionPost.post(question, op: .post, root: "/r", vault: counting.vault(folder), socket: socket, enabled: false))
        #expect(counting.requests.isEmpty)
        #expect(listener.lines.isEmpty)
    }

    /// The Mac's tool server, with a listener at the path: nothing arrives (`enabled` is false there by default).
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's tool server")) func theMacsToolServerPostsNoQuestion() throws {
        let folder = try shortFolder()
        let socket = folder.appendingPathComponent("s.sock").path
        let listener = try Listener(path: socket)
        defer { listener.stop() }
        let counting = Counting()
        #expect(!NodeQuestionPost.post(question, op: .post, root: "/r", vault: counting.vault(folder), socket: socket))
        #expect(counting.requests.isEmpty)
        #expect(listener.lines.isEmpty)
    }
}
