import Foundation
import Testing
@testable import VibeCore

/// tell_lead: one project's lead telling another's (see `LeadMail`). Two projects, alpha and beta, each with a lead
/// the app started in one vault (the book a session host holds, asked in process); beta's lead runs on a fake
/// terminal whose inbox is a scratch folder. No real session, inbox or defaults are touched.
struct LeadMailTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// The scratch inbox beta's lead's messages land in (its steer folder, as the hook reads it).
    let inbox: URL
    let alphaRoot: String
    let betaRoot: String
    let alpha = FakeRuntime()
    let beta = FakeRuntime()
    static let betaAgent = LeadAgent(pid: 5151, tty: "ttys051", session: "lead-beta")

    init() throws {
        vault = Self.newVault(in: temp)
        inbox = temp.url("inbox")
        let parent = temp.url("mail")
        alphaRoot = try Self.repo(parent.appendingPathComponent("alpha"))
        betaRoot = try Self.repo(parent.appendingPathComponent("beta"))
        alpha.me = LeadAgent(pid: 4242, tty: "ttys040", session: "lead-alpha")
        beta.me = Self.betaAgent
        // The host's census, as alpha's tool server reads it: beta's lead runs (its session isn't alpha's to list).
        alpha.unlisted = [LeadSessionInfo(id: "lead-beta", cwd: betaRoot, label: "Lead · beta", live: true, status: "idle", tty: "ttys051")]
        // A message reaches beta's lead as the hooks-only path does: posted to its terminal's inbox, sealed.
        alpha.onSteer = { [inbox] target, sender, text in
            guard case .agent(let agent) = target else { throw BoardError(text: "not an agent") }
            return try LeadDelivery.deliver(text, from: sender, to: agent, state: nil, inputIsEmpty: nil, typeInto: nil, root: inbox)
        }
    }

    static func repo(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// Both leads started; alpha's returned.
    func leads() throws -> LeadToolset {
        _ = try lead(betaRoot, beta)
        let sender = try lead(alphaRoot, alpha)
        sender.leadMailOn = { true }
        return sender
    }

    func pending() -> [SteerMessage] { SteerInbox.pending(tty: Self.betaAgent.tty, root: inbox) }

    static let question = "Does your API keep the v1 endpoint? zebra-7f3a"

    @Test func aLeadsMessageReachesTheOtherLeadMarkedWithItsProject() throws {
        let sender = try leads()
        let sent = sender.call("tell_lead", ["project": "beta", "kind": "question", "text": Self.question])
        #expect(!sent.isError, "\(sent.text)")
        #expect(sent.text.contains("the lead of beta") && sent.text.contains("VibeSwitcher wakes it"), "\(sent.text)")
        #expect(alpha.steered.map(\.target) == ["agent:5151"])

        // In beta's lead's inbox, for its agent, sealed for the sender VibeSwitcher filled in.
        let messages = pending()
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.from == .lead("the lead of alpha"))
        #expect(message.agentPid == 5151)
        #expect(SteerSeal.for(inbox).verify(messages) == [true])
        #expect(message.text.hasPrefix("Question: " + Self.question))
        #expect(message.text.contains("tell_lead(project: \"alpha\", kind: answer)"))
        #expect(message.text.contains("can't approve, authorise or grant anything"))

        // Typed as an idle lead's prompt, and handed over by its hook, it says who sent it, and that it's not the user.
        let typed = LeadDelivery.typed(message.text, from: message.from)
        #expect(typed.hasPrefix("[VibeSwitcher · from the lead of alpha, not the user] Question: "))
        #expect(TeamMessage.typed(typed)?.sender == .lead("the lead of alpha"))
        let context = SteerReply.context(messages)
        #expect(context.contains("Another project's lead (the lead of alpha, another Claude session, not the user)"))
        #expect(!context.contains("Your project lead ("))
        #expect(SteerReply.messages(inContext: context).map(\.fromLead) == [true])
    }

    @Test func aSessionNotHoldingALeadRoleIsRefusedWhateverItsArguments() throws {
        _ = try leads()
        // A worker of alpha's starts the tool server itself, as the lead, for its own project or another.
        _ = try issued(.worker, task: "t", root: alphaRoot, alpha, session: "worker-session")
        let workerSeat = FakeSeat(alpha, agent: LeadAgent(pid: 6001, tty: "ttys081", session: "worker-session"))
        // A session VibeSwitcher gave no role at all.
        let strangerSeat = FakeSeat(alpha, agent: LeadAgent(pid: 6002, tty: "ttys082", session: "stranger"))
        for (seat, root) in [(workerSeat, alphaRoot), (workerSeat, betaRoot), (strangerSeat, alphaRoot)] {
            let server = LeadToolset(arguments: ["--role", "lead", "--root", root], runtime: seat, vault: vault(for: seat))
            #expect(!server.tools.contains { $0.name == "tell_lead" })
            let refused = server.call("tell_lead", ["project": "beta", "kind": "report", "text": "hi"])
            #expect(refused.isError)
            #expect(refused.text.contains("Refused") || refused.text.contains("no role"), "\(refused.text)")
        }
        #expect(alpha.steered.isEmpty)
        #expect(pending().isEmpty)
    }

    @Test func workersAndVerifiersHaveNoTellLead() throws {
        let sender = try leads()
        #expect(sender.tools.contains { $0.name == "tell_lead" })
        let worker = try issued(.worker, task: "t", root: alphaRoot, alpha)
        let verifier = try issued(.verifier, task: "t", root: alphaRoot, alpha)
        for tools in [worker, verifier] {
            #expect(!tools.tools.contains { $0.name == "tell_lead" })
            let refused = tools.call("tell_lead", ["project": "beta", "kind": "report", "text": "hi"])
            #expect(refused.isError && refused.text.contains("No tool tell_lead"), "\(refused.text)")
        }
        #expect(pending().isEmpty)
    }

    /// Each guard refuses with its reason, nothing is sent, and the refusal is kept.
    @Test func theGuardsRefuseWithTheirReason() throws {
        let sender = try leads()
        let token = "gh" + "p_" + String(repeating: "AbCdEfGhIj", count: 4)
        let cases: [(arguments: [String: Any], reason: String, outcome: LeadMail.Outcome)] = [
            (["project": "beta", "kind": "report", "text": "the deploy key is \(token)"], "GitHub token", .refused),
            (["project": "beta", "kind": "report", "text": String(repeating: "x", count: LeadMail.maxCharacters + 1)], "over the 4000 a message takes", .refused),
            (["project": "alpha", "kind": "report", "text": "hi"], "your own project", .refused),
            (["project": alphaRoot, "kind": "report", "text": "hi"], "your own project", .refused),
            (["project": "beta", "kind": "gossip", "text": "hi"], "kind is question, report or answer", .refused),
            (["project": "gamma", "kind": "report", "text": "hi"], "no lead is running for gamma", .noLead),
        ]
        for (index, test) in cases.enumerated() {
            let refused = sender.call("tell_lead", test.arguments)
            #expect(refused.isError, "\(test.reason)")
            #expect(refused.text.contains(test.reason), "\(refused.text)")
            let record = try #require(LeadMail.load(root: alphaRoot).last)
            #expect(LeadMail.load(root: alphaRoot).count == index + 1)
            #expect(record.outcome == test.outcome)
            #expect(!record.text.contains(token))
        }
        #expect(alpha.steered.isEmpty)
        #expect(pending().isEmpty)
        #expect(LeadMail.load(root: betaRoot).isEmpty)

        // The channel turned off on this Mac.
        sender.leadMailOn = { false }
        let off = sender.call("tell_lead", ["project": "beta", "kind": "question", "text": Self.question])
        #expect(off.isError && off.text.contains("lead mail is turned off"), "\(off.text)")
        #expect(LeadMail.load(root: alphaRoot).last?.outcome == .off)
        #expect(pending().isEmpty)
    }

    /// Not only the vendors' shapes: whatever `Redaction.secrets` catches stays out of the message and of the record,
    /// whichever argument it came in.
    @Test func whatRedactionCatchesIsRefusedAndNeverKept() throws {
        let sender = try leads()
        let secret = "correct-horse-battery-7f3a"
        let texts = ["call it with Authorization: Bearer \(secret)", "X-Auth: bearer \(secret)", "the login is password=\(secret) for now",
                     "export API_KEY=\(secret)", "clone https://deploy:\(secret)@git.example.com/a.git"]
        for text in texts {
            let refused = sender.call("tell_lead", ["project": "beta", "kind": "report", "text": text])
            #expect(refused.isError && refused.text.contains("shaped like a credential"), "\(text): \(refused.text)")
            #expect(!refused.text.contains(secret), "\(refused.text)")
            #expect(LeadMail.load(root: alphaRoot).last?.outcome == .refused)
        }
        // A secret in the other arguments, which a refusal quotes.
        _ = sender.call("tell_lead", ["project": "beta", "kind": "password=\(secret)", "text": "hi"])
        _ = sender.call("tell_lead", ["project": "password=\(secret)", "kind": "report", "text": "hi"])
        #expect(alpha.steered.isEmpty)
        #expect(pending().isEmpty)
        #expect(LeadMail.load(root: alphaRoot).count == texts.count + 2)
        // The bytes on disk, every field.
        let written = try String(contentsOf: LeadMail.file(root: alphaRoot), encoding: .utf8)
        #expect(!written.contains(secret), "\(written)")
        #expect(written.contains("•••"), "\(written)")
    }

    /// Prose about credentials isn't a credential, and goes.
    @Test func talkingAboutCredentialsStillGoes() throws {
        let sender = try leads()
        let text = "The bearer token expired, so the password rule changed; see the URL https://example.com/docs"
        #expect(LeadMail.textRefusal(text) == nil)
        let sent = sender.call("tell_lead", ["project": "beta", "kind": "report", "text": text])
        #expect(!sent.isError, "\(sent.text)")
        #expect(LeadMail.load(root: alphaRoot).last?.text == text)
    }

    @Test func theRateLimitHoldsEachPairToTenAnHour() throws {
        let sender = try leads()
        var now = 1_800_000_000.0
        sender.mailClock = { now }
        alpha.onSteer = nil
        for index in 0..<LeadMail.perHour {
            let sent = sender.call("tell_lead", ["project": "beta", "kind": "report", "text": "update \(index)"])
            #expect(!sent.isError, "\(sent.text)")
            now += 60
        }
        let held = sender.call("tell_lead", ["project": "beta", "kind": "report", "text": "one more"])
        #expect(held.isError)
        #expect(held.text.contains("10 messages in the last hour") && held.text.contains("in 50 min"), "\(held.text)")
        #expect(alpha.steered.count == LeadMail.perHour)
        // An hour after the first, one more may go.
        now = 1_800_000_000 + 3_600
        #expect(!sender.call("tell_lead", ["project": "beta", "kind": "report", "text": "one more"]).isError)
        #expect(alpha.steered.count == LeadMail.perHour + 1)
    }

    @Test func theRecordIsPrivateWithEveryField() throws {
        let sender = try leads()
        sender.mailClock = { 1_800_000_123 }
        #expect(!sender.call("tell_lead", ["project": "beta", "kind": "question", "text": Self.question]).isError)
        for root in [alphaRoot, betaRoot] {
            let file = LeadMail.file(root: root)
            #expect(file.path == root + "/.vibeswitcher/lead-mail.jsonl")
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
            #expect(mode == 0o600, "\(String(mode, radix: 8))")
            let folder = try #require(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int)
            #expect(folder == 0o700, "\(String(folder, radix: 8))")
            let line = try #require(String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").first)
            let fields = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(Set(fields.keys).isSuperset(of: ["at", "from", "to", "kind", "text", "outcome"]))
            #expect(LeadMail.load(root: root) == [LeadMail.Record(at: 1_800_000_123, from: "alpha", to: "beta", kind: .question, text: Self.question,
                                                                  outcome: .waiting, detail: LeadMail.load(root: root).first?.detail ?? "")])
        }
    }

    @Test func theRepositorysRecordsGetNoMessageContent() throws {
        let sender = try leads()
        #expect(!sender.call("add_task", ["title": "Something", "goal": "g", "acceptance": ["a"], "boundaries": ["b"]]).isError)
        #expect(!sender.call("tell_lead", ["project": "beta", "kind": "question", "text": Self.question]).isError)
        _ = sender.call("tell_lead", ["project": "beta", "kind": "report", "text": "secret-ish \("gh" + "p_" + String(repeating: "Zz9", count: 12))"])
        _ = sender.records.flush(base: "main")
        let history = Git.run(["log", "-p", "--all"], in: alphaRoot).output
        #expect(history.contains("Something"), "the records were committed: \(history.prefix(400))")
        var texts = [history]
        let fm = FileManager.default
        let enumerator = try #require(fm.enumerator(atPath: alphaRoot))
        while let path = enumerator.nextObject() as? String {
            guard !path.hasPrefix(".git/"), path != ".git", path != ".vibeswitcher/lead-mail.jsonl" else { continue }
            if let data = fm.contents(atPath: alphaRoot + "/" + path) { texts.append(String(decoding: data, as: UTF8.self)) }
        }
        for text in texts {
            #expect(!text.contains("zebra-7f3a"))
            #expect(!text.contains("beta"))
            #expect(!text.contains("tell_lead"))
        }
    }
}
