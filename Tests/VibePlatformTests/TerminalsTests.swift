import Foundation
import Testing
import VibePlatform

/// A terminal's name, from its path and from its device number: one word with no slash, the same from both.
struct TerminalsTests {
    @Test func aMacTerminalIsNamedAsItIs() {
        #expect(Platform.Terminals.name(devicePath: "/dev/ttys009") == "ttys009")
    }

    @Test func aLinuxPseudoTerminalIsNamedWithoutItsSlash() {
        #expect(Platform.Terminals.name(devicePath: "/dev/pts/3") == "ttypts3")
        #expect(Platform.Terminals.name(devicePath: "/dev/pts/1048575") == "ttypts1048575")
    }

    @Test func theProcesssOwnTerminalIsNamedTty() {
        #expect(Platform.Terminals.name(devicePath: "/dev/tty") == "tty")
    }

    /// Only a path inside a folder of /dev is changed: every other name stays what the system calls it, as the Mac's
    /// were before there was a rule (the path without "/dev/").
    @Test func otherNamesStayAsTheSystemGivesThem() {
        #expect(Platform.Terminals.name(devicePath: "/dev/console") == "console")
        #expect(Platform.Terminals.name(devicePath: "/dev/ttyS0") == "ttyS0")
        #expect(Platform.Terminals.name(devicePath: "/dev/tty1") == "tty1")
        // Not a path under /dev: as given.
        #expect(Platform.Terminals.name(devicePath: "ttys012") == "ttys012")
        #expect(Platform.Terminals.name(devicePath: "") == "")
        // In a folder whose name starts "tty" already: no second one.
        #expect(Platform.Terminals.name(devicePath: "/dev/ttyfolder/4") == "ttyfolder4")
        #expect(Platform.Terminals.name(devicePath: "/dev/a/b/c") == "ttyabc")
    }

    /// A pseudo-terminal opened here has one name, from its path and from its device number (what a process's record
    /// holds of its terminal), and the name is fit for a file's: "tty", then letters and digits, 16 at most (the
    /// steer inbox's rule).
    @Test func aTerminalsPathAndNumberGiveOneName() throws {
        var buffer = [CChar](repeating: 0, count: 128)
        // Its file is there from the moment it is opened; it is never opened here, so needn't be unlocked.
        #if os(Linux)
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        try #require(vibe_ptsname_r(primary, &buffer, buffer.count) == 0)
        #else
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        try #require(grantpt(primary) == 0 && unlockpt(primary) == 0)
        try #require(ptsname_r(primary, &buffer, buffer.count) == 0)
        #endif
        let path = String(cString: buffer)
        var node = stat()
        try #require(stat(path, &node) == 0)

        let name = Platform.Terminals.name(devicePath: path)
        #expect(Platform.Terminals.name(device: node.st_rdev) == name)
        #expect(name.hasPrefix("tty") && name.count <= 16 && name.allSatisfy { $0.isLetter || $0.isNumber }, "\(name)")
        #if os(Linux)
        #expect(name == "ttypts" + path.dropFirst("/dev/pts/".count))
        #endif
    }

    #if os(Linux)
    /// No terminal is 0. A device that isn't a pseudo-terminal is named as the kernel names its file under /dev,
    /// where the kernel says (/sys/dev/char); one it doesn't know has no name.
    @Test func otherDevicesAreNamedByTheKernelOrNotAtAll() {
        #expect(Platform.Terminals.name(device: 0) == nil)
        // The console, 5:1, where this system shows it (a container may not).
        if FileManager.default.fileExists(atPath: "/sys/dev/char/5:1/uevent") {
            #expect(Platform.Terminals.name(device: 5 << 8 | 1) == "console")
        }
        // /dev/tty itself, 5:0.
        if FileManager.default.fileExists(atPath: "/sys/dev/char/5:0/uevent") {
            #expect(Platform.Terminals.name(device: 5 << 8) == "tty")
        }
        #expect(!FileManager.default.fileExists(atPath: "/sys/dev/char/4000:77"))
        #expect(Platform.Terminals.name(device: 4000 << 8 | 77) == nil)
    }
    #else
    @Test func noTerminalHasNoName() {
        #expect(Platform.Terminals.name(device: -1) == nil)
    }
    #endif
}
