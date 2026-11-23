import Foundation
import Testing
import VibeNode

/// What the command line reads of the machine (`NodeFacts`, the engine plan's E1; the security architecture
/// document's S1 and S11), on readers a test gives. The Mac runs these.
struct NodeFactsTests {
    private let scratch = Scratch()

    /// WSL's own entries as a machine with systemd registers them, interop off.
    static let off = ["WSLInterop": "disabled\ninterpreter /init\nflags: PF\n", "WSLInterop-late": "disabled\ninterpreter /init\nflags: P\n",
                      "status": "enabled\n"]

    static func readers(binfmt: [String: String]? = NodeFactsTests.off, mounts: String = "", files: [String: String] = [:],
                        folders: [String: [String]] = [:],
                        manager: Result<String, NodeFacts.Failure> = .success("HOME=/home/u\nPATH=/usr/bin:/bin\n")) -> NodeFacts.Readers {
        NodeFacts.Readers(binfmt: { binfmt }, mounts: { mounts }, file: { files[$0] }, folder: { folders[$0] }, managerEnvironment: { manager })
    }

    @Test func statusSaysPlainModeAndInterop() {
        let off = NodeFacts.read(Self.readers())
        #expect(off.interop == false)
        #expect(off.lines.first?.hasPrefix("plain mode: no sandbox") == true, "\(off.lines)")
        #expect(off.lines.contains("interop: off"))
        let on = NodeFacts.read(Self.readers(binfmt: ["WSLInterop": "enabled\ninterpreter /init\nflags: F\n", "status": "enabled\n"]))
        #expect(on.interop == true)
        #expect(on.lines.first?.hasPrefix("plain mode") == true)
        #expect(on.lines.contains { $0.hasPrefix("interop: on") && $0.contains("void") }, "\(on.lines)")
        // No WSLInterop registered at all (or no binfmt_misc): off. Something else in it: can't be told.
        #expect(NodeFacts.read(Self.readers(binfmt: nil)).interop == false)
        #expect(NodeFacts.read(Self.readers(binfmt: ["status": "enabled\n"])).interop == false)
        #expect(NodeFacts.read(Self.readers(binfmt: ["WSLInterop": "garbage"])).interop == nil)
        // `start` refuses while interop is on, unless told; and while it can't be told.
        #expect(StartCheck.refusal(facts: on, interopIsOn: false)?.contains("--interop-is-on") == true)
        #expect(StartCheck.refusal(facts: on, interopIsOn: true) == nil)
        #expect(StartCheck.refusal(facts: off, interopIsOn: false) == nil)
        #expect(StartCheck.refusal(facts: NodeFacts.read(Self.readers(binfmt: ["WSLInterop": "garbage"])), interopIsOn: false) != nil)
        // The start line `stop` and `status` say: the flag while `start` would refuse without it.
        #expect(StartCheck.startLine(facts: on) == "vibeswitcher start --interop-is-on")
        #expect(StartCheck.startLine(facts: off) == "vibeswitcher start")
        #expect(StartCheck.startLine(facts: NodeFacts.read(Self.readers(binfmt: ["WSLInterop": "garbage"]))) == "vibeswitcher start --interop-is-on")
    }

