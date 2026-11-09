import Foundation
import Testing
@testable import VibeCore

/// Whichever route a change takes onto main, the commit about to become main is checked first (`Worktrees.landingRefusal`):
/// every line of main's lead records is still there, and any remote commit it's meant to carry is its ancestor. The
/// fixture is the shape of 2026-11-07 with made-up content: the other Mac pushed code and lead records, this Mac wrote its
/// own records meanwhile, and a worker merged the fetched tip in. In `LeadRemoteTests` for its scratch origin and other Mac.
extension LeadRemoteTests {
    /// Every route that moves main through `Worktrees.fastForward`.
    enum Route: String, CaseIterable, CustomTestStringConvertible {
        case merge, batchCarrierFirst, batchCarrierLast, mergeRemote, revert
        var testDescription: String { rawValue }
        var name: String {
            switch self {
            case .merge: return "merge(carrier)"
            case .batchCarrierFirst, .batchCarrierLast: return "batch ("
            case .mergeRemote: return "merge_remote"
            case .revert: return "revert(undone)"
            }
        }
        var carries: Bool { self != .revert }
    }

    /// The fixture, with `route` ready to land: what `land` does next is the move of main under test.
    struct Landing {
        let scene: Scene
        let lead: LeadToolset
        let runtime: FakeRuntime
        /// The remote's tip fetch_remote fetched.
        let tip: String
        /// main with `route` ready to land.
        let before: String
    }

