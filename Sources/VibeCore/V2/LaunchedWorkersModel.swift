import Foundation

extension LeadToolset {
    /// What a task's audit is kept off under the floor that keeps audits off the workers' model, and the line that
    /// says so (`WorkerLaunch.excluded`): `projectDefault` (Claude Code's default, as `LeadRuntime.workerModel` reads
    /// it), the lead's model (as it starts now, and as the board noted it; with `leadExcluded`), and the families the vault recorded for the
    /// task's launches. Only ever more than before: nothing here takes a model off.
    func workersBasis(_ task: LeadTask?, projectDefault: String?, workflow: LeadWorkflow) -> (workers: [String?], text: String) {
        let launched = task.flatMap { vault.launchedFamilies(root: root, task: $0.slug) }
        // The lead's model: only with `leadExcluded` (a decision pending: with lead_model fable, the default, it keeps
        // every audit off Fable).
        let lead = Self.leadExcluded
            ? [LeadLaunch.leadRun(workflow, defaultModel: projectDefault, fableHeldBack: fableFallback() != nil).model ?? projectDefault, store.load().leadModel] : []
        return WorkerLaunch.excluded(projectDefault: projectDefault, lead: lead, launched: launched)
    }

    /// Whether the lead's model is kept off audits too (the W0 review's list). Off until decided.
    static let leadExcluded = false
}
