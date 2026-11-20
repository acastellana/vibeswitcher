import Foundation
import VibeCore

/// A project's lead reopened in its same conversation after a host restart (v2-parity gap 10; the app's restart card,
/// `RestartCard.swift`, `RestartReopen` and `LeadController.reopenLead`, for a node).
///
/// **The record.** While a lead runs holding its role, the engine keeps what reopens it in `engine.json`
/// (`EngineState.Reopen`, by root): its host session, Claude's conversation id and transcript (from its hook, as
/// `NodeSessions` checked it), the model and advisor it was started on, and the workers running. A host restart (a
/// reboot) ends the lead; the record stays.
///
/// **The offer.** After the restart, `status`'s notice for the project (`restartNotices`) says, after the accepts it
/// asks for, `vibeswitcher lead ROOT --resume` reopens the lead in its conversation, and which workers ended with it.
///
/// **The reopen.** `vibeswitcher lead ROOT --resume`, in the user's voice, is a lead start like any other (the app's
/// `reopenLead`): the vault's first look refuses it until `config accept` and `base accept`, the grant is fresh and bound
/// to the new session, and the prompt, rules, model and advisor are the start's own. Only the conversation differs:
/// `claude --resume <id>`, with no last turns handed over, and its first message (`notice`) says the host restarted,
/// that its workers and verifiers ended, and which tasks had workers running, on which branch at which commit, to start
/// again with `start_worker` (a worker's conversation isn't resumed: as on the Mac, `start_worker` continues in the task's
/// worktree, its commits kept).
///
/// **What the record can't do.** A worker of the user's uid can write `engine.json`, so the record is only a hint of which
/// conversation to look at: it's taken only for a root the host restart ended a lead of, and only a transcript that
/// checks out (`resumable`): inside the agents' folders (`TranscriptReader.checkedURL`), in Claude's folder for this very
/// repository (not a worktree's, not another project's), named by a conversation id (the record's, when it says one),
/// and started under the lead's name. Anything else is refused, said, and nothing starts.
extension LeadEngine {
    /// Each running lead that holds its role: its reopen record kept current (its conversation once its hook names its
    /// transcript, its board's running workers), written to `engine.json` when it changed. On `queue`.
    func noteReopen() {
        let hooked = Dictionary((sessions?.sessions ?? []).compactMap { session in session.hostID.map { ($0, session) } },
                                uniquingKeysWith: { $1 })
        var changed = false
        for lead in leads.leads.values {
            guard let session = lead.session, lead.bound?.lowercased() == session.uuidString.lowercased() else { continue }
            let root = lead.root
            var record = reopen[root].flatMap { $0.session.lowercased() == session.uuidString.lowercased() ? $0 : nil }
                ?? EngineState.Reopen(session: session.uuidString)
            if let hook = hooked[session], let path = hook.transcriptPath {
                record.transcript = path
                record.conversation = hook.agentSessionID ?? Self.conversation(ofTranscript: path) ?? record.conversation
            }
            if let board = boards[root] { record.workers = Self.runningWorkers(board) }
            guard reopen[root] != record else { continue }
            reopen[root] = record
            changed = true
        }
        if changed { saveState() }
    }

    /// The lead started in `root` (`session`) on `run`, carrying on `resumed` when it was reopened: its record from now
    /// on, before its hook says anything. On `queue`.
    func noteStarted(root: String, session: UUID, run: LeadLaunch.Run, resumed: (conversation: String, transcript: String)?) {
        reopen[root] = EngineState.Reopen(session: session.uuidString, conversation: resumed?.conversation, transcript: resumed?.transcript,
                                          model: run.model, advisor: run.advisor, workers: boards[root].map(Self.runningWorkers) ?? [])
        saveState()
    }

    /// What `status`'s host-restart notice for `root` ends with: the reopen, when the record names a conversation,
    /// else a fresh start. On `queue`.
    func reopenStep(root: String) -> String {
        guard let record = reopen[root], let conversation = record.conversation else { return "`vibeswitcher lead \(root)`" }
        var step = "`vibeswitcher lead \(root) --resume` to reopen its lead in its same conversation (\(ConfigSeal.inert(conversation, limit: 40)))"
        if !record.workers.isEmpty {
            step += ", told that its worker\(record.workers.count == 1 ? "" : "s") on "
                + record.workers.map { "\(ConfigSeal.inert($0.task, limit: 80)) (\(ConfigSeal.inert($0.branch, limit: 120)))" }.joined(separator: ", ")
                + " ended, to start again from \(record.workers.count == 1 ? "its branch" : "their branches")"
        }
        return step + ", or `vibeswitcher lead \(root)` for a fresh lead"
    }

    /// Why `--resume` can't reopen `root`'s lead, before anything is asked of git or the vault; nil when the host restart
    /// ended a lead there and the record names its transcript (checked off the queue, `resumable`). On `queue`.
    func reopenRefusal(root: String) -> String? {
        let project = LeadMail.project(of: root)
        guard hostRestart?.gone.contains(root) == true else {
            return "no session host restart ended a lead of \(project) since one last started: --resume reopens only that lead "
                + "(`vibeswitcher lead \(root)` starts one, or shows the one running)"
        }
        guard reopen[root]?.transcript != nil else {
            return "the node kept no conversation for the lead of \(project) that the restart ended (its hooks never named its transcript): "
                + "`vibeswitcher lead \(root)` starts a fresh lead"
        }
        return nil
    }

