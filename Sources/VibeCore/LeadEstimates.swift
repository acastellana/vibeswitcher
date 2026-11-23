import Foundation

/// A task's estimate (the web design of 2026-11-23, "Estimates (new in the node)"): minutes to done from when it was
/// given, likely and worst case, by the worker (its `progress`) or the lead (add_task, update_task).
public struct LeadEstimate: Codable, Equatable, Sendable {
    public enum By: String, Codable, Sendable { case worker, lead }
    public var likelyMin: Int
    public var worstMin: Int
    public var at: Double
    public var by: By

    public init(likelyMin: Int, worstMin: Int, at: Double = Date().timeIntervalSince1970, by: By) {
        self.likelyMin = likelyMin
        self.worstMin = worstMin
        self.at = at
        self.by = by
    }

    /// The most minutes an estimate says (a week).
    public static let mostMinutes = 7 * 24 * 60
}

/// A status a task took, and when (`BoardStore.update`).
public struct LeadStateStamp: Codable, Equatable, Sendable {
    public var status: LeadTask.Status
    public var at: Double

    public init(status: LeadTask.Status, at: Double) {
        self.status = status
        self.at = at
    }
}

extension LeadTask {
    /// The most estimates a task keeps (the first and the newest), and status stamps.
    public static let keptEstimates = 20
    public static let keptStates = 40

    /// `estimate` added: the first kept, then the newest.
    public mutating func add(_ estimate: LeadEstimate) {
        var list = (estimates ?? []) + [estimate]
        if list.count > Self.keptEstimates { list = [list[0]] + list.suffix(Self.keptEstimates - 1) }
        estimates = list
    }

    /// Its current status stamped at `at` (`BoardStore.update`, on each change).
    mutating func stamp(at: Double) {
        states = ((states ?? []) + [LeadStateStamp(status: status, at: at)]).suffix(Self.keptStates)
    }

    /// Minutes it spent blocked between `from` and `to` (its stamps; a blocked spell still open counts to `to`).
    public func blockedMinutes(from: Double, to: Double) -> Double {
        let stamps = states ?? []
        var total = 0.0
        for (index, stamp) in stamps.enumerated() where stamp.status == .blocked {
            let end = index + 1 < stamps.count ? stamps[index + 1].at : to
            total += max(0, min(end, to) - max(stamp.at, from))
        }
        return total / 60
    }

    /// Minutes from its first start to its merge, and those of them it wasn't blocked; nil when not merged or never started.
    public var actualMinutes: (total: Double, unblocked: Double)? {
        guard let start = startedAt, let merged = merged?.at, merged > start else { return nil }
        let total = (merged - start) / 60
        return (total, max(0, total - blockedMinutes(from: start, to: merged)))
    }
}

/// How this project's estimates compare with what happened, over its last `window` merged tasks that had one: the
/// median of actual minutes (time blocked excluded) over the first likely estimate, and the share that landed inside the
/// first worst case. The correction is that median, clamped to `clamp`; 1 under `enough` such tasks.
public struct LeadScore: Equatable, Sendable {
    public static let window = 20
    public static let enough = 5
    public static let clamp: ClosedRange<Double> = 0.5...5

    public var estimated: Int
    public var ratio: Double?
    public var insideWorst: Double?
    public var correction: Double
    public var clamped: Bool
    /// The median of the merged tasks' unblocked minutes (all merged, estimated or not; `enough` of them at least), for a
    /// task with no estimate.
    public var medianMinutes: Double?
    public var isEnough: Bool { estimated >= Self.enough }

    /// The line `status`, the board and `vibeswitcher board` say.
    public var line: String {
        guard isEnough, let ratio, let inside = insideWorst else {
            return "Estimates: fewer than \(Self.enough) estimated merges here (\(estimated)), so the dates are the workers' own, uncorrected."
        }
        let pace = abs(ratio - 1) < 0.05 ? "on time" : ratio > 1 ? String(format: "%.1f× over", ratio) : String(format: "%.1f× under", ratio)
        return "Estimates here run \(pace) (excluding time blocked); \(Int((inside * 100).rounded()))% land inside the worst case"
            + (clamped ? String(format: "; the dates are corrected by %.1f× at most (the bound)", correction) : ".")
    }
}

