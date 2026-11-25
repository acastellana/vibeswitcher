import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// `vibeswitcher approve` (`ApproveRequest.swift`): one typed code for a batch the user sees whole, of what a plain accept
/// settles, each item recorded in the vault as its own action under the one voiced request; what needs the user's own
/// decision listed only. On a scratch host in the test process (`CardWorld`), its vault sealing at a first look, then a
/// change to the home's Claude settings held.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct ApproveTests {
    private let scratch = Scratch()

    /// A world whose home's settings changed after the first look: held, for the repo's card (a project of the node's:
    /// its lead in the vault's roster) and the home's, both with their guard rails recorded as they are.
    private func world() async throws -> CardWorld {
        let world = try await CardWorld.make(scratch)
        world.queue.sync { world.requests.home = world.host.home.path }
        try await project(world, world.repo)
        try await recordRails(world, world.host.home.path)
        let settings = world.host.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"env":{"A":"1"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        for folder in [world.repo, world.host.home.path] { _ = await world.ask("config.held", ["folder": .string(folder)], action: nil) }
        try #"{"env":{"A":"2"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        return world
    }

    /// `root` a project of the node's: its lead running (a session labelled as a lead's, started there, the vault's grant
    /// bound to it), as the engine lists it, and its rails recorded.
    private func project(_ world: CardWorld, _ root: String, floor: Bool = true) async throws {
        let session = try await world.host.spawn("exec sleep 600", cwd: root, label: "Lead · \((root as NSString).lastPathComponent)")
        let vault = world.host.vault
        try await offPool {
            let grant = try vault.startLead(root: root, branch: "main")
            try vault.bind(grant, root: root, session: session.id.uuidString)
        }
        try await recordRails(world, root, floor: floor)
        let project = NodeIds.project(root: root)
        let listed = await eventually(timeout: 60) {
            world.engine.refresh()
            return world.queue.sync { world.engine.leads.leads[project]?.session == session.id }
        }
        try #require(listed, "the engine never listed \(root)'s lead")
    }

    /// `root`'s guard rails and review floor recorded as its workflow sets them now, exactly as an accept records them
    /// (`ConfigHoldStore.recordedHashes`, `base_branch` among them; the floor it proposes).
    private func recordRails(_ world: CardWorld, _ root: String, floor: Bool = true) async throws {
        let vault = world.host.vault
        let workflow = LeadWorkflow.load(from: ConfigHoldStore.workflowPath(root: root))
        try await offPool {
            try vault.setGuardedSettings(ConfigHoldStore.recordedHashes(workflow), root: root)
            if floor { _ = try vault.setReviewFloor(LeadReviewFloor.starting(from: workflow), root: root) }
        }
    }

    /// `root`'s workflow.md set to `text`.
    private func workflow(_ root: String, _ text: String) throws {
        let url = URL(fileURLWithPath: ConfigHoldStore.workflowPath(root: root))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func list(_ world: CardWorld, only: [String] = ["config"]) async throws -> NodeWire.Value {
        let reply = try #require(await world.ask("approve.list", ["only": .array(only.map(NodeWire.Value.string))], action: nil))
        return try #require(reply.result, "\(reply)")
    }

    private func baseCards(_ world: CardWorld) -> [CardStore.Card] {
        world.queue.sync { world.engine.cards.list(project: NodeIds.project(root: world.repo), all: true).filter { $0.kind == .baseMove } }
    }

    /// A base at the head the vault recorded draws no card, however often `approve` or `base show` asks; a move shown
    /// again is its open card, not another (on 2026-11-23 the real node's every `approve` drew a "from 2ccf4f6d… to
    /// 2ccf4f6d…" card per project, each superseding the last, and left it open).
    @Test func aBaseAtItsRecordedHeadNeverDrawsACardAndAMoveShownAgainIsItsCard() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        world.queue.sync { world.requests.home = world.host.home.path }
        try await project(world, world.repo)
        // The lead's own records commit, the head recorded where it went (as the lead's commits are credited).
        let vault = world.host.vault
        let repo = world.repo
        try "decisions\n".write(toFile: repo + "/decisions.md", atomically: true, encoding: .utf8)
        try await scratchGit(repo, ["add", "decisions.md"])
        try await scratchGit(repo, ["commit", "-q", "-m", "Lead: decisions and progress"])
        let tip = Git.run(["rev-parse", "main"], in: repo).output
        try await offPool { try vault.setHead(tip, root: repo, branch: "main") }

        // An open card from before (an older build's) closes once a show finds the base where it was recorded.
        world.queue.sync {
            var stale = CardStore.Card(root: repo, kind: .baseMove)
            stale.base = BaseMoveStore.Shown(branch: "main", from: tip, fromIs: .recorded, to: tip, commits: [])
            world.engine.cards.put(stale)
        }
        for _ in 0..<3 {
            let listed = try #require(await world.ask("approve.list", ["only": .array([.string("base")])], action: nil))
            #expect(listed.result?["items"]?.array?.isEmpty == true, "\(listed)")
        }
        let shown = try #require(await world.ask("base.show", ["folder": .string(repo)], action: nil))
        #expect(shown.result?["card"] == nil && shown.result?["unmoved"]?.string == tip, "\(shown)")
        // None open, and none drawn by the lists or the show: the one put above, closed (and the look's, if it saw the
        // commit before the head was recorded, closed with it).
        let said = baseCards(world).map { "\($0.closed ?? "open") \($0.base?.from ?? "") \($0.base?.to ?? "")" }
        #expect(baseCards(world).filter(\.isOpen).isEmpty, "\(said)")
        #expect(baseCards(world).allSatisfy { $0.closed == "the base is where the vault recorded it" }, "\(said)")
        #expect(baseCards(world).filter { $0.base?.move == nil }.count == 1, "\(said)")
        let before = Set(baseCards(world).map(\.id))

        // A real move: listed once with its card; listed again, the same card, no other drawn.
        try "more\n".write(toFile: repo + "/more.txt", atomically: true, encoding: .utf8)
        try await scratchGit(repo, ["add", "more.txt"])
        try await scratchGit(repo, ["commit", "-q", "-m", "the user's commit"])
        var ids: [String] = []
        for _ in 0..<3 {
            let listed = try #require(await world.ask("approve.list", ["only": .array([.string("base")])], action: nil))
            let items = listed.result?["items"]?.array ?? []
            #expect(items.count == 1 && items.first?["kind"]?.string == "base.accept", "\(listed)")
            ids += items.compactMap { $0["card"]?["id"]?.string }
        }
        #expect(Set(ids).count == 1, "\(ids)")
        // One card for the move (the look's or the list's), open, whichever drew it.
        let drawn = baseCards(world).filter { !before.contains($0.id) }
        #expect(drawn.count == 1 && drawn.first?.isOpen == true && drawn.first?.id == ids.first, "\(drawn.map { "\($0.id) \($0.closed ?? "open")" }) \(ids)")
    }

    /// A project's card leaves what another root's open card (the home folder's here) lists with the same hashes, of the
    /// home's things, to that card: one line, neither listed nor sealed by the project's (after a restart the user read
    /// four near-identical cards, 85 of each's lines the home's). Accepted first, the project's says the home's still
    /// waits and records no floor; once the home's is accepted, the project's next card ends its first look. A card
    /// drawn alone lists everything.
    @Test func aProjectsCardLeavesWhatTheHomesCardShowsToItInOneLine() async throws {
        let world = try await world()
        defer { world.stop() }
        let home = world.host.home.path
        // The home's card first (as `approve` draws it).
        let homeFirst = try #require(await world.ask("config.held", ["folder": .string(home)], action: nil))
        #expect(homeFirst.result?["card"]?["config"]?["sharedHome"] == .null, "\(homeFirst)")
        let held = try #require(await world.ask("config.held", ["folder": .string(world.repo)], action: nil))
        let card = try #require(held.result?["card"], "\(held)")
        let shared = card["config"]?["sharedHome"]
        let names = shared?["names"]?.array?.compactMap(\.string) ?? []
        #expect(names.contains("~/.claude/settings.json"), "\(card)")
        #expect(WireSchema.check(card, as: "card") == nil, "\(WireSchema.check(card, as: "card") ?? "")")
        let id = try #require(card["id"]?.string)
        let projectCard = try #require(world.card(id))
        #expect(!(projectCard.config?.items ?? []).contains { names.contains($0.name) }, "not listed")
        #expect(!(projectCard.config?.hashes.keys.map(ConfigSeal.name(ofKey:)) ?? []).contains { names.contains($0) }, "not sealed")
        let homeID = try #require(shared?["card"]?.string)
        #expect(homeID == homeFirst.result?["card"]?["id"]?.string)
        let homeCard = try #require(world.card(homeID))
        #expect(homeCard.isOpen && homeCard.root == home && homeCard.kind == .configHeld)
        let homeNames = Set((homeCard.config?.items ?? []).map(\.name))
        #expect(Set(names).isSubset(of: homeNames), "\(names) \(homeNames)")
        let short = CardText.lines(card, long: false)
        // The folder, never the other card's id (it may be superseded or accepted since).
        #expect(short.contains { $0.contains("and \(names.count) of your home folder's config, the same as \(home)'s card shows it") }, "\(short)")
        #expect(!short.contains { $0.contains(homeID) }, "\(short)")
        #expect(!short.contains { $0.hasPrefix("    ~/.claude/settings.json") }, "\(short)")
        // Asked again: the same cards (nothing redrawn); the home's own card leaves nothing to another.
        let again = try #require(await world.ask("config.held", ["folder": .string(world.repo)], action: nil))
        #expect(again.result?["card"]?["id"]?.string == id && again.result?["card"]?["config"]?["sharedHome"]?["card"]?.string == homeID, "\(again)")
        let homeHeld = try #require(await world.ask("config.held", ["folder": .string(home)], action: nil))
        #expect(homeHeld.result?["card"]?["id"]?.string == homeID && homeHeld.result?["card"]?["config"]?["sharedHome"] == .null, "\(homeHeld)")

        // The project's first: its own sealed, the home's still held, said; no floor recorded.
        let first = try #require(await world.ask("config.accept", ["card": .string(id), "code": .string(NodeIds.code(card: id))]))
        #expect(first.ok && first.result?["homeWaits"]?.array?.compactMap(\.string).contains("~/.claude/settings.json") == true
                && first.result?["homeCard"]?.string == homeID && first.result?["floorRecorded"]?.bool == false, "\(first)")
        #expect(world.card(id)?.closed?.hasPrefix("accepted; the home folder's") == true, "\(String(describing: world.card(id)?.closed))")
        // Said in `status` while its rails and floor wait, with the one command.
        let notices = { world.requests.queue.sync { world.requests.statusValue()["notices"]?.array?.compactMap(\.string) ?? [] } }
        #expect(notices().contains { $0.contains("guard rails and review floor aren't recorded yet") && $0.contains("vibeswitcher config held \(world.repo)") },
                "\(notices())")
        // And in the brief (the template's words: no model in a test).
        let brief = try #require(await world.ask("brief", [:], action: nil))
        #expect(brief.result?["text"]?.string?.contains("guard rails and review floor aren't recorded yet") == true, "\(brief)")
        // The home's, then the project's again: nothing of the home's left on it, and its accept records the floor.
        let heldBefore = world.held().count
        let homeAccepted = try #require(await world.ask("config.accept", ["card": .string(homeID), "code": .string(NodeIds.code(card: homeID))]))
        #expect(homeAccepted.ok, "\(homeAccepted)")
        // The project's lead is told to go ahead (its home's config sealed), and the notice says to accept its card again.
        #expect(await eventually(timeout: 30) { world.held().count > heldBefore && world.held().last?.text.contains("(your home folder's)") == true },
                "\(world.held().map(\.text))")
        #expect(notices().contains { $0.contains("that one is accepted now, so accept this folder's again") }, "\(notices())")
        let after = try #require(await world.ask("config.held", ["folder": .string(world.repo)], action: nil))
        let afterCard = try #require(after.result?["card"], "\(after)")
        #expect(afterCard["config"]?["sharedHome"] == .null && afterCard["config"]?["items"]?.array?.contains { $0["name"]?.string == "~/.claude/settings.json" } != true,
                "\(afterCard)")
        let afterID = try #require(afterCard["id"]?.string)
        let last = try #require(await world.ask("config.accept", ["card": .string(afterID), "code": .string(NodeIds.code(card: afterID))]))
        #expect(last.ok && last.result?["homeWaits"] == nil, "\(last)")
        #expect(!notices().contains { $0.contains("guard rails and review floor aren't recorded yet") }, "\(notices())")
    }

    @Test func oneCodeDoesTheListedBatchEachItemItsOwnAction() async throws {
        let world = try await world()
        defer { world.stop() }
        let listed = try await list(world)
        let items = listed["items"]?.array ?? []
        #expect(items.compactMap { $0["kind"]?.string }.allSatisfy { $0 == "config.accept" } && !items.isEmpty, "\(listed)")
        let subjects = items.compactMap { $0["subject"]?.string }
        #expect(subjects.contains(world.repo), "\(listed)")
        // Each item with its card, as `config held` shows it.
        let shown = items.map { item in CardText.lines(item["card"] ?? .null, long: false).joined(separator: "\n") }
        // Plain (the default): what changed in the node's words, whom it holds, each item's kind and what on the wire.
        for item in items {
            let card = item["card"] ?? .null
            let plain = CardText.plainConfig(card)
            #expect(plain.contains { $0.hasPrefix("holds ") }, "\(plain)")
            #expect(!plain.joined().contains("hash"), "\(plain)")
            for held in card["config"]?["items"]?.array ?? [] { #expect(held["kind"]?.string != nil && held["what"]?.string != nil, "\(held)") }
            #expect(WireSchema.check(card, as: "card") == nil, "\(WireSchema.check(card, as: "card") ?? "")")
        }
        // The home's lists it; a project's says it in its line of what it shares with the home's card.
        // The home's lists it; a project's says it in its line of what it leaves to the home's card.
        #expect(shown.allSatisfy { $0.contains("~/.claude/settings.json") || $0.contains("of your home folder's config, the same as") }, "\(shown)")
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        #expect(code == NodeIds.code(card: batch))

        // Another code: refused by voice; the batch still stands.
        let wrong = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string("ZZZZ")]))
        #expect(wrong.error?.code == NodeWire.Code.voice.rawValue, "\(wrong)")

        let action = UUID().uuidString.lowercased()
        let done = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)], action: action))
        let result = try #require(done.result, "\(done)")
        let doneItems = result["done"]?.array ?? []
        #expect(doneItems.count == items.count && result["refused"] == .null, "\(result)")
        #expect(doneItems.enumerated().allSatisfy { $0.element["action"]?.string == Requests.itemAction(action, $0.offset) }, "\(result)")
        // Recorded: the batch's action and each item's, each its own.
        let accepted = world.queue.sync { world.requests.accepted }
        #expect(accepted.contains { $0.kind == "approve" && $0.action == action }, "\(accepted)")
        for index in items.indices {
            #expect(accepted.contains { $0.kind == "config.accept" && $0.action == Requests.itemAction(action, index) }, "\(accepted)")
        }
        // Taken once: a new action finds no batch; the same action is answered as before, nothing done twice.
        let again = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        #expect(again.error?.code == NodeWire.Code.gone.rawValue, "\(again)")
        let replayed = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)], action: action))
        #expect(replayed.ok && replayed.result?["done"]?.array?.count == items.count, "\(replayed)")
        #expect(world.queue.sync { world.requests.accepted }.filter { $0.kind == "config.accept" }.count == items.count)
        // Nothing held any more: nothing to list.
        let after = try await list(world)
        #expect(after["items"]?.array?.isEmpty == true && after["batch"] == nil, "\(after)")
    }

    @Test func aCardSettledSinceStopsTheBatchSayingWhatsLeft() async throws {
        let world = try await world()
        defer { world.stop() }
        let listed = try await list(world)
        let items = listed["items"]?.array ?? []
        try #require(items.count >= 2, "the repo's card and the home's: \(listed)")
        // The first item's card accepted on its own meanwhile.
        let first = try #require(items[0]["card"]?["id"]?.string)
        let alone = try #require(await world.ask("config.accept", ["card": .string(first), "code": .string(NodeIds.code(card: first))]))
        #expect(alone.ok, "\(alone)")
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        let done = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        let result = try #require(done.result, "\(done)")
        #expect(result["done"]?.array?.isEmpty == true, "\(result)")
        #expect(result["refused"]?["kind"]?.string == "config.accept" && result["refused"]?["subject"]?.string == items[0]["subject"]?.string, "\(result)")
        #expect(result["left"]?.array?.count == items.count - 1, "\(result)")
    }

    @Test func onlyTheUserListsOrApprovesAndOnlyNamesNarrowIt() async throws {
        let world = try await world()
        defer { world.stop() }
        var session = CardWorld.user
        session.sessionMarker = true
        for kind in ["approve.list", "approve"] {
            let refused = try #require(await world.ask(kind, ["batch": .string("x"), "code": .string("x")], from: session))
            #expect(refused.error?.code == NodeWire.Code.voice.rawValue, "\(kind): \(refused)")
        }
        #expect(NodeWire.kinds["approve"] == .user && NodeWire.changesState("approve") && !NodeWire.changesState("approve.list"))
        let bad = try #require(await world.ask("approve.list", ["only": .array([.string("questions")])], action: nil))
        #expect(bad.error?.code == NodeWire.Code.badArgs.rawValue, "\(bad)")
        let bases = try await list(world, only: ["base"])
        #expect(bases["items"]?.array?.allSatisfy { $0["kind"]?.string == "base.accept" } == true, "\(bases)")
        #expect(Requests.itemAction("a", 0) != Requests.itemAction("a", 1) && Requests.itemAction("a", 0) == Requests.itemAction("A", 0))
        #expect(UUID(uuidString: Requests.itemAction(UUID().uuidString, 3)) != nil)
    }
}

