import Foundation
import VibeCore

/// The Team view's plain-language lines: what each task's agent is doing now, what a long decision of the lead's
/// means. Asked for while a Team view is on screen (it calls `request` every few seconds), written by a small model
/// through headless Claude Code off the main thread, cached per task and per decision (see `Summarizer`). Off in
/// Settings, or while none has come, the rows show their checkpoint or live activity instead.
final class TeamSummaryModel: ObservableObject {
    /// Settings' "AI summaries" switch.
    @Published var enabled = true
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
        summarizer.changed = { [weak self] in self?.objectWillChange.send() }
    }

    /// The summary of what a row's agent is doing, when there's one (nil: show the fallback).
    func line(_ row: TeamRow) -> String? {
        guard enabled, let key = row.summaryKey else { return nil }
        return summarizer.cached(key)
    }

    /// The plain summary of a long decision, when there's one.
    func line(_ decision: LeadDecision) -> String? {
        guard enabled, DecisionFeed.needsSummary(decision) else { return nil }
        return summarizer.cached(DecisionFeed.summaryKey(decision))
    }

    /// Asks for the lines that are due: each task at work (when its agent's transcript changed, at most every three
    /// minutes) and each recent long decision (once).
    func request(rows: [TeamRow], decisions: [LeadDecision]) {
        guard enabled else { return }
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
        for decision in decisions where DecisionFeed.needsSummary(decision) {
            summarizer.line(DecisionFeed.summaryKey(decision), fingerprint: decision.text) {
                SummaryPrompts.decision(decision.text, why: decision.why)
            }
        }
    }
}
