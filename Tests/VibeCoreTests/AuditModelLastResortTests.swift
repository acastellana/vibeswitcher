import Testing
@testable import VibeCore

/// An audit under a different-model floor whose workers', task's and launched models together take every model of the
/// fallback order (fable, opus, sonnet) goes to Mythos, the last resort, never back to one of those the floor excludes.
struct AuditModelLastResortTests {
    @Test func fableOpusAndSonnetAllExcludedGoesToMythos() {
        var workflow = LeadWorkflow()
        workflow.floor = LeadReviewFloor()
        #expect(workflow.floor?.verifierDifferent == true)
        let audit = workflow.auditModel(workerModel: "opus", taskModel: "fable", launchedModel: "sonnet")
        #expect(audit == "mythos")
        #expect(!LeadReviewFloor.sameModel(audit, "opus") && !LeadReviewFloor.sameModel(audit, "fable") && !LeadReviewFloor.sameModel(audit, "sonnet"))
        // A sensitive audit whose security_audit_model is one of theirs takes the same search.
        workflow.securityAuditModel = "fable"
        #expect(workflow.auditModel(workerModel: "opus", taskModel: "fable", launchedModel: "sonnet", security: true) == "mythos")
        // Fable held back, opus and sonnet the workers' and the task's: the search past Fable ends on Mythos too.
        workflow.securityAuditModel = LeadWorkflow.defaultSecurityAuditModel
        workflow.verifierModel = "fable"
        #expect(workflow.auditModel(workerModel: "opus", taskModel: "sonnet", heldBack: "fable") == "mythos")
        // With a model of the order free, the order is kept.
        #expect(workflow.auditModel(workerModel: "opus", taskModel: "fable") == "sonnet")
    }
}
