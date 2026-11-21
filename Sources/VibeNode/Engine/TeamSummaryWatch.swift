import Foundation
import VibeCore

/// AI summaries of what each agent is doing (the parity table's row; the app's `TeamSummaryModel.request(rows:)`): after
/// each refresh, for every task at work (a running task's worker, a reviewed task's awaited verifier) whose session is
/// live, one plain line is asked of a small model (`Options.summarize`: headless Claude on Haiku on the user's node,
/// `NodeSummaries.headless`), written from the task's title, its last checkpoints and its transcript's last steps,
/// every field masked (`SummaryPrompts`). Rate-limited by `SummaryCache`: a line per agent only when its transcript or
/// checkpoints changed, at most every 3 minutes, never while one is being written; and the model runs one prompt at a
/// time (`summaryRuns`). Off with Settings' AI summaries (`ai_summaries`, `NodeSummaries.isOn`), and while the account's
/// usage holds Haiku back (`AccountUsage.hold`): the lines go and the board shows its own words again.
///
/// The lines go to the boards (`teamSummaries`, by root: task id to line), and so to `vibeswitcher board` and the page,
/// where a running task's line stands in for its checkpoint (`BoardValue`'s `summary`). A model's line is the sessions'
/// writing retold: inert text there, as every board string is.
///
/// And the lead's own words, as the app's Team view and chat cards retell them: each long decision of the latest
/// `decisionsShown` (the board's `decisions`, "Decided: …"), once; and each long message VibeSwitcher handed a lead,
/// once, when its chat is open (`summarizeMessage`, the chat's `team` item's `summary`), the latest `messagesSummarized`
/// of a chat.
extension LeadEngine {
    /// The most recent decisions a board carries, newest first.
    static let decisionsShown = 20
    /// The most recent long messages of a chat a line is asked for (an old lead's chat holds hundreds of reports).
    static let messagesSummarized = 10

    /// Asks for the lines due, after a refresh read `loaded`, `teams` and each lead's `decisions` (newest first);
    /// `on`: Settings' AI summaries. The decisions go to the boards whatever the summaries do. On `queue`.
    func lookAtSummaries(loaded: [String: LeadBoard], teams: [String: TeamReading], decisions: [String: [LeadDecision]] = [:], on: Bool) {
        recentDecisions = decisions
        let held = usage.flatMap { $0.usage.hold(model: ClaudeHeadless.model, now: $0.now, ignoring: $0.ignoring) }
        guard let summarizer, on, held == nil else {
            summariesAllowed = false
            summaryKeys = [:]
            messageKeys = [:]
            publishSummaries()
            return
        }
        summariesAllowed = true
        var keys: [String: [String: String]] = [:]
        let observer = observer
        for (root, board) in loaded {
            let team = teams[root] ?? TeamReading()
            keys[root] = [:]
            for task in board.tasks {
                guard let (agent, role) = Self.summarized(task), let session = team.hosted[agent], session.isLive else { continue }
                let key = "\(root)|\(task.id)|\(agent)"
                keys[root]?[task.id] = key
                let (pid, title, checkpoints) = (team.sessions[agent]?.pid, task.title, task.checkpoints ?? [])
                // The transcript is found and looked at off the engine's queue, as the app's model does off its main thread.
                summaryReads.async {
                    let path = observer.transcript(session, hook: observer.hook(session, agentPid: pid))
                    let transcript = path.flatMap(SummaryPrompts.fingerprint(transcript:))
                    // Nothing to write it from yet: the board's own words say what there is.
                    guard transcript != nil || !checkpoints.isEmpty else { return }
                    summarizer.line(key, fingerprint: "\(transcript ?? "-")|\(checkpoints.count)") {
                        SummaryPrompts.task(title: title, role: role, checkpoints: checkpoints,
                                            steps: path.map { SummaryPrompts.steps(transcript: $0) } ?? [])
                    }
                }
            }
        }
        // Each long decision once (the app's `DecisionFeed.needsSummary`): its text never changes, so it's never due again.
        for (root, list) in decisions {
            for decision in list where NodeSummaries.needsSummary(decision) {
                summarizer.line(Self.decisionKey(root, decision), fingerprint: decision.text) { SummaryPrompts.decision(decision.text, why: decision.why) }
            }
        }
        summaryKeys = keys
        publishSummaries()
    }

    static func decisionKey(_ root: String, _ decision: LeadDecision) -> String { "decision|\(root)|\(decision.id)" }

