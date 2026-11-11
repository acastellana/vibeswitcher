import Foundation

/// A worker that has stopped making progress, whatever its screen says: the witness tells the lead (see
/// `LeadWitness`), and the board keeps it on the task so status and the Team view show it until the worker moves again.
public struct LeadStall: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// It reads as working, but its transcript hasn't grown for a while and its turn runs no shell (one it left in
        /// the background doesn't count).
        case silent
        /// Between turns for a while, without having reported and with no question to the lead pending.
        case idle
        /// Its transcript ends at a context-compaction summary, and nothing followed.
        case compacted
        /// A message has waited in its inbox, undelivered.
        case undelivered
        /// A permission prompt or question has waited on its screen past `promptAfter` (see `awaitingPrompt`).
        case prompt
    }

    public var reason: Reason
    /// When it last did something: its transcript's last step (or its subagents').
    public var lastActivity: Double
    /// When the witness noticed.
    public var at: Double
    /// For `undelivered`: since when the message has waited, and who sent it.
    public var waitingSince: Double?
    public var waitingFrom: String?
    /// For `idle`: the background task it still waits on, past `backgroundCeiling` (see `LeadWitness.Seen.waitingOn`).
    public var background: String?
    /// For `silent` and `idle`: the shells it left running in the background, which weren't counted as it doing
    /// anything ("npm run dev · 2h", see `BackgroundJobs.summary`).
    public var shells: String?
    /// What it's really waiting on, with what shows it (see `StallCause`).
    public var cause: StallCause?
    /// How long the Mac slept in its window, by the awake clock (nil: not watched).
    public var sleep: MacSleepLog.Reading?

    public init(reason: Reason, lastActivity: Double, at: Double = Date().timeIntervalSince1970,
                waitingSince: Double? = nil, waitingFrom: String? = nil, background: String? = nil, shells: String? = nil,
                cause: StallCause? = nil, sleep: MacSleepLog.Reading? = nil) {
        self.cause = cause
        self.sleep = sleep
        self.reason = reason
        self.lastActivity = lastActivity
        self.at = at
        self.waitingSince = waitingSince
        self.waitingFrom = waitingFrom
        self.background = background
        self.shells = shells
    }

    /// How long each takes to count as a stall.
    public static let silentAfter: TimeInterval = 15 * 60
    public static let idleAfter: TimeInterval = 10 * 60
    public static let compactedAfter: TimeInterval = 5 * 60
    public static let undeliveredAfter: TimeInterval = 5 * 60
    /// Between turns waiting on its own background task or shell (a long test run), it's idle only past this; once
    /// the task is told complete, `idleAfter` counts from then.
    public static let backgroundCeiling: TimeInterval = 45 * 60
    /// The longest Claude Code's Bash tool runs a command in the foreground: a shell older than this, started before
    /// its transcript's last write, isn't what its turn waits on (see `LeadWitness.Seen.turnShells`).
    public static let bashCeiling: TimeInterval = 10 * 60

    /// The share of a stall's window (up to when the Mac last woke) the Mac must have slept for it to be the Mac's
    /// pause, not a stall to tell.
    public static let sleptThroughShare = 0.9

    /// The Mac slept through its window, and it hasn't had its time awake since: the worker was paused with the Mac.
    /// Not told to the lead; status says "paused while the Mac slept". Once the Mac has been awake for the stall's
    /// own threshold the cause is no longer the sleep, and the normal report comes.
    public var pausedAsleep: Bool { if case .sleptThrough? = cause { return true } else { return false } }

    /// The reason in words.
    public func why(now: Date = Date()) -> String {
        switch reason {
        case .silent:
            if let shells { return "it reads as working, but its transcript hasn't grown and its turn runs no command, only \(Self.left(shells))" }
            return "it reads as working, but its transcript hasn't grown and no shell of its runs"
        case .idle:
            if let background { return "it has waited on its background task (\(background)) for over \(Int(Self.backgroundCeiling / 60)) min without having reported" }
            return "it's between turns without having reported, and has no question to the lead pending"
                + (shells.map { "; \(Self.left($0)) runs on" } ?? "")
        case .compacted: return "its transcript ends at a context-compaction summary and nothing followed"
        case .prompt: return "it has waited on a permission prompt or question"
        case .undelivered:
            let waited = LeadToolset.age(now.timeIntervalSince1970 - (waitingSince ?? at))
            return "a message\(waitingFrom.map { " from \($0)" } ?? "") has waited \(waited) in its inbox, undelivered"
        }
    }

    /// "a shell it left in the background (npm run dev · 2h)", or "shells it left in the background (2 shells · …)".
    static func left(_ shells: String) -> String {
        (shells.contains(" shells · oldest ") ? "shells" : "a shell") + " it left in the background (\(shells))"
    }

    /// "stalled: <reason>, last activity N min ago" ("no activity seen yet" without a time for it).
    public func text(now: Date = Date()) -> String {
        let last = Self.known(lastActivity).map { "last activity \(LeadToolset.age(now.timeIntervalSince1970 - $0)) ago" }
        return "stalled: \(why(now: now)), \(last ?? "no activity seen yet")"
    }

    /// What status's Stalled lines and the witness tell the lead: `text` with what it's really waiting on and what
    /// shows it (the Mac's sleep, a test slot, a prompt, a live process, a background job, or that it couldn't tell).
    /// A worker waiting on a live job of its own is labelled so, and isn't called stalled.
    public func report(now: Date = Date()) -> String {
        guard let cause else { return text(now: now) }
        if pausedAsleep { return "paused while the Mac slept: \(cause.text(now: now))" }
        if waitsOnOwnJob {
            let last = Self.known(lastActivity).map { ", last activity \(LeadToolset.age(now.timeIntervalSince1970 - $0)) ago" } ?? ""
            return "\(heldBack ? "not stalled" : "not known to be stalled"): \(cause.text(now: now))\(last)\(sleepNote(now: now))"
        }
        return "\(text(now: now)). Cause: \(cause.text(now: now))\(sleepNote(now: now))"
    }

    /// The Mac's sleep in the window, when the cause isn't that already and there was any.
    private func sleepNote(now: Date) -> String {
        if case .macAsleep? = cause { return "" }
        if pausedAsleep { return "" }
        guard let sleep, sleep.slept > 0 else { return "" }
        return "; \(sleep.text(now: now))"
    }

    /// Waiting between turns on a live background job of its own: the process table shows it alive, so this isn't a
    /// stall that needs the lead. Told apart in status and left out of the Team view's red "Stalled".
    public var waitsOnOwnJob: Bool { reason == .idle && cause?.isOwnJob == true }

    /// Whether the witness keeps this from the lead: its own job, which its transcript names and which still runs (the
    /// report would be a wake-up with nothing to do), or a window the Mac slept through (`pausedAsleep`).
    public var heldBack: Bool {
        if pausedAsleep { return true }
        if case .backgroundJob(_, _, _, named: true)? = cause { return reason == .idle }
        return false
    }

    /// Whether the Team view shows it as a red "Stalled": not a wait on its own job, nor a prompt, which shows as waiting for input.
    /// Nor one paused while the Mac slept.
    public var showsAsStalled: Bool { !waitsOnOwnJob && reason != .prompt && !pausedAsleep }

    /// A time, unless it's a placeholder for none (`.distantPast`, or anything before 2001).
    static func known(_ at: Double) -> Double? { at >= Date(timeIntervalSinceReferenceDate: 0).timeIntervalSince1970 ? at : nil }

    /// What the lead can do about it.
    public func advice(slug: String) -> String {
        switch reason {
        case .silent: return "read_session(\(slug)) to see where it is; message it to go on, or stop_worker and start_worker again."
        case .idle: return "read_session(\(slug)) to see where it stopped, then message it what to do next."
        case .compacted: return "It lost its place after the compaction: message(\(slug), …) what it was doing and what's next."
        case .undelivered: return "read_session(\(slug)) to see what holds it (a draft in its box, a prompt); message again with clear_draft: true, or tell the user."
        case .prompt: return "Answer it with message(\(slug), …), or ask the user if it's theirs to decide."
        }
    }

    /// Each stall is told once per episode: silent, idle and compacted are one episode per last activity (the first
    /// to fire tells it; nothing new until the worker moves again), an undelivered message one per message.
    public func key(session: String) -> String {
        switch reason {
        case .undelivered: return "\(session)|held-\(Int(waitingSince ?? at))"
        case .silent, .idle, .compacted:
            // Told as the Mac's sleep, it's told again if the worker is still silent once it has had its time awake.
            if case .macAsleep? = cause { return "\(session)|stalled-\(Int(lastActivity))|asleep" }
            if pausedAsleep { return "\(session)|stalled-\(Int(lastActivity))|asleep" }
            return "\(session)|stalled-\(Int(lastActivity))"
        case .prompt: return "\(session)|prompt-\(Int(waitingSince ?? at))"
        }
    }

    /// The stalls a running task's worker is in, the most telling first (at most one of silent, idle and
    /// compacted, with undelivered beside it). Nothing for a worker that waits on a prompt, ended, or stopped on an
    /// API error or the usage limit: the witness tells those its own way. Nor silent, idle or compacted while a run of its waits in line
    /// for the Mac-wide test and build lock (`Seen.lockWait`): it goes on once a slot is free, and every holder's run
    /// ends within its timeout (status says whom it waits for).
    public static func detect(_ seen: LeadWitness.Seen, task: LeadTask, now: Date = Date()) -> [LeadStall] {
        guard task.status == .running, seen.live, !seen.agentQuit, seen.apiError == nil, seen.usageLimit == nil,
              seen.status != .needsInput, !(seen.activity.map { if case .needsInput = $0 { return true } else { return false } } ?? false)
        else { return [] }
        let at = now.timeIntervalSince1970
        var stalls: [LeadStall] = []
        let working = seen.status == .working || seen.activity.map { if case .working = $0 { return true } else { return false } } ?? false
        let betweenTurns = seen.activity?.betweenTurns ?? [.done, .idle, .background].contains(seen.status ?? .unknown)
        // Between turns waiting on its own background task: its transcript says (see `LeadActivity`), or its shells.
        let background = betweenTurns ? seen.waitingOn : nil
        // Mid-turn, a command its turn runs is it at work; a shell it left in the background (a server) runs on
        // whether or not it does anything, so it's named in the stall (as every shell, past those), not counted as progress.
        let turnShells = seen.turnShells(now: now)
        let shells = BackgroundJobs.summary(seen.shells, now: now)
        // Between turns with no transcript to read, its status says since when. Neither counts from before this
        // session started: one first seen before its hooks fire reads as between turns since ever (`.distantPast`),
        // one on a reused terminal as the earlier session left it.
        let since = seen.lastActivity ?? (betweenTurns ? seen.since?.timeIntervalSince1970 : nil)
        if seen.lockWait == nil, let last = since.flatMap({ known(max($0, seen.started ?? -.infinity)) }) {
            let quiet = at - last
            // A compaction once its turn was over is Claude tidying an idle session: it's idle, if anything.
            if let compacted = seen.compactedAt, !betweenTurns, quiet >= compactedAfter {
                stalls.append(explained(LeadStall(reason: .compacted, lastActivity: max(last, compacted), at: at), seen, from: last, needed: compactedAfter, background: nil))
            } else if working, turnShells.isEmpty, quiet >= silentAfter {
                stalls.append(explained(LeadStall(reason: .silent, lastActivity: last, at: at, shells: shells), seen, from: last, needed: silentAfter, background: nil))
            } else if betweenTurns, !seen.jobCheckPending, task.leadQuestionAt == nil, quiet >= (background == nil ? idleAfter : backgroundCeiling) {
                stalls.append(explained(LeadStall(reason: .idle, lastActivity: last, at: at, background: background,
                                                  shells: background == nil ? shells : nil), seen, from: last,
                                        needed: background == nil ? idleAfter : backgroundCeiling, background: background))
            }
        }
        // A worker at work with its turn's command running (or waiting for the lock) takes the message at its next step.
        if let held = seen.heldSince, at - held >= undeliveredAfter, !(working && (!turnShells.isEmpty || seen.lockWait != nil)) {
            stalls.append(explained(LeadStall(reason: .undelivered, lastActivity: seen.lastActivity ?? held, at: at,
                                              waitingSince: held, waitingFrom: seen.heldFrom), seen, from: held, needed: undeliveredAfter, background: background))
        }
        return stalls
    }

    /// `stall` with what it's really waiting on and the Mac's sleep in its window (see `cause`).
    private static func explained(_ stall: LeadStall, _ seen: LeadWitness.Seen, from: Double, needed: TimeInterval, background: String?) -> LeadStall {
        var explained = stall
        explained.cause = cause(seen, reason: stall.reason, from: from, at: stall.at, needed: needed, background: background)
        explained.sleep = seen.sleep.reading(from: from, to: stall.at)
        return explained
    }
}

