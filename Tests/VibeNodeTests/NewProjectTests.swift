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

    /// `lead FOLDER --init` (the app's offer for a folder a lead can't start in yet): what it would commit shown before
    /// the code, a secret left out, nothing made when the code isn't typed; typed, git init and the first commit, then
    /// the lead. An empty repository's own folder gets the first commit alone.
    @Test func leadInitMakesTheRepositoryAndFirstCommitAfterTheCode() async throws {
        let node = try await node()
        defer { node.stop() }
        let folder = node.root.appendingPathComponent("projects/notes").path
        try FileManager.default.createDirectory(atPath: folder + "/src", withIntermediateDirectories: true)
        try "hello\n".write(toFile: folder + "/src/a.txt", atomically: true, encoding: .utf8)
        try "KEY=1\n".write(toFile: folder + "/.env", atomically: true, encoding: .utf8)
        // Its own .gitignore (one VibeSwitcher would write ignores .env, so nothing would be left out).
        try "*.log\n".write(toFile: folder + "/.gitignore", atomically: true, encoding: .utf8)

        let declined = try await node.runOnTerminal(["lead", folder, "--init"], answer: { _ in "nope" })
        #expect(declined.status == 77 && declined.output.contains("First, git init in \(folder), and a first commit of its 2 files")
                && declined.output.contains("Left out, as they look like secrets: .env"), "\(declined.output)")
        #expect(!FileManager.default.fileExists(atPath: folder + "/.git"), "\(declined.output)")

        let ran = try await node.runOnTerminal(["lead", folder, "--init", "--goal", "tidy the notes"])
        #expect(ran.status == 0 && ran.output.contains("made: a git repository with a first commit") && ran.output.contains("the lead started"), "\(ran.output)")
        #expect(Git.run(["ls-files"], in: folder).output.split(separator: "\n").sorted() == [".gitignore", "src/a.txt"])
        #expect(try node.sessions().contains { $0.isLive && $0.label == "Lead · notes" && $0.cwd == folder }, "\(node.said)")

        let empty = node.root.appendingPathComponent("projects/empty").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try "# e\n".write(toFile: empty + "/README.md", atomically: true, encoding: .utf8)
        #expect(Git.run(["init", "--quiet"], in: empty).ok)
        let first = try await node.runOnTerminal(["lead", empty, "--init"])
        #expect(first.output.contains("First, in \(empty) (a repository with no commits yet), a first commit of its 2 files")
                && first.output.contains("made: a first commit in \(empty)") && first.status == 0, "\(first.output)")
        #expect(Git.run(["ls-files"], in: empty).output.split(separator: "\n").sorted() == [".gitignore", "README.md"])
    }

    /// What the app doesn't offer stays refused, before any code and with nothing made: the home folder, a folder
    /// inside a repository with no commits (a stray git init above it). Without `--init` the lead's refusal names it.
    @Test func leadInitRefusesWhatTheAppDoesntOfferAndTheRefusalNamesIt() async throws {
        let node = try await node()
        defer { node.stop() }
        let home = try await node.run(["lead", node.home.path, "--init"])
        #expect(home.status == 77 && home.errors.contains("a project's lead goes in a folder of its own"), "\(home.errors)")
        #expect(!FileManager.default.fileExists(atPath: node.home.path + "/.git"))

        let parent = node.root.appendingPathComponent("projects/stray").path
        try FileManager.default.createDirectory(atPath: parent + "/inner", withIntermediateDirectories: true)
        #expect(Git.run(["init", "--quiet"], in: parent).ok)
        let inner = try await node.run(["lead", parent + "/inner", "--init"])
        #expect(inner.status == 77 && inner.errors.contains("is in the repository \(parent), which has no commits"), "\(inner.errors)")
        #expect(!FileManager.default.fileExists(atPath: parent + "/inner/.git") && !Git.run(["rev-parse", "--verify", "HEAD"], in: parent).ok)

        let plain = node.root.appendingPathComponent("projects/plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let refused = try await node.runOnTerminal(["lead", plain])
        #expect(refused.status == 77 && refused.output.contains("`vibeswitcher lead FOLDER --init` makes them"), "\(refused.output)")
    }
}
