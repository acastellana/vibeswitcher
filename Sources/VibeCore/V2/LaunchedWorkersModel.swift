import Foundation

extension LeadToolset {
    /// What a task's audit is kept off under the floor that keeps audits off the workers' model, and the line that
    /// says so (`WorkerLaunch.excluded`): the floor's worker_model when the user set one, else `projectDefault` (Claude
    /// Code's default, as `LeadRuntime.workerModel` reads it), and the families the vault recorded for the task's (and
    /// its team members') launches. The record only ever adds.
    ///
    /// Under that floor the vault's own exclusion set for the task (`LeadVault.auditExclusions`: what a verifier's bind
    /// is judged by) is added, so the model chosen here is never one the bind refuses; this side's own view (the project
    /// command's model, Opus in Fable's place while Fable is held back) stays in, as it only adds.
    func workersBasis(_ task: LeadTask?, projectDefault: String?, workflow: LeadWorkflow) -> (workers: [String?], text: String) {
        let launched = task.flatMap { vault.launchedFamilies(root: root, task: $0.slug) }
        var basis = WorkerLaunch.excluded(floorModel: workflow.floor?.workerModel, projectDefault: projectDefault, launched: launched)
        if workflow.floor?.verifierDifferent == true, let set = vault.auditExclusions(root: root, task: task?.slug ?? "") {
            basis.workers = set.map { Optional($0) } + basis.workers
        }
        return basis
    }
}