    @Test func interopIsOnWhileAnyOfItsEntriesIsEnabled() throws {
        let late = "enabled\ninterpreter /init\nflags: P\n"
        // WSL with systemd registers `WSLInterop-late` beside `WSLInterop`, and either runs Windows programs: turning
        // the first off (`echo 0 >`, or `-1` to remove it) leaves the second on.
        for binfmt in [["WSLInterop": "disabled\ninterpreter /init\n", "WSLInterop-late": late, "status": "enabled\n"],
                       ["WSLInterop-late": late, "status": "enabled\n"],
                       ["WSLInterop": "disabled\n", "windows": "enabled\ninterpreter /init\nflags: P\nmagic 4d5a\n", "status": "enabled\n"]] {
            let facts = NodeFacts.read(Self.readers(binfmt: binfmt))
            #expect(facts.interop == true, "\(binfmt)")
            #expect(facts.lines.contains { $0.hasPrefix("interop: on") }, "\(facts.lines)")
            #expect(StartCheck.refusal(facts: facts, interopIsOn: false) != nil)
        }
        // Every one off, or binfmt_misc itself off: off. One that can't be read: can't be told.
        #expect(NodeFacts.read(Self.readers()).interop == false)
        #expect(NodeFacts.read(Self.readers(binfmt: ["WSLInterop": late, "WSLInterop-late": late, "status": "disabled\n"])).interop == false)
        #expect(NodeFacts.read(Self.readers(binfmt: ["WSLInterop": "disabled\n", "WSLInterop-late": "", "status": "enabled\n"])).interop == nil)
        // Another program's entry isn't interop.
        #expect(NodeFacts.read(Self.readers(binfmt: ["python3.12": "enabled\ninterpreter /usr/bin/python3.12\n", "status": "enabled\n"])).interop == false)

        // The machine's reader takes every entry of the folder.
        let folder = scratch.url("binfmt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in ["WSLInterop": "disabled\ninterpreter /init\n", "WSLInterop-late": late, "status": "enabled\n"] {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let machine = NodeFacts.Readers.machine(binfmtFolder: folder.path, mountsFile: "/nonexistent/mounts", managerEnvironment: { .failure(.init("test")) })
        #expect(NodeFacts.read(machine).interop == true)
        #expect(NodeFacts.read(.machine(binfmtFolder: "/nonexistent/binfmt", mountsFile: "/nonexistent/mounts",
                                        managerEnvironment: { .failure(.init("test")) })).interop == false)
    }

    @Test func statusSaysWhenAutomountIsOnAndAKernelLineIsSet() {
        let mounts = """
            /dev/sdc / ext4 rw,relatime 0 0
            C:\\134 /mnt/c 9p rw,noatime,aname=drvfs 0 0
            D:\\134 /mnt/d drvfs rw 0 0
            none /mnt/wsl tmpfs rw 0 0
            tools /usr/lib/wsl/lib 9p ro 0 0
            """
        let facts = NodeFacts.read(Self.readers(mounts: mounts,
                                                files: ["/mnt/c/Users/me/.wslconfig": "[wsl2]\n# kernel=old\nmemory=8GB\n kernel = C:\\\\k\\\\bzImage\n",
                                                        "/mnt/d/Users/me/.wslconfig": "[wsl2]\n;kernel=x\nguiApplications=false\n"],
                                                folders: ["/mnt/c/Users": ["me", "Public"], "/mnt/d/Users": ["me"]]))
        #expect(facts.automounts == ["/mnt/c", "/mnt/d"])
        #expect(facts.kernelLines == ["/mnt/c/Users/me/.wslconfig"])
        #expect(facts.lines.contains { $0.hasPrefix("automount: on") && $0.contains("/mnt/c") && $0.contains("/mnt/d") }, "\(facts.lines)")
        #expect(facts.lines.contains { $0.hasPrefix("kernel= set in /mnt/c/Users/me/.wslconfig") }, "\(facts.lines)")
        let none = NodeFacts.read(Self.readers(mounts: "/dev/sdc / ext4 rw 0 0\n"))
        #expect(none.automounts.isEmpty && none.kernelLines.isEmpty)
        #expect(none.lines.contains("automount: off"))
        #expect(!none.lines.contains { $0.hasPrefix("kernel=") })
    }

    @Test func anExtraVariableInTheManagersEnvironmentIsNamed() {
        let shown = """
            HOME=/home/u
            LANG=C.UTF-8
            LC_TIME=en_GB.UTF-8
            PATH=/usr/local/bin:/usr/bin:/bin
            XDG_RUNTIME_DIR=/run/user/1000
            LD_PRELOAD=/home/u/.cache/x.so
            BASH_ENV=$'/srv/a\\nb'
            """
        let facts = NodeFacts.read(Self.readers(manager: .success(shown)))
        #expect(facts.manager == .extra(["BASH_ENV", "LD_PRELOAD"]))
        #expect(facts.lines.contains("the manager's environment holds more than expected: BASH_ENV, LD_PRELOAD"), "\(facts.lines)")
        #expect(NodeFacts.read(Self.readers()).lines.contains("the manager's environment: nothing beyond the expected"))
        let unknown = NodeFacts.read(Self.readers(manager: .failure(.init("scratch node: no journal, no manager"))))
        #expect(unknown.lines.contains("the manager's environment: not read (scratch node: no journal, no manager)"))
    }
}
