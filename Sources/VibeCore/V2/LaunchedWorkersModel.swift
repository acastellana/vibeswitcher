import Foundation

extension LeadToolset {
    /// What a task's audit is kept off under the floor that keeps audits off the workers' model, and why: the models
    /// its worker sessions were launched on, as the host recorded each launch in the vault (`WorkerLaunch`), or with no
    /// such record, `projectDefault` (Claude Code's default, as `LeadRuntime.workerModel` reads it). Never the board's.
    func workersBasis(_ task: LeadTask, projectDefault: String?) -> (workers: [String?], text: String) {
        WorkerLaunch.basis(vault.launches(root: root, task: task.slug), projectDefault: projectDefault)
    }
}