/// Where a task or goal is expected to land (all estimates: the worker's, corrected by this project's history).
public struct LeadLanding: Equatable, Sendable {
    public enum Basis: String, Sendable, CaseIterable {
        /// From its own estimate, corrected.
        case estimated
        /// From the project's median time to merge (it has no estimate).
        case median
        /// Finished: `likely` is when it merged.
        case done
        /// Blocked, failed or kept: no date; `waitsOn` says on whom.
        case blocked
        /// At work past its worst case: no date; `overdueMinutes` says by how much.
        case overdue
        /// A goal some of whose tasks have no date: `likely` is the least it lands.
        case partial
        /// Nothing to go by.
        case none
    }

    public var likely: Double?
    public var worst: Double?
    public var basis: Basis
    public var waitsOn: String?
    public var overdueMinutes: Int?
    /// At work past its likely estimate (inside its worst case).
    public var over: Bool = false
    /// A goal's tasks with no date.
    public var undated: Int = 0

    public init(likely: Double? = nil, worst: Double? = nil, basis: Basis, waitsOn: String? = nil, overdueMinutes: Int? = nil, over: Bool = false,
                undated: Int = 0) {
        self.likely = likely
        self.worst = worst
        self.basis = basis
        self.waitsOn = waitsOn
        self.overdueMinutes = overdueMinutes
        self.over = over
        self.undated = undated
    }
}

/// The forecast (computed once, in VibeCore, so the node's board value, `vibeswitcher board` and the lead's tools say the
/// same numbers): each task's landing, each goal's, and the score they are corrected by.
public enum LeadForecast {
    public struct Result: Equatable, Sendable {
        public var score: LeadScore
        public var tasks: [String: LeadLanding]
        public var goals: [String: LeadLanding]
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// The project's score from `board`'s merged tasks, the newest merges first.
    public static func score(_ board: LeadBoard) -> LeadScore {
        let merged = board.tasks.filter { $0.status == .done && $0.actualMinutes != nil }.sorted { ($0.merged?.at ?? 0) > ($1.merged?.at ?? 0) }
        let estimated = merged.filter { ($0.estimates?.first?.likelyMin ?? 0) > 0 }.prefix(LeadScore.window)
        let ratios = estimated.compactMap { task in task.actualMinutes.map { $0.unblocked / Double(task.estimates![0].likelyMin) } }
        let inside = estimated.filter { task in (task.actualMinutes?.unblocked ?? .infinity) <= Double(task.estimates![0].worstMin) }.count
        let ratio = median(ratios)
        let enough = estimated.count >= LeadScore.enough
        let raw = enough ? ratio ?? 1 : 1
        let correction = min(max(raw, LeadScore.clamp.lowerBound), LeadScore.clamp.upperBound)
        return LeadScore(estimated: estimated.count, ratio: ratio, insideWorst: estimated.isEmpty ? nil : Double(inside) / Double(estimated.count),
                         correction: correction, clamped: enough && correction != raw,
                         medianMinutes: merged.count >= LeadScore.enough ? median(merged.prefix(LeadScore.window).compactMap { $0.actualMinutes?.unblocked }) : nil)
    }

