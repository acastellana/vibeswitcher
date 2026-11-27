import Foundation

/// The whole Mac as every project's lead shares it: its load (`steady`) and the team sessions (workers and verifiers)
/// of every project the session host knows. A lead that counted only its own team believed it had the Mac
/// to itself: on 2026-10-19 three leads' teams together held it at load 100–190 for hours, a worker's build took 25
/// minutes and merges failed on timing-sensitive tests.
public struct MacLoad: Equatable, Sendable {
    /// One project's live team sessions.
    public struct Holder: Equatable, Sendable {
        /// The repository's folder name.
        public var project: String
        public var sessions: Int
    }

    /// The load the leads judge room by (`MacLoad.room`'s, once `judge`d); nil when it couldn't be read.
    public var load: Double?
    /// The projects holding live team sessions, most first.
    public var holders: [Holder]
    /// The Mac's memory (`MacMemory`), where it was read: start_worker, audit and auto_advance's starts weigh it too.
    public var memory: MacMemory? = nil
    /// The gates' reading of the load (`MacLoad.room`), set by `judge`: which average `load` is, and why.
    public var room: Room? = nil
    /// Judged by the gates' rule (`judge`): a load that couldn't be read is then no room (`isBusy`).
    public var judged = false

    public var sessions: Int { holders.reduce(0) { $0 + $1.sessions } }

    /// The Mac's 1-minute load average; nil when the system doesn't say.
    public static func oneMinute() -> Double? { averages()?.one }

    /// The 1- and 5-minute load averages, as `uptime` gives them.
    public struct Averages: Equatable, Sendable {
        public var one: Double
        public var five: Double

        public init(one: Double, five: Double) {
            self.one = one
            self.five = five
        }

        /// The greater of the two, the load `MacLoad.room` judges by while anything of ours runs (no gate reads it
        /// alone). The 1-minute alone dips within a minute or two of a spike's work pausing: on 2026-10-28 the Mac
        /// hit load 150 on 12 cores at 17:30, and at 17:38, with the 5-minute still at 64 and a heavy slot held,
        /// auto_advance read a dip under load_threshold and started two workers. The 5-minute falls only once the load
        /// has stayed down for minutes (from 64 to 24 with the Mac idle, about 5 minutes), and the 1-minute still says
        /// a new rise at once.
        public var steady: Double { max(one, five) }
    }

    /// The load the gates judge room by, and which reading of the averages it is (`MacLoad.room`).
    public struct Room: Equatable, Sendable {
        public enum Reading: Equatable, Sendable {
            /// The 1-minute alone: no worker or verifier runs in any project and no build or test holds a heavy slot.
            case lastMinute
            /// The greater of the 1- and 5-minute: something of ours runs, or that couldn't be told.
            case steady
        }

        public var averages: Averages
        public var reading: Reading

        public init(averages: Averages, reading: Reading) {
            self.averages = averages
            self.reading = reading
        }

        /// The load judged against load_threshold.
        public var load: Double { reading == .lastMinute ? averages.one : averages.steady }

        /// Which reading the load is, in plain words: "the last minute's: no worker or verifier runs and no build or
        /// test holds a slot", "its 5-minute average; the last minute's is 6.0", "the last minute's; the 5-minute
        /// average is 12.0".
        public var reason: String {
            switch reading {
            case .lastMinute: return "the last minute's: no worker or verifier runs and no build or test holds a slot"
            case .steady where averages.five > averages.one:
                return "its 5-minute average; the last minute's is \(MacLoad.text(averages.one))"
            case .steady: return "the last minute's; the 5-minute average is \(MacLoad.text(averages.five))"
            }
        }

        /// `reason` in a few words, for status's line: "1-min: none of ours runs", "5-min; 1-min 20.0", "greater of 1-
        /// and 5-min".
        public var shortReason: String {
            switch reading {
            case .lastMinute: return "1-min: none of ours runs"
            case .steady where averages.five > averages.one: return "5-min; 1-min \(MacLoad.text(averages.one))"
            case .steady: return "greater of 1- and 5-min"
            }
        }

        /// Whole minutes until the 5-minute average decays to `threshold`, when that alone holds the load over it
        /// (the 1-minute under it): N = 5 ln((five − one) / (threshold − one)), rounded up. In the load-gate review's
        /// replay (docs/process/reviews/load-gate-2026-11.md) it was within 2 minutes of the actual wait 63% of the
        /// time. Nil otherwise.
        public func minutesToRoom(threshold: Double) -> Int? {
            guard reading == .steady, averages.one < threshold, averages.five > threshold else { return nil }
            let minutes = 5 * Foundation.log((averages.five - averages.one) / (threshold - averages.one))
            guard minutes.isFinite, minutes > 0 else { return nil }
            return max(1, Int(minutes.rounded(.up)))
        }
    }

