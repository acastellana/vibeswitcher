import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A project's lead reopened in its same conversation after a host restart (v2-parity gap 10, `RestartResume.swift`):
/// while a lead runs the node keeps what reopens it in `engine.json`; after the host restarts, `status` offers
/// `vibeswitcher lead ROOT --resume`, refused until the user's accepts, which starts `claude --resume <its conversation>`
/// told which workers ended with the restart. The record is only a hint: one naming a transcript outside the agents'
/// folders, or another project's, starts nothing. The record's checks on their own (`resumable`), then two host restarts
/// on a `ScratchNode` (its root again, as `RestartTests` does).
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(10)))
struct RestartResumeTests {
    private let scratch = Scratch()

    // MARK: The record's checks

    /// A transcript in Claude's folder for the repository, named by its conversation and started under the lead's name,
    /// is taken; anything else a record can say is refused, saying why.
    @Test func onlyTheLeadsOwnTranscriptIsResumable() throws {
        let home = scratch.url("home")
        let root = scratch.url("parent").appendingPathComponent("repo").path
        let projects = home.appendingPathComponent(".claude/projects")
        let id = UUID().uuidString.lowercased()
        let named = #"{"type":"agent-name","agentName":"lead-repo","sessionId":"x"}"# + "\n"
        func write(_ url: URL, _ text: String = named) throws -> String {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        func check(_ transcript: String?, conversation: String? = nil) -> Result<(conversation: String, transcript: String), LeadEngine.Refused> {
            LeadEngine.resumable(transcript.map { EngineState.Reopen(session: UUID().uuidString, conversation: conversation, transcript: $0) },
                                 root: root, home: home.path)
        }
        func refusal(_ result: Result<(conversation: String, transcript: String), LeadEngine.Refused>) -> String? {
            if case .failure(let refused) = result { return "\(refused)" }
            return nil
        }
        let own = try write(projects.appendingPathComponent(RecentProjects.claudeSlug(for: root)).appendingPathComponent("\(id).jsonl"))
        let taken = try check(own, conversation: id).get()
        #expect(taken.conversation == id && taken.transcript == URL(fileURLWithPath: own).resolvingSymlinksInPath().path)
        #expect((try? check(own).get())?.conversation == id)

        // No record, or one with no transcript.
        #expect(refusal(LeadEngine.resumable(nil, root: root, home: home.path))?.contains("kept no conversation") == true)
        // Outside the agents' folders, directly or through a link in Claude's folder for the repository.
        let outside = try write(scratch.url("elsewhere").appendingPathComponent("\(id).jsonl"))
        #expect(refusal(check(outside))?.contains("isn't a Claude transcript inside the agents' folders") == true, "\(String(describing: refusal(check(outside))))")
        let linked = projects.appendingPathComponent(RecentProjects.claudeSlug(for: root)).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: outside)
        #expect(refusal(check(linked.path))?.contains("inside the agents' folders") == true)
        // Another project's conversation, or a worktree's.
        let other = try write(projects.appendingPathComponent(RecentProjects.claudeSlug(for: root + "-other")).appendingPathComponent("\(id).jsonl"))
        #expect(refusal(check(other))?.contains("isn't in Claude's folder for \(root)") == true, "\(String(describing: refusal(check(other))))")
        // Not named by a conversation id, or not the one the record says.
        let unnamed = try write(projects.appendingPathComponent(RecentProjects.claudeSlug(for: root)).appendingPathComponent("notes.jsonl"))
        #expect(refusal(check(unnamed))?.contains("isn't named by a conversation id") == true)
        #expect(refusal(check(own, conversation: UUID().uuidString))?.contains("isn't the one its transcript holds") == true)
        // Not started under the lead's name (a worker's conversation in the same folder).
        let worker = try write(projects.appendingPathComponent(RecentProjects.claudeSlug(for: root)).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"),
                               #"{"type":"agent-name","agentName":"worker-parser"}"# + "\n")
        #expect(refusal(check(worker))?.contains("isn't the conversation of a lead started as lead-repo") == true)
    }

    // MARK: After a host restart

    /// The lead's conversation and its board's running worker recorded, the host restarted: `status` offers the reopen
    /// naming the worker; `lead --resume` is refused until `config accept` and `base accept`; then it starts the lead
    /// with `--resume <its conversation>`, its first message saying the host restarted and which worker ended, on which
    /// branch at which commit; and the project's restart notice is over.
    @Test func aRestartedNodeReopensTheLeadInItsConversation() async throws {
        let conversation = UUID().uuidString.lowercased()
        let (node, repo, firstLead) = try await hostRestarted(conversation: conversation)
        defer { node.stop() }
        let head = Git.run(["rev-parse", "agent/write-the-parser"], in: repo.path).output

        let status = try await node.statusJSON()
        let notice = try #require(((status["notices"] as? [String]) ?? []).first { $0.contains("ended with the host before it") }, "\(status)")
        #expect(notice.contains("`vibeswitcher lead \(repo.path) --resume`") && notice.contains(conversation), "\(notice)")
        #expect(notice.contains("write-the-parser (agent/write-the-parser)"), "\(notice)")

        let refused = try await node.runOnTerminal(["lead", repo.path, "--resume"])
        #expect(refused.status == 77 && refused.output.contains("config held"), "\(refused.output)")
        #expect(try node.sessions().contains { $0.isLive && $0.label.hasPrefix("Lead · ") } == false)

        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        let reopened = try await node.runOnTerminal(["lead", repo.path, "--resume"])
        #expect(reopened.status == 0 && reopened.output.contains("the lead started") && reopened.output.contains("same conversation"),
                "\(reopened.output)\n\(node.said)")
        let lead = try #require(try node.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(node.said)")
        let files = node.fake.files(terminal: lead.tty)
        let state = { (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any] ?? [:] }
        // The new lead's fake: Linux hands the ended lead's pty number out again, and its files stay there until the new
        // fake starts and moves them aside, so a state with any pid may still be the first lead's.
        #expect(await eventually(timeout: 60) { (state()["pid"] as? Int).map { $0 != firstLead } == true }, "\(state())\n\(node.said)")
        #expect(state()["resume"] as? String == conversation, "\(state())")
        let prompt = try #require(state()["prompt"] as? String, "\(state())")
        #expect(prompt.contains("session host restarted") && prompt.contains("reopened you in your same conversation"), "\(prompt)")
        #expect(prompt.contains("write-the-parser (Write the parser) on branch agent/write-the-parser at \(head.prefix(12))"), "\(prompt)")
        #expect(prompt.contains("start_worker"), "\(prompt)")
        let after = try await node.statusJSON()
        #expect(!((after["notices"] as? [String]) ?? []).contains { $0.contains("ended with the host before it") }, "\(after)")
    }

