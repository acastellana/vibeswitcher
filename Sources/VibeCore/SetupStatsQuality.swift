import Foundation

/// How well the setup is doing, not just how much happened: quality, autonomy, where the time goes and what it cost,
/// over the tasks merged in the range (every project's), broken down by who did the work, with an 8-week trend. Read
/// only from what VibeSwitcher already keeps: board.json and board-archive.jsonl (each task's audits, findings,
/// answers, re-rolls, notes, receipt and launchedModels; the board's questions), the incidents record and the load
/// recorder's merges-<day>.jsonl.
///
/// The definitions:
/// - A merge here is a task the scorecard counts (`LeadScorecard.counts`: merged, not folded or abandoned) whose
///   `merged.at` is in the range. First-audit pass rate, mean rounds to pass, reverts and the user's minutes per
///   merged task are `LeadScorecard`'s, worked out over those merges (and the questions below), never redefined here.
/// - The questions counted are those about one of the merges (whenever asked) and, for all merges together, the
///   questions about no task asked in the range: a question about no task belongs to no agent or model.
/// - A merge passed first try when its first line in the merges recorder (from 14 days before the range) passed with
///   no rerun, and its receipt counts no merge rerun: no failed run, no conflict, no send-back before it landed.
/// - An escape is a merge since reverted, or one an incident names (`Task: <slug>`) recorded after it merged.
/// - Needed nobody: no question to the user about it, no message from the lead to its worker after its first start,
///   and no re-roll.
/// - Time: created → merged; the worker's share of it is the merges' working time summed over their created → merged
///   summed, of the merges whose working time is known. Parallelism: the worker hours of the receipts that ended in
///   the range over the wall-clock hours from start to end of any of them.
/// - Cost: the receipts of the merges whose cost is known, worker (implementation) and verifier (verification).
/// - Who: Codex when a Codex worker worked on it (`codexWorked`, or agent codex), else Claude; the model is the one
///   its worker session was started on (`launchedModels`), by family.
///
/// A figure whose inputs aren't kept is nil ("Not recorded"), never 0.
public struct SetupQuality: Equatable, Sendable {
    /// Every project's merges in the range.
    public var all: QualityFigures
    /// Claude, then Codex.
    public var byAgent: [QualityGroup]
    /// Claude's merges by their worker's model: fable, opus, sonnet, haiku, then any other by name; merges whose model
    /// isn't recorded are in none. Empty when none is recorded.
    public var byModel: [QualityGroup]
    /// The 8 weeks (7 days each) up to the range's end, oldest first.
    public var weeks: [QualityWeek]

    public init(all: QualityFigures, byAgent: [QualityGroup], byModel: [QualityGroup], weeks: [QualityWeek]) {
        self.all = all
        self.byAgent = byAgent
        self.byModel = byModel
        self.weeks = weeks
    }
}

/// One breakdown's merges: "Claude", "Codex", "fable"…
public struct QualityGroup: Equatable, Sendable {
    public var name: String
    public var figures: QualityFigures

    public init(name: String, figures: QualityFigures) {
        self.name = name
        self.figures = figures
    }
}

/// One week of the trend.
public struct QualityWeek: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var merged: Int
    /// `LeadScorecard`'s, over the week's merges; nil with no audited merge.
    public var firstAuditPassRate: Double?
    /// Over the week's merges whose cost is known; nil with none.
    public var costPerMergedTask: Double?

    public init(start: Date, end: Date, merged: Int, firstAuditPassRate: Double?, costPerMergedTask: Double?) {
        self.start = start
        self.end = end
        self.merged = merged
        self.firstAuditPassRate = firstAuditPassRate
        self.costPerMergedTask = costPerMergedTask
    }
}

/// What became of the findings the merges' audits raised (unconfirmed ones left out).
public struct FindingOutcomes: Equatable, Sendable {
    /// A later audit saw it fixed by the worker.
    public var fixed = 0
    /// The worker disagreed (answer_findings) and the verifier accepted it: dismissed by the verifier.
    public var disagreementAccepted = 0
    /// Dismissed by a verifier with no disagreement from the worker.
    public var dismissedByVerifier = 0
    /// Dismissed by the lead, with a reason.
    public var dismissedByLead = 0
    /// Dismissed by the lead into a task of its own (add_task from_finding).
    public var movedToTask = 0
    /// Still open when it merged (Nits, Pre-existing).
    public var leftOpen = 0
    /// Of all of them, the Important ones.
    public var important = 0