    /// Who a task that isn't at work waits on: the first task it comes after that isn't finished, else the user (a
    /// question names it), else its blocker's first line.
    static func waitsOn(_ task: LeadTask, board: LeadBoard) -> String {
        if let first = (task.after ?? []).first(where: { name in board.task(name).map { $0.unfinished } ?? false }) { return first }
        if board.openQuestions.contains(where: { $0.task == task.slug }) { return "you (a question)" }
        if task.status == .failed { return "the lead (it failed)" }
        if task.status == .kept { return "kept back by the lead" }
        let first = (task.blocker ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "something not said" : String(first.prefix(120))
    }

    /// Each task's and goal's landing on `board` at `now`, its queue run on `workers` slots.
    public static func forecast(_ board: LeadBoard, workers: Int, now: Double) -> Result {
        let score = score(board)
        let c = score.correction
        var landings: [String: LeadLanding] = [:]
        // The slots' free times, for the likely and the worst schedules.
        var likelySlots: [Double] = [], worstSlots: [Double] = []
        for task in board.tasks {
            switch task.status {
            case .done, .folded, .abandoned, .reverted:
                landings[task.slug] = LeadLanding(likely: task.merged?.at, worst: task.merged?.at, basis: .done)
            case .blocked, .failed, .kept:
                landings[task.slug] = LeadLanding(basis: .blocked, waitsOn: waitsOn(task, board: board))
            case .running, .review:
                var landing = LeadLanding(basis: .none)
                if let estimate = task.estimates?.last {
                    let elapsed = (now - estimate.at) / 60 - task.blockedMinutes(from: estimate.at, to: now)
                    let likely = Double(estimate.likelyMin) * c - elapsed, worst = Double(estimate.worstMin) * c - elapsed
                    if worst < 0 {
                        landing = LeadLanding(basis: .overdue, overdueMinutes: Int((-worst).rounded(.up)))
                    } else {
                        landing = LeadLanding(likely: now + max(0, likely) * 60, worst: now + worst * 60, basis: .estimated, over: likely < 0)
                    }
                } else if let median = score.medianMinutes, let start = task.startedAt {
                    let elapsed = (now - start) / 60 - task.blockedMinutes(from: start, to: now)
                    let likely = max(0, median * c - elapsed)
                    landing = LeadLanding(likely: now + likely * 60, worst: now + max(likely, median * c * 2 - elapsed) * 60, basis: .median)
                }
                landings[task.slug] = landing
                likelySlots.append(landing.likely ?? now)
                worstSlots.append(landing.worst ?? now)
            case .planned:
                break
            }
        }
        // The queue, in board order, each on the slot free first, after what it waits on.
        let slots = max(1, workers)
        while likelySlots.count < slots { likelySlots.append(now); worstSlots.append(now) }
        for task in board.tasks where task.status == .planned {
            var after: [LeadLanding] = []
            var undated: String?
            for name in task.after ?? [] {
                guard let other = board.task(name), other.unfinished else { continue }
                guard let landing = landings[other.slug], landing.likely != nil, landing.basis != .done else { undated = other.slug; break }
                after.append(landing)
            }
            if let undated {
                landings[task.slug] = LeadLanding(basis: .blocked, waitsOn: undated)
                continue
            }
            let own = task.estimates?.last.map { (Double($0.likelyMin) * c, Double($0.worstMin) * c, LeadLanding.Basis.estimated) }
                ?? score.medianMinutes.map { ($0 * c, $0 * c * 2, LeadLanding.Basis.median) }
            guard let (likely, worst, basis) = own else {
                landings[task.slug] = LeadLanding(basis: .none)
                continue
            }
            let freeLikely = likelySlots.indices.min { likelySlots[$0] < likelySlots[$1] }!
            let freeWorst = worstSlots.indices.min { worstSlots[$0] < worstSlots[$1] }!
            let startLikely = ([likelySlots[freeLikely]] + after.compactMap(\.likely)).max()!
            let startWorst = ([worstSlots[freeWorst]] + after.compactMap(\.worst)).max()!
            let landing = LeadLanding(likely: startLikely + likely * 60, worst: startWorst + worst * 60, basis: basis)
            likelySlots[freeLikely] = landing.likely!
            worstSlots[freeWorst] = landing.worst!
            landings[task.slug] = landing
        }
        // A goal lands with its last task; with some undated, at least then.
        var goals: [String: LeadLanding] = [:]
        for goal in board.goals ?? [] {
            let mine = board.tasks.filter { $0.goalID == goal.id }
            guard !mine.isEmpty else { goals[goal.id] = LeadLanding(basis: .none); continue }
            let open = mine.filter(\.unfinished)
            if open.isEmpty {
                let last = mine.compactMap { landings[$0.slug]?.likely }.max()
                goals[goal.id] = LeadLanding(likely: last, worst: last, basis: .done)
                continue
            }
            let dated = open.compactMap { landings[$0.slug] }.filter { $0.likely != nil && $0.basis != .done }
            let undated = open.count - dated.count
            goals[goal.id] = dated.isEmpty ? LeadLanding(basis: .none, undated: undated)
                : LeadLanding(likely: dated.compactMap(\.likely).max(), worst: dated.compactMap(\.worst).max(), basis: undated > 0 ? .partial : .estimated,
                              undated: undated)
        }
        return Result(score: score, tasks: landings, goals: goals)
    }

    /// The line a lead's tool result carries for a task at work past its worst case, once a task an estimate (the
    /// board stamps `overdueTold`): ask its worker for a new estimate. Nil when none is.
    public static func overdueLine(_ board: LeadBoard, result: Result) -> (line: String, tasks: [(String, Double)])? {
        let due = board.tasks.compactMap { task -> (LeadTask, Int, Double)? in
            guard let estimate = task.estimates?.last, task.overdueTold != estimate.at, let landing = result.tasks[task.slug], landing.basis == .overdue,
                  let minutes = landing.overdueMinutes else { return nil }
            return (task, minutes, estimate.at)
        }
        guard !due.isEmpty else { return nil }
        let named = due.prefix(5).map { "\($0.0.slug) (by \($0.1) min)" }.joined(separator: ", ")
        return ("Estimates: past the worst case: \(named). Ask \(due.count == 1 ? "its worker" : "each worker") for a new estimate (message): progress with likely_min and worst_min.",
                due.map { ($0.0.slug, $0.2) })
    }

    /// A landing as one line: "lands ~14:30 (by 16:00)", "no date: waits on X", "past its worst case by N min".
    public static func text(_ landing: LeadLanding, now: Double, calendar: Calendar = .current) -> String? {
        func when(_ at: Double) -> String {
            let date = Date(timeIntervalSince1970: at)
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.dateFormat = calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now)) ? "HH:mm" : "EEE d MMM HH:mm"
            return format.string(from: date)
        }
        switch landing.basis {
        case .estimated, .median, .partial:
            guard let likely = landing.likely else { return nil }
            let range = landing.worst.map { " (by \(when($0)))" } ?? ""
            let note = landing.basis == .median ? ", by this project's median" : landing.over ? ", over its likely estimate" : ""
            return (landing.basis == .partial ? "lands at least ~" : "lands ~") + when(likely) + range + note
                + (landing.undated > 0 ? "; \(landing.undated) task\(landing.undated == 1 ? "" : "s") with no date" : "")
        case .blocked: return "no date: waits on \(landing.waitsOn ?? "something not said")"
        case .overdue: return "past its worst case by \(landing.overdueMinutes ?? 0) min"
        case .done, .none: return nil
        }
    }
}

