import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The app's watch of its own logs (see `AppHealthWatcher`), on fake debug and DiagnosticReports folders and an app.log
/// in scratch, never the app's own: file events bring each new report in, one digest goes out per burst, a repeat isn't
/// sent again, a relaunch neither repeats nor misses one, and only a project with watch_app_logs gets them.
@MainActor
struct AppHealthWatcherTests {
    let temp = Scratch()

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    struct World {
        let folders: AppHealth.Folders
        let appLog: URL
        let stateFile: URL
        let clock: Box<Date>
        let sent: Box<[String]>
        let takes: Box<Bool>
    }

    func world() throws -> World {
        let debug = temp.url("debug"), reports = temp.url("reports")
        for url in [debug, reports] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let appLog = debug.appendingPathComponent("app.log")
        try "09:00:00.000 app: launched\n".write(to: appLog, atomically: true, encoding: .utf8)
        return World(folders: AppHealth.Folders(debug: debug, reports: reports), appLog: appLog,
                     stateFile: temp.url("state").appendingPathComponent("app-health.json"),
                     clock: Box(Date(timeIntervalSince1970: 1_761_393_730)), sent: Box([]), takes: Box(true))
    }

    /// A watcher on `world`'s folders, started, with what it took in counted in `took`.
    func watcher(_ world: World, took: Box<Int>) async -> AppHealthWatcher {
        let watcher = AppHealthWatcher(folders: world.folders, appLog: world.appLog, stateFile: world.stateFile,
                                       now: { world.clock.value }, memory: { nil }, timed: false) { text in
            guard world.takes.value else { return false }
            world.sent.value.append(text)
            return true
        }
        watcher.tookIn = { took.value += 1 }
        watcher.start()
        // Started once its first run saved what was there.
        _ = await until { FileManager.default.fileExists(atPath: world.stateFile.path) }
        _ = watcher.state
        return watcher
    }

    static let log = AppHealth.hangHeader(since: Date(timeIntervalSince1970: 1_761_393_730), duration: 3.5) + """

        Main thread stuck since 2026-10-25 12:02:10 +0000

        State:
        window visible=true key=false frame={{0, 0}, {800, 600}} mounted=true
        selected=host:6F1A kind=worker project=secret-project showsChat=false chatShown=false terminalHidden=false
        chat path=/Users/someone/.claude/projects/p/secret-transcript.jsonl state=loaded

        Latest events:
        14:02:09.000 composer: sent "SECRET-MESSAGE-TEXT"

        """

    static func sample(_ frame: String) -> String {
        """
        Physical footprint:         512.0M
        Physical footprint (peak):  640.0M
        ----

        Call graph:
            100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 100 main  (in VibeSwitcher) + 1  [0x1]
            +   100 \(frame).outer()  (in VibeSwitcher) + 1  [0x2]
            +     100 \(frame).middle()  (in VibeSwitcher) + 1  [0x3]
            +       100 \(frame).inner()  (in VibeSwitcher) + 1  [0x4]

        """
    }

