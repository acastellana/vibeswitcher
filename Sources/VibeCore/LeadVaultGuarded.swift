import Foundation

/// workflow.md's guard rails: its test, regression and setup commands, which run under the lead's tool server when merge tests a
/// branch (whoever writes them runs code as the lead), and the settings a worker could loosen to get its work merged
/// or to start more of itself (the merge policy and what it holds back, the records' folder, the limits on sessions
/// and load). The file is in the project's `.vibeswitcher` folder, which every session of the team can write (Bash
/// isn't held by the roles' deny rules), and a worker edits its worktree's copy freely. So the vault keeps a hash of
/// each as the lead last set it with configure, and merge and start_worker refuse, naming the setting, when the file
/// says something else.
extension LeadVault {
    public static let guardedKeys = ["test_command", "regression_command", "init_command", "merge_policy", "sensitive_paths", "records_dir",
                                     "max_workers", "mac_max_sessions", "heavy_slots", "load_threshold", "audit_finders", "audit_nit_cap"]

    /// A guard rail as the team reads it (a limit left out is its default, "ask-all" is ask_all); a key this build
    /// doesn't read itself, as written. Empty when it isn't set.
    public static func guardedValue(_ key: String, in workflow: LeadWorkflow) -> String {
        switch key {
        case "test_command": return workflow.testCommand ?? ""
        case "init_command": return workflow.initCommand ?? ""
        case "regression_command": return workflow.regressionCommand ?? ""
        case "merge_policy": return workflow.mergePolicy?.rawValue ?? ""
        case "sensitive_paths": return workflow.sensitivePaths?.joined(separator: ", ") ?? ""
        case "max_workers": return String(workflow.maxWorkers)
        case "mac_max_sessions": return String(workflow.macMaxSessions)
        case "heavy_slots": return workflow.heavySlots.map(String.init) ?? ""
        case "audit_finders": return String(workflow.auditFinders)
        case "audit_nit_cap": return String(workflow.auditNitCap)
        case "load_threshold": return workflow.loadThreshold.map { String(format: "%g", $0) } ?? ""
        // Left out: docs/lead; empty (or not a folder in the repository): local, in .vibeswitcher.
        case "records_dir": return workflow.recordsDir ?? ""
        default: return workflow.settings[key] ?? ""
        }
    }

    /// The guard rails' hashes, by key, of what the file says.
    public static func guardedHashes(_ workflow: LeadWorkflow) -> [String: String] {
        Dictionary(uniqueKeysWithValues: guardedKeys.map { ($0, hash(guardedValue($0, in: workflow))) })
    }

    /// What the lead last set the guard rails to, as hashes by key; nil when nothing is recorded yet.
    public func guardedSettings(root: String) throws -> [String: String]? {
        guard case .guarded(let hashes) = try call(.guarded(root: root)) else { throw Self.unexpected }
        return hashes
    }

    /// These settings are the lead's now (the app, or the repository's lead); the others stay as recorded.
    public func setGuardedSettings(_ hashes: [String: String], root: String) throws {
        _ = try call(.setGuarded(root: root, hashes: hashes))
    }

    /// The guard rails in `workflow` that aren't what the lead last set: each key, and what the file says now (as
    /// written; a line left out, as it reads). One
    /// with nothing recorded yet (a lead that never set it, a vault that began empty, a key guarded since) is
    /// recorded as it is.
    public func changedSettings(_ workflow: LeadWorkflow, root: String) throws -> [(key: String, value: String)] {
        let now = Self.guardedHashes(workflow)
        let recorded = try guardedSettings(root: root) ?? [:]
        let unrecorded = now.filter { recorded[$0.key] == nil }
        if !unrecorded.isEmpty { try setGuardedSettings(unrecorded, root: root) }
        return Self.guardedKeys.filter { recorded[$0] != nil && recorded[$0] != now[$0] }.map { ($0, workflow.settings[$0] ?? Self.guardedValue($0, in: workflow)) }
    }
}
