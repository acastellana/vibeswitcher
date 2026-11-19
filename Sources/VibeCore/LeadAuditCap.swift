import Foundation

/// A project's audits at once are capped at its heavy_slots in force (`auditCap`): each audit builds and runs the test
/// command (its merged result's run, the verifier's own), and only heavy_slots of those run at once on the Mac. On
/// 2026-11-19 nine audits started within a minute after a quota reset: the load went to 54–110, and every merge waited
/// 20+ minutes on the load hold and on every test slot held. So auto_advance starts at most that many of a project's
/// audits, the rest waiting in board order until one ends (`LeadAdvance`), and the lead's audit is refused past it
/// unless it says override_heavy_slots. Only this project's audits count, its re-audits and post-merge Claude
/// re-audits among them; another project's count for its own cap. The Mac-wide limits are as they were.
extension LeadToolset {
    /// How many of this project's audits may be under way at once: heavy_slots in force, as merges and `vs-heavy` take it.
    func auditCap(_ workflow: LeadWorkflow) -> Int {
        max(1, heavyLock(workflow)?.slots ?? macLimits().heavySlotsInForce(workflow.heavySlots ?? TestLock.slotsSet()))
    }

    /// This project's audits under way but `slug`'s, in board order: one this tool server is starting (its merged
    /// result's build and test run come before its verifier is on the board), one whose verifiers it waits on still
    /// work (live, not ended, not submitted, not stopped at a usage limit, not idle: `idleVerifier`), and a post-merge
    /// Claude re-audit whose verifier works.
    func auditsUnderWay(except slug: String?, sessions: [LeadSessionInfo]) -> [String] {
        auditsUnderWay(except: slug, sessions: sessions, starting: auditStarts.withLock { startingAudits })
    }

    private func auditsUnderWay(except slug: String?, sessions: [LeadSessionInfo], starting: Set<String>) -> [String] {
        let submitted = Set(((try? vault.roster(root: root)) ?? []).filter { $0.submittedAt != nil }.map(\.session))
        let working: (String) -> Bool = { [runtime] id in
            guard !submitted.contains(id), let info = sessions.first(where: { $0.id == id }) else { return false }
            return info.live && info.usageLimit == nil && runtime.agentEnding(info) == nil && !Self.idleVerifier(info)
        }
        return store.load().tasks.filter { task in
            guard task.slug != slug else { return false }
            if starting.contains(task.slug) { return true }
            if task.evidence == nil, task.awaitedVerifiers.contains(where: working) { return true }
            if let followup = task.claudeReaudit, followup.pending, followup.evidence == nil, let session = followup.session, working(session) { return true }
            return false
        }.map(\.slug)
    }

    /// A verifier that builds and tests nothing now, though live: waiting on a prompt (Claude's trust question for a
    /// branch that changes its settings waits on the user), or its turn over without its verdict (finished, or ended on
    /// an API error) until someone messages it. Not counted, or such verifiers could hold every one of the project's
    /// audits back for hours. One whose turn waits on its background task (a test run) still counts.
    static func idleVerifier(_ info: LeadSessionInfo) -> Bool {
        if info.waiting != nil { return true }
        guard let status = info.status else { return false }
        return status.hasPrefix(LeadActivity.needsInput(nil).text) || status == LeadActivity.idle(background: nil).text
            || status.hasPrefix(String(LeadActivity.apiError("").text.prefix { $0 != "(" }))
    }

    /// Takes `slug`'s place among the audits starting, unless the project's audits are at the cap (and `override` isn't
    /// given): then nothing is taken, and the refusal says why and where `slug` stands in line. The caller lets go of
    /// its place with `auditStarted` once its verifier is on the board, or the audit didn't start.
    func claimAuditStart(_ slug: String, workflow: LeadWorkflow, sessions: [LeadSessionInfo], override: Bool, not: String) throws {
        let cap = auditCap(workflow)
        let (under, held) = auditStarts.withLock { () -> ([String], [String])? in
            let under = override ? [] : auditsUnderWay(except: slug, sessions: sessions, starting: startingAudits)
            guard under.count >= cap else {
                startingAudits.insert(slug)
                return nil
            }
            return (under, heldAudits)
        } ?? ([], [])
        guard !under.isEmpty else { return }
        let ahead = held.firstIndex(of: slug).map { Array(held.prefix($0)) } ?? held.filter { $0 != slug }
        throw Problem(text: "\(not): " + Self.capText(cap: cap, under: under) + " Its place in line: " + Self.place(ahead)
                      + ". auto_advance starts the waiting ones in board order as one ends; otherwise audit(\(slug)) again once one's verdict is in, "
                      + "or audit(\(slug), override_heavy_slots: true) to start it now anyway.")
    }

    /// `slug`'s audit started (its verifier is on the board) or didn't: its place among those starting is free.
    func auditStarted(_ slug: String) {
        auditStarts.withLock { _ = startingAudits.remove(slug) }
    }

    /// The audits auto_advance holds for the cap now, in board order (what audit's refusal counts a place in line by).
    func holdAudits(_ slugs: [String]) {
        auditStarts.withLock { heldAudits = slugs }
    }

    /// "heavy_slots is 2, and 2 of this project's audits are under way (a, b)…".
    static func capText(cap: Int, under: [String]) -> String {
        "heavy_slots is \(cap), and \(under.count) of this project's audits \(under.count == 1 ? "is" : "are") under way (\(under.joined(separator: ", "))), "
            + "each with its build and test runs: another would only queue for the Mac's test slots with them and load the Mac for every review and merge."
    }

    /// "1st (none ahead of it)", "3rd, after a, b (board order)".
    static func place(_ ahead: [String]) -> String {
        let n = ahead.count + 1
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)" + (ahead.isEmpty ? " (none waits ahead of it)" : ", after \(ahead.joined(separator: ", ")) (board order)")
    }
}
