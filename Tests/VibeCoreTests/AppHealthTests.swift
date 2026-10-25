import Foundation
import Testing
@testable import VibeCore

/// VibeSwitcher's own health digests (see `AppHealth`), from fake debug and DiagnosticReports folders in scratch, never
/// the app's own logs: a freeze's fields, a burst told once, a repeat counted, crashes, error kinds, the daily trend,
/// and none of what a message, transcript or attachment says.
struct AppHealthTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// What must never reach the lead: a message's words, a transcript's path, an attachment's, a project's name.
    static let secrets = ["SECRET-MESSAGE-TEXT", "secret-transcript", "SECRET-ATTACHMENT", "attachments/", "secret-project", ".jsonl"]

    func folders() throws -> AppHealth.Folders {
        let debug = temp.url("debug"), reports = temp.url("reports")
        for url in [debug, reports] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return AppHealth.Folders(debug: debug, reports: reports)
    }

    /// A hang's .log as `HangWatchdog` writes it, with a message, a transcript path and an attachment in its state and
    /// breadcrumbs.
    static func log(duration: Double? = 12.4, kind: String = "lead", key: Bool = true) -> String {
        AppHealth.hangHeader(since: Date(timeIntervalSince1970: 1_761_393_730), duration: duration) + "\n" + """
        Main thread stuck since 2026-10-25 12:02:10 +0000

        State:
        host state=connected sessions=5 live=4
        scanned sessions=3
        window visible=true key=\(key) frame={{0, 0}, {800, 600}} mounted=true
        selected=host:6F1A kind=\(kind) project=secret-project showsChat=true chatShown=true terminalHidden=true
        chat path=/Users/someone/.claude/projects/p/secret-transcript.jsonl state=loaded entries=10 items=4 shownLimit=200 atBottom=true pending=0 menu=false draft=31 chars
        attached terminals=1 current=none

        Latest events:
        14:02:09.000 composer: sent "please deploy the SECRET-MESSAGE-TEXT" error
        14:02:09.500 chat: attachment /Users/someone/.vibeswitcher/attachments/SECRET-ATTACHMENT.png

        """
    }

    /// A `sample` report whose main thread's busiest path runs through `frames` (outermost first) under a timer.
    static func sample(_ frames: [String] = ["SessionStore.rescan()", "specialized ChatModel.reload(from:)", "TranscriptReader.parse(_:)"]) -> String {
        var lines = """
        Analysis of sampling VibeSwitcher (pid 4242) every 1 millisecond
        Process:         VibeSwitcher [4242]
        Date/Time:       2026-10-25 14:02:12.345 +0200
        Launch Time:     2026-10-25 09:00:00.000 +0200

        Physical footprint:         812.4M
        Physical footprint (peak):  900.0M
        ----

        Call graph:
            2600 Thread_100   DispatchQueue_1: com.apple.main-thread  (serial)
            + 2600 start  (in dyld) + 6076  [0x18e0b0274]
            +   2600 main  (in VibeSwitcher) + 100  [0x100001000]
            +     2600 NSApplicationMain  (in AppKit) + 880  [0x1]
            +       2500 __CFRunLoopRun  (in CoreFoundation) + 1  [0x2]
            +       ! 2500 __CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__  (in CoreFoundation) + 32  [0x3]
            +       !   2500 thunk for @escaping @callee_guaranteed (@guaranteed NSTimer) -> ()  (in VibeSwitcher) + 28  [0x4]
            +       !     2500 closure #1 in Heartbeat.every(_:_:)  (in VibeSwitcher) + 40  [0x5]
        """.components(separatedBy: "\n")
        var depth = "    +       !       "
        for (index, frame) in frames.enumerated() {
            lines.append("\(depth)\(2400 - index) \(frame)  (in VibeSwitcher) + 12  [0x\(index + 6)]  File.swift:\(index)")
            depth += "  "
        }
        lines.append("\(depth)2300 memmove  (in libsystem_platform.dylib) + 1  [0x9]")
        lines += [
            "    +       !       100 LeadController.refresh()  (in VibeSwitcher) + 1  [0xa]",
            "    +       100 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0xb]",
            "    2600 Thread_101",
            "    + 2600 start_wqthread  (in libsystem_pthread.dylib) + 8  [0xc]",
            "    +   2600 OtherThing.work()  (in VibeSwitcher) + 1  [0xd]",
            "",
            "Total number in stack (recursive counted multiple times):",
        ]
        return lines.joined(separator: "\n")
    }

    func writeHang(_ name: String, in folders: AppHealth.Folders, log: String = Self.log(), sample: String = Self.sample()) throws {
        try log.write(to: folders.debug.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
        try sample.write(to: folders.debug.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    /// An .ips crash report of `program`: a header line, then the report.
    static func ips(program: String = "vibeswitcher-host", bugType: String = "309") -> String {
        let header = #"{"app_name":"\#(program)","timestamp":"2026-10-25 14:02:10.00 +0200","app_version":"1.4","build_version":"77","bug_type":"\#(bugType)","name":"\#(program)"}"#
        let body = #"""
        {"procName":"\#(program)","exception":{"codes":"0x1, 0x10","type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010"},
         "termination":{"indicator":"Segmentation fault: 11"},"faultingThread":1,
         "asi":{"libswiftCore.dylib":["Fatal error: SECRET-MESSAGE-TEXT"]},
         "threads":[{"frames":[{"symbol":"mach_msg2_trap","imageIndex":1}]},
                    {"triggered":true,"frames":[{"symbol":"HostedSession.feed(_:)","imageIndex":0},{"symbol":"HostServer.read()","imageIndex":0},{"imageIndex":1}]}],
         "usedImages":[{"name":"\#(program)","path":"/Users/someone/secret-project/.build/\#(program)"},{"name":"libsystem_kernel.dylib","path":"/usr/lib/system/libsystem_kernel.dylib"}]}
        """#
        return header + "\n" + body
    }

    func noSecrets(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in Self.secrets { #expect(!text.contains(secret), "\(secret) in:\n\(text)", sourceLocation: sourceLocation) }
    }

    let start = Date(timeIntervalSince1970: 1_761_393_730)

    // MARK: Freezes

    @Test func aHangReportReadsAsItsFields() {
        let hang = AppHealth.hang(name: "hang-20261025-140210", log: Self.log(), sample: Self.sample())
        #expect(hang.duration == 12.4)
        #expect(hang.since == start)
        #expect(hang.session == "lead")
        #expect(hang.shown == "chat")
        #expect(hang.key == true)
        #expect(hang.footprint == 812.4)
        #expect(hang.peak == 900)
        // The busiest path's app frames, the top of the stack first; thunks and the entry point left out.
        #expect(hang.frames == ["TranscriptReader.parse(_:)", "ChatModel.reload(from:)", "SessionStore.rescan()", "closure #1 in Heartbeat.every(_:_:)"])
        #expect(hang.signature == "TranscriptReader.parse(_:) < ChatModel.reload(from:) < SessionStore.rescan()")
    }

    @Test func aReportFromBeforeTheHeaderStillReads() {
        let old = Self.log().components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        let hang = AppHealth.hang(name: "hang-20261025-140210", log: old, sample: nil)
        #expect(hang.duration == nil)
        #expect(hang.since != nil)
        #expect(hang.session == "lead")
        #expect(hang.frames.isEmpty)
        let line = AppHealth.Watch.line([hang])
        #expect(line.contains("stuck, no recovery recorded"))
        #expect(line.contains("no app frames"))
    }

    @Test func aNewHangIsOneDigestWithItsFieldsAndNoMessageText() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        watch.baseline(hangs: folders.hangNames(), crashes: folders.crashFiles())
        try writeHang("hang-20261025-140210", in: folders)
        let new = watch.saw(hangs: folders.hangNames(), crashes: folders.crashFiles(), now: start)
        #expect(new)
        // Not before the window closes: more may come.
        watch.look(now: start.addingTimeInterval(AppHealth.window - 1), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        let digest = try #require(watch.pending.first)
        #expect(digest.contains("hang-20261025-140210: stuck 12.4 s; lead session selected, chat shown, window key; footprint 812 MB (peak 900 MB); "
                                + "top app frames: TranscriptReader.parse(_:) < ChatModel.reload(from:) < SessionStore.rescan() < closure #1 in Heartbeat.every(_:_:)"),
                "\(digest)")
        noSecrets(digest)
        // Seen once: the same files again aren't news.
        watch.pending = []
        let again = watch.saw(hangs: folders.hangNames(), crashes: folders.crashFiles(), now: start.addingTimeInterval(700))
        #expect(!again)
        watch.look(now: start.addingTimeInterval(2000), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
    }

    @Test func aFolderReadAsEmptyForAMomentDoesntMakeItsReportsNewAgain() throws {
        let folders = try folders()
        try writeHang("hang-20261025-140210", in: folders)
        var watch = AppHealth.Watch()
        watch.baseline(hangs: folders.hangNames(), crashes: folders.crashFiles())
        watch.saw(hangs: [], crashes: [], now: start)
        let again = watch.saw(hangs: folders.hangNames(), crashes: folders.crashFiles(), now: start.addingTimeInterval(1))
        #expect(!again)
        #expect(watch.opened == nil)
    }

    @Test func aHangNotSampledYetWaitsForTheNextDigest() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        // Its .log is written; `sample` is still running when the window closes, a minute after the freeze began.
        let name = "hang-20261025-140210"
        let began = start.addingTimeInterval(AppHealth.window - 60)
        try (AppHealth.hangHeader(since: began, duration: nil) + "\n" + Self.log().components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
            .write(to: folders.debug.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
        watch.saw(hangs: folders.hangNames(), crashes: [], now: start)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
        #expect(watch.hangs == [name])
        try writeHang(name, in: folders)
        watch.look(now: start.addingTimeInterval(2 * AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        #expect(watch.pending.first?.contains("top app frames: TranscriptReader.parse(_:)") == true, "\(watch.pending)")
    }

    @Test func whatWasThereAtTheFirstRunIsHistory() throws {
        let folders = try folders()
        try writeHang("hang-20261024-090000", in: folders)
        try Self.ips().write(to: folders.reports.appendingPathComponent("vibeswitcher-host-2026-10-24-090000.ips"), atomically: true, encoding: .utf8)
        var watch = AppHealth.Watch()
        watch.baseline(hangs: folders.hangNames(), crashes: folders.crashFiles())
        let new = watch.saw(hangs: folders.hangNames(), crashes: folders.crashFiles(), now: start)
        #expect(!new)
        watch.look(now: start.addingTimeInterval(3600), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
    }

    @Test func aBurstOfHangsIsOneDigest() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        let stacks = [["A.one()", "A.two()", "A.three()"], ["B.one()", "B.two()", "B.three()"], ["A.one()", "A.two()", "A.three()"]]
        for (index, frames) in stacks.enumerated() {
            try writeHang("hang-20261025-14021\(index)", in: folders, sample: Self.sample(frames))
            watch.saw(hangs: folders.hangNames(), crashes: [], now: start.addingTimeInterval(Double(index) * 120))
            watch.look(now: start.addingTimeInterval(Double(index) * 120 + 1), folders: folders, memory: nil)
        }
        #expect(watch.pending.isEmpty)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        let digest = try #require(watch.pending.first)
        // The two with the same top frames share a line.
        #expect(digest.contains("hang-20261025-140210 and 1 more like it (hang-20261025-140212)"), "\(digest)")
        #expect(digest.contains("hang-20261025-140211:"))
        #expect(watch.days[AppHealth.Watch.day(start)]?.hangs == 3)
    }

    @Test func aRepeatWithin24HoursIsCountedNotSent() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        try writeHang("hang-20261025-140210", in: folders)
        watch.saw(hangs: folders.hangNames(), crashes: [], now: start)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        watch.pending = []
        // The same top frames two hours on: counted against the digest told, no new one.
        let later = start.addingTimeInterval(2 * 3600)
        try writeHang("hang-20261025-160210", in: folders)
        watch.saw(hangs: folders.hangNames(), crashes: [], now: later)
        watch.look(now: later.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
        let key = "hang " + folders.hang("hang-20261025-140210").signature
        #expect(watch.told[key]?.repeats == 1)
        #expect(watch.told[key]?.first == "hang-20261025-140210")
        // A different freeze in the same window as a repeat is told, the repeat counted beside it.
        try writeHang("hang-20261025-170000", in: folders)
        try writeHang("hang-20261025-170100", in: folders, sample: Self.sample(["Other.freeze()"]))
        let third = start.addingTimeInterval(3 * 3600)
        watch.saw(hangs: folders.hangNames(), crashes: [], now: third)
        watch.look(now: third.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        let digest = try #require(watch.pending.first)
        #expect(digest.contains("hang-20261025-170100:"))
        #expect(!digest.contains("hang-20261025-170000:"))
        #expect(digest.contains("Seen again, told within 24 h, so only counted"))
        #expect(watch.told[key]?.repeats == 2)
        // Past 24 h it's news again.
        watch.pending = []
        let nextDay = start.addingTimeInterval(25 * 3600)
        try writeHang("hang-20261026-150210", in: folders)
        watch.saw(hangs: folders.hangNames(), crashes: [], now: nextDay)
        watch.look(now: nextDay.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.contains { $0.contains("hang-20261026-150210:") })
    }

    // MARK: Crashes

    @Test func aCrashReportReadsAsItsExceptionAndTopFrames() throws {
        let crash = try #require(AppHealth.crash(file: "vibeswitcher-host-2026-10-25-140210.ips", text: Self.ips()))
        #expect(crash.program == "vibeswitcher-host")
        #expect(crash.version == "1.4 (77)")
        #expect(crash.exception == "EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0000000000000010, Segmentation fault: 11")
        #expect(crash.frames == ["HostedSession.feed(_:) (vibeswitcher-host)", "HostServer.read() (vibeswitcher-host)", "??? (libsystem_kernel.dylib)"])
        // Not a crash (a resource report), another program's, a file still being written: none.
        #expect(AppHealth.crash(file: "VibeSwitcher-2026-10-25-140210.ips", text: Self.ips(program: "VibeSwitcher", bugType: "202")) == nil)
        #expect(AppHealth.crashProgram(file: "Safari-2026-10-25-140210.ips") == nil)
        #expect(AppHealth.crashProgram(file: "VibeSwitcher-2026-10-25-140210.ips") == "VibeSwitcher")
        #expect(AppHealth.crashProgram(file: "vibeswitcher-mcp-2026-10-25-140210.ips") == "vibeswitcher-mcp")
        #expect(AppHealth.crashProgram(file: "vibeswitcher-hook-2026-10-25-140210.ips") == nil)
        #expect(AppHealth.crash(file: "vibeswitcher-host-2026-10-25-140210.ips", text: String(Self.ips().prefix(200))) == nil)
    }

    @Test func aNewCrashIsToldWithoutWhatItsMessageSaid() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        try Self.ips().write(to: folders.reports.appendingPathComponent("vibeswitcher-host-2026-10-25-140210.ips"), atomically: true, encoding: .utf8)
        try Self.ips(program: "Safari").write(to: folders.reports.appendingPathComponent("Safari-2026-10-25-140210.ips"), atomically: true, encoding: .utf8)
        #expect(folders.crashFiles() == ["vibeswitcher-host-2026-10-25-140210.ips"])
        watch.saw(hangs: [], crashes: folders.crashFiles(), now: start)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        let digest = try #require(watch.pending.first)
        #expect(digest.contains("- vibeswitcher-host-2026-10-25-140210.ips: vibeswitcher-host 1.4 (77): EXC_BAD_ACCESS (SIGSEGV)"), "\(digest)")
        #expect(digest.contains("top frames: HostedSession.feed(_:) (vibeswitcher-host) < HostServer.read() (vibeswitcher-host)"))
        #expect(!digest.contains("Safari"))
        noSecrets(digest)
        #expect(watch.days[AppHealth.Watch.day(start)]?.crashes == 1)
    }

    // MARK: Error lines

    @Test func errorLinesAreToldAsKindsAndCounts() throws {
        #expect(AppHealth.errorKind("14:02:09.000 composer: couldn't save the outbox: SECRET-MESSAGE-TEXT") == "composer: couldn't")
        #expect(AppHealth.errorKind("14:02:09.000 lead: its role wasn't bound to its session: Error Domain=x") == "lead: error")
        #expect(AppHealth.errorKind("14:02:09.000 spawn failed: no such folder '/Users/someone/secret-project'") == "spawn failed: failed")
        #expect(AppHealth.errorKind("14:02:09.000 SECRET-MESSAGE-TEXT: cannot do it") == "app: cannot")
        #expect(AppHealth.errorKind("14:02:09.000 chat: apiError shown") == nil)
        #expect(AppHealth.errorKind("14:02:09.000 main thread stuck since now; sampling into hang-1.txt") == nil)
        let folders = try folders()
        var watch = AppHealth.Watch()
        watch.saw(lines: ["14:02:09.000 composer: couldn't save the outbox: SECRET-MESSAGE-TEXT",
                          "14:02:10.000 composer: couldn't save the outbox: SECRET-MESSAGE-TEXT",
                          "14:02:11.000 lead: couldn't bind the running lead of secret-project again: x",
                          "14:02:12.000 window: present"], now: start)
        watch.look(now: start.addingTimeInterval(AppHealth.window), folders: folders, memory: nil)
        let digest = try #require(watch.pending.first)
        #expect(digest.contains("Error lines in app.log within 10 min, by kind: composer: couldn't ×2, lead: couldn't ×1"), "\(digest)")
        noSecrets(digest)
        // The same kinds within 24 h: counted, no message.
        watch.pending = []
        watch.saw(lines: ["15:00:00.000 composer: couldn't save the outbox"], now: start.addingTimeInterval(3600))
        watch.look(now: start.addingTimeInterval(3600 + AppHealth.window), folders: folders, memory: nil)
        #expect(watch.pending.isEmpty)
        #expect(watch.days[AppHealth.Watch.day(start)]?.errors == 4)
    }

    // MARK: The daily trend

    func day(_ offset: Int, hour: Int = 12) -> Date {
        let base = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: start)!
        return Calendar.current.date(byAdding: .day, value: offset, to: base)!
    }

    @Test func aQuietDaySendsNothing() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        watch.look(now: day(0), folders: folders, memory: AppHealth.Memory(footprint: 300, peak: 320, atLaunch: 290, launched: day(0, hour: 9)))
        watch.look(now: day(1, hour: 0), folders: folders, memory: AppHealth.Memory(footprint: 305, peak: 320, atLaunch: 290, launched: day(0, hour: 9)))
        #expect(watch.pending.isEmpty)
    }

    @Test func aDayWithFreezesGetsOneTrendLine() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        // A freeze each of the 7 days before, then 5 on the day.
        for offset in -7 ... -1 { watch.days[AppHealth.Watch.day(day(offset))] = AppHealth.Watch.Day(hangs: 1, crashes: 0, errors: 0) }
        watch.days[AppHealth.Watch.day(day(0))] = AppHealth.Watch.Day(hangs: 5, crashes: 1, errors: 12)
        watch.lookedOn = AppHealth.Watch.day(day(0))
        let memory = AppHealth.Memory(footprint: 1300, peak: 1400, atLaunch: 300, launched: day(0, hour: 4))
        watch.look(now: day(1, hour: 0), folders: folders, memory: memory)
        #expect(watch.pending.count == 1)
        let trend = try #require(watch.pending.first)
        #expect(trend.contains("VibeSwitcher's day, \(AppHealth.Watch.day(day(0)))"), "\(trend)")
        #expect(trend.contains("5 freezes (1.0 a day over the 7 days before), 1 crash, 12 error lines."))
        #expect(trend.contains("footprint 1300 MB, peak 1400 MB since launch 20 h ago, +50 MB an hour since launch (growing: worth a look)."))
        // Once a day.
        watch.look(now: day(1, hour: 9), folders: folders, memory: memory)
        #expect(watch.pending.count == 1)
    }

    @Test func memoryGrowingFastIsWorthATrendOnAnotherwiseQuietDay() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        watch.lookedOn = AppHealth.Watch.day(day(0))
        watch.look(now: day(1, hour: 0), folders: folders, memory: AppHealth.Memory(footprint: 2000, peak: 2100, atLaunch: 300, launched: day(0, hour: 0)))
        #expect(watch.pending.count == 1)
        #expect(watch.pending[0].contains("0 freezes"))
        #expect(watch.pending[0].contains("growing: worth a look"))
    }

    @Test func theTrendCountsRepeatsOnce() throws {
        let folders = try folders()
        var watch = AppHealth.Watch()
        watch.lookedOn = AppHealth.Watch.day(day(0))
        watch.told["hang A.one() < A.two() < A.three()"] = AppHealth.Watch.Told(at: day(0).timeIntervalSince1970, repeats: 3, first: "hang-20261025-120000")
        watch.look(now: day(1, hour: 0), folders: folders, memory: nil)
        #expect(watch.pending.count == 1)
        #expect(watch.pending[0].contains("hang A.one() < A.two() < A.three() ×3 (first hang-20261025-120000)"), "\(watch.pending[0])")
        #expect(watch.told.values.allSatisfy { $0.repeats == 0 })
    }

    // MARK: The workflow key

    @Test func watchAppLogsIsOffUnlessTheProjectSetsIt() throws {
        #expect(LeadWorkflow().watchAppLogs == false)
        #expect(LeadWorkflow.parse("---\nmax_workers: 2\n---\n").watchAppLogs == false)
        #expect(LeadWorkflow.parse("---\nwatch_app_logs: true\n---\n").watchAppLogs == true)
        #expect(LeadWorkflow.parse("---\nwatch_app_logs: maybe\n---\n").watchAppLogs == false)
        #expect(LeadWorkflow.configurable.contains("watch_app_logs"))
    }

    @Test func configureSetsWatchAppLogs() throws {
        let root = try folder("health-lead").path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("configure", [:]).text.contains("watch_app_logs"))
        let set = lead.call("configure", ["watch_app_logs": true])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("watch_app_logs: true"))
        #expect(lead.workflow.watchAppLogs)
        #expect(lead.call("configure", ["watch_app_logs": "sometimes"]).isError)
        #expect(!lead.call("configure", ["watch_app_logs": ""]).isError)
        #expect(!lead.workflow.watchAppLogs)
    }

    func folder(_ name: String) throws -> URL {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
}
