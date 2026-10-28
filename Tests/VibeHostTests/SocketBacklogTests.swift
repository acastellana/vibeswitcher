import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A burst of callers connecting at once: the host's backlog takes them all, and a refused connect is retried.
@Suite struct SocketBacklogTests {
    @Test func aBurstOf64ConnectsIsNotRefused() throws {
        let host = try TestHost()
        // On the host's queue, which accepts nothing until this returns: every connect waits in the backlog.
        let results = host.server.queue.sync { () -> [Result<Int32, Error>] in
            let lock = NSLock()
            var results: [Result<Int32, Error>] = []
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let result = Result { try UnixSocket.connect(path: host.socket) }
                lock.lock(); results.append(result); lock.unlock()
            }
            return results
        }
        let fds = results.compactMap { try? $0.get() }
        fds.forEach { Darwin.close($0) }
        #expect(fds.count == 64, "refused: \(results.compactMap { if case .failure(let e) = $0 { return "\(e)" } else { return nil } })")
    }
}
