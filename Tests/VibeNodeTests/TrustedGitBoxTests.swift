import Foundation
import Testing
@testable import VibeCore

/// VibeSwitcher's git inside a box (`Platform.Tools.trustedGit`'s `box`): root's files read there as the overflow uid
/// and the box's own `/` as the run's uid, so with today's rule alone no git was found and every Swift test of a branch
/// run that runs git failed ("Couldn't start git: it should be at /nonexistent/vibeswitcher/git").
///
/// The probe: this test binary, started inside a real box with `probeVariable` set, prints what `Platform.Tools`
/// finds there and exits, before any test of its own (`answerProbe`). The variable only picks the probe; the rule
/// reads the kernel's `uid_map`.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && RealBox.unavailable == nil,
                "needs a box: \(RealBox.unavailable ?? "the Mac has none")"), .timeLimit(.minutes(5)))
struct TrustedGitBoxTests {
    private let scratch = Scratch()

    static let probeVariable = "VIBE_TRUSTED_GIT_PROBE"

    @Test func insideABoxTheSystemsGitIsFoundAndOneTheBoxCouldWriteIsnt() async throws {
        let folder = SandboxPolicy.resolved(try scratch.shortFolder("tg").path)
        // A git in a folder the box's uid owns and can write: never trusted, inside as outside.
        try FileManager.default.createDirectory(atPath: folder + "/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: folder + "/bin/git", atomically: true, encoding: .utf8)
        chmod(folder + "/bin", 0o755)
        chmod(folder + "/bin/git", 0o755)
        let binary = try #require(Bundle.main.executablePath)
        let plan = RealBox.plan(folder, door: false, network: .none, environment: ["\(Self.probeVariable)=\(folder)/bin"])
        let output = scratch.url("probe.out")
        let pid = try RealBox.launch(plan, [binary], in: URL(fileURLWithPath: folder), output: output)
        let raw = await offPool { collected(pid, by: MacTime.real.awake() + 120) }
        let said = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        #expect(raw.map { $0 & 0x7f == 0 && ($0 >> 8) & 0xff == 0 } == true, "\(said)")
        // Inside: root's /usr/bin/git, which reads as the overflow uid's under the box's own `/`.
        #expect(said.contains("box=yes\n"), "\(said)")
        #expect(said.contains("system=/usr/bin/git\n"), "\(said)")
        #expect(said.contains("writable=none\n"), "\(said)")
    }
}

/// The probe's answer, when this binary was started with `TrustedGitBoxTests.probeVariable` (inside a box, by
/// `insideABoxTheSystemsGitIsFoundAndOneTheBoxCouldWriteIsnt`): whether the kernel says this is a box, the git found on
/// the system's folders, and the one found in the folder the variable names. Written with libc, then the process ends.
private func answerProbe() {
    guard let named = getenv(TrustedGitBoxTests.probeVariable) else { return }
    let box = Platform.Tools.boxOwners
    // `lstat`, as the rule reads a path.
    func status(_ path: String) -> Platform.Tools.FileStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_uid, info.st_mode, info.st_mode & S_IFMT == S_IFREG)
    }
    // What VibeSwitcher's own git is here (the rule with the kernel's word), and what the rule finds in the named folder.
    let system = Platform.Tools.git
    let writable = Platform.Tools.trustedGit(path: String(cString: named), status: status, box: box)
    let text = "box=\(box == nil ? "no" : "yes")\nsystem=\(system)\nwritable=\(writable ?? "none")\n"
    _ = text.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    _exit(0)
}

// After the shim's launcher mode (00200), which is what starts this binary inside the box.
@_used @_section(".init_array.00300")
private let answerWhenAsked: @convention(c) () -> Void = { answerProbe() }