/// What a transcript says about progress, beyond its last step (see `TranscriptTail`): when anything was last
/// written to it, and whether it ends at a context-compaction summary.
public struct TranscriptProgress: Equatable, Sendable {
    /// The latest timestamped entry (the main thread's or a subagent's), not counting notices written while idle.
    public var lastWritten: Double?
    /// When the conversation's last entry is a compaction (Claude Code's boundary and summary) made mid-turn, its
    /// time. One made after the turn was over (Claude compacts idle sessions) is neither this nor activity.
    public var compactedAt: Double?

    public init(lastWritten: Double?, compactedAt: Double?) {
        self.lastWritten = lastWritten
        self.compactedAt = compactedAt
    }

    /// Notices written between turns: they aren't the agent doing anything.
    static let notices: Set<String> = ["away_summary", "informational", "local_command"]

    /// The file's tail (see `TranscriptTail.window`), with its subagents' transcripts (`<file>/subagents/`) for when
    /// they were last written to.
    public static func read(url: URL) -> TranscriptProgress? {
        TranscriptTail.noteRead()
        // The file's own part read again only once it changed (see `UnchangedFiles`); its subagents' looked at each time.
        guard var progress = mains.value(at: url.path, read: { readFile(url) }) else { return nil }
        let subagents = url.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let latest = files.filter { $0.pathExtension == "jsonl" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 }.max()
        if let latest, latest > (progress.lastWritten ?? 0) { progress.lastWritten = latest }
        return progress
    }