    /// A TL;DR asked for a long message VibeSwitcher handed a lead (`TeamMessage.needsSummary`), as a chat shows it
    /// (`ChatStore`): `session`'s chat, its item `entry`. Once a message: its text never changes, so it's never due
    /// again (the app's `TeamSummaryModel.request(_:id:)`). Nothing while the summaries are off or held back. From any
    /// thread; the line reaches `messageSummaries` under "session|entry".
    public func summarizeMessage(session: String, entry: String, message: TeamMessage) {
        queue.async { [weak self] in
            guard let self, let summarizer = self.summarizer, self.summariesAllowed, message.needsSummary else { return }
            let id = "\(session)|\(entry)"
            let key = "message:" + id
            self.messageKeys[id] = key
            summarizer.line(key, fingerprint: "message") { SummaryPrompts.message(message) }
            self.publishSummaries()
        }
    }

    /// The agent a task's line is about, and its role in the prompt's words: a running task's worker, a task in
    /// review's awaited verifier; nil for any other.
    static func summarized(_ task: LeadTask) -> (agent: String, role: String)? {
        switch task.status {
        case .running: return task.worker.map { ($0, "software agent") }
        case .review where task.evidence == nil: return task.awaitedVerifier().map { ($0, "reviewer, who checks another agent's work") }
        default: return nil
        }
    }

    /// Each team's lines written so far sent to the boards (`teamSummaries`); a root no longer looked at is dropped.
    /// On `queue`.
    /// Each lead's recent decisions with their lines (`boardDecisions`), and each long message's TL;DR
    /// (`messageSummaries`). On `queue`.
    func publishSummaries() {
        let cached = { (key: String) -> String? in self.summariesAllowed ? self.summarizer?.cached(key) : nil }
        for root in teamSummaries.values.keys where summaryKeys[root] == nil { teamSummaries.send(root, nil) }
        for (root, keys) in summaryKeys { teamSummaries.send(root, keys.compactMapValues(cached)) }
        for root in boardDecisions.values.keys where recentDecisions[root] == nil { boardDecisions.send(root, nil) }
        for (root, list) in recentDecisions {
            boardDecisions.send(root, list.map { decision in
                BoardDecision(id: decision.id, at: decision.at, text: decision.text, why: decision.why,
                              summary: NodeSummaries.needsSummary(decision) ? cached(Self.decisionKey(root, decision)) : nil)
            })
        }
        for id in messageSummaries.values.keys where messageKeys[id] == nil { messageSummaries.send(id, nil) }
        for (id, key) in messageKeys { messageSummaries.send(id, cached(key)) }
    }
}

/// The AI summaries' setting and their model on a node.
public enum NodeSummaries {
    /// The app's defaults' key (`Preferences.aiSummaries`), in the node's `settings.plist`.
    public static let key = "aiSummaries"

    /// A decision longer than this gets a plain one-line summary (the app's `DecisionFeed.long`).
    public static let longDecision = 80

    /// Longer than `longDecision` characters, walking at most that many (the app's `DecisionFeed.needsSummary`).
    public static func needsSummary(_ decision: LeadDecision) -> Bool {
        let text = decision.text
        guard text.utf8.count > longDecision, let end = text.index(text.startIndex, offsetBy: longDecision, limitedBy: text.endIndex) else { return false }
        return end != text.endIndex
    }

    /// Settings' AI summaries: on unless set off (the app's default).
    public static func isOn(_ store: (any SettingsStore)?) -> Bool { (store?.object(forKey: key) as? Bool) ?? true }

    /// Headless Claude Code on Haiku (`ClaudeHeadless.command`: no tools, settings, hooks, MCP servers or saved
    /// session), through the login shell, in `<root>/headless` (made empty each time, so Claude Code's start-up scan
    /// finds nothing): the line, or nil when Claude isn't there, fails or takes longer than `ClaudeHeadless.timeout`.
    /// Blocks. Only the user's node's server gives it (`ServerStart`); a scratch node's engine asks no model.
    /// `system`, `timeout`: the all-done summary's (`BatchSummaryPrompts.system`, `ClaudeHeadless.briefingTimeout`).
    public static func headless(root: URL, system: String = SummaryPrompts.system, timeout: TimeInterval = ClaudeHeadless.timeout) -> Summarizer.Generate {
        { prompt in
            guard let folder = folder(root: root) else { return nil }
            let command = ClaudeHeadless.command(prompt: prompt, system: system)
            let result = Shell.run(executable: command.executable, args: command.args, in: folder, timeout: timeout, grace: 1)
            return result.ok && !result.output.isEmpty ? result.output : nil
        }
    }

    /// `<root>/headless`, made (0700) and emptied of anything left in it; nil when it can't be, or is a link.
    static func folder(root: URL) -> String? {
        let files = FileManager.default
        let folder = root.appendingPathComponent("headless")
        // A link there is never followed (its target's files would be the ones emptied).
        guard (try? VibePaths.ensurePrivate(folder)) != nil,
              (try? files.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory,
              let left = try? files.contentsOfDirectory(atPath: folder.path) else { return nil }
        for name in left { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        return (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true ? folder.path : nil
    }
}
