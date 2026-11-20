import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The node's settings (`NodeSettings`, the parity table's gap 9): each key reads where the app keeps it, a value is
/// taken only in its form and limits, a change is written where the leads' tool servers read it, a guard rail is
/// recorded in the vault as the user's, and the review rules' floor is kept in the vault.
struct NodeSettingsTests {
    private let scratch = Scratch()

    /// A vault in memory: the guard rails' record and the floor, and what was asked of it.
    final class FakeVault: @unchecked Sendable {
        let lock = NSLock()
        var guarded: [String: String]?
        var floor: LeadReviewFloor?
        var sets: [[String: String]] = []
        var floors: [LeadReviewFloor] = []
        var refuseFloor = false

        func vault(folder: URL) -> LeadVault {
            LeadVault(folder: folder) { [self] request in
                lock.lock()
                defer { lock.unlock() }
                switch request {
                case .guarded: return .guarded(guarded)
                case .setGuarded(_, let hashes):
                    sets.append(hashes)
                    guarded = (guarded ?? [:]).merging(hashes) { $1 }
                    return .ok
                case .reviewFloor:
                    if refuseFloor { throw LeadVault.Refused("The session host didn't answer.") }
                    return .reviewFloor(floor)
                case .setReviewFloor(_, let given, _):
                    floors.append(given)
                    floor = given
                    return .reviewFloor(given)
                default: throw LeadVault.Refused("not here")
                }
            }
        }
    }

    private func files() throws -> NodeSettings.Files {
        let root = scratch.url("node")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return NodeSettings.Files(root: root)
    }

    /// A project a lead has worked in: its workflow.md the template.
    private func project() throws -> String {
        let root = scratch.url("project").path
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try LeadWorkflow.template.write(toFile: NodeSettings.workflowPath(project: root), atomically: true, encoding: .utf8)
        return root
    }

    private func value(_ key: String, _ shown: [NodeSettings.Shown]) -> String? { shown.first { $0.setting.key == key }?.value }

    private func set(_ key: String, _ text: String, files: NodeSettings.Files) throws -> NodeSettings.Applied {
        let setting = try #require(NodeSettings.setting(key))
        return try NodeSettings.setNode(setting, to: NodeSettings.parse(setting, text).get(), files: files)
    }

    // MARK: The catalog

