import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `vibeswitcher new-project` (the parity table's New Project… row, the app's sheet through `ProjectCreation`): the
/// folder named for the project, a git repository with its first commit, nothing left behind on a refusal, and its lead
/// asked for after (the lead's own refusals and code). Run on a `ScratchNode`.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(10)))
struct NewProjectTests {
    private let scratch = Scratch()

    /// A node whose home's git has an identity (the first commit needs one, as on the user's machine).
    private func node() async throws -> ScratchNode {
        let node = try await ScratchNode(scratch)
        try "[user]\n\tname = Test\n\temail = test@example.invalid\n".write(to: node.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        return node
    }

    @Test func aProjectIsMadeWithItsFirstCommitAndAFolderThereIsRefused() async throws {
        let node = try await node()
        defer { node.stop() }
        let location = node.root.appendingPathComponent("projects/deeper").path
        let made = try await node.run(["new-project", "My App", "--in", location, "--no-lead"])
        let folder = location + "/my-app"
        #expect(made.status == 0 && made.output.contains("made: ") && made.output.contains("my-app"), "\(made.output)\(made.errors)")
        #expect(Git.run(["log", "--format=%s"], in: folder).output == ProjectCreation.commitMessage)
        #expect(Git.run(["ls-files"], in: folder).output.split(separator: "\n").sorted() == [".gitignore", "README.md"])
        #expect((try? String(contentsOfFile: folder + "/README.md", encoding: .utf8)) == "# My App\n")

        let again = try await node.run(["new-project", "My App", "--in", location, "--no-lead"])
        #expect(again.status == 77 && again.errors.contains("There's already a folder named “my-app”"), "\(again.output)\(again.errors)")
        let hidden = try await node.run(["new-project", "x", "--folder", ".hidden", "--in", location, "--no-lead"])
        #expect(hidden.status == 77 && !FileManager.default.fileExists(atPath: location + "/.hidden"), "\(hidden.errors)")
        let usage = try await node.run(["new-project", "x", "--goal", "g", "--no-lead"])
        #expect(usage.status == 64, "\(usage.errors)")
    }

    /// With its lead: its start asked for after, in the user's voice (the lead's own code, its goal shown), and started.
    @Test func itsLeadStartsAfterInTheUsersVoice() async throws {
        let node = try await node()
        defer { node.stop() }
        let location = node.root.appendingPathComponent("projects").path
        let ran = try await node.runOnTerminal(["new-project", "Acme", "--in", location, "--goal", "plan the work"])
        let folder = location + "/acme"
        #expect(Git.run(["rev-parse", "--verify", "HEAD"], in: folder).ok, "\(ran.output)")
        #expect(ran.status == 0 && ran.output.contains("This starts the project lead for \(folder)") && ran.output.contains("Its goal: plan the work")
                && ran.output.contains("the lead started"), "\(ran.output)")
        #expect(try node.sessions().contains { $0.isLive && $0.label == "Lead · acme" && $0.cwd == folder }, "\(node.said)")
    }
}
