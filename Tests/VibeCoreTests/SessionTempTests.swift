import Foundation
import Testing
@testable import VibeCore

/// The lead, each worker and each verifier start with a TMPDIR of their own, which goes with them: SwiftPM leaves empty
/// TemporaryDirectory.XXXXXX folders in TMPDIR at every swift build (7) and swift test (5) and never removes them, and
/// sessions' ad hoc runs had left 32,871 in the user's /var/folders/…/T/ by 2026-10-20. Nothing here starts a session:
/// the launch's command and environment are read as `LeadLaunch.prepare` returns them.
struct SessionTempTests {
    let temp = Scratch()

    func folder(_ name: String) throws -> URL {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func mode(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    }

    func session(cwd: String, command: String?, live: Bool) -> HostSession {
        HostSession(id: UUID(), tty: "ttys001", childPID: 1, cwd: cwd, command: command, label: "", agent: "claude", title: "",
                    startedAt: Date(), cols: 80, rows: 24, exit: live ? nil : HostSession.Exit(status: 0, at: Date()))
    }

    /// Settled: last changed longer ago than `SessionTemp.settle`.
    func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-SessionTemp.settle - 5)], ofItemAtPath: url.path)
    }

    /// The user's own sessions' go in /private/tmp, short enough for a socket under them (104 bytes): under 60
    /// characters however long the project's path and the task's name. A scratch VibeSwitcher (a test run, a bench)
    /// keeps them in its own folder.
    @Test func theFolderIsShortAndEachSessionsOwn() {
        let account = "/Users/someone"
        let root = SessionTemp.root(vibeRoot: URL(fileURLWithPath: account + "/.vibeswitcher"), accountHome: account)
        #expect(root.path == "/private/tmp/vibeswitcher-\(getuid())")
        let deep = "/Users/someone/" + String(repeating: "very-deep/", count: 20) + ".vibeswitcher/worktrees/"
        let worker = SessionTemp.folder(cwd: deep + "a-task-with-a-long-name-indeed", name: "worker-a-task-with-a-long-name-indeed", in: root)
        #expect(worker.path.count < 60)
        #expect(worker.path.hasPrefix(root.path + "/"))
        // Its verifier's, another task's, another project's: each its own.
        let others = [SessionTemp.folder(cwd: deep + "a-task-with-a-long-name-indeed", name: "verify-a-task-with-a-long-name-indeed", in: root),
                      SessionTemp.folder(cwd: deep + "another", name: "worker-another", in: root),
                      SessionTemp.folder(cwd: "/Users/someone/other/.vibeswitcher/worktrees/a-task-with-a-long-name-indeed",
                                         name: "worker-a-task-with-a-long-name-indeed", in: root)]
        #expect(Set(others + [worker]).count == 4)
        let scratch = URL(fileURLWithPath: "/somewhere/scratch/.vibeswitcher")
        #expect(SessionTemp.root(vibeRoot: scratch, accountHome: account).path == scratch.appendingPathComponent("tmp").path)
    }

    /// The lead's, a worker's and a verifier's command start with TMPDIR set to a folder of their own (0700, made now),
    /// found by where they run and their name: the lead's in the project, a task's sessions' in its worktree. The command
    /// line itself doesn't change.
    @Test func everyRolesSessionStartsWithItsOwnTMPDIR() throws {
        let root = try folder("launch").path
        let sessions = try folder("tmpdirs")
        let lead = try LeadLaunch.prepare(role: .lead, root: root, task: nil, base: "claude", prompt: "p", start: "Go.",
                                          server: "/s", name: "lead-acme", folder: temp.url("run-lead"), cwd: root, temporary: sessions)
        let worker = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: "p", start: "Go.",
                                            server: "/s", name: "worker-x", folder: temp.url("run-worker"), temporary: sessions)
        let verifier = try LeadLaunch.prepare(role: .verifier, root: root, task: "x", base: "claude", prompt: "p", start: "Check.",
                                              server: "/s", name: "verify-x", folder: temp.url("run-verifier"), temporary: sessions)
        let worktree = Worktrees.path(root: root, slug: "x")
        #expect(lead.environment == ["TMPDIR": SessionTemp.folder(cwd: root, name: "lead-acme", in: sessions).path + "/"])
        #expect(worker.environment == ["TMPDIR": SessionTemp.folder(cwd: worktree, name: "worker-x", in: sessions).path + "/"])
        #expect(verifier.environment == ["TMPDIR": SessionTemp.folder(cwd: worktree, name: "verify-x", in: sessions).path + "/"])
        for launch in [lead, worker, verifier] {
            let tmpdir = try #require(launch.environment["TMPDIR"])
            #expect(try mode(tmpdir) == 0o700)
            #expect(launch.command.hasPrefix("claude "))
            #expect(!launch.command.contains("TMPDIR"))
        }
        #expect(try mode(sessions.path) == 0o700)
        // The worker's and the verifier's are the task's, the lead's isn't.
        #expect(SessionTemp.folders(for: worktree, in: sessions).map { $0.path + "/" }
                == [worker.environment["TMPDIR"]!, verifier.environment["TMPDIR"]!].sorted())
        // Prepared again (a worker restarted): the same folder, still there.
        let again = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: "p", start: "Go.",
                                           server: "/s", name: "worker-x", folder: temp.url("run-worker"), temporary: sessions)
        #expect(again.environment == worker.environment)
    }

    /// Anyone can make a folder in /tmp: when the root is something else in its place (a link to elsewhere), the
    /// session keeps the TMPDIR it has. One of the user's that's open to others is made private (0700).
    @Test func aRootThatIsntAFolderOfTheUsersGivesNoTMPDIR() throws {
        let root = try folder("launch").path
        let link = temp.url("link"), elsewhere = try folder("elsewhere")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let launch = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: "p", start: "Go.",
                                            server: "/s", name: "worker-x", folder: temp.url("run"), temporary: link)
        #expect(launch.environment == [:])
        // Nothing made or changed where it points.
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [])
        #expect(try mode(elsewhere.path) == 0o755)
        let open = try folder("open")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: open.path)
        #expect(SessionTemp.make(cwd: root, name: "worker-x", in: open) != nil)
        #expect(try mode(open.path) == 0o700)
    }

    /// /tmp is anyone's: a root that's a link (to a folder of the user's full of names like a session's) or isn't 0700
    /// is read as empty, so neither cleanup (`folders`) nor the app (`removable`) removes anything there.
    @Test func aRootThatIsntPrivateIsNeverEmptied() throws {
        let worktree = "/Users/x/dev/app/.vibeswitcher/worktrees/one"
        let target = try folder("users-folder")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        var names = [SessionTemp.folder(cwd: worktree, name: "worker-one", in: target).lastPathComponent, "abc-def", "src-main"]
        names.sort()
        for name in names {
            try FileManager.default.createDirectory(at: target.appendingPathComponent(name), withIntermediateDirectories: true)
            try age(target.appendingPathComponent(name))
        }
        // The same folder, read directly, is a root like any other: these would go.
        #expect(SessionTemp.removable(in: target, sessions: []).map(\.lastPathComponent) == names)
        #expect(SessionTemp.folders(for: worktree, in: target).count == 1)

        let link = temp.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(SessionTemp.removable(in: link, sessions: []) == [])
        #expect(SessionTemp.folders(for: worktree, in: link) == [])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        #expect(SessionTemp.removable(in: target, sessions: []) == [])
        #expect(SessionTemp.folders(for: worktree, in: target) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == names)
    }

    /// What the app removes once the host's list says so: the folders no live session uses (an ended one's, or one a
    /// host that's gone left) once they've settled; never a live session's, nor one just made for a session that
    /// isn't listed yet, nor anything else in the root.
    @Test func theAppRemovesWhatNoLiveSessionUses() throws {
        let sessions = try folder("tmpdirs")
        let worktree = "/Users/x/dev/app/.vibeswitcher/worktrees/one"
        let command = { (name: String) in "claude --append-system-prompt-file '/p' --name '\(name)' -- 'Go.'" }
        let live = try #require(SessionTemp.make(cwd: worktree, name: "worker-one", in: sessions))
        let ended = try #require(SessionTemp.make(cwd: worktree, name: "verify-one", in: sessions))
        let orphan = try #require(SessionTemp.make(cwd: "/Users/x/dev/app", name: "lead-app", in: sessions))
        let starting = try #require(SessionTemp.make(cwd: worktree, name: "finder2-one", in: sessions))
        let other = sessions.appendingPathComponent("not-ours.txt")
        try Data().write(to: other)
        for url in [live, ended, orphan, other] { try age(url) }
        // A swift build's leftovers in the ended one: it goes with them.
        try FileManager.default.createDirectory(at: ended.appendingPathComponent("TemporaryDirectory.abc123"), withIntermediateDirectories: true)
        try age(ended)
        let list = [session(cwd: worktree, command: command("worker-one"), live: true),
                    session(cwd: worktree, command: command("verify-one"), live: false),
                    session(cwd: worktree, command: nil, live: true)]
        #expect(SessionTemp.removable(in: sessions, sessions: list) == [ended, orphan].sorted { $0.path < $1.path })
        // Ended a moment ago: not yet.
        #expect(SessionTemp.removable(in: sessions, sessions: list, now: Date().addingTimeInterval(-SessionTemp.settle - 10)) == [])
        #expect(!SessionTemp.removable(in: sessions, sessions: list).contains(starting))
    }

    /// A process with its working folder in `folder` (what a live pytest does to its run's folder), until killed.
    func holding(_ folder: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["3600"]
        process.currentDirectoryURL = folder
        try process.run()
        return process
    }

    func end(_ process: Process) {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    /// While a session lives, its TMPDIR loses what pytest keeps of earlier runs (a worker's pytest left 2.6 GB there on
    /// 2026-10-22, 3 GB free on the disk): each pytest-of-*'s pytest-N but the newest, and never one a live process
    /// holds. pytest's own pytest-current link and anything else stay.
    @Test func theSweepKeepsTheNewestPytestRunAndWhatALiveProcessHolds() throws {
        let sessions = try folder("tmpdirs")
        let worktree = "/Users/x/dev/TGE/.vibeswitcher/worktrees/one"
        let command = "claude --append-system-prompt-file '/p' --name 'worker-one' -- 'Go.'"
        let live = try #require(SessionTemp.make(cwd: worktree, name: "worker-one", in: sessions))
        let pytest = live.appendingPathComponent("pytest-of-x")
        let runs = (1...4).map { pytest.appendingPathComponent("pytest-\($0)") }
        for run in runs {
            try FileManager.default.createDirectory(at: run.appendingPathComponent("test_a0"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1000).write(to: run.appendingPathComponent("test_a0/data.bin"))
        }
        try FileManager.default.createSymbolicLink(at: pytest.appendingPathComponent("pytest-current"), withDestinationURL: runs[3])
        try Data().write(to: live.appendingPathComponent("notes.txt"))
        let holder = try holding(runs[1].appendingPathComponent("test_a0"))
        defer { end(holder) }
        let list = [session(cwd: worktree, command: command, live: true)]

        let removed = SessionTemp.sweep(sessions: list, in: sessions, handovers: nil)
        #expect(removed.map(\.path) == [runs[0], runs[2]].map(\.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: pytest.path).sorted() == ["pytest-2", "pytest-4", "pytest-current"])
        #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("notes.txt").path))
        // Let go: it goes at the next sweep; the newest stays.
        end(holder)
        #expect(SessionTemp.sweep(sessions: list, in: sessions, handovers: nil).map(\.path) == [runs[1].path])
        #expect(SessionTemp.sweep(sessions: list, in: sessions, handovers: nil) == [])
        #expect(FileManager.default.fileExists(atPath: runs[3].appendingPathComponent("test_a0/data.bin").path))
        // Processes that can't be read: nothing goes.
        try FileManager.default.createDirectory(at: pytest.appendingPathComponent("pytest-5"), withIntermediateDirectories: true)
        #expect(SessionTemp.sweep(sessions: list, in: sessions, handovers: nil, open: { nil }) == [])
    }

    /// The same sweep takes an ended session's TMPDIR whole (unless a process it left still holds it), and what the
    /// session host's handover tests leave in /tmp when their run is killed (vsho-XXXXXXXX, 6 of them 275 MB on
    /// 2026-10-22) once untouched past `handoverSettle`: never a recent one, one a live process holds, a link, or
    /// another name.
    @Test func theSweepRemovesEndedSessionsFoldersAndHandoverTestsLeftovers() throws {
        let sessions = try folder("tmpdirs")
        let worktree = "/Users/x/dev/app/.vibeswitcher/worktrees/one"
        let ended = try #require(SessionTemp.make(cwd: worktree, name: "verify-one", in: sessions))
        let lingering = try #require(SessionTemp.make(cwd: worktree, name: "worker-one", in: sessions))
        try FileManager.default.createDirectory(at: ended.appendingPathComponent("pytest-of-x/pytest-1"), withIntermediateDirectories: true)
        for url in [ended, lingering] { try age(url) }
        let tmp = try folder("tmp")
        let old = Date().addingTimeInterval(-SessionTemp.handoverSettle - 60)
        func make(_ name: String, at date: Date, folder: Bool = true) throws -> URL {
            let url = tmp.appendingPathComponent(name)
            if folder {
                try FileManager.default.createDirectory(at: url.appendingPathComponent("home"), withIntermediateDirectories: true)
                try Data("log".utf8).write(to: url.appendingPathComponent("session.log"))
                for child in ["home", "session.log"] {
                    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.appendingPathComponent(child).path)
                }
            } else {
                try Data("state".utf8).write(to: url)
            }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let stale = try make("vsho-0123ABCD", at: old)
        let state = try make("vsho-state-89ABCDEF", at: old, folder: false)
        let recent = try make("vsho-11111111", at: Date())
        let held = try make("vsho-22222222", at: old)
        let other = try make("vsh-44444444", at: old)
        let link = tmp.appendingPathComponent("vsho-33333333")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        // A log written lately in an old folder: still in use.
        let touched = try make("vsho-55555555", at: old)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: touched.appendingPathComponent("session.log").path)
        let holder = try holding(held.appendingPathComponent("home")), straggler = try holding(lingering)
        defer { end(holder); end(straggler) }
        let command = { (name: String) in "claude --append-system-prompt-file '/p' --name '\(name)' -- 'Go.'" }
        let list = [session(cwd: worktree, command: command("verify-one"), live: false),
                    session(cwd: worktree, command: command("worker-one"), live: false)]

        let removed = SessionTemp.sweep(sessions: list, in: sessions, handovers: tmp)
        #expect(removed.map(\.path) == [ended, stale, state].map(\.path), "\(removed)")
        for url in [lingering, recent, held, other, link, touched] { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
        // The user's own VibeSwitcher sweeps /private/tmp; a scratch one (this test run's) no handover folders.
        #expect(SessionTemp.handoverRoot == nil)
    }

    /// When disk space is low, status names every project's session TMPDIR over 500 MB, by its project and task.
    @Test func bigTMPDIRsAreNamedByProjectAndTask() throws {
        let sessions = try folder("tmpdirs")
        let tge = "/Users/x/dev/TGE-ANALYSIS"
        let worker = try #require(SessionTemp.make(cwd: tge + "/.vibeswitcher/worktrees/oktgmi", name: "worker-oktgmi", in: sessions))
        let lead = try #require(SessionTemp.make(cwd: tge, name: "lead-tge", in: sessions))
        let gone = try #require(SessionTemp.make(cwd: "/Users/x/dev/gone", name: "lead-gone", in: sessions))
        let small = try #require(SessionTemp.make(cwd: "/Users/x/dev/small", name: "lead-small", in: sessions))
        let sizes = [worker.path: 2_600_000_000, lead.path: 600_000_000, gone.path: 900_000_000, small.path: 400_000_000] as [String: Int64]
        let big = SessionTemp.big(cwds: [tge + "/.vibeswitcher/worktrees/oktgmi", tge, "/Users/x/dev/small"], in: sessions,
                                  size: { sizes[$0] ?? 0 })
        #expect(big.map(\.path) == [worker.path, gone.path, lead.path])
        #expect(big[0].text == "the TMPDIR of a session on TGE-ANALYSIS's task oktgmi, 2.6 GB (\(worker.path))")
        #expect(big[1].text == "the TMPDIR of a session no longer listed, 900 MB (\(gone.path))")
        #expect(big[2].text == "the TMPDIR of a session in TGE-ANALYSIS (not a task's), 600 MB (\(lead.path))")
        let text = LeadWitness.diskText(free: DiskSpace.bytes(3), workflow: LeadWorkflow(), folders: [], tmpdirs: big)
        #expect(text.contains("Sessions' TMPDIRs over 500 MB (every project's): the TMPDIR of a session on TGE-ANALYSIS's task oktgmi, 2.6 GB"), "\(text)")
    }
}