extension ApproveTests {
    /// The review's fixes: what a batch may hold, and how it is asked.
    @Test func whatABatchLeavesToTheUserAndWhatItNeverLists() async throws {
        let world = try await world()
        defer { world.stop() }
        // A folder only the accepted snapshot names (a file an agent could write) is never listed.
        let planted = scratch.url("planted")
        try FileManager.default.createDirectory(at: planted.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try AcceptedSnapshot.update(root: world.host.root, project: planted.path) { _ in }
        // A project whose guard rails changed since they were recorded: its card is the user's own decision.
        let railed = scratch.url("railed")
        try await scratchRepository(railed)
        try await project(world, railed.path)
        try workflow(railed.path, "---\ntest_command: make check\n---\n")
        _ = await world.ask("config.held", ["folder": .string(railed.path)], action: nil)
        let listed = try await list(world, only: ["config", "base"])
        let subjects = (listed["items"]?.array ?? []).compactMap { $0["subject"]?.string }
        #expect(!subjects.contains(planted.path) && !subjects.contains(railed.path), "\(subjects)")
        let own = (listed["own"]?.array ?? []).map { "\($0["text"]?.string ?? "") \($0["command"]?.string ?? "")" }
        // Named with the card's own command (`CardStore.Card.settle`), as `status` and the page name it.
        #expect(own.contains { $0.contains("rules to record") && $0.contains(railed.path) && $0.contains("vibeswitcher config accept local:card:") }, "\(own)")
        // Bases that didn't move list nothing.
        #expect(!(listed["items"]?.array ?? []).contains { $0["kind"]?.string == "base.accept" }, "\(listed)")
        let bases = try await list(world, only: ["base"])
        #expect(bases["items"]?.array?.isEmpty == true && bases["batch"] == nil, "\(bases)")
        // The hooks out of date: never beside a config accept (their own line), a batch of their own otherwise.
        world.queue.sync { world.requests.nodeRoot = world.host.folder.path }
        let withConfig = try await list(world, only: ["config", "hooks"])
        #expect(!(withConfig["items"]?.array ?? []).contains { $0["kind"]?.string == "hooks.install" }, "\(withConfig)")
        #expect((withConfig["own"]?.array ?? []).contains { $0["command"]?.string == HooksRequest.installCommand }, "\(withConfig)")
        let alone = try await list(world, only: ["hooks"])
        #expect(alone["items"]?.array?.map { $0["kind"]?.string } == ["hooks.install"], "\(alone)")
    }

    @Test func moreThanOneCodeMayCoverIsRefusedAndARefusedBatchLeavesNoRecord() async throws {
        let world = try await world()
        defer { world.stop() }
        for index in 0..<Requests.approveMost {
            let root = scratch.url("project-\(index)")
            try await scratchRepository(root)
            try await project(world, root.path)
            _ = await world.ask("config.held", ["folder": .string(root.path)], action: nil)
        }
        let settings = world.host.home.appendingPathComponent(".claude/settings.json")
        try #"{"env":{"A":"3"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let many = try #require(await world.ask("approve.list", ["only": .array([.string("config")])], action: nil))
        #expect(many.error?.code == NodeWire.Code.refused.rawValue && many.error?.message.contains("settle them per folder") == true, "\(many)")
        // A batch it doesn't know: refused before anything is recorded (no false mark in `status`'s journal check).
        let unknown = try #require(await world.ask("approve", ["batch": .string("local:approve:none"), "code": .string("ABCD")]))
        #expect(unknown.error?.code == NodeWire.Code.gone.rawValue, "\(unknown)")
        #expect(!world.queue.sync { world.requests.accepted }.contains { $0.kind == "approve" })
    }

    /// The rails gate is the card's own, and the accept's: a base_branch changed counts as a rail, a floor the vault
    /// hasn't recorded while the workflow proposes one counts; and a batch's card whose accept would record a rail
    /// (the vault's record changed between the list and the code) is refused at approve, recording nothing.
    @Test func aBatchNeverRecordsARailOrAFloorEvenIfTheRecordChangesMeanwhile() async throws {
        let world = try await world()
        defer { world.stop() }
        let vault = world.host.vault
        // base_branch changed since it was recorded: a rail to record.
        let based = scratch.url("based")
        try await scratchRepository(based)
        try await project(world, based.path)
        try workflow(based.path, "---\nbase_branch: develop\n---\n")
        _ = await world.ask("config.held", ["folder": .string(based.path)], action: nil)
        // No floor recorded while the workflow proposes one.
        let floorless = scratch.url("floorless")
        try await scratchRepository(floorless)
        try await project(world, floorless.path, floor: false)
        let unset = try await offPool { try vault.reviewFloor(root: floorless.path) }
        try #require(unset == nil)
        _ = await world.ask("config.held", ["folder": .string(floorless.path)], action: nil)
        let listed = try await list(world)
        let subjects = (listed["items"]?.array ?? []).compactMap { $0["subject"]?.string }
        let own = (listed["own"]?.array ?? []).map { "\($0["text"]?.string ?? "") \($0["command"]?.string ?? "")" }
        #expect(!subjects.contains(based.path) && own.contains { $0.contains(based.path) && $0.contains("vibeswitcher config accept local:card:") }, "\(subjects) \(own)")
        #expect(!subjects.contains(floorless.path) && own.contains { $0.contains(floorless.path) && $0.contains("vibeswitcher config accept local:card:") }, "\(subjects) \(own)")
        #expect(subjects.contains(world.repo), "\(listed)")

        // Between the list and the code, the vault's record of the repo's rails changes (another accept, a newer
        // workflow): the batch's card would write its older rails back. Refused at approve; nothing recorded.
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        let changed = ["test_command": LeadVault.hash("make other")]
        try await offPool { try vault.setGuardedSettings(changed, root: world.repo) }
        let before = try await offPool { try vault.guardedSettings(root: world.repo) }
        let floorBefore = try await offPool { try vault.reviewFloor(root: world.repo) }
        let done = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        let result = try #require(done.result, "\(done)")
        let refused = try #require(result["refused"], "\(result)")
        #expect(refused["subject"]?.string == world.repo && refused["message"]?.string?.contains("which a batch never does") == true
                && refused["message"]?.string?.contains("vibeswitcher config held \(world.repo)") == true, "\(result)")
        let after = try await offPool { try vault.guardedSettings(root: world.repo) }
        let floorAfter = try await offPool { try vault.reviewFloor(root: world.repo) }
        #expect(after == before, "no rail recorded")
        #expect(floorAfter == floorBefore, "no floor recorded")
        let card = try #require((listed["items"]?.array ?? []).first { $0["subject"]?.string == world.repo }?["card"]?["id"]?.string)
        #expect(world.queue.sync { world.engine.cards.cards[card]?.isOpen } == true, "the card left open for the folder's own accept")
    }

