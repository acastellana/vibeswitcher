import Foundation
import VibeCore

/// The Team view's plain-language lines: what each task's agent is doing now, what a long decision of the lead's
/// means. Asked for while a Team view is on screen (it calls `request` every few seconds), written by a small model
/// through headless Claude Code off the main thread, cached per task and per decision (see `Summarizer`). Off in
/// Settings, or while none has come, the rows show their checkpoint or live activity instead.
final class TeamSummaryModel: ObservableObject {
    /// Settings' "AI summaries" switch.
    @Published var enabled = true {
        didSet {
            isOn = enabled
            version += 1
        }
    }
    /// `enabled` as a plain read: the lines look it up for every task and decision on each pass, and a @Published read
    /// is a dynamic cast each time (`line(LeadDecision)`'s top frame in hang-20261031-003909).
    private var isOn = true
    /// Counts the changes to what `line` gives (a line come, the switch turned): a view keeps the lines it looked up
    /// while it's the same.
    private(set) var version = 0
    /// Whether each message VibeSwitcher handed a lead needs a TL;DR, by its chat entry's id: a message's text never
    /// changes, and counting a long report's characters and lines in each card's body, as every chat update drew them
    /// all again, showed in a 52 s freeze (hang-20261028-175314).
    private var needs: [String: Bool] = [:]
    /// How many times a message's need was worked out (for tests).
    private(set) var needsMade = 0
    /// Each decision's summary key, nil when it's short enough to be shown whole, by its time (and checked against its
    /// text): counting a decision's characters and making its key from its whole text, for every decision on every
    /// pass of the Team tab's lines, is worked out once a decision instead.
    private var decisionKeys: [Double: (text: String, key: String?)] = [:]
    /// What the main thread knows about a team member's session (by host id): its host session, and the transcript
    /// the scan found for its agent.
    var lookup: (String) -> (session: HostSession?, transcript: String?) = { _ in (nil, nil) }

    private let summarizer: Summarizer
    private let observer: LeadObserver
    /// Where transcripts are found and read (file reads, kept off the main thread).
    private let perform: (@escaping () -> Void) -> Void

    init(generate: @escaping Summarizer.Generate = ClaudeHeadless.summarize, interval: Double = SummaryCache.interval,
         now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         run: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         deliver: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         perform: ((@escaping () -> Void) -> Void)? = nil, observer: LeadObserver = LeadObserver()) {
        summarizer = Summarizer(generate: generate, interval: interval, now: now, run: run, deliver: deliver)
        self.observer = observer
        let queue = DispatchQueue(label: "VibeSwitcher.team-summaries", qos: .utility)
        self.perform = perform ?? { queue.async(execute: $0) }
        summarizer.changed = { [weak self] in
            self?.version += 1
            self?.objectWillChange.send()
        }
    }

    /// `message.needsSummary`, once a message (by its chat entry's id).
    func needsSummary(_ message: TeamMessage, id: String) -> Bool {
        if let known = needs[id] { return known }
        needsMade += 1
        let needs = message.needsSummary
        self.needs[id] = needs
        return needs
    }

    /// `DecisionFeed.summaryKey` of a decision that needs a summary (nil: it doesn't), once a decision.
    func summaryKey(_ decision: LeadDecision) -> String? {
        if let known = decisionKeys[decision.at], known.text == decision.text { return known.key }
        let key = DecisionFeed.needsSummary(decision) ? DecisionFeed.summaryKey(decision) : nil
        // Every lead's decisions of the app's run, edited ones included: forgotten all at once now and then.
        if decisionKeys.count >= 4_096 { decisionKeys.removeAll() }
        decisionKeys[decision.at] = (decision.text, key)
        return key
    }

    /// The summary of what a row's agent is doing, when there's one (nil: show the fallback).
    func line(_ row: TeamRow) -> String? {
        guard isOn, let key = row.summaryKey else { return nil }
        return summarizer.cached(key)
    }

    /// The plain summary of a long decision, when there's one.
    func line(_ decision: LeadDecision) -> String? {
        guard isOn, let key = summaryKey(decision) else { return nil }
        return summarizer.cached(key)
    }

    /// The TL;DR of a long message VibeSwitcher handed a lead (by its chat entry's id), when there's one.
    func line(_ message: TeamMessage, id: String) -> String? {
        guard isOn, needsSummary(message, id: id) else { return nil }
        return summarizer.cached(Self.messageKey(id))
    }

    /// Asks for a message's TL;DR, once: its text never changes, so the cache never finds it due again (not after
    /// a failure either).
    func request(_ message: TeamMessage, id: String) {
        guard isOn, needsSummary(message, id: id) else { return }
        summarizer.line(Self.messageKey(id), fingerprint: "message") { SummaryPrompts.message(message) }
    }

    static func messageKey(_ id: String) -> String { "message:\(id)" }

    /// Asks for the lines that are due: each task at work (when its agent's transcript changed, at most every three
    /// minutes) and each recent long decision (once).
    func request(rows: [TeamRow], decisions: [LeadDecision]) {
        guard isOn else { return }
        for row in rows where row.isLive {
            guard let agent = row.agent, let key = row.summaryKey else { continue }
            let known = lookup(agent)
            let task = row.task
            let role = agent == task.verifier ? "reviewer, who checks another agent's work" : "software agent"
            perform { [summarizer, observer] in
                let path = known.transcript ?? known.session.flatMap { observer.transcript($0, hook: observer.hook($0, agentPid: nil)) }
                let checkpoints = task.checkpoints ?? []
                let transcript = path.flatMap(SummaryPrompts.fingerprint(transcript:))
                // Nothing to write it from yet: the fallback says what there is.
                guard transcript != nil || !checkpoints.isEmpty else { return }
                let fingerprint = "\(transcript ?? "-")|\(checkpoints.count)"
                summarizer.line(key, fingerprint: fingerprint) {
                    SummaryPrompts.task(title: task.title, role: role, checkpoints: checkpoints,
                                        steps: path.map { SummaryPrompts.steps(transcript: $0) } ?? [])
                }
            }
        }
        for decision in decisions {
            guard let key = summaryKey(decision) else { continue }
            summarizer.line(key, fingerprint: decision.text) {
                SummaryPrompts.decision(decision.text, why: decision.why)
            }
        }
    }
}
