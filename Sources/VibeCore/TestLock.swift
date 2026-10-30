import Darwin
import Foundation

/// At most N builds or test runs at a time on this Mac, for every project: the slots `vs-heavy` takes around the command
/// it's given (scripts/test.sh and scripts/build-app.sh around swift build and swift test, workers around a full suite
/// or a release build), which merge and an audit's shared run take around their commands too. Two suites side by side
/// starved each other and the benches (3–4 min each at load 30–50, measured 2026-10-21); a single slot let one
/// 38-minute pytest hold up every project's builds, suites and merges (2026-10-22). N is `slotsVariable`, the
/// workflow's heavy_slots for merge and audits, else the Mac's cores ÷ 4 (at least 1).
/// Slot 1 is a flock on `<directory>/test-build.lock`, slot k on `<directory>/test-build-k.lock`: the kernel lets go of
/// it when its holder exits, however it ends, so no stale slot outlives a run. `<slot>.holder` says who holds it, for
/// the one waiting and for status: its first line "pid P, WHAT in DIR, since T" (all an older reader reads), then
/// "taken <seconds since 1970>" (when it took the slot), "pid started <seconds>" (when process P started: a note naming a
/// pid that's gone, or that's another process's since, says nothing), and "project <name>" and "task <slug>" (DIR's,
/// see `whose`). `<slot>.active` ("pid P", P the note's) when its work last used CPU: touched by its
/// holder (vs-heavy's supervisor, `Held` here) each `sampleEvery` its work used 1 % of a core or more, so a hung one
/// reads "idle 40 min" (a TGE pytest held the only slot 3 h 23 min at 0 % CPU, 2026-10-22).
///
/// Waiters take slots first come, first served (flock has no queue: on 2026-10-22 a merge waited over 90 minutes for a
/// slot while pytests and merges arriving after it took it again and again). Each takes a number (a ticket) on
/// arriving and takes a slot only once no live ticket before it could take that one; `vs-heavy` keeps the same line:
/// - Taking a number: under a flock on `<directory>/queue.lock`, whose text is the last number given, the next is one
///   past that (or past the highest ticket there, if higher), and `<directory>/ticket-<n>` is created with O_EXCL and
///   O_EXLOCK, so it's never seen unlocked while its waiter lives. Numbers aren't given twice.
/// - A ticket's text is a holder's note ("pid P, WHAT in DIR, since T") and "slots N", the slots its waiter may take.
/// - Its waiter keeps it flocked while it waits, and removes it once it holds a slot or gives up. One that can be
///   flocked has no waiter (it died, however it ended): whoever finds it so removes it, and it's passed over.
/// - A waiter takes slot k only when no live ticket before its own has slots ≥ k: the first in line takes any of its
///   slots, and one behind a waiter with fewer slots takes the ones that waiter can't.
/// An older `vs-heavy` (or app) takes no ticket: it may take a slot ahead of the line, as before, but waits on nothing
/// in it, and holds a slot only while its command runs; so the line can be held up by one, never stuck.
public struct TestLock: Sendable {
    /// Set to the held slot's path for the commands run under its holder: a script among them doesn't wait for its own
    /// ancestor (`vs-heavy` reads it).
    public static let heldVariable = "VIBESWITCHER_TEST_LOCK"
    /// Where the slots are kept instead of /private/tmp/vibeswitcher-<uid> (tests).
    public static let directoryVariable = "VIBESWITCHER_TEST_LOCK_DIR"
    /// How often `vs-heavy`'s supervisor looks at its command's CPU time, in seconds, when set (tests); else 60.
    public static let sampleVariable = "VIBESWITCHER_HEAVY_SAMPLE"
    /// How many slots, when set (a whole number above 0); else `defaultSlots`.
    public static let slotsVariable = "VIBESWITCHER_HEAVY_SLOTS"
    /// How long `vs-heavy` lets its command run before it ends its group, when set ("90", "90m", "30s", "2h"); else 60
    /// min. The lead gives its sessions the project's test_timeout_min, when the workflow sets one of its own.
    public static let timeoutVariable = "VIBESWITCHER_HEAVY_TIMEOUT"
    /// A slot held this long is "long" in status, the witness and a waiter's words: only said, never acted on.
    public static let longAfter: TimeInterval = 30 * 60
    /// A holder whose work has used almost no CPU this long is "idle" there: only said, never acted on.
    public static let idleAfter: TimeInterval = 10 * 60

