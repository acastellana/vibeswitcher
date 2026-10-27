import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The project leads on the phone: `/api/state`'s `leads` and `/api/lead`'s page carry what the phone shows (titles,
/// states, counts, the lead's own words; no paths), and an answer to a lead's question from the phone goes through the
/// Mac's answer path (`LeadController.answer`, wired by `PhoneLeads.wire` as the app wires it), recorded as yours from
/// the phone, for the paired phone only, once, and only while the question is open.
///
/// Phone Access is served in memory only (`serveForTests`); the lead's board is a scratch folder's; no lead runs, so
/// what the lead would be told is held by the controller.
@MainActor
@Suite(.serialized)
struct PhoneLeadsTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"
    private let scratch = Scratch()

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    struct World {
        let root: String
        let access: PhoneAccess
        let token: String
        let controller: LeadController
        /// The board the phone last read (the leads' list as the Mac last read it): set by `read()`.
        let shown: Box<LeadBoard>
        var store: BoardStore { BoardStore(root: root) }
        func read() { shown.value = store.load() }
    }

    private func world() throws -> World {
        AppStatus.enabled = false
        let base = scratch.url("phone-leads-\(UUID().uuidString.prefix(6))")
        let root = base.appendingPathComponent("shop").resolvingSymlinksInPath().path
        let stateDir = base.appendingPathComponent("state"), inbox = base.appendingPathComponent("inbox"), home = base.appendingPathComponent("home")
        for dir in [root, stateDir.path, inbox.path, home.path] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: "\(shortScratchRoot)/vsh-pl-\(UUID().uuidString.prefix(8)).sock")
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault.Book().vault(folder: base.appendingPathComponent("vault"), as: { .app })
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: home.path) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        let access = PhoneAccess(store: store)
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        access.screenLocked = { false }
        access.inputAllowed = true
        // As the app wires it; only the list of leads is the test's (no lead session runs here for the controller to list).
        PhoneLeads.wire(access, controller: controller, model: WindowModel())
        let shown = Box(LeadBoard())
        access.leads = { [PhoneLeads.Lead(root: root, board: shown.value, summary: "team: 1 working · 1 waits on lead",
                                          rows: TeamRows.rows(shown.value, seen: [:]))] }
        access.startPairing()
        let code = try #require(access.pairing?.code)
        let paired = Box<[String: Any]>([:])
        access.handleForTests(try request("POST", "/api/pair", body: #"{"code":"\#(code)","name":"Lead phone"}"#)) {
            paired.value = ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]) ?? [:]
        }
        let token = try #require(paired.value["token"] as? String)
        return World(root: root, access: access, token: token, controller: controller, shown: shown)
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "") throws -> HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\n"
            + "Tailscale-User-Login: \(Self.login)\r\nX-Forwarded-For: 100.64.0.7\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let parsed) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        return parsed
    }

    /// Sends a request; the box gets its answer (status, JSON) once it comes.
    private func send(_ world: World, _ method: String, _ path: String, token: String?, body: String = "") throws -> Box<(Int, [String: Any])?> {
        let answer = Box<(Int, [String: Any])?>(nil)
        world.access.handleForTests(try request(method, path, token: token, body: body)) {
            answer.value = ($0.status, ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]) ?? [:])
        }
        return answer
    }

    private func call(_ world: World, _ method: String, _ path: String, token: String?, body: String = "") async throws -> (Int, [String: Any]) {
        let answer = try send(world, method, path, token: token, body: body)
        #expect(await until { answer.value != nil })
        return try #require(answer.value)
    }

    private func answerBody(_ world: World, _ question: LeadQuestion, _ text: String, version: Int? = nil) -> String {
        let object: [String: Any] = ["lead": PhoneLeads.id(root: world.root), "question": question.id, "version": version ?? question.version, "text": text]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func ask(_ world: World, _ text: String = "Ship to the testers first?") throws -> LeadQuestion {
        let question = try world.store.update { board in
            board.ask(text, options: ["Testers first", "Everyone"], priority: .important, whyNow: nil)
        }
        world.read()
        return question
    }

    private func onBoard(_ world: World, _ question: LeadQuestion) -> LeadQuestion? {
        world.store.load().questions.first { $0.id == question.id }
    }

    @Test func anAnswerFromAnUnpairedOrWrongTokenRequestIsRefused() async throws {
        let world = try world()
        let question = try ask(world)
        let body = answerBody(world, question, "Testers first")
        let unpaired = try await call(world, "POST", "/api/lead/answer", token: nil, body: body)
        let wrong = try await call(world, "POST", "/api/lead/answer", token: "not-the-phones-token", body: body)
        #expect(unpaired.0 == 401)
        #expect(wrong.0 == 401)
        // The lead's page and its questions are the paired phone's only, too.
        #expect(try await call(world, "GET", "/api/lead?lead=\(PhoneLeads.id(root: world.root))", token: "not-the-phones-token").0 == 401)
        #expect(try await call(world, "GET", "/api/state", token: nil).0 == 401)
        #expect(onBoard(world, question)?.answer == nil)
    }

    @Test func aValidAnswerLandsOnceAsYoursFromThePhoneAndADoubleTapAnswersOnce() async throws {
        let world = try world()
        let question = try ask(world)
        let body = answerBody(world, question, "Testers first")
        // Two taps before either is answered: both reach the Mac with the question open as the phone last read it.
        let first = try send(world, "POST", "/api/lead/answer", token: world.token, body: body)
        let second = try send(world, "POST", "/api/lead/answer", token: world.token, body: body)
        #expect(await until { first.value != nil && second.value != nil })
        let statuses = [first.value?.0, second.value?.0].compactMap { $0 }.sorted()
        #expect(statuses == [200, 409])
        let landed = try #require(onBoard(world, question))
        #expect(landed.answer == "Testers first")
        #expect(landed.answeredFrom == .phone)
        #expect(landed.answeredVersion == 1)
        #expect(landed.state == .answered)
        // The refused tap says it isn't open, with the question as it is now.
        let refused = try #require([first.value, second.value].compactMap { $0 }.first { $0.0 == 409 })
        #expect((refused.1["question"] as? [String: Any])?["state"] as? String == "answered")
        // Recorded once: the Mac's card is not told of a second answer.
        #expect(world.controller.answerNotices[question.id] == "Already answered: Testers first. Your new answer wasn't sent.")
    }

    @Test func anAnswerIsTiedToTheVersionThePhoneShowed() async throws {
        let world = try world()
        let question = try ask(world)
        _ = try world.store.update { board in try board.revise(question.id, text: "Ship to the testers on Thursday?", options: nil, note: "A date now") }
        let (status, reply) = try await call(world, "POST", "/api/lead/answer", token: world.token, body: answerBody(world, question, "Everyone", version: 1))
        #expect(status == 200)
        #expect(reply["saw"] as? Int == 1)
        #expect(onBoard(world, question)?.answeredVersion == 1)
    }

    @Test func aWithdrawnOrAnsweredQuestionCantBeAnsweredFromThePhone() async throws {
        let world = try world()
        // Withdrawn, as the phone last read it.
        let withdrawn = try ask(world)
        _ = try world.store.update { board in try board.withdraw(withdrawn.id, reason: "Not needed") }
        world.read()
        let refused = try await call(world, "POST", "/api/lead/answer", token: world.token, body: answerBody(world, withdrawn, "Everyone"))
        #expect(refused.0 == 409)
        #expect((refused.1["question"] as? [String: Any])?["state"] as? String == "withdrawn")
        #expect(onBoard(world, withdrawn)?.answer == nil)

        // Withdrawn after the phone's last read: the board's own check refuses it (no answer kept as a note).
        let late = try ask(world, "Merge the docs task now?")
        _ = try world.store.update { board in try board.withdraw(late.id, reason: "Merged anyway") }
        let lateReply = try await call(world, "POST", "/api/lead/answer", token: world.token, body: answerBody(world, late, "Testers first"))
        #expect(lateReply.0 == 409)
        #expect(onBoard(world, late)?.answer == nil)

        // Answered on the Mac meanwhile.
        let answered = try ask(world, "Keep the old export?")
        _ = try world.store.update { board in board.answer(answered.id, with: "Everyone", saw: 1) }
        let again = try await call(world, "POST", "/api/lead/answer", token: world.token, body: answerBody(world, answered, "Testers first"))
        #expect(again.0 == 409)
        #expect(onBoard(world, answered)?.answer == "Everyone")
        #expect(onBoard(world, answered)?.answeredFrom == .mac)
    }

    @Test func answeringIsOffWhileRepliesFromThePhoneAreOff() async throws {
        let world = try world()
        let question = try ask(world)
        world.access.inputAllowed = false
        let (status, _) = try await call(world, "POST", "/api/lead/answer", token: world.token, body: answerBody(world, question, "Everyone"))
        #expect(status == 403)
        #expect(onBoard(world, question)?.answer == nil)
    }

    @Test func theStateAndTheLeadsPageCarryWhatThePhoneShowsAndNoPaths() async throws {
        let world = try world()
        let now = Date().timeIntervalSince1970
        let contract = LeadContract(goal: "g", acceptance: [], boundaries: [], context: "TRANSCRIPT-NOT-SENT")
        _ = try world.store.update { board in
            var working = LeadTask(slug: "ledger", title: "Ledger reconciles", contract: contract, status: .running)
            working.checkpoints = [LeadCheckpoint(text: "Tests written", at: now - 60)]
            var audit = LeadTask(slug: "cleanup", title: "Clean up folders", contract: contract, status: .review)
            audit.review = .audit
            audit.riskRaised = LeadRiskRaise(reason: "it deletes files", commit: "abc1234", byModel: false)
            var reverted = LeadTask(slug: "paste", title: "Paste images", contract: contract, status: .reverted)
            reverted.merged = LeadMergeRecord(commit: "abc9", tested: true, audited: false, at: now - 600)
            reverted.merged?.revertReason = "Froze on a large paste"
            var merged = LeadTask(slug: "copy", title: "Landing copy", contract: contract, status: .done)
            merged.merged = LeadMergeRecord(commit: "abc8", tested: true, audited: false, at: now - 900)
            let blocked = LeadTask(slug: "badge", title: "Badge counts", contract: contract, status: .blocked)
            board.tasks = [working, audit, reverted, merged, blocked]
            _ = board.ask("Keep a PNG fallback?", options: ["WebP only", "Keep a PNG fallback"], priority: .whenever, whyNow: "Images next",
                          proposal: "Keep a PNG fallback", decideIn: 10)
            let revised = board.ask("Launch to everyone?", options: ["Yes", "No"], priority: .blocking, whyNow: nil)
            _ = try board.revise(revised.id, text: "Launch to the testers on Thursday?", options: ["Thursday", "Wait"], note: "Testers first")
            let gone = board.ask("Re-plan the sidebar?", options: [], priority: nil, whyNow: nil)
            _ = try board.withdraw(gone.id, reason: "Not needed")
            var mark = LeadAllDone(at: now - 30, since: now - 3_600, tasks: [.init(slug: "copy", title: "Landing copy", outcome: .merged)])
            mark.summary = .init(headline: "The landing page is ready", bullets: ["Copy merged"], byModel: true)
            board.allDone = [mark]
            board.updates = [LeadUpdate(title: "Board done", body: "Checked in the sandbox.")]
            board.refreshScores(now: now)
        }
        world.read()

        let (status, state) = try await call(world, "GET", "/api/state", token: world.token)
        #expect(status == 200)
        let leads = try #require(state["leads"] as? [[String: Any]])
        let lead = try #require(leads.first)
        #expect(Set(lead.keys) == ["id", "project", "questions", "open", "blocking", "allDone", "summary"])
        #expect(lead["project"] as? String == "shop")
        #expect(lead["summary"] as? String == "team: 1 working · 1 waits on lead")
        #expect(lead["open"] as? Int == 2)
        #expect(lead["blocking"] as? Int == 1)
        let questions = try #require(lead["questions"] as? [[String: Any]])
        // The Mac's stack: the open ones, most important first, then the one withdrawn lately.
        #expect(questions.map { $0["state"] as? String } == ["open", "open", "withdrawn"])
        let blocking = questions[0], timed = questions[1], withdrawn = questions[2]
        #expect(Set(blocking.keys) == ["id", "version", "text", "options", "priority", "state", "askedAt", "revised"])
        #expect(blocking["priority"] as? String == "blocking")
        #expect(blocking["version"] as? Int == 2)
        let revised = try #require(blocking["revised"] as? [String: Any])
        #expect(revised["note"] as? String == "Testers first")
        #expect((revised["earlier"] as? [[String: Any]])?.first?["text"] as? String == "Launch to everyone?")
        #expect(Set(timed.keys) == ["id", "version", "text", "options", "priority", "state", "askedAt", "whyNow", "proposal", "decideIn", "decideBy", "timeLeft"])
        #expect(timed["timeLeft"] as? String == "10 min")
        #expect(timed["proposal"] as? String == "Keep a PNG fallback")
        #expect(withdrawn["withdrawReason"] as? String == "Not needed")

        let (pageStatus, page) = try await call(world, "GET", "/api/lead?lead=\(PhoneLeads.id(root: world.root))", token: world.token)
        #expect(pageStatus == 200)
        #expect(Set(page.keys) == ["id", "project", "summary", "allDone", "updates", "tasks", "finished", "scorecard"])
        let card = try #require(page["allDone"] as? [String: Any])
        #expect(card["headline"] as? String == "The landing page is ready")
        #expect(card["count"] as? String == "1 task · 1 merged")
        #expect((page["updates"] as? [[String: Any]])?.first?["title"] as? String == "Board done")
        let tasks = try #require(page["tasks"] as? [[String: Any]])
        #expect(Set(tasks.flatMap(\.keys)).isSubset(of: ["title", "state", "stateText", "group", "mark", "line"]))
        func task(_ title: String) -> [String: Any]? { tasks.first { $0["title"] as? String == title } }
        #expect(task("Ledger reconciles")?["state"] as? String == "Working")
        #expect(task("Ledger reconciles")?["line"] as? String == "Tests written")
        #expect(task("Clean up folders")?["state"] as? String == "Needs audit")
        #expect(task("Clean up folders")?["line"] as? String == "Audited: it deletes files")
        #expect(task("Paste images")?["state"] as? String == "Reverted")
        #expect(task("Paste images")?["line"] as? String == "Froze on a large paste")
        #expect(task("Landing copy")?["state"] as? String == "Merged")
        #expect(task("Badge counts")?["state"] as? String == "Blocked")
        // The Team tab's scorecard line (the reverted task counts as merged there).
        #expect((page["scorecard"] as? String)?.hasPrefix("Scorecard (2 merged") == true)
        #expect((page["finished"] as? [String: Any])?["title"] as? String == "Merged (1) · Reverted (1)")

        // No path, and nothing of a task's contract (its context, what a transcript would hold), anywhere.
        for object in [state, page] {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            #expect(!text.contains(world.root))
            #expect(!text.contains("TRANSCRIPT-NOT-SENT"))
        }
        // An unknown lead: 404.
        #expect(try await call(world, "GET", "/api/lead?lead=nope", token: world.token).0 == 404)
    }
}