    public var total: Int { fixed + disagreementAccepted + dismissedByVerifier + dismissedByLead + movedToTask + leftOpen }

    public init(fixed: Int = 0, disagreementAccepted: Int = 0, dismissedByVerifier: Int = 0, dismissedByLead: Int = 0, movedToTask: Int = 0,
                leftOpen: Int = 0, important: Int = 0) {
        self.fixed = fixed
        self.disagreementAccepted = disagreementAccepted
        self.dismissedByVerifier = dismissedByVerifier
        self.dismissedByLead = dismissedByLead
        self.movedToTask = movedToTask
        self.leftOpen = leftOpen
        self.important = important
    }
}

/// The merges the merges recorder saw, and those that passed first try.
public struct MergeFirstTry: Equatable, Sendable {
    public var counted: Int
    public var firstTry: Int
    public var rate: Double? { counted > 0 ? Double(firstTry) / Double(counted) : nil }

    public init(counted: Int, firstTry: Int) {
        self.counted = counted
        self.firstTry = firstTry
    }
}

/// The project lead's own tokens and their estimated cost over a range (`LeadTokenLedger`).
public struct LeadSpend: Equatable, Sendable {
    public var tokens: Int
    /// The cost of its days whose cost is known; nil when none's is.
    public var cost: Double?
    /// Its days with a model `LeadPrices` has no price for: their cost isn't in `cost`.
    public var unpricedDays: Int
    /// Part of the range isn't covered: a ledger began after the range started, or a project keeps none for it.
    public var partial: Bool

    public init(tokens: Int, cost: Double?, unpricedDays: Int, partial: Bool = false) {
        self.tokens = tokens
        self.cost = cost
        self.unpricedDays = unpricedDays
        self.partial = partial
    }
}

/// The figures of a set of merges (see `SetupQuality` for the definitions).
public struct QualityFigures: Equatable, Sendable {
    // MARK: Quality

    public var merged = 0
    /// Merges whose audit rounds to pass are known (`LeadScorecard.counted`).
    public var audited = 0
    /// `LeadScorecard`'s, 0…1; nil with no audited merge.
    public var firstAuditPassRate: Double?
    public var meanRoundsToPass: Double?
    /// The audited merges' Important findings (`LeadTaskScore.importantFindings`).
    public var importantFindings = 0
    public var importantPerAudited: Double? { audited > 0 ? Double(importantFindings) / Double(audited) : nil }
    /// Nil when no merge's audits are kept.
    public var findings: FindingOutcomes?
    /// Nil when the merges recorder has no line for any of the merges.
    public var mergeFirstTry: MergeFirstTry?
    public var rerolls = 0
    /// `LeadScorecard.reverts`: merges since reverted.
    public var reverts = 0
    /// Merges since reverted or named by a later incident.
    public var escapes = 0

    // MARK: Autonomy

    /// The lead's questions to the user counted (see `SetupQuality`).
    public var questions = 0
    public var questionsPerMergedTask: Double? { merged > 0 ? Double(questions) / Double(merged) : nil }
    /// `LeadScorecard`'s: the minutes those questions waited on the user, over the merges.
    public var userMinutesPerMergedTask: Double?
    /// Merges with no question, no lead message to the worker after its start, and no re-roll.
    public var neededNobody = 0
    public var neededNobodyShare: Double? { merged > 0 ? Double(neededNobody) / Double(merged) : nil }

    // MARK: Where time goes

