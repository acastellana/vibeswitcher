import Foundation
import Testing
@testable import VibeHost

/// The soft limit a handover carries (`HostImages.carriedValue`): taken only by an image a handover started, from the
/// floor to the hard limit; anything else refused, saying why.
struct CarriedLimitTests {
    @Test func onlyAHandoversValueInBoundsIsTaken() {
        #expect(HostImages.carriedValue(nil, handedOver: true, hard: 4096) == nil)
        #expect(HostImages.carriedValue("2048", handedOver: true, hard: 4096) == .success(2048))
        #expect(HostImages.carriedValue("1024", handedOver: true, hard: nil) == .success(1024))
        #expect(HostImages.carriedValue("2048", handedOver: false, hard: 4096) == .failure(.init("a fresh start takes none (only an image a handover started)")))
        #expect(HostImages.carriedValue("0", handedOver: true, hard: 4096) == .failure(.init("0 is under 1024")))
        #expect(HostImages.carriedValue("9000", handedOver: true, hard: 4096) == .failure(.init("9000 is over the hard limit, 4096")))
        #expect(HostImages.carriedValue("-1", handedOver: true, hard: 4096) == .failure(.init("-1 isn't a number")))
    }
}