    /// The one rule every gate judges the Mac's room by (rule (cI) of docs/process/reviews/load-gate-2026-11.md): the
    /// 1-minute load alone while no worker or verifier runs in any project (`teamSessions`, the host's census) and no
    /// build or test holds a heavy slot (`slotsHeld`, `TestLock.readHolders`); otherwise the greater of the 1- and
    /// 5-minute, as before. After the 2026-11-27 11:01 restart the 5-minute's spike decayed for 10 minutes while
    /// nothing of ours ran, and every start was refused ("it can be that the load is 51, since literally all of them
    /// are queued or the worker ended. It can't be."). The 5-minute stays whenever anything of ours runs: a dip of the
    /// 1-minute under the threshold with the 5-minute over it preceded an overload 27% of the time in the replay.
    /// A census or slots that can't be read (nil) count as something running; nil when the averages can't be read
    /// (no room: `judge`).
    public static func room(_ averages: Averages?, teamSessions: Int?, slotsHeld: Int?) -> Room? {
        guard let averages else { return nil }
        let idle = teamSessions == 0 && slotsHeld == 0
        return Room(averages: averages, reading: idle ? .lastMinute : .steady)
    }

    /// The rule in one sentence, as a lead or the user is told it.
    public static let ruleText = "The Mac has room when its load is under the threshold, counting the last 5 minutes too unless nothing of ours runs: no worker, no verifier, no build or test holding a slot."

