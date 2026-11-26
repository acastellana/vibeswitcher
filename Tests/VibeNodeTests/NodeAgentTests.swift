import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeNode

/// The Mac's LaunchAgent as data (`NodeAgent`, the node on the Mac's step 5), on both systems: its property list from
/// the unit's inputs, read back exactly, refused for what the unit refuses; the `launchctl` lines; what `launchctl
/// print` says of the job. Nothing runs `launchctl` or writes the agent's file.
struct NodeAgentTests {
    static let commit = String(repeating: "a", count: 40)
    static let inputs = NodeUnit.Inputs(prefix: "/Users/u/.vibeswitcher/v2/node/builds", commit: commit, home: "/Users/u",
                                        swiftBin: "/Users/u/.swiftly/bin", nodeBin: "/Users/u/.nvm/versions/node/v22.16.0/bin")
    static let root = "/Users/u/.vibeswitcher/v2/node"

    @Test func thePlistIsTheUnitsInputsAndReadsBackExactly() throws {
        let data = try NodeAgent.plist(Self.inputs, nodeRoot: Self.root, atLogin: false).get()
        let read = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(read["Label"] as? String == "dev.vibeswitcher.node")
        #expect(read["ProgramArguments"] as? [String] == NodeUnit.execStart(prefix: Self.inputs.prefix, commit: Self.commit))
        #expect((read["ProgramArguments"] as? [String])?.contains("--node") == true)
        #expect(read["KeepAlive"] as? Bool == false && read["RunAtLoad"] as? Bool == false)
        #expect(read["LimitLoadToSessionType"] as? String == "Aqua" && read["ProcessType"] as? String == "Interactive")
        #expect(read["StandardErrorPath"] as? String == Self.root + "/node.log")
        // The one variable that acts: the Swift runtime reads it at load, before the checked start's reset (which rebuilds
        // HOME and PATH itself).
        #expect(read["EnvironmentVariables"] as? [String: String] == ["SWIFT_BACKTRACE": "enable=no"])
        #expect(NodeAgent.check(data, inputs: Self.inputs, nodeRoot: Self.root, atLogin: false) == nil)
        // At login: RunAtLoad, and the file for one isn't the other's.
        let atLogin = try NodeAgent.plist(Self.inputs, nodeRoot: Self.root, atLogin: true).get()
        #expect(NodeAgent.check(atLogin, inputs: Self.inputs, nodeRoot: Self.root, atLogin: false)?.contains("RunAtLoad") == true)
        #expect(NodeAgent.path(home: "/Users/u") == "/Users/u/Library/LaunchAgents/dev.vibeswitcher.node.plist")
    }

    /// What a process of the user's could change in the file (it is the user's to write; the Mac seal watches it):
    /// anything added or changed is found.
    @Test func aChangedFileIsFound() throws {
        let data = try NodeAgent.plist(Self.inputs, nodeRoot: Self.root, atLogin: false).get()
        let values = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        func check(_ change: (inout [String: Any]) -> Void) throws -> String? {
            var copy = values
            change(&copy)
            let written = try PropertyListSerialization.data(fromPropertyList: copy, format: .xml, options: 0)
            return NodeAgent.check(written, inputs: Self.inputs, nodeRoot: Self.root, atLogin: false)
        }
        #expect(try check { $0["KeepAlive"] = true }?.contains("KeepAlive") == true)
        #expect(try check { $0["EnvironmentVariables"] = ["HOME": "/Users/u", "PATH": "/Users/u/evil:/usr/bin", "SWIFT_BACKTRACE": "enable=no"] } != nil)
        #expect(try check { var env = $0["EnvironmentVariables"] as? [String: String] ?? [:]; env["DYLD_INSERT_LIBRARIES"] = "/Users/u/evil.dylib"; $0["EnvironmentVariables"] = env } != nil)
        #expect(try check { $0["ProgramArguments"] = ["/Users/u/evil"] }?.contains("ProgramArguments") == true)
        #expect(try check { $0["WatchPaths"] = ["/Users/u"] }?.contains("WatchPaths") == true)
        #expect(try check { $0["Label"] = nil }?.contains("no Label") == true)
        #expect(NodeAgent.check(Data("not a plist".utf8), inputs: Self.inputs, nodeRoot: Self.root, atLogin: false) == "the agent's file isn't a property list")
    }

    @Test func whatTheUnitRefusesTheAgentRefuses() {
        var relative = Self.inputs
        relative.prefix = "builds"
        #expect((try? NodeAgent.plist(relative, nodeRoot: Self.root, atLogin: false).get()) == nil)
        var short = Self.inputs
        short.commit = "abc"
        #expect((try? NodeAgent.plist(short, nodeRoot: Self.root, atLogin: false).get()) == nil)
        #expect((try? NodeAgent.plist(Self.inputs, nodeRoot: "/Users/u/../x", atLogin: false).get()) == nil)
    }