    /// What each transcript's own lines said, while the file is the same.
    static let mains = UnchangedFiles<TranscriptProgress?>()

    private static func readFile(_ url: URL) -> TranscriptProgress? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(TranscriptTail.window) ? size - UInt64(TranscriptTail.window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.subdata(in: (data.startIndex + TranscriptReader.tailStart(data))..<data.endIndex) }
        var progress = read(data)
        // A last line longer than the window (a Read of a big file) leaves it no timestamped line: the file was last
        // written when it was modified. Without this the reading fell back to a subagent that ended long before, and
        // the worker read as silent while its transcript grew (land-pr-1-host, 2026-10-27 17:35Z: a 383 KB result).
        if progress.lastWritten == nil, start > 0, !timestamped(data),
           let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
            progress.lastWritten = modified.timeIntervalSince1970
        }
        return progress
    }

    /// Whether any complete line in `data` has a timestamp (a notice's included).
    static func timestamped(_ data: Data) -> Bool {
        var lines = TranscriptReader.lines(data)
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        return lines.contains { line in
            ((try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any])?["timestamp"] != nil
        }
    }

    /// From complete transcript lines (a partial last line is skipped).
    public static func read(_ data: Data) -> TranscriptProgress {
        var lines = TranscriptReader.lines(data)
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        var lastWritten: Double?
        // While the conversation ends at a compaction: when it was, and the latest entry written before it.
        var compaction: Double?
        var writtenBefore: Double?
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = object["type"] as? String
            let subtype = object["subtype"] as? String
            let at = ChatReader.date(object["timestamp"])?.timeIntervalSince1970
            if type == "system", notices.contains(subtype ?? "") { continue }
            let compacting = object["isCompactSummary"] as? Bool == true || subtype == "compact_boundary"
            if lastWritten == nil, let at { lastWritten = at }
            if compaction != nil, !compacting, writtenBefore == nil, let at { writtenBefore = at }
            // The conversation's last entry: a step of the main thread (attachments and bookkeeping lines aren't).
            guard object["isSidechain"] as? Bool != true, ["user", "assistant", "system"].contains(type ?? "") else { continue }
            if type == "user", object["isMeta"] as? Bool == true { continue }
            if compacting {
                if compaction == nil { compaction = at ?? 0 }
                continue
            }
            if let compaction {
                switch TranscriptTail.step(object) {
                case nil: continue
                // Compacted mid-turn: it should have gone on from the summary.
                case .state?: return TranscriptProgress(lastWritten: lastWritten, compactedAt: compaction)
                // Compacted after its turn was over: Claude tidying an idle session, not the agent doing anything.
                default: return TranscriptProgress(lastWritten: writtenBefore ?? at, compactedAt: nil)
                }
            }
            if lastWritten != nil { break }
        }
        return TranscriptProgress(lastWritten: lastWritten, compactedAt: compaction)
    }
}