    /// The conversation a reopen of `root`'s lead carries on, from its record: its id and its transcript, or why it's
    /// refused. The transcript must be a regular `.jsonl` inside the agents' folders in `home`
    /// (`TranscriptReader.checkedURL`), Claude's, in Claude's folder for `root` itself, named `<conversation id>.jsonl` (the
    /// record's id, when it says one), and started under the lead's name (`lead-<project>`, as `--name` writes it).
    static func resumable(_ record: EngineState.Reopen?, root: String, home: String) -> Result<(conversation: String, transcript: String), Refused> {
        let project = LeadMail.project(of: root)
        func refused(_ why: String) -> Result<(conversation: String, transcript: String), Refused> {
            .failure(Refused("the lead of \(project) wasn't reopened: \(why); `vibeswitcher lead \(root)` starts a fresh lead"))
        }
        guard let record, let path = record.transcript else { return refused("the node kept no conversation for it") }
        let shown = ConfigSeal.inert(path, limit: 200)
        guard let (url, format) = TranscriptReader.checkedURL(path, home: home), format == .claude else {
            return refused("its recorded transcript \(shown) isn't a Claude transcript inside the agents' folders")
        }
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").resolvingSymlinksInPath()
        let spellings = [root, (root as NSString).standardizingPath, URL(fileURLWithPath: root).resolvingSymlinksInPath().path]
        let folders = Set(spellings.map { projects.appendingPathComponent(RecentProjects.claudeSlug(for: $0)).path })
        guard folders.contains(url.deletingLastPathComponent().path) else {
            return refused("its recorded transcript \(shown) isn't in Claude's folder for \(root)")
        }
        guard let conversation = conversation(ofTranscript: url.path) else {
            return refused("its recorded transcript \(shown) isn't named by a conversation id")
        }
        if let said = record.conversation, said.lowercased() != conversation.lowercased() {
            return refused("its recorded conversation \(ConfigSeal.inert(said, limit: 40)) isn't the one its transcript holds")
        }
        let name = leadName(root: root)
        let needles = ["\"agentName\":\"\(name)\"", "\"customTitle\":\"\(name)\""].map { Data($0.utf8) }
        guard let ends = edges(of: url), needles.contains(where: { ends.range(of: $0) != nil }) else {
            return refused("its recorded transcript \(shown) isn't the conversation of a lead started as \(name)")
        }
        return .success((conversation, url.path))
    }

    /// The name a lead of `root` is started with (`--name`).
    static func leadName(root: String) -> String { "lead-\(Slug.make((root as NSString).lastPathComponent, taken: []))" }

    /// The conversation id a Claude transcript's name says (`<id>.jsonl`), when it's one.
    static func conversation(ofTranscript path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "jsonl" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: stem) != nil ? stem : nil
    }

    /// The board's workers that were running: each task's worker not stopped nor released, with its branch.
    static func runningWorkers(_ board: LeadBoard) -> [EngineState.Reopen.Worker] {
        working(board).compactMap { task in
            task.worker.map { EngineState.Reopen.Worker(task: task.slug, session: $0, branch: task.branch ?? Worktrees.branch(task.slug)) }
        }
    }

    private static func working(_ board: LeadBoard) -> [LeadTask] {
        board.tasks.filter { $0.status == .running && $0.worker != nil && $0.worker != $0.stopped }
    }

    /// The one message a reopened lead starts with (the app's `RestartReopen.leadNotice`, for a node): the host restarted
    /// and its team ended, the tasks that had workers running with each one's branch and the commit it's at (read in
    /// `root`), and the tasks whose verifier was checking. From the board as the restart left it. Off the engine's queue
    /// (git).
    static func notice(board: LeadBoard, root: String) -> String {
        let checking = board.tasks.filter { $0.status == .review && !$0.awaitedVerifiers.isEmpty }
        var text = "This node's session host restarted (the machine did, or the host was), and it ended with every session in it: "
            + "your workers and verifiers aren't running any more. The user reopened you in your same conversation, on a fresh "
            + "grant: the host's vault started over, and the user accepted the config and the base again."
        let working = working(board)
        if working.isEmpty {
            text += " No task had a worker running."
        } else {
            text += " Tasks whose worker ended with it: " + working.map { task -> String in
                let branch = task.branch ?? Worktrees.branch(task.slug)
                let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: root)
                let at = head.ok && !head.output.isEmpty ? " at \(head.output.prefix(12))" : ", which isn't there"
                return "\(ConfigSeal.inert(task.slug, limit: 80)) (\(ConfigSeal.inert(task.title, limit: 120))) on branch "
                    + "\(ConfigSeal.inert(branch, limit: 120))\(at)"
            }.joined(separator: ", ") + ". Restart each with start_worker: it continues in the task's existing worktree, its commits kept."
        }
        if !checking.isEmpty {
            text += " Tasks whose verifier was checking: " + checking.map { ConfigSeal.inert($0.slug, limit: 80) }.joined(separator: ", ")
                + "; audit starts it again."
        }
        return text + " Check the board first."
    }

    /// The first and last 64 KB of a file, where Claude writes the session's name (`TranscriptLocator`'s read).
    private static func edges(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 64 * 1024
        guard var data = try? handle.read(upToCount: limit), let size = try? handle.seekToEnd() else { return nil }
        if size > UInt64(limit) {
            let from = max(UInt64(limit), size - UInt64(limit))
            if (try? handle.seek(toOffset: from)) != nil, let end = try? handle.readToEnd() { data.append(end) }
        }
        return data
    }
}