    @Test func aWorkflowEditedBetweenTheListAndTheCodeRecordsNoRail() async throws {
        let world = try await world()
        defer { world.stop() }
        let vault = world.host.vault
        let listed = try await list(world)
        try #require((listed["items"]?.array ?? []).contains { $0["subject"]?.string == world.repo }, "\(listed)")
        let before = try await offPool { try vault.guardedSettings(root: world.repo) }
        try workflow(world.repo, "---\ntest_command: make edited\nbase_branch: edited\n---\n")
        let batch = try #require(listed["batch"]?.string)
        let code = try #require(listed["code"]?.string)
        _ = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        let after = try await offPool { try vault.guardedSettings(root: world.repo) }
        #expect(after == before, "the edit's rails are never recorded by the batch")
    }

    /// The Mac's approval dialog names a batch within its budget: counts per kind, its folders once.
    @Test func theMacsDialogNamesABatchCompactly() {
        let items = (0..<12).map { index in
            Requests.ApproveItem(kind: index < 9 ? "config.accept" : "base.accept", args: [:], subject: "/home/u/projects/a-long-project-name-\(index % 10)")
        } + [Requests.ApproveItem(kind: "hooks.install", args: [:], subject: "claude")]
        let shown = Requests.approveShown(items)
        #expect(shown.count <= ApprovalVoice.cardLimit - 40 + 20 && shown.hasPrefix("accept 9 held config cards, 3 moved bases, the hooks in "), "\(shown)")
        #expect(shown.contains("more"), "\(shown)")
    }
}

