import Foundation
import Testing
@testable import VibeCore

/// Running lead tool calls share the gate; a scheduled rotation alone needs it exclusively.
struct LeadRotationToolGateTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    @Test func anActiveToolDoesNotRefuseAnotherToolAsARotation() throws {
        let root = temp.url("rotation-project").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let runtime = FakeRuntime()
        let tools = try lead(root, runtime)
        let active = try #require(FileLock.attempt(LeadRotation.gate(root), shared: true))
        defer { active.release() }
        for name in ["audit", "merge"] {
            // A missing task is refused normally, after taking the tool gate; the active call isn't a rotation.
            let result = tools.call(name, ["task": "missing"])
            #expect(result.isError)
            #expect(!result.text.contains("scheduled lead rotation"), "\(result.text)")
        }
        #expect(runtime.spawned.isEmpty)
        #expect(FileLock.attempt(LeadRotation.gate(root)) == nil)
    }
}
