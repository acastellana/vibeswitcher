import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Check for Updates on a node (`UpdateWatch`): the newest v2 commit both CI workflows passed, compared with the running
/// build, said by `status` with its install line; kept across restarts, asked again only when due. GitHub is a stand-in.
struct UpdateWatchTests {
    private let scratch = Scratch()

    private static func sha(_ c: Character) -> String { String(repeating: c, count: 40) }
    private let running = sha("a"), newer = sha("b"), newest = sha("c")

    private func run(_ id: Int, _ workflow: String, _ sha: String, _ conclusion: String? = "success", status: String = "completed",
                     event: String = "push") -> UpdateWatch.Run {
        UpdateWatch.Run(databaseId: id, workflowName: workflow, headSha: sha, status: status, conclusion: conclusion, event: event)
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.withLock { value } }
        func set(_ newValue: Value) { lock.withLock { value = newValue } }
    }

    /// GitHub as a stand-in: its runs, and compare's answer by (base, head); counts the calls.
    final class FakeHub: @unchecked Sendable {
        let lock = NSLock()
        var runs: Result<[UpdateWatch.Run], UpdateWatch.Refusal> = .success([])
        var compared: [String: String] = [:]
        var calls = 0
        var looker: UpdateWatch.Looker {
            UpdateWatch.Looker(runs: { [self] in
                lock.withLock { calls += 1; return runs }
            }, compare: { [self] base, head in
                lock.withLock {
                    guard let status = compared["\(base)...\(head)"] else { return .failure(.init("no compare of \(base)...\(head)")) }
                    return .success(.init(status: status, aheadBy: status == "ahead" ? 3 : 0))
                }
            })
        }
    }

    @Test func aCommitIsGreenOnlyWhenEachWorkflowsLatestRunPassed() {
        let runs = [
            run(1, "v2 linux", newer), run(2, "v2 macos", newer),
            // The newest: macos's re-run failed after a pass (the higher id is the latest).
            run(3, "v2 linux", newest), run(4, "v2 macos", newest), run(5, "v2 macos", newest, "failure"),
            // One workflow only, one still running, a pull request's run.
            run(6, "v2 linux", Self.sha("d")),
            run(7, "v2 linux", Self.sha("e")), run(8, "v2 macos", Self.sha("e"), nil, status: "in_progress"),
            run(9, "v2 linux", Self.sha("f"), event: "pull_request"), run(10, "v2 macos", Self.sha("f"), event: "pull_request"),
            // Not a commit.
            run(11, "v2 linux", "main"), run(12, "v2 macos", "main"),
        ]
        #expect(UpdateWatch.green(runs) == [newer])
        #expect(UpdateWatch.green(runs + [run(13, "v2 macos", newest)]) == [newest, newer])
    }

    @Test func aNewerGreenCommitOnV2IsOffered() throws {
        let hub = FakeHub()
        hub.runs = .success([run(1, "v2 linux", newer), run(2, "v2 macos", newer)])
        hub.compared = ["\(running)...\(newer)": "ahead", "\(newer)...v2": "ahead"]
        #expect(try UpdateWatch.decide(running: running, looker: hub.looker).get() == .init(commit: newer, aheadBy: 3))
        // The running build is the newest green one, or newer than it, or off v2's line: nothing.
        #expect(try UpdateWatch.decide(running: newer, looker: hub.looker).get() == nil)
        hub.compared["\(running)...\(newer)"] = "behind"
        #expect(try UpdateWatch.decide(running: running, looker: hub.looker).get() == nil)
        hub.compared["\(running)...\(newer)"] = "diverged"
        #expect(try UpdateWatch.decide(running: running, looker: hub.looker).get() == nil)
        // Dropped from v2 since its run (a force push): nothing.
        hub.compared = ["\(running)...\(newer)": "ahead", "\(newer)...v2": "diverged"]
        #expect(try UpdateWatch.decide(running: running, looker: hub.looker).get() == nil)
        // No green run at all.
        hub.runs = .success([run(1, "v2 linux", newer)])
        #expect(try UpdateWatch.decide(running: running, looker: hub.looker).get() == nil)
        // GitHub not asked, or a build whose commit isn't known.
        hub.runs = .failure(.init("gh has no token for github.com (gh auth login)"))
        #expect((try? UpdateWatch.decide(running: running, looker: hub.looker).get()) == nil)
        #expect((try? UpdateWatch.decide(running: "unknown", looker: hub.looker).get()) == nil)
    }

    @Test func theNoticeNamesTheCommitAndTheInstallLine() throws {
        let record = UpdateWatch.Record(running: running, checkedAt: Date(), offer: .init(commit: newer, aheadBy: 1))
        let notice = try #require(UpdateWatch.notice(record, running: running))
        #expect(notice.contains(newer) && notice.contains("(1 commit ahead)"))
        #expect(notice.contains("scripts/install-node.sh \(newer), then `vibeswitcher switch \(newer)`"))
        // Kept for another build (since switched): not this one's.
        #expect(UpdateWatch.notice(record, running: newest) == nil)
        #expect(UpdateWatch.notice(UpdateWatch.Record(running: running, checkedAt: Date()), running: running) == nil)
    }

    /// Looked at when due only (2 minutes after the start, then every 6 hours), the answer kept on disk, so a restart
    /// says it at once and doesn't ask again before its time; a failure keeps the last answer and says why.
    @Test func aLookIsKeptAndAskedAgainOnlyWhenDue() async throws {
        let hub = FakeHub()
        hub.runs = .success([run(1, "v2 linux", newer), run(2, "v2 macos", newer)])
        hub.compared = ["\(running)...\(newer)": "ahead", "\(newer)...v2": "identical"]
        let file = scratch.url("update-check.json")
        let queue = DispatchQueue(label: "update-watch-test")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Box(start)
        let notes = Box<[String]>([])
        func watch() -> UpdateWatch {
            UpdateWatch(file: file, running: running, looker: hub.looker, queue: queue, now: { clock.get() },
                        note: { line in notes.set(notes.get() + [line]) })
        }
        func look(_ watch: UpdateWatch) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { watch.look { done.resume() } } }
        }
        var first = watch()
        #expect(queue.sync { first.due(at: start) } == false)
        #expect(queue.sync { first.due(at: start.addingTimeInterval(UpdateWatch.firstDelay)) })
        await look(first)
        #expect(queue.sync { first.notice }?.contains(newer) == true)
        #expect(queue.sync { first.value["install"]?.string } == UpdateWatch.installLine(newer))
        #expect(hub.calls == 1)

        // A restart: the answer at once, and no look until 6 hours after the last.
        clock.set(start.addingTimeInterval(3600))
        first = watch()
        #expect(queue.sync { first.notice }?.contains(newer) == true)
        #expect(queue.sync { first.due(at: start.addingTimeInterval(3600 + UpdateWatch.firstDelay)) } == false)
        #expect(queue.sync { first.due(at: start.addingTimeInterval(UpdateWatch.interval + 1)) })

        // A failure keeps the last answer, says why once, and waits its interval.
        hub.lock.withLock { hub.runs = .failure(.init("gh run list failed: offline")) }
        await look(first)
        await look(first)
        #expect(queue.sync { first.notice }?.contains(newer) == true)
        #expect(queue.sync { first.value["problem"]?.string } == "gh run list failed: offline")
        #expect(notes.get().filter { $0.contains("couldn't look") }.count == 1)
        #expect(queue.sync { first.due(at: clock.get().addingTimeInterval(UpdateWatch.interval - 1)) } == false)

        // Up to date after a switch to the newer build: its first look is due at once, and finds nothing newer.
        hub.lock.withLock { hub.runs = .success([run(1, "v2 linux", newer), run(2, "v2 macos", newer)]) }
        let switched = UpdateWatch(file: file, running: newer, looker: hub.looker, queue: queue, now: { clock.get() }, note: { _ in })
        #expect(queue.sync { switched.notice } == nil)
        #expect(queue.sync { switched.due(at: clock.get().addingTimeInterval(UpdateWatch.firstDelay)) })
        await look(switched)
        #expect(queue.sync { switched.notice } == nil)
        #expect(queue.sync { switched.value["checkedAt"] } != .null)
        #expect(queue.sync { switched.value["problem"] } == .null)
    }

    /// The repository and workflows are the install script's, which checks the commit again before it builds.
    @Test func theRepositoryAndWorkflowsAreTheInstallScripts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install-node.sh"), encoding: .utf8)
        #expect(script.contains("local -r repository=\(UpdateWatch.repository)\n"))
        let workflows = UpdateWatch.workflows.map { "\"\($0)\"" }.joined(separator: " ")
        #expect(script.contains("local -r workflows=(\(workflows))\n"))
    }
}
