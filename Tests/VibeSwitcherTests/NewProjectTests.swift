import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Home's New Project… sheet: what it derives, that it makes the project (always with git and a first commit) off the
/// main thread and hands back the first goal, and the projects folder setting. Git runs with a scratch HOME and config,
/// never the user's.
@MainActor
struct NewProjectTests {
    let temp = Scratch()

    private func withSuite(_ body: (UserDefaults, URL) throws -> Void) throws {
        let name = "dev.vibeswitcher.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let folder = temp.url("newproject-prefs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, folder.appendingPathComponent("presets.json"))
    }

    @Test func theProjectsFolderIsTildeDevUntilSetAndIsKept() throws {
        try withSuite { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            #expect(preferences.projectsFolder == "~/dev")
            #expect(preferences.projectsFolderPath == NSHomeDirectory() + "/dev")
            preferences.projectsFolder = "~/code/new"
            #expect(Preferences(defaults: defaults, presetsFile: presets).projectsFolder == "~/code/new")
            preferences.projectsFolder = "  "
            #expect(preferences.projectsFolderPath == NSHomeDirectory() + "/dev")
        }
    }

    @Test func madeProjectsAreRememberedNewestFirstUpTo20() throws {
        try withSuite { defaults, presets in
            let preferences = Preferences(defaults: defaults, presetsFile: presets)
            for index in 0..<25 { preferences.noteCreatedProject("/p/\(index)", at: Date(timeIntervalSince1970: Double(index))) }
            let kept = Preferences(defaults: defaults, presetsFile: presets).createdProjects
            #expect(kept.count == 20)
            #expect(kept["/p/24"] != nil && kept["/p/4"] == nil)
        }
    }

    @Test func theFolderNameFollowsTheNameUntilEdited() {
        let model = NewProjectModel(location: "~/dev")
        model.name = "  My Big App "
        #expect(model.folderName == "my-big-app")
        model.editFolderName("big")
        model.name = "My Bigger App"
        #expect(model.folderName == "big")
        // Edited back to what it would be, it follows again.
        model.editFolderName("my-bigger-app")
        model.name = "Other"
        #expect(model.folderName == "other")
    }

    @Test func itSaysWhatsWrongAndTrimsTheGoal() {
        let model = NewProjectModel(location: "/nonexistent-location-\(UUID().uuidString)")
        #expect(model.problem == nil)  // nothing typed yet, nothing tried
        model.create { _, _ in Issue.record("made with no name") }
        #expect(model.problem == "Give the project a name.")
        model.name = "a/b"
        #expect(model.problem == "A folder name can't contain “/” or “:”.")
        model.name = "Fine"
        #expect(model.problem == nil)
        #expect(model.locationNote?.hasSuffix("isn't there yet: it will be made.") == true)
        #expect(model.firstGoal == nil)
        model.goal = "  "
        #expect(model.firstGoal == nil)
        model.goal = " add a login page "
        #expect(model.firstGoal == "add a login page")
    }

    /// git with a scratch HOME and config; `defaultBranch` is its init.defaultBranch, when set.
    func scratchGit(defaultBranch: String? = nil) throws -> ProjectCreation.GitRunner {
        let home = temp.url("newproject-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".gitconfig")
        let initSection = defaultBranch.map { "[init]\n\tdefaultBranch = \($0)\n" } ?? ""
        try ("[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n" + initSection)
            .write(to: config, atomically: true, encoding: .utf8)
        let env = Git.environment.merging(["HOME": home.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
                                           "XDG_CONFIG_HOME": home.path]) { $1 }
        return { args, directory in
            #expect(!Thread.isMainThread, "git ran on the main thread")
            return Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: env)
        }
    }

    /// Makes the project with `git` and returns its folder and the goal `create` handed back.
    private func make(_ name: String, goal: String, in dev: String,
                      git: @escaping ProjectCreation.GitRunner) async throws -> (folder: String, goal: String?) {
        let model = NewProjectModel(location: dev)
        model.git = git
        model.name = name
        model.goal = goal
        var made: (folder: String, goal: String?)?
        model.create { made = ($0, $1) }
        #expect(model.creating)
        #expect(await until { made != nil })
        #expect(!model.creating)
        #expect(model.failure == nil)
        return try #require(made)
    }

    /// README.md, .gitignore and one commit with both, on `branch`.
    private func expectRepository(_ folder: String, on branch: String) {
        #expect(ProjectCreation.existing(folder + "/README.md") == .file)
        #expect(ProjectCreation.existing(folder + "/.gitignore") == .file)
        let log = Git.run(["log", "--oneline"], in: folder)
        #expect(log.output.split(separator: "\n").count == 1)
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines) == branch)
        #expect(Git.run(["status", "--porcelain"], in: folder).output.isEmpty)
    }

    @Test func createMakesItOffTheMainThreadWithGitAndHandsBackTheGoal() async throws {
        let dev = temp.url("newproject-dev").path
        let made = try await make("Hello World", goal: "  ship it ", in: dev, git: try scratchGit(defaultBranch: "trunk"))
        #expect(made.folder == URL(fileURLWithPath: dev).appendingPathComponent("hello-world").path)
        #expect(made.goal == "ship it")
        expectRepository(made.folder, on: "trunk")
    }

    @Test func withNoGoalOrDefaultBranchItsMainAndNoGoal() async throws {
        let dev = temp.url("newproject-dev").path
        let made = try await make("Plain", goal: " ", in: dev, git: try scratchGit())
        #expect(made.goal == nil)
        expectRepository(made.folder, on: "main")
    }

    @Test func aGitFailureIsOneAlertAndNoFolder() async throws {
        let dev = temp.url("newproject-dev").path
        let model = NewProjectModel(location: dev)
        model.git = { args, _ in Git.Result(status: 128, output: "", error: "fatal: not today") }
        model.name = "Broken"
        model.create { _, _ in Issue.record("reported as made") }
        #expect(await until { !model.creating })
        #expect(model.failure == "git init failed: fatal: not today")
        #expect(ProjectCreation.existing(dev + "/broken") == .none)
        #expect(ProjectCreation.existing(dev) == .none)
    }
}
