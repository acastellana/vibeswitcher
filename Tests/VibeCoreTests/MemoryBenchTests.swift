import Foundation
import Testing
@testable import VibeCore

/// The memory benches the app runs by itself once a day (`MemoryBench`): when it decides to run, the watch that starts
/// and gives up runs (an injected clock, conditions and run: no bench runs here), the run's scratch worktree and record
/// (a scratch repository and a small script in place of the benches), and the app-health line a failing budget makes.
struct MemoryBenchTests {
    private let scratch = Scratch()

    // MARK: When

    /// A calm night: on AC, awake, load 2–3, a slot free, no merge.
    static let calm = MemoryBench.Conditions(onAC: true, load: [2.4, 2.9, 3.1], awake: true, slotFree: true, merge: nil)

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func aCalmNightOnACRuns() {
        #expect(MemoryBench.decide(now: Self.date("2026-11-18 03:00"), state: .init(), conditions: Self.calm) == .run)
    }

    @Test func itRunsAtMostOnceADay() {
        let ran = MemoryBench.State(lastRun: Self.date("2026-11-18 02:10").timeIntervalSince1970)
        #expect(MemoryBench.decide(now: Self.date("2026-11-18 05:00"), state: ran, conditions: Self.calm) == .wait("ran today"))
        #expect(MemoryBench.decide(now: Self.date("2026-11-18 23:59"), state: ran, conditions: Self.calm) == .wait("ran today"))
        // A later day, but under 12 h since it began: not yet.
        let late = MemoryBench.State(lastRun: Self.date("2026-11-18 23:30").timeIntervalSince1970)
        #expect(MemoryBench.decide(now: Self.date("2026-11-19 02:00"), state: late, conditions: Self.calm) == .wait("ran under 12 h ago"))
        #expect(MemoryBench.decide(now: Self.date("2026-11-19 11:31"), state: late, conditions: Self.calm) == .run)
        #expect(MemoryBench.decide(now: Self.date("2026-11-19 02:10"), state: ran, conditions: Self.calm) == .run)
    }

    @Test func onlyWhenCalm() {
        let now = Self.date("2026-11-18 03:00")
        func with(_ change: (inout MemoryBench.Conditions) -> Void) -> MemoryBench.Decision {
            var conditions = Self.calm
            change(&conditions)
            return MemoryBench.decide(now: now, state: .init(), conditions: conditions)
        }
        #expect(with { $0.onAC = false } == .wait("on battery"))
        #expect(with { $0.onAC = nil } == .wait("the power source didn't say AC"))
        #expect(with { $0.awake = false } != .run)
        #expect(with { $0.merge = "VibeSwitcher's merge test of 1234abcd" } == .wait("a merge's tests run: VibeSwitcher's merge test of 1234abcd"))
        #expect(with { $0.slotFree = false } == .wait("no heavy slot free"))
        #expect(with { $0.load = nil } == .wait("the load wasn't read"))
        // The threshold: the 1- and the 5-minute load both under 4.
        #expect(with { $0.load = [4.0, 2, 2] } != .run)
        #expect(with { $0.load = [3.9, 4.1, 2] } != .run)
        #expect(with { $0.load = [3.9, 3.9, 9] } == .run)
    }

    @Test func aRunGivenUpIsTriedAgainHalfAnHourLater() {
        let gaveUp = MemoryBench.State(gaveUp: Self.date("2026-11-18 03:00").timeIntervalSince1970)
        #expect(MemoryBench.decide(now: Self.date("2026-11-18 03:20"), state: gaveUp, conditions: Self.calm) != .run)
        #expect(MemoryBench.decide(now: Self.date("2026-11-18 03:31"), state: gaveUp, conditions: Self.calm) == .run)
    }