    public let directory: String
    public let slots: Int
    /// How often a holder here looks at its work's CPU time (`Held`).
    public var sampleEvery: TimeInterval = 60
    /// Slot 1's file (an older `vs-heavy` knows only this one).
    public var path: String { slotPath(1) }

    public init(directory: String, slots: Int = 1) {
        self.directory = directory
        self.slots = max(1, slots)
    }

    /// The same slots, `count` of them.
    public func with(slots count: Int) -> TestLock {
        var lock = TestLock(directory: directory, slots: count)
        lock.sampleEvery = sampleEvery
        return lock
    }

    /// Slot `index`'s file (from 1).
    public func slotPath(_ index: Int) -> String {
        (directory as NSString).appendingPathComponent(index == 1 ? "test-build.lock" : "test-build-\(index).lock")
    }

    /// Whether `path` is one of this folder's slots, whatever their number.
    public func isSlot(_ path: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent == directory else { return false }
        let name = (path as NSString).lastPathComponent
        if name == "test-build.lock" { return true }
        guard name.hasPrefix("test-build-"), name.hasSuffix(".lock") else { return false }
        let number = name.dropFirst("test-build-".count).dropLast(".lock".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// The Mac's cores ÷ 4, at least 1: 3 on a 12-core Mac.
    public static var defaultSlots: Int { max(1, ProcessInfo.processInfo.processorCount / 4) }

    /// The count `environment` sets (`slotsVariable`), else `defaultSlots`.
    public static func slotCount(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        environment[slotsVariable].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil } ?? defaultSlots
    }

    /// `vs-heavy`, the command that runs its arguments under this lock, for any project (Resources/bin/vs-heavy in the
    /// repository): in the app bundle's Contents/Resources/bin, which every session the app starts has on its PATH.
    public static let command = "vs-heavy"

    /// The folder holding `vs-heavy` for a program at `executable` in the app bundle's Contents/MacOS (the session
    /// host); nil when there's none there (a `swift build`'s binaries).
    public static func commandFolder(besideExecutable executable: String) -> String? {
        let contents = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let folder = contents.appendingPathComponent("Resources/bin").path
        return FileManager.default.isExecutableFile(atPath: (folder as NSString).appendingPathComponent(command)) ? folder : nil
    }

    /// The sessions' environment `base` with `folder` first on its PATH (once): the login shell's path_helper keeps
    /// what PATH had after the system's folders, and the user's own startup files add to it.
    public static func sessionEnvironment(_ base: [String: String], adding folder: String?) -> [String: String] {
        guard let folder else { return base }
        var environment = base
        let rest = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0 != folder }
        environment["PATH"] = ([folder] + rest).joined(separator: ":")
        return environment
    }