    /// `engine.json` rewritten while the hosts were down (a worker of the user's uid can): its record names a transcript
    /// outside the agents' folders, under the lead's name and the conversation's. After the accepts `lead --resume` is
    /// refused, saying why, and no lead starts; a fresh `lead` still does. (The other forgeries: `resumable`'s case.)
    @Test func aForgedRecordReopensNothing() async throws {
        let forged = scratch.url("forged")
        let conversation = UUID().uuidString.lowercased()
        let (node, repo, _) = try await hostRestarted(conversation: conversation) { node, repo in
            let outside = forged.appendingPathComponent("\(conversation).jsonl")
            try FileManager.default.createDirectory(at: forged, withIntermediateDirectories: true)
            try #"{"agentName":"lead-repo"}"#.write(to: outside, atomically: true, encoding: .utf8)
            try Self.rewriteRecord(node, repo) { $0["transcript"] = outside.path }
        }
        defer { node.stop() }
        try await node.acceptConfig(repo)
        try await node.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        let outside = try await node.runOnTerminal(["lead", repo.path, "--resume"])
        #expect(outside.status != 0 && outside.output.contains("isn't a Claude transcript inside the agents' folders"), "\(outside.output)\n\(node.said)")
        #expect(try node.sessions().contains { $0.isLive && $0.label.hasPrefix("Lead · ") } == false)


        let fresh = try await node.runOnTerminal(["lead", repo.path])
        #expect(fresh.status == 0 && fresh.output.contains("the lead started"), "\(fresh.output)\n\(node.said)")
    }

    // MARK: Helpers

