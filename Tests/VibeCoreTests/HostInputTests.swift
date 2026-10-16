import Foundation
import Testing
@testable import VibeCore

struct HostInputTests {
    @Test func keysMapToTerminalBytes() {
        #expect(HostInput.bytes(forKey: "enter") == [13])
        #expect(HostInput.bytes(forKey: "escape") == [27])
        #expect(HostInput.bytes(forKey: "up") == [27, 91, 65])
        #expect(HostInput.bytes(forKey: "down") == [27, 91, 66])
        #expect(HostInput.bytes(forKey: "right") == [27, 91, 67])
        #expect(HostInput.bytes(forKey: "left") == [27, 91, 68])
        #expect(HostInput.bytes(forKey: "tab") == [9])
        #expect(HostInput.bytes(forKey: "backspace") == [127])
        #expect(HostInput.bytes(forKey: "interrupt") == [3])
        #expect(HostInput.bytes(forKey: "nope") == nil)
    }

    @Test func textThenEnterSeparately() {
        #expect(HostInput.writes(text: "hi", submit: true, key: nil)
                == [.init(bytes: Array("hi".utf8), delay: 0), .init(bytes: [13], delay: 0.06)])
        #expect(HostInput.writes(text: "hi", submit: false, key: nil) == [.init(bytes: Array("hi".utf8), delay: 0)])
        #expect(HostInput.writes(text: nil, submit: true, key: "escape") == [.init(bytes: [27], delay: 0)])
        #expect(HostInput.writes(text: "x", submit: false, key: "down")
                == [.init(bytes: [120], delay: 0), .init(bytes: [27, 91, 66], delay: 0.06)])
        #expect(HostInput.writes(text: nil, submit: false, key: "bogus").isEmpty)
    }
}
