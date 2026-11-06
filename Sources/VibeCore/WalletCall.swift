import Foundation

/// A contract call's calldata in words, for the card and the browser wallet's page: the common token functions (ERC-20
/// approve, transfer, transferFrom, increaseAllowance; ERC-721 and ERC-1155 setApprovalForAll and safeTransferFrom;
/// EIP-2612 permit) and Safe's approveHash and execTransaction by their selector, with who they let spend or receive
/// what. Anything else, or arguments that don't decode as their function's (for the Safe functions: exactly, in the
/// layout an ABI encoder writes), is an unknown call, said plainly: it may move tokens. On the browser path nothing else
/// decodes the call (the Wallet Manager's checks are skipped), so an approve must never read as "0 GEN".
///
/// Amounts are in the token's base units (its decimals aren't known here); one of 2^96−1 or more, which no real
/// balance comes near, is unlimited.
public struct WalletCall: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        public var value: String
        /// Shown in red: an unlimited amount, an approval for every token, bytes after the arguments.
        public var alarming: Bool
        public init(_ name: String, _ value: String, alarming: Bool = false) {
            self.name = name
            self.value = value
            self.alarming = alarming
        }
    }

    /// The function's signature ("approve(address,uint256)"); nil for an unknown call.
    public var function: String?
    /// What it does, in a few words ("Approve a spender"), or `unknownHeadline`.
    public var headline: String
    /// Shown in red: an unknown call, an unlimited approval, an approval for every token.
    public var alarming: Bool
    /// Who it lets spend or receive what, a row each.
    public var fields: [Field]
    /// For a call that lets someone else spend the wallet's tokens (approve, increaseAllowance, permit,
    /// setApprovalForAll granting): the sentence the browser page has the user tick before it sends, naming the spender
    /// and the amount. Nil for any other.
    public var confirmation: String?
    /// The call in one line, in VibeSwitcher's words and from the calldata alone ("Approve Safe transaction 0x2ff4171f… on
    /// Safe 0x16F7…915b"): the card's and the browser page's lead line. Addresses are shortened (`short`); the rows keep
    /// them whole. Nothing but the calldata and the contract feeds it: the same bytes always give the same line.
    public var line: String = ""

    public static let unknownHeadline = "Unknown contract call: it may move tokens"

    /// `data` (0x calldata, as a request carries it) sent to `contract`.
    public static func decode(_ data: String, contract: String) -> WalletCall {
        let hex = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
        guard let bytes = Self.bytes(hex) else { return unknown(selector: nil, size: max(0, hex.utf8.count / 2), contract: contract) }
        return decode(bytes, contract: contract, depth: 0)
    }

    /// `depth`: how many execTransactions this call is inside; one inside another is decoded no further.
    static func decode(_ bytes: [UInt8], contract: String, depth: Int) -> WalletCall {
        guard bytes.count >= 4 else { return unknown(selector: nil, size: bytes.count, contract: contract) }
        let selector = bytes[0..<4].map { String(format: "%02x", $0) }.joined()
        let reader = Reader(bytes: Array(bytes[4...]))
        let decoder: Decoder? = selector == "6a761202" ? (depth == 0 ? { r, c in execTransaction(r, c) } : nil) : Self.known[selector]
        guard let known = decoder else { return unknown(selector: selector, size: bytes.count, contract: contract) }
        guard var call = known(reader, contract.lowercased()) else {
            return unknown(selector: selector, size: bytes.count, contract: contract, malformed: true)
        }
        // The line names the contract as the request wrote it (its checksum case), shortened.
        call.line = call.line.replacingOccurrences(of: Self.contractMark, with: short(contract))
        return call
    }

    /// Where a decoder's line names the contract: `decode` puts the request's own spelling of it there.
    static let contractMark = "\u{E000}"

    /// An address in a line: its first 6 and last 4 characters ("0x16F7…915b"); anything 12 characters or shorter whole.
    public static func short(_ address: String) -> String {
        address.count > 12 ? "\(address.prefix(6))…\(address.suffix(4))" : address
    }

    /// A 32-byte hash in a line: its first 10 characters ("0x2ff4171f…").
    static func shortHash(_ hash: String) -> String { hash.count > 12 ? "\(hash.prefix(10))…" : hash }

    /// A call not decoded here: it may do anything the contract allows, moving tokens included, so the browser page asks
    /// for the same deliberate tick as a grant (`confirmation`).
    static func unknown(selector: String?, size: Int, contract: String, malformed: Bool = false) -> WalletCall {
        var fields: [Field] = []
        if let selector { fields.append(Field("Function", "0x\(selector)" + (malformed ? ", its arguments don't decode as the known function's" : ""))) }
        fields.append(Field("Calldata", "\(size) bytes, not decoded here"))
        let line = selector.map { "Call 0x\($0) on \(short(contract)) (not decoded)" }
            ?? "Call \(short(contract)) with \(size) bytes of calldata (not decoded)"
        return WalletCall(function: nil, headline: unknownHeadline, alarming: true, fields: fields,
                          confirmation: "I understand this call to the contract \(contract.lowercased()) wasn't decoded here, and it may move tokens from this wallet.",
                          line: line)
    }

    // MARK: The functions

    private typealias Decoder = (Reader, String) -> WalletCall?

    private static let known: [String: Decoder] = [
        "095ea7b3": { r, token in allowance(r, token, function: "approve(address,uint256)", headline: "Approve a spender") },
        "39509351": { r, token in allowance(r, token, function: "increaseAllowance(address,uint256)", headline: "Raise a spender's allowance") },
        "a9059cbb": { r, token in
            guard r.isStatic(2), let to = r.address(0), let amount = r.uint(1) else { return nil }
            return WalletCall(function: "transfer(address,uint256)", headline: "Transfer tokens", alarming: false,
                              fields: [Field("Recipient", to), amountField(amount), Field("Token", token)] + r.extra(2), confirmation: nil,
                              line: "Transfer tokens: \(amountWords(amount)) of token \(contractMark) to \(short(to))")
        },
        "23b872dd": { r, token in
            guard r.isStatic(3), let from = r.address(0), let to = r.address(1), let amount = r.uint(2) else { return nil }
            return WalletCall(function: "transferFrom(address,address,uint256)", headline: "Transfer tokens from an account", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), amountField(amount), Field("Token", token)] + r.extra(3),
                              confirmation: nil,
                              line: "Transfer tokens from an account: \(amountWords(amount)) of token \(contractMark) from \(short(from)) to \(short(to))")
        },
        "a22cb465": { r, collection in
            guard r.isStatic(2), let operator_ = r.address(0), let approved = r.bool(1) else { return nil }
            let fields = [Field("Operator", operator_),
                          approved ? Field("Approval", "every token of this collection, now and later", alarming: true) : Field("Approval", "revoked"),
                          Field("Collection", collection)] + r.extra(2)
            return WalletCall(function: "setApprovalForAll(address,bool)",
                              headline: approved ? "Approve an operator for every token" : "Revoke an operator's approval",
                              alarming: approved, fields: fields,
                              confirmation: approved ? "I understand this lets \(operator_) move every token I hold in the collection \(collection)." : nil,
                              line: approved ? "Approve an operator for every token: \(short(operator_)) may move every token of collection \(contractMark)"
                                : "Revoke an operator's approval: \(short(operator_)) on collection \(contractMark)")
        },
        "42842e0e": { r, collection in
            guard r.isStatic(3), let from = r.address(0), let to = r.address(1), let id = r.uint(2) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256)", headline: "Transfer an NFT", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), Field("Collection", collection)] + r.extra(3),
                              confirmation: nil, line: nftLine(id, from, to))
        },
        "b88d4fde": { r, collection in
            guard let from = r.address(0), let to = r.address(1), let id = r.uint(2), let data = r.dynamicBytes(3, head: 4) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256,bytes)", headline: "Transfer an NFT", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), Field("Collection", collection)]
                                + dataField(data), confirmation: nil, line: nftLine(id, from, to))
        },
        "f242432a": { r, contract in
            guard let from = r.address(0), let to = r.address(1), let id = r.uint(2), let amount = r.uint(3),
                  let data = r.dynamicBytes(4, head: 5) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256,uint256,bytes)", headline: "Transfer tokens (ERC-1155)",
                              alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), amountField(amount),
                                       Field("Contract", contract)] + dataField(data), confirmation: nil,
                              line: "Transfer tokens (ERC-1155): \(amountWords(amount)) of token id \(decimal(id)) on \(contractMark) from \(short(from)) to \(short(to))")
        },
        "d505accf": { r, token in
            guard r.isStatic(7), let owner = r.address(0), let spender = r.address(1), let amount = r.uint(2), let deadline = r.uint(3),
                  let v = r.uint(4), isSmall(v, below: 256) else { return nil }
            let unlimited = isUnlimited(amount)
            return WalletCall(function: "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", headline: "Permit: approve a spender",
                              alarming: unlimited,
                              fields: [Field("Owner", owner), Field("Spender", spender), amountField(amount), Field("Deadline", date(deadline)),
                                       Field("Token", token)] + r.extra(7),
                              confirmation: "I understand this lets \(spender) spend \(amountWords(amount)) of the token \(token) from \(owner).",
                              line: "Permit: approve a spender: \(short(spender)) may spend \(amountWords(amount)) of token \(contractMark) from \(short(owner))")
        },
        // Safe's approveHash(bytes32): one owner's approval of a Safe transaction by its hash. Exactly one word.
        "d4d9bdcd": { r, safe in
            guard r.bytes.count == 32, let word = r.word(0) else { return nil }
            let hash = "0x" + word.map { String(format: "%02x", $0) }.joined()
            return WalletCall(function: "approveHash(bytes32)", headline: "Approve a Safe transaction", alarming: false,
                              fields: [Field("Safe transaction hash", hash), Field("Safe", safe)],
                              confirmation: "I understand this approves the Safe transaction \(hash) on the Safe \(safe) as one of its owners; what that transaction does isn't shown here.",
                              line: "Approve Safe transaction \(shortHash(hash)) on Safe \(contractMark)")
        },
    ]

    private static func nftLine(_ id: [UInt8], _ from: String, _ to: String) -> String {
        "Transfer an NFT: token id \(decimal(id)) of collection \(contractMark) from \(short(from)) to \(short(to))"
    }

    /// Safe's execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas,
    /// uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures), in exactly the layout an ABI encoder
    /// writes: data right after the 10 head words, signatures right after it, each zero-padded, nothing after. The inner
    /// call is decoded as a call of its own (one execTransaction inside another isn't: it's unknown).
    private static func execTransaction(_ r: Reader, _ safe: String) -> WalletCall? {
        guard let to = r.address(0), let value = r.uint(1), let operation = r.uint(3), isSmall(operation, below: 2),
              let safeTxGas = r.uint(4), let baseGas = r.uint(5), let gasPrice = r.uint(6),
              let gasToken = r.address(7), let refundReceiver = r.address(8),
              let data = r.canonicalBytes(offsetWord: 2, at: 10 * 32),
              let signatures = r.canonicalBytes(offsetWord: 9, at: data.end), signatures.end == r.bytes.count else { return nil }
        let delegate = operation[31] == 1
        let zero = [UInt8](repeating: 0, count: 32)
        let inner: WalletCall? = data.bytes.isEmpty ? nil : decode(data.bytes, contract: to, depth: 1)
        let valueText = "\(decimal(value)) base units of the native coin"
        var fields = [Field("Safe", safe), Field("Target", to),
                      delegate ? Field("Operation", "delegatecall: runs the target's code as the Safe itself", alarming: true) : Field("Operation", "call"),
                      Field("Value", valueText)]
        if let inner {
            fields.append(Field("Inner call", inner.headline + (inner.function.map { " (\($0))" } ?? ""), alarming: inner.alarming))
            fields += inner.fields.map { Field("Inner: \($0.name)", $0.value, alarming: $0.alarming) }
        } else {
            fields.append(Field("Inner call", "none: no calldata"))
        }
        let refund = gasPrice != zero
        if refund {
            let token = gasToken == "0x" + String(repeating: "0", count: 40) ? "the native coin" : "token \(gasToken)"
            let receiver = refundReceiver == "0x" + String(repeating: "0", count: 40) ? "whoever submits it" : refundReceiver
            fields.append(Field("Gas refund", "the Safe pays \(receiver) for gas in \(token), at gas price \(decimal(gasPrice))", alarming: true))
        }
        fields.append(Field("Safe gas", "safeTxGas \(decimal(safeTxGas)), baseGas \(decimal(baseGas))"))
        fields.append(Field("Signatures", "\(signatures.bytes.count) bytes"))

        let verb = delegate ? "delegatecall" : "call"
        let what: String
        if let inner {
            if let function = inner.function {
                what = "\(delegate ? "delegatecall " : "")\(function) on \(short(to))"
            } else if data.bytes.count >= 4 {
                what = "\(verb) 0x\(data.bytes[0..<4].map { String(format: "%02x", $0) }.joined()) on \(short(to)) (not decoded)"
            } else {
                what = "\(verb) \(short(to)) with \(data.bytes.count) bytes of calldata (not decoded)"
            }
        } else {
            what = value == zero ? "an empty \(verb) to \(short(to))" : "\(delegate ? "delegatecall " : "send ")\(valueText) to \(short(to))"
        }
        let withValue = inner != nil && value != zero ? ", with \(valueText)" : ""
        return WalletCall(function: "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)",
                          headline: "Execute a Safe transaction", alarming: delegate || refund || inner?.alarming == true, fields: fields,
                          confirmation: "I understand this has the Safe \(safe) \(verb) \(to)\(inner.map { ": \($0.headline)" } ?? ""), which may move the Safe's funds.",
                          line: "Execute a Safe transaction on \(contractMark): \(what)\(withValue)")
    }

    /// approve and increaseAllowance: (spender, amount) on the token contract.
    private static func allowance(_ r: Reader, _ token: String, function: String, headline: String) -> WalletCall? {
        guard r.isStatic(2), let spender = r.address(0), let amount = r.uint(1) else { return nil }
        return WalletCall(function: function, headline: headline, alarming: isUnlimited(amount),
                          fields: [Field("Spender", spender), amountField(amount), Field("Token", token)] + r.extra(2),
                          confirmation: "I understand this lets \(spender) spend \(amountWords(amount)) of the token \(token) from this wallet.",
                          line: "\(headline): \(short(spender)) may spend \(amountWords(amount))\(function.hasPrefix("increase") ? " more" : "") of token \(contractMark)")
    }

    private static func amountField(_ word: [UInt8]) -> Field {
        guard isUnlimited(word) else { return Field("Amount", "\(decimal(word)) base units") }
        let value = word.allSatisfy { $0 == 0xff } ? "2^256−1, the largest there is" : "\(decimal(word)) base units"
        return Field("Amount", "Unlimited (\(value))", alarming: true)
    }

    private static func amountWords(_ word: [UInt8]) -> String {
        isUnlimited(word) ? "an unlimited amount" : "\(decimal(word)) base units"
    }

    private static func dataField(_ data: Int) -> [Field] {
        data == 0 ? [] : [Field("Data", "\(data) bytes passed on to the recipient")]
    }

    // MARK: Words

    /// 2^96−1 or more: the top 20 bytes aren't all zero, or the low 12 are all 0xff.
    static func isUnlimited(_ word: [UInt8]) -> Bool {
        word[0..<20].contains { $0 != 0 } || word[20..<32].allSatisfy { $0 == 0xff }
    }

    static func isSmall(_ word: [UInt8], below limit: Int) -> Bool {
        word[0..<30].allSatisfy { $0 == 0 } && Int(word[30]) << 8 | Int(word[31]) < limit
    }

    /// A 32-byte big-endian number in decimal digits.
    static func decimal(_ word: [UInt8]) -> String {
        var number = word
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in number.indices {
                let value = remainder << 8 | Int(number[index])
                number[index] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
        }
        return digits.isEmpty ? "0" : String(digits.reversed())
    }

    /// A permit's deadline: a UTC time, or the number when it's past any date.
    static func date(_ word: [UInt8]) -> String {
        guard word[0..<24].allSatisfy({ $0 == 0 }) else { return "never (\(decimal(word)))" }
        let seconds = word[24..<32].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard seconds < 253_402_300_800 else { return "never (\(seconds))" }   // past 9999-12-31
        return WalletRequestFormat.string(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func bytes(_ hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0, digits.allSatisfy(WalletRequestFormat.isHex) else { return nil }
        func value(_ digit: UInt8) -> UInt8 {
            switch digit {
            case 0x30...0x39: return digit - 0x30
            case 0x61...0x66: return digit - 0x61 + 10
            default: return digit - 0x41 + 10
            }
        }
        return stride(from: 0, to: digits.count, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) }
    }

    /// The arguments after the selector, as ABI words.
    struct Reader {
        let bytes: [UInt8]

        func word(_ index: Int) -> [UInt8]? {
            let start = index * 32
            guard start + 32 <= bytes.count else { return nil }
            return Array(bytes[start..<start + 32])
        }

        /// At least `count` words: arguments past them are named (`extra`), not dropped.
        func isStatic(_ count: Int) -> Bool { bytes.count >= count * 32 }

        /// The bytes after `count` words, as a field when there are any: the contract ignores them, but nothing here
        /// knows what they are.
        func extra(_ count: Int) -> [Field] {
            let left = bytes.count - count * 32
            return left > 0 ? [Field("Extra data", "\(left) bytes after the arguments", alarming: true)] : []
        }

        func uint(_ index: Int) -> [UInt8]? { word(index) }

        func address(_ index: Int) -> String? {
            guard let word = word(index), word[0..<12].allSatisfy({ $0 == 0 }) else { return nil }
            return "0x" + word[12...].map { String(format: "%02x", $0) }.joined()
        }

        func bool(_ index: Int) -> Bool? {
            guard let word = word(index), word[0..<31].allSatisfy({ $0 == 0 }), word[31] <= 1 else { return nil }
            return word[31] == 1
        }

        /// The length of the `bytes` argument whose offset is word `index`, of a function with `head` words; nil when
        /// its offset or length points outside the calldata.
        func dynamicBytes(_ index: Int, head: Int) -> Int? {
            // Offsets and lengths fit in 32 bits (calldata is 24 KiB at most), so no sum below can overflow.
            guard let offsetWord = word(index), offsetWord[0..<28].allSatisfy({ $0 == 0 }) else { return nil }
            let offset = offsetWord[28..<32].reduce(0) { $0 << 8 | Int($1) }
            guard offset >= head * 32, offset % 32 == 0, offset + 32 <= bytes.count,
                  let lengthWord = word(offset / 32), lengthWord[0..<28].allSatisfy({ $0 == 0 }) else { return nil }
            let length = lengthWord[28..<32].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 32 + length <= bytes.count else { return nil }
            return length
        }

        /// The `bytes` argument whose offset is word `index`, only where an ABI encoder puts it: at `at`, its length
        /// word then its bytes, zero-padded to a whole word. Its bytes and where the next argument would start; nil
        /// for any other layout.
        func canonicalBytes(offsetWord index: Int, at: Int) -> (bytes: [UInt8], end: Int)? {
            guard let offsetWord = word(index), offsetWord[0..<28].allSatisfy({ $0 == 0 }) else { return nil }
            let offset = offsetWord[28..<32].reduce(0) { $0 << 8 | Int($1) }
            guard offset == at, offset % 32 == 0, let lengthWord = word(offset / 32), lengthWord[0..<28].allSatisfy({ $0 == 0 }) else { return nil }
            let length = lengthWord[28..<32].reduce(0) { $0 << 8 | Int($1) }
            let start = offset + 32, end = start + (length + 31) / 32 * 32
            guard end <= bytes.count, bytes[(start + length)..<end].allSatisfy({ $0 == 0 }) else { return nil }
            return (Array(bytes[start..<(start + length)]), end)
        }
    }
}