    @Test func theCatalogsKeysAreUniqueAndAProjectsAreConfiguresOwn() {
        let keys = NodeSettings.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        for setting in NodeSettings.all where setting.home == .workflow {
            #expect(LeadWorkflow.configurable.contains(setting.key), "\(setting.key)")
        }
        #expect(Set(NodeSettings.all.filter(\.guardRail).map(\.key)) == ["security_audit_model", "max_workers"])
        // Each floor rule is one of the app's floor editor's rows.
        #expect(NodeSettings.all.filter { $0.home == .floor }.count == 8)
        // The machine-wide keys configure refuses (`LeadWorkflow.macKeys`) are the node's, never a project's.
        for key in LeadWorkflow.macKeys { #expect(NodeSettings.setting(key)?.scope != .project, "\(key)") }
    }

    @Test func anEmptyNodeReadsEveryDefault() throws {
        let shown = NodeSettings.node(files: try files())
        #expect(shown.count == NodeSettings.all.filter { $0.scope == .node }.count)
        for item in shown { #expect(item.isDefault, "\(item.setting.key): \(item.value)") }
        #expect(value("policy", shown) == WorkingPolicy.defaultText)
        #expect(value("lead_mail", shown) == "on")
        #expect(value("boost", shown) == "off")
    }

    // MARK: Taking a value

    @Test func aValueIsTakenOnlyInItsFormAndLimits() throws {
        func parse(_ key: String, _ text: String) -> Result<String?, NodeSettings.Refusal> {
            NodeSettings.parse(NodeSettings.setting(key)!, text)
        }
        #expect(try parse("mac_max_sessions", "7").get() == "7")
        #expect((try? parse("mac_max_sessions", "0").get()) == nil)
        #expect((try? parse("mac_max_sessions", "lots").get()) == nil)
        #expect(try parse("mac_max_sessions", "default").get() == nil)
        #expect(try parse("load_threshold", "30.5").get() == "30.5")
        #expect((try? parse("load_threshold", "-1").get()) == nil)
        #expect((try? parse("boost_load_threshold", String(BoostLimits.loadCeiling + 1)).get()) == nil)
        #expect(try parse("ignore_usage_limits", "yes").get() == "on")
        #expect((try? parse("ignore_usage_limits", "maybe").get()) == nil)
        #expect(try parse("boost", "ON").get() == "on")
        #expect((try? parse("boost", "turbo").get()) == nil)
        #expect(try parse("floor_merge_policy", "ask-all").get() == "ask_all")
        #expect(try parse("lead_model", "Opus").get() == "opus")
        #expect((try? parse("lead_model", "opus; rm -rf").get()) == nil)
        #expect((try? parse("security_audit_model", "best").get()) == nil)
        #expect(try parse("floor_strict_paths", " Sources/Auth/ ,, docs/ ").get() == "Sources/Auth/, docs/")
        #expect(try parse("floor_strict_paths", "none").get() == "")
        #expect(try parse("policy", "  - One rule.\n- Two.\n").get() == "- One rule.\n- Two.")
        #expect((try? parse("policy", String(repeating: "x", count: NodeSettings.policyLimit + 1)).get()) == nil)
    }

    // MARK: The node's own

    @Test func theLimitsAreWrittenWhereTheLeadsReadThem() throws {
        let files = try files()
        let applied = try set("mac_max_sessions", "7", files: files)
        #expect(applied.value == "7" && applied.was == String(MacLimits.defaultMaxSessions) && applied.told == nil)
        _ = try set("load_threshold", "30", files: files)
        _ = try set("ignore_usage_limits", "on", files: files)
        var limits = MacLimits.load(from: files.limits)
        #expect(limits.maxSessions == 7 && limits.loadThreshold == 30 && limits.ignoreUsageLimits)
        _ = try set("load_threshold", "default", files: files)
        limits = MacLimits.load(from: files.limits)
        #expect(limits.loadThreshold == nil && limits.maxSessions == 7)
        #expect(value("load_threshold", NodeSettings.node(files: files)) == "default")
    }

    /// The memory holds the file has, which no setting here shows, are kept as they are.
    @Test func aLimitsChangeKeepsWhatItDoesntSet() throws {
        let files = try files()
        try MacLimits(memoryPressure: "critical", swapOutRate: 80).save(to: files.limits)
        _ = try set("mac_heavy_slots", "1", files: files)
        let limits = MacLimits.load(from: files.limits)
        #expect(limits.memoryPressure == "critical" && limits.swapOutRate == 80 && limits.heavySlots == 1)
    }

    @Test func boostAndLeadMailAreTheAppsDefaultsKeys() throws {
        let files = try files()
        _ = try set("boost", "on", files: files)
        _ = try set("boost_max_workers", "9", files: files)
        _ = try set("lead_mail", "off", files: files)
        let store = try #require(Platform.settings(domain: files.preferencesDomain))
        #expect(store.string(forKey: "boostMode") == "on")
        #expect(NodeSettings.boostLimits(store).maxWorkers == 9 && NodeSettings.boostLimits(store).maxSessions == BoostLimits.defaultMaxSessions)
        #expect(!LeadMail.isOn(store))
        _ = try set("lead_mail", "default", files: files)
        #expect(LeadMail.isOn(store) && store.object(forKey: LeadMail.enabledKey) == nil)
        #expect(FileManager.default.fileExists(atPath: files.root.appendingPathComponent("settings.plist").path))
    }

    @Test func thePolicyIsWrittenAndPutBack() throws {
        let files = try files()
        _ = try set("policy", "- Ship small.", files: files)
        #expect(WorkingPolicy.load(from: files.policy) == "- Ship small.")
        _ = try set("policy", "default", files: files)
        #expect(WorkingPolicy.load(from: files.policy) == WorkingPolicy.defaultText)
    }

    // MARK: A project's

    @Test func aGuardRailIsWrittenAndRecordedAsTheUsers() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        let vault = fake.vault(folder: scratch.url("vault"))
        let setting = try #require(NodeSettings.setting("max_workers"))
        let applied = try NodeSettings.setProject(setting, to: "5", root: root, vault: vault, workerModel: nil, files: files)
        let workflow = LeadWorkflow.load(from: NodeSettings.workflowPath(project: root))
        #expect(workflow.maxWorkers == 5 && applied.value == "5" && applied.was == "3")
        // Its hash is the user's now, and every rail not recorded before is recorded as it was.
        #expect(fake.guarded?["max_workers"] == LeadVault.guardedHashes(workflow)["max_workers"])
        #expect(Set(fake.guarded?.keys.map { $0 } ?? []) == Set(LeadVault.guardedKeys))
        #expect(try vault.changedSettings(workflow, root: root).isEmpty)
        #expect(applied.told?.contains("max_workers to 5") == true && applied.told?.contains("recorded in the vault") == true)
    }

    @Test func aModelThatIsNoGuardRailIsWrittenAloneWithNoRecord() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        let vault = fake.vault(folder: scratch.url("vault"))
        let applied = try NodeSettings.setProject(NodeSettings.setting("lead_model")!, to: "opus", root: root, vault: vault, workerModel: nil, files: files)
        #expect(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)).leadModel == "opus")
        #expect(fake.sets.isEmpty)
        #expect(applied.told?.contains("next starts") == true)
        // Back to the default: the line is cleared.
        _ = try NodeSettings.setProject(NodeSettings.setting("lead_model")!, to: nil, root: root, vault: vault, workerModel: nil, files: files)
        #expect(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)).leadModel == LeadWorkflow.defaultLeadModel)
    }

