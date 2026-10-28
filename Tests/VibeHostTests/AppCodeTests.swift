import Darwin
import Foundation
import Testing
@testable import VibeHost

/// The host tells the app's code by the cdhash of the slice its process runs (`AppCode`), read with `proc_pidinfo`'s
/// architecture flavor, declared in the code since not every SDK's headers have it.
struct AppCodeTests {
    @Test func theArchitectureOfAProcessIsTheOneItRuns() throws {
        let architecture = try #require(AppCode.architecture(of: getpid()))
        #if arch(arm64)
        #expect(architecture.cpuType == CPU_TYPE_ARM64)
        #elseif arch(x86_64)
        #expect(architecture.cpuType == CPU_TYPE_X86_64)
        #endif
        let runner = try #require(HostServer.executable(of: getpid()))
        let slice = try #require(AppCode.cdhash(atPath: runner, architecture: architecture))
        #expect(slice == AppCode.cdhash(atPath: runner))
        #expect(AppCode.architecture(of: -1) == nil)
    }

    @Test func thisProcessRunsItsOwnCodeAndNotAnothers() throws {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        #expect(result == KERN_SUCCESS)
        let runner = try #require(HostServer.executable(of: getpid()))
        #expect(AppCode.runs(token, executable: runner))
        #expect(!AppCode.runs(token, executable: hostLauncher))
    }
}
