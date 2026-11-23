import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// External plugins' parsers fuzzed (the architecture review's row 19, with `ParserFuzzTests`): the protocol's line
/// reader and the answer check (`PluginProcess.answer`, `nesting`), every answer's shape (`ExternalPlugin`: hello, card,
/// outcome, page, settings, file; the filed envelope), the program checks (`PluginProgram`: ELF, mutated real small
/// ones and synthetic ones, and `#!`), the manifest (`PluginManifest.read`) and the page's own reads (`PluginPage`: its
/// spec, its cookie, and a live page given mutated requests). Never a trap or a hang, bounded in time and memory, a
/// refusal for everything malformed, the same thing back for everything sound. A fixed seed, a few seconds;
/// `VIBESWITCHER_FUZZ_ROUNDS` and `VIBESWITCHER_FUZZ_SEED` as `ParserFuzzTests`'.
@Suite(.serialized) struct PluginFuzzTests {
    typealias Random = ParserFuzzTests.Random
    static var rounds: Int { ParserFuzzTests.rounds }
    static var seed: UInt64 { ParserFuzzTests.seed ^ 0x9106 }

    // MARK: The protocol's lines and answers

    /// The plugin's reader is the wire's (`NodeWire.Lines(maxLine:)`, in place of a loop of its own that had both
    /// quadratic patterns): a line dripped a byte at a time and many short lines at once grow in cost linearly (n to 4n:
    /// about 4 times, never the quadratic 16), and a line past 256 KiB ends the program.
    @Test func thePluginsLinesAreReadInLinearTime() {
        let drip = ParserFuzzTests.growth(32 * 1_024) { length in
            var reader = NodeWire.Lines(maxLine: PluginProcess.lineBytesAtMost)
            var read: [Data] = []
            for _ in 0..<length { read += reader.append(Data([0x61])) }
            read += reader.append(Data([0x0A]))
            precondition(read == [Data(repeating: 0x61, count: length)] && !reader.tooLong)
        }
        #expect(drip < 9, "a line 4 times as long cost \(drip) times as much")
        let many = ParserFuzzTests.growth(32 * 1_024) { count in
            var reader = NodeWire.Lines(maxLine: PluginProcess.lineBytesAtMost)
            precondition(reader.append(Data(Array(repeating: Array("{}\n".utf8), count: count).joined())).count == count)
        }
        #expect(many < 9, "4 times the lines cost \(many) times as much")
        var over = NodeWire.Lines(maxLine: PluginProcess.lineBytesAtMost)
        _ = over.append(Data(repeating: 0x61, count: PluginProcess.lineBytesAtMost + 1))
        #expect(over.tooLong, "a line past 256 KiB ends the program")
    }

    /// Random JSON: `nesting` never counts less than the parse's depth (it bounds the parser), whatever the strings
    /// hold (brackets, quotes and backslashes escaped); random bytes never trap it.
    @Test func nestingNeverUndercounts() {
        var random = Random(state: Self.seed)
        func value(_ depth: Int) -> (text: String, depth: Int) {
            switch random.int(0...(depth > 40 ? 2 : 5)) {
            case 0: return ("\"" + random.pick(["a", "[", "{", "\\\"", "\\\\", "]}", "\\u005b"]) + "\"", 0)
            case 1: return (String(random.int(-9...9)), 0)
            case 2: return (random.pick(["true", "null"]), 0)
            case 3, 4:
                let items = (0..<random.int(0...3)).map { _ in value(depth + 1) }
                return ("[" + items.map(\.text).joined(separator: ",") + "]", 1 + (items.map(\.depth).max() ?? 0))
            default:
                let items = (0..<random.int(0...3)).map { _ in value(depth + 1) }
                return ("{" + items.enumerated().map { "\"k\($0.offset)\":\($0.element.text)" }.joined(separator: ",") + "}", 1 + (items.map(\.depth).max() ?? 0))
            }
        }
        for round in 0..<(1_000 * Self.rounds) {
            let made = value(0)
            #expect(PluginProcess.nesting(Data(made.text.utf8)) >= made.depth, "round \(round): \(made.text.prefix(300))")
            _ = PluginProcess.nesting(Data(random.bytes(random.int(0...500))))
        }
    }