    @Test func theFloorHoldsTheVerifiersModelForTheUserToo() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        fake.floor = LeadReviewFloor(verifierDifferent: true)
        let vault = fake.vault(folder: scratch.url("vault"))
        let setting = try #require(NodeSettings.setting("verifier_model"))
        #expect(throws: NodeSettings.Refusal.self) {
            try NodeSettings.setProject(setting, to: "opus", root: root, vault: vault, workerModel: "opus", files: files)
        }
        #expect(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)).verifierModel?.isEmpty != false)
        _ = try NodeSettings.setProject(setting, to: "fable", root: root, vault: vault, workerModel: "opus", files: files)
        #expect(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)).verifierModel == "fable")
        // A vault that can't say what the floor is changes nothing.
        fake.refuseFloor = true
        #expect(throws: NodeSettings.Refusal.self) {
            try NodeSettings.setProject(setting, to: "sonnet", root: root, vault: vault, workerModel: "opus", files: files)
        }
        #expect(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)).verifierModel == "fable")
    }

    @Test func aFloorRuleIsKeptInTheVault() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        let vault = fake.vault(folder: scratch.url("vault"))
        // None recorded: the project's values, then the one rule changed.
        let finders = try NodeSettings.setProject(NodeSettings.setting("floor_audit_finders")!, to: "2", root: root, vault: vault,
                                                  workerModel: nil, files: files)
        #expect(finders.value == "2" && finders.was == "1")
        let starting = LeadReviewFloor.starting(from: LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)))
        #expect(fake.floor?.auditFinders == 2 && fake.floor?.sensitivePaths == starting.sensitivePaths)
        _ = try NodeSettings.setProject(NodeSettings.setting("floor_strict_paths")!, to: "Sources/Auth/, docs/", root: root, vault: vault,
                                        workerModel: nil, files: files)
        #expect(fake.floor?.strictPaths == ["Sources/Auth/", "docs/"] && fake.floor?.auditFinders == 2)
        _ = try NodeSettings.setProject(NodeSettings.setting("floor_merge_policy")!, to: "ask_all", root: root, vault: vault,
                                        workerModel: nil, files: files)
        #expect(fake.floor?.mergePolicy == .askAll)
        // The workflow.md isn't touched by a floor.
        #expect(try String(contentsOfFile: NodeSettings.workflowPath(project: root), encoding: .utf8) == LeadWorkflow.template)
        let shown = NodeSettings.project(root: root, workflow: LeadWorkflow.load(from: NodeSettings.workflowPath(project: root)), floor: fake.floor, files: files)
        #expect(value("floor_merge_policy", shown) == "ask_all" && shown.first { $0.setting.home == .floor }?.note == nil)
    }

    @Test func aFolderNoLeadWorkedInIsRefused() throws {
        let files = try files()
        let root = scratch.url("bare").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let vault = FakeVault().vault(folder: scratch.url("vault"))
        #expect(throws: NodeSettings.Refusal.self) {
            try NodeSettings.setProject(NodeSettings.setting("max_workers")!, to: "4", root: root, vault: vault, workerModel: nil, files: files)
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/.vibeswitcher"))
    }
}