    @Test func aRunUnderWayStopsForPowerSleepOrAMergeNotForItsOwnLoad() {
        #expect(MemoryBench.stillFine(Self.calm) == nil)
        var busy = Self.calm
        busy.load = [14, 10, 6]
        busy.slotFree = false
        #expect(MemoryBench.stillFine(busy) == nil)
        busy.onAC = false
        #expect(MemoryBench.stillFine(busy) == "on battery")
        var merging = Self.calm
        merging.merge = "VibeSwitcher's batch merge test of 1234abcd"
        #expect(MemoryBench.stillFine(merging) != nil)
    }

    @Test func aMergesTestsAreFoundHoldingOrWaitingForASlot() {
        let since = Date()
        let merge = TestLock.Holder(slot: 1, note: "pid 1, VibeSwitcher's merge test of 1234abcd in /r/p, since 02:00:00", since: since)
        let suite = TestLock.Holder(slot: 2, note: "pid 2, scripts/test.sh in /r/p/.vibeswitcher/worktrees/x, since 02:00:00", since: since)
        let waiting = TestLock.Waiter(number: 3, slots: 2, who: TestLock.Holder(slot: 0, note: "pid 3, VibeSwitcher's revert test of 9a in /r/p, since 02:01:00", since: since))
        #expect(MemoryBench.merge(holders: [suite], waiters: []) == nil)
        #expect(MemoryBench.merge(holders: [suite, merge], waiters: []) == "VibeSwitcher's merge test of 1234abcd")
        #expect(MemoryBench.merge(holders: [suite], waiters: [waiting]) == "VibeSwitcher's revert test of 9a")
        // Its own run isn't a merge.
        let own = TestLock.Holder(slot: 1, note: "pid 4, VibeSwitcher's memory benches of 1234abcd in /h/.vibeswitcher/memory-bench/checkout, since 02:00:00", since: since)
        #expect(MemoryBench.merge(holders: [own], waiters: []) == nil)
    }

    // MARK: Budgets and records

    @Test func aBudgetsLineIsReadBack() {
        let budgets = [
            MemoryBench.Budget(name: "footprint-window-closed-mb", value: 72.37, limit: 150, unit: "MB", pass: true),
            MemoryBench.Budget(name: "churn-growth-percent", value: 12.5, limit: 10, unit: "%", pass: false),
            MemoryBench.Budget(name: "soak-hour-growth-mb", value: nil, limit: 30, unit: "MB/h", pass: nil),
        ]
        #expect(budgets[0].line == "BUDGET footprint-window-closed-mb 72.37 150 MB pass")
        #expect(budgets[2].line == "BUDGET soak-hour-growth-mb n/a 30 MB/h unjudged")
        // Swift Testing's output around them, a line that only looks like one, and a later line for the same name.
        let output = "Building...\n" + budgets.map(\.line).joined(separator: "\n")
            + "\nBUDGET bad name with spaces 1 2 MB pass\nBUDGET x 1 2 MB maybe\n◇ Test footprint passed\n"
            + "BUDGET churn-growth-percent 9 10 % pass\n"
        var expected = budgets
        expected[1] = MemoryBench.Budget(name: "churn-growth-percent", value: 9, limit: 10, unit: "%", pass: true)
        #expect(MemoryBench.Budget.parse(output) == expected)
        #expect(MemoryBench.Budget(name: "x", value: 3, limit: 10, unit: "%", judged: true, within: { $0 <= 10 }).pass == true)
        #expect(MemoryBench.Budget(name: "x", value: nil, limit: 10, unit: "%", judged: true, within: { $0 <= 10 }).pass == false)
        #expect(MemoryBench.Budget(name: "x", value: 30, limit: 10, unit: "%", judged: false, within: { $0 <= 10 }).pass == nil)
    }