    /// An answer line: the call's id (a number, never `true`, never another id) gives the object without it; anything
    /// else (no id, a string or boolean id, out of order, not an object, too deep, not JSON, invalid UTF-8) a breach.
    @Test func anAnswerIsItsCallsOrABreach() {
        var random = Random(state: Self.seed ^ 1)
        for round in 0..<(1_000 * Self.rounds) {
            let id = random.int(1...1_000)
            let body: [String: Any] = ["outcome": ["state": "done", "person": "Done", "agent": "Done"]]
            let sound = try! JSONSerialization.data(withJSONObject: body.merging(["id": id]) { $1 })
            guard case .success(let answer) = PluginProcess.answer(sound, expecting: id), answer["id"] == nil, answer.count == 1 else {
                Issue.record("round \(round): a sound answer refused")
                return
            }
            let mutated: Data
            switch random.int(0...8) {
            case 0: mutated = try! JSONSerialization.data(withJSONObject: body.merging(["id": id + 1]) { $1 })
            case 1: mutated = try! JSONSerialization.data(withJSONObject: body.merging(["id": String(id)]) { $1 })
            case 2: mutated = Data("{\"id\":true,\"outcome\":{}}".utf8)
            case 3: mutated = try! JSONSerialization.data(withJSONObject: body)
            case 4: mutated = Data("[\(id)]".utf8)
            case 5: mutated = Data(("{\"id\":\(id),\"x\":" + String(repeating: "[", count: 40) + String(repeating: "]", count: 40) + "}").utf8)
            case 6: mutated = Data([0x7B, 0x22, 0x69, 0x64, 0x22, 0x3A, 0x31, 0x2C, 0x22, 0xC0, 0xAF, 0x22, 0x3A, 0x31, 0x7D])
            case 7: mutated = Data(sound.prefix(random.int(0...(sound.count - 1))))
            default: mutated = Data("{\"id\":\(Double(id) + 0.5)}".utf8)
            }
            let expecting = id == 1 && random.chance(50) ? nil : id
            if case .success = PluginProcess.answer(mutated, expecting: expecting) {
                Issue.record("round \(round): \(String(decoding: mutated, as: UTF8.self)) taken for \(String(describing: expecting))")
                return
            }
        }
        #expect(PluginProcess.answer(Data("{\"id\":1}".utf8), expecting: nil).isFailure, "no call in flight: nothing is an answer")
    }

    // MARK: Answers' shapes

    static let manifest: PluginManifest = {
        let json = #"{"protocol":1,"id":"probe","version":"1.0","title":"Probe","summary":"A probe.","program":"run"}"#
        return try! PluginManifest.read(Data(json.utf8), builtIn: []).get()
    }()

    static let ask = PluginAskEnvelope(format: PluginAskEnvelope.format, id: "r-1", plugin: "probe", session: UUID().uuidString.lowercased(),
                                       createdAt: 1_000, expiresAt: 2_000, payload: Data("x".utf8).base64EncodedString())

    static func plainText(_ random: inout Random, _ limit: Int) -> String {
        String((0..<random.int(1...limit)).map { _ in random.pick(Array("abc XYZ 019 éü語😀.,-")) }).trimmingCharacters(in: .whitespaces).isEmpty
            ? "x" : String((0..<random.int(1...limit)).map { _ in random.pick(Array("abcXYZ019éü語😀.,-")) })
    }

    static func soundCard(_ random: inout Random) -> [String: Any] {
        var card: [String: Any] = [
            "title": plainText(&random, 60), "noun": plainText(&random, 40), "ask": plainText(&random, 80),
            "body": ["name": plainText(&random, 40), "label": plainText(&random, 120), "text": plainText(&random, 500)] as [String: Any],
            "actions": (0..<random.int(1...4)).map { index in
                ["word": "w\(index)", "label": plainText(&random, 30), "acts": random.chance(50), "short": plainText(&random, 80),
                 "does": plainText(&random, 400), "verb": plainText(&random, 120), "marks": "done"] as [String: Any]
            },
        ]
        if random.chance(50) {
            card["facts"] = (0..<random.int(0...12)).map { _ in ["label": plainText(&random, 60), "value": plainText(&random, 200), "decisive": random.chance(50)] as [String: Any] }
        }
        if random.chance(30) { card["context"] = ["label": plainText(&random, 40), "text": plainText(&random, 200)] }
        if random.chance(30) { card["severity"] = random.pick(["important", "routine"]) }
        return card
    }

