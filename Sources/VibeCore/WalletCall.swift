import Foundation

/// A contract call's calldata in words, for the card and the browser wallet's page: the common token functions (ERC-20
/// approve, transfer, transferFrom, increaseAllowance; ERC-721 and ERC-1155 setApprovalForAll and safeTransferFrom;
/// EIP-2612 permit) by their selector, with who they let spend or receive what. Anything else, or arguments that don't
/// decode as their function's, is an unknown call, said plainly: it may move tokens. On the browser path nothing else
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

    public static let unknownHeadline = "Unknown contract call: it may move tokens"

    /// `data` (0x calldata, as a request carries it) sent to `contract`.
    public static func decode(_ data: String, contract: String) -> WalletCall {
        let hex = data.hasPrefix("0x") ? String(data.dropFirst(2)) : data
        guard let bytes = Self.bytes(hex), bytes.count >= 4 else { return unknown(selector: nil, size: max(0, hex.utf8.count / 2), contract: contract) }
        let selector = bytes[0..<4].map { String(format: "%02x", $0) }.joined()
        let reader = Reader(bytes: Array(bytes[4...]))
        guard let known = Self.known[selector] else { return unknown(selector: selector, size: bytes.count, contract: contract) }
        guard let call = known(reader, contract.lowercased()) else {
            return unknown(selector: selector, size: bytes.count, contract: contract, malformed: true)
        }
        return call
    }

    /// A call not decoded here: it may do anything the contract allows, moving tokens included, so the browser page asks
    /// for the same deliberate tick as a grant (`confirmation`).
    static func unknown(selector: String?, size: Int, contract: String, malformed: Bool = false) -> WalletCall {
        var fields: [Field] = []
        if let selector { fields.append(Field("Function", "0x\(selector)" + (malformed ? ", its arguments don't decode as the known function's" : ""))) }
        fields.append(Field("Calldata", "\(size) bytes, not decoded here"))
        return WalletCall(function: nil, headline: unknownHeadline, alarming: true, fields: fields,
                          confirmation: "I understand this call to the contract \(contract.lowercased()) wasn't decoded here, and it may move tokens from this wallet.")
    }

    // MARK: The functions

    private typealias Decoder = (Reader, String) -> WalletCall?

    private static let known: [String: Decoder] = [
        "095ea7b3": { r, token in allowance(r, token, function: "approve(address,uint256)", headline: "Approve a spender") },
        "39509351": { r, token in allowance(r, token, function: "increaseAllowance(address,uint256)", headline: "Raise a spender's allowance") },
        "a9059cbb": { r, token in
            guard r.isStatic(2), let to = r.address(0), let amount = r.uint(1) else { return nil }
            return WalletCall(function: "transfer(address,uint256)", headline: "Transfer tokens", alarming: false,
                              fields: [Field("Recipient", to), amountField(amount), Field("Token", token)] + r.extra(2), confirmation: nil)
        },
        "23b872dd": { r, token in
            guard r.isStatic(3), let from = r.address(0), let to = r.address(1), let amount = r.uint(2) else { return nil }
            return WalletCall(function: "transferFrom(address,address,uint256)", headline: "Transfer tokens from an account", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), amountField(amount), Field("Token", token)] + r.extra(3),
                              confirmation: nil)
        },
        "a22cb465": { r, collection in
            guard r.isStatic(2), let operator_ = r.address(0), let approved = r.bool(1) else { return nil }
            let fields = [Field("Operator", operator_),
                          approved ? Field("Approval", "every token of this collection, now and later", alarming: true) : Field("Approval", "revoked"),
                          Field("Collection", collection)] + r.extra(2)
            return WalletCall(function: "setApprovalForAll(address,bool)",
                              headline: approved ? "Approve an operator for every token" : "Revoke an operator's approval",
                              alarming: approved, fields: fields,
                              confirmation: approved ? "I understand this lets \(operator_) move every token I hold in the collection \(collection)." : nil)
        },
        "42842e0e": { r, collection in
            guard r.isStatic(3), let from = r.address(0), let to = r.address(1), let id = r.uint(2) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256)", headline: "Transfer an NFT", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), Field("Collection", collection)] + r.extra(3),
                              confirmation: nil)
        },
        "b88d4fde": { r, collection in
            guard let from = r.address(0), let to = r.address(1), let id = r.uint(2), let data = r.dynamicBytes(3, head: 4) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256,bytes)", headline: "Transfer an NFT", alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), Field("Collection", collection)]
                                + dataField(data), confirmation: nil)
        },
        "f242432a": { r, contract in
            guard let from = r.address(0), let to = r.address(1), let id = r.uint(2), let amount = r.uint(3),
                  let data = r.dynamicBytes(4, head: 5) else { return nil }
            return WalletCall(function: "safeTransferFrom(address,address,uint256,uint256,bytes)", headline: "Transfer tokens (ERC-1155)",
                              alarming: false,
                              fields: [Field("From", from), Field("Recipient", to), Field("Token id", decimal(id)), amountField(amount),
                                       Field("Contract", contract)] + dataField(data), confirmation: nil)
        },
        "d505accf": { r, token in
            guard r.isStatic(7), let owner = r.address(0), let spender = r.address(1), let amount = r.uint(2), let deadline = r.uint(3),
                  let v = r.uint(4), isSmall(v, below: 256) else { return nil }
            let unlimited = isUnlimited(amount)
            return WalletCall(function: "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", headline: "Permit: approve a spender",
                              alarming: unlimited,
                              fields: [Field("Owner", owner), Field("Spender", spender), amountField(amount), Field("Deadline", date(deadline)),
                                       Field("Token", token)] + r.extra(7),
                              confirmation: "I understand this lets \(spender) spend \(amountWords(amount)) of the token \(token) from \(owner).")
        },
    ]

    /// approve and increaseAllowance: (spender, amount) on the token contract.
    private static func allowance(_ r: Reader, _ token: String, function: String, headline: String) -> WalletCall? {
        guard r.isStatic(2), let spender = r.address(0), let amount = r.uint(1) else { return nil }
        return WalletCall(function: function, headline: headline, alarming: isUnlimited(amount),
                          fields: [Field("Spender", spender), amountField(amount), Field("Token", token)] + r.extra(2),
                          confirmation: "I understand this lets \(spender) spend \(amountWords(amount)) of the token \(token) from this wallet.")
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
    }
}