    @Test func aRunsResultFollowsItsBudgetsAndItsEnd() {
        let pass = MemoryBench.Budget(name: "a", value: 1, limit: 2, unit: "MB", pass: true)
        let fail = MemoryBench.Budget(name: "b", value: 3, limit: 2, unit: "MB", pass: false)
        let unjudged = MemoryBench.Budget(name: "c", value: 3, limit: 2, unit: "MB", pass: nil)
        #expect(MemoryBench.Record.result(budgets: [pass], exitStatus: 0, timedOut: false).result == "pass")
        #expect(MemoryBench.Record.result(budgets: [pass, fail], exitStatus: 1, timedOut: false).result == "fail")
        #expect(MemoryBench.Record.result(budgets: [pass, unjudged], exitStatus: 0, timedOut: false).result == "unjudged")
        #expect(MemoryBench.Record.result(budgets: [pass], exitStatus: 1, timedOut: false).result == "error")
        #expect(MemoryBench.Record.result(budgets: [], exitStatus: 0, timedOut: false).result == "error")
        #expect(MemoryBench.Record.result(budgets: [pass], exitStatus: 0, timedOut: true) == ("error", "ran past 90 min and was stopped"))
    }

    // MARK: The watch

    /// A clock, conditions and a run of the test's own.
    final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var now = MemoryBenchTests.date("2026-11-18 03:00")
        var conditions = MemoryBenchTests.calm
        var enabled = true
        var starts = 0
        /// Set to end the run under way as recorded.
        var release = false
        var outcomes: [MemoryBench.Run.Outcome] = []

        func get<T>(_ read: (Fake) -> T) -> T { lock.lock(); defer { lock.unlock() }; return read(self) }
        func set(_ change: (Fake) -> Void) { lock.lock(); change(self); lock.unlock() }

