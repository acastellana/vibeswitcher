import Foundation
import Testing
@testable import VibeCore

struct SocketBoundsTests {
    @Test func anUnconsumedFloodIsRejectedBeforeReturningAnyFrame() throws {
        var decoder = HostFrameDecoder()
        let frame = HostFrame.encode(.control, Data("{}".utf8))
        // Valid small frames must not accumulate forever while the reader postpones parsing.
        let flood = Data(repeating: 0, count: 2 * HostFrame.maxPayload)
        decoder.append(frame + flood)
        #expect(throws: HostFrameDecoder.Failure.self) { try decoder.next() }
    }

    @Test func maximumFramesStillDecodeAcrossReadBoundaries() throws {
        var decoder = HostFrameDecoder()
        let body = Data(repeating: 65, count: HostFrame.maxPayload)
        let frame = HostFrame.encode(.control, body)
        for start in stride(from: 0, to: frame.count, by: 65_536) {
            decoder.append(frame.subdata(in: start..<min(start + 65_536, frame.count)))
            if start + 65_536 < frame.count { #expect(try decoder.next() == nil) }
        }
        #expect(try decoder.next()?.payload == body)
    }
}
