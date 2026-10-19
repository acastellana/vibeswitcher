import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Home's New Project… sheet: what it derives and offers, that it makes the project off the main thread, and the
/// projects folder setting. Git runs with a scratch HOME and config, never the user's.
@MainActor
struct NewProjectTests {
    let temp = Scratch()
    let presets = LaunchPresets.builtIns().global

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
        let model = NewProjectModel(location: "~/dev", presets: presets)
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

    @Test func itOffersClaudeAndSaysWhatsWrong() {
        let model = NewProjectModel(location: "/nonexistent-location-\(UUID().uuidString)", presets: presets)
        #expect(model.preset?.name == "Claude")
        #expect(model.problem == nil)  // nothing typed yet, nothing tried
        model.create { _, _ in Issue.record("made with no name") }
        #expect(model.problem == "Give the project a name.")
        model.name = "a/b"
        #expect(model.problem == "A folder name can't contain “/” or “:”.")
        model.name = "Fine"
        #expect(model.problem == nil)
        #expect(model.locationNote?.hasSuffix("isn't there yet: it will be made.") == true)
        model.then = .lead
        model.initializeGit = false
        #expect(model.problem == NewProjectModel.leadNeedsGit)
        model.initializeGit = true
        model.goal = "  "
        #expect(model.next == .lead(goal: nil))
        model.goal = " add a login page "
        #expect(model.next == .lead(goal: "add a login page"))
        model.then = .session
        #expect(model.next == .session(presets[0]))
        model.then = .nothing
        #expect(model.next == .nothing)
    }

    func scratchGit() throws -> ProjectCreation.GitRunner {
        let home = temp.url("newproject-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".gitconfig")
        try "[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n".write(to: config, atomically: true, encoding: .utf8)
        let env = Git.environment.merging(["HOME": home.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
                                           "XDG_CONFIG_HOME": home.path]) { $1 }
        return { args, directory in
            #expect(!Thread.isMainThread, "git ran on the main thread")
            return Shell.run(executable: "/usr/bin/git", args: args, in: directory, env: env)
        }
    }

    @Test func createMakesItOffTheMainThreadAndHandsBackTheFolder() async throws {
        let dev = temp.url("newproject-dev").path
        let model = NewProjectModel(location: dev, presets: presets)
        model.git = try scratchGit()
        model.name = "Hello World"
        model.then = .lead
        model.goal = "ship it"
        var made: (String, ProjectCreation.Next)?
        model.create { made = ($0, $1) }
        #expect(model.creating)
        #expect(await until { made != nil })
        #expect(made?.0 == URL(fileURLWithPath: dev).appendingPathComponent("hello-world").path)
        #expect(made?.1 == .lead(goal: "ship it"))
        #expect(!model.creating)
        #expect(model.failure == nil)
        let log = Git.run(["log", "--oneline"], in: made?.0 ?? "/nonexistent")
        #expect(log.output.split(separator: "\n").count == 1)
    }

    @Test func aGitFailureIsOneAlertAndNoFolder() async throws {
        let dev = temp.url("newproject-dev").path
        let model = NewProjectModel(location: dev, presets: presets)
        model.git = { args, _ in Git.Result(status: 128, output: "", error: "fatal: not today") }
        model.name = "Broken"
        model.create { _, _ in Issue.record("reported as made") }
        #expect(await until { !model.creating })
        #expect(model.failure == "git init failed: fatal: not today")
        #expect(ProjectCreation.existing(dev + "/broken") == .none)
        #expect(ProjectCreation.existing(dev) == .none)
    }
}
