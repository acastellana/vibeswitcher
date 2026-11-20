import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `settings` and `set` on a scratch host (the parity table's gap 9): a read anyone of the uid may ask, in the wire's
/// shape; a change in the user's voice, recorded in the vault first, written where the leads read it, a guard rail
/// recorded as the user's, the project's running lead told, the policy told to every running lead, boost decided; refused
/// from a session's process and from a web page, and for a value out of its form.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct SettingsRequestTests {
    private let scratch = Scratch()

    private func set(_ world: CardWorld, _ key: String, _ value: String, folder: String? = nil, action: String = UUID().uuidString.lowercased(),
                     from facts: PeerFacts = CardWorld.user) async -> NodeWire.Reply? {
        var args: [String: NodeWire.Value] = ["key": .string(key), "value": .string(value)]
        if let folder { args["folder"] = .string(folder) }
        return await world.ask("set", args, action: action, from: facts)
    }

    private func files(_ world: CardWorld) -> NodeSettings.Files { NodeSettings.Files(root: world.world.host.root) }

    @Test func settingsReadsTheNodesAndAProjectsInTheWiresShape() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        // No lead has worked in the repository yet: its folder is gone, the node's still read.
        let gone = try #require(await world.ask("settings", ["folder": .string(world.repo)], action: nil))
        #expect(gone.error?.code == NodeWire.Code.gone.rawValue && gone.error?.message.contains("vibeswitcher lead") == true, "\(gone)")
        let node = try #require(await world.ask("settings", [:], action: nil))
        #expect(node.ok && node.result?["project"] == .null, "\(node)")
        #expect(WireSchema.check(node.result ?? .null, as: "settings.result", strict: true) == nil)

        _ = try await offPool { try BoardStore(root: world.repo).prepare() }
        let inside = world.repo + "/docs"
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        let both = try #require(await world.ask("settings", ["folder": .string(inside)], action: nil))
        let result = try #require(both.result, "\(both)")
        #expect(WireSchema.check(result, as: "settings.result", strict: true) == nil, "\(WireSchema.check(result, as: "settings.result", strict: true) ?? "")")
        #expect(result["project"]?["root"]?.string == world.repo)
        let keys = result["project"]?["settings"]?.array?.compactMap { $0["key"]?.string } ?? []
        #expect(keys == NodeSettings.all.filter { $0.scope == .project }.map(\.key))
        let rail = result["project"]?["settings"]?.array?.first { $0["key"]?.string == "max_workers" }
        #expect(rail?["guardRail"]?.bool == true && rail?["where"]?.string == NodeSettings.workflowPath(project: world.repo))
        // Read, so no vault record.
        #expect(await world.actions().isEmpty)
    }

    @Test func aNodeSettingIsRecordedThenWrittenWhereTheLeadsReadIt() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await set(world, "mac_max_sessions", "7", action: action))
        #expect(reply.ok && reply.result?["value"]?.string == "7" && reply.result?["was"]?.string == String(MacLimits.defaultMaxSessions), "\(reply)")
        #expect(WireSchema.check(reply.result ?? .null, as: "set.result", strict: true) == nil)
        #expect(MacLimits.load(from: files(world).limits).maxSessions == 7)
        #expect(await world.actions().filter { $0.action == action }.map(\.kind) == ["set"])
        // The same action again is answered as before.
        let again = try #require(await set(world, "mac_max_sessions", "9", action: action))
        #expect(again.ok && MacLimits.load(from: files(world).limits).maxSessions == 7, "\(again)")
    }

    @Test func boostOnIsDecidedForTheLeadsAtOnce() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        // Within the ceiling on any machine (4× the cores), and above the normal limit.
        let sessions = min(20, BoostLimits.countCeiling)
        #expect(try #require(await set(world, "boost_max_sessions", String(sessions))).ok)
        #expect(try #require(await set(world, "boost", "on")).ok)
        let file = files(world).boost
        #expect(await eventually(timeout: 60) { BoostState.active(from: file) != nil })
        #expect(BoostState.active(from: file)?.limits.maxSessions == sessions)
        #expect(MacLimits.current(file: files(world).limits, boostFile: file).maxSessions >= sessions)
        // Automatic acts as off on a node: the boost is taken back.
        #expect(try #require(await set(world, "boost", "automatic")).ok)
        #expect(await eventually(timeout: 60) { BoostState.load(from: file)?.on == false })
        #expect(BoostState.load(from: file)?.why.contains("acts as off") == true)
    }

    @Test func aProjectsGuardRailIsTheUsersAndItsRunningLeadIsTold() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let harness = try await world.world.lead(idle: false)
        let reply = try #require(await set(world, "max_workers", "5", folder: world.repo))
        #expect(reply.ok && reply.result?["told"]?.string == "lead", "\(reply)")
        let workflow = LeadWorkflow.load(from: NodeSettings.workflowPath(project: world.repo))
        #expect(workflow.maxWorkers == 5)
        // Recorded as the user's: the lead's checks take the file as it is.
        let (vault, repo) = (world.world.host.vault, world.repo)
        #expect(try await offPool { try vault.changedSettings(workflow, root: repo) }.isEmpty)
        #expect(try await offPool { try vault.guardedSettings(root: repo) }?["max_workers"] == LeadVault.guardedHashes(workflow)["max_workers"])
        #expect(await eventually(timeout: 60) {
            world.world.pending(harness).contains { $0.from == .system("settings") && $0.text.contains("max_workers to 5") }
        }, "\(world.world.pending(harness))")
    }

    @Test func aFloorRuleIsKeptInTheHostsVault() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        _ = try await offPool { try BoardStore(root: world.repo).prepare() }
        let reply = try #require(await set(world, "floor_audit_finders", "2", folder: world.repo))
        #expect(reply.ok && reply.result?["told"] == .null, "\(reply)")
        let (vault, repo) = (world.world.host.vault, world.repo)
        #expect(try await offPool { try vault.reviewFloor(root: repo) }?.auditFinders == 2)
    }

    @Test func aChangedPolicyIsToldToTheRunningLead() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        world.engine.watchRoom()
        let harness = try await world.world.lead(idle: false)
        let reply = try #require(await set(world, "policy", "- Ship small.\n- Ask before deleting data."))
        #expect(reply.ok && reply.result?["told"]?.string == "leads", "\(reply)")
        #expect(WorkingPolicy.load(from: files(world).policy) == "- Ship small.\n- Ask before deleting data.")
        let told = WorkingPolicy.witnessText("- Ship small.\n- Ask before deleting data.")
        #expect(await eventually(timeout: 60) { world.world.pending(harness).contains { $0.from == .system("witness") && $0.text == told } },
                "\(world.world.pending(harness))")
        // Told once: the next look tells nothing more.
        world.queue.sync { world.engine.lookAtPolicy() }
        await world.drained()
        #expect(world.world.pending(harness).filter { $0.text == told }.count == 1)
    }

    @Test func aValueOutOfItsFormOrScopeIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        for (key, value, folder, says) in [("mac_max_sessions", "0", nil, "1 to 99"), ("boost", "turbo", nil, "one of"),
                                           ("max_workers", "4", nil, "a project's"), ("mac_max_sessions", "4", world.repo, "the node's"),
                                           ("nonsense", "1", nil, "one of `vibeswitcher settings`'s")] as [(String, String, String?, String)] {
            let reply = try #require(await set(world, key, value, folder: folder))
            #expect(reply.error?.code == NodeWire.Code.badArgs.rawValue && reply.error?.message.contains(says) == true, "\(key): \(reply)")
        }
        #expect(MacLimits.load(from: files(world).limits).maxSessions == MacLimits.defaultMaxSessions)
    }

    @Test func aSetFromASessionsProcessIsRefused() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let session = try await world.host.spawn("exec /bin/sleep 600", cwd: world.repo, label: "Worker · parser")
        try #require(await eventually(timeout: 60) { world.queue.sync { world.world.link.sessions.contains { $0.id == session.id && $0.isLive } } })
        let action = UUID().uuidString.lowercased()
        let reply = try #require(await set(world, "ignore_usage_limits", "on", action: action, from: PeerFacts.read(pid: session.childPID)))
        #expect(reply.error?.code == NodeWire.Code.voice.rawValue, "\(reply)")
        #expect(!MacLimits.load(from: files(world).limits).ignoreUsageLimits)
        #expect(await world.actions().filter { $0.action == action }.isEmpty)
    }

    /// A page reads the settings and never sets one, whatever its token's rights.
    @Test func aWebPageReadsAndNeverSets() {
        #expect(NodeWire.kinds["settings"] == .anyone && !NodeWire.changesState("settings"))
        #expect(NodeWire.kinds["set"] == .user && NodeWire.changesState("set") && Requests.recorded.contains("set"))
        let read = WebAccess.refusal(for: NodeWire.Request(id: "1", kind: "settings"), rights: [.read])
        #expect(read == nil)
        let refused = WebAccess.refusal(for: NodeWire.Request(id: "2", kind: "set", args: ["key": .string("boost"), "value": .string("on")]),
                                        rights: [.read, .draft])
        #expect(refused?.error?.code == NodeWire.Code.voice.rawValue, "\(String(describing: refused))")
    }

    /// Through the command line on a scratch node, its code typed on its terminal: a limit set and read back; a value
    /// out of range refused before any code is asked; a wrong form is the usage.
    @Test func theCommandLineSetsAndReadsASetting() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let set = try await node.runOnTerminal(["set", "mac_max_sessions", "7"])
        #expect(set.status == 0, "\(set.output)\(set.errors)\n\(node.said)")
        #expect(set.output.contains("set mac_max_sessions: \(MacLimits.defaultMaxSessions) → 7"), "\(set.output)")
        let read = try await node.run(["settings"])
        #expect(read.status == 0 && read.output.contains("mac_max_sessions = 7"), "\(read.output)\(read.errors)")
        #expect(read.output.contains("Not on a node"), "\(read.output)")
        let refused = try await node.run(["set", "mac_max_sessions", "0"])
        #expect(refused.status == 77 && refused.errors.contains("1 to 99"), "\(refused.output)\(refused.errors)")
        let usage = try await node.run(["set", "mac_max_sessions"])
        #expect(usage.status == 64 && usage.errors.contains("usage: vibeswitcher set"), "\(usage.output)\(usage.errors)")
    }
}
