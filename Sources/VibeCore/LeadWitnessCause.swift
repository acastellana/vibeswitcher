import Foundation

/// How long the Mac slept, by the same two clocks a merge's limits use (`MacTime`): each look the witness takes notes
/// the wall clock and the awake clock, and whatever the wall clock gained beyond the awake clock between two looks is
/// sleep. No privileges, no process run, nothing on the user's screen: on 2026-11-08 merges looked hung for about 5
/// hours while the Mac slept 41 times on battery, and finding that out took reading `pmset -g log` by hand.
///
/// In memory, as long as the app runs: a stall's window reaching back before the first look says so (`unwatchedBefore`).
public struct MacSleepLog: Equatable, Sendable {
    /// One gap between two looks that held sleep.
    struct Span: Equatable, Sendable {
        var from: Double
        var to: Double
        var slept: TimeInterval
    }

    /// Sleep shorter than this between two looks is the clocks' jitter (an NTP step, a slow read), not the Mac asleep.
    static let jitter: TimeInterval = 2
    /// The most spans kept: weeks of dark wakes.
    static let keep = 4_000

    private(set) var spans: [Span] = []
    /// The wall clock at the first look: nothing is known of the time before it.
    private(set) var since: Double?
    private var last: (wall: Double, awake: TimeInterval)?

    public init() {}

    public static func == (a: MacSleepLog, b: MacSleepLog) -> Bool {
        a.spans == b.spans && a.since == b.since && a.last?.wall == b.last?.wall && a.last?.awake == b.last?.awake
    }

    /// Takes a look at the clocks.
    public mutating func note(_ time: MacTime) { note(wall: time.wall().timeIntervalSince1970, awake: time.awake()) }

    public mutating func note(wall: Double, awake: TimeInterval) {
        if since == nil { since = wall }
        if let last {
            let slept = (wall - last.wall) - (awake - last.awake)
            if slept >= Self.jitter {
                spans.append(Span(from: last.wall, to: wall, slept: slept))
                if spans.count > Self.keep { spans.removeFirst(spans.count - Self.keep) }
            }
        }
        last = (wall, awake)
    }

    /// What the log says of `from` to `to`.
    public struct Reading: Codable, Equatable, Sendable {
        public var from: Double
        public var slept: TimeInterval
        public var sleeps: Int
        public var lastWoke: Double?
        /// The log started after `from`: what the Mac did before this wasn't watched.
        public var unwatchedBefore: Double?

        /// "the Mac slept 52 min of the 53 min since 14:02, by its awake clock (3 sleeps, last woke 14:55)".
        public func text(now: Date) -> String {
            let window = now.timeIntervalSince1970 - from
            var text = "the Mac slept \(Worktrees.duration(slept)) of the \(Worktrees.duration(window)) since \(LeadBoard.clock(from)), by its awake clock"
            if sleeps > 0 {
                text += " (\(sleeps) sleep\(sleeps == 1 ? "" : "s")" + (lastWoke.map { ", last woke \(LeadBoard.clock($0))" } ?? "") + ")"
            }
            return text + (unwatchedBefore.map { "; VibeSwitcher only watched its clock from \(LeadBoard.clock($0))" } ?? "")
        }
    }

    /// Nil when nothing was ever noted.
    public func reading(from: Double, to: Double) -> Reading? {
        guard let since else { return nil }
        var slept: TimeInterval = 0, sleeps = 0, lastWoke: Double?
        for span in spans where span.to > from && span.from < to {
            // A gap only partly inside: at most what's inside it.
            slept += min(span.slept, min(span.to, to) - max(span.from, from))
            sleeps += 1
            lastWoke = span.to
        }
        return Reading(from: from, slept: slept, sleeps: sleeps, lastWoke: lastWoke, unwatchedBefore: since > from ? since : nil)
    }
}

/// What a stall is really waiting on, with what shows it: told to the lead with the stall, and kept on the board for
/// status. Times are absolute, so a line read later says how long it has been by then.
public enum StallCause: Codable, Equatable, Sendable {
    /// One slot of the Mac-wide test and build lock and who holds it.
    public struct SlotHolder: Codable, Equatable, Sendable {
        public var slot: Int
        public var who: String
        public var since: Double?