extension LeadToolset {
    /// `likely_min` and `worst_min` given to progress, add_task or update_task: nil when neither was; both, whole minutes,
    /// 1 ≤ likely ≤ worst ≤ a week, else refused.
    static func estimateArgument(_ arguments: [String: Any], by: LeadEstimate.By) throws -> LeadEstimate? {
        func minutes(_ key: String) throws -> Int? {
            guard let given = arguments[key], !(given is NSNull) else { return nil }
            if let number = given as? Int { return number }
            if let number = given as? Double, number == number.rounded() { return Int(number) }
            if let text = given as? String, let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
            throw Problem(text: "\(key) is a whole number of minutes, not \(given). Nothing was changed.")
        }
        let likely = try minutes("likely_min"), worst = try minutes("worst_min")
        guard likely != nil || worst != nil else { return nil }
        guard let likely, let worst else { throw Problem(text: "Give likely_min and worst_min together (minutes to done from now). Nothing was changed.") }
        guard likely >= 1, worst >= likely, worst <= LeadEstimate.mostMinutes else {
            throw Problem(text: "An estimate is 1 ≤ likely_min ≤ worst_min ≤ \(LeadEstimate.mostMinutes) minutes, not \(likely) and \(worst). Nothing was changed.")
        }
        return LeadEstimate(likelyMin: likely, worstMin: worst, by: by)
    }

    /// `likely_min` and `worst_min` for the tools' schemas.
    static var likelyProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "integer", description: "Your likely estimate: minutes to done from now (with worst_min)")
    }
    static var worstProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "integer", description: "The worst case: minutes to done from now, at least likely_min")
    }

    /// The line a lead's tool result carries while a task at work ran past its worst case (once a task an estimate).
    func overdueNotice() -> String? {
        let board = store.load()
        let now = Date().timeIntervalSince1970
        let result = LeadForecast.forecast(board, workers: maxWorkers(workflow), now: now)
        guard let (line, due) = LeadForecast.overdueLine(board, result: result) else { return nil }
        _ = try? store.update { board in
            for (slug, at) in due { if let index = board.taskIndex(slug) { board.tasks[index].overdueTold = at } }
        }
        return line
    }
}