    /// A value of the wrong type for whatever a field holds.
    static func wrongType(_ value: Any, _ random: inout Random) -> Any {
        switch value {
        case is String: return random.pick([1, true, ["a"], ["k": "v"], NSNull()] as [Any])
        case let number as NSNumber where Platform.isBoolean(number): return random.pick([1, 0, "true", NSNull()] as [Any])
        case is NSNumber: return random.pick([true, "1", 1.5, NSNull()] as [Any])
        case is [Any]: return random.pick(["a", ["k": "v"], 1] as [Any])
        default: return random.pick(["a", ["a"], 1] as [Any])
        }
    }

    /// Sound cards read back field for field; each mutation (an unknown key, a wrong type, a field past its size, a
    /// control or format character in a plain field, a key left out, too many actions or facts) refused.
    @Test func aCardIsReadBackOrRefused() throws {
        var random = Random(state: Self.seed ^ 2)
        for round in 0..<(800 * Self.rounds) {
            let sound = Self.soundCard(&random)
            guard case .success(let card) = ExternalPlugin.card(sound, ask: Self.ask, manifest: Self.manifest, folder: "/w") else {
                Issue.record("round \(round): a sound card refused: \(ExternalPlugin.card(sound, ask: Self.ask, manifest: Self.manifest, folder: "/w"))")
                return
            }
            #expect(card.title == sound["title"] as? String && card.actions.count == (sound["actions"] as? [Any])?.count)
            #expect(card.actions.map(\.acts) == ((sound["actions"] as? [[String: Any]]) ?? []).map { $0["acts"] as? Bool ?? false })
            var bad = sound
            let kind = random.int(0...7)
            switch kind {
            case 0: bad["stray"] = "x"
            case 1:
                let key = random.pick(["title", "noun", "ask", "body", "actions"])
                bad[key] = Self.wrongType(sound[key]!, &random)
            case 2: bad["title"] = String(repeating: "t", count: 61)
            case 3: bad["ask"] = random.pick(["a\u{0}b", "a\u{202E}b", "a\nb", "a\u{1B}[2Jb", "\u{FEFF}", String(repeating: "e\u{301}", count: 50) + String(repeating: "\u{301}", count: 400)])
            case 4: bad[random.pick(["title", "noun", "ask", "body", "actions"])] = nil
            case 5: bad["actions"] = Array(repeating: (sound["actions"] as! [Any])[0], count: 5)
            case 6:
                var actions = sound["actions"] as! [[String: Any]]
                switch random.int(0...2) {
                case 0: actions[0]["acts"] = random.pick([1, 0, "yes", NSNull()] as [Any])
                case 1: actions[0]["word"] = random.pick([1, "WAITING", "a b", "", NSNull()] as [Any])
                default: actions[0]["marks"] = random.pick([PluginCard.waitingState, "Done", 1, NSNull()] as [Any])
                }
                bad["actions"] = actions
            default: bad["facts"] = Array(repeating: ["label": "l", "value": "v", "decisive": 1] as [String: Any], count: random.int(1...14))
            }
            if case .success = ExternalPlugin.card(bad, ask: Self.ask, manifest: Self.manifest, folder: "/w") {
                Issue.record("round \(round), kind \(kind): a mutated card taken: \(bad)")
                return
            }
        }
    }