    /// The Mac's load averages; nil when the system doesn't say.
    public static func averages() -> Averages? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) >= 2 ? Averages(one: loads[0], five: loads[1]) : nil
    }

    /// Judged by the gates' one rule (`MacLoad.room`): `load` is `room`'s, and a `room` that couldn't be read is busy.
    public mutating func judge(_ room: Room?) {
        self.room = room
        load = room?.load
        judged = true
    }

    /// As `judge`, a copy.
    public func judging(_ room: Room?) -> MacLoad {
        var mac = self
        mac.judge(room)
        return mac
    }

    /// The cores the load is shared by.
    public static var processors: Int { simulatedProcessors ?? ProcessInfo.processInfo.activeProcessorCount }
    /// Tests only (`@testable`): the cores a test's own task reads instead, inside `$simulatedProcessors.withValue(3) { … }`,
    /// so the rules that follow the cores are checked for any Mac here. Task-local: other tests running beside it, and
    /// the app (which never binds it), read the machine's.
    @TaskLocal static var simulatedProcessors: Int?

    /// The live workers and verifiers among `sessions` (told by their labels, see `LeadTeams.role`), by the project
    /// whose worktree they run in, leaving out those in the folder `except` (a task's own: the session about to start
    /// takes their place).
    public static func count(_ sessions: [(label: String?, cwd: String, live: Bool)], load: Double?, except folder: String? = nil) -> MacLoad {
        let excluded = folder.map { ($0 as NSString).standardizingPath }
        var counts: [String: Int] = [:]
        for session in sessions where session.live {
            guard let role = LeadTeams.role(label: session.label), role != .lead else { continue }
            let cwd = (session.cwd as NSString).standardizingPath
            if let excluded, cwd == excluded { continue }
            let root = LeadTeams.root(ofWorktree: cwd) ?? cwd
            counts[(root as NSString).lastPathComponent, default: 0] += 1
        }
        let holders = counts.map { Holder(project: $0.key, sessions: $0.value) }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.project < $1.project }
        return MacLoad(load: load, holders: holders)
    }

    /// As `count`, from the host's census of every project's team (`HostCensus`): since PR #1 the host lists a lead
    /// only its own team, and a lead counting what it's listed saw the Mac emptier than it was (2026-10-28: 5 team
    /// sessions across 1 project, with 9 running across 3) and started past mac_max_sessions. `sessions`, what the
    /// host lists this caller, only tell which of the counted are in the folder `except`.
    public static func count(census: [HostCensus], sessions: [(label: String?, cwd: String, live: Bool)], load: Double?,
                             except folder: String? = nil) -> MacLoad {
        var counts: [String: Int] = [:]
        for entry in census where entry.role != .lead && entry.sessions > 0 {
            counts[(entry.root as NSString).lastPathComponent, default: 0] += entry.sessions
        }
        if let folder {
            let excluded = MacLoad.count(sessions, load: nil).holders
            let kept = MacLoad.count(sessions, load: nil, except: folder).holders
            for holder in excluded {
                let there = holder.sessions - (kept.first { $0.project == holder.project }?.sessions ?? 0)
                if there > 0 { counts[holder.project] = max(0, (counts[holder.project] ?? 0) - there) }
            }
        }
        let holders = counts.filter { $0.value > 0 }.map { Holder(project: $0.key, sessions: $0.value) }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.project < $1.project }
        return MacLoad(load: load, holders: holders)
    }

    /// Above the threshold: builds and tests slow down for every project's team. A load that couldn't be read is room
    /// unless `judged` by the gates' rule, which fails toward waiting.
    public func isBusy(threshold: Double) -> Bool { load.map { $0 > threshold } ?? judged }

    /// Why the Mac is short of memory under `limits` (`MacMemory.shortage`); nil when it isn't or wasn't read.
    public func memoryShortage(_ limits: MacLimits) -> String? { memory?.shortage(limits) }

    /// At the cap: one more session would go past it.
    public func isFull(max: Int) -> Bool { sessions >= max }

    /// 12.34 → "12.3"; unknown → "unknown".
    public var loadText: String { load.map(Self.text) ?? "unknown" }

    /// 12.34 → "12.3".
    static func text(_ load: Double) -> String { String(format: "%.1f", load) }

    /// The load with which reading it is, as a lead is told it: "64.0 (its 5-minute average; the last minute's is
    /// 20.0)", "6.0 (the last minute's: no worker or verifier runs and no build or test holds a slot)"; unjudged,
    /// `loadText` alone.
    public var loadSaid: String { loadText + (room.map { " (\($0.reason))" } ?? "") }

    /// A refusal's "room again in about 4 minutes", when the 5-minute's decay alone holds the load over `threshold`
    /// (`Room.minutesToRoom`); "" otherwise.
    public func roomAgainText(threshold: Double) -> String {
        guard isBusy(threshold: threshold), let minutes = room?.minutesToRoom(threshold: threshold) else { return "" }
        return "room again in about \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// "3 team sessions across 2 projects (vibeswitcher 2, project-c 1)": every project by name, for the app's own
    /// views only. What a lead is told goes into its repository's records (auto_advance logs refusals to progress.md),
    /// so it names only its own project: see `sessionsText(for:)`.
    public var sessionsText: String {
        let who = holders.isEmpty ? "" : " (" + holders.map { "\($0.project) \($0.sessions)" }.joined(separator: ", ") + ")"
        return sessionsCount + who
    }

    /// "8 team sessions across 3 projects (this one 3, 2 others 5)": as told to the lead of the repository `root`,
    /// naming no other project. On 2026-10-28 a start refusal naming the Mac's other projects went into this repo's
    /// progress.md through auto_advance, an hour after the user had their names scrubbed from it.
    public func sessionsText(for root: String) -> String {
        guard !holders.isEmpty else { return sessionsCount }
        let own = ((root as NSString).standardizingPath as NSString).lastPathComponent
        let mine = holders.filter { $0.project == own }.reduce(0) { $0 + $1.sessions }
        let others = holders.filter { $0.project != own }
        var who = ["this one \(mine)"]
        if !others.isEmpty {
            who.append("\(others.count) other\(others.count == 1 ? "" : "s") \(others.reduce(0) { $0 + $1.sessions })")
        }
        return sessionsCount + " (" + who.joined(separator: ", ") + ")"
    }

    /// "3 team sessions across 2 projects".
    private var sessionsCount: String {
        let projects = holders.count == 1 ? "1 project" : "\(holders.count) projects"
        return "\(sessions) team session\(sessions == 1 ? "" : "s") across \(projects)"
    }

    /// The Team view's line: "Mac: load 12.3, 3 team sessions across 2 projects"; judged, which reading the load is
    /// where it isn't both averages': "load 6.0 (last minute)", "load 64.0 (5-minute)".
    public var line: String { "Mac: load \(loadText)\(readingShort), \(sessionsCount)" }

    /// " (last minute)" while nothing of ours runs, " (5-minute)" while the 5-minute is the greater; "" otherwise.
    private var readingShort: String {
        guard let room else { return "" }
        if room.reading == .lastMinute { return " (last minute)" }
        return room.averages.five > room.averages.one ? " (5-minute)" : ""
    }

    /// The line as VoiceOver reads it: what the numbers are, who holds the sessions, and against the lead's limits.
    public func spoken(threshold: Double, max: Int) -> String {
        let load = self.load.map { _ in "load average \(loadText), " + spokenReading } ?? "load average unknown"
        var parts = ["Whole Mac, all projects: \(load)", sessionsText]
        if isBusy(threshold: threshold) { parts.append("over the load limit of \(Self.number(threshold)): new workers and audits wait") }
        if isFull(max: max) { parts.append("at the limit of \(max) team sessions: new workers and audits wait") }
        return parts.joined(separator: "; ")
    }

    /// Which load the line shows, spoken: "the last minute's, since nothing of ours runs", or "the greater of the last
    /// minute's and the last 5 minutes'" (also when not judged: the gates' rule then fails toward the greater).
    private var spokenReading: String {
        room?.reading == .lastMinute ? "the last minute's, since nothing of ours runs" : "the greater of the last minute's and the last 5 minutes'"
    }

    /// 24 → "24", 2.5 → "2.5".
    public static func number(_ value: Double) -> String { String(format: "%g", value) }
}

