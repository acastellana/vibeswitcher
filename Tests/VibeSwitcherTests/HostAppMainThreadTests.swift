import AppKit
import Foundation
import Testing
@testable import VibeSwitcher

/// Bringing Terminal or a session's host app to the front never waits on the main thread: `HostApp.bringToFront` asks
/// it (async) only to yield our activation, and the requests to the app and Launch Services (`HostApp.request`) run on
/// a queue of their own. A stand-in request that takes 2 s stands for a slow or hung host: it never runs on the main
/// thread, and main-queue blocks timed during it run on time (< 0.1 s late; tried again when other tests held the main
/// thread all through). The stand-in activates nothing, so no window moves.
@MainActor
@Suite(.serialized)
struct HostAppMainThreadTests {
    nonisolated static let requestTime: TimeInterval = 2

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// What the main thread did while a stand-in request of `requestTime` went on.
    struct Waited {
        /// The pids the stand-in was asked to bring forward.
        var requested: [Int32]
        /// Whether any request ran on the main thread.
        var requestOnMain: Bool
        /// How late each main-queue block due while the request went on (and not in its last 0.15 s) ran.
        var lateness: [TimeInterval]
    }

    /// Runs `call` off the main thread with `HostApp.request` replaced by one that takes `requestTime`; main-queue
    /// blocks are timed every 0.1 s from the moment it starts (it schedules them), so a main thread held by other tests
    /// before then doesn't count. A request on the main thread, or one it waits for, holds every one of them.
    private func whileRequesting(_ call: @escaping @Sendable () -> Void) async throws -> Waited {
        let started = Box<Date?>(nil), finished = Box<Date?>(nil), onMain = Box(false), requested = Box<[Int32]>([])
        let ran = Box<[(due: Date, at: Date)]>([]), steps = Int(Self.requestTime * 10)
        let original = HostApp.request
        defer { HostApp.request = original }
        HostApp.request = { app in
            if Thread.isMainThread { onMain.value = true }
            requested.value.append(app.processIdentifier)
            guard started.value == nil else { return }
            let origin = Date()
            started.value = origin
            for step in 1...steps {
                let delay = 0.1 * Double(step)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ran.value.append((origin + delay, Date())) }
            }
            Thread.sleep(forTimeInterval: Self.requestTime)
            finished.value = Date()
        }
        let done = Box(false)
        DispatchQueue.global(qos: .userInitiated).async {
            call()
            done.value = true
        }
        #expect(await until { done.value && finished.value != nil && ran.value.count == steps })
        let start = try #require(started.value), end = try #require(finished.value)
        #expect(end.timeIntervalSince(start) >= Self.requestTime - 0.05)
        let during = ran.value.filter { $0.due > start && $0.due < end - 0.15 }
        #expect(during.count >= steps / 2, "only \(during.count) blocks were due during the request")
        return Waited(requested: requested.value, requestOnMain: onMain.value,
                      lateness: during.map { $0.at.timeIntervalSince($0.due) })
    }

    /// `whileRequesting`, up to `attempts` times until a main-queue block due during the request ran on time.
    private func mainStaysFree(attempts: Int = 4, _ call: @escaping @Sendable () -> Void,
                               check: ([Int32]) -> Void) async throws {
        var seen: [[TimeInterval]] = []
        for _ in 1...attempts {
            let waited = try await whileRequesting(call)
            check(waited.requested)
            #expect(!waited.requestOnMain)
            seen.append(waited.lateness)
            if waited.lateness.contains(where: { $0 < 0.1 }) { return }
        }
        Issue.record("main-queue blocks ran late through every request: \(seen)")
    }

    /// Terminal's path (`AppDelegate.open`, the phone's input, a launch): `bringToFrontAndWait` off the main thread.
    /// The app is this test process, which is never frontmost, so the wait runs to its timeout.
    @Test func bringingTerminalForwardLeavesTheMainThreadFree() async throws {
        let me = NSRunningApplication.current
        try await mainStaysFree({ #expect(!HostApp.bringToFrontAndWait(me, timeout: 0.5)) }) { requested in
            #expect(requested.first == me.processIdentifier)
        }
    }

    /// Another host's path (`AppDelegate.open` for a session outside Terminal.app): `activate(forPID:)` off the main
    /// thread finds the GUI app (Finder here, always running) and returns before its request is done.
    @Test func activatingAHostAppLeavesTheMainThreadFree() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let returnedIn = Box<TimeInterval?>(nil)
        try await mainStaysFree({
            let start = Date()
            #expect(HostApp.activate(forPID: finder.processIdentifier))
            returnedIn.value = Date().timeIntervalSince(start)
        }) { requested in
            #expect(requested == [finder.processIdentifier])
            #expect((returnedIn.value ?? .infinity) < Self.requestTime / 2)
        }
    }
}
