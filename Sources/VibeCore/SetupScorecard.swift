import Foundation

/// The weekly scorecard: how well the lead serves the user's goal, from exact data only (no model reads anything). Two
/// weeks side by side, the last 7 days (ending with the range: today) and the 7 before, each figure with its n:
/// - Origins: the tasks created in the week by `LeadTask.origin` (`LeadOrigins`): bugs the user reported against those
///   the system found.
/// - Questions per delivered task: the lead's questions to the user about the week's merges (whenever asked) and those
///   about no task asked in the week, per merge; and the minutes they waited on the user (`LeadScorecard`'s).
/// - Cost per merged task, with the lead's share: the receipts' estimated cost per merge whose cost is known, plus the
///   lead's own cost (`LeadTokenLedger`) on each day spread over that day's merges in its project. The lead's cost on
///   a day with no merge is said apart, not spread. Receipts never carry the lead's share.
/// - Time to install: from a task's creation to the first install that contained its merge commit, known from the
///   builds receipts record (`LeadReceipt.build`: the build that ran a later merge was installed by then, and holds
///   every commit its source commit descends from) and the installed app's own record (its commit, installed when its
///   copy is dated: `SetupInstalls.installedApp`); a merge no recorded build contains is "not installed yet".
///
/// A comparison between the weeks is said only when both have at least `trendFloor` (n); below it the figures are
/// shown with their n and no trend.
public struct SetupScorecard: Equatable, Sendable {
    public static let trendFloor = 10

    /// The last 7 days, and the 7 before.
    public var week: ScorecardWeek
    public var previous: ScorecardWeek
    /// The last 7 days' merges, latest first, each with its time to install (or not installed yet).
    public var installs: [ScorecardInstall]

    public init(week: ScorecardWeek, previous: ScorecardWeek, installs: [ScorecardInstall]) {
        self.week = week
        self.previous = previous
        self.installs = installs
    }
}

/// One week of the scorecard (see `SetupScorecard`).
public struct ScorecardWeek: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var origins = LeadOrigins()
    /// Merges in the week (`LeadScorecard.counts`): the n of questions, waiting and the lead's share.
    public var merged = 0
    public var questions = 0
    /// Minutes those questions waited on the user, in all; nil with no merge.
    public var userMinutes: Double?
    /// Merges whose receipt's cost is known (the n of the cost), and their cost summed.
    public var costed = 0
    public var cost = 0.0
    /// The lead's cost on the week's days that had a merge in its project (spread over those merges), and on its days
    /// with none (not spread); `leadUnpricedDays`: days with a model that has no price (their cost isn't in these);
    /// `leadKept`: a lead ledger covers some of the week.
    public var leadSpread = 0.0
    public var leadUnspread = 0.0
    public var leadUnpricedDays = 0
    public var leadKept = false
    /// Created → first install, seconds, of the week's merges a recorded build contains; and those none does.
    public var installTimes: [Double] = []
    public var notInstalled = 0

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var questionsPerTask: Double? { merged > 0 ? Double(questions) / Double(merged) : nil }
    public var userMinutesPerTask: Double? { merged > 0 ? userMinutes.map { $0 / Double(merged) } : nil }
    /// The receipts' cost per costed merge.
    public var receiptCostPerTask: Double? { costed > 0 ? cost / Double(costed) : nil }
    /// The lead's spread cost per merge; nil with no merge or no ledger.
    public var leadPerTask: Double? { merged > 0 && leadKept ? leadSpread / Double(merged) : nil }
    /// Receipts' cost per costed merge plus the lead's per merge; nil when no merge's cost is known.
    public var costPerTask: Double? { receiptCostPerTask.map { $0 + (leadPerTask ?? 0) } }
    public var medianInstall: Double? { SetupStatsMath.median(installTimes) }
}

/// One merge's time to install.
public struct ScorecardInstall: Equatable, Sendable, Identifiable {
    public var slug: String
    public var title: String
    public var createdAt: Double
    public var mergedAt: Double
    /// When the first recorded build containing its merge was seen installed; nil: not installed yet.
    public var installedAt: Double?
    public var id: String { slug }

    public init(slug: String, title: String, createdAt: Double, mergedAt: Double, installedAt: Double?) {
        self.slug = slug
        self.title = title
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.installedAt = installedAt
    }

    /// Created → installed, seconds; nil: not installed yet.
    public var toInstall: Double? { installedAt.map { max(0, $0 - createdAt) } }
}

/// When each merge was first seen installed, from the builds receipts record.
public enum SetupInstalls {
    /// A build as a receipt names it (`ServerBuild.label`): its source commit's first 12 characters, also "… with
    /// changes not committed" (a build of that commit plus edits: it holds that commit's history); nil for "unknown …".
    public static func commit(ofBuild label: String) -> String? {
        let first = label.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard first.count >= 7, first.count <= 64, first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }

