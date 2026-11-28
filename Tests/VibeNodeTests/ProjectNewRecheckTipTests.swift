import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The re-check's attacks on the fix round's new code (59543453 only: `ProjectMaker.stillMade`, the start's pin,
/// `projectNewPhrase`). `LeadEngine.startLead` is Linux-only in this repository's tests (LeadStartTests), so the start is
/// driven here in its own order (LeadStart.swift:70-82: the pin with no root, `GitGuard.accept(root: folder, only: [],
/// baseline: true)`, the repository found, the pin with its top) with the real functions; the swap is timed by the FIFO
/// include of `ProjectNewRecheckTests` during the pin's own git.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ProjectNewRecheckTipTests {
    private let base = ProjectNewRecheckTests()

    /// The swap made before the start (the folder moved and a link to another repository left by its name): the first
    /// pin refuses, before the baseline. Green: the case the pin closes.
    @Test func startPin_aSwapBeforeTheStartRefusesBeforeTheBaseline() throws {
        let world = try base.world()
        let server = ProjectNewRecheckTests.FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        let other = try ProjectMaker.make(name: "other", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        let made = try ProjectMaker.make(name: "shop", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        // The parent moved out and linked back (the same inode by its path through the link): the first pin passes its
        // lstat, but the top found isn't the folder made.
        let parentMoved = world.base + "/projects-moved"
        #expect(rename(world.projects, parentMoved) == 0 && symlink(parentMoved, world.projects) == 0)
        let firstParent = ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch)
        let top = Git.run(["rev-parse", "--show-toplevel"], in: made.folder)
        let secondParent = ProjectMaker.stillMade(made, root: (top.output as NSString).standardizingPath, home: world.home, scratch: world.nodeScratch)
        #expect(firstParent != nil || secondParent != nil, "a start through the moved parent: \(top.output)")
        #expect(unlink(world.projects) == 0 && rename(parentMoved, world.projects) == 0)
        // A same-named real repository in its place (the folder renamed away, another renamed in).
        #expect(rename(made.folder, world.base + "/away") == 0 && rename(other.folder, made.folder) == 0)
        #expect(ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch) != nil)
    }
}

/// The fix round's new code: what still gets through on 59543453 (red by design: each failure is a finding's evidence).
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ProjectNewRecheckOpenTipTests {
    private let base = ProjectNewRecheckTests()

    /// The folder made is swapped for a link to another repository (one with a hook) while the first pin's own git runs
    /// (`rev-parse HEAD`, after its lstat passed): the first pin passes, so the hooks baseline the start records next is
    /// the other repository's (its store, its hooks folder); the second pin then refuses the lead. Red where the window is:
    /// the baseline reaches another repository.
    @Test func startPin_aSwapDuringThePinsOwnGitReachesTheBaseline() throws {
        let world = try base.world()
        let armed = Locked(false)
        let swapped = Locked<String?>(nil)
        let madeBox = Locked<ProjectMaker.Made?>(nil)
        let otherBox = Locked<String?>(nil)
        let server = ProjectNewRecheckTests.FifoServer(world.fifo) { _ in
            guard armed.value, swapped.value == nil, let made = madeBox.value, let other = otherBox.value else { return }
            let moved = rename(made.folder, world.base + "/away") == 0
            let linked = symlink(other, made.folder) == 0
            swapped.value = "moved \(moved), linked \(linked)"
        }
        defer { server.stop() }
        let other = try ProjectMaker.make(name: "other", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        let hook = other.folder + "/.git/hooks/post-checkout"
        try FileManager.default.createDirectory(atPath: other.folder + "/.git/hooks", withIntermediateDirectories: true)
        try writeClosedOnExec("#!/bin/sh\nexit 0\n", to: URL(fileURLWithPath: hook))
        let made = try ProjectMaker.make(name: "shop", location: nil, projectsFolder: world.projects, home: world.home, scratch: world.nodeScratch).get()
        madeBox.value = made
        otherBox.value = other.folder
        armed.value = true

        // LeadStart.swift:71: the pin, with no root.
        let first = ProjectMaker.stillMade(made, root: nil, home: world.home, scratch: world.nodeScratch)
        #expect(swapped.value == "moved true, linked true", "\(swapped.value ?? "no swap")")
        #expect(first == nil, "the first pin saw the swap: \(first ?? "")")
        // LeadStart.swift:76: the baseline, by the folder's path (a store of the test's; the real one is keyed by the
        // common git folder found here).
        let dirs = GitGuard.gitDirs(of: made.folder)
        let store = URL(fileURLWithPath: world.base).appendingPathComponent("guard/git-hooks/test", isDirectory: true)
        _ = try GitGuard.accept(root: made.folder, only: [], baseline: true, store: store, step: nil)
        let record = GitGuard.accepted(in: store)
        // LeadStart.swift:81-82: the repository found, and the pin with its top: the lead refused.
        let top = Git.run(["rev-parse", "--show-toplevel"], in: made.folder)
        let second = ProjectMaker.stillMade(made, root: (top.output as NSString).standardizingPath, home: world.home, scratch: world.nodeScratch)
        #expect(second != nil, "the lead would start in \(top.output)")
        withKnownIssue("N-a: the baseline by path between the first pin and the second; fixed with P1 at the device-keys cut-over") {
            #expect(dirs?.common == made.folder + "/.git", "the baseline is keyed by another repository's git folder: \(dirs?.common ?? "none")")
            #expect(record?.folder.hasPrefix(made.folder + "/") == true && record?.files.isEmpty == true,
                    "the baseline recorded another repository's hooks as seen, none to run: \(record.map { "\($0.folder): \($0.files.map(\.name)) run \($0.run)" } ?? "none")")
        }
    }

    /// What the dialog names and where the make goes, when the projects folder changes after the card is built
    /// (`approvalJudgment` builds the card, waits on Touch ID, then the request runs and `newProject` reads
    /// `NodeSettings.projectsFolder` again: ApprovalRequests.swift:70-88, ProjectNewRequest.swift:345). A page that acts
    /// may `set projects_folder` (NodeSettings.swift:120, page: .sets) while the dialog is up. Red: the dialog named
    /// another folder than the one made.
    @Test func dialog_namesTheFolderTheMakeUses_whenTheProjectsFolderChangesWhileItWaits() throws {
        let world = try base.world()
        let server = ProjectNewRecheckTests.FifoServer(world.fifo) { _ in }
        defer { server.stop() }
        let elsewhere = world.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let phrase = Requests.projectNewPhrase(name: "Shop", location: nil, goal: nil, projectsFolder: world.projects, home: world.home)
        let made = try ProjectMaker.make(name: "Shop", location: nil, projectsFolder: elsewhere, home: world.home, scratch: world.nodeScratch).get()
        withKnownIssue("N-b: the dialog names the projects folder read when it was built; carried with the approval at the device-keys cut-over") {
            #expect(phrase.contains(made.folder), "the dialog said “\(phrase)”; the project was made in \(made.folder)")
        }
    }
}