/// The hooks out of date, as `approve` lists them (`HooksRequest.outOfDate`).
struct HooksOutOfDateTests {
    private let scratch = Scratch()

    /// `status` after a switch (2026-11-24): one line with what waits and the one command for each part, and the hooks
    /// out of date with their command (`HooksLook`), each program hashed again only when its file changed.
    @Test func statusSaysWhatWaitsAndTheHooksWithTheirCommands() async throws {
        typealias Counts = WireKinds.Status.CardCounts
        #expect(CardText.waitingLine(nil) == nil && CardText.waitingLine(Counts(questions: 0, approvals: 0, config: 0, base: 0)) == nil)
        #expect(CardText.waitingLine(Counts(questions: 2, approvals: 1, config: 4, base: 1))
            == "waiting on you: 4 held config, 1 base move: `vibeswitcher approve` settles them with one code; 2 questions, 1 approval to answer: `vibeswitcher questions`")
        #expect(CardText.waitingLine(Counts(questions: 1, approvals: nil, config: nil, base: 2))
            == "waiting on you: 2 base moves: `vibeswitcher approve` settles them with one code; 1 question to answer: `vibeswitcher questions`")
        #expect(HooksLook.notice(reasons: ["a", "b"], agents: [.claude, .codex])
            == "the hooks are out of date: a; b: vibeswitcher hooks install (or `vibeswitcher approve`, with what else waits)")

        // Kept by the file's stat: the same file isn't read again; a changed one is.
        let look = HooksLook()
        let file = scratch.url("program")
        try Data("one".utf8).write(to: file)
        let first = look.sha256(file.path)
        #expect(first == HooksRequest.sha256(file.path))
        #expect(look.sha256(file.path) == first)
        try Data("two".utf8).write(to: file)
        #expect(look.sha256(file.path) == HooksRequest.sha256(file.path) && look.sha256(file.path) != first)

        // A server's status on a home without the hooks: the notice, after the look `status` makes.
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let done = Locked(false)
        world.queue.async {
            world.requests.nodeRoot = world.host.folder.path
            world.requests.refreshNotes { done.value = true }
        }
        try #require(await eventually(timeout: 60) { done.value })
        let notices = world.queue.sync { world.requests.statusNotices() }
        #expect(notices.contains { $0.hasPrefix("the hooks are out of date: ") && $0.contains(": vibeswitcher hooks install (or") }, "\(notices)")
    }

    @Test func aMissingProgramAndAConfigWithoutTheHooksAreSaid() throws {
        let home = scratch.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try "{}".write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let request = HooksRequest(nodeRoot: "/nonexistent", home: home, binaries: ["vibeswitcher-hook": "aa", "vibeswitcher-mcp": "bb"],
                                   vault: LeadVault(folder: scratch.url("vault")) { _ in .ok })
        let said = request.outOfDate(agents: [.claude])
        #expect(said.contains { $0.contains("vibeswitcher-hook isn't installed") } && said.contains { $0.contains("vibeswitcher-mcp isn't installed") }, "\(said)")
        #expect(said.contains { $0.contains("lacks VibeSwitcher's hooks for claude") }, "\(said)")
        // A program that isn't the build's.
        try FileManager.default.createDirectory(atPath: home + "/.vibeswitcher/bin", withIntermediateDirectories: true)
        try Data("other".utf8).write(to: URL(fileURLWithPath: home + "/.vibeswitcher/bin/vibeswitcher-hook"))
        #expect(request.outOfDate(agents: []).contains { $0.contains("isn't this build's vibeswitcher-hook") })
        // Never read: a file past a program's size (sparse, so it costs nothing here), nor one that isn't a plain file.
        let mcp = home + "/.vibeswitcher/bin/vibeswitcher-mcp"
        FileManager.default.createFile(atPath: mcp, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: mcp))
        try handle.truncate(atOffset: UInt64(HooksRequest.programLimit) + 1)
        try handle.close()
        try FileManager.default.removeItem(atPath: home + "/.vibeswitcher/bin/vibeswitcher-hook")
        try FileManager.default.createDirectory(atPath: home + "/.vibeswitcher/bin/vibeswitcher-hook", withIntermediateDirectories: true)
        let odd = request.outOfDate(agents: [])
        #expect(odd.filter { $0.contains("isn't a plain file of a program's size") }.count == 2, "\(odd)")
    }
}