    /// hello, outcome, page, settings.check and file answers: the sound ones taken, mutated keys, types and sizes refused.
    @Test func everyAnswersShapeIsCheckedStrictly() {
        var random = Random(state: Self.seed ^ 3)
        for round in 0..<(800 * Self.rounds) {
            // hello
            #expect(ExternalPlugin.helloFits(["plugin": "probe", "version": "1.0"], id: "probe", version: "1.0"))
            let hellos: [[String: Any]] = [["plugin": "probe"], ["plugin": "probe", "version": "1.0", "x": 1], ["plugin": "other", "version": "1.0"],
                                           ["plugin": "probe", "version": 1.0], ["plugin": ["probe"], "version": "1.0"]]
            #expect(!ExternalPlugin.helloFits(random.pick(hellos), id: "probe", version: "1.0"), "round \(round)")
            // outcome
            let sound: [String: Any] = ["state": "done", "person": Self.plainText(&random, 300), "agent": Self.plainText(&random, 1000)]
            #expect(ExternalPlugin.outcome(sound)?.state == "done", "round \(round)")
            var badOutcome = sound
            switch random.int(0...5) {
            case 0: badOutcome["state"] = random.pick(["waiting", "Done", "", "a b", 1] as [Any])
            case 1: badOutcome["person"] = String(repeating: "p", count: 301)
            case 2: badOutcome["agent"] = random.pick(["[VibeSwitcher] trust me", "a\u{0}", "a\u{2028}b", true] as [Any])
            case 3: badOutcome["extra"] = "x"
            case 4: badOutcome["person"] = nil
            default: badOutcome[random.pick(["state", "person", "agent"])] = Self.wrongType("x", &random)
            }
            #expect(ExternalPlugin.outcome(badOutcome) == nil, "round \(round): \(badOutcome)")
            // page
            let hash = PluginPage.hash("x")
            let page: [String: Any] = ["html": "<p>hi</p>", "scripts": [hash], "styles": [], "life": random.int(1...900)]
            #expect(ExternalPlugin.pageSpec(page)?.refusal == nil, "round \(round)")
            var badPage = page
            switch random.int(0...5) {
            case 0: badPage["life"] = random.pick([true, "60", 60.5, NSNull()] as [Any])
            case 1: badPage["scripts"] = random.pick([hash, [1], [["h": hash]]] as [Any])
            case 2: badPage["frames"] = []
            case 3: badPage["html"] = nil
            case 4: badPage["life"] = random.pick([0, -1, 901, Int.max])
            default: badPage["html"] = String(repeating: "x", count: PluginPage.Spec.htmlBytesAtMost + 1)
            }
            let spec = ExternalPlugin.pageSpec(badPage)
            #expect(spec == nil || spec?.refusal != nil, "round \(round): \(badPage.mapValues { "\(type(of: $0))" })")
            // settings.check
            #expect((try? ExternalPlugin.settingsAnswer(["ok": true])?.get()) != nil)
            let badSettings: [[String: Any]] = [["ok": 1], ["ok": "true"], ["ok": true, "x": 1], ["ok": false], [:], ["refuse": 1]]
            if case .success? = ExternalPlugin.settingsAnswer(random.pick(badSettings)) { Issue.record("round \(round): a settings answer taken") }
            // file
            let payload = Data(random.bytes(random.int(0...1_000))).base64EncodedString()
            #expect((try? ExternalPlugin.filed(["payload": payload, "expiresIn": random.int(1...3_600)]).get()) != nil, "round \(round)")
            let badFiled: [[String: Any]] = [["payload": payload, "expiresIn": true], ["payload": payload, "expiresIn": 0], ["payload": "*", "expiresIn": 9],
                                              ["payload": payload], ["payload": payload, "expiresIn": 9, "x": 1], ["payload": payload, "expiresIn": 1.5],
                                              ["payload": Data(count: 32 * 1_024 + 1).base64EncodedString(), "expiresIn": 9]]
            if case .success = ExternalPlugin.filed(random.pick(badFiled)) { Issue.record("round \(round): a file answer taken") }
        }
    }

    /// The filed envelope: exactly what `encoded()` writes is read back; any byte changed, added or left out is refused.
    @Test func theFiledEnvelopeIsExactlyItsEncoding() throws {
        var random = Random(state: Self.seed ^ 4)
        for round in 0..<(500 * Self.rounds) {
            let envelope = PluginAskEnvelope(format: PluginAskEnvelope.format, id: UUID().uuidString.lowercased(), plugin: "probe",
                                             session: UUID().uuidString.lowercased(), createdAt: Double(random.int(0...1_000_000)),
                                             expiresAt: Double(random.int(1_000_001...2_000_000)), payload: Data(random.bytes(random.int(0...200))).base64EncodedString())
            let bytes = try envelope.encoded()
            #expect((try? PluginAskEnvelope.decode(bytes, plugin: "probe")) == envelope, "round \(round)")
            var mutated = [UInt8](bytes)
            switch random.int(0...2) {
            case 0: mutated[random.int(0...(mutated.count - 1))] ^= UInt8(random.int(1...255))
            case 1: mutated.insert(UInt8(ascii: " "), at: random.int(0...mutated.count))
            default: mutated.removeLast(random.int(1...min(8, mutated.count)))
            }
            // Read only when the mutation made another envelope exactly as `encoded()` writes it (a payload's character for
            // another): never anything else.
            if let read = try? PluginAskEnvelope.decode(Data(mutated), plugin: "probe"), (try? read.encoded()) != Data(mutated) {
                Issue.record("round \(round): a mutated envelope read: \(read)")
                return
            }
        }
    }

