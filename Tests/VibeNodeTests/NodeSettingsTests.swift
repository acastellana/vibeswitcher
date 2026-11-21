import Foundation
import Testing
@testable import VibeCore
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
            // lead_rotation is the node's stand-in for the app's Settings (`IdleHandover`): the user's to set, never a
            // lead's through configure.
            if setting.key == "lead_rotation" {
                #expect(!LeadWorkflow.configurable.contains(setting.key))
                continue
            }
            #expect(LeadWorkflow.configurable.contains(setting.key), "\(setting.key)")
        }
        #expect(Set(NodeSettings.all.filter(\.guardRail).map(\.key)) == ["security_audit_model", "max_workers"])
        // Each floor rule is one of the app's floor editor's rows.
        #expect(NodeSettings.all.filter { $0.home == .floor }.count == 8)
        // The machine-wide keys configure refuses (`LeadWorkflow.macKeys`) are the node's, never a project's.
        for key in LeadWorkflow.macKeys { #expect(NodeSettings.setting(key)?.scope != .project, "\(key)") }
    }

    /// On any machine: Boost's ceilings follow the cores (4× them), so on a small one its defaults are kept under them,
    /// and those are what a node reads as its defaults.
    @Test(arguments: [nil, 2, 4, 24] as [Int?])
    func anEmptyNodeReadsEveryDefault(cores: Int?) throws {
        let files = try files()
        try MacLoad.$simulatedProcessors.withValue(cores ?? MacLoad.processors) { () throws in
            let shown = NodeSettings.node(files: files)
            #expect(shown.count == NodeSettings.all.filter { $0.scope == .node }.count)
            for item in shown { #expect(item.isDefault, "\(cores.map(String.init) ?? "this machine's") cores: \(item.setting.key): \(item.value)") }
            #expect(value("policy", shown) == WorkingPolicy.defaultText)
            #expect(value("lead_mail", shown) == "on")
            #expect(value("boost", shown) == "off")
            // Each default is a value `set` takes back.
            for item in shown where item.setting.form == .count || item.setting.form == .number {
                #expect(try NodeSettings.parse(item.setting, item.defaultValue).get() == (item.defaultValue == "default" ? nil : item.defaultValue),
                        "\(item.setting.key): \(item.defaultValue)")
            }
        }
    }

    // MARK: Taking a value

    @Test func aValueIsTakenOnlyInItsFormAndLimits() throws {
        func parse(_ key: String, _ text: String) -> Result<String?, NodeSettings.Refusal> {
            NodeSettings.parse(NodeSettings.setting(key)!, text)
        }
        #expect(try parse("node_max_sessions", "7").get() == "7")
        // The app's names stand for the node's.
        #expect(NodeSettings.setting("mac_max_sessions")?.key == "node_max_sessions" && NodeSettings.setting("mac_heavy_slots")?.key == "node_heavy_slots")
        #expect(!NodeSettings.all.contains { $0.key.hasPrefix("mac_") })
        #expect((try? parse("node_max_sessions", "0").get()) == nil)
        #expect((try? parse("node_max_sessions", "lots").get()) == nil)
        #expect(try parse("node_max_sessions", "default").get() == nil)
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

    /// The projects folder (Settings › General): kept in the node's settings.plist under the app's key, as given (a tilde
    /// path or a full one), read back by `new-project`'s default; `default` puts back `~/dev`. Only a folder is taken.
    @Test func theProjectsFolderIsKeptWhereNewProjectReadsIt() throws {
        let files = try files()
        #expect(NodeSettings.projectsFolder(files: files) == ProjectCreation.defaultLocation)
        let applied = try set("projects_folder", "  ~/code/projects ", files: files)
        #expect(applied.was == "~/dev" && applied.value == "~/code/projects")
        #expect(NodeSettings.projectsFolder(files: files) == "~/code/projects")
        #expect(files.preferences?.string(forKey: "projectsFolder") == "~/code/projects")
        #expect(value("projects_folder", NodeSettings.node(files: files)) == "~/code/projects")
        _ = try set("projects_folder", "/srv/work", files: files)
        #expect(NodeSettings.projectsFolder(files: files) == "/srv/work")
        _ = try set("projects_folder", "default", files: files)
        #expect(NodeSettings.projectsFolder(files: files) == "~/dev")
        #expect(files.preferences?.string(forKey: "projectsFolder") == nil)
        let setting = try #require(NodeSettings.setting("projects_folder"))
        for refused in ["dev", "~other/dev", "./dev", "/a\nb", String(repeating: "/a", count: 600)] {
            #expect((try? NodeSettings.parse(setting, refused).get()) == nil, "\(refused)")
        }
        #expect(try NodeSettings.parse(setting, "~").get() == "~")
    }

    @Test func theLimitsAreWrittenWhereTheLeadsReadThem() throws {
        let files = try files()
        let applied = try set("node_max_sessions", "7", files: files)
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
        _ = try set("node_heavy_slots", "1", files: files)
        let limits = MacLimits.load(from: files.limits)
        #expect(limits.memoryPressure == "critical" && limits.swapOutRate == 80 && limits.heavySlots == 1)
    }

    @Test func boostAndLeadMailAreTheAppsDefaultsKeys() throws {
        let files = try files()
        _ = try set("boost", "on", files: files)
        // Within the ceiling on any machine (4× the cores).
        let workers = min(9, BoostLimits.countCeiling)
        _ = try set("boost_max_workers", String(workers), files: files)
        _ = try set("lead_mail", "off", files: files)
        let store = try #require(Platform.settings(domain: files.preferencesDomain))
        #expect(store.string(forKey: "boostMode") == "on")
        #expect(NodeSettings.boostLimits(store).maxWorkers == workers && NodeSettings.boostLimits(store).maxSessions == BoostLimits().maxSessions)
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
        // Its hash is the user's now, and only its: the rails not recorded before are left to the lead's checks.
        #expect(fake.sets == [["max_workers": LeadVault.guardedHashes(workflow)["max_workers"]!]])
        #expect(try vault.changedSettings(workflow, root: root).isEmpty)
        #expect(applied.told?.contains("max_workers to 5") == true && applied.told?.contains("recorded in the vault") == true)
    }

    /// A rail a worker wrote that the vault has no record of (`sandbox: off`) isn't made the user's by a `set` of
    /// another key: the lead's checks still hold it.
    @Test func aWorkerWrittenUnrecordedRailStaysHeldAfterTheUserSetsAnother() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        let path = NodeSettings.workflowPath(project: root)
        // The vault records every rail as the template has them but the sandbox's keys; then a worker writes one.
        fake.guarded = LeadVault.guardedHashes(LeadWorkflow.load(from: path)).filter { !SandboxPolicy.keys.contains($0.key) }
        try LeadWorkflow.write(LeadWorkflow.updating(try Data(contentsOf: URL(fileURLWithPath: path)), with: [("sandbox", "off")]), to: path)
        let vault = fake.vault(folder: scratch.url("vault"))
        _ = try NodeSettings.setProject(NodeSettings.setting("max_workers")!, to: "5", root: root, vault: vault, workerModel: nil, files: files)
        #expect(fake.sets.flatMap(\.keys) == ["max_workers"])
        let workflow = LeadWorkflow.load(from: path)
        #expect(workflow.maxWorkers == 5)
        #expect(try vault.changedSettings(workflow, root: root).map(\.key) == ["sandbox"])
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

    // MARK: The rotation and the prompt-audit reminder (2026-11-21)

    /// The prompt-audit reminder's on and days are the app's keys in settings.plist; the rotation is workflow.md's
    /// lead_rotation, which the engine's rotation reads.
    @Test func theReminderAndTheRotationAreSetAndRead() async throws {
        let files = NodeSettings.Files(root: scratch.url("node-root"))
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        func shown(_ key: String) -> String? { NodeSettings.node(files: files).first { $0.setting.key == key }?.value }
        #expect(shown("prompt_audit") == "on" && shown("prompt_audit_days") == "14")
        #expect(try set("prompt_audit", "off", files: files).value == "off")
        #expect(try set("prompt_audit_days", "30", files: files).value == "30")
        let store = try #require(files.preferences)
        #expect(!PromptAudit.isOn(store) && PromptAudit.intervalDays(store) == 30)
        guard case .failure = NodeSettings.parse(try #require(NodeSettings.setting("prompt_audit_days")), "91") else {
            Issue.record("91 days is past the app's range")
            return
        }
        let setting = try #require(NodeSettings.setting("lead_rotation"))
        #expect(setting.scope == .project && setting.choices == ["daily", "context", "never"] && !setting.guardRail)
        let workflow = LeadWorkflow.load(from: "/nowhere")
        #expect(NodeSettings.project(root: "/r", workflow: workflow, floor: nil, files: files).first { $0.setting.key == "lead_rotation" }?.value == "context")
        #expect(!NodeSettings.leftOut.contains { $0.title.contains("fresh lead") || $0.title.contains("prompt-audit") })
    }

    /// lead_rotation set in a project's workflow.md, as the rotation reads it, with no vault record; never back.
    @Test func theRotationIsWrittenInWorkflowAndReadByTheEngine() throws {
        let (files, root, fake) = (try files(), try project(), FakeVault())
        let vault = fake.vault(folder: scratch.url("vault"))
        let applied = try NodeSettings.setProject(NodeSettings.setting("lead_rotation")!, to: "never", root: root, vault: vault, workerModel: nil, files: files)
        #expect(applied.value == "never" && applied.was == "context")
        #expect(LeadEngine.rotationMode(LeadWorkflow.load(from: NodeSettings.workflowPath(project: root))) == .never)
        #expect(fake.sets.isEmpty && applied.told?.contains("fresh lead session") == true)
        guard case .failure = NodeSettings.parse(NodeSettings.setting("lead_rotation")!, "hourly") else {
            Issue.record("hourly isn't a mode")
            return
        }
    }
}
