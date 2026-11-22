import Foundation
import Testing
@testable import VibeNode

/// The envelope's one check (`NodeWire.unwrap`), the same on the Unix socket and a WebSocket.
@Suite struct EnvelopeTests {
    @Test func whatIsntARequestIsRefusedWithItsCode() {
        for (text, code) in [("[1,2]", "not-object"), ("nonsense", "not-object"), (#"{"v":1,"kind":"status"}"#, "not-request")] {
            guard case .refused(let reply, let refused, _) = NodeWire.unwrap(Data(text.utf8)) else {
                Issue.record("\(text) was taken"); continue
            }
            #expect(reply == nil && refused == code, "\(text)")
        }
        guard case .refused(let reply, let code, _) = NodeWire.unwrap(Data(#"{"v":99,"id":"3","kind":"status"}"#.utf8)) else {
            Issue.record("a newer version was taken")
            return
        }
        #expect(code == "version" && reply?.re == "3" && reply?.error?.code == "version")
        #expect(NodeWire.unwrap(Data(#"{"v":1,"id":"4","kind":"status"}"#.utf8)) == .request(NodeWire.Request(id: "4", kind: "status")))
    }

    @Test func anUnknownKindEndsTheConnectionOnlyWhenItMustBeUnderstood() {
        let plain = NodeWire.unknownKind(NodeWire.Request(id: "1", kind: "no.such"))
        #expect(plain.reply.error?.code == "unknown-kind" && plain.bye == nil)
        let must = NodeWire.unknownKind(NodeWire.Request(id: "2", kind: "no.such", must: true))
        #expect(must.reply.re == "2" && must.bye?.code == "must")
    }
}