        init(held: TestLock.Holder) {
            slot = held.slot
            who = String(held.who.prefix(120))
            since = held.since?.timeIntervalSince1970
        }
    }

    case macAsleep(MacSleepLog.Reading)
    /// In line for a slot: which run, since when, how many ahead, and who holds the slots.
    case testSlot(what: String, since: Double?, ahead: Int, holders: [SlotHolder])
    /// Waiting on a permission prompt or a question.
    case prompt(text: String, since: Double?)
    /// A process of its own lives on (`pid`), and nothing has been written for how long since `quietSince`.
    case liveProcess(pid: Int32, command: String, startedAt: Double, quietSince: Double)
    /// A background job it waits on, its process alive. `named`: its transcript says it waits on it; otherwise only
    /// the process table shows a shell it may be waiting on.
    case backgroundJob(what: String, pid: Int32, startedAt: Double, named: Bool)
    /// The background job its transcript says it waits on has no process any more.
    case jobDied(what: String, startedAt: Double?)
    /// Nothing read says why: what was read, as it was.
    case unknown(read: [String])

    /// How far apart a background task's start in the transcript and its shell's start in the process table may be and
    /// still be the same job: its call returns as the shell starts, later on a loaded Mac.
    static let sameJobWithin: TimeInterval = 120

    /// The evidence, in words, with its times as of `now`.
    public func text(now: Date) -> String {
        switch self {
        case .macAsleep(let reading):
            return "the Mac was asleep: \(reading.text(now: now)), so it hasn't had the time to do anything"
        case let .testSlot(what, since, ahead, holders):
            let waited = since.map { " since \(LeadBoard.clock($0)) (\(LeadToolset.age(now.timeIntervalSince1970 - $0)))" } ?? ""
            let line = ahead > 0 ? ", \(TestLock.ordinal(ahead + 1)) in line" : ", first in line"
            let held = holders.isEmpty ? "nothing says who holds the slots"
                : holders.map { holder in
                    "slot \(holder.slot) held by \(holder.who)" + (holder.since.map { " since \(LeadBoard.clock($0))" } ?? "")
                }.joined(separator: "; ")
            return "waiting for a slot of the Mac-wide test and build lock\(waited)\(line) (\(what)); \(held)"
        case let .prompt(text, since):
            let waited = since.map { " since \(LeadBoard.clock($0)) (\(LeadToolset.age(now.timeIntervalSince1970 - $0)))" } ?? ""
            return "a permission prompt or question is on its screen\(waited): “\(text)”"
        case let .liveProcess(pid, command, startedAt, quietSince):
            return "a live process with no output: pid \(pid) (\(command)), started \(LeadBoard.clock(startedAt)), and nothing written for \(LeadToolset.age(now.timeIntervalSince1970 - quietSince)), since \(LeadBoard.clock(quietSince))"
        case let .backgroundJob(what, pid, startedAt, named):
            return "waiting on its own background job (\(what)): pid \(pid), started \(LeadBoard.clock(startedAt)), still alive after \(LeadToolset.age(now.timeIntervalSince1970 - startedAt))"
                + (named ? "" : "; its transcript names no task it waits on, only this shell")
        case let .jobDied(what, startedAt):
            return "the background job it waited on (\(what)\(startedAt.map { ", started \(LeadBoard.clock($0))" } ?? "")) has no process any more"
        case .unknown(let read):
            return "couldn't tell why. What was read: " + read.joined(separator: "; ")
        }
    }

    /// Whether this only says the worker waits on a live job of its own: not a stall that needs the lead.
    var isOwnJob: Bool { if case .backgroundJob = self { return true } else { return false } }
}

extension LeadWitness.Seen {
    /// The tasks its transcript says its turn waits on.
    var waitedTasks: [TranscriptTail.Background] {
        if case .idle(_?)? = activity { return backgroundTasks }
        return []
    }

    /// The live shell of a task its transcript names: the one started as its call returned.
    func liveShell(of task: TranscriptTail.Background) -> BackgroundJob? {
        guard let at = task.startedAt else { return nil }
        return shells.first { abs($0.startedAt.timeIntervalSince1970 - at) <= StallCause.sameJobWithin }
    }