    /// A node whose host restarted with a lead's conversation recorded: a first node on a fresh vault (its config and
    /// base accepted), its lead started, a task with a worker running on its branch, the lead's hook naming its
    /// transcript `<conversation>.jsonl` in Claude's folder for the repository; once `engine.json` holds both, the host
    /// stops, `between` runs, and a second host starts on the same root. The first lead's fake's pid comes back with them.
    private func hostRestarted(conversation: String,
                               between: (ScratchNode, URL) async throws -> Void = { _, _ in }) async throws -> (ScratchNode, URL, Int) {
        let first = try await ScratchNode(scratch, holdFirstLook: true)
        let repo = first.root.appendingPathComponent("repo")
        try await scratchRepository(repo)
        try ScratchNode.workflow(repo, testCommand: "make check")
        try await first.acceptConfig(repo)
        try await first.acceptBase(repo, from: Git.run(["rev-parse", "main"], in: repo.path).output)
        let started = try await first.runOnTerminal(["lead", repo.path, "--goal", "plan the work"])
        try #require(started.status == 0, "\(started.output)\n\(first.said)")
        let lead = try #require(try first.sessions().first { $0.isLive && $0.label.hasPrefix("Lead · ") }, "\(first.said)")
        let files = first.fake.files(terminal: lead.tty)
        let state = { (try? JSONSerialization.jsonObject(with: Data(contentsOf: files.state))) as? [String: Any] ?? [:] }
        try #require(await eventually(timeout: 60) { state()["pid"] != nil }, "\(first.said)")
        let pid = try #require((state()["pid"] as? Int).map(Int32.init))

        // A worker on its task's branch, as the board says.
        let made = Git.run(["branch", "agent/write-the-parser", "main"], in: repo.path)
        try #require(made.ok, "\(made.output)")
        try BoardStore(root: repo.path).update { board in
            var task = LeadTask(slug: "write-the-parser", title: "Write the parser",
                                contract: LeadContract(goal: "A parser.", acceptance: [], boundaries: [], context: ""), status: .running)
            task.worker = UUID().uuidString
            task.branch = "agent/write-the-parser"
            board.tasks.append(task)
        }
        // The lead's transcript, as Claude writes it for `--name lead-repo`, and its hook naming it.
        let transcript = first.home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(RecentProjects.claudeSlug(for: repo.resolvingSymlinksInPath().path))
            .appendingPathComponent("\(conversation).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (#"{"type":"agent-name","agentName":"lead-repo","sessionId":"\#(conversation)"}"# + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        var hook = HookState(agent: .claude, tty: lead.tty, lastEvent: "Stop", lastEventAt: Date().timeIntervalSince1970)
        hook.agentPid = pid
        hook.transcriptPath = transcript.path
        let states = first.root.appendingPathComponent("state")
        try VibePaths.ensurePrivate(states)
        try hook.save(to: states.appendingPathComponent("\(lead.tty).json"))
        try #require(await eventually(timeout: 90) {
            let record = Self.record(first, repo)
            return record?["conversation"] as? String == conversation && (record?["workers"] as? [Any])?.count == 1
        }, "\(String(describing: try? String(contentsOf: EngineState.url(root: first.root), encoding: .utf8)))\n\(first.said)")
        try #require(await eventually(timeout: 60) { EngineState.load(root: first.root).state.hostStartedAt != nil })
        first.stop()
        try await between(first, repo)
        let second = try await ScratchNode(scratch, holdFirstLook: true, reusing: first.root)
        return (second, repo, Int(pid))
    }

    /// `engine.json`'s reopen record for `repo`, as written (read as JSON: what the next server reads).
    private static func record(_ node: ScratchNode, _ repo: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: EngineState.url(root: node.root)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["reopen"] as? [String: Any])?[repo.path] as? [String: Any]
    }

    /// `engine.json` with `repo`'s reopen record changed by `change`.
    private static func rewriteRecord(_ node: ScratchNode, _ repo: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = EngineState.url(root: node.root)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var reopen = try #require(object["reopen"] as? [String: Any], "\(object)")
        var record = try #require(reopen[repo.path] as? [String: Any], "\(reopen)")
        change(&record)
        reopen[repo.path] = record
        object["reopen"] = reopen
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
