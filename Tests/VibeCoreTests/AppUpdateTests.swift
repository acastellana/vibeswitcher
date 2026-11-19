import Foundation
import Testing
@testable import VibeCore

/// The app's update check, against a scratch bare repository standing in for GitHub (never a real remote, never the
/// network): this Mac's checkout, built at a made-up installed commit, and another clone that pushes to it.
struct AppUpdateTests {
    let temp = Scratch()

    @discardableResult
    func git(_ args: [String], in dir: String) -> Git.Result {
        let result = Shell.run(executable: "/usr/bin/git", args: args, in: dir, env: Git.environment, timeout: 60, grace: 1)
        #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.error)")
        return result
    }

    struct Scene {
        let root: String
        let origin: String
        let other: String
        /// The installed build's commit: the checkout's first.
        let installed: String
        var build: ServerBuild { ServerBuild(commit: installed, builtAt: nil) }
    }

    func makeScene() throws -> Scene {
        let base = temp.url("update").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let (root, origin, other) = (base.appendingPathComponent("vibeswitcher").path, base.appendingPathComponent("origin.git").path,
                                     base.appendingPathComponent("other").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        git(["init", "-q", "--bare", "-b", "main", origin], in: base.path)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { git(args, in: root) }
        try commit("Sources/App/main.swift", "print(1)\n", in: root, message: "first")
        try commit("docs/lead/progress.md", "- first\n", in: root, message: "Lead: progress")
        git(["remote", "add", "origin", origin], in: root)
        git(["push", "-q", "origin", "main"], in: root)
        git(["clone", "-q", origin, other], in: base.path)
        for args in [["config", "user.email", "o@o"], ["config", "user.name", "Other"]] { git(args, in: other) }
        return Scene(root: root, origin: origin, other: other, installed: git(["rev-parse", "HEAD"], in: root).output)
    }

    func commit(_ file: String, _ text: String, in dir: String, message: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let before = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try (before + text).write(toFile: path, atomically: true, encoding: .utf8)
        git(["add", file], in: dir)
        git(["commit", "-q", "-m", message], in: dir)
    }

    /// The other clone commits and pushes; returns the commit.
    func pushed(_ scene: Scene, _ file: String, _ text: String, message: String) throws -> String {
        try commit(file, text, in: scene.other, message: message)
        git(["push", "-q", "origin", "main"], in: scene.other)
        return git(["rev-parse", "HEAD"], in: scene.other).output
    }

    func fetched(_ scene: Scene) -> String? {
        let scratch = temp.url("update-git")
        return try? LeadRemote.fetch(root: scene.root, remote: "origin", url: scene.origin, branch: "main", scratch: scratch).get()
    }

    @Test func aCommitToTheBuildOnGitHubIsAnUpdate() throws {
        let scene = try makeScene()
        let pushed = try pushed(scene, "Sources/App/main.swift", "print(2)\n", message: "Chat: replies stream faster")
        #expect(fetched(scene) == pushed)
        let offer = try #require(try AppUpdate.find(root: scene.root, remote: "origin", base: "main", installed: scene.build).get())
        #expect(offer.changes.map(\.id) == [pushed])
        #expect(offer.changes.first?.subject == "Chat: replies stream faster")
        // Only GitHub has it: the lead merges it first.
        #expect(offer.waiting == 1 && !offer.ready && offer.newest == pushed && offer.tip == pushed)
    }

    func find(_ scene: Scene, installed: ServerBuild? = nil) -> AppUpdate.Offer? {
        try? AppUpdate.find(root: scene.root, remote: "origin", base: "main", installed: installed ?? scene.build).get()
    }

    @Test func eachPathTheBuildReadsMakesAnUpdateAndDocsAlone() throws {
        let scene = try makeScene()
        // The lead's records, and other docs: nothing new to install.
        _ = try pushed(scene, "docs/lead/decisions.md", "## a decision\n", message: "Lead: decisions and progress")
        _ = try pushed(scene, "docs/guide.md", "words\n", message: "Docs: a guide")
        #expect(fetched(scene) != nil)
        #expect(find(scene) == nil)
        var ids: [String] = []
        for path in ["Sources/VibeCore/x.swift", "Package.swift", "Package.resolved", "scripts/build-app.sh", "scripts/lib/swift-jobs.sh",
                     "Resources/Info.plist", "Web/app.js"] {
            ids.insert(try pushed(scene, path, "x\n", message: "Touch \(path)"), at: 0)
        }
        // Not what the build reads: tests and other scripts.
        _ = try pushed(scene, "Tests/a.swift", "x\n", message: "Tests only")
        _ = try pushed(scene, "scripts/test.sh", "x\n", message: "Test script only")
        #expect(fetched(scene) != nil)
        #expect(find(scene)?.changes.map(\.id) == ids)
    }

    @Test func thisMacsMainCountsWithoutGitHub() throws {
        let scene = try makeScene()
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Lead: a merged task")
        let local = git(["rev-parse", "HEAD"], in: scene.root).output
        let offer = try #require(find(scene))
        #expect(offer.changes.map(\.id) == [local] && offer.ready && offer.waiting == 0)
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer) == nil)
        // The installed build is the newest: nothing.
        #expect(find(scene, installed: ServerBuild(commit: local, builtAt: nil)) == nil)
    }

    @Test func divergedMainsWaitForTheLead() throws {
        let scene = try makeScene()
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Local: one")
        let local = git(["rev-parse", "HEAD"], in: scene.root).output
        let remote = try pushed(scene, "Sources/App/other.swift", "x\n", message: "Remote: two")
        #expect(fetched(scene) == remote)
        let offer = try #require(find(scene))
        #expect(Set(offer.changes.map(\.id)) == [local, remote] && offer.waiting == 1 && !offer.ready)
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer)?.contains("lead merges them first") == true)
    }

    @Test func aBuildThatCantBeComparedFindsNothing() throws {
        let scene = try makeScene()
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.find(root: scene.root, remote: "origin", base: "main", installed: nil).get() }
        #expect(throws: AppUpdate.Failure.self) {
            try AppUpdate.find(root: scene.root, remote: "origin", base: "main", installed: ServerBuild(commit: String(repeating: "a", count: 40), builtAt: nil)).get()
        }
        // A task branch's commit, on neither main nor origin/main.
        git(["checkout", "-q", "-b", "agent/x"], in: scene.root)
        try commit("Sources/App/task.swift", "x\n", in: scene.root, message: "Task")
        let task = git(["rev-parse", "HEAD"], in: scene.root).output
        git(["checkout", "-q", "main"], in: scene.root)
        #expect(throws: AppUpdate.Failure.self) {
            try AppUpdate.find(root: scene.root, remote: "origin", base: "main", installed: ServerBuild(commit: task, builtAt: nil)).get()
        }
    }

    // MARK: The changelog

    @Test func theChangelogIsTheBuildsCommitsGroupedWithASummaryOrTheSubjectsAlone() throws {
        let scene = try makeScene()
        try commit("Sources/A.swift", "1\n", in: scene.root, message: "Chat: images load faster")
        try commit("docs/lead/progress.md", "x\n", in: scene.root, message: "Lead: decisions and progress")
        try commit("Sources/B.swift", "2\n", in: scene.root, message: "Lead: merges name their build")
        // A merge commit: its subject isn't listed, its sides' are.
        git(["checkout", "-q", "-b", "side"], in: scene.root)
        try commit("Sources/C.swift", "3\n", in: scene.root, message: "Fix the composer losing a draft")
        git(["checkout", "-q", "main"], in: scene.root)
        try commit("Sources/D.swift", "4\n", in: scene.root, message: "Chat: thumbnails decode two at a time")
        git(["merge", "-q", "--no-ff", "-m", "Merge branch 'side'", "side"], in: scene.root)
        let offer = try #require(find(scene))
        let subjects = offer.changes.map(\.subject)
        #expect(Set(subjects) == ["Chat: images load faster", "Lead: merges name their build", "Fix the composer losing a draft",
                                  "Chat: thumbnails decode two at a time"])
        #expect(!subjects.contains { $0.hasPrefix("Merge") || $0.contains("decisions and progress") || $0 == "first" })

        let groups = AppUpdate.groups(offer.changes)
        #expect(groups.last?.area == "Other" && groups.last?.changes.map(\.subject) == ["Fix the composer losing a draft"])
        #expect(groups.first { $0.area == "Chat" }?.changes.count == 2)
        #expect(groups.map(\.area).sorted() == ["Chat", "Lead", "Other"])

        // The model is asked with the subjects; what it says is cleaned up. When it fails or says nothing, no summary:
        // the card shows the subjects alone.
        var asked: String?
        let summary = AppUpdate.summarize(offer.changes) { prompt in asked = prompt; return "  Images load faster.\n\nDrafts stay put.  \n" }
        #expect(summary == "Images load faster. Drafts stay put.")
        #expect(asked?.contains("- Chat: images load faster") == true)
        #expect(AppUpdate.summarize(offer.changes) { _ in nil } == nil)
        #expect(AppUpdate.summarize(offer.changes) { _ in " \n \n" } == nil)
        #expect(AppUpdate.summarize([]) { _ in "anything" } == nil)
    }

    // MARK: Fetch and install

    @Test func theFetchTakesOnlyThePinnedURL() throws {
        let scene = try makeScene()
        let pushed = try pushed(scene, "Sources/App/main.swift", "print(2)\n", message: "Remote")
        let before = git(["rev-parse", "main"], in: scene.root).output
        let scratch = temp.url("update-git")
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.fetch(root: scene.root, remote: "origin", base: "main", pin: nil, scratch: scratch).get() }
        #expect(throws: AppUpdate.Failure.self) {
            try AppUpdate.fetch(root: scene.root, remote: "origin", base: "main", pin: LeadVault.hash("/somewhere/else.git"), scratch: scratch).get()
        }
        #expect(Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"], in: scene.root).output == before)
        let tip = try AppUpdate.fetch(root: scene.root, remote: "origin", base: "main", pin: LeadVault.hash(scene.origin), scratch: scratch).get()
        #expect(tip == pushed)
        // origin/main only: main and the checkout stay where they were.
        #expect(git(["rev-parse", "main"], in: scene.root).output == before)
        #expect(git(["rev-parse", "refs/remotes/origin/main"], in: scene.root).output == pushed)
    }

    @Test func installRunsOnlyOnMainHoldingTheVersion() throws {
        let scene = try makeScene()
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Local")
        let offer = try #require(find(scene))
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer) == nil)
        git(["checkout", "-q", "-b", "elsewhere"], in: scene.root)
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer)?.contains("is on elsewhere, not main") == true)
        git(["checkout", "-q", "--detach", "main"], in: scene.root)
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer)?.contains("detached HEAD") == true)
        git(["checkout", "-q", "main"], in: scene.root)
        git(["reset", "-q", "--hard", scene.installed], in: scene.root)
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer)?.contains("doesn't hold the new version") == true)

        // The keychain is unlocked in the shell (security asks for its password there), then the install.
        let keychain = temp.url("signing dir").appendingPathComponent("vibeswitcher.keychain-db")
        try FileManager.default.createDirectory(at: keychain.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(AppUpdate.installCommand(keychain: keychain.path) == "scripts/build-app.sh --install")
        try Data().write(to: keychain)
        #expect(AppUpdate.installCommand(keychain: keychain.path) == "security unlock-keychain '\(keychain.path)' && scripts/build-app.sh --install")
    }

    // MARK: The schedule and the lead's hand-off

    final class World: @unchecked Sendable {
        var fetches = 0
        var fetchFails = false
        var power: PowerState?
        var logs: [String] = []
        var reports: [(root: String, text: String)] = []
        var summaries = 0
    }

    func watch(_ scene: Scene, _ world: World, launched: Date, file: URL? = nil) -> AppUpdateWatch {
        let file = file ?? temp.url("update-state").appendingPathComponent("update-check.json")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = temp.url("update-git")
        return AppUpdateWatch(launched: launched, file: file, checkout: { .init(root: scene.root) }, installed: { scene.build },
                              fetch: { checkout in
                                  world.fetches += 1
                                  if world.fetchFails { return .failure(AppUpdate.Failure("offline")) }
                                  return AppUpdate.fetch(root: checkout.root, remote: checkout.remote, base: checkout.base,
                                                         pin: LeadVault.hash(scene.origin), scratch: scratch)
                              },
                              power: { world.power }, batteryLimit: { 30 },
                              summarize: { _ in world.summaries += 1; return "What's new." },
                              tellLead: { world.reports.append(($0, $1)) }, log: { world.logs.append($0) })
    }

    @Test func checksTwoMinutesAfterLaunchThenEverySixHoursNotOnLowBattery() throws {
        let scene = try makeScene()
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let watch = watch(scene, world, launched: t0)
        #expect(watch.tick(now: t0.addingTimeInterval(60)) == .notDue)
        #expect(world.fetches == 0)
        #expect(watch.tick(now: t0.addingTimeInterval(120)) == .checked(nil, show: false))
        #expect(world.fetches == 1)
        #expect(watch.tick(now: t0.addingTimeInterval(120 + 5 * 3600)) == .notDue)
        #expect(world.fetches == 1)
        // Due, but on battery under the limit: no check until that ends.
        world.power = PowerState(onBattery: true, percent: 20)
        let due = t0.addingTimeInterval(120 + 6 * 3600)
        #expect(watch.tick(now: due) == .held)
        #expect(watch.tick(now: due.addingTimeInterval(60)) == .held)
        #expect(world.fetches == 1)
        // On battery above it, or on AC power: it checks.
        world.power = PowerState(onBattery: true, percent: 50)
        #expect(watch.tick(now: due.addingTimeInterval(120)) == .checked(nil, show: false))
        #expect(world.fetches == 2)
        #expect(watch.next == due.addingTimeInterval(120 + 6 * 3600))
        // Check for Updates…: at once, and the next scheduled one a full interval after it.
        let asked = due.addingTimeInterval(600)
        #expect(watch.checkNow(now: asked) == .checked(nil, show: false))
        #expect(world.fetches == 3 && watch.next == asked.addingTimeInterval(6 * 3600))
    }

    @Test func aFailedFetchIsLoggedOnceAndThisMacsMainStillCounts() throws {
        let scene = try makeScene()
        let world = World()
        world.fetchFails = true
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let watch = watch(scene, world, launched: t0)
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Local")
        guard case .checked(let offer?, show: true) = watch.tick(now: t0.addingTimeInterval(120)) else {
            Issue.record("no offer from this Mac's main")
            return
        }
        #expect(offer.ready && offer.summary == "What's new.")
        _ = watch.tick(now: t0.addingTimeInterval(120 + 6 * 3600))
        _ = watch.checkNow(now: t0.addingTimeInterval(120 + 7 * 3600))
        #expect(world.fetches == 3)
        #expect(world.logs.filter { $0.contains("failed") }.count == 1, "\(world.logs)")
        // The summary is asked once per version.
        #expect(world.summaries == 1)
        world.fetchFails = false
        _ = watch.checkNow(now: t0.addingTimeInterval(120 + 8 * 3600))
        #expect(world.logs.last?.contains("works again") == true)
        #expect(world.reports.isEmpty)
    }

    @Test func githubsCommitsGoToTheLeadOncePerTipAndTheCardWaitsForItsMerge() throws {
        let scene = try makeScene()
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let watch = watch(scene, world, launched: t0)
        let first = try pushed(scene, "Sources/App/main.swift", "print(2)\n", message: "Chat: faster")
        guard case .checked(let offer?, show: true) = watch.tick(now: t0.addingTimeInterval(120)) else {
            Issue.record("no offer from GitHub's commit")
            return
        }
        // The card shows the changelog, with Install & Restart off until main holds it.
        #expect(!offer.ready && offer.changes.map(\.id) == [first])
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: offer) != nil)
        #expect(world.reports.count == 1)
        #expect(world.reports.first?.root == scene.root)
        #expect(world.reports.first?.text.contains("run fetch_remote, then merge_remote") == true)
        #expect(world.reports.first?.text.contains("(\(first.prefix(8)))") == true)
        // Looked at again while waiting (this Mac's main alone, no fetch) and at the next slot: the same tip isn't
        // reported again.
        _ = watch.tick(now: t0.addingTimeInterval(120 + 60))
        #expect(world.fetches == 1)
        _ = watch.checkNow(now: t0.addingTimeInterval(3600))
        #expect(world.reports.count == 1)
        // Nor after a restart (the state file is kept).
        let file = temp.url("update-state2").appendingPathComponent("update-check.json")
        let again = self.watch(scene, world, launched: t0, file: file)
        _ = again.checkNow(now: t0.addingTimeInterval(3700))
        #expect(world.reports.count == 2, "a new watch with its own file reports once")
        let restarted = self.watch(scene, world, launched: t0, file: file)
        _ = restarted.checkNow(now: t0.addingTimeInterval(3800))
        #expect(world.reports.count == 2)
        // A new tip on GitHub: one more report.
        let second = try pushed(scene, "Sources/App/main.swift", "print(4)\n", message: "Lead: more")
        _ = watch.checkNow(now: t0.addingTimeInterval(4000))
        #expect(world.reports.count == 3)
        #expect(world.reports.last?.text.contains("(\(second.prefix(8)))") == true)

        // The lead merges (main fast-forwards to origin/main): the next look, within a minute, offers the install.
        git(["merge", "-q", "--ff-only", "refs/remotes/origin/main"], in: scene.root)
        guard case .checked(let ready?, show: true) = watch.tick(now: t0.addingTimeInterval(4000 + 60)) else {
            Issue.record("no ready offer after the merge")
            return
        }
        #expect(ready.ready && ready.changes.map(\.id) == [second, first])
        #expect(AppUpdate.installRefusal(root: scene.root, base: "main", offer: ready) == nil)
        #expect(world.fetches == 5, "the three watches' checks and the slot; the look after the merge fetched nothing")
        #expect(world.reports.count == 3)
    }

    @Test func laterSnoozesThisVersionUntilANewerOne() throws {
        let scene = try makeScene()
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let watch = watch(scene, world, launched: t0)
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "One")
        guard case .checked(let offer?, show: true) = watch.tick(now: t0.addingTimeInterval(120)) else {
            Issue.record("no offer")
            return
        }
        watch.snooze(offer)
        // The lead's records move main: still the same version, still snoozed.
        try commit("docs/lead/progress.md", "x\n", in: scene.root, message: "Lead: progress")
        #expect(watch.tick(now: t0.addingTimeInterval(120 + 6 * 3600)) == .checked(offer.with(head: git(["rev-parse", "HEAD"], in: scene.root).output), show: false))
        // Asked for: shown all the same.
        guard case .checked(_, show: true) = watch.checkNow(now: t0.addingTimeInterval(120 + 7 * 3600)) else {
            Issue.record("Check for Updates… didn't show the snoozed version")
            return
        }
        // A newer version: shown again.
        try commit("Sources/App/main.swift", "print(4)\n", in: scene.root, message: "Two")
        guard case .checked(let newer?, show: true) = watch.tick(now: t0.addingTimeInterval(120 + 14 * 3600)) else {
            Issue.record("the newer version wasn't shown")
            return
        }
        #expect(newer.changes.count == 2)
    }

    /// No checkout found at the slot (its lead not started yet): the slot isn't spent, it's tried at each tick; the
    /// checkout once found is remembered for when no lead of it runs.
    @Test func aSlotWithoutTheCheckoutIsTriedAgainAtTheNextTick() throws {
        let scene = try makeScene()
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var found: AppUpdateWatch.Checkout?
        let file = temp.url("update-state").appendingPathComponent("update-check.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func make() -> AppUpdateWatch {
            AppUpdateWatch(launched: t0, file: file, checkout: { found }, installed: { scene.build },
                           fetch: { _ in world.fetches += 1; return .failure(AppUpdate.Failure("offline")) }, log: { world.logs.append($0) })
        }
        let watch = make()
        guard case .unavailable = watch.tick(now: t0.addingTimeInterval(120)) else { Issue.record("checked without a checkout"); return }
        guard case .unavailable = watch.tick(now: t0.addingTimeInterval(180)) else { Issue.record("checked without a checkout"); return }
        #expect(world.logs.count == 1 && world.fetches == 0)
        // VibeSwitcher's lead started: checked at the next tick, not 6 hours on.
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Local")
        found = .init(root: scene.root)
        guard case .checked(_?, show: true) = watch.tick(now: t0.addingTimeInterval(240)) else { Issue.record("not checked once found"); return }
        #expect(world.fetches == 1 && watch.next == t0.addingTimeInterval(240 + 6 * 3600))
        // Next launch, its lead not running: the remembered checkout, while it's still VibeSwitcher's.
        found = nil
        guard case .unavailable = make().tick(now: t0.addingTimeInterval(120)) else { Issue.record("a checkout without the app's files"); return }
        for file in ["scripts/build-app.sh", "Sources/VibeSwitcher/main.swift", "Package.swift"] {
            try FileManager.default.createDirectory(atPath: ((scene.root + "/" + file) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x\n".write(toFile: scene.root + "/" + file, atomically: true, encoding: .utf8)
        }
        let later = make()
        guard case .checked(_?, show: true) = later.tick(now: t0.addingTimeInterval(120)) else { Issue.record("the remembered checkout wasn't used"); return }
        // And it's the one Install & Restart builds in (the app reads `found`, not the leads' projects again).
        #expect(later.found == AppUpdateWatch.Checkout(root: scene.root))
    }

    /// Diverged, with this Mac's commits newer than GitHub's: the report names GitHub's.
    @Test func theReportNamesGitHubsCommitsNotThisMacs() throws {
        let scene = try makeScene()
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try pushed(scene, "Sources/App/other.swift", "x\n", message: "Remote: from the other Mac")
        try commit("Sources/App/main.swift", "print(3)\n", in: scene.root, message: "Local: newer, here")
        try commit("Sources/App/main.swift", "print(4)\n", in: scene.root, message: "Local: newest, here")
        _ = watch(scene, world, launched: t0).tick(now: t0.addingTimeInterval(120))
        let text = try #require(world.reports.first?.text)
        #expect(text.contains("has 1 commit for the app") && text.contains("Remote: from the other Mac"), "\(text)")
        #expect(!text.contains("Local:"), "\(text)")
    }

    @Test func noCheckoutOrNoBuildIsLoggedOnce() throws {
        let world = World()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let file = temp.url("update-state").appendingPathComponent("update-check.json")
        let watch = AppUpdateWatch(launched: t0, file: file, checkout: { nil }, installed: { nil },
                                   fetch: { _ in world.fetches += 1; return .failure(AppUpdate.Failure("no")) },
                                   log: { world.logs.append($0) })
        guard case .unavailable = watch.checkNow(now: t0) else { Issue.record("checked without a checkout"); return }
        guard case .unavailable = watch.checkNow(now: t0.addingTimeInterval(10)) else { Issue.record("checked without a checkout"); return }
        #expect(world.logs.count == 1 && world.fetches == 0)
    }
}

extension AppUpdate.Offer {
    func with(head: String) -> Self {
        var offer = self
        offer.head = head
        return offer
    }
}
