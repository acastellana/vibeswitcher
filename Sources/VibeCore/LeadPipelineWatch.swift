import Foundation

/// The pipeline watch's side in the lead's tool server (`LeadPipeline`): what it sees of the Mac and the repository,
/// the report to the lead, and status's line. auto_advance looks after each run of passes and arms the next look
/// (`LeadAdvance.watchPipeline`), so a stall is seen within minutes though nothing in the project's folder changes.
extension LeadToolset {
    /// What may hold the merges, as VibeSwitcher sees it now (`LeadPipeline.Signals`).
    func pipelineSignals(_ workflow: LeadWorkflow, now: Date) -> LeadPipeline.Signals {
        var signals = LeadPipeline.Signals()
        let base = workflow.base
        signals.head = branchHead(base)
        signals.mainRedHolds = store.load().mainRed.map { $0.all && !mainRedLifted($0) } ?? false
        // The records as the base has them: what every merge's run tests.
        let lints = recordLints()
        if let dir = workflow.recordsDir, !lints.isEmpty {
            for path in LeadRecords.paths(dir) {
                let read = Git.run(["show", "refs/heads/\(base):\(path)"], in: root)
                guard read.ok else { continue }
                for (number, line) in read.output.components(separatedBy: "\n").enumerated() {
                    for problem in RecordLint.problems(in: line, lints: lints) {
                        signals.records.append("\(path):\(number + 1) (\(problem.prefix { $0 != ":" }))")
                    }
                }
            }
        }
        if let lock = heavyLock(workflow) {
            let holders = lock.holders()
            if holders.count >= lock.slots {
                signals.slotsHeld = (lock.slots, TestLock.text(holders, for: root, now: now))
            }
        }
        let limits = macLimits()
        if let load = runtime.steadyLoad(), load > limits.loadLimit { signals.loadHold = (load, limits.loadLimit) }
        signals.gateLag = gateLag(workflow)?.text(base: base)
        // A merge into the base under way (its lock held), and since when (as it noted when it took the lock).
        let baseLock = LeadRecords.baseLock(vault: vault, root: root, base: base)
        if let lock = FileLock.attempt(baseLock.path) {
            lock.release()
        } else {
            let noted = mergeStarted()
            let tasks = noted?.tasks ?? store.load().tasks.filter { $0.status == .review && mergeUnderWay($0.slug) }.map(\.slug)
            signals.merging = (tasks.isEmpty ? ["a task"] : tasks, noted?.at ?? now)
        }
        signals.recentDurations = recentMergeDurations()
        signals.lastMerge = lastMerge()
        return signals
    }

    /// When the last merge landed, archived tasks' too.
    func lastMerge() -> Date? {
        store.loadAll().tasks.compactMap { $0.merged?.at }.max().map { Date(timeIntervalSince1970: $0) }
    }

    private var mergeStartedFile: URL { URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("run/merge-started")) }

    /// A merge of `tasks` into the base took its lock now: the watch says since when it runs.
    func noteMergeStarted(_ tasks: [String], at: Date = Date()) {
        try? VibePaths.ensurePrivate(mergeStartedFile.deletingLastPathComponent())
        try? VibePaths.writePrivate(Data(("\(at.timeIntervalSince1970)\n" + tasks.joined(separator: "\n") + "\n").utf8), to: mergeStartedFile)
    }

    /// The merge last noted started, and its tasks.
    func mergeStarted() -> (at: Date, tasks: [String])? {
        guard let text = try? String(contentsOf: mergeStartedFile, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard let first = lines.first, let at = Double(first) else { return nil }
        return (Date(timeIntervalSince1970: at), Array(lines.dropFirst()))
    }

    /// The durations of this project's last merges that passed (the Mac's merge stats), newest last, at most 10.
    func recentMergeDurations() -> [Double] {
        guard let folder = mergeStats(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let project = (root as NSString).lastPathComponent
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var durations: [Double] = []
        for name in names.filter({ $0.hasPrefix("merges-") }).sorted().suffix(3) {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let sample = try? decoder.decode(MergeSample.self, from: Data(line.utf8)), sample.project == project,
                      sample.result.hasPrefix("passed") else { continue }
                durations.append(Double(sample.durationS))
            }
        }
        return Array(durations.suffix(10))
    }

    /// The watch's look now; the lead is told when it's due (`LeadPipeline.Look.tell`), and the board keeps when.
    /// Returns the look, for the next one's time.
    @discardableResult
    func watchPipeline(now: Date? = nil) -> LeadPipeline.Look {
        let now = now ?? pipelineClock()
        let workflow = self.workflow
        let board = store.load()
        // It runs after every run of auto_advance's passes: the signals (git, the records' lint) only once a task stalled.
        let quick = LeadPipeline.look(board, signals: LeadPipeline.Signals(lastMerge: lastMerge()), base: workflow.base, now: now)
        guard !quick.stalled.isEmpty else { return quick }
        let look = LeadPipeline.look(board, signals: pipelineSignals(workflow, now: now), base: workflow.base, now: now)
        guard look.tell, let text = look.text, let since = look.since, let cause = look.cause else { return look }
        try? store.update { board in
            board.pipeline = LeadPipeline.Told(at: now.timeIntervalSince1970, since: since.timeIntervalSince1970, cause: cause.rawValue)
        }
        try? store.appendProgress("Pipeline held: \(look.stalled.joined(separator: ", ")) ready to merge with none landing; cause: \(cause.rawValue)")
        _ = try? tellLead(text, about: LeadAdvance.sender)
        return look
    }

    /// status's line while merges are held (`LeadPipeline`); nil when none is.
    func pipelineLine(now: Date? = nil) -> String? {
        let now = now ?? pipelineClock()
        let workflow = self.workflow
        let board = store.load()
        // Nothing ready long enough: no signals read.
        guard board.tasks.contains(where: { LeadPipeline.readySince($0).map { now.timeIntervalSince($0) >= LeadPipeline.stallAfter } ?? false }) else { return nil }
        return LeadPipeline.look(board, signals: pipelineSignals(workflow, now: now), base: workflow.base, now: now).text
    }
}
