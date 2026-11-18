import Foundation
import Testing
@testable import VibeCore

/// Which hosts a confined session's proxy lets it reach (the session sandbox plan's SB9). Pure: names and addresses
/// in, a decision out; nothing resolves or connects.
struct EgressRulesTests {
    typealias Address = EgressRules.Address
    static let public1 = Address("203.0.113.7")!
    static let public6 = Address("2606:4700::1111")!

    static func refused(_ decision: EgressRules.Decision) -> Bool {
        if case .refuse = decision { return true } else { return false }
    }

    @Test func aNameOffTheListIsRefused() {
        let rules = EgressRules(hosts: ["api.anthropic.com", "registry.npmjs.org"])
        #expect(rules.decision(host: "api.anthropic.com", port: 443, resolved: [Self.public1]) == .allow([Self.public1]))
        #expect(rules.decision(host: "API.Anthropic.com.", port: 443, resolved: [Self.public1]) == .allow([Self.public1]))
        for host in ["evil.com", "anthropic.com", "api.anthropic.com.evil.com", "xapi.anthropic.com", "api-anthropic.com", "", ".",
                     "api.anthropic.com..", "api..anthropic.com", "api.anthropic.com/x", "api.anthropic.com@evil.test", "user@anthropic.test",
                     "api.anthropic.com\0.evil.com", "api.anthropic.com\r\nhost: x", "ápi.anthropic.com", "api_anthropic.com"] {
            #expect(rules.admits(host: host, port: 443) != nil, "\(host)")
            #expect(Self.refused(rules.decision(host: host, port: 443, resolved: [Self.public1])), "\(host)")
        }
        #expect(EgressRules(hosts: []).admits(host: "api.anthropic.com", port: 443) != nil)
        // An entry that isn't one matches nothing.
        for entry in ["https://api.anthropic.com", "api.anthropic.com/", "*", "*.*", "*.com:0", "api.anthropic.com:x", "1.2.3.4", "[::1]"] {
            #expect(EgressRules(hosts: [entry]).admits(host: "api.anthropic.com", port: 443) != nil, "\(entry)")
        }
    }

    @Test func loopbackTheTailnetLinkLocalAndMetadataAreRefusedWhateverTheListSays() {
        let names = ["localhost", "a.localhost", "printer.local", "metadata.google.internal", "x.internal", "box.tail1234.ts.net",
                     "router.home.arpa", "1.0.0.127.in-addr.arpa", "nas.lan"]
        let rules = EgressRules(hosts: names + names.map { "*." + $0 } + ["listed.example"], privateHosts: names + ["listed.example"])
        for name in names {
            #expect(rules.admits(host: name, port: 443) != nil, "\(name)")
        }
        for text in ["127.0.0.1", "127.255.255.254", "0.0.0.0", "100.100.100.100", "100.64.0.1", "169.254.169.254", "169.254.1.1",
                     "224.0.0.251", "255.255.255.255", "240.0.0.1", "192.0.0.170",
                     "::1", "::", "fe80::1", "fec0::1", "ff02::fb", "fd7a:115c:a1e0::1", "fd00:ec2::254",
                     "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::", "2001:0:4136:e378::1"] {
            let address = Address(text)!
            let decision = rules.decision(host: "listed.example", port: 443, resolved: [Self.public1, address])
            #expect(Self.refused(decision), "\(text)")
        }
        #expect(rules.decision(host: "listed.example", port: 443, resolved: [Self.public1, Self.public6]) == .allow([Self.public1, Self.public6]))
    }

