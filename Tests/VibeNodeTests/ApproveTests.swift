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

    @Test func oneCodeDoesTheListedBatchEachItemItsOwnAction() async throws {
        let world = try await world()
        defer { world.stop() }
        let listed = try await list(world)
        let items = listed["items"]?.array ?? []
        #expect(items.compactMap { $0["kind"]?.string }.allSatisfy { $0 == "config.accept" } && !items.isEmpty, "\(listed)")
        let subjects = items.compactMap { $0["subject"]?.string }
        #expect(subjects.contains(world.repo), "\(listed)")
        // Each item with its card, as `config held` shows it.
        let shown = items.map { item in CardText.lines(item["card"] ?? .null).joined(separator: "\n") }
        #expect(shown.allSatisfy { $0.contains("~/.claude/settings.json") }, "\(shown)")
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
        // Taken once: a new action finds no batch; the same action is told it was done (a batch's result isn't kept,
        // `RetryRule.keepsResult`), nothing done twice.
        let again = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)]))
        #expect(again.error?.code == NodeWire.Code.gone.rawValue, "\(again)")
        let replayed = try #require(await world.ask("approve", ["batch": .string(batch), "code": .string(code)], action: action))
        #expect(!replayed.ok && replayed.error?.message.contains("was done") == true, "\(replayed)")
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
        #expect(own.contains { $0.contains("guard rails or a review floor to record") && $0.contains("vibeswitcher config held \(railed.path)") }, "\(own)")
        // Bases that didn't move list nothing.
        #expect(!(listed["items"]?.array ?? []).contains { $0["kind"]?.string == "base.accept" }, "\(listed)")
        let bases = try await list(world, only: ["base"])
        #expect(bases["items"]?.array?.isEmpty == true && bases["batch"] == nil, "\(bases)")
        // The hooks out of date: never beside a config accept (their own line), a batch of their own otherwise.
        world.queue.sync { world.requests.nodeRoot = world.host.folder.path }
        let withConfig = try await list(world, only: ["config", "hooks"])
        #expect(!(withConfig["items"]?.array ?? []).contains { $0["kind"]?.string == "hooks.install" }, "\(withConfig)")
        #expect((withConfig["own"]?.array ?? []).contains { $0["command"]?.string?.hasPrefix("vibeswitcher hooks install --agent claude") == true }, "\(withConfig)")
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
        let own = (listed["own"]?.array ?? []).compactMap { $0["command"]?.string }
        #expect(!subjects.contains(based.path) && own.contains("vibeswitcher config held \(based.path)"), "\(subjects) \(own)")
        #expect(!subjects.contains(floorless.path) && own.contains("vibeswitcher config held \(floorless.path)"), "\(subjects) \(own)")
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
