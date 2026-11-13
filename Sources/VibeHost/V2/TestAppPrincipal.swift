import Foundation
import VibeCore

/// A scratch host's stand-in for the app on Linux (the stage 2 plan's Task 5a): the test process that started it.
///
/// On Linux the app is the connections the host makes through an app connector (`AppConnector`), and a host started
/// as a process by a test has no server child yet to make them for. So a test starts it with one end of a
/// `SOCK_SEQPACKET` pair as a descriptor it inherits, `--test-app-connector N`, and its own pid, `--test-app-pid P`;
/// the host takes that end as an app connector whose requests it answers only from P (its token, read at once), and
/// the test reaches the host through the other end (`HostConnection.register(connector:for:)`). The connector is
/// carried across a handover (`HostHandover.State.testAppConnector`), so a test that acts as the app after one still
/// can.
///
/// Honoured only by a scratch host, on a lock of its own: the user's host refuses both flags, saying so in its log,
/// and takes nothing from them. Both are left out of what a build this host hands over to is started with. The Mac
/// has no connector: there the flags do nothing, and the app proves itself by its code (`AppProof`).
public enum TestAppPrincipal {
    public static let pidFlag = "--test-app-pid"
    public static let connectorFlag = "--test-app-connector"
    /// Both flags, each with its value, as `main`'s list of what a handover drops (true: it takes a value).
    public static let handoverFlags: [String: Bool] = [pidFlag: true, connectorFlag: true]

    /// After the server has started: the stand-in a handover carried (`restored`), else the one the flags in
    /// `arguments` name. `ownsLaunchers`: this is the user's host, which takes neither. A descriptor named at 0 to 2
    /// (the test's own stdin) is moved off it, and /dev/null put there in its place.
    public static func adopt(arguments: [String], restored: HostHandover.TestAppConnector?, ownsLaunchers: Bool, server: HostServer) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let named = value(after: connectorFlag).flatMap(Int32.init)
        let pid = value(after: pidFlag).flatMap(pid_t.init)
        guard restored != nil || named != nil || pid != nil else { return }
        func say(_ line: String) {
            server.note("host: " + line)
            FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
        }
        guard !ownsLaunchers else {
            return say("refused \(pidFlag) and \(connectorFlag): the user's host takes no test stand-in for the app")
        }
        guard !Platform.CodeIdentity.isAvailable else {
            return say("ignored \(pidFlag) and \(connectorFlag): this system has no app connector")
        }
        if let restored {
            guard server.adoptTestAppConnector(restored.fd, pid: restored.pid) else {
                return say("no test stand-in for the app: connector \(restored.fd) didn't survive the handover")
            }
            return say("test stand-in for the app: connector \(restored.fd) for pid \(restored.pid), carried over")
        }
        guard let named, named >= 0, let pid, pid > 0 else {
            return say("no test stand-in for the app: \(pidFlag) and \(connectorFlag) each need a number")
        }
        // Off 0 to 2, where a child of the host would find it (and the host's own stdin is then /dev/null).
        var fd = named
        if named <= 2 {
            fd = fcntl(named, F_DUPFD_CLOEXEC, 3)
            let null = open("/dev/null", O_RDWR | O_CLOEXEC)
            if null >= 0 {
                dup2(null, named)
                if null != named { Sys.close(null) }
            }
        }
        guard fd >= 0, server.adoptTestAppConnector(fd, pid: pid) else {
            return say("no test stand-in for the app: connector \(named) isn't open here, or this system has no connector")
        }
        say("test stand-in for the app: connector \(fd) for pid \(pid)")
    }
}