/// The Mac-wide limits every project's lead starts teams under, set once for the Mac in Settings › Project lead and
/// kept in `~/.vibeswitcher/mac-limits.json` (the leads' tool servers read it at each call). They were keys in each
/// project's workflow.md: TGE-ANALYSIS had 20 there after a refusal suggested raising it while vibeswitcher had 10, so
/// the cap held no project back. A project's workflow.md values for them are ignored (see `LeadWorkflow.ignoredKeys`).
public struct MacLimits: Codable, Equatable, Sendable {
    public static let defaultMaxSessions = 10

    /// How many workers and verifiers may run at once across every project the session host knows; start_worker and
    /// audit refuse at it.
    public var maxSessions: Int
    /// The load (as `MacLoad.room` judges it: the 1-minute alone while nothing of ours runs, else the greater of the 1-
    /// and 5-minute averages) above which start_worker and audit refuse, and merge waits before its tests; nil: twice
    /// the cores (`loadLimit`).
    public var loadThreshold: Double?
    /// The heavy-work slots (builds and full test runs at once, Mac-wide: `vs-heavy`'s, merges', audits'; see
    /// `TestLock`), 1 to the cores. The user chose 2 on a 12-core Mac (2026-11-01): the default is the cores ÷ 6.
    /// VIBESWITCHER_HEAVY_SLOTS, or a project's heavy_slots, sets it instead; boost raises it (`heavySlotsInForce`).
    public var heavySlots: Int
    /// "Ignore usage limits" (Settings › Project lead, off by default; the user asked for "a setting to disable
    /// worrying about quota", 2026-11-07): start_worker, audit and auto_advance start at any share of a Claude limit, as
    /// with override_usage, Boost's usage watch holds nothing off, and agent: auto picks Claude unless Claude refused at a
    /// reached limit. A limit Claude refused at still holds (`AccountUsage.hold(ignoring:)`): a session started into it
    /// would stop at once.
    public var ignoreUsageLimits: Bool
    /// The memory pressure level (`MacMemory.Pressure`'s name: "warning" or "critical"; "off": none) at which
    /// start_worker, audit and auto_advance's starts refuse, as for the load; nil: "warning" (`pressureLimit`).
    /// Mac-wide defaults kept in mac-limits.json, no Settings control: on 2026-11-08 new sessions kept starting into a
    /// Mac that was paging (see `MacMemory`).
    public var memoryPressure: String?
    /// The pages swapped out per second, over about the last minute, above which they refuse too; nil: 50
    /// (`swapOutRateLimit`), 0: no hold on it.
    public var swapOutRate: Double?
    /// The boost these were raised by (`boosted(by:)`), and the limits as set before it; nil: not boosted. Not saved.
    public internal(set) var boost: BoostState?
    var normal: Normal?

    /// The limits as set, kept beside boosted ones for what a lead is told.
    struct Normal: Equatable, Sendable {
        var maxSessions: Int
        var loadLimitText: String
    }

    enum CodingKeys: String, CodingKey { case maxSessions, loadThreshold, heavySlots, ignoreUsageLimits, memoryPressure, swapOutRate }

    public static let defaultPressure = MacMemory.Pressure.warning
    public static let defaultSwapOutRate = 50.0

