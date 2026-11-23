import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibePlatform

#if os(Linux)
/// The host's path watch watches its paths' folder; one that couldn't be watched (the system had no watch left) is
/// checked at each housekeeping meanwhile, said once, and asked for again at each housekeeping (the hub review's F4).
@Suite struct HostPathWatchFolderTests {
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's watches (the hub)"))
    func aFolderWatchThatCouldntBeMadeIsAskedForAgainAtHousekeeping() async throws {
        let socket = scratchSocketPath()
        let folder = URL(fileURLWithPath: socket).deletingLastPathComponent().path
        #if os(Linux)
        InotifyHub.shared.failNextWatch(of: folder)
        #endif
        let host = try TestHost(watchesItsPath: true, socket: socket)
        let server = host.server
        let watch = try #require(server.queue.sync { server.pathWatch })
        #expect(server.queue.sync { watch.folders[folder] } == nil, "the forced failure didn't happen")
        // What each housekeeping does first.
        server.queue.sync { watch.watchFolders() }
        #expect(server.queue.sync { watch.folders[folder] } != nil)
        // And the watch made then is heard: a foreign socket renamed over the path is replaced with no check asked.
        let beside = socket + "-f"
        let foreign = try UnixSocket.listen(path: beside)
        defer { Sys.close(foreign); unlink(beside) }
        let foreignFile = try #require(HostPathWatch.identity(atPath: beside))
        try #require(rename(beside, socket) == 0, "errno \(errno)")
        #expect(await eventually { HostPathWatch.identity(atPath: socket).map { $0 != foreignFile } == true }, "the change wasn't heard")
        _ = try TestClient(host)
    }
}
#endif
