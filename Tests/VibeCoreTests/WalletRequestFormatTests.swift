import CryptoKit
import Foundation
import Testing
@testable import VibeCore

/// wallet-request v1 and wallet-result v1 (docs/protocol/wallet-request.md): the strict parser refuses each thing the
/// format doesn't allow, and a request holding anything shaped like key material. Made-up values only: workspace
/// "example", addresses 0x000…01.
struct WalletRequestFormatTests {
    static let created = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z
    static let someone = "0x0000000000000000000000000000000000000001"
    static let token = "0x00000000000000000000000000000000000000aa"

    static func request(action: WalletRequest.Action = .transfer, reason: String = "Pay the example invoice.") -> WalletRequest {
        WalletRequest(id: "00000000-0000-4000-8000-000000000001", createdAt: created, expiresAt: created.addingTimeInterval(86_400),
                     requestedBy: .init(project: "example-project", session: "example-session", label: "Example"),
                     workspace: "example", from: "example-wallet", chainId: 42_424_242, action: action, to: someone,
                     asset: action == .call ? "native" : token, amount: action == .call ? "0" : "1000000",
                     data: action == .call ? "0xa9059cbb" : nil, reason: reason)
    }

    static func result(status: WalletResult.Status = .received, sequence: Int64 = 1) -> WalletResult {
        WalletResult(id: "00000000-0000-4000-8000-000000000001", sequence: sequence, createdAt: created.addingTimeInterval(60),
                    status: status, checks: [.init(name: "format", ok: true, detail: "")], message: "Received.")
    }

