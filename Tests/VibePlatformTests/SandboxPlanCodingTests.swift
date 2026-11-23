import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Sandbox`'s types, on both systems: a plan travels as JSON (in sealed memory, SB3), so every kind of mount
/// and network comes back as it went; and the Mac has no box.
struct SandboxPlanCodingTests {
    static let everyKind = Platform.Sandbox.Plan(
        mounts: [
            .init("/usr", .readOnly(source: "/usr")),
            .init("/work", .readWrite(source: "/scratch/work")),
            .init("/cache", .overlay(lower: "/scratch/cache", upper: "/scratch/layer/upper", work: "/scratch/layer/work")),
            .init("/var/tmp", .empty(mode: 0o1777)),
            .init("/proc", .proc),
            .init("/dev/pts", .devpts),
            .init("/sys", .sysfs),
            .init("/dev/null", .device("null")),
            .init("/bin", .link(to: "usr/bin")),
            .init("/home/u/.gitconfig", .file(contents: Data("[gc]\n\tauto = 0\n".utf8), mode: 0o444)),
            .init("/proc/sys/fs/binfmt_misc", .binfmt),
        ],
        network: .proxied(port: 3128), hostname: "box", directory: "/work",
        environment: ["PATH=/usr/bin:/bin", "HOME=/home/u"], door: "/run/vibeswitcher/door", terminal: .foreground, nesting: true)

    @Test func aPlanSurvivesItsCoding() throws {
        for plan in [Self.everyKind,
                     Platform.Sandbox.Plan(mounts: [], network: .none, hostname: "b", directory: "/", environment: [], door: nil,
                                           terminal: .none, nesting: false),
                     Platform.Sandbox.Plan(mounts: [], network: .shared, hostname: "b", directory: "/", environment: [], door: nil,
                                           terminal: .none, nesting: false)] {
            let coded = try JSONEncoder().encode(plan)
            #expect(try JSONDecoder().decode(Platform.Sandbox.Plan.self, from: coded) == plan)
        }
    }

    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's"))
    func theMacHasNoSandbox() {
        let facts = Platform.Sandbox.probe()
        #expect(facts == Platform.Sandbox.Facts(userNamespaces: false, overlay: false, landlockABI: 0, vsock: false, why: "macOS"))
        let failure = Platform.Sandbox.enter(Self.everyKind, doorLine: nil, proxyOut: nil, program: ["/usr/bin/true"])
        #expect(failure == Platform.Sandbox.Failure(step: "unavailable", code: ENOTSUP))
    }
}