        /// Waits for a release (recorded) or its cancel (given up), whichever comes first.
        func go(_ run: MemoryBench.Run) -> MemoryBench.Run.Outcome {
            set { $0.starts += 1 }
            let cancel = ShellCancel.current
            while !get({ $0.release }) {
                if cancel?.isCancelled == true { return .gaveUp }
                usleep(5000)
            }
            set { $0.release = false }
            return .recorded(MemoryBench.Record(t: "", day: "", commit: String(repeating: "a", count: 40), result: "pass", durationS: 1, budgets: []))
        }
    }

    func watch(_ fake: Fake, stateFile: URL? = nil) -> MemoryBenchWatch {
        let run = MemoryBench.Run(root: "/nowhere", base: "main", folder: scratch.url("mb"), stats: scratch.url("stats"))
        let sources = MemoryBenchWatch.Sources(
            enabled: { fake.get(\.enabled) }, conditions: { fake.get(\.conditions) }, plan: { _ in run }, now: { fake.get(\.now) },
            go: { fake.go($0) }, ended: { outcome in fake.set { $0.outcomes.append(outcome) } })
        return MemoryBenchWatch(sources: sources, stateFile: stateFile ?? scratch.url("state").appendingPathComponent("state.json"))
    }

    @Test func theWatchRunsOnceADayAndKeepsItAcrossLaunches() async {
        let fake = Fake()
        let stateFile = scratch.url("state").appendingPathComponent("state.json")
        let watch = watch(fake, stateFile: stateFile)
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 1 })
        #expect(watch.isRunning)
        // A tick while it runs starts nothing more.
        watch.tick()
        fake.set { $0.release = true }
        #expect(await eventually { fake.get(\.outcomes).count == 1 && !watch.isRunning })
        fake.set { $0.now = MemoryBenchTests.date("2026-11-18 05:00") }
        watch.tick()
        #expect(!watch.isRunning && fake.get(\.starts) == 1)
        // The next night: again.
        fake.set { $0.now = MemoryBenchTests.date("2026-11-19 03:00") }
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 2 })
        fake.set { $0.release = true }
        #expect(await eventually { fake.get(\.outcomes).count == 2 && !watch.isRunning })
        #expect(watch.current.lastRun == MemoryBenchTests.date("2026-11-19 03:00").timeIntervalSince1970)
        // Another launch the same day reads the state and doesn't run.
        let later = Fake()
        later.now = MemoryBenchTests.date("2026-11-19 06:00")
        let again = self.watch(later, stateFile: stateFile)
        #expect(again.current == watch.current)
        again.tick()
        #expect(!again.isRunning && later.get(\.starts) == 0)
    }

    @Test func aRunWhoseConditionsChangeIsGivenUpQuietlyAndTriedLater() async {
        let fake = Fake()
        let watch = watch(fake)
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 1 })
        // Unplugged: the next tick cancels it, nothing is recorded.
        fake.set { $0.conditions.onAC = false; $0.now = MemoryBenchTests.date("2026-11-18 03:05") }
        watch.tick()
        #expect(await eventually { fake.get(\.outcomes) == [.gaveUp] && !watch.isRunning })
        #expect(watch.current.lastRun == nil && watch.current.gaveUp == MemoryBenchTests.date("2026-11-18 03:05").timeIntervalSince1970)
        // Plugged in again: not before half an hour, then it runs.
        fake.set { $0.conditions.onAC = true; $0.now = MemoryBenchTests.date("2026-11-18 03:20") }
        watch.tick()
        #expect(!watch.isRunning && fake.get(\.starts) == 1)
        fake.set { $0.now = MemoryBenchTests.date("2026-11-18 03:40") }
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 2 })
        // A merge's tests starting: given up again.
        fake.set { $0.conditions.merge = "VibeSwitcher's merge test of 1234abcd" }
        watch.tick()
        #expect(await eventually { fake.get(\.outcomes) == [.gaveUp, .gaveUp] && !watch.isRunning })
    }

    @Test func sleepGivesUpTheRunAndAWakeWaitsTenMinutes() async {
        let fake = Fake()
        let watch = watch(fake)
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 1 })
        watch.sleeping()
        #expect(await eventually { fake.get(\.outcomes) == [.gaveUp] && !watch.isRunning })
        // Asleep (a dark wake's tick): nothing starts.
        fake.set { $0.now = MemoryBenchTests.date("2026-11-18 04:00") }
        watch.tick()
        #expect(!watch.isRunning && fake.get(\.starts) == 1)
        watch.woke(at: MemoryBenchTests.date("2026-11-18 04:00"))
        fake.set { $0.now = MemoryBenchTests.date("2026-11-18 04:05") }
        watch.tick()
        #expect(!watch.isRunning && fake.get(\.starts) == 1)
        fake.set { $0.now = MemoryBenchTests.date("2026-11-18 04:11") }
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 2 })
        fake.set { $0.release = true }
        #expect(await eventually { fake.get(\.outcomes).count == 2 && !watch.isRunning })
    }

    @Test func turnedOffItNeitherRunsNorKeepsRunning() async {
        let fake = Fake()
        fake.enabled = false
        let watch = watch(fake)
        watch.tick()
        #expect(!watch.isRunning && fake.get(\.starts) == 0)
        fake.set { $0.enabled = true }
        watch.tick()
        #expect(await eventually { fake.get(\.starts) == 1 })
        fake.set { $0.enabled = false }
        watch.tick()
        #expect(await eventually { fake.get(\.outcomes) == [.gaveUp] && !watch.isRunning })
    }

    // MARK: The run

    func repo() throws -> String {
        let root = scratch.url("repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                     ["commit", "-q", "--allow-empty", "-m", "first"]] {
            #expect(Git.run(args, in: root).ok, "git \(args)")
        }
        return root
    }

    func commit(_ subject: String, in root: String) -> String {
        Git.run(["commit", "-q", "--allow-empty", "-m", subject], in: root)
        return Git.run(["rev-parse", "HEAD"], in: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func run(_ root: String, folder: URL, stats: URL, _ script: String, timeout: TimeInterval = hangGuard) -> MemoryBench.Run {
        MemoryBench.Run(root: root, base: "main", folder: folder, stats: stats, command: ["/bin/bash", "-c", script], timeout: timeout)
    }

    @Test func aRunBenchesMainsHeadInAScratchWorktreeItRemovesAndAppendsOneLine() async throws {
        let root = try repo()
        let head = commit("the head", in: root)
        // A branch checked out elsewhere: main's head is benched, not what the checkout has.
        #expect(Git.run(["checkout", "-q", "-b", "other"], in: root).ok)
        _ = commit("not on main", in: root)
        let folder = scratch.url("vs").appendingPathComponent(MemoryBench.folderName)
        let stats = scratch.url("stats")
        let seen = scratch.url("seen")
        let bench = run(root, folder: folder, stats: stats,
                        "git rev-parse HEAD > '\(seen.path)'; pwd -P >> '\(seen.path)'; echo 'BUDGET footprint-window-closed-mb 72.4 150 MB pass'")
        let outcome = await offPool { bench.go() }
        guard case .recorded(let record) = outcome else { Issue.record("\(outcome)"); return }
        let lines = try String(contentsOf: seen, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == head)
        // In the worktree (/tmp is /private/tmp).
        #expect(lines.last.map { $0.replacingOccurrences(of: "/private/", with: "/") } == bench.checkout.path.replacingOccurrences(of: "/private/", with: "/"))
        #expect(record.commit == head && record.result == "pass" && record.budgets.count == 1)
        #expect(record.day == LoadStats.day(Date()))
        // Gone, and gone from git's list.
        #expect(!FileManager.default.fileExists(atPath: bench.checkout.path))
        #expect(!Git.run(["worktree", "list"], in: root).output.contains(MemoryBench.folderName))
        let written = try String(contentsOf: stats.appendingPathComponent(MemoryBench.statsName), encoding: .utf8)
        #expect(written.split(separator: "\n").count == 1)
        #expect(written.contains("\"commit\":\"\(head)\"") && written.contains("\"duration_s\":") && written.contains("\"limit\":150"))
        #expect(MemoryBench.Record.all(in: stats.appendingPathComponent(MemoryBench.statsName)) == [record])
        // The output is kept for a look.
        #expect(try String(contentsOf: bench.log, encoding: .utf8).contains("BUDGET footprint-window-closed-mb"))
        let mode = try FileManager.default.attributesOfItem(atPath: stats.appendingPathComponent(MemoryBench.statsName).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aFailNamesTheCommitsSinceTheLastPass() async throws {
        let root = try repo()
        let folder = scratch.url("vs").appendingPathComponent(MemoryBench.folderName)
        let stats = scratch.url("stats")
        let passed = run(root, folder: folder, stats: stats, "echo 'BUDGET soak-hour-growth-mb 4 30 MB/h pass'")
        guard case .recorded(let first) = await offPool({ passed.go() }) else { Issue.record("no first record"); return }
        #expect(first.result == "pass" && first.lastPass == nil)
        _ = commit("Chat: keep the transcript's rows", in: root)
        _ = commit("Footprint: cache the session list", in: root)
        let failed = run(root, folder: folder, stats: stats, "echo 'BUDGET soak-hour-growth-mb 41.5 30 MB/h fail'; exit 1")
        guard case .recorded(let record) = await offPool({ failed.go() }) else { Issue.record("no second record"); return }
        #expect(record.result == "fail")
        #expect(record.lastPass == first.commit)
        #expect(record.sincePass == ["Footprint: cache the session list", "Chat: keep the transcript's rows"])
        #expect(MemoryBench.Record.all(in: stats.appendingPathComponent(MemoryBench.statsName)).count == 2)
    }

    @Test func aHungRunIsEndedByItsTimeoutAndRecordedAsAnError() async throws {
        let root = try repo()
        let folder = scratch.url("vs").appendingPathComponent(MemoryBench.folderName)
        let stats = scratch.url("stats")
        let pidFile = scratch.url("pid")
        // Hangs after saying its pid; the run's limit ends it, and everything it started.
        let hung = run(root, folder: folder, stats: stats, "sleep 600 & echo $! > '\(pidFile.path)'; wait", timeout: 2)
        guard case .recorded(let record) = await offPool({ hung.go() }) else { Issue.record("no record"); return }
        #expect(record.result == "error" && record.note?.contains("ran past") == true)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { kill(pid, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: hung.checkout.path))
    }

    @Test func aRunCancelledIsGivenUpRecordingNothing() async throws {
        let root = try repo()
        let folder = scratch.url("vs").appendingPathComponent(MemoryBench.folderName)
        let stats = scratch.url("stats")
        let started = scratch.url("started")
        let bench = run(root, folder: folder, stats: stats, "touch '\(started.path)'; sleep 600")
        let cancel = ShellCancel()
        async let outcome = offPool { ShellCancel.with(cancel) { bench.go() } }
        #expect(await eventually { FileManager.default.fileExists(atPath: started.path) })
        cancel.cancel()
        #expect(await outcome == .gaveUp)
        #expect(!FileManager.default.fileExists(atPath: stats.appendingPathComponent(MemoryBench.statsName).path))
        #expect(!FileManager.default.fileExists(atPath: bench.checkout.path))
    }

    @Test func anythingUnexpectedStopsItBeforeItRuns() async throws {
        let root = try repo()
        let stats = scratch.url("stats")
        let ran = scratch.url("ran")
        let script = "touch '\(ran.path)'"
        // Its folder a link to somewhere else.
        let elsewhere = scratch.url("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let parent = scratch.url("vs")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let linked = parent.appendingPathComponent(MemoryBench.folderName)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        guard case .refused = await offPool({ run(root, folder: linked, stats: stats, script).go() }) else { Issue.record("ran in a linked folder"); return }
        // A link where the worktree goes: left as it is, nothing run.
        let folder = scratch.url("vs2").appendingPathComponent(MemoryBench.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bench = run(root, folder: folder, stats: stats, script)
        try FileManager.default.createSymbolicLink(at: bench.checkout, withDestinationURL: elsewhere)
        guard case .refused = await offPool({ bench.go() }) else { Issue.record("ran over a linked checkout"); return }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        // A base that isn't a plain branch name, or has no commit.
        var odd = run(root, folder: scratch.url("vs3").appendingPathComponent(MemoryBench.folderName), stats: stats, script)
        for base in ["../main", "-main", "main;rm", "nothing-here"] {
            odd.base = base
            guard case .refused = await offPool({ odd.go() }) else { Issue.record("ran with base \(base)"); return }
        }
        #expect(!FileManager.default.fileExists(atPath: ran.path))
        #expect(!FileManager.default.fileExists(atPath: stats.appendingPathComponent(MemoryBench.statsName).path))
    }

    @Test func aCheckoutACrashLeftIsRemovedFirst() async throws {
        let root = try repo()
        let folder = scratch.url("vs").appendingPathComponent(MemoryBench.folderName)
        let stats = scratch.url("stats")
        let bench = run(root, folder: folder, stats: stats, "test ! -e left-behind && echo 'BUDGET a 1 2 MB pass'")
        try VibePaths.ensurePrivate(folder)
        #expect(Git.run(["worktree", "add", "--detach", "-q", bench.checkout.path, "main"], in: root).ok)
        FileManager.default.createFile(atPath: bench.checkout.appendingPathComponent("left-behind").path, contents: Data())
        guard case .recorded(let record) = await offPool({ bench.go() }) else { Issue.record("no record"); return }
        #expect(record.result == "pass")
    }

    @Test func theBenchesCommandHoldsASlotWithATimeout() {
        let command = MemoryBench.Run.command(commit: String(repeating: "c", count: 40))
        #expect(command.prefix(4) == ["/bin/bash", "Resources/bin/vs-heavy", "--as", "VibeSwitcher's memory benches of cccccccc"])
        #expect(command.contains("--timeout") && command[command.firstIndex(of: "--timeout")! + 1] == "90m")
        #expect(Array(command.suffix(7)) == ["/bin/bash", "scripts/test.sh", "--perf", "--filter", MemoryBench.filter, "--skip", MemoryBench.skip])
        // The skip leaves the two memory benches and nothing else of --perf's list.
        let skip = try! Regex(MemoryBench.skip)
        #expect(!"VibeSwitcherTests.FootprintBenchTests/theWindowClosedIsUnder150MBAndChurnGrowsItAtMost10Percent()".contains(skip))
        #expect(!"VibeSwitcherTests.SandboxSoakBenchTests".contains(skip))
        #expect("VibeSwitcherTests.ChatBenchTests/theChatSettlesWithoutAStall()".contains(skip))
        #expect("VibeSwitcherTests.ChatMemoryTests".contains(skip))
    }

    // MARK: The report

    @Test func aFailingBudgetIsOneLineOfTheAppHealthReportToldOnce() throws {
        let record = MemoryBench.Record(
            t: "2026-11-19T03:00:00+01:00", day: "2026-11-19", commit: "1234abcd" + String(repeating: "0", count: 32), result: "fail", durationS: 1500,
            budgets: [MemoryBench.Budget(name: "footprint-window-closed-mb", value: 162.4, limit: 150, unit: "MB", pass: false),
                      MemoryBench.Budget(name: "soak-hour-growth-mb", value: 4, limit: 30, unit: "MB/h", pass: true),
                      MemoryBench.Budget(name: "churn-growth-percent", value: 14, limit: 10, unit: "%", pass: false)],
            lastPass: "abcdef12" + String(repeating: "0", count: 32), sincePass: ["Chat: keep rows", "Sidebar: cache icons"])
        var watch = AppHealth.Watch()
        let folders = AppHealth.Folders(debug: scratch.url("debug"), reports: scratch.url("reports"))
        let now = MemoryBenchTests.date("2026-11-19 04:00")
        watch.look(now: now, folders: folders, memory: nil, bench: { record })
        let report = try #require(watch.pending.first)
        let lines = report.split(separator: "\n").filter { $0.hasPrefix("- memory budget failed: ") }
        #expect(lines == [
            "- memory budget failed: footprint-window-closed-mb 162.4 MB, limit 150 MB; commits since the last pass (abcdef12): \"Chat: keep rows\"; \"Sidebar: cache icons\"",
            "- memory budget failed: churn-growth-percent 14 %, limit 10 %; commits since the last pass (abcdef12): \"Chat: keep rows\"; \"Sidebar: cache icons\"",
        ])
        #expect(report.contains("main at 1234abcd on 2026-11-19"))
        // It wakes the lead, and isn't told again.
        #expect(AppHealth.wakes(report))
        watch.pending = []
        watch.look(now: now.addingTimeInterval(60), folders: folders, memory: nil, bench: { record })
        #expect(watch.pending.isEmpty)
        // A run that passed, or none yet, says nothing.
        var quiet = AppHealth.Watch()
        var passed = record
        passed.result = "pass"
        passed.budgets = [record.budgets[1]]
        quiet.look(now: now, folders: folders, memory: nil, bench: { passed })
        quiet.look(now: now, folders: folders, memory: nil, bench: { nil })
        #expect(quiet.pending.isEmpty)
        // With no pass before it.
        var first = record
        first.lastPass = nil
        first.sincePass = nil
        var fresh = AppHealth.Watch()
        fresh.look(now: now, folders: folders, memory: nil, bench: { first })
        #expect(fresh.pending.first?.contains("no run has passed yet to compare with") == true)
    }
}