    @Test func launchctlsLinesAndWhatPrintSays() {
        #expect(NodeAgent.bootstrap(launchctl: "/bin/launchctl", uid: 501, home: "/Users/u")
                == ["/bin/launchctl", "bootstrap", "gui/501", "/Users/u/Library/LaunchAgents/dev.vibeswitcher.node.plist"])
        #expect(NodeAgent.bootout(launchctl: "/bin/launchctl", uid: 501) == ["/bin/launchctl", "bootout", "gui/501/dev.vibeswitcher.node"])
        #expect(NodeAgent.print(launchctl: "/bin/launchctl", uid: 501) == ["/bin/launchctl", "print", "gui/501/dev.vibeswitcher.node"])
        // The shape of `launchctl print`'s output (as documented by launchctl(1)'s examples; a real Mac's is the check).
        let output = """
            gui/501/dev.vibeswitcher.node = {
            \tactive count = 1
            \tpath = /Users/u/Library/LaunchAgents/dev.vibeswitcher.node.plist
            \tstate = running
            \tprogram = /Users/u/.vibeswitcher/v2/node/builds/\(Self.commit)/bin/vibeswitcher-host
            \tenvironment = {
            \t\tpid = 1
            \t\tprogram = /Users/u/evil
            \t}
            \tpid = 4242
            }
            """
        #expect(NodeAgent.printed(output) == .init(pid: 4242, program: "/Users/u/.vibeswitcher/v2/node/builds/\(Self.commit)/bin/vibeswitcher-host",
                                                   state: "running", path: "/Users/u/Library/LaunchAgents/dev.vibeswitcher.node.plist"))
        #expect(NodeAgent.printed("gui/501/dev.vibeswitcher.node = {\n\tstate = not running\n}").pid == nil)
    }

    /// What `vibeswitcher agent-plist` prints for the Mac's install: the build's agent, its root the node's, no start at
    /// login; refused for a commit the unit can't hold.
    @Test func theInstallsAgentIsTheInstalledBuilds() throws {
        let data = try NodeAgent.installed(prefix: Self.inputs.prefix, commit: Self.commit, home: "/Users/u").get()
        let root = NodeFolders.nodeRoot(accountHome: "/Users/u")
        #expect(NodeAgent.check(data, inputs: Self.inputs, nodeRoot: root, atLogin: false) == nil)
        if case .success = NodeAgent.installed(prefix: Self.inputs.prefix, commit: "current", home: "/Users/u") {
            Issue.record("made for a commit that isn't one")
        }
    }

    /// The plist's program and arguments are exactly a checked node's command line: the host of the build, then what
    /// `HostImages.CheckedCommandLine` parses into that build's folder and server and renders back the same (the design's
    /// "The LaunchAgent", its table). The real plist runs only as data here: a scratch host isn't a checked node.
    @Test func theProgramArgumentsAreACheckedNodesCommandLine() throws {
        let job = try NodeAgent.Job.node(prefix: Self.inputs.prefix, commit: Self.commit, home: "/Users/u", dataRoot: Self.root, atLogin: false).get()
        let folder = Self.inputs.prefix + "/" + Self.commit
        #expect(job.programArguments.first == folder + "/bin/vibeswitcher-host")
        let line = try HostImages.CheckedCommandLine.parse(job.programArguments).get()
        #expect(line == HostImages.CheckedCommandLine(nodeRoot: folder, server: folder + "/bin/vibeswitcher-server", keeper: nil))
        #expect(Array(job.programArguments.dropFirst()) == line.rendered)
        #expect(job.label == NodeAgent.label && job.environment == ["SWIFT_BACKTRACE": "enable=no"] && job.standardErrorPath == Self.root + "/node.log")
    }

    /// What `launchctl print` says of a job, as this Mac measured it (the design's "The LaunchAgent", measured first):
    /// before a run, running, and after its process was killed or exited.
    @Test func printsStateRunsAndLastExit() {
        let before = "gui/501/x = {\n\tstate = not running\n\truns = 0\n\tlast exit code = (never exited)\n\tpath = /p/x.plist\n}"
        #expect(NodeAgent.printed(before) == .init(pid: nil, program: nil, state: "not running", runs: 0, lastExit: nil, path: "/p/x.plist"))
        let running = "gui/501/x = {\n\tstate = running\n\tprogram = /bin/sh\n\truns = 1\n\tpid = 52708\n\t\tstate = active\n}"
        #expect(NodeAgent.printed(running) == .init(pid: 52708, program: "/bin/sh", state: "running", runs: 1))
        let killed = "gui/501/x = {\n\tstate = not running\n\truns = 1\n\tlast terminating signal = Killed: 9\n}"
        #expect(NodeAgent.printed(killed).lastExit == "signal Killed: 9")
        #expect(NodeAgent.printed("x = {\n\tlast exit code = 1\n}").lastExit == "exit code 1")
    }
}