    @Test func everyEmbeddedIPv4FormIsJudgedByItsIPv4() {
        let rules = EgressRules(hosts: ["listed.example"])
        // loopback, metadata and a private address, in each form that carries an IPv4 address.
        let forms: [(String, [String])] = [
            ("::ffff:", ["::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:10.0.0.1"]),
            ("SIIT ::ffff:0:0:0/96", ["::ffff:0:127.0.0.1", "::ffff:0:169.254.169.254", "::ffff:0:10.0.0.1"]),
            ("64:ff9b::/96", ["64:ff9b::127.0.0.1", "64:ff9b::169.254.169.254", "64:ff9b::10.0.0.1"]),
            // Local-use NAT64: refused whole, whatever the address decodes to under any one prefix length, a public
            // one under the /48 layout (203.0.113.7) and under the /96 one (198.51.100.1) included.
            ("64:ff9b:1::/48", ["64:ff9b:1:7f00:0:100::", "64:ff9b:1:a9fe:a9:fe00::", "64:ff9b:1:a00:0:100::",
                                "64:ff9b:1:cb00:71:700::", "64:ff9b:1::c633:6401", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff"]),
            ("2002::/16", ["2002:7f00:1::", "2002:a9fe:a9fe::", "2002:a00:1::"]),
        ]
        for (form, texts) in forms {
            for text in texts {
                let address = try! #require(Address(text), "\(text)")
                #expect(Self.refused(rules.decision(host: "listed.example", port: 443, resolved: [address])), "\(form): \(text)")
            }
        }
        #expect(EgressRules.carried(Address("64:ff9b:1:a9fe:a9:fe00::")!) == nil, "local-use NAT64 is never decoded")
        #expect(EgressRules.carried(Address("::ffff:0:169.254.169.254")!) == Address("169.254.169.254"))
        // The well-known 64:ff9b::/96 maps one to one: a public IPv4 address in it stays public, and is that address.
        #expect(EgressRules.carried(Address("64:ff9b::203.0.113.7")!) == Address("203.0.113.7"))
        #expect(rules.decision(host: "listed.example", port: 443, resolved: [Address("64:ff9b::203.0.113.7")!]) == .allow([Address("64:ff9b::203.0.113.7")!]))
        #expect(rules.decision(host: "listed.example", port: 443, resolved: [Address("::ffff:0:203.0.113.7")!]) == .allow([Address("::ffff:0:203.0.113.7")!]))
    }

    @Test func ipv6OutsideGlobalUnicastIsRefusedUnlessPrivateAndGiven() {
        let rules = EgressRules(hosts: ["listed.example"], privateHosts: ["listed.example"])
        for text in ["100::1", "1::1", "4000::1", "8000::1", "e000::1", "fe00::1", "64:ff9b:2::1", "3fff::1".replacingOccurrences(of: "3fff", with: "1fff")] {
            #expect(Self.refused(rules.decision(host: "listed.example", port: 443, resolved: [Address(text)!])), "\(text)")
        }
        #expect(rules.decision(host: "listed.example", port: 443, resolved: [Address("2606:4700::1111")!]) == .allow([Address("2606:4700::1111")!]))
        #expect(rules.decision(host: "listed.example", port: 443, resolved: [Address("fd12::1")!]) == .allow([Address("fd12::1")!]))
        #expect(Self.refused(EgressRules(hosts: ["listed.example"]).decision(host: "listed.example", port: 443, resolved: [Address("fd12::1")!])))
    }

    @Test func aListedNameThatResolvesToARefusedAddressIsRefused() {
        let rules = EgressRules(hosts: ["api.anthropic.com"])
        #expect(Self.refused(rules.decision(host: "api.anthropic.com", port: 443, resolved: [Address("127.0.0.1")!])))
        // One bad address among good ones refuses the whole: a resolver an attacker answers can mix them.
        #expect(Self.refused(rules.decision(host: "api.anthropic.com", port: 443, resolved: [Self.public1, Address("10.0.0.5")!])))
        // Nothing resolved: refused, nothing to connect to.
        #expect(Self.refused(rules.decision(host: "api.anthropic.com", port: 443, resolved: [])))
    }

    @Test func privateRangesNeedTheProjectsWord() {
        let lan = ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.10", "fd12:3456::1", "fc00::1", "::ffff:192.168.1.10"]
        let without = EgressRules(hosts: ["build.corp.example", "*.corp.example"])
        let with = EgressRules(hosts: ["build.corp.example", "*.corp.example"], privateHosts: ["build.corp.example", "*.corp.example"])
        for text in lan {
            let address = Address(text)!
            #expect(Self.refused(without.decision(host: "build.corp.example", port: 443, resolved: [address])), "\(text)")
            #expect(with.decision(host: "build.corp.example", port: 443, resolved: [address]) == .allow([address]), "\(text)")
            #expect(with.decision(host: "a.corp.example", port: 443, resolved: [address]) == .allow([address]), "\(text)")
        }
        // The word is for the names it gives, not for every name on the list.
        let narrow = EgressRules(hosts: ["build.corp.example", "other.example"], privateHosts: ["build.corp.example"])
        #expect(Self.refused(narrow.decision(host: "other.example", port: 443, resolved: [Address("10.0.0.1")!])))
        // Just outside the ranges: public.
        for text in ["172.15.255.255", "172.32.0.1", "11.0.0.1", "192.169.0.1", "100.63.255.255", "100.128.0.1"] {
            #expect(without.decision(host: "build.corp.example", port: 443, resolved: [Address(text)!]) == .allow([Address(text)!]), "\(text)")
        }
    }

    @Test func anAddressLiteralIsRefused() {
        let rules = EgressRules(hosts: ["*.example", "1.2.3.4", "[2606:4700::1111]", "2130706433"])
        for host in ["1.2.3.4", "203.0.113.7", "[2606:4700::1111]", "2606:4700::1111", "[::1]", "::1", "2130706433", "0x7f000001",
                     "127.1", "0177.0.0.1", "0x7f.0.0.1", "1.2.3.4.", "a.0x10", "a.123"] {
            #expect(rules.admits(host: host, port: 443) != nil, "\(host)")
            #expect(Self.refused(rules.decision(host: host, port: 443, resolved: [Self.public1])), "\(host)")
        }
        // A name with digits isn't one.
        #expect(rules.admits(host: "s3.example", port: 443) == nil)
        #expect(rules.admits(host: "123abc.example", port: 443) == nil)
    }

    @Test func onlyPort443UnlessTheEntryNamesAnother() {
        let rules = EgressRules(hosts: ["api.anthropic.com", "mirror.example:8443", "plain.example:80", "*.cdn.example:8080"])
        #expect(rules.admits(host: "api.anthropic.com", port: 443) == nil)
        for port: UInt16 in [80, 22, 25, 8443, 444, 1, 65535] {
            #expect(rules.admits(host: "api.anthropic.com", port: port) != nil, "\(port)")
        }
        #expect(rules.admits(host: "mirror.example", port: 8443) == nil)
        #expect(rules.admits(host: "mirror.example", port: 443) != nil)
        #expect(rules.admits(host: "plain.example", port: 80) == nil)
        #expect(rules.admits(host: "plain.example", port: 443) != nil)
        #expect(rules.admits(host: "a.cdn.example", port: 8080) == nil)
        #expect(rules.admits(host: "a.cdn.example", port: 443) != nil)
    }

    @Test func aWildcardCoversSubdomainsAndNotTheNameItself() {
        let rules = EgressRules(hosts: ["*.githubusercontent.com"])
        #expect(rules.admits(host: "raw.githubusercontent.com", port: 443) == nil)
        #expect(rules.admits(host: "a.b.githubusercontent.com", port: 443) == nil)
        #expect(rules.admits(host: "githubusercontent.com", port: 443) != nil)
        #expect(rules.admits(host: "evilgithubusercontent.com", port: 443) != nil)
        #expect(rules.admits(host: "githubusercontent.com.evil.com", port: 443) != nil)
    }

    @Test func theDefaultListIsDataAndNamesOnlyTheAgentsHosts() {
        let claude = EgressRules.defaultHosts[.claude] ?? []
        #expect(claude.contains("api.anthropic.com"))
        for entry in claude {
            #expect(EgressRules(hosts: [entry]).admits(host: entry, port: 443) == nil, "\(entry) isn't an entry that matches itself")
            #expect(!entry.hasPrefix("*."), "a default entry names one host: \(entry)")
        }
    }

    @Test func addressesReadAsTheyAreWritten() {
        #expect(Address("1.2.3.4")?.bytes == [1, 2, 3, 4])
        #expect(Address("::ffff:1.2.3.4")?.bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4])
        #expect(Address("fd7a:115c:a1e0::1")?.description == "fd7a:115c:a1e0:0:0:0:0:1")
        for bad in ["1.2.3", "1.2.3.256", "01.2.3.4.5", "1:2:3:4:5:6:7:8:9", "1::2::3", "g::1", "", "::ffff:1.2.3.999"] {
            #expect(Address(bad) == nil, "\(bad)")
        }
    }
}