    /// For each of `merges` (slug, merge commit), the earliest time a build containing its commit was seen running: a
    /// receipt's `build` at its merge's time (`seen`). `contains(build, commit)` says whether a build's commit descends
    /// from (or is) a merge commit; it's asked once per pair at most.
    public static func firstInstalls(merges: [(slug: String, commit: String)], seen: [(build: String, at: Double)],
                                     contains: (String, String) -> Bool) -> [String: Double] {
        let builds = seen.compactMap { observed in commit(ofBuild: observed.build).map { (build: $0, at: observed.at) } }.sorted { $0.at < $1.at }
        var found: [String: Double] = [:]
        var answers: [String: Bool] = [:]
        for merge in merges {
            for observed in builds {
                let key = observed.build + " " + merge.commit
                let holds = answers[key] ?? contains(observed.build, merge.commit)
                answers[key] = holds
                if holds {
                    found[merge.slug] = observed.at
                    break
                }
            }
        }
        return found
    }

    /// The install record the app carries: the build of the app running from /Applications (`ServerBuild.running`) and
    /// when it was installed (its executable's date: install-app.sh's copy dates it then); nil for any other process
    /// (tests, the sandbox, a build run from build/) or a build that recorded no commit.
    public static func installedApp(bundle: String = Bundle.main.bundlePath, build: ServerBuild? = ServerBuild.running) -> (build: String, at: Double)? {
        guard bundle.hasPrefix("/Applications/"), let build, let commit = build.commit, let at = build.builtAt else { return nil }
        return (String(commit.prefix(12)), at.timeIntervalSince1970)
    }

    /// `contains` for the repository at `root`, by git: the commits each build's history holds since `since` (a merge
    /// before it isn't asked about), read once per build. A build the repository doesn't have holds nothing.
    public static func gitContains(root: String, since: Double) -> (String, String) -> Bool {
        var histories: [String: Set<String>] = [:]
        return { build, commit in
            let history: Set<String>
            if let known = histories[build] {
                history = known
            } else {
                let result = Git.run(["rev-list"] + (since > 0 ? ["--since=\(Int(since))"] : []) + [build, "--"], in: root, timeout: 20)
                history = result.status == 0 ? Set(result.output.split(whereSeparator: \.isNewline).map { String($0).lowercased() }) : []
                histories[build] = history
            }
            let wanted = commit.lowercased()
            return history.contains(wanted) || (wanted.count < 40 && history.contains { $0.hasPrefix(wanted) })
        }
    }
}

extension SetupQualityMath {
    /// The scorecard of the two weeks ending at `weeks`' last two (see `SetupScorecard`). `dayKey` names a moment's
    /// local day as the lead ledger keys it ("2026-11-02"); `dayStart` the start of such a day (nil: not a day).
    static func scorecard(_ sources: [QualitySource], merges: [Merge], untasked: [LeadQuestion], questions: [LeadQuestion],
                          weeks: [DateInterval], now: Double, dayKey: (Double) -> String, dayStart: (String) -> Double?) -> SetupScorecard? {
        guard weeks.count >= 2 else { return nil }
        func week(_ span: DateInterval) -> ScorecardWeek {
            let t0 = span.start.timeIntervalSince1970, t1 = span.end.timeIntervalSince1970
            var w = ScorecardWeek(start: span.start, end: span.end)
            w.origins = LeadOrigins(sources.flatMap { $0.tasks.compactMap { view in view.createdAt.map { (createdAt: $0, origin: view.origin) } } },
                                    from: t0, to: t1)
            let mine = merges.filter { t0 <= $0.at && $0.at < t1 }
            let slugs = Set(mine.map(\.task.slug))
            let asked = questions.filter { slugs.contains($0.task ?? "") } + untasked.filter { t0 <= $0.askedAt && $0.askedAt < t1 }
            let card = scorecard(mine.map(\.task), questions: asked, now: now)
            w.merged = mine.count
            w.questions = asked.count
            w.userMinutes = card.userMinutesPerMergedTask.map { $0 * Double(max(1, card.merged)) }
            for merge in mine {
                if let cost = merge.view.receipt?.cost {
                    w.costed += 1
                    w.cost += cost
                }
                if let installed = merge.installedAt {
                    w.installTimes.append(max(0, installed - merge.task.createdAt))
                } else {
                    w.notInstalled += 1
                }
            }
            // The lead's cost per project and day: spread over the day's merges there, or said apart.
            for (index, source) in sources.enumerated() {
                guard let lead = source.leadDays else { continue }
                let mergeDays = Set(mine.filter { $0.source == index }.map { dayKey($0.at) })
                for (day, tally) in lead {
                    guard let start = dayStart(day), t0 <= start, start < t1 else { continue }
                    w.leadKept = true
                    if tally.unpriced { w.leadUnpricedDays += 1; continue }
                    if mergeDays.contains(day) { w.leadSpread += tally.cost } else { w.leadUnspread += tally.cost }
                }
            }
            return w
        }
        let last = weeks[weeks.count - 1]
        let installs = merges.filter { last.start.timeIntervalSince1970 <= $0.at && $0.at < last.end.timeIntervalSince1970 }
            .sorted { $0.at > $1.at }
            .map { ScorecardInstall(slug: String($0.task.slug.drop { $0 != "/" }.dropFirst()), title: $0.task.title, createdAt: $0.task.createdAt,
                                    mergedAt: $0.at, installedAt: $0.installedAt) }
        return SetupScorecard(week: week(last), previous: week(weeks[weeks.count - 2]), installs: installs)
    }
}
