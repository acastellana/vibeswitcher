import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

struct SocketSchedulingTests {
    @Test func aPipelinedClientYieldsAndThenResumesItsBufferedFrames() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        UnixSocket.configure(fds[0])
        UnixSocket.configure(fds[1])
        defer { Darwin.close(fds[1]) }
        let queue = DispatchQueue(label: "security.socket-budget")
        let client = ClientConnection(fd: fds[0], queue: queue)
        defer { queue.sync { client.close() } }
        var handled = 0, handledWhenOtherWorkRan = 0
        let finished = DispatchSemaphore(value: 0)
        client.onFrame = { _, _ in
            handled += 1
            if handled == 1 { queue.async { handledWhenOtherWorkRan = handled } }
            if handled == 128 { finished.signal() }
        }
        let frame = HostFrame.encode(.control, Data("{}".utf8))
        var pipeline = Data()
        for _ in 0..<128 { pipeline.append(frame) }
        let written = pipeline.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        #expect(written == pipeline.count)
        client.start()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        let result = queue.sync { (handled, handledWhenOtherWorkRan) }
        #expect(result.0 == 128)
        #expect(result.1 > 0 && result.1 <= 64)
    }
}