    /// Created → merged of each merge, in seconds, in merge order.
    public var createdToMerged: [Double] = []
    public var medianCreatedToMerged: Double? { SetupStatsMath.median(createdToMerged) }
    public var p90CreatedToMerged: Double? { SetupStatsMath.p90(createdToMerged) }
    /// Of the merges whose working time is known: how many, their created → merged and working time summed (seconds).
    public var timed = 0
    public var timedSpan = 0.0
    public var timedWorked = 0.0
    /// The worker's working time's share of created → merged; nil when no merge's working time is known.
    public var workingShare: Double? { timedSpan > 0 ? min(1, timedWorked / timedSpan) : nil }
    /// Of the merges whose working time is known, those whose receipt keeps its waits (`LeadWaits`): how many, their
    /// created → merged summed, and their waits for an audit to start summed (seconds).
    public var waited = 0
    public var waitedSpan = 0.0
    public var auditWaited = 0.0
    /// Waiting for its audit: the audit waits' share of created → merged, over the merges whose waits are kept; nil
    /// when none's are (receipts from before they were kept): then in the rest.
    public var auditWaitShare: Double? { waitedSpan > 0 ? min(1, auditWaited / waitedSpan) : nil }
    /// The rest (planning, queueing, audits, merging), audit waits included while they aren't recorded.
    public var restShare: Double? { workingShare.map { max(0, 1 - $0 - (auditWaitShare ?? 0)) } }
    /// Worker hours of the receipts that ended in the range, and the wall-clock hours any of them ran.
    public var workerHours = 0.0
    public var busyHours = 0.0
    public var parallelism: Double? { busyHours > 0 ? workerHours / busyHours : nil }
    /// Verifier hours of those receipts (`LeadWaits.verifierTime`: each audit's time times its sessions); nil when none
    /// of them kept it.
    public var verifierHours: Double?

    // MARK: Cost

    /// The merges whose cost is known, their cost, and its worker and verifier parts.
    public var costed = 0
    public var cost = 0.0
    public var workerCost = 0.0
    public var verifierCost = 0.0
    public var costPerMergedTask: Double? { costed > 0 ? cost / Double(costed) : nil }
    public var implementationShare: Double? { cost > 0 ? workerCost / cost : nil }
    public var verificationShare: Double? { cost > 0 ? verifierCost / cost : nil }
    /// The merges' test reruns' cost: nil, not recorded (receipts count a rerun, not what it cost).
    public var mergeRerunCost: Double?
    /// The merges' workers' Codex tokens (`LeadTokens.codex`): not in the cost (`LeadPrices` has no Codex price); nil
    /// when no merge's receipt read any.
    public var codexTokens: Int?
    /// The project lead's own spend on the range's days, every project's (`ProjectFigures.leadTokens`): only on
    /// `SetupQuality.all`, since the lead works for every agent's tasks; nil there when no lead's ledger covers the range.
    public var lead: LeadSpend?

    // MARK: Inputs of the comparison with working solo (see SetupStatsCompared.swift)

    /// Merges whose audits are kept, and the Important findings among them a later audit saw fixed.
    public var auditsKept = 0
    public var importantFixed = 0
    /// Of the merges the merges recorder saw (`mergeFirstTry.counted`), those whose first line failed its tests and
    /// landed later: sent back, not passed on a rerun (a flake).
    public var sentBack = 0
    /// The flake ledger's entries in the range about these merges' tasks (each a flaky test a rerun caught); nil when
    /// no project keeps a ledger.
    public var flakesCaught: Int?
    /// Merges named by an incident recorded after they merged.
    public var incidents = 0
    /// The solo baseline's merges: cost known, no re-roll, their workers' tokens all priced (no Codex worker); their
    /// workers' cost, their verifiers', and those of them whose merge's tests were rerun.
    public var soloMerges = 0
    public var soloWorkerCost = 0.0
    public var soloVerifierCost = 0.0
    public var soloReran = 0
    /// Merges with a known cost left out of the baseline: re-rolled (their workers' tokens aren't split by attempt),
    /// and worked by Codex (its tokens have no price).
    public var rerolledLeftOut = 0
    public var codexLeftOut = 0

    public init() {}
}