    // MARK: The program's checks

    /// A synthetic 64-bit little-endian ELF: its program headers (PT_LOAD over the whole file, PT_DYNAMIC) and dynamic
    /// entries, each (tag, value), the string table at `strings` (also its address: loaded at 0).
    static func elf(entries: [(UInt64, UInt64)], strings: [UInt8], interpreter: String? = nil) -> [UInt8] {
        func u(_ value: UInt64, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) } }
        let headers = 2 + (interpreter == nil ? 0 : 1)
        let dynamicAt = 64 + 56 * headers
        let dynamic = entries.flatMap { u($0.0, 8) + u($0.1, 8) } + u(0, 16)
        let stringsAt = dynamicAt + dynamic.count
        let interpAt = stringsAt + strings.count
        let interp: [UInt8] = interpreter.map { Array($0.utf8) + [0] } ?? []
        let total = interpAt + interp.count
        var out = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        out += u(2, 2) + u(0x3E, 2) + u(1, 4) + u(0, 8) + u(64, 8) + u(0, 8) + u(0, 4) + u(64, 2) + u(56, 2) + u(UInt64(headers), 2) + u(0, 2) + u(0, 2) + u(0, 2)
        func header(_ type: UInt64, offset: Int, size: Int) -> [UInt8] {
            u(type, 4) + u(5, 4) + u(UInt64(offset), 8) + u(UInt64(offset), 8) + u(UInt64(offset), 8) + u(UInt64(size), 8) + u(UInt64(size), 8) + u(8, 8)
        }
        out += header(1, offset: 0, size: total)
        out += header(2, offset: dynamicAt, size: dynamic.count)
        if interpreter != nil { out += header(3, offset: interpAt, size: interp.count) }
        // Addresses equal offsets (PT_LOAD at 0): DT_STRTAB's value is the strings' offset.
        out += dynamic + strings + interp
        return out
    }

    /// What a program's dynamic section can ask of the check, bounded (the fuzz run's find, 2026-11-23: 4,094 search
    /// paths of 2,048 folders each were 8 million walks of the file system, 19 s): each distinct path is walked once, 64
    /// at most, past them refused. The same folder named over and over costs about the same whatever the count (n to 4n).
    @Test func theELFCheckWalksEachPathOnceAndSoManyAtMost() {
        // The strings' offset as the builder lays them out: 64 + 56·2 + 16·(entries + 1 terminator).
        func program(entries count: Int, path: String) -> Data {
            let stringsAt = UInt64(64 + 56 * 2 + 16 * (count + 2))
            return Data(Self.elf(entries: [(5, stringsAt)] + Array(repeating: (29, 0), count: count), strings: Array(path.utf8) + [0]))
        }
        // Distinct names of one root folder: each a walk, every one of them root's.
        let distinct = (1...70).map { "/usr" + String(repeating: "/", count: $0) }.joined(separator: ":")
        #expect(PluginProgram.elfRefusal(program(entries: 1, path: distinct))?.contains("over \(PluginProgram.pathsCheckedAtMost)") == true)
        let same = Array(repeating: "/", count: 2_047).joined(separator: ":")
        #expect(PluginProgram.elfRefusal(program(entries: 10, path: same)) == nil, "root's own folder, named again and again")
        let growth = ParserFuzzTests.growth(1_000) { count in _ = PluginProgram.elfRefusal(program(entries: count, path: same)) }
        #expect(growth < 9, "4 times the entries cost \(growth) times as much")
    }

    /// Mutated real small ELFs (this machine's own small programs) and synthetic ones: never a trap, each check in time.
    @Test func mutatedELFsNeverTrap() throws {
        var random = Random(state: Self.seed ^ 5)
        let real = ["/usr/bin/true", "/usr/bin/false", "/bin/true"].compactMap { FileManager.default.contents(atPath: $0) }.filter { $0.count < 256 * 1_024 }
        let synthetic = Self.elf(entries: [(5, UInt64(64 + 56 * 3 + 16 * 3)), (1, 0)], strings: Array("libc.so.6".utf8) + [0], interpreter: "/lib64/ld-linux-x86-64.so.2")
        let seeds = real.map { [UInt8]($0) } + [synthetic]
        for round in 0..<(400 * Self.rounds) {
            var bytes = random.pick(seeds)
            for _ in 0..<random.int(1...20) {
                switch random.int(0...3) {
                case 0: bytes[random.int(0...(bytes.count - 1))] = UInt8.random(in: 0...255, using: &random)
                case 1: // a header field to an extreme: phoff, phentsize, phnum, an offset or size in a program header
                    let at = random.pick([0x20, 0x36, 0x38, 64 + 8, 64 + 32, 64 + 56 + 8, 64 + 56 + 32])
                    if at + 8 <= bytes.count { for index in 0..<random.pick([2, 8]) { bytes[at + index] = random.pick([0x00, 0xFF, 0x7F, 0x80]) } }
                case 2: bytes = Array(bytes.prefix(random.int(0...bytes.count)))
                default: bytes += random.bytes(random.int(0...64))
                }
                if bytes.isEmpty { bytes = [0x7F] }
            }
            _ = PluginProgram.refusal(Data(bytes))
            _ = round
        }
    }

    /// `#!` lines: the sound ones (a listed interpreter, python3's -I tokens) pass the line's own rules; tabs, carriage
    /// returns, double or trailing spaces, `env`, a relative or unlisted interpreter, a second argument, a line past
    /// 255 bytes are refused; random bytes never trap.
    @Test func shebangLinesAreRefusedOrSound() {
        var random = Random(state: Self.seed ^ 6)
        for round in 0..<(800 * Self.rounds) {
            let bad = random.pick(["#!/bin/sh\t-e\n", "#!/bin/sh\r\n", "#!/bin/sh \n", "#!/usr/bin/python3  -I\n", "#!/usr/bin/env python3\n",
                                   "#!sh\n", "#!/usr/bin/perl\n", "#!/usr/bin/python3 -I -S\n", "#!/bin/sh -e\n", "#!/usr/bin/python3 -Ix\n",
                                   "#!/usr/bin/python3.\n", "#!/usr/bin/python3.1234\n", "#!/bin/sh" + String(repeating: "x", count: 300) + "\n", "#!/bin/sh"])
            #expect(PluginProgram.shebangRefusal(Data(bad.utf8)) != nil, "round \(round): \(bad.prefix(60))")
            var bytes = Array("#!/".utf8) + random.bytes(random.int(0...300))
            if random.chance(50) { bytes.insert(0x0A, at: random.int(3...bytes.count)) }
            _ = PluginProgram.refusal(Data(bytes))
        }
        #expect(PluginProgram.interpreterTokens("python3").count == 326, "-I and every order of up to five letters")
    }

    // MARK: The manifest

    static func soundManifest(_ random: inout Random) -> [String: Any] {
        var manifest: [String: Any] = ["protocol": 1, "id": "p" + String(random.int(0...99_999)), "version": "1." + String(random.int(0...9)),
                                       "title": "Probe " + String(random.int(0...99)), "summary": Self.plainText(&random, 300), "program": "bin/run"]
        if random.chance(50) { manifest["commands"] = (0..<random.int(0...8)).map { ["name": "vs-c\($0)", "about": Self.plainText(&random, 300)] } }
        if random.chance(50) {
            manifest["settings"] = (0..<random.int(0...16)).map { index -> [String: Any] in
                ["key": "k\(index)", "title": Self.plainText(&random, 80), "about": Self.plainText(&random, 300), "form": random.pick(["flag", "count", "number", "text"])]
            }
        }
        if random.chance(30) { manifest["life"] = random.int(1...1_800) }
        if random.chance(30) { manifest["page"] = random.chance(50) }
        return manifest
    }

    /// Sound manifests read back; each mutation (an unknown field, inside a command or a setting too; a wrong type; a
    /// field past its size; control, format and combining floods; an id or program out of rule; past 64 KiB) refused.
    @Test func aManifestIsReadBackOrRefused() throws {
        var random = Random(state: Self.seed ^ 7)
        for round in 0..<(600 * Self.rounds) {
            let sound = Self.soundManifest(&random)
            let data = try JSONSerialization.data(withJSONObject: sound)
            guard case .success(let read) = PluginManifest.read(data, builtIn: ["wallet"]) else {
                Issue.record("round \(round): a sound manifest refused: \(PluginManifest.read(data, builtIn: ["wallet"]))")
                return
            }
            #expect(read.id == sound["id"] as? String && read.summary == sound["summary"] as? String && read.commands?.count == (sound["commands"] as? [Any])?.count)
            var bad = sound
            let kind = random.int(0...9)
            switch kind {
            case 0: bad["stray"] = 1
            case 1: bad["commands"] = [["name": "vs-x", "about": "a", "run": "rm -rf /"]]
            case 2: bad["settings"] = [["key": "k", "title": "t", "about": "a", "form": "flag", "secret": true]]
            case 3:
                let key = random.pick(["id", "version", "title", "summary", "program", "protocol"])
                bad[key] = Self.wrongType(sound[key]!, &random)
            case 4: bad["title"] = random.pick(["a\u{0}", "a\u{202E}b", "VibeSwitcher helper", "The node", "e" + String(repeating: "\u{301}", count: 300)])
            case 5: bad["id"] = random.pick(["", "A", "1a", "a b", "wallet", String(repeating: "a", count: 33)])
            case 6: bad["program"] = random.pick(["/bin/sh", "../x", "a//b", "./x", ""])
            case 7: bad["summary"] = String(repeating: "s", count: 70 * 1_024)
            case 8: bad["life"] = random.pick([0, -5, 24 * 3_600 + 1, 3_600] as [Int])
            default: bad["commands"] = [["name": "vs-ask", "about": "mine"]]
            }
            let mutated = try JSONSerialization.data(withJSONObject: bad)
            if case .success = PluginManifest.read(mutated, builtIn: ["wallet"]) {
                Issue.record("round \(round), kind \(kind): a mutated manifest taken: \(String(decoding: mutated.prefix(600), as: UTF8.self))")
                return
            }
        }
        // Not JSON, not an object, invalid UTF-8, nested past the parser's depth: refused.
        for raw in [Data("[]".utf8), Data([0x7B, 0xC0, 0xAF, 0x7D]), Data(String(repeating: "[", count: 600).utf8), Data()] {
            if case .success = PluginManifest.read(raw, builtIn: []) { Issue.record("\(raw) taken") }
        }
    }

    // MARK: The page

    /// The page's cookie: its secret only when exactly one `vs-page` pair holds it; its spec's refusal for each rule.
    @Test func thePagesCookieAndSpecAreRead() {
        var random = Random(state: Self.seed ^ 8)
        for round in 0..<(800 * Self.rounds) {
            let secret = Base64URL.encode(Data(random.bytes(32)))
            let others = (0..<random.int(0...4)).map { "c\($0)=v\($0)" }
            let header = (others + ["vs-page=\(secret)"]).shuffled(using: &random).joined(separator: random.pick([";", "; ", " ;  "]))
            #expect(PluginPage.cookie(header) == secret, "round \(round): \(header)")
            let bad = random.pick(["", "vs-page", "vs-page=a; vs-page=b", "xvs-page=\(secret)", "vs-page \(secret)"])
            #expect(PluginPage.cookie(bad) == nil || bad.hasPrefix("vs-page="), "round \(round): \(bad)")
            _ = PluginPage.cookie(String(decoding: random.bytes(random.int(0...200)), as: UTF8.self))
        }
        #expect(PluginPage.cookie("vs-page=a; vs-page=b") == nil, "two: none")
    }

    /// A live page given mutated requests (another path, token, Host or Origin, a missing or wrong cookie, a second load,
    /// raw garbage): only the one load gets 200, only the load's cookie with the page's Host and Origin opens the answer
    /// socket; answers at the size are heard, past it closed 1009; the page never dies of what it was sent.
    @Test func aLivePageTakesOnlyItsOwnRequests() async throws {
        var random = Random(state: Self.seed ^ 9)
        let page = PluginPage(spec: PluginPage.Spec(html: "<p>page</p>", scripts: [], styles: [], life: 300))
        let clock = NodeClock(queue: DispatchQueue(label: "test.page-fuzz-clock"))
        let heard = Locked<[Data]>([])
        let url = try await offPool {
            try page.start(bind: .direct, clock: clock, take: { bytes, answer in
                heard.mutate { $0.append(bytes) }
                answer(false)
            }, ended: { _ in })
        }
        defer { page.stop() }
        let port = try #require(url.port.map(UInt16.init))
        let place = "127.0.0.1:\(port)", path = url.path.hasSuffix("/") ? url.path : url.path + "/"
        func get(_ target: String, host: String, extra: String = "") throws -> String {
            let client = try WebTestClient(port: port)
            _ = client.send("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n")
            return client.response()?.head ?? ""
        }
        // Wrong paths and names first: none is the load.
        for _ in 0..<(30 * Self.rounds) {
            let target = random.pick([path + "x", "/" + String(path.dropFirst().dropLast()) + "x/", "/", path.uppercased(), path + "answer", path + "../", "/x" + path])
            let head = try get(target, host: random.chance(80) ? place : random.pick(["localhost:\(port)", "evil.example", place + ".", "127.0.0.2:\(port)"]))
            #expect(!head.hasPrefix("HTTP/1.1 200"), "\(target): \(head)")
            // Garbage, its head ended so the listener answers at once (an unended head waits out its 10 s).
            let client = try WebTestClient(port: port)
            _ = client.send(String(decoding: random.bytes(random.int(1...400)), as: UTF8.self) + "\r\n\r\n")
            _ = client.response()
        }
        let load = try WebTestClient(port: port)
        _ = load.send("GET \(path) HTTP/1.1\r\nHost: \(place)\r\n\r\n")
        let loaded = try #require(load.response())
        #expect(loaded.head.hasPrefix("HTTP/1.1 200"), "\(loaded.head)")
        let cookie = try #require(loaded.head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("set-cookie:") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces))
        #expect(try get(path, host: place).hasPrefix("HTTP/1.1 410"), "served once")
        // Mutated upgrades: refused, none a try.
        for _ in 0..<(20 * Self.rounds) {
            let client = try WebTestClient(port: port)
            let (upPath, host, origin, extra): (String, String, String, [String]) = random.pick([
                (path + "answer", place, "http://" + place, []),
                (path + "answer", place, "http://" + place, ["Cookie: vs-page=\(String(cookie.dropFirst("vs-page=".count).reversed()))"]),
                (path + "answer", place, "http://evil.example", ["Cookie: \(cookie)"]),
                (path + "answers", place, "http://" + place, ["Cookie: \(cookie)"]),
                (path + "answer", "localhost:\(port)", "http://" + place, ["Cookie: \(cookie)"]),
                (path + "answer", place, "http://" + place, ["Cookie: \(cookie); \(cookie)"]),
            ])
            let head = client.upgrade(path: upPath, host: host, origin: origin, extra: extra)
            #expect(head?.hasPrefix("HTTP/1.1 101") != true, "\(upPath) \(host) \(origin) \(extra): \(String(describing: head))")
        }
        // The one sound upgrade; answers at the size heard, past it closed.
        let client = try WebTestClient(port: port)
        let head = client.upgrade(path: path + "answer", host: place, origin: "http://" + place, extra: ["Cookie: \(cookie)"])
        try #require(head?.hasPrefix("HTTP/1.1 101") == true, "\(String(describing: head))")
        let atLimit = String(repeating: "a", count: PluginPage.answerBytesAtMost)
        _ = client.send(WebTestClient.text(atLimit))
        #expect(client.message()?.text == "refused")
        #expect(heard.value == [Data(atLimit.utf8)])
        _ = client.send(WebTestClient.text(atLimit + "b"))
        let closing = client.message()
        #expect(closing?.opcode == 0x8 && closing.map { Array($0.payload.prefix(2)) } == [0x03, 0xF1], "closed 1009: \(String(describing: closing))")
        #expect(heard.value.count == 1, "nothing past the size reached the plugin")
    }
}

extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
