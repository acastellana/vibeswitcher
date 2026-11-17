import Foundation
import Testing
@testable import VibeCore

/// The door's one line (the session sandbox plan's SB4): what a relay inside a box says, and what the porter outside
/// takes as said. Pure: no box, no process.
struct DoorProtocolTests {
    @Test func aHelloSurvivesItsCoding() throws {
        for mode in DoorProtocol.Mode.allCases {
            let hello = DoorProtocol.Hello(mode: mode, args: ["claude", "--root", "/a b/ü", "", "x\ty"])
            let line = try #require(DoorProtocol.line(hello))
            #expect(line.last == UInt8(ascii: "\n"))
            #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
            #expect(DoorProtocol.hello(Array(line.dropLast())) == .success(hello))
        }
        #expect(DoorProtocol.answer(DoorProtocol.exitLine(3).trimmingCharacters(in: .newlines)) == .exit(3))
        #expect(DoorProtocol.answer(DoorProtocol.refusedLine("no\nway").trimmingCharacters(in: .newlines)) == .refused("no way"))
    }

    @Test func anOversizedOrMalformedHelloIsRefused() {
        let long = DoorProtocol.Hello(mode: .mcp, args: [String(repeating: "x", count: DoorProtocol.maxHello)])
        #expect(DoorProtocol.line(long) == nil)
        let tooLong = Array("{\"v\":1,\"mode\":\"mcp\",\"args\":[\"\(String(repeating: "x", count: DoorProtocol.maxHello))\"]}".utf8)
        for refused in [tooLong,
                        Array("{\"v\":1,\"mode\":\"mcp\"}".utf8),
                        Array("{\"v\":2,\"mode\":\"mcp\",\"args\":[]}".utf8),
                        Array("{\"v\":1,\"mode\":\"shell\",\"args\":[]}".utf8),
                        Array("{\"v\":1,\"mode\":\"mcp\",\"args\":[]}\n{}".utf8),
                        Array("{\"v\":1,\"mode\":\"mcp\",\"args\":[]}".utf8) + [0],
                        Array("not json".utf8), [0xff, 0xfe], []] {
            guard case .failure = DoorProtocol.hello(refused) else {
                Issue.record("taken: \(String(decoding: refused.prefix(80), as: UTF8.self))")
                continue
            }
        }
        for unknown in ["exit", "exit -1", "exit 256", "exit 1 2", "refusedx", "ok"] {
            #expect(DoorProtocol.answer(unknown) == nil, "\(unknown)")
        }
    }
}