    /// The cores ÷ 6, rounded down, at least 1: 2 on a 12-core Mac.
    public static var defaultHeavySlots: Int { max(1, MacLoad.processors / 6) }
    /// The most heavy slots: one per core.
    public static var heavySlotsCeiling: Int { max(1, MacLoad.processors) }

    public init(maxSessions: Int = MacLimits.defaultMaxSessions, loadThreshold: Double? = nil, heavySlots: Int = MacLimits.defaultHeavySlots,
                ignoreUsageLimits: Bool = false, memoryPressure: String? = nil, swapOutRate: Double? = nil) {
        self.maxSessions = max(1, maxSessions)
        self.memoryPressure = memoryPressure
        self.swapOutRate = swapOutRate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.ignoreUsageLimits = ignoreUsageLimits
        self.loadThreshold = loadThreshold.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.heavySlots = min(max(1, heavySlots), Self.heavySlotsCeiling)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxSessions: (try? container.decodeIfPresent(Int.self, forKey: .maxSessions)) ?? Self.defaultMaxSessions,
                  loadThreshold: try? container.decodeIfPresent(Double.self, forKey: .loadThreshold),
                  heavySlots: (try? container.decodeIfPresent(Int.self, forKey: .heavySlots)) ?? Self.defaultHeavySlots,
                  ignoreUsageLimits: (try? container.decodeIfPresent(Bool.self, forKey: .ignoreUsageLimits)) ?? false,
                  memoryPressure: try? container.decodeIfPresent(String.self, forKey: .memoryPressure),
                  swapOutRate: try? container.decodeIfPresent(Double.self, forKey: .swapOutRate))
    }

    /// The pressure level start_worker and audit refuse at: the one set, "warning" when unset or unknown; nil: "off".
    public var pressureLimit: MacMemory.Pressure? {
        guard let memoryPressure else { return Self.defaultPressure }
        if memoryPressure.lowercased() == "off" { return nil }
        return MacMemory.Pressure(name: memoryPressure).flatMap { $0 > .normal ? $0 : nil } ?? Self.defaultPressure
    }

    /// The swap-out rate (pages/s) above which they refuse: the one set, 50 when unset; nil: 0, no hold.
    public var swapOutRateLimit: Double? {
        guard let swapOutRate else { return Self.defaultSwapOutRate }
        return swapOutRate > 0 ? swapOutRate : nil
    }

    /// The load threshold in force: the one set, else twice the Mac's cores.
    public var loadLimit: Double { loadThreshold ?? Double(2 * MacLoad.processors) }

    /// load_threshold as said to a lead: "30 in Settings", or "24, twice the 12 cores" when it isn't set.
    public var loadLimitText: String {
        if let normal, boost != nil { return MacLoad.number(loadLimit) + " while boosted (normally \(normal.loadLimitText))" }
        return MacLoad.number(loadLimit) + (loadThreshold == nil ? ", twice the \(MacLoad.processors) cores" : " in Settings")
    }

    /// The file's name: the Mac's `mac-limits.json`; on a Linux node `node-limits.json` (they are the node's limits),
    /// with the Mac's name kept as an alias (`legacyFileName`): read while the node's isn't there, and written with it
    /// while it is there, for what still reads only that name (a tool server of the build before a switch).
    public static let fileName = Platform.Files.limitsFileName
    public static let legacyFileName = "mac-limits.json"

    public static var file: URL { VibePaths.root.appendingPathComponent(fileName) }

    /// The alias beside `file`, when `file` is the node's name and the alias is another.
    static func alias(of file: URL) -> URL? {
        guard fileName != legacyFileName, file.lastPathComponent == fileName else { return nil }
        return file.deletingLastPathComponent().appendingPathComponent(legacyFileName)
    }

    /// The limits as set; the defaults while there's no file (or it can't be read). The alias's while `file` isn't there.
    public static func load(from file: URL = file) -> MacLimits {
        let data = (try? Data(contentsOf: file)) ?? alias(of: file).flatMap { try? Data(contentsOf: $0) }
        return data.flatMap { try? JSONDecoder().decode(MacLimits.self, from: $0) } ?? MacLimits()
    }

    /// Writes them (0600), and the alias too while one is there.
    public func save(to file: URL = MacLimits.file) throws {
        try VibePaths.ensurePrivate(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try VibePaths.writePrivate(data, to: file)
        if let alias = Self.alias(of: file), FileManager.default.fileExists(atPath: alias.path) { try VibePaths.writePrivate(data, to: alias) }
    }
}