    /// `extra`, when given, is more of the carrier worker's work, after it merged the remote in and before it reports done.
    func prepare(_ route: Route, carrierExtra extra: ((String) throws -> Void)? = nil) throws -> Landing {
        let scene = try makeScene()
        _ = try pushed(scene, "b.txt", "bee\n", message: "Remote b")
        _ = try pushed(scene, "docs/lead/decisions.md", "## the other Mac's decision\n", append: true, message: LeadRecords.subject)
        let tip = try pushed(scene, "docs/lead/progress.md", "- the other Mac's progress\n", append: true, message: LeadRecords.subject)
        try commit("docs/lead/progress.md", "- local progress\n", in: scene.root, append: true, message: LeadRecords.subject)
        try commit("docs/lead/decisions.md", "## this Mac's decision\n", in: scene.root, append: true, message: LeadRecords.subject)
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 12) }
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(!lead.call("fetch_remote", [:]).isError)
        lead.records.flush(base: "main")
        let done = { (slug: String, work: (String) throws -> Void) throws in
            let added = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]])
            #expect(!added.isError, "\(added.text)")
            #expect(!lead.call("start_worker", ["task": slug]).isError)
            try work(Worktrees.path(root: scene.root, slug: slug))
            #expect(!(try self.seat("worker-\(slug)", runtime)).call("report", doneReport("done")).isError)
        }
        let carrier = { (worktree: String) throws in
            _ = Git.run(["merge", "-q", "--no-edit", "origin/main"], in: worktree)
            if !Git.run(["diff", "--name-only", "--diff-filter=U"], in: worktree).output.isEmpty {
                try "# Progress\n\n- first\n- local progress\n- the other Mac's progress\n".write(toFile: worktree + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
                try "# Decisions\n\n## first\n## this Mac's decision\n## the other Mac's decision\n".write(toFile: worktree + "/docs/lead/decisions.md", atomically: true, encoding: .utf8)
                Git.run(["add", "docs/lead"], in: worktree)
                #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
            }
            #expect(self.isAncestor(tip, of: "HEAD", in: worktree))
            try extra?(worktree)
        }
        let plain = { (name: String) in { (worktree: String) throws in try self.commit(name, "\(name)\n", in: worktree, message: name) } }
        switch route {
        case .merge: try done("carrier", carrier)
        case .batchCarrierFirst, .batchCarrierLast:
            #expect(!lead.call("configure", ["merge_batching": "always"]).isError)
            try done("carrier", carrier)
            try done("other", plain("o.txt"))
        case .mergeRemote: break
        case .revert:
            try done("undone", plain("r.txt"))
            let merged = lead.call("merge", ["task": "undone"])
            #expect(!merged.isError, "\(merged.text)")
            lead.records.flush(base: "main")
        }
        return Landing(scene: scene, lead: lead, runtime: runtime, tip: tip, before: head(scene.root))
    }

    func land(_ route: Route, _ fixture: Landing) -> MCPToolResult {
        switch route {
        case .merge: return fixture.lead.call("merge", ["task": "carrier"])
        case .batchCarrierFirst: return fixture.lead.call("merge", ["tasks": ["carrier", "other"]])
        case .batchCarrierLast: return fixture.lead.call("merge", ["tasks": ["other", "carrier"]])
        case .mergeRemote: return fixture.lead.call("merge_remote", [:])
        case .revert: return fixture.lead.call("revert", ["task": "undone", "reason": "it broke"])
        }
    }

    static let guardedRecords = ["docs/lead/decisions.md", "docs/lead/incidents.md", "docs/lead/progress.md"]

    func recordLines(_ root: String, at commit: String) -> [String: [String]] {
        Self.guardedRecords.reduce(into: [:]) { found, file in
            found[file] = Git.run(["show", "\(commit):\(file)"], in: root).output.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    }

    /// A made-up commit on main as it is now, of `tree`, with the extra `parents` after main.
    func tampered(_ root: String, tree: String, parents: [String] = []) -> String {
        git(["commit-tree", tree, "-m", "Made up", "-p", head(root)] + parents.flatMap { ["-p", $0] }, in: root).output
    }

    func tree(_ commit: String, _ root: String) -> String { Git.run(["rev-parse", "\(commit)^{tree}"], in: root).output }

    /// `commit`'s tree with `line` taken out of `file`.
    func tree(of commit: String, dropping line: String, from file: String, _ root: String) throws -> String {
        let text = Git.run(["show", "\(commit):\(file)"], in: root).output.components(separatedBy: "\n").filter { $0 != line }.joined(separator: "\n") + "\n"
        let scratch = temp.url("edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("copy").path
        try text.write(toFile: copy, atomically: true, encoding: .utf8)
        let blob = git(["hash-object", "-w", copy], in: root).output
        let index = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]
        #expect(Git.run(["read-tree", commit], in: root, env: index).ok)
        #expect(Git.run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(file)"], in: root, env: index).ok)
        return Git.run(["write-tree"], in: root, env: index).output
    }

    // MARK: Every route, checked on what it made

    /// The check runs on the commit the route made, with main still where it was, and what lands holds main's lines
    /// and, with a remote carried, the fetched tip.
    @Test(arguments: Route.allCases)
    func everyRouteLandsTheCommitItChecked(route: Route) throws {
        let fixture = try prepare(route)
        let root = fixture.scene.root
        let lines = recordLines(root, at: fixture.before)
        var seen: [(candidate: String, main: String)] = []
        fixture.lead.records.landingProbe = Worktrees.LandingProbe(candidate: { candidate in
            seen.append((candidate, self.head(root)))
            return candidate
        })
        let result = land(route, fixture)
        #expect(!result.isError, "\(result.text)")
        fixture.lead.records.landingProbe = nil

        let board = BoardStore(root: root).load()
        let produced: String
        switch route {
        case .merge: produced = try #require(board.task("carrier")?.merged?.commit)
        case .batchCarrierFirst: produced = try #require(board.task("other")?.merged?.commit)
        case .batchCarrierLast: produced = try #require(board.task("carrier")?.merged?.commit)
        case .mergeRemote: produced = Git.run(["rev-list", "--merges", "--max-count=1", "main"], in: root).output
        case .revert: produced = try #require(BoardStore(root: root).loadAll().task("undone")?.merged?.revertedBy)
        }
        #expect(seen.count == 1, "\(seen)")
        #expect(seen.first?.candidate == produced, "checked \(seen.first?.candidate ?? ""), landed \(produced)")
        #expect(seen.first?.main == fixture.before)
        if route == .merge {
            #expect(produced != Git.run(["rev-parse", Worktrees.branch("carrier")], in: root).output)
        }
        for (file, kept) in lines {
            let after = Set(recordLines(root, at: produced)[file] ?? [])
            for line in kept { #expect(after.contains(line), "\(route): \(line) gone from \(file)") }
        }
        if route.carries {
            #expect(isAncestor(fixture.tip, of: produced, in: root), "\(route) flattened the remote")
            // The remote's lines are in the commit itself: nothing after the move has to add them.
            #expect(Git.run(["show", "\(produced):docs/lead/progress.md"], in: root).output.contains("- the other Mac's progress"))
            #expect(Git.run(["show", "\(produced):docs/lead/decisions.md"], in: root).output.contains("## the other Mac's decision"))
        }
    }

    enum Fault: String, CaseIterable, CustomTestStringConvertible {
        case lineDropped, ancestorMissing, checkFails, checkTimesOut
        var testDescription: String { rawValue }
    }

    static var routesAndFaults: [(Route, Fault)] {
        Route.allCases.flatMap { route in Fault.allCases.filter { $0 != .ancestorMissing || route.carries }.map { (route, $0) } }
    }

    /// Each way the check can fail leaves main where it was, and the refusal names the route, the file and what's
    /// missing. A batch is asked about every task in it: in carrier-first order its top holds a task that carries nothing.
    @Test(arguments: routesAndFaults)
    func aFailedCheckLeavesMainUnmovedAndSaysWhy(route: Route, fault: Fault) throws {
        let fixture = try prepare(route)
        let root = fixture.scene.root
        var made: String?
        switch fault {
        case .lineDropped:
            fixture.lead.records.landingProbe = Worktrees.LandingProbe(candidate: { candidate in
                let bad = self.tampered(root, tree: (try? self.tree(of: candidate, dropping: "- first", from: "docs/lead/progress.md", root)) ?? "",
                                        parents: route.carries ? [fixture.tip] : [])
                made = bad
                return bad
            })
        case .ancestorMissing:
            fixture.lead.records.landingProbe = Worktrees.LandingProbe(candidate: { candidate in
                let flat = self.tampered(root, tree: self.tree(candidate, root))
                made = flat
                return flat
            })
        case .checkFails:
            fixture.lead.records.landingProbe = Worktrees.LandingProbe(git: { args in
                args.first == "ls-tree" ? Git.Result(status: 128, output: "", error: "fatal: bad object") : nil
            })
        case .checkTimesOut:
            fixture.lead.records.landingProbe = Worktrees.LandingProbe(git: { args in
                args.first == "ls-tree" ? Git.Result(status: 15, output: "", error: "git was stopped: it ran past 30 s.", timedOut: true) : nil
            })
        }
        let result = land(route, fixture)
        fixture.lead.records.landingProbe = nil
        #expect(result.isError, "\(route) landed through \(fault): \(result.text)")
        // A batch's tool call flushes the records after it, nothing merged or not: that's the records commit's own landing.
        #expect(Git.run(["log", "--format=%s", "\(fixture.before)..main"], in: root).output.split(whereSeparator: \.isNewline).allSatisfy { $0 == LeadRecords.subject },
                "\(route) moved main through \(fault): \(result.text)")
        if let made { #expect(!isAncestor(made, of: "main", in: root)) }
        #expect(result.text.contains(route.name), "\(result.text)")
        switch fault {
        case .lineDropped:
            #expect(result.text.contains("docs/lead/progress.md") && result.text.contains("- first"), "\(result.text)")
        case .ancestorMissing:
            #expect(result.text.contains(fixture.tip.prefix(8)) && result.text.contains("ancestor"), "\(result.text)")
        case .checkFails:
            #expect(result.text.contains("docs/lead/") && result.text.contains("bad object"), "\(result.text)")
        case .checkTimesOut:
            #expect(result.text.contains("docs/lead/") && result.text.contains("ran past"), "\(result.text)")
        }
    }

    /// git that can't say what the branch carries isn't "carries nothing": a flattened commit would pass on an empty list.
    @Test func noAnswerAboutWhatABranchCarriesStopsTheMerge() throws {
        let fixture = try prepare(.merge)
        fixture.lead.records.landingProbe = Worktrees.LandingProbe(git: { args in
            args.first == "merge-base" ? Git.Result(status: 15, output: "", error: "git was stopped: it ran past 30 s.", timedOut: true) : nil
        })
        let result = land(.merge, fixture)
        #expect(result.isError && result.text.contains("ran past"), "\(result.text)")
        #expect(head(fixture.scene.root) == fixture.before)
    }

    /// The candidate holds the remote's commits but not the lines they brought: refused, not left for a step after the move.
    @Test func aCandidateWithoutTheRemotesLinesIsRefused() throws {
        let fixture = try prepare(.merge)
        let root = fixture.scene.root
        let tip = fixture.tip
        fixture.lead.records.landingProbe = Worktrees.LandingProbe(candidate: { candidate in
            let tree = (try? self.tree(of: candidate, dropping: "- the other Mac's progress", from: "docs/lead/progress.md", root)) ?? ""
            return self.tampered(root, tree: tree, parents: [tip])
        })
        let result = land(.merge, fixture)
        fixture.lead.records.landingProbe = nil
        #expect(result.isError && head(root) == fixture.before, "\(result.text)")
        #expect(result.text.contains("merge(carrier)") && result.text.contains("- the other Mac's progress") && result.text.contains(tip.prefix(8)), "\(result.text)")
    }

    /// A branch carrying an older tip than the one fetched since merges: what it's meant to carry is what it holds.
    @Test func aBranchCarryingAnOlderFetchedTipStillLands() throws {
        let fixture = try prepare(.merge)
        let root = fixture.scene.root
        let newer = try pushed(fixture.scene, "c.txt", "see\n", message: "Remote c, fetched after the worker merged")
        #expect(!fixture.lead.call("fetch_remote", [:]).isError)
        let result = land(.merge, fixture)
        #expect(!result.isError, "\(result.text)")
        #expect(isAncestor(fixture.tip, of: "main", in: root) && !isAncestor(newer, of: "main", in: root))
    }

    // MARK: How it could pass while still being wrong

    /// The check is on the candidate, not the branch's head: a head missing a line whose candidate has it lands.
    @Test func aBranchHeadMissingARecordLineLandsWhenTheCandidateHasIt() throws {
        var branchHead = ""
        let fixture = try prepare(.merge, carrierExtra: { worktree in
            let record = self.read(worktree + "/docs/lead/progress.md")
            #expect(record.contains("- first"))
            try self.commit("docs/lead/progress.md", record.replacingOccurrences(of: "- first\n", with: ""), in: worktree, message: "A worker's hand edit of the records")
            branchHead = self.git(["rev-parse", "HEAD"], in: worktree).output
        })
        let root = fixture.scene.root
        #expect(!Git.run(["show", "\(branchHead):docs/lead/progress.md"], in: root).output.contains("- first"))
        let result = land(.merge, fixture)
        #expect(!result.isError, "\(result.text)")
        let landed = try #require(BoardStore(root: root).load().task("carrier")?.merged?.commit)
        #expect(Git.run(["show", "\(landed):docs/lead/progress.md"], in: root).output.contains("- first"))
    }

    /// The other way round: a clean branch head, and the commit that would land drops a line.
    @Test func aCleanBranchHeadDoesntVouchForTheCandidate() throws {
        let fixture = try prepare(.merge)
        let root = fixture.scene.root
        #expect(Git.run(["show", "\(Worktrees.branch("carrier")):docs/lead/progress.md"], in: root).output.contains("- first"))
        fixture.lead.records.landingProbe = Worktrees.LandingProbe(candidate: { candidate in
            self.tampered(root, tree: (try? self.tree(of: candidate, dropping: "- first", from: "docs/lead/progress.md", root)) ?? "", parents: [fixture.tip])
        })
        let result = land(.merge, fixture)
        #expect(result.isError && head(root) == fixture.before && result.text.contains("- first"), "\(result.text)")
    }

    /// No route moves a base without the check: the only places that move one take a `Landing` (required), and nothing
    /// else in the sources writes a branch but an agent's own (a recovery) or a remote-tracking one.
    @Test func nothingMovesABaseOutsideTheTwoPlacesThatCheck() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = top.appendingPathComponent("Sources/VibeCore")
        var fastForwards: [String] = [], moves: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let lines = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("///"), !code.hasPrefix("//") else { continue }
                if code.contains("Worktrees.fastForward(") || code.contains(" fastForward(root:") {
                    fastForwards.append(name)
                    #expect(code.contains("landing:") || lines[index + 1].contains("landing:"), "\(name):\(index + 1): \(code)")
                }
                if code.contains("\"--ff-only\"") { moves.append("\(name): ff-only") }
                if code.contains("\"update-ref\""), code.contains("refs/heads/") { moves.append("\(name): \(code.contains("stuck.branch") ? "recovery" : code.contains("\\(main)") ? "fastForward" : "commitFiles")") }
                if code.contains("\"refs/heads/\\(branch)\", commit, head") { moves.append("\(name): commitFiles") }
            }
        }
        #expect(fastForwards.sorted() == ["LeadMergeBatch.swift", "LeadRemote.swift", "LeadToolset.swift", "LeadToolset.swift", "Worktrees.swift", "Worktrees.swift"], "\(fastForwards)")
        #expect(Set(moves) == ["Worktrees.swift: ff-only", "Worktrees.swift: fastForward", "Worktrees.swift: recovery", "Worktrees.swift: commitFiles"], "\(moves)")
    }

    // MARK: The records flush, the route the contract didn't list

    /// The records' own commit moves main too: a line gone from the working file doesn't reach main, and says why.
    @Test func aRecordsCommitThatLosesALineIsRefused() throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        lead.records.flush(base: "main")
        let before = head(scene.root)
        let path = BoardStore(root: scene.root).recordPath("progress.md")
        try read(path).replacingOccurrences(of: "- first\n", with: "- changed by hand\n").write(toFile: path, atomically: true, encoding: .utf8)
        guard case .failed(let why) = lead.records.flush(base: "main") else { Issue.record("the flush landed"); return }
        #expect(why.contains("records commit") && why.contains("docs/lead/progress.md") && why.contains("- first"), "\(why)")
        #expect(head(scene.root) == before)
        #expect(lead.records.statusLine?.contains("- first") == true)
        #expect(read(path).contains("- changed by hand"))
    }

    @Test(arguments: [(Git.Result(status: 128, output: "", error: "fatal: bad object"), "bad object"),
                      (Git.Result(status: 15, output: "", error: "git was stopped: it ran past 30 s.", timedOut: true), "ran past")])
    func aRecordsCommitWhoseCheckCantRunIsRefused(answer: Git.Result, said: String) throws {
        let scene = try makeScene()
        let lead = try lead(scene.root, FakeRuntime())
        let before = head(scene.root)
        try (read(scene.root + "/docs/lead/progress.md") + "- new line\n").write(toFile: scene.root + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        lead.records.landingProbe = Worktrees.LandingProbe(git: { $0.first == "ls-tree" ? answer : nil })
        guard case .failed(let why) = lead.records.flush(base: "main") else { Issue.record("the flush landed"); return }
        #expect(why.contains("records commit") && why.contains(said), "\(why)")
        #expect(head(scene.root) == before)
    }

    /// `Worktrees.merge` (no route of the app's uses it, its tests do) goes through the same check.
    @Test func thePlainMergeDropsNoRecordLineEither() throws {
        let scene = try makeScene()
        git(["branch", "agent/w"], in: scene.root)
        let base = temp.url("remote").resolvingSymlinksInPath().appendingPathComponent("w").path
        git(["worktree", "add", "-q", base, "agent/w"], in: scene.root)
        try commit("docs/lead/progress.md", "# Progress\n", in: base, message: "Drop a line")
        let before = head(scene.root)
        guard case .refused(let why) = try Worktrees.merge(root: scene.root, slug: "w") else { Issue.record("merged"); return }
        #expect(why.contains("merge of agent/w") && why.contains("docs/lead/progress.md") && why.contains("- first"), "\(why)")
        #expect(head(scene.root) == before)
    }

    // MARK: Records that rewrite themselves, legitimately

    /// `archive_decisions` moves whole entries to the archive, and its pointer line changes each time: none of it is a loss.
    @Test func archivingDecisionsLandsThroughTheCheck() throws {
        let scene = try makeScene()
        try commit("docs/lead/decisions.md", "# Decisions\n\n## first\n\n## 2026-11-01 10:00 Old way\n\nWhy: the old reason\n\n## 2026-11-02 10:00 Older way\n\nWhy: another\n\n## 2026-11-03 10:00 Current way\n\nWhy: now\n",
                   in: scene.root, message: LeadRecords.subject)
        let lead = try lead(scene.root, FakeRuntime())
        for name in ["2026-11-01 10:00 Old way", "2026-11-02 10:00 Older way"] {
            _ = try LeadRecords.archive([name], reason: "superseded", in: lead.store)
            guard case .committed = lead.records.flush(base: "main") else { Issue.record("the archive didn't land: \(lead.records.statusLine ?? "")"); return }
        }
        #expect(!Git.run(["show", "main:docs/lead/decisions.md"], in: scene.root).output.contains("Old way"))
        #expect(Git.run(["show", "main:docs/lead/decisions-archive.md"], in: scene.root).output.contains("Old way"))
    }

    /// The month's roll moves earlier months of progress.md to its archive.
    @Test func theProgressRollLandsThroughTheCheck() throws {
        let scene = try makeScene()
        let month = String(LeadDecision.stamp(Date()).prefix(7))
        try commit("docs/lead/progress.md", "# Progress\n\n- first\n- 2026-09-01 10:00 An earlier month's line\n- \(month)-01 10:00 This month's line\n",
                   in: scene.root, message: LeadRecords.subject)
        let lead = try lead(scene.root, FakeRuntime())
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("the roll didn't land: \(lead.records.statusLine ?? "")"); return }
        #expect(!Git.run(["show", "main:docs/lead/progress.md"], in: scene.root).output.contains("An earlier month's line"))
        #expect(Git.run(["show", "main:docs/lead/progress-archive.md"], in: scene.root).output.contains("An earlier month's line"))
    }

    /// The other Mac archived a decision: merge_remote's clean merge removes it from decisions.md and adds it to the archive.
    @Test func aRemoteThatArchivedADecisionMergesThroughTheCheck() throws {
        let scene = try makeScene()
        let tip = try archivedOnTheOtherMac(scene)
        try commit("local.txt", "ours\n", in: scene.root, message: "Local")
        let lead = try lead(scene.root, FakeRuntime())
        #expect(!lead.call("fetch_remote", [:]).isError)
        let merged = lead.call("merge_remote", [:])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(tip, of: "main", in: scene.root))
        #expect(!Git.run(["show", "main:docs/lead/decisions.md"], in: scene.root).output.contains("## first"))
        #expect(Git.run(["show", "main:docs/lead/decisions-archive.md"], in: scene.root).output.contains("## first"))
    }

    /// The same through a task that merged that remote in.
    @Test func aTaskCarryingARemoteThatArchivedLandsThroughTheCheck() throws {
        let scene = try makeScene()
        let tip = try archivedOnTheOtherMac(scene)
        try commit("local.txt", "ours\n", in: scene.root, message: "Local")
        let runtime = FakeRuntime()
        let lead = try lead(scene.root, runtime)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        #expect(!lead.call("fetch_remote", [:]).isError)
        lead.records.flush(base: "main")
        #expect(!lead.call("add_task", ["title": "carrier", "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": "carrier"]).isError)
        let worktree = Worktrees.path(root: scene.root, slug: "carrier")
        #expect(Git.run(["merge", "-q", "--no-edit", "origin/main"], in: worktree).ok)
        #expect(!(try seat("worker-carrier", runtime)).call("report", doneReport("done")).isError)
        let merged = lead.call("merge", ["task": "carrier"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(isAncestor(tip, of: "main", in: scene.root))
        #expect(Git.run(["show", "main:docs/lead/decisions-archive.md"], in: scene.root).output.contains("## first"))
    }

    /// The other Mac moves "## first" from decisions.md to the archive, as archive_decisions does.
    func archivedOnTheOtherMac(_ scene: Scene) throws -> String {
        _ = try pushed(scene, "docs/lead/decisions-archive.md", "# Archived decisions\n\n## first\n", message: "Remote archive")
        return try pushed(scene, "docs/lead/decisions.md", "# Decisions\n\n", message: "Remote archive: decisions")
    }

    // MARK: Uncommitted lines

    /// The lead's lines not committed yet, in a record the candidate changes: they stay, the candidate's lines join them
    /// and main moves. If git then doesn't move it, the file and the index are put back.
    @Test func uncommittedRecordLinesSurviveTheFastForward() throws {
        let scene = try makeScene()
        let root = scene.root
        let before = head(root)
        git(["checkout", "-q", "-b", "candidate"], in: root)
        try commit("docs/lead/progress.md", "- the candidate's line\n", in: root, append: true, message: "c")
        let candidate = head("candidate", root)
        git(["checkout", "-q", "main"], in: root)
        try (read(root + "/docs/lead/progress.md") + "- not committed yet\n").write(toFile: root + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        let index = Git.run(["ls-files", "-s", "--", "docs/lead/progress.md"], in: root).output

        // Git refusing the move at the last step puts everything back.
        let kept = Worktrees.landKeepingRecords(files: ["docs/lead/progress.md"], root: root, expected: before, commit: candidate, move: { .refused("no") })
        #expect(kept == .refused("no") && head(root) == before)
        #expect(read(root + "/docs/lead/progress.md") == "# Progress\n\n- first\n- not committed yet\n")
        #expect(Git.run(["ls-files", "-s", "--", "docs/lead/progress.md"], in: root).output == index)

        let landing = Worktrees.Landing(route: "test", records: "docs/lead", lockRecords: { try $0() })
        #expect(Worktrees.fastForward(root: root, base: "main", to: candidate, from: before, landing: landing) == .merged)
        #expect(head(root) == candidate)
        let text = read(root + "/docs/lead/progress.md")
        for line in ["- first", "- the candidate's line", "- not committed yet"] { #expect(text.contains(line), "\(text)") }
        // Without the lock, or over anything else, it's the usual refusal.
        #expect(Git.run(["show", "main:docs/lead/progress.md"], in: root).output.contains("- the candidate's line"))
        #expect(!Git.run(["show", "main:docs/lead/progress.md"], in: root).output.contains("- not committed yet"))
    }

    @Test func uncommittedRecordsStopAFastForwardThatCantKeepThem() throws {
        let scene = try makeScene()
        let root = scene.root
        let before = head(root)
        git(["checkout", "-q", "-b", "candidate"], in: root)
        try commit("docs/lead/progress.md", "- the candidate's line\n", in: root, append: true, message: "c")
        let candidate = head("candidate", root)
        git(["checkout", "-q", "main"], in: root)
        try (read(root + "/docs/lead/progress.md") + "- not committed yet\n").write(toFile: root + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        guard case .refused(let why) = Worktrees.fastForward(root: root, base: "main", to: candidate, from: before, landing: .unchecked("test")) else {
            Issue.record("moved over uncommitted lines"); return
        }
        #expect(why.contains("uncommitted changes") && head(root) == before, "\(why)")
    }

    func head(_ branch: String, _ root: String) -> String { Git.run(["rev-parse", branch], in: root).output }
}