extension SetupStatsMath {
    /// As load-report.sh takes it: the sorted values' element at 90 % of their count.
    static func p90(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(0.9 * Double(sorted.count)))]
    }

    /// The hours covered by `spans` (start, end in seconds), overlaps counted once.
    static func covered(_ spans: [(Double, Double)]) -> Double {
        var total = 0.0, current: (Double, Double)?
        for (start, end) in spans.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            if let open = current, start <= open.1 {
                current = (open.0, max(open.1, end))
            } else {
                if let open = current { total += open.1 - open.0 }
                current = (start, end)
            }
        }
        if let open = current { total += open.1 - open.0 }
        return total / 3600
    }

    /// "fable", "opus", "sonnet", "haiku", or the name as recorded; nil for Claude's default ("") and Codex's.
    static func family(_ model: String?) -> String? {
        guard let name = model?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty, !name.hasPrefix("codex") else { return nil }
        return families.first { name.contains($0) } ?? name
    }

    static let families = ["fable", "opus", "sonnet", "haiku"]
}

// MARK: - The work, on the collector's queue

/// One project's part: its tasks (each once), its questions, its incidents by task slug, its folder name.
struct QualitySource {
    var name: String
    var tasks: [TaskView]
    var questions: [LeadQuestion]
    /// When each incident naming a task was recorded, by the task's slug.
    var incidents: [String: [Double]]
    /// Its flake ledger: each entry's task and when; nil when its board keeps none.
    var flakes: [(task: String, at: Double?)]?
}

enum SetupQualityMath {
    /// One merge, its task's slug made unique across projects ("<project index>/<slug>", its questions' too).
    struct Merge {
        var task: LeadTask
        var view: TaskView
        var at: Double
        var codex: Bool
        var model: String?
        var firstTry: Bool?
        /// Its first line in the merges recorder failed its tests (it was sent back); nil: no line.
        var sentBack: Bool?
        var escaped: Bool
        var incident: Bool
        var neededNobody: Bool
    }

    /// A receipt that ended: who worked, from when to when, and the working time.
    struct Ended {
        var codex: Bool
        var model: String?
        var start: Double?
        var end: Double
        var worked: Double
        /// Its verifiers' time (`LeadWaits.verifierTime`), seconds; nil when not kept.
        var verifier: Double?
    }

