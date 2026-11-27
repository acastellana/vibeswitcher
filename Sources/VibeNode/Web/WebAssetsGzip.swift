import Foundation

/// The page's text files gzipped for the browser (the design review's D26: a cold load on a slow link): DEFLATE
/// (RFC 1951) in a gzip member (RFC 1952), made here in Swift because Foundation gives no compressor on Linux and the
/// node links no zlib. Deterministic: the same bytes always give the same output, on every platform and build (no
/// time, no name, no table that depends on the machine), so a file's gzipped `ETag` is stable across restarts.
///
/// The encoder: LZ77 over a 32 KiB window with hash chains (up to `maxChain` candidates a position) and one step of lazy
/// matching, then each block of up to `blockSymbols` symbols coded with its own Huffman codes (dynamic), lengths
/// limited to 15 bits (7 for the code lengths' own code), or stored where that is smaller. Not as small as zlib's best,
/// close to its default; the page's 1.5 MiB takes a moment once, then each file's result is kept (`WebAssets.gzipped`).
enum WebGzip {
    static let maxChain = 128
    static let niceLength = 258
    static let blockSymbols = 1 << 15

    /// `data` as one gzip member: header (no name, no time, OS unknown), the deflate stream, CRC-32 and size.
    static func gzip(_ data: Data) -> Data {
        let input = [UInt8](data)
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]
        out += deflate(input)
        let crc = crc32(input)
        let size = UInt32(truncatingIfNeeded: input.count)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: crc >> UInt32(shift))) }
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8(truncatingIfNeeded: size >> UInt32(shift))) }
        return Data(out)
    }

    // MARK: CRC-32 (the gzip trailer's)

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: The bit writer (LSB first, as DEFLATE packs)

    struct Bits {
        var bytes: [UInt8] = []
        var buffer: UInt64 = 0
        var count = 0

        mutating func write(_ value: Int, _ width: Int) {
            guard width > 0 else { return }
            buffer |= UInt64(value) << UInt64(count)
            count += width
            while count >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                count -= 8
            }
        }

        /// A Huffman code, whose bits go most significant first.
        mutating func code(_ code: Int, _ length: Int) {
            var reversed = 0
            var c = code
            for _ in 0..<length { reversed = reversed << 1 | c & 1; c >>= 1 }
            write(reversed, length)
        }

        mutating func align() {
            if count > 0 { write(0, 8 - count) }
        }
    }

    // MARK: Length and distance codes (RFC 1951 3.2.5)

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                      4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// The length code (0-based, symbol 257 + it) for a length of 3 to 258.
    private static let lengthCode: [Int] = {
        var table = [Int](repeating: 0, count: 259)
        for code in 0..<29 {
            let end = code == 28 ? 259 : lengthBase[code + 1]
            for length in lengthBase[code]..<min(end, 259) { table[length] = code }
        }
        table[258] = 28
        return table
    }()

    private static func distanceCode(_ distance: Int) -> Int {
        var code = 0
        while code < 29 && distanceBase[code + 1] <= distance { code += 1 }
        return code
    }

    // MARK: LZ77

    /// A symbol: a literal (`length` 0) or a match of `length` at `distance` back.
    struct Symbol {
        var literal: UInt8
        var length: UInt16
        var distance: UInt16
    }

    static func matches(_ input: [UInt8]) -> [Symbol] {
        let n = input.count
        var symbols: [Symbol] = []
        symbols.reserveCapacity(n / 3 + 16)
        guard n > 0 else { return symbols }
        let window = 1 << 15
        let hashSize = 1 << 15
        var head = [Int32](repeating: -1, count: hashSize)
        var prev = [Int32](repeating: -1, count: window)
        input.withUnsafeBufferPointer { bytes in
            func hash(_ i: Int) -> Int {
                (Int(bytes[i]) << 10 ^ Int(bytes[i + 1]) << 5 ^ Int(bytes[i + 2])) & (hashSize - 1)
            }
            func insert(_ i: Int) {
                guard i + 2 < n else { return }
                let h = hash(i)
                prev[i & (window - 1)] = head[h]
                head[h] = Int32(i)
            }
            // The longest match for position `i` among the earlier positions the chain holds: (length, distance).
            func longest(_ i: Int) -> (Int, Int) {
                guard i + 2 < n else { return (0, 0) }
                var candidate = Int(head[hash(i)])
                let limit = min(258, n - i)
                var best = 0
                var bestDistance = 0
                var chain = maxChain
                while candidate >= 0, i - candidate <= window - 1, chain > 0 {
                    if candidate < i, bytes[candidate + best] == bytes[i + best] || best == 0 {
                        var length = 0
                        while length < limit && bytes[candidate + length] == bytes[i + length] { length += 1 }
                        if length > best {
                            best = length
                            bestDistance = i - candidate
                            if length >= niceLength || length == limit { break }
                        }
                    }
                    let next = Int(prev[candidate & (window - 1)])
                    if next >= candidate { break }
                    candidate = next
                    chain -= 1
                }
                return best >= 3 ? (best, bestDistance) : (0, 0)
            }
            var i = 0
            var pending: (length: Int, distance: Int)? = nil
            while i < n {
                let found = pending ?? longest(i)
                pending = nil
                if found.0 >= 3 {
                    // One step lazy: a longer match at the next byte wins, this byte going as a literal.
                    insert(i)
                    if found.0 < niceLength, i + 1 < n {
                        let next = longest(i + 1)
                        if next.0 > found.0 {
                            symbols.append(Symbol(literal: bytes[i], length: 0, distance: 0))
                            i += 1
                            pending = next
                            continue
                        }
                    }
                    symbols.append(Symbol(literal: 0, length: UInt16(found.0), distance: UInt16(found.1)))
                    for j in (i + 1)..<(i + found.0) { insert(j) }
                    i += found.0
                } else {
                    insert(i)
                    symbols.append(Symbol(literal: bytes[i], length: 0, distance: 0))
                    i += 1
                }
            }
        }
        return symbols
    }

    // MARK: Huffman codes

    /// Code lengths for `frequencies`, none longer than `limit`: a Huffman tree's depths, then the lengths moved under
    /// the limit keeping the code complete (the JPEG standard's adjustment), the shortest to the most frequent. At least
    /// two symbols get a code (a one-symbol code is incomplete; the absent symbols 0 and 1 stand in), as zlib does.
    static func lengths(_ frequencies: [Int], limit: Int) -> [Int] {
        var frequencies = frequencies
        var used = frequencies.indices.filter { frequencies[$0] > 0 }
        for stand in [0, 1] where used.count < 2 && !used.contains(stand) {
            frequencies[stand] = 1
            used.append(stand)
        }
        used.sort()
        // The tree: leaves sorted by (frequency, symbol), merged with the two-queue method; each node's parent.
        let leaves = used.sorted { (frequencies[$0], $0) < (frequencies[$1], $1) }
        var weight = leaves.map { frequencies[$0] }
        var parent = [Int](repeating: -1, count: leaves.count)
        var leaf = 0
        var inner: [Int] = []  // indices into weight/parent past the leaves
        var innerAt = 0
        func takeSmallest() -> Int {
            if leaf < leaves.count, innerAt >= inner.count || weight[leaf] <= weight[inner[innerAt]] {
                leaf += 1
                return leaf - 1
            }
            innerAt += 1
            return inner[innerAt - 1]
        }
        while (leaves.count - leaf) + (inner.count - innerAt) > 1 {
            let a = takeSmallest()
            let b = takeSmallest()
            weight.append(weight[a] + weight[b])
            parent.append(-1)
            let node = weight.count - 1
            parent[a] = node
            parent[b] = node
            inner.append(node)
        }
        var depth = [Int](repeating: 0, count: weight.count)
        for node in stride(from: weight.count - 2, through: 0, by: -1) { depth[node] = depth[parent[node]] + 1 }
        // How many codes of each length, moved under the limit.
        let deepest = max(limit, depth.prefix(leaves.count).max() ?? 0)
        var count = [Int](repeating: 0, count: deepest + 1)
        for index in 0..<leaves.count { count[depth[index]] += 1 }
        var bits = deepest
        while bits > limit {
            while count[bits] > 0 {
                var shorter = bits - 2
                while count[shorter] == 0 { shorter -= 1 }
                count[bits] -= 2
                count[bits - 1] += 1
                count[shorter + 1] += 2
                count[shorter] -= 1
            }
            bits -= 1
        }
        // The shortest lengths to the most frequent symbols (the leaves' order reversed).
        var result = [Int](repeating: 0, count: frequencies.count)
        var length = 1
        for symbol in leaves.reversed() {
            while count[length] == 0 { length += 1 }
            result[symbol] = length
            count[length] -= 1
        }
        return result
    }

    /// Canonical codes for `lengths` (RFC 1951 3.2.2).
    static func codes(_ lengths: [Int]) -> [Int] {
        let maxLength = lengths.max() ?? 0
        var count = [Int](repeating: 0, count: maxLength + 1)
        for length in lengths where length > 0 { count[length] += 1 }
        var next = [Int](repeating: 0, count: maxLength + 2)
        var code = 0
        for bits in 1...max(maxLength, 1) {
            code = (code + (bits - 1 < count.count ? count[bits - 1] : 0)) << 1
            next[bits] = code
        }
        return lengths.map { length in
            guard length > 0 else { return 0 }
            defer { next[length] += 1 }
            return next[length]
        }
    }

    // MARK: Blocks

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// The code lengths of both codes as code-length symbols (0–15, 16 repeat, 17 and 18 zeros) with their extras.
    private static func runs(_ lengths: [Int]) -> [(symbol: Int, extra: Int, width: Int)] {
        var out: [(Int, Int, Int)] = []
        var i = 0
        while i < lengths.count {
            let value = lengths[i]
            var run = 1
            while i + run < lengths.count && lengths[i + run] == value { run += 1 }
            var left = run
            if value == 0 {
                while left >= 11 { let take = min(left, 138); out.append((18, take - 11, 7)); left -= take }
                if left >= 3 { out.append((17, left - 3, 3)); left = 0 }
            } else {
                out.append((value, 0, 0))
                left -= 1
                while left >= 3 { let take = min(left, 6); out.append((16, take - 3, 2)); left -= take }
            }
            for _ in 0..<left { out.append((value, 0, 0)) }
            i += run
        }
        return out
    }

    static func deflate(_ input: [UInt8]) -> [UInt8] {
        let symbols = matches(input)
        var bits = Bits()
        var start = 0
        var byteAt = 0
        repeat {
            let end = min(start + blockSymbols, symbols.count)
            let block = symbols[start..<end]
            let blockBytes = block.reduce(0) { $0 + ($1.length == 0 ? 1 : Int($1.length)) }
            let last = end == symbols.count
            var literal = [Int](repeating: 0, count: 286)
            var distance = [Int](repeating: 0, count: 30)
            for symbol in block {
                if symbol.length == 0 { literal[Int(symbol.literal)] += 1 } else {
                    literal[257 + lengthCode[Int(symbol.length)]] += 1
                    distance[distanceCode(Int(symbol.distance))] += 1
                }
            }
            literal[256] = 1
            let literalLengths = lengths(literal, limit: 15)
            let distanceLengths = lengths(distance, limit: 15)
            var hlit = 286
            while hlit > 257 && literalLengths[hlit - 1] == 0 { hlit -= 1 }
            var hdist = 30
            while hdist > 1 && distanceLengths[hdist - 1] == 0 { hdist -= 1 }
            let header = runs(Array(literalLengths.prefix(hlit)) + Array(distanceLengths.prefix(hdist)))
            var lengthFrequencies = [Int](repeating: 0, count: 19)
            for run in header { lengthFrequencies[run.symbol] += 1 }
            let lengthLengths = lengths(lengthFrequencies, limit: 7)
            var hclen = 19
            while hclen > 4 && lengthLengths[codeLengthOrder[hclen - 1]] == 0 { hclen -= 1 }
            // The block's size coded, against stored (its bytes, plus a header of 5 bytes a 65535).
            var coded = 3 + 5 + 5 + 4 + hclen * 3
            for run in header { coded += lengthLengths[run.symbol] + run.width }
            for (symbol, frequency) in literal.enumerated() where frequency > 0 {
                coded += frequency * (literalLengths[symbol] + (symbol > 256 ? lengthExtra[symbol - 257] : 0))
            }
            for (code, frequency) in distance.enumerated() where frequency > 0 { coded += frequency * (distanceLengths[code] + distanceExtra[code]) }
            let stored = (blockBytes + 4) * 8 + ((blockBytes / 65535) + 1) * 40
            if stored < coded || blockBytes == 0 && !last {
                var at = byteAt
                var left = blockBytes
                repeat {
                    let take = min(left, 65535)
                    bits.write(last && left == take ? 1 : 0, 1)
                    bits.write(0, 2)
                    bits.align()
                    bits.write(take, 16)
                    bits.write(take ^ 0xFFFF, 16)
                    bits.bytes += input[at..<(at + take)]
                    at += take
                    left -= take
                } while left > 0
            } else {
                bits.write(last ? 1 : 0, 1)
                bits.write(2, 2)
                bits.write(hlit - 257, 5)
                bits.write(hdist - 1, 5)
                bits.write(hclen - 4, 4)
                for index in 0..<hclen { bits.write(lengthLengths[codeLengthOrder[index]], 3) }
                let lengthCodes = codes(lengthLengths)
                for run in header {
                    bits.code(lengthCodes[run.symbol], lengthLengths[run.symbol])
                    bits.write(run.extra, run.width)
                }
                let literalCodes = codes(literalLengths)
                let distanceCodes = codes(distanceLengths)
                for symbol in block {
                    if symbol.length == 0 {
                        bits.code(literalCodes[Int(symbol.literal)], literalLengths[Int(symbol.literal)])
                    } else {
                        let length = Int(symbol.length)
                        let code = lengthCode[length]
                        bits.code(literalCodes[257 + code], literalLengths[257 + code])
                        bits.write(length - lengthBase[code], lengthExtra[code])
                        let distanceValue = Int(symbol.distance)
                        let dcode = distanceCode(distanceValue)
                        bits.code(distanceCodes[dcode], distanceLengths[dcode])
                        bits.write(distanceValue - distanceBase[dcode], distanceExtra[dcode])
                    }
                }
                bits.code(literalCodes[256], literalLengths[256])
            }
            byteAt += blockBytes
            start = end
        } while start < symbols.count
        bits.align()
        return bits.bytes
    }
}