    func writeHang(_ name: String, frame: String = "Terminal", in world: World) throws {
        try Self.log.write(to: world.folders.debug.appendingPathComponent(name + ".log"), atomically: true, encoding: .utf8)
        try Self.sample(frame).write(to: world.folders.debug.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Past the digest's window, and the watcher looks.
    func closeWindow(_ watcher: AppHealthWatcher, _ world: World) {
        world.clock.value = world.clock.value.addingTimeInterval(AppHealth.window)
        watcher.look()
    }

    @Test func aNewHangFileIsOneReportWithItsFields() async throws {
        let world = try world()
        let took = Box(0)
        let watcher = await watcher(world, took: took)
        defer { watcher.stop() }
        try writeHang("hang-20261025-140210", in: world)
        #expect(await until { watcher.state.hangs == ["hang-20261025-140210"] })
        closeWindow(watcher, world)
        #expect(await until { world.sent.value.count == 1 })
        let digest = try #require(world.sent.value.first)
        #expect(digest.contains("hang-20261025-140210: stuck 3.5 s; worker session selected, terminal shown, window not key; footprint 512 MB (peak 640 MB); "
                                + "top app frames: Terminal.inner() < Terminal.middle() < Terminal.outer()"), "\(digest)")
        for secret in ["SECRET-MESSAGE-TEXT", "secret-transcript", "secret-project"] { #expect(!digest.contains(secret)) }
        // Told once.
        world.clock.value = world.clock.value.addingTimeInterval(3600)
        watcher.look()
        #expect(watcher.state.pending.isEmpty)
        #expect(world.sent.value.count == 1)
    }

    @Test func aBurstIsOneReportAndARepeatIsCounted() async throws {
        let world = try world()
        let took = Box(0)
        let watcher = await watcher(world, took: took)
        defer { watcher.stop() }
        for (index, frame) in ["Terminal", "Chat", "Terminal"].enumerated() {
            try writeHang("hang-20261025-14021\(index)", frame: frame, in: world)
        }
        #expect(await until { watcher.state.hangs.count == 3 })
        closeWindow(watcher, world)
        #expect(await until { world.sent.value.count == 1 })
        #expect(world.sent.value[0].contains("hang-20261025-140210 and 1 more like it (hang-20261025-140212)"), "\(world.sent.value[0])")
        #expect(world.sent.value[0].contains("hang-20261025-140211:"))
        // The same freeze an hour on: counted, not sent.
        world.clock.value = world.clock.value.addingTimeInterval(3600)
        try writeHang("hang-20261025-151000", in: world)
        #expect(await until { watcher.state.hangs == ["hang-20261025-151000"] })
        closeWindow(watcher, world)
        #expect(await until { watcher.state.opened == nil })
        #expect(world.sent.value.count == 1)
        #expect(watcher.state.told.values.contains { $0.first == "hang-20261025-140210" && $0.repeats == 1 })
    }

    @Test func aCrashReportAndErrorLinesAreToldTogether() async throws {
        let world = try world()
        let took = Box(0)
        let watcher = await watcher(world, took: took)
        defer { watcher.stop() }
        let header = #"{"app_name":"VibeSwitcher","app_version":"1.4","bug_type":"309","name":"VibeSwitcher"}"#
        let body = #"{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"threads":[{"triggered":true,"frames":[{"symbol":"SessionStore.apply(_:)","imageIndex":0}]}],"usedImages":[{"name":"VibeSwitcher"}]}"#
        try (header + "\n" + body).write(to: world.folders.reports.appendingPathComponent("VibeSwitcher-2026-10-25-140210.ips"), atomically: true, encoding: .utf8)
        try append("14:02:11.000 composer: couldn't save the outbox: SECRET-MESSAGE-TEXT\n14:02:12.000 window: present\n", to: world.appLog)
        #expect(await until { watcher.state.crashes.count == 1 && watcher.state.errors == ["composer: couldn't": 1] })
        // app.log rotates (as Breadcrumbs does it): the new file's lines count too.
        try FileManager.default.moveItem(at: world.appLog, to: world.appLog.appendingPathExtension("1"))
        try "14:03:00.000 lead: couldn't bind the running lead of secret-project again\n".write(to: world.appLog, atomically: false, encoding: .utf8)
        #expect(await until { watcher.state.errors["lead: couldn't"] == 1 })
        closeWindow(watcher, world)
        #expect(await until { world.sent.value.count == 1 })
        let digest = world.sent.value[0]
        #expect(digest.contains("- VibeSwitcher-2026-10-25-140210.ips: VibeSwitcher 1.4: EXC_BREAKPOINT (SIGTRAP); top frames: SessionStore.apply(_:) (VibeSwitcher)"), "\(digest)")
        #expect(digest.contains("by kind: composer: couldn't ×1, lead: couldn't ×1"))
        for secret in ["SECRET-MESSAGE-TEXT", "secret-project"] { #expect(!digest.contains(secret)) }
    }

    @Test func aRelaunchNeitherRepeatsNorMissesAReport() async throws {
        let world = try world()
        // At the first run what's there is history.
        try writeHang("hang-20261024-090000", in: world)
        let took = Box(0)
        let first = await watcher(world, took: took)
        try writeHang("hang-20261025-140210", in: world)
        #expect(await until { first.state.hangs == ["hang-20261025-140210"] })
        closeWindow(first, world)
        #expect(await until { world.sent.value.count == 1 })
        first.stop()
        // While the app is down: its own crash, and a freeze before it.
        try writeHang("hang-20261025-160000", frame: "Chat", in: world)
        let again = await watcher(world, took: took)
        defer { again.stop() }
        #expect(await until { again.state.hangs == ["hang-20261025-160000"] })
        closeWindow(again, world)
        #expect(await until { world.sent.value.count == 2 })
        #expect(world.sent.value[1].contains("hang-20261025-160000:"))
        #expect(!world.sent.value[1].contains("hang-20261025-140210") && !world.sent.value.joined().contains("hang-20261024-090000"))
    }

    @Test func aDigestNoLeadTookIsSentAtTheNextLook() async throws {
        let world = try world()
        world.takes.value = false
        let took = Box(0)
        let watcher = await watcher(world, took: took)
        defer { watcher.stop() }
        try writeHang("hang-20261025-140210", in: world)
        #expect(await until { watcher.state.hangs.count == 1 })
        closeWindow(watcher, world)
        #expect(await until { watcher.state.pending.count == 1 && world.sent.value.isEmpty && !watcher.isSending })
        world.takes.value = true
        world.clock.value = world.clock.value.addingTimeInterval(300)
        watcher.look()
        #expect(await until { world.sent.value.count == 1 && watcher.state.pending.isEmpty })
    }

    @Test func onlyAProjectWithWatchAppLogsGetsThem() throws {
        func project(_ name: String, workflow: String?) throws -> String {
            let root = temp.url(name).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
            if let workflow { try workflow.write(to: root.appendingPathComponent(".vibeswitcher/workflow.md"), atomically: true, encoding: .utf8) }
            return root.path
        }
        let builds = try project("vibeswitcher", workflow: "---\nwatch_app_logs: true\n---\n")
        let off = try project("project-c", workflow: "---\nwatch_app_logs: false\n---\n")
        let unset = try project("films", workflow: "---\nmax_workers: 2\n---\n")
        let none = try project("tge", workflow: nil)
        #expect(LeadController.appHealthRoots([builds, off, unset, none]) == [builds])
        #expect(LeadController.appHealthRoots([off, unset, none]).isEmpty)
    }
}