    /// The figures of `sources` for `window`; `merges` the recorder's lines by project name and task slug, oldest
    /// first (nil: no recorder file for those days); `weeks` the trend's.
    static func quality(_ sources: [QualitySource], window: SetupStatsCollector.Window, weeks: [DateInterval],
                        mergeLines: [String: [String: [RecorderLine]]]?) -> SetupQuality {
        var merges: [Merge] = [], ended: [Ended] = []
        var questions: [LeadQuestion] = [], untasked: [LeadQuestion] = []
        // Every task's worker (made unique as merges' are), for the flake ledger's entries; and those entries in the range.
        var who: [String: (codex: Bool, model: String?)] = [:], flakes: [String]?
        for (index, source) in sources.enumerated() {
            let prefix = "\(index)/"
            for var question in source.questions {
                if let task = question.task {
                    question.task = prefix + task
                    questions.append(question)
                } else if window.within(question.askedAt) {
                    untasked.append(question)
                }
            }
            let askedAbout = Set(source.questions.compactMap(\.task))
            if let ledger = source.flakes {
                flakes = (flakes ?? []) + ledger.filter { window.within($0.at) }.map { prefix + $0.task }
            }
            for view in source.tasks {
                guard var task = view.lead else { continue }
                let slug = task.slug
                task.slug = prefix + slug
                let model = SetupStatsMath.family(task.worker.flatMap { task.launchedModels?[$0] })
                who[task.slug] = (view.codex, model)
                // A receipt whose working time wasn't counted has no worker hours to put over its span: left out.
                if let receipt = view.receipt, window.within(receipt.endedAt), let worked = task.receipt?.worked ?? task.worked {
                    ended.append(Ended(codex: view.codex, model: model, start: receipt.startedAt ?? view.startedAt, end: receipt.endedAt!,
                                       worked: worked, verifier: receipt.waits?.verifierTime))
                }
                guard LeadScorecard.counts(task), let at = task.merged?.at else { continue }
                let lines = mergeLines.map { $0[source.name]?[slug] ?? [] }
                let first = lines.flatMap { $0.first }
                let firstTry = first.map { $0.result == "passed" && $0.firstRun != "failed" && (view.receipt?.mergeReruns ?? 0) == 0 }
                let sentBack = first.map { $0.result == "failed" && $0.firstRun != "passed" }
                let reverted = task.merged?.revertedBy != nil || task.status == .reverted
                let incident = source.incidents[slug]?.contains { $0 >= at } ?? false
                let began = task.startedAt ?? task.createdAt
                let asked = askedAbout.contains(slug)
                let messaged = task.notes?.contains { $0.kind == .message && $0.at > began } ?? false
                let rerolled = max(task.rerolls?.count ?? 0, task.receipt?.rerolls ?? 0) > 0
                merges.append(Merge(task: task, view: view, at: at, codex: view.codex, model: model, firstTry: firstTry, sentBack: sentBack,
                                    escaped: reverted || incident, incident: incident, neededNobody: !asked && !messaged && !rerolled))
            }
        }
        merges.sort { $0.at < $1.at }
        let inRange = merges.filter { window.within($0.at) }
        let slugs = Set(inRange.map(\.task.slug))
        let about = questions.filter { slugs.contains($0.task ?? "") }
        func group(_ keep: (Bool, String?) -> Bool, untasked extra: [LeadQuestion] = [], everyone: Bool = false) -> QualityFigures {
            let mine = inRange.filter { keep($0.codex, $0.model) }
            let tasks = Set(mine.map(\.task.slug))
            var f = figures(mine, ended: ended.filter { keep($0.codex, $0.model) },
                            questions: about.filter { tasks.contains($0.task ?? "") } + extra, now: window.now)
            // A flake whose task isn't on the board any more is no agent's: in everyone's only.
            f.flakesCaught = flakes?.filter { slug in everyone || who[slug].map { keep($0.codex, $0.model) } == true }.count
            return f
        }
        let all = group({ _, _ in true }, untasked: untasked, everyone: true)
        let byAgent = [QualityGroup(name: "Claude", figures: group { codex, _ in !codex }),
                       QualityGroup(name: "Codex", figures: group { codex, _ in codex })]
        let models = Set(inRange.filter { !$0.codex }.compactMap(\.model))
        let ordered = SetupStatsMath.families.filter(models.contains) + models.subtracting(SetupStatsMath.families).sorted()
        let byModel = ordered.map { name in QualityGroup(name: name, figures: group { codex, model in !codex && model == name }) }
        let trend = weeks.map { week -> QualityWeek in
            let mine = merges.filter { week.start.timeIntervalSince1970 <= $0.at && $0.at < week.end.timeIntervalSince1970 }
            let card = scorecard(mine.map(\.task), questions: [], now: window.now)
            let costs = mine.compactMap { $0.view.receipt?.cost }
            return QualityWeek(start: week.start, end: week.end, merged: mine.count, firstAuditPassRate: card.firstAuditPassRate,
                               costPerMergedTask: costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count))
        }
        return SetupQuality(all: all, byAgent: byAgent, byModel: byModel, weeks: trend)
    }

    /// `LeadScorecard` over `tasks` and `questions` alone: its definitions, for a range's merges.
    static func scorecard(_ tasks: [LeadTask], questions: [LeadQuestion], now: Double) -> LeadScorecard {
        var board = LeadBoard()
        board.tasks = tasks
        board.questions = questions
        return LeadScorecard(board, now: now)
    }

    static func figures(_ merges: [Merge], ended: [Ended], questions: [LeadQuestion], now: Double) -> QualityFigures {
        var f = QualityFigures()
        let card = scorecard(merges.map(\.task), questions: questions, now: now)
        f.merged = card.merged
        f.audited = card.counted
        f.firstAuditPassRate = card.firstAuditPassRate
        f.meanRoundsToPass = card.meanRoundsToPass
        f.userMinutesPerMergedTask = card.userMinutesPerMergedTask
        f.reverts = card.reverts
        f.questions = questions.count
        var outcomes: FindingOutcomes?
        var counted = 0, firstTry = 0
        for merge in merges {
            let task = merge.task
            let score = LeadTaskScore(task, questions: [], now: now)
            if score.roundsToPass != nil { f.importantFindings += score.importantFindings }
            if let audits = task.audits {
                var o = outcomes ?? FindingOutcomes()
                let disagreed = Set((task.answers ?? []).filter { $0.kind == .disagree }.map { $0.id.uppercased() })
                for finding in audits.findings where finding.status != .unconfirmed {
                    if finding.severity == .important { o.important += 1 }
                    switch finding.status {
                    case .fixed: o.fixed += 1
                    case .open, .unconfirmed: o.leftOpen += 1
                    case .dismissed:
                        if finding.followUp != nil { o.movedToTask += 1 }
                        else if finding.closedBy == "lead" { o.dismissedByLead += 1 }
                        else if disagreed.contains(finding.id.uppercased()) { o.disagreementAccepted += 1 }
                        else { o.dismissedByVerifier += 1 }
                    }
                }
                outcomes = o
            }
            if let passed = merge.firstTry {
                counted += 1
                if passed { firstTry += 1 }
            }
            if merge.sentBack == true { f.sentBack += 1 }
            if let audits = task.audits {
                f.auditsKept += 1
                f.importantFixed += audits.findings.filter { $0.severity == .important && $0.status == .fixed }.count
            }
            if merge.incident { f.incidents += 1 }
            f.rerolls += max(task.rerolls?.count ?? 0, task.receipt?.rerolls ?? 0)
            if merge.escaped { f.escapes += 1 }
            if merge.neededNobody { f.neededNobody += 1 }
            let span = max(0, merge.at - task.createdAt)
            f.createdToMerged.append(span)
            if let worked = task.receipt?.worked ?? task.worked {
                f.timed += 1
                f.timedSpan += span
                f.timedWorked += worked
                if let waits = merge.view.receipt?.waits {
                    f.waited += 1
                    f.waitedSpan += span
                    f.auditWaited += waits.auditWait ?? 0
                }
            }
            if let codex = merge.view.receipt?.worker?.codex { f.codexTokens = (f.codexTokens ?? 0) + codex }
            if let receipt = merge.view.receipt, let cost = receipt.cost {
                f.costed += 1
                f.cost += cost
                f.workerCost += receipt.worker?.cost ?? 0
                f.verifierCost += receipt.verifier?.cost ?? 0
                let rerolled = max(task.rerolls?.count ?? 0, task.receipt?.rerolls ?? 0, receipt.rerolls) > 0
                if merge.codex || (receipt.worker?.codex ?? 0) > 0 {
                    f.codexLeftOut += 1
                } else if rerolled {
                    f.rerolledLeftOut += 1
                } else {
                    f.soloMerges += 1
                    f.soloWorkerCost += receipt.worker?.cost ?? 0
                    f.soloVerifierCost += receipt.verifier?.cost ?? 0
                    if receipt.mergeReruns > 0 { f.soloReran += 1 }
                }
            }
        }
        f.findings = outcomes
        f.mergeFirstTry = counted > 0 ? MergeFirstTry(counted: counted, firstTry: firstTry) : nil
        f.busyHours = SetupStatsMath.covered(ended.compactMap { e in e.start.map { ($0, e.end) } })
        // Worker hours of receipts with no start have no wall-clock span to go over: left out of both.
        f.workerHours = ended.filter { $0.start != nil }.reduce(0) { $0 + $1.worked } / 3600
        let verifiers = ended.compactMap(\.verifier)
        f.verifierHours = verifiers.isEmpty ? nil : verifiers.reduce(0, +) / 3600
        return f
    }

    /// The incidents in `markdown` (`## <stamp> <what>`, a `Task: <slug>` line below) by the slug they name.
    static func incidents(_ markdown: String) -> [String: [Double]] {
        var found: [String: [Double]] = [:]
        for incident in LeadDecision.parse(markdown) {
            for line in incident.why.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("Task:") else { continue }
                let slug = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if !slug.isEmpty { found[slug, default: []].append(incident.at) }
            }
        }
        return found
    }
}