    /// The Mac-wide slots (`slotCount` of them); nil when this process runs under a holder of one already
    /// (`heldVariable` names it).
    public static func standard(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TestLock? {
        let lock = TestLock(directory: environment[directoryVariable] ?? "/private/tmp/vibeswitcher-\(getuid())", slots: slotCount(environment))
        return environment[heldVariable].map(lock.isSlot) == true ? nil : lock
    }

    /// A slot while it's held: let go with `release` (or when it goes). While it's held, the commands this process
    /// runs (its descendants: the test command's group, and whatever other calls run meanwhile) are looked at every
    /// `every`, and its `.active` note touched when they used 1 % of a core or more.
    public final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        /// The slot's file.
        public let path: String
        private let sampling = ShellCancel()
        init(fd: Int32, path: String, every: TimeInterval) {
            self.fd = fd
            self.path = path
            let active = path + ".active", stop = sampling
            Thread.detachNewThread {
                var seen: [pid_t: Double]?
                var next = Date().addingTimeInterval(every)
                while !stop.isCancelled {
                    if Date() >= next {
                        if let now = TestLock.descendantsCPU() {
                            // The first look only sets where it starts from.
                            let used = seen.map { seen in now.reduce(0) { $0 + $1.value - (seen[$1.key] ?? 0) } } ?? 0
                            if used >= 0.01 * every, !stop.isCancelled { utimes(active, nil) }
                            seen = now
                        }
                        next = Date().addingTimeInterval(every)
                    }
                    Thread.sleep(forTimeInterval: min(0.5, every / 4))
                }
            }
        }

        public func release() {
            lock.lock()
            defer { lock.unlock() }
            guard fd >= 0 else { return }
            sampling.cancel()
            // Its notes go first, while the slot is still this process's: only its own (no other holder could write
            // one meanwhile).
            let note = path + ".holder", active = path + ".active"
            if (try? String(contentsOfFile: note, encoding: .utf8))?.hasPrefix("pid \(getpid()), ") == true { unlink(note) }
            if TestLock.firstLine(active) == "pid \(getpid())" { unlink(active) }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    /// The first line of the file at `path`, trimmed; nil when there's none.
    static func firstLine(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// CPU seconds (user and system) of this process's descendants, by pid; nil when the process table couldn't be read.
    static func descendantsCPU(of root: pid_t = getpid()) -> [pid_t: Double]? {
        guard let table = ProcessTable.trySnapshot() else { return nil }
        var family: [pid_t] = [root], index = 0
        while index < family.count {
            let parent = family[index]
            family += table.values.filter { $0.ppid == parent && $0.pid != parent && !family.contains($0.pid) }.map(\.pid)
            index += 1
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let seconds = Double(timebase.numer) / Double(max(1, timebase.denom)) / 1e9
        var cpu: [pid_t: Double] = [:]
        for pid in family.dropFirst() {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            cpu[pid] = Double(info.pti_total_user + info.pti_total_system) * seconds
        }
        return cpu
    }

    /// Who holds a slot, as its note says.
    public struct Holder: Equatable, Sendable {
        public var slot: Int
        /// The note's line ("pid 30098, scripts/test.sh in /Users/a/dev/p, since 02:53:22"); nil when there's none.
        public var note: String?
        /// When the note was written: when the slot was taken.
        public var since: Date?
        /// When its work last used CPU, as its `.active` note says; nil when it says nothing (an older holder's).
        public var active: Date?
        /// The project and task its note's "project" and "task" lines name (nil: an older note's, read from its folder).
        var recordedProject: String?
        var recordedTask: String?

        public init(slot: Int, note: String?, since: Date?, active: Date? = nil, project: String? = nil, task: String? = nil) {
            self.slot = slot
            self.note = note
            self.since = since
            self.active = active
            recordedProject = project
            recordedTask = task
        }

        /// The note's parts: "pid P, WHAT in DIR, since T" (vs-heavy's, merge's and audits'), or without " in DIR".
        private var parts: (pid: String, what: String, directory: String?)? {
            guard let note, let match = note.firstMatch(of: #/^pid (\d+), (.*?)(?: in (/.*))?, since [^,]*$/#) else { return nil }
            return (String(match.1), String(match.2), match.3.map(String.init))
        }

        /// The command (or what it said it is).
        public var what: String? { parts?.what }

        /// The folder it runs in, as its note says.
        public var directory: String? { parts?.directory ?? nil }

        /// The project it runs for: the folder it ran in, or the repository a worktree of VibeSwitcher's belongs to.
        public var project: String? { recordedProject ?? directory.map { TestLock.whose($0).project } }

        /// The task whose worktree it runs in (`<repo>/.vibeswitcher/worktrees/<slug>`); nil elsewhere (a merge's run).
        public var task: String? { recordedTask ?? directory.flatMap { TestLock.whose($0).task } }

        /// "vibeswitcher/the-mac-wide-test" for a task's run, else "TGE (pytest -q)", or what its note says.
        public var who: String {
            if let project, let task { return "\(project)/\(task)" }
            guard let what else { return note ?? "a run that didn't say who it is" }
            return project.map { "\($0) (\(what.prefix(80)))" } ?? String(what.prefix(80))
        }

        public func held(now: Date = Date()) -> TimeInterval { since.map { max(0, now.timeIntervalSince($0)) } ?? 0 }

        /// "vibeswitcher/the-x for 12 min" ("for 40 s" under a minute), or "a run that didn't say who it is".
        public func whoFor(now: Date = Date()) -> String {
            guard note != nil else { return "a run that didn't say who it is" }
            let seconds = Int(held(now: now))
            return who + " for " + (seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min")
        }
        public func isLong(now: Date = Date()) -> Bool { since != nil && held(now: now) >= TestLock.longAfter }

        /// How long its work has used almost no CPU (0 when it doesn't say).
        public func idle(now: Date = Date()) -> TimeInterval { active.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
        public func isIdle(now: Date = Date()) -> Bool { active != nil && idle(now: now) >= TestLock.idleAfter }
        private func idleText(now: Date) -> String { isIdle(now: now) ? ", idle \(Int(idle(now: now)) / 60) min" : "" }

        /// "pid 30098, pytest -q in /Users/a/dev/TGE (TGE), for 38 min, long, idle 35 min".
        public func text(now: Date = Date()) -> String {
            var text = parts.map { parts in
                "pid \(parts.pid), \(parts.what)" + (parts.directory.map { " in \($0) (\(project ?? "?"))" } ?? "")
            } ?? note ?? "a run that didn't say who it is"
            return text + heldText(now: now)
        }

        /// "another project's run, for 38 min, long": as `text` without its folder, command or project.
        public func anonymous(now: Date = Date()) -> String { "another project's run" + heldText(now: now) }

        private func heldText(now: Date) -> String {
            guard since != nil else { return "" }
            let seconds = Int(held(now: now))
            return ", for " + (seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min") + (isLong(now: now) ? ", long" : "") + idleText(now: now)
        }

        /// Status's and the witness's words for a long or idle one: "TGE (pytest -q) for 38 min, idle 35 min".
        public func short(now: Date = Date()) -> String {
            "\(project ?? "a run") (\((what ?? note ?? "it didn't say what").prefix(80))) for \(Int(held(now: now)) / 60) min" + idleText(now: now)
        }
    }

    /// "slot 1 held by pid 1, a in /r (r), for 3 min; slot 2 held by …".
    public static func text(_ holders: [Holder], now: Date = Date()) -> String {
        holders.isEmpty ? "nothing says who" : holders.map { "slot \($0.slot) held by \($0.text(now: now))" }.joined(separator: "; ")
    }

    /// As `text`, for what may go into the records of the repository `root` (a merge's output, which auto_advance
    /// logs to progress.md): its own runs as `text` has them, every other project's (or one that doesn't say whose it
    /// is) as "another project's run", with no name or folder. On 2026-10-28 the Mac-wide census text put the user's
    /// other projects' names into this repo's progress.md, an hour after they had them scrubbed.
    public static func text(_ holders: [Holder], for root: String, now: Date = Date()) -> String {
        let own = ((root as NSString).standardizingPath as NSString).lastPathComponent
        return holders.isEmpty ? "nothing says who" : holders.map {
            "slot \($0.slot) held by " + ($0.project == own ? $0.text(now: now) : $0.anonymous(now: now))
        }.joined(separator: "; ")
    }

    /// A waiter in line for a slot, as its ticket says.
    public struct Waiter: Equatable, Sendable {
        /// Its ticket's number: lower ones go first.
        public var number: Int
        /// The slots it may take (the ticket's "slots N"; any of them when it doesn't say).
        public var slots: Int
        /// Who it is, its ticket's note read as a holder's (slot 0); `since` is when it arrived.
        public var who: Holder

        public init(number: Int, slots: Int, who: Holder) {
            self.number = number
            self.slots = slots
            self.who = who
        }

        /// "merge of x (vibeswitcher)", or the note itself.
        public var name: String {
            guard let what = who.what else { return who.note ?? "a run that didn't say who it is" }
            return what + (who.project.map { " (\($0))" } ?? "")
        }
    }

    /// A place in line: "1st in line", "3rd in line, behind merge of a (alpha) and pytest -q (TGE)".
    public static func place(behind ahead: [Waiter]) -> String {
        let place = ordinal(ahead.count + 1)
        guard !ahead.isEmpty else { return "\(place) in line" }
        var names = ahead.prefix(3).map(\.name)
        if ahead.count > 3 { names.append("\(ahead.count - 3) more") }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(place) in line, behind " + list
    }

    /// "1st", "2nd", "11th", "23rd".
    static func ordinal(_ number: Int) -> String {
        let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
        return "\(number)\(suffix)"
    }

    /// How a wait for a slot ended.
    public enum Outcome {
        /// Taken: `waited` seconds, and who held every slot when it started waiting (empty when one was free).
        case held(Held, waited: TimeInterval, after: [Holder])
        /// Every slot still held, by `holders`, after `timeout`: nothing ran.
        case busy(holders: [Holder])
        case cancelled
        case failed(String)
    }

    /// The line's lock, whose text is the last number given.
    public var queuePath: String { (directory as NSString).appendingPathComponent("queue.lock") }

    /// Ticket `number`'s file.
    public func ticketPath(_ number: Int) -> String { (directory as NSString).appendingPathComponent("ticket-\(number)") }

    /// The numbers of the tickets there, live or not.
    private func ticketNumbers() -> [Int] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).compactMap { name in
            guard name.hasPrefix("ticket-") else { return nil }
            let number = name.dropFirst("ticket-".count)
            return !number.isEmpty && number.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(number) : nil
        }
    }

    /// Takes the next number in line for `note` (a holder's line), waiting on up to `slots`: its ticket, flocked from
    /// its making on the returned fd. Nil when the folder won't have it.
    private func takeTicket(_ note: String, slots: Int) -> (fd: Int32, number: Int)? {
        let queue = open(queuePath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard queue >= 0 else { return nil }
        defer { close(queue) }
        guard flock(queue, LOCK_EX) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = pread(queue, &bytes, bytes.count, 0)
        let given = Int(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let number = max(given, ticketNumbers().max() ?? 0) + 1
        let text = Array("\(number)\n".utf8)
        guard ftruncate(queue, 0) == 0, pwrite(queue, text, text.count, 0) == text.count else { return nil }
        let fd = open(ticketPath(number), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK, 0o600)
        guard fd >= 0 else { return nil }
        let line = Array("\(note)\nslots \(slots)\n".utf8)
        _ = write(fd, line, line.count)
        return (fd, number)
    }

    /// The waiters in line before ticket `number` (all of them by default), first first. A ticket no waiter holds is
    /// removed and passed over.
    public func waiters(before number: Int = .max) -> [Waiter] {
        ticketNumbers().filter { $0 < number }.sorted().compactMap { number in
            let path = ticketPath(number)
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Numbers aren't given twice: the name can only be this dead one's.
                unlink(path)
                return nil
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            let lines = String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let slots = lines.lazy.compactMap { $0.hasPrefix("slots ") ? Int($0.dropFirst("slots ".count)) : nil }.first ?? .max
            var info = stat()
            let since = fstat(fd, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            let note = lines.first.flatMap { $0.isEmpty || $0.hasPrefix("slots ") ? nil : $0 }
            return Waiter(number: number, slots: slots, who: Holder(slot: 0, note: note, since: note == nil ? nil : since))
        }
    }

    /// Who holds slot `index`, as its note says (written when it was taken). A note naming a process that's gone says
    /// nothing: it outlived its run (killed outright, or the slot is held by something it left running), and naming it
    /// sent waiters, status and the witness after a worktree cleaned up long ago (2026-10-22, pid 56668).
    public func holder(_ index: Int) -> Holder {
        let note = slotPath(index) + ".holder", activeNote = slotPath(index) + ".active"
        let lines = ((try? String(contentsOfFile: note, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ key: String) -> String? {
            lines.dropFirst().first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let started = value("pid started").flatMap(TimeInterval.init)
        let line = lines.first.flatMap { $0.isEmpty || Self.isGone(note: $0, started: started) ? nil : $0 }
        let since = value("taken").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            ?? (try? FileManager.default.attributesOfItem(atPath: note))?[.modificationDate] as? Date
        // Its own: the holder's pid. One another holder left says nothing.
        let pid = line?.firstMatch(of: #/^pid (\d+),/#).map { String($0.1) }
        let active = pid != nil && Self.firstLine(activeNote) == "pid \(pid!)"
            ? (try? FileManager.default.attributesOfItem(atPath: activeNote))?[.modificationDate] as? Date : nil
        guard line != nil else { return Holder(slot: index, note: nil, since: nil) }
        return Holder(slot: index, note: line, since: since, active: active, project: value("project"), task: value("task"))
    }

    /// Whether `note` ("pid P, …") names a process that has ended, or, when its process's start time (`started`,
    /// seconds since 1970) is known, a process that started at another time: its pid given again since.
    static func isGone(note: String, started: TimeInterval? = nil) -> Bool {
        guard let match = note.firstMatch(of: #/^pid (\d+),/#), let pid = pid_t(match.1) else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        guard let started, let now = startTime(of: pid) else { return false }
        // vs-heavy's is from ps's elapsed time: to a second or two.
        return abs(now - started) > 3
    }

    /// When process `pid` started, in seconds since 1970; nil when it can't be told (it's gone).
    static func startTime(of pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6
    }

    /// The project and task a run in `directory` is for: in a worktree of VibeSwitcher's
    /// (`<repo>/.vibeswitcher/worktrees/<slug>`, or a folder in it), the repository's name and the slug; elsewhere the
    /// folder's name, and no task.
    public static func whose(_ directory: String) -> (project: String, task: String?) {
        var folder = directory
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        guard let range = folder.range(of: "/.vibeswitcher/worktrees/") else { return (URL(fileURLWithPath: folder).lastPathComponent, nil) }
        let slug = folder[range.upperBound...].split(separator: "/").first.map(String.init)
        return (URL(fileURLWithPath: String(folder[..<range.lowerBound])).lastPathComponent, slug)
    }

    /// The lines after a note's first that record its holder (see the type's notes): taken now by process `pid`, run in
    /// `directory`.
    static func record(pid: pid_t = getpid(), in directory: String?, now: Date = Date()) -> String {
        var lines = ["taken \(Int(now.timeIntervalSince1970))"]
        if let started = startTime(of: pid) { lines.append("pid started \(Int(started))") }
        if let directory {
            let whose = whose(directory)
            lines.append("project \(whose.project)")
            if let task = whose.task { lines.append("task \(task)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A run in line for a slot (`waiter`, its ticket), and who held the slots when it was looked at: what a worker
    /// queued for the lock is doing, not a stall (see `LeadStall`).
    public struct Wait: Equatable, Sendable {
        public var waiter: Waiter
        /// How many are in line before it.
        public var ahead: Int
        public var holders: [Holder]

        public init(waiter: Waiter, ahead: Int, holders: [Holder]) {
            self.waiter = waiter
            self.ahead = ahead
            self.holders = holders
        }

        /// How long it has waited.
        public func waited(now: Date = Date()) -> TimeInterval { waiter.who.held(now: now) }

        /// "waiting for the Mac-wide test lock (held by vibeswitcher/the-x for 12 min), 2nd in line".
        public func text(now: Date = Date()) -> String {
            let held = holders.map { $0.whoFor(now: now) }
            let by = held.isEmpty ? "" : " (held by " + (held.count == 1 ? held[0] : held.dropLast().joined(separator: ", ") + " and " + held.last!) + ")"
            return "waiting for the Mac-wide test lock\(by)" + (ahead > 0 ? ", \(TestLock.ordinal(ahead + 1)) in line" : "")
        }
    }

    /// For each of `folders` (any key: a session's id), its first run in line for a slot, if any: a ticket whose note's
    /// folder is that folder or one in it. One look at the line and the slots for all of them.
    public func waits(for folders: [String: String]) -> [String: Wait] {
        let line = waiters()
        var found: [String: Wait] = [:]
        var holders: [Holder]?
        // As the kernel spells them: a shell's $PWD may be a folder's real path (/private/var/… for /var/…).
        func real(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let directories = line.map { $0.who.directory.map(real) }
        for (key, folder) in folders {
            let folder = real(folder)
            guard folder.count > 1, let index = directories.firstIndex(where: { directory in
                directory.map { $0 == folder || $0.hasPrefix(folder + "/") } ?? false
            }) else { continue }
            if holders == nil { holders = self.holders() }
            found[key] = Wait(waiter: line[index], ahead: index, holders: holders ?? [])
        }
        return found
    }

    /// The slots held now, with who holds them: a slot is tried (and let go at once), so a holder that died isn't
    /// counted, whatever its note says.
    public func holders() -> [Holder] {
        // Every slot there is: another project's heavy_slots may be more than this one's.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let highest = files.compactMap { name -> Int? in
            guard isSlot((directory as NSString).appendingPathComponent(name)) else { return nil }
            return name == "test-build.lock" ? 1 : Int(name.dropFirst("test-build-".count).dropLast(".lock".count))
        }.max() ?? 1
        return (1...max(slots, highest)).compactMap { index in
            let fd = open(slotPath(index), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return nil
            }
            return holder(index)
        }
    }

    /// Waits in line for a slot up to `timeout` (checking `cancel`), takes the first it may, and writes `what` (run in
    /// `directory`) as its holder. While it waits, `waiting` hears who holds them and who's in line before it (first
    /// first), at once and then every `every`.
    public func acquire(as what: String, in directory: String? = nil, timeout: TimeInterval, cancel: ShellCancel? = ShellCancel.current,
                        every: TimeInterval = 30, waiting: (([Holder], [Waiter], TimeInterval) -> Void)? = nil) -> Outcome {
        let folder = self.directory
        do { try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true)) } catch {
            return .failed("Couldn't make \(folder) for the test and build lock (\(error.localizedDescription)).")
        }
        // /private/tmp is everyone's: a folder someone else made there (or a link) isn't taken as this user's.
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            return .failed("\(folder) isn't a folder of yours: the test and build lock can't be kept there.")
        }
        var fds: [Int32] = []
        defer { fds.forEach { if $0 >= 0 { close($0) } } }
        for index in 1...slots {
            let fd = open(slotPath(index), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return .failed("Couldn't open \(slotPath(index)) (\(String(cString: strerror(errno)))).") }
            fds.append(fd)
        }
        let place = directory.map { " in \($0)" } ?? ""
        func note() -> String {
            "pid \(getpid()), \(what)\(place), since \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        }
        guard let ticket = takeTicket(note(), slots: slots) else {
            return .failed("Couldn't take a number in line at \(queuePath) (\(String(cString: strerror(errno)))).")
        }
        // Out of line however this ends: removed first, so no one finds it let go.
        defer {
            unlink(ticketPath(ticket.number))
            close(ticket.fd)
        }
        let start = Date()
        var waitedFor: [Holder] = []
        var told: Date?
        while true {
            let ahead = waiters(before: ticket.number)
            // The slots no one before it may take.
            let from = min(slots, ahead.map(\.slots).max() ?? 0)
            if let free = fds.indices.dropFirst(from).first(where: { flock(fds[$0], LOCK_EX | LOCK_NB) == 0 }) {
                let fd = fds[free]
                fds[free] = -1
                let index = free + 1
                try? VibePaths.writePrivate(Data((note() + "\n" + Self.record(in: directory)).utf8), to: URL(fileURLWithPath: slotPath(index) + ".holder"))
                try? VibePaths.writePrivate(Data("pid \(getpid())\n".utf8), to: URL(fileURLWithPath: slotPath(index) + ".active"))
                return .held(Held(fd: fd, path: slotPath(index), every: sampleEvery), waited: Date().timeIntervalSince(start), after: waitedFor)
            }
            if waitedFor.isEmpty { waitedFor = (1...slots).map(holder) }
            if cancel?.isCancelled == true { return .cancelled }
            let now = Date()
            if now.timeIntervalSince(start) >= timeout { return .busy(holders: (1...slots).map(holder)) }
            if let waiting, told.map({ now.timeIntervalSince($0) >= every }) ?? true {
                told = now
                waiting((1...slots).map(holder), ahead, now.timeIntervalSince(start))
            }
            usleep(useconds_t(min(500_000, max(10_000, every * 1_000_000 / 2))))
        }
    }
}
