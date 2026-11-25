import Foundation

extension LeadToolset {
    /// What a task's audit is kept off under the floor that keeps audits off the workers' model, and the line that
    /// says so (`WorkerLaunch.excluded`): the floor's worker_model when the user set one, else `projectDefault` (Claude
    /// Code's default, as `LeadRuntime.workerModel` reads it), and the families the vault recorded for the task's (and
    /// its team members') launches. The record only ever adds.
    func workersBasis(_ task: LeadTask?, projectDefault: String?, workflow: LeadWorkflow) -> (workers: [String?], text: String) {
        let launched = task.flatMap { vault.launchedFamilies(root: root, task: $0.slug) }
        return WorkerLaunch.excluded(floorModel: workflow.floor?.workerModel, projectDefault: projectDefault, launched: launched)
    }
}
