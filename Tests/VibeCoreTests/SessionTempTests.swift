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
}
