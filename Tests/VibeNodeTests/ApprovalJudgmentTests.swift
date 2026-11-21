import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The Mac's rule's decision on the server (`Requests.approvalJudgment`) and its dialog (`approvalCard`), on both systems
/// and with no host: a fake person (`ApprovalVoiceTests.Person`), never a dialog. What runs on the Mac's CI runner of
/// the Touch ID path; the whole request on a scratch host is `ApprovalRequestsTests` (Linux).
struct ApprovalJudgmentTests {
    private let scratch = Scratch()

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    static let pid: pid_t = 9_000_901
    static let commandLine = Data(repeating: 0xc1, count: 20)
    static let user = PeerFacts(pid: pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: pid, startTicks: 5)], terminal: .named("ttytest-mac"),
                                sessionMarker: nil, underRunner: false)

    /// A `Requests` on the Mac's rule with `person`, over a link with no host, with an engine to hold cards.
    private func requests(_ person: any ApprovalVoice.Authenticator, commandLinePeer: Bool = true, hardened: Bool = true,
                          welcomed: Bool = true) -> Requests {
        let queue = DispatchQueue(label: "approval-judgment")
        let root = scratch.url("root-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = HostLink(dialer: NoHost(), root: root, queue: queue)
        let requests = Requests(link: link, sessions: nil, rule: VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays),
                                root: root, hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 1)
        requests.engine = LeadEngine(root: root, nodeRoot: nil, link: link, clock: nil)
        requests.approval = ApprovalVoice(authenticator: person, commandLine: Self.commandLine, runs: { token, code in
            commandLinePeer && code == Self.commandLine && token.pid == Self.pid
        }, hardened: { _ in hardened })
        requests.approvalLinkWelcomed = { welcomed }
        return requests
    }

    private func judge(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value] = [:],
                       action: String? = UUID().uuidString.lowercased(), facts: PeerFacts = user) async -> (done: Bool, refused: NodeWire.Reply?) {
        let result = Locked<(Bool, NodeWire.Reply?)>((false, nil))
        let request = NodeWire.Request(id: UUID().uuidString, kind: kind, args: args, action: action)
        let token = ApprovalVoiceTests.token(Self.pid)
        requests.queue.async { requests.approvalJudgment(request, from: facts, token: token) { result.value = (true, $0) } }
        _ = await eventually(timeout: 60) { result.value.0 }
        return result.value
    }

    /// A card put into the engine's store.
    private func put(_ card: CardStore.Card, _ requests: Requests) {
        requests.queue.sync { requests.engine?.cards.put(card) }
    }

    /// The dialog's text for a request of `kind` (its word from `action`).
    private func dialog(_ requests: Requests, _ kind: String, _ args: [String: NodeWire.Value], action: String) -> Result<String, Requests.ApprovalTextRefusal> {
        requests.queue.sync { requests.approvalCard(NodeWire.Request(id: "d", kind: kind, args: args, action: action)) }
    }

    @Test func aReadPassesWithoutAskingAndAStateChangeOnlyOnceApprovedWithItsWord() async {
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(person)
        let read = await judge(requests, "status", action: nil)
        #expect(read.done && read.refused == nil && person.asked.isEmpty)
        let action = UUID().uuidString.lowercased()
        let set = await judge(requests, "set", ["key": .string("lead_mail"), "value": .string("off")], action: action)
        #expect(set.done && set.refused == nil, "\(String(describing: set.refused))")
        #expect(person.asked == ["change a VibeSwitcher setting: \(NodeIds.code(action: action)) · set lead_mail to “off”; for the whole node"], "\(person.asked)")
    }

    @Test func declinedUnavailableOrNotTheCommandLineIsRefused() async {
        for answer: Platform.Approval.Outcome in [.declined("cancelled at the Mac"), .unavailable("over ssh")] {
            let refused = await judge(requests(ApprovalVoiceTests.Person(answer)), "session.end", ["session": .string("local:abcd")]).refused
            #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
        }
        let person = ApprovalVoiceTests.Person(.approved)
        let stranger = await judge(requests(person, commandLinePeer: false), "session.end", ["session": .string("local:abcd")]).refused
        #expect(stranger?.error?.message.contains("isn't the installed command line") == true)
        let soft = await judge(requests(person, hardened: false), "session.end", ["session": .string("local:abcd")]).refused
        #expect(soft?.error?.message.contains("Hardened Runtime") == true)
        // Under the session host: refused before asking (the guard rails).
        let underSession = PeerFacts(pid: Self.pid, uid: getuid(), cgroup: nil, ancestry: [.init(pid: Self.pid, startTicks: 5), .init(pid: 1, startTicks: 1)],
                                     terminal: .named("ttytest-mac"), sessionMarker: nil, underRunner: false)
        let hosted = await judge(requests(person), "session.end", ["session": .string("local:abcd")], facts: underSession).refused
        #expect(hosted?.error?.message.contains("session host") == true, "\(String(describing: hosted))")
        let noAction = await judge(requests(person), "session.end", ["session": .string("local:abcd")], action: nil).refused
        #expect(noAction?.error?.code == NodeWire.Code.badArgs.rawValue)
        // Before the host's welcome: `not-yet`, before any dialog (a retry would otherwise ask twice).
        let early = await judge(requests(person, welcomed: false), "session.end", ["session": .string("local:abcd")]).refused
        #expect(early?.error?.code == NodeWire.Code.notYet.rawValue, "\(String(describing: early))")
        // A card the server doesn't hold, or a field the kind doesn't take: refused before asking.
        let card = await judge(requests(person), "answer", ["card": .string("local:card:x"), "code": .string("ABCD"), "text": .string("yes")]).refused
        #expect(card != nil)
        let stray = await judge(requests(person), "session.end", ["session": .string("local:abcd"), "text": .string("; key value")]).refused
        #expect(stray?.error?.message.contains("carries a field it doesn't take") == true, "\(String(describing: stray))")
        #expect(person.asked.isEmpty)
    }

    /// One dialog at a time; the "busy" refusal never tells the person to answer the dialog on screen (it may be an
    /// agent's: its word tells); after a dialog that came to nothing, none for a moment.
    @Test func oneAtATimeTruthfullyAndQuietAfterADecline() async throws {
        let person = ApprovalRequestsTests.SlowPerson()
        let requests = requests(person)
        let first = Locked<(Bool, NodeWire.Reply?)>((false, nil))
        let request = NodeWire.Request(id: "first", kind: "session.end", args: ["session": .string("local:abcd")], action: UUID().uuidString.lowercased())
        let token = ApprovalVoiceTests.token(Self.pid)
        requests.queue.async { requests.approvalJudgment(request, from: Self.user, token: token) { first.value = (true, $0) } }
        try #require(await offPool { person.asking.wait(timeout: .now() + 60) == .success })
        let second = await judge(requests, "session.end", ["session": .string("local:efgh")])
        let busy = second.refused?.error?.message ?? ""
        #expect(busy.contains("wasn't asked") && busy.contains("if your terminal didn't print it, it isn't yours, cancel it"), "\(busy)")
        #expect(!busy.contains("answer"), "\(busy)")
        #expect(await judge(requests, "status", action: nil).refused == nil)
        person.release.signal()
        #expect(await eventually(timeout: 60) { first.value.0 && first.value.1 == nil })

        let declining = self.requests(ApprovalVoiceTests.Person(.declined("cancelled at the Mac")))
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        declining.queue.sync { declining.approvalNow = { now.value } }
        _ = await judge(declining, "session.end", ["session": .string("local:abcd")])
        let quiet = await judge(declining, "session.end", ["session": .string("local:abcd")]).refused
        #expect(quiet?.error?.message.contains("none is shown for 10 s") == true, "\(String(describing: quiet))")
        now.value = now.value.addingTimeInterval(Requests.approvalCooldown + 1)
        let later = await judge(declining, "session.end", ["session": .string("local:abcd")]).refused
        #expect(later?.error?.message.contains("declined at the Mac") == true, "\(String(describing: later))")
    }

    /// The caller's checks come before the dialog's one place: a stranger gets its own refusal, never "busy".
    @Test func theCallerChecksComeBeforeTheOnePlace() async throws {
        let person = ApprovalRequestsTests.SlowPerson()
        let requests = requests(person)
        requests.queue.sync {
            requests.approval?.runs = { token, code in code == Self.commandLine && token.pid == Self.pid }
        }
        let token = ApprovalVoiceTests.token(Self.pid)
        let first = Locked(false)
        let request = NodeWire.Request(id: "first", kind: "session.end", args: ["session": .string("local:abcd")], action: UUID().uuidString.lowercased())
        requests.queue.async { requests.approvalJudgment(request, from: Self.user, token: token) { _ in first.value = true } }
        try #require(await offPool { person.asking.wait(timeout: .now() + 60) == .success })
        let strangerFacts = PeerFacts(pid: 9_000_999, uid: getuid(), cgroup: nil, ancestry: [.init(pid: 9_000_999, startTicks: 5)], terminal: .named("ttytest-mac"),
                                      sessionMarker: nil, underRunner: false)
        let result = Locked<NodeWire.Reply?>(nil)
        let other = NodeWire.Request(id: "other", kind: "session.end", args: ["session": .string("local:abcd")], action: UUID().uuidString.lowercased())
        requests.queue.async { requests.approvalJudgment(other, from: strangerFacts, token: ApprovalVoiceTests.token(9_000_999)) { result.value = $0 } }
        #expect(await eventually(timeout: 60) { result.value != nil })
        #expect(result.value?.error?.message.contains("isn't the installed command line") == true, "\(String(describing: result.value))")
        person.release.signal()
        #expect(await eventually(timeout: 60) { first.value })
    }

    /// An action the server answered already is answered as it was, with no dialog.
    @Test func aReplayedActionIsAnsweredWithoutAsking() async {
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(person)
        let action = UUID().uuidString.lowercased()
        requests.queue.sync { requests.replies[action] = .init(re: "old", result: .object(["said": .string("done before")])) }
        let replay = await judge(requests, "session.end", ["session": .string("local:abcd")], action: action)
        #expect(replay.refused?.result?["said"]?.string == "done before" && replay.refused?.re != "old")
        #expect(person.asked.isEmpty)
    }

    // MARK: The dialog's text (the review's HIGH finding)

    /// A long lead question never hides the answer: the word and the answer first, the lead's words after, marked and cut.
    @Test func aLongLeadQuestionNeverHidesTheAnswer() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        var card = CardStore.Card(root: "/Users/u/shop", kind: .question)
        card.question = LeadQuestion(id: "q1", text: String(repeating: "Please read all of this carefully. ", count: 20) + "Ship it?", options: ["yes", "no"])
        put(card, requests)
        let action = UUID().uuidString.lowercased()
        let text = try dialog(requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string("no"), "version": .int(1)], action: action).get()
        #expect(text.hasPrefix("\(NodeIds.code(action: action)) · answer “no” in shop; the lead asks “Please read"), "\(text)")
        #expect(text.count <= Requests.approvalBudget && text.hasSuffix("…"), "\(text)")
        // An answer too long to show whole: nothing is asked.
        let long = dialog(requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string(String(repeating: "y", count: 200))], action: action)
        #expect((try? long.get()) == nil)
    }

    /// An approval's answer shows the commit and the tasks it approves, before the lead's words.
    @Test func anApprovalShowsTheCommitAndTasksFirst() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        var card = CardStore.Card(root: "/Users/u/shop", kind: .approval)
        card.question = LeadQuestion(id: "q2", text: String(repeating: "x", count: 300), options: ["Approve", "Hold"])
        card.approval = .init(commit: String(repeating: "c", count: 40), tasks: ["login-fix"])
        put(card, requests)
        let action = UUID().uuidString.lowercased()
        let text = try dialog(requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string("Approve")], action: action).get()
        #expect(text.hasPrefix("\(NodeIds.code(action: action)) · answer “Approve” to merging cccccccccccc (task login-fix) in shop;"), "\(text)")
    }

    /// A shell card's Run names the command and the folder, under "run an agent's command in your login shell".
    @Test func aShellCardShowsItsCommandAndFolder() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        let request = ShellRequest(session: "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f", cwd: "/Users/u/shop", command: "make install", label: "", createdAt: Date())
        var card = CardStore.Card(root: "/Users/u/shop", kind: .shell)
        card.shell = .init(request: request, asker: "Claude")
        put(card, requests)
        let action = UUID().uuidString.lowercased()
        let text = try dialog(requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string("run")], action: action).get()
        #expect(text == "\(NodeIds.code(action: action)) · run an agent's command in your login shell: “make install” in shop (/Users/u/shop)", "\(text)")
        var long = CardStore.Card(root: "/Users/u/shop", kind: .shell)
        long.shell = .init(request: ShellRequest(session: request.session, cwd: "/Users/u/shop", command: String(repeating: "a", count: 150), label: "", createdAt: Date()),
                           asker: "Claude")
        put(long, requests)
        #expect((try? dialog(requests, "answer", ["card": .string(long.id), "code": .string(long.code), "text": .string("run")], action: action).get()) == nil)
    }

    /// A config card with many held items says how many, and how many guard rails changed, before any name.
    @Test func aManyItemConfigCardSaysHowMany() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        var card = CardStore.Card(root: "/Users/u/shop", kind: .configHeld)
        card.config = .init(items: (1...30).map { .init(name: "~/.claude/agents/agent-\($0).md") },
                            guarded: [.init(key: "sandbox", value: "off"), .init(key: "max_workers", value: "4", sinceAccept: "the same as at your last accept")])
        put(card, requests)
        let action = UUID().uuidString.lowercased()
        let text = try dialog(requests, "config.accept", ["card": .string(card.id), "code": .string(card.code)], action: action).get()
        #expect(text.hasPrefix("\(NodeIds.code(action: action)) · accept 30 held items and 1 guard rail changed in shop; held: ~/.claude/agents/agent-1.md"), "\(text)")
        #expect(text.count <= Requests.approvalBudget)
    }

    /// No argument key is shown, a value can't pass itself off as a field, and words sent are marked, whole.
    @Test func valuesAreMarkedWholeAndNoKeyIsShown() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        let action = UUID().uuidString.lowercased()
        let send = try dialog(requests, "send", ["session": .string("local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f"),
                                                  "text": .string("fine; session other\n\u{1B}[2Jok")], action: action).get()
        #expect(send.hasPrefix("\(NodeIds.code(action: action)) · type into session 3f6c2c1e: “fine; session other ⏎ "), "\(send)")
        #expect(!send.contains("\u{1B}") && !send.contains("text "), "\(send)")
        #expect(try dialog(requests, "stop", [:], action: action).get() == "\(NodeIds.code(action: action)) · stop the node, ending 0 live sessions")
    }

    // MARK: The second review (2026-11-21)

    /// The dialog reads a shell card's answer exactly as `answerShell` does: "run" with a line break around it is run,
    /// and shown as run; anything but run or decline is refused, never shown as a decline.
    @Test func aShellAnswerIsReadOnceForTheDialogAndTheRun() throws {
        #expect(ShellCards.answerWord("run\n") == "run" && ShellCards.answerWord(" Run\t\n") == "run" && ShellCards.answerWord("DECLINE") == "decline")
        #expect(ShellCards.answerWord("maybe") == nil && ShellCards.answerWord("ru n") == nil && ShellCards.answerWord("") == nil)
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        var card = CardStore.Card(root: "/Users/u/shop", kind: .shell)
        card.shell = .init(request: ShellRequest(session: "3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f", cwd: "/Users/u/shop", command: "make install",
                                                 label: "", createdAt: Date()), asker: "Claude")
        put(card, requests)
        let action = UUID().uuidString.lowercased()
        func text(_ answer: String) -> String? {
            try? dialog(requests, "answer", ["card": .string(card.id), "code": .string(card.code), "text": .string(answer)], action: action).get()
        }
        for answer in ["run\n", " Run\t\n", "RUN"] { #expect(text(answer)?.contains("run an agent's command in your login shell: “make install”") == true, "\(answer)") }
        #expect(text("decline\n")?.contains("decline an agent's shell request") == true)
        for answer in ["maybe", "yes", "run it"] { #expect(text(answer) == nil, "\(answer)") }
    }

    /// A decisive value is never cut: too long for the dialog, nothing is asked. Every field a preset edit changes is shown.
    @Test func decisiveValuesAreWholeOrNothingIsAsked() throws {
        let requests = requests(ApprovalVoiceTests.Person(.approved))
        let action = UUID().uuidString.lowercased()
        let long = String(repeating: "x", count: 180)
        #expect((try? dialog(requests, "set", ["key": .string("policy"), "value": .string(long)], action: action).get()) == nil)
        #expect((try? dialog(requests, "send", ["session": .string("local:abcd"), "text": .string(long)], action: action).get()) == nil)
        #expect((try? dialog(requests, "presets.edit", ["op": .string("add"), "name": .string("dev"), "args": .string(long)], action: action).get()) == nil)
        #expect((try? dialog(requests, "presets.edit", ["op": .string("add"), "name": .string("dev"), "env": .object(["TOKEN": .string(long)])], action: action).get()) == nil)
        let preset = try dialog(requests, "presets.edit", ["op": .string("edit"), "name": .string("dev"), "kind": .string("shell"), "rename": .string("web"),
                                                            "args": .string("npm run dev"), "env": .object(["PORT": .string("5173")]),
                                                            "unset": .array([.string("DEBUG")]), "default": .bool(true), "keepShell": .bool(true)], action: action).get()
        #expect(preset == "\(NodeIds.code(action: action)) · “edit” the launch preset “dev” (“shell”) renamed “web”: runs “npm run dev” with “PORT”=“5173” unsetting “DEBUG” as the folder's default, a shell kept after it", "\(preset)")
        let set = try dialog(requests, "set", ["key": .string("lead_mail"), "value": .string("off")], action: action).get()
        #expect(set.contains("set lead_mail to “off”"))
    }

    /// A replayed action id is answered only to a caller that passes the checks: an action id alone gets nothing.
    @Test func aReplayIsAnsweredOnlyToACallerThatPasses() async {
        let person = ApprovalVoiceTests.Person(.approved)
        let requests = requests(person, commandLinePeer: false)
        let action = UUID().uuidString.lowercased()
        requests.queue.sync { requests.replies[action] = .init(re: "old", result: .object(["said": .string("done before")])) }
        let replay = await judge(requests, "session.end", ["session": .string("local:abcd")], action: action)
        #expect(replay.refused?.result == nil && replay.refused?.error?.message.contains("isn't the installed command line") == true, "\(String(describing: replay.refused))")
        #expect(person.asked.isEmpty)
    }
}