    /// The task its transcript says it waits on, once no process of it is left: every task named is a shell (an agent
    /// has no process to look for), the process table was read, and none has its shell. Nil otherwise, also when
    /// nothing says either way.
    var diedJob: TranscriptTail.Background? {
        let tasks = waitedTasks
        guard shellsRead, !tasks.isEmpty,
              tasks.allSatisfy({ $0.isShell && $0.startedAt != nil && liveShell(of: $0) == nil }) else { return nil }
        return tasks.first
    }

    /// The live job it waits on, if the transcript names one that has its shell.
    var liveNamedJob: (task: TranscriptTail.Background, shell: BackgroundJob)? {
        for task in waitedTasks {
            if let shell = liveShell(of: task) { return (task, shell) }
        }
        return nil
    }
}

extension LeadStall {
    /// What a stall detected from `seen` over `from`…`at` is really waiting on, by what was read: the most telling that
    /// can be shown, or that it couldn't tell. Never a guess: each case needs what it names to have been read.
    /// `needed`: the awake time this stall takes to count, so a Mac that slept through most of it is the cause.
    static func cause(_ seen: LeadWitness.Seen, reason: Reason, from: Double, at: Double, needed: TimeInterval, background: String?) -> StallCause {
        let sleep = seen.sleep.reading(from: from, to: at)
        if let sleep, at - from - sleep.slept < needed, sleep.slept > 0 { return .macAsleep(sleep) }
        if let wait = seen.lockWait {
            return .testSlot(what: String(wait.waiter.name.prefix(120)), since: wait.waiter.who.since?.timeIntervalSince1970, ahead: wait.ahead,
                             holders: wait.holders.map(StallCause.SlotHolder.init(held:)))
        }
        if let died = seen.diedJob { return .jobDied(what: died.what, startedAt: died.startedAt) }
        if reason == .idle || reason == .undelivered, background != nil {
            if let job = seen.liveNamedJob {
                return .backgroundJob(what: job.task.what, pid: job.shell.pid, startedAt: job.shell.startedAt.timeIntervalSince1970, named: true)
            }
            // Its transcript names none: the shells it was seen to run, which it may or may not be waiting on.
            if seen.waitedTasks.isEmpty, let shell = seen.waitedShells.first {
                return .backgroundJob(what: String(shell.command.prefix(120)), pid: shell.pid,
                                      startedAt: shell.startedAt.timeIntervalSince1970, named: false)
            }
        }
        if reason == .silent, let shell = seen.shells.first {
            return .liveProcess(pid: shell.pid, command: String(shell.command.prefix(120)),
                                startedAt: shell.startedAt.timeIntervalSince1970, quietSince: from)
        }
        return .unknown(read: Self.read(seen, sleep: sleep, background: background, at: at))
    }

    /// What the witness read, for a stall it can't explain.
    static func read(_ seen: LeadWitness.Seen, sleep: MacSleepLog.Reading?, background: String?, at: Double) -> [String] {
        var read = ["status \(seen.status?.rawValue ?? "unread")" + (seen.since.flatMap { LeadStall.known($0.timeIntervalSince1970) }.map { " since \(LeadBoard.clock($0))" } ?? "")]
        read.append("transcript last written " + (seen.lastActivity.map { LeadBoard.clock($0) } ?? "unread"))
        if let background { read.append("waiting on \(background), its process \(seen.shellsRead ? "not found" : "not read")") }
        read.append(seen.shells.isEmpty ? "no shells of its own in the process table" : "\(seen.shells.count) shell(s) of its own alive")
        if let pending = seen.pending { read.append("its last call has no result yet: \(Redaction.secrets(in: String(pending.text.prefix(120))))") }
        if let sleep {
            read.append(sleep.slept > 0 ? sleep.text(now: Date(timeIntervalSince1970: at)) : "the Mac was awake the whole time, by its awake clock"
                        + (sleep.unwatchedBefore.map { " from \(LeadBoard.clock($0)), when VibeSwitcher began watching it" } ?? ""))
        } else {
            read.append("how long the Mac slept wasn't watched")
        }
        return read
    }