    /// `value` with `key` set to `new` (nil removes it), in `path`'s object ("requestedBy", or "" for the top).
    static func edit(_ value: WalletRequestFormat.Value, _ key: String, _ new: WalletRequestFormat.Value?, in path: String = "") -> WalletRequestFormat.Value {
        guard case var .object(members) = value else { return value }
        if !path.isEmpty {
            let index = members.firstIndex { $0.key == path }!
            members[index].value = edit(members[index].value, key, new)
            return .object(members)
        }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let new { members[index].value = new } else { members.remove(at: index) }
        } else if let new {
            members.append(.init(key, new))
        }
        return .object(members)
    }

    static func parseRequest(_ value: WalletRequestFormat.Value) throws -> WalletRequest { try WalletRequest.parse(value.encoded()) }
    static func parseResult(_ value: WalletRequestFormat.Value) throws -> WalletResult { try WalletResult.parse(value.encoded()) }

    // MARK: Round trips and the doc's examples

    @Test func aRequestAndAResultRoundTrip() throws {
        for request in [Self.request(), Self.request(action: .call)] {
            #expect(try WalletRequest.parse(request.encoded()) == request)
        }
        let submitted = WalletResult(id: Self.request().id, sequence: 4, createdAt: Self.created.addingTimeInterval(600), status: .submitted,
                                    checks: [.init(name: "balance", ok: true, detail: "enough")], txHash: "0x" + String(repeating: "ab", count: 32),
                                    explorerURL: "https://explorer.example/tx/0x" + String(repeating: "ab", count: 32), message: "Submitted.")
        #expect(try WalletResult.parse(submitted.encoded()) == submitted)
    }

    /// The doc's two examples are the format: each parses, and writes back byte for byte (one line, a newline).
    @Test func theDocsExamplesParse() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/protocol/wallet-request.md"), encoding: .utf8)
        let blocks = doc.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
        #expect(blocks.count == 2)
        let request = try WalletRequest.parse(Data(blocks[0].utf8))
        #expect(request.workspace == "example")
        let result = try WalletResult.parse(Data(blocks[1].utf8))
        #expect(result.id == request.id)
        // Pretty-printed in the doc; the same values written compactly parse to the same.
        #expect(try WalletRequest.parse(request.encoded()) == request)
        #expect(try WalletResult.parse(result.encoded()) == result)
    }

    static var vectors: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/protocol/vectors", isDirectory: true)
    }

    /// A refusal as the vectors name it: the kind of failure, and its field (none for the file's size or its JSON).
    static func refusal(_ failure: WalletRequestFormat.Failure) -> (String, String?) {
        switch failure {
        case .tooLarge: ("tooLarge", nil)
        case .notJSON: ("notJSON", nil)
        case let .unknownField(field): ("unknownField", field)
        case let .missingField(field): ("missingField", field)
        case let .wrongType(field, _): ("wrongType", field)
        case let .invalid(field, _): ("invalid", field)
        case let .keyMaterial(field, _): ("keyMaterial", field)
        }
    }

    /// The shared vectors (docs/protocol/vectors/index.json), which the Wallet Manager tests too: each valid file
    /// parses and writes back to the same value; each invalid one is refused for its stated reason, on its field.
    @Test func theSharedVectorsHold() throws {
        let index = try WalletRequestFormat.Fields(WalletRequestFormat.Value.parse(Data(contentsOf: Self.vectors.appendingPathComponent("index.json"))),
                                           path: "", allowed: ["format", "vectors"])
        var listed: Set<String> = ["index.json"]
        var counts: [String: Int] = [:]
        for item in try index.array("vectors") {
            let vector = try WalletRequestFormat.Fields(item, path: "vector", allowed: ["file", "kind", "valid", "refusal", "field", "note"])
            let file = try vector.string("file"), kind = try vector.string("kind")
            listed.insert(file)
            #expect(!(try vector.string("note")).isEmpty, "\(file)")
            let data = try Data(contentsOf: Self.vectors.appendingPathComponent(file))
            let parse: (Data) throws -> Void
            switch kind {
            case "request": parse = { data in
                let request = try WalletRequest.parse(data)
                #expect(try WalletRequest.parse(request.encoded()) == request, "\(file)")
            }
            case "result": parse = { data in
                let result = try WalletResult.parse(data)
                #expect(try WalletResult.parse(result.encoded()) == result, "\(file)")
            }
            default: Issue.record("\(file): unknown kind \(kind)"); continue
            }
            if try vector.bool("valid") {
                #expect(throws: Never.self, "\(file)") { try parse(data) }
                counts[kind + " valid", default: 0] += 1
                continue
            }
            let expected = (try vector.string("refusal"), try vector.optionalString("field"))
            do {
                try parse(data)
                Issue.record("\(file) parsed, but should be refused (\(expected.0) \(expected.1 ?? ""))")
            } catch let failure as WalletRequestFormat.Failure {
                let got = Self.refusal(failure)
                #expect(got.0 == expected.0 && got.1 == expected.1, "\(file): refused as \(failure)")
            }
            counts[kind + " invalid", default: 0] += 1
        }
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: Self.vectors.path))
        #expect(files == listed, "files not in index.json: \(files.subtracting(listed)); listed but missing: \(listed.subtracting(files))")
        #expect(counts["request valid", default: 0] >= 5 && counts["result valid", default: 0] >= 5)
        #expect(counts["request invalid", default: 0] >= 40 && counts["result invalid", default: 0] >= 15)
    }

    /// The doc's examples are the first vectors of each kind.
    @Test func theDocsExamplesAreVectors() throws {
        let doc = try String(contentsOf: Self.vectors.deletingLastPathComponent().appendingPathComponent("wallet-request.md"), encoding: .utf8)
        let blocks = doc.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
        #expect(try WalletRequest.parse(Data(blocks[0].utf8))
            == WalletRequest.parse(Data(contentsOf: Self.vectors.appendingPathComponent("request-valid-transfer-native.json"))))
        #expect(try WalletResult.parse(Data(blocks[1].utf8))
            == WalletResult.parse(Data(contentsOf: Self.vectors.appendingPathComponent("result-valid-submitted.json"))))
    }

    /// The answer to a request that fails the format (the doc's "The format check"): rejected, sequence 1, its only
    /// check `format`, failed, with a detail of at most 300 characters.
    @Test func theFormatCheckVectorIsTheAnswerToARequestThatFailsTheFormat() throws {
        let result = try WalletResult.parse(Data(contentsOf: Self.vectors.appendingPathComponent("result-valid-rejected-format.json")))
        #expect(result.status == .rejected && result.sequence == 1)
        #expect(result.txHash == nil && result.safeTxHash == nil && result.explorerURL == nil)
        #expect(result.checks.count == 1)
        let check = try #require(result.checks.first)
        #expect(check.name == "format" && !check.ok)
        #expect(!check.detail.isEmpty && check.detail.unicodeScalars.count <= 300)
        let doc = try String(contentsOf: Self.vectors.deletingLastPathComponent().appendingPathComponent("wallet-request.md"), encoding: .utf8)
        #expect(doc.contains("#### The format check") && doc.contains("at most **300** characters"))
    }

    @Test func theWordlistIsBIP39English() {
        let file = WalletWordlist.text.split(separator: " ").joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
        #expect(WalletWordlist.words.count == 2048)
    }

    // MARK: Refused: unknown fields

    @Test func unknownFieldsAreRefused() throws {
        let request = Self.request().value
        #expect(throws: WalletRequestFormat.Failure.unknownField("note")) { try Self.parseRequest(Self.edit(request, "note", .string("x"))) }
        #expect(throws: WalletRequestFormat.Failure.unknownField("requestedBy.host")) {
            try Self.parseRequest(Self.edit(request, "host", .string("x"), in: "requestedBy"))
        }
        let result = Self.result().value
        #expect(throws: WalletRequestFormat.Failure.unknownField("signature")) { try Self.parseResult(Self.edit(result, "signature", .string("x"))) }
        let check = WalletRequestFormat.Value.array([.object([.init("name", .string("a")), .init("ok", .bool(true)), .init("detail", .string("")),
                                                     .init("extra", .bool(true))])])
        #expect(throws: WalletRequestFormat.Failure.unknownField("checks[0].extra")) { try Self.parseResult(Self.edit(result, "checks", check)) }
    }

    // MARK: Refused: wrong types

    @Test func wrongTypesAreRefused() throws {
        let request = Self.request().value
        #expect(throws: WalletRequestFormat.Failure.wrongType("chainId", "a whole number")) {
            try Self.parseRequest(Self.edit(request, "chainId", .string("42424242")))
        }
        #expect(throws: WalletRequestFormat.Failure.wrongType("amount", "a string")) { try Self.parseRequest(Self.edit(request, "amount", .integer(1))) }
        #expect(throws: WalletRequestFormat.Failure.wrongType("requestedBy", "an object")) {
            try Self.parseRequest(Self.edit(request, "requestedBy", .string("me")))
        }
        #expect(throws: WalletRequestFormat.Failure.wrongType("reason", "a string")) { try Self.parseRequest(Self.edit(request, "reason", .null)) }
        let result = Self.result().value
        let check = WalletRequestFormat.Value.array([.object([.init("name", .string("a")), .init("ok", .string("yes")), .init("detail", .string(""))])])
        #expect(throws: WalletRequestFormat.Failure.wrongType("checks[0].ok", "true or false")) { try Self.parseResult(Self.edit(result, "checks", check)) }
        #expect(throws: WalletRequestFormat.Failure.wrongType("checks", "an array")) { try Self.parseResult(Self.edit(result, "checks", .object([]))) }
    }

    /// Numbers are whole and unsigned; a key may not repeat; a top-level array isn't a request.
    @Test func jsonOutsideTheSubsetIsRefused() {
        let text = String(decoding: Self.request().value.encoded(), as: UTF8.self)
        for bad in [text.replacingOccurrences(of: "\"chainId\":42424242", with: "\"chainId\":42424242.0"),
                    text.replacingOccurrences(of: "\"chainId\":42424242", with: "\"chainId\":4.2e7"),
                    text.replacingOccurrences(of: "\"chainId\":42424242", with: "\"chainId\":-1"),
                    text.replacingOccurrences(of: "\"workspace\":\"example\"", with: "\"workspace\":\"example\",\"workspace\":\"other\""),
                    "[" + text + "]", text + "{}", "\u{FEFF}" + text] {
            #expect(throws: WalletRequestFormat.Failure.self) { try WalletRequest.parse(Data(bad.utf8)) }
        }
    }

    // MARK: Refused: size

    @Test func filesOver64KiBAreRefused() throws {
        let data = Self.request().value.encoded()
        let padded = data + Data(repeating: 0x20, count: WalletRequestFormat.maxFileBytes + 1 - data.count)
        #expect(throws: WalletRequestFormat.Failure.tooLarge(WalletRequestFormat.maxFileBytes + 1)) { try WalletRequest.parse(padded) }
        #expect(throws: WalletRequestFormat.Failure.tooLarge(WalletRequestFormat.maxFileBytes + 1)) { try WalletResult.parse(padded) }
        // Exactly 64 KiB is still read.
        #expect(try WalletRequest.parse(padded.dropLast()) == Self.request())
    }

    // MARK: Refused: addresses

    @Test(arguments: ["0x123", "0x" + String(repeating: "g", count: 40), "0x" + String(repeating: "0", count: 41),
                      "0X" + String(repeating: "0", count: 40), String(repeating: "0", count: 42), " 0x" + String(repeating: "0", count: 40)])
    func badAddressesAreRefused(_ address: String) {
        let request = Self.request().value
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseRequest(Self.edit(request, "to", .string(address))) }
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseRequest(Self.edit(request, "asset", .string(address))) }
        // `from` may be a wallet id instead: only one that starts as an address must be one.
        if address.lowercased().hasPrefix("0x") || address.hasPrefix(" ") {
            #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseRequest(Self.edit(request, "from", .string(address))) }
        }
    }

    @Test func addressesOfEitherCaseAreTaken() throws {
        let mixed = "0x00000000000000000000000000000000000000Aa"
        #expect(try Self.parseRequest(Self.edit(Self.request().value, "to", .string(mixed))).to == mixed)
        #expect(try Self.parseRequest(Self.edit(Self.request().value, "from", .string(mixed))).from == mixed)
    }

    // MARK: Refused: explorer links

    @Test(arguments: ["http://explorer.example/tx/1", "javascript:alert(1)", "ftp://explorer.example/", "https://", "https:///tx",
                      "https://user:pass@explorer.example/tx", "https://explorer.example/tx 1", "explorer.example/tx"])
    func nonHTTPSExplorerLinksAreRefused(_ link: String) {
        let hash = "0x" + String(repeating: "ab", count: 32)
        var result = Self.result(status: .submitted)
        result.txHash = hash
        let value = Self.edit(result.value, "explorerURL", .string(link))
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseResult(value) }
    }

    @Test func anExplorerLinkNamesOnlyItsOwnHash() throws {
        let hash = "0x" + String(repeating: "ab", count: 32)
        var result = Self.result(status: .submitted)
        result.txHash = hash
        result.explorerURL = "https://explorer.example/tx/" + hash
        #expect(try WalletResult.parse(result.encoded()).explorerURL == result.explorerURL)
        let other = Self.edit(result.value, "explorerURL", .string("https://explorer.example/tx/0x" + String(repeating: "cd", count: 32)))
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseResult(other) }
        // No hash, no link.
        let bare = Self.edit(Self.result(status: .received).value, "explorerURL", .string("https://explorer.example/"))
        #expect(throws: WalletRequestFormat.Failure.invalid("explorerURL", "only with a hash")) { try Self.parseResult(bare) }
    }

    // MARK: Refused: status

    @Test(arguments: ["approved", "Received", "", "done", "pending"])
    func unknownStatusValuesAreRefused(_ status: String) {
        let value = Self.edit(Self.result().value, "status", .string(status))
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseResult(value) }
    }

    @Test func everyDocumentedStatusIsTaken() throws {
        for status in WalletResult.Status.allCases {
            var result = Self.result(status: status)
            if status == .submitted { result.txHash = "0x" + String(repeating: "ab", count: 32) }
            #expect(try WalletResult.parse(result.encoded()).status == status)
        }
        // submitted needs its transaction; received can't name one.
        #expect(throws: WalletRequestFormat.Failure.missingField("txHash")) { try Self.parseResult(Self.result(status: .submitted).value) }
        let early = Self.edit(Self.result(status: .received).value, "txHash", .string("0x" + String(repeating: "ab", count: 32)))
        #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseResult(early) }
    }

    // MARK: Other request rules

    @Test func theRequestsOwnRulesHold() {
        let request = Self.request().value
        let refused: [WalletRequestFormat.Value] = [
            Self.edit(request, "type", .string("vibeswitcher.wallet-result")), Self.edit(request, "version", .integer(2)),
            Self.edit(request, "id", .string("00000000-0000-4000-8000-00000000000A")), Self.edit(request, "id", .string("not-a-uuid")),
            Self.edit(request, "expiresAt", .string("2026-10-31T12:00:00Z")), Self.edit(request, "expiresAt", .string("2026-11-30T12:00:00Z")),
            Self.edit(request, "createdAt", .string("2026-10-31T12:00:00.5Z")), Self.edit(request, "createdAt", .string("2026-02-30T12:00:00Z")),
            Self.edit(request, "createdAt", .string("2026-10-31T13:00:00+01:00")),
            Self.edit(request, "chainId", .integer(0)), Self.edit(request, "action", .string("approve")),
            Self.edit(request, "amount", .string("0")), Self.edit(request, "amount", .string("01")), Self.edit(request, "amount", .string("1.5")),
            Self.edit(request, "amount", .string(String(repeating: "9", count: 61))), Self.edit(request, "data", .string("0xa9059cbb")),
            Self.edit(request, "workspace", .string("")), Self.edit(request, "workspace", .string("a/b")),
            Self.edit(request, "reason", .string("")), Self.edit(request, "reason", .string(String(repeating: "a", count: 1001))),
            Self.edit(request, "reason", .string("pay \u{202E}evil")), Self.edit(request, "reason", nil),
            Self.edit(request, "project", nil, in: "requestedBy"), Self.edit(request, "label", .string("two\nlines"), in: "requestedBy"),
        ]
        for value in refused {
            #expect(throws: WalletRequestFormat.Failure.self, "\(String(decoding: value.encoded(), as: UTF8.self))") { try Self.parseRequest(value) }
        }
        let call = Self.request(action: .call).value
        for value in [Self.edit(call, "data", nil), Self.edit(call, "data", .string("0xa9059c")), Self.edit(call, "data", .string("a9059cbb")),
                      Self.edit(call, "asset", .string(Self.token))] {
            #expect(throws: WalletRequestFormat.Failure.self) { try Self.parseRequest(value) }
        }
        // A reason may run over lines, and up to 1000 characters.
        #expect((try? Self.parseRequest(Self.edit(request, "reason", .string("one\ntwo" + String(repeating: "é", count: 993))))) != nil)
    }

    /// A reason can't pass for more of the card than it is: 8 lines at most, no more than 2 combining marks on one
    /// character, nothing that draws as blank space but isn't a space.
    @Test func reasonCantImitateOtherRows() throws {
        let request = Self.request().value
        func reason(_ text: String) throws -> WalletRequest { try Self.parseRequest(Self.edit(request, "reason", .string(text))) }
        let eight = (1...8).map { "line \($0)" }.joined(separator: "\n")
        #expect((try? reason(eight)) != nil)
        #expect(throws: WalletRequestFormat.Failure.invalid("reason", "over 8 lines")) { try reason(eight + "\nline 9") }
        #expect(throws: WalletRequestFormat.Failure.invalid("reason", "over 8 lines")) { try reason("pay" + String(repeating: "\n", count: 8)) }
        // Two marks on a letter (decomposed Vietnamese) is writing; three is stacking.
        #expect((try? reason("Tie\u{0323}\u{0302}n, e\u{0301} and a\u{0300}")) != nil)
        #expect(throws: WalletRequestFormat.Failure.invalid("reason", "stacks more than 2 combining marks on one character")) {
            try reason("pay e\u{0323}\u{0302}\u{0301}xample")
        }
        #expect(throws: WalletRequestFormat.Failure.invalid("reason", "stacks more than 2 combining marks on one character")) {
            try reason("Z" + String(repeating: "\u{0336}", count: 20))
        }
        for blank: UInt32 in [0x3164, 0x115F, 0x1160, 0x2800, 0xFFA0, 0x2028, 0x2029, 0x17B4, 0xFFFC] {
            let scalar = String(Unicode.Scalar(blank)!)
            #expect(throws: WalletRequestFormat.Failure.invalid("reason", "holds a character that draws as blank space (U+\(String(format: "%04X", blank)))")) {
                try reason("Pay the invoice.\n\(scalar)\nAmount: 0 GEN")
            }
        }
        // Ordinary spaces, emoji (a variation selector is one mark) and non-Latin scripts are fine.
        #expect((try? reason("Pay\u{00A0}the 👍\u{FE0F} invoice: 請求書 · счёт · فاتورة")) != nil)
        // The CLI refuses the same, with the parser's words.
        #expect(throws: WalletRequestFormat.Failure.self) {
            var made = Self.request()
            made.reason = "a\u{3164}"
            _ = try made.encoded()
        }
    }

    // MARK: Key material

    static let hex64 = String(repeating: "0123456789abcdef", count: 4)

    @Test func aRunOf64HexDigitsIsRefused() {
        let request = Self.request().value
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("reason", "64 or more hex digits in a row")) {
            try Self.parseRequest(Self.edit(request, "reason", .string("use key " + Self.hex64 + " please")))
        }
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("reason", "64 or more hex digits in a row")) {
            try Self.parseRequest(Self.edit(request, "reason", .string("0x" + Self.hex64)))
        }
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("requestedBy.label", "64 or more hex digits in a row")) {
            try Self.parseRequest(Self.edit(request, "label", .string(Self.hex64), in: "requestedBy"))
        }
        // 63 isn't a key; calldata is made of 32-byte words, and isn't screened.
        #expect((try? Self.parseRequest(Self.edit(request, "reason", .string(String(Self.hex64.dropLast()))))) != nil)
        let call = Self.edit(Self.request(action: .call).value, "data", .string("0xa9059cbb" + Self.hex64 + Self.hex64))
        #expect((try? Self.parseRequest(call)) != nil)
    }

    @Test func twelveBIP39WordsAreRefused() {
        let words = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        let request = Self.request().value
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("reason", "12 or more BIP39 words in a row")) {
            try Self.parseRequest(Self.edit(request, "reason", .string("My words: " + words)))
        }
        // Any case and any separator between them.
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("reason", "12 or more BIP39 words in a row")) {
            try Self.parseRequest(Self.edit(request, "reason", .string(words.uppercased().replacingOccurrences(of: " ", with: ", "))))
        }
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("requestedBy.session", "12 or more BIP39 words in a row")) {
            try Self.parseRequest(Self.edit(request, "session", .string(words.replacingOccurrences(of: " ", with: "-")), in: "requestedBy"))
        }
        // Eleven isn't a phrase.
        let eleven = words.split(separator: " ").dropLast().joined(separator: " ")
        #expect((try? Self.parseRequest(Self.edit(request, "reason", .string(eleven)))) != nil)
    }

    @Test func aBeginBlockIsRefused() {
        let block = "-----" + "BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----" + "END EC PRIVATE KEY-----"
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("reason", "a -----BEGIN block")) {
            try Self.parseRequest(Self.edit(Self.request().value, "reason", .string(block)))
        }
    }

    @Test func anOrdinaryEnglishReasonIsTaken() throws {
        let reason = """
            Monthly payment to the design contractor for October, as agreed in the project budget. The invoice is in the \
            shared folder; please check the amount against it before signing. Thanks!
            """
        #expect(try WalletRequest.parse(Self.request(reason: reason).encoded()).reason == reason)
    }

    @Test func aResultIsScreenedButForItsHashes() throws {
        var result = Self.result(status: .failed)
        result.txHash = "0x" + Self.hex64
        result.safeTxHash = "0x" + Self.hex64
        #expect(try WalletResult.parse(result.encoded()).txHash == result.txHash)
        result.message = "key " + Self.hex64
        #expect(throws: WalletRequestFormat.Failure.keyMaterial("message", "64 or more hex digits in a row")) { try WalletResult.parse(result.value.encoded()) }
    }
}