    /// A worker that has waited on a permission prompt or question this long shows on status's Stalled lines, saying so.
    /// Not told again: the witness told it when it began (`LeadWitness.notices`).
    static let promptAfter: TimeInterval = 15 * 60

    /// A stall naming the prompt a worker has waited on for over `promptAfter` (`detect` has none for it).
    static func awaitingPrompt(_ seen: LeadWitness.Seen, task: LeadTask, now: Date) -> LeadStall? {
        guard task.status == .running, seen.live, !seen.agentQuit, seen.apiError == nil, seen.usageLimit == nil, seen.lockWait == nil,
              seen.status == .needsInput || { if case .needsInput = seen.activity { return true } else { return false } }(),
              let since = seen.since?.timeIntervalSince1970, now.timeIntervalSince1970 - since >= promptAfter else { return nil }
        let text = Redaction.secrets(in: String(seen.prompt.text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "").prefix(200).description)
        var stall = LeadStall(reason: .prompt, lastActivity: seen.lastActivity ?? since, at: now.timeIntervalSince1970, waitingSince: since)
        stall.cause = .prompt(text: text.isEmpty ? "a question or a permission" : text, since: since)
        stall.sleep = seen.sleep.reading(from: since, to: now.timeIntervalSince1970)
        return stall
    }
}

extension MergeRerun {
    /// What a hung run's cause note starts with: a line after its output, as `quietNote` is.
    static let causePrefix = "Why it stopped: "

    /// What the times and the process table say of a hung run, one line: why it stopped, the Mac's sleep in its
    /// window by the same two clocks its limits count, and a slot queue if something in its folder sat in line.
    static func causeNote(stall: StallWatch.Stall?, quiet: TimeInterval?, slept: TimeInterval, window: TimeInterval, started: Date, stopped: Date,
                          queued: TestLock.Wait?, recorded: ([TestLock.Holder]) -> String = { TestLock.text($0) }) -> String {
        let awake = max(0, window - slept)
        let times = "from \(LeadBoard.clock(started.timeIntervalSince1970)) to \(LeadBoard.clock(stopped.timeIntervalSince1970))"
        let sleep = slept > 0
            ? "the Mac slept \(Worktrees.duration(slept)) of the \(Worktrees.duration(window)) it ran \(times), by its awake clock, so it had \(Worktrees.duration(awake)) awake"
            : "the Mac was awake the whole \(Worktrees.duration(window)) it ran, \(times)"
        var why: String
        if slept > 0, slept >= awake {
            why = "the Mac slept through most of it: \(sleep). The run's limits only count the time awake."
            return causePrefix + why
        } else if let queued {
            let wait = queued.waiter.who.since.map { " since \(LeadBoard.clock($0.timeIntervalSince1970))" } ?? ""
            why = "something it started sat in line for a Mac-wide test slot\(wait) (\(queued.waiter.name)), \(recorded(queued.holders))"
        } else if let stall {
            let names = stall.processes.prefix(3).joined(separator: ", ")
            why = "a live process with no output for \(Worktrees.duration(stall.idle)) of awake time, its processes when stopped: \(names.isEmpty ? "none read" : names)"
        } else if let quiet {
            why = quiet >= StallWatch.defaultMinutes * 60
                ? "a live process with no output: its last line came \(Worktrees.duration(quiet)) of awake time before the stop"
                : "it was still writing output (its last line \(Worktrees.duration(quiet)) of awake time before the stop): it ran out of time, not stuck"
        } else {
            why = "couldn't tell why: its output's last line and its process list weren't read"
        }
        return causePrefix + why + "; " + sleep + "."
    }

    /// "Why it stopped: …. ", for a message about a stopped run: empty when its output carries no cause.
    public static func causeText(_ output: String) -> String {
        cause(in: output).map { causePrefix + Redaction.secrets(in: $0) + " " } ?? ""
    }

    /// The cause a stopped run's `output` carries, without its prefix; nil when it carries none.
    public static func cause(in output: String) -> String? {
        output.components(separatedBy: "\n").last { $0.hasPrefix(causePrefix) }.map { String($0.dropFirst(causePrefix.count)) }
    }
}
