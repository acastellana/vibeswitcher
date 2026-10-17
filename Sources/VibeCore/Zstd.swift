import Foundation

/// Decompresses Zstandard data (RFC 8878): what Codex writes for compressed rollouts (`rollout-*.jsonl.zst`).
/// macOS ships no zstd (libcompression has none, there is no /usr/bin/zstd), so this is a small decoder of its own:
/// every block type, Huffman literals and FSE sequences, concatenated and skippable frames. No dictionaries; the
/// optional content checksum isn't verified.
public enum Zstd {
    public enum Failure: Error, Equatable {
        case corrupt(String)
        case unsupported(String)
        /// The output would pass the caller's limit.
        case tooLarge
    }

    public static func decompress(_ data: Data, limit: Int = 512 << 20) throws -> Data {
        let input = [UInt8](data)
        var output: [UInt8] = []
        var offset = 0
        while offset < input.count {
            guard input.count - offset >= 4 else { throw Failure.corrupt("truncated frame") }
            let magic = UInt32(littleEndianBytes: input, at: offset)
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {   // skippable frame
                guard input.count - offset >= 8 else { throw Failure.corrupt("truncated skippable frame") }
                offset += 8 + Int(UInt32(littleEndianBytes: input, at: offset + 4))
                continue
            }
            guard magic == 0xFD2F_B528 else { throw Failure.corrupt("not a zstd frame") }
            var frame = FrameDecoder(input: input, offset: offset + 4, limit: limit)
            try frame.decode(into: &output)
            offset = frame.offset
        }
        guard offset == input.count else { throw Failure.corrupt("truncated skippable frame") }
        return Data(output)
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: [UInt8], at index: Int) {
        self = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}

/// Bits `start..<start+count` of `bytes[base..<base+length]`, numbered little-endian (bit 0 is byte 0's lowest).
/// Bits past the end read as zero.
@inline(__always)
private func bits(_ bytes: [UInt8], base: Int, length: Int, start: Int, count: Int) -> UInt64 {
    guard count > 0 else { return 0 }
    var word: UInt64 = 0
    let first = start >> 3
    for index in 0..<8 where first + index < length {
        word |= UInt64(bytes[base + first + index]) << (8 * UInt64(index))
    }
    return (word >> UInt64(start & 7)) & ((1 << UInt64(count)) - 1)
}

/// Reads a stream written backwards (Huffman and FSE payloads): from the end, below the last byte's marker bit.
private struct BackwardBits {
    let bytes: [UInt8]
    let base: Int
    let length: Int
    /// Bits left; negative once a read went past the start (which yields zeros).
    var position: Int

    init(_ bytes: [UInt8], base: Int, length: Int) throws {
        guard length > 0, bytes[base + length - 1] != 0 else { throw Zstd.Failure.corrupt("bitstream without end mark") }
        self.bytes = bytes
        self.base = base
        self.length = length
        position = (length - 1) * 8 + (7 - bytes[base + length - 1].leadingZeroBitCount)
    }

    mutating func read(_ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        let start = position - count
        position = start
        if start >= 0 { return bits(bytes, base: base, length: length, start: start, count: count) }
        let available = start + count
        guard available > 0 else { return 0 }
        return bits(bytes, base: base, length: length, start: 0, count: available) << UInt64(-start)
    }

    func peek(_ count: Int) -> UInt64 {
        var copy = self
        return copy.read(count)
    }
}

/// A finite-state-entropy decoding table.
private struct FSETable {
    struct Entry { var symbol: UInt8; var bits: UInt8; var base: UInt16 }
    var accuracyLog: Int
    var entries: [Entry]

    static func rle(_ symbol: UInt8) -> FSETable { FSETable(accuracyLog: 0, entries: [Entry(symbol: symbol, bits: 0, base: 0)]) }

    init(accuracyLog: Int, entries: [Entry]) {
        self.accuracyLog = accuracyLog
        self.entries = entries
    }

    init(counts: [Int], accuracyLog: Int) throws {
        let size = 1 << accuracyLog
        var table = [Entry](repeating: Entry(symbol: 0, bits: 0, base: 0), count: size)
        var next = [Int](repeating: 0, count: counts.count)
        var high = size - 1
        for (symbol, count) in counts.enumerated() {
            if count == -1 {
                table[high].symbol = UInt8(symbol)
                high -= 1
                next[symbol] = 1
            } else {
                next[symbol] = max(count, 0)
            }
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for (symbol, count) in counts.enumerated() where count > 0 {
            for _ in 0..<count {
                table[position].symbol = UInt8(symbol)
                repeat { position = (position + step) & (size - 1) } while position > high
            }
        }
        guard position == 0 else { throw Zstd.Failure.corrupt("FSE distribution doesn't fill its table") }
        for index in 0..<size {
            let symbol = Int(table[index].symbol)
            let state = next[symbol]
            next[symbol] += 1
            let bitCount = accuracyLog - (Int.bitWidth - 1 - state.leadingZeroBitCount)
            table[index].bits = UInt8(bitCount)
            table[index].base = UInt16((state << bitCount) - size)
        }
        self.init(accuracyLog: accuracyLog, entries: table)
    }

    /// Reads a normalized distribution (RFC 8878 4.1.1) from `bytes[offset…]`; returns the table and the bytes it took.
    static func read(_ bytes: [UInt8], offset: Int, end: Int, maxLog: Int, maxSymbol: Int) throws -> (FSETable, Int) {
        let length = end - offset
        guard length > 0 else { throw Zstd.Failure.corrupt("missing FSE table") }
        var bitPosition = 0
        func read(_ count: Int) -> Int {
            defer { bitPosition += count }
            return Int(bits(bytes, base: offset, length: length, start: bitPosition, count: count))
        }
        func peek(_ count: Int) -> Int { Int(bits(bytes, base: offset, length: length, start: bitPosition, count: count)) }
        let accuracyLog = read(4) + 5
        guard accuracyLog <= maxLog else { throw Zstd.Failure.corrupt("FSE accuracy too high") }
        var remaining = (1 << accuracyLog) + 1
        var threshold = 1 << accuracyLog
        var bitCount = accuracyLog + 1
        var counts: [Int] = []
        var previousZero = false
        while remaining > 1, counts.count <= maxSymbol {
            if previousZero {
                var zeros = 0
                while true {
                    let flag = read(2)
                    zeros += flag
                    if flag != 3 { break }
                }
                counts += [Int](repeating: 0, count: zeros)
                guard counts.count <= maxSymbol else { throw Zstd.Failure.corrupt("FSE zeros past the last symbol") }
            }
            let maxValue = (2 * threshold - 1) - remaining
            var value: Int
            if peek(bitCount - 1) & (threshold - 1) < maxValue {
                value = read(bitCount - 1) & (threshold - 1)
            } else {
                value = read(bitCount) & (2 * threshold - 1)
                if value >= threshold { value -= maxValue }
            }
            let count = value - 1
            remaining -= abs(count)
            counts.append(count)
            previousZero = count == 0
            while remaining < threshold { bitCount -= 1; threshold >>= 1 }
        }
        guard remaining == 1, (bitPosition + 7) / 8 <= length else { throw Zstd.Failure.corrupt("bad FSE distribution") }
        return (try FSETable(counts: counts, accuracyLog: accuracyLog), (bitPosition + 7) / 8)
    }

    @inline(__always) func symbol(_ state: Int) -> Int { Int(entries[state].symbol) }

    @inline(__always) func update(_ state: inout Int, _ stream: inout BackwardBits) {
        let entry = entries[state]
        state = Int(entry.base) + Int(stream.read(Int(entry.bits)))
    }
}

/// A Huffman decoding table: indexed by the next `maxBits` bits.
private struct HuffmanTable {
    var maxBits: Int
    var symbols: [UInt8]
    var lengths: [UInt8]

    /// The tree description at `bytes[offset…]` (RFC 8878 4.2.1); returns the table and the bytes it took.
    static func read(_ bytes: [UInt8], offset: Int, end: Int) throws -> (HuffmanTable, Int) {
        guard offset < end else { throw Zstd.Failure.corrupt("missing Huffman tree") }
        let header = Int(bytes[offset])
        var weights: [Int] = []
        let used: Int
        if header >= 128 {
            let count = header - 127
            used = 1 + (count + 1) / 2
            guard offset + used <= end else { throw Zstd.Failure.corrupt("truncated Huffman weights") }
            for index in 0..<count {
                let byte = Int(bytes[offset + 1 + index / 2])
                weights.append(index % 2 == 0 ? byte >> 4 : byte & 15)
            }
        } else {
            used = 1 + header
            guard offset + used <= end else { throw Zstd.Failure.corrupt("truncated Huffman weights") }
            let (table, tableSize) = try FSETable.read(bytes, offset: offset + 1, end: offset + used, maxLog: 6, maxSymbol: 255)
            var stream = try BackwardBits(bytes, base: offset + 1 + tableSize, length: header - tableSize)
            var state1 = Int(stream.read(table.accuracyLog))
            var state2 = Int(stream.read(table.accuracyLog))
            while weights.count < 255 {
                weights.append(table.symbol(state1))
                table.update(&state1, &stream)
                if stream.position < 0 { weights.append(table.symbol(state2)); break }
                weights.append(table.symbol(state2))
                table.update(&state2, &stream)
                if stream.position < 0 { weights.append(table.symbol(state1)); break }
            }
        }
        return (try HuffmanTable(weights: weights), used)
    }

    init(weights given: [Int]) throws {
        var total = 0
        for weight in given where weight > 0 {
            guard weight <= 11 else { throw Zstd.Failure.corrupt("Huffman weight too big") }
            total += 1 << (weight - 1)
        }
        guard total > 0 else { throw Zstd.Failure.corrupt("empty Huffman tree") }
        let maxBits = Int.bitWidth - total.leadingZeroBitCount   // highest bit + 1
        let rest = (1 << maxBits) - total
        guard rest > 0, rest & (rest - 1) == 0, maxBits <= 11 else { throw Zstd.Failure.corrupt("bad Huffman weights") }
        let weights = given + [rest.trailingZeroBitCount + 1]
        var symbols = [UInt8](repeating: 0, count: 1 << maxBits)
        var lengths = [UInt8](repeating: 0, count: 1 << maxBits)
        var position = 0
        for weight in 1...maxBits {
            for (symbol, w) in weights.enumerated() where w == weight {
                let span = 1 << (weight - 1)
                for index in position..<(position + span) {
                    symbols[index] = UInt8(symbol)
                    lengths[index] = UInt8(maxBits + 1 - weight)
                }
                position += span
            }
        }
        self.maxBits = maxBits
        self.symbols = symbols
        self.lengths = lengths
    }

    func decode(_ bytes: [UInt8], base: Int, length: Int, count: Int, into output: inout [UInt8]) throws {
        var stream = try BackwardBits(bytes, base: base, length: length)
        for _ in 0..<count {
            let index = Int(stream.peek(maxBits))
            output.append(symbols[index])
            _ = stream.read(Int(lengths[index]))
        }
        guard stream.position == 0 else { throw Zstd.Failure.corrupt("Huffman stream size mismatch") }
    }
}

private struct FrameDecoder {
    let input: [UInt8]
    var offset: Int
    let limit: Int
    var huffman: HuffmanTable?
    var literalTable: FSETable?
    var offsetTable: FSETable?
    var matchTable: FSETable?
    var repeats = [1, 4, 8]

    init(input: [UInt8], offset: Int, limit: Int) {
        self.input = input
        self.offset = offset
        self.limit = limit
    }

    mutating func byte() throws -> Int {
        guard offset < input.count else { throw Zstd.Failure.corrupt("truncated frame header") }
        defer { offset += 1 }
        return Int(input[offset])
    }

    mutating func decode(into output: inout [UInt8]) throws {
        let descriptor = try byte()
        let singleSegment = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw Zstd.Failure.corrupt("reserved frame bit set") }
        if !singleSegment { _ = try byte() }   // window size: the whole output is kept anyway
        var dictionary = 0
        for index in 0..<[0, 1, 2, 4][descriptor & 3] { dictionary |= try byte() << (8 * index) }
        guard dictionary == 0 else { throw Zstd.Failure.unsupported("dictionary") }
        let sizeBytes = [singleSegment ? 1 : 0, 2, 4, 8][descriptor >> 6]
        var contentSize = 0
        for index in 0..<sizeBytes { contentSize |= try byte() << (8 * index) }
        if sizeBytes == 2 { contentSize += 256 }
        if sizeBytes > 0 {
            guard contentSize <= limit - output.count else { throw Zstd.Failure.tooLarge }
            output.reserveCapacity(output.count + contentSize)
        }

        let frameStart = output.count
        var last = false
        while !last {
            guard input.count - offset >= 3 else { throw Zstd.Failure.corrupt("truncated block header") }
            let header = Int(input[offset]) | Int(input[offset + 1]) << 8 | Int(input[offset + 2]) << 16
            offset += 3
            last = header & 1 != 0
            let size = header >> 3
            switch (header >> 1) & 3 {
            case 0:
                guard input.count - offset >= size else { throw Zstd.Failure.corrupt("truncated raw block") }
                guard size <= limit - output.count else { throw Zstd.Failure.tooLarge }
                output.append(contentsOf: input[offset..<(offset + size)])
                offset += size
            case 1:
                guard offset < input.count else { throw Zstd.Failure.corrupt("truncated RLE block") }
                guard size <= limit - output.count else { throw Zstd.Failure.tooLarge }
                output.append(contentsOf: repeatElement(input[offset], count: size))
                offset += 1
            case 2:
                guard input.count - offset >= size, size <= 128 << 10 else { throw Zstd.Failure.corrupt("bad compressed block") }
                try block(end: offset + size, frameStart: frameStart, into: &output)
                offset += size
            default:
                throw Zstd.Failure.corrupt("reserved block type")
            }
        }
        if descriptor & 0x04 != 0 {   // content checksum
            guard input.count - offset >= 4 else { throw Zstd.Failure.corrupt("truncated checksum") }
            offset += 4
        }
        if sizeBytes > 0, output.count - frameStart != contentSize { throw Zstd.Failure.corrupt("frame size mismatch") }
    }

    // MARK: Compressed blocks

    mutating func block(end: Int, frameStart: Int, into output: inout [UInt8]) throws {
        var position = offset
        let literals = try readLiterals(&position, end: end)
        try sequences(&position, end: end, literals: literals, frameStart: frameStart, into: &output)
    }

    mutating func readLiterals(_ position: inout Int, end: Int) throws -> [UInt8] {
        guard position < end else { throw Zstd.Failure.corrupt("missing literals") }
        let first = Int(input[position])
        let type = first & 3
        let format = (first >> 2) & 3
        func header(_ length: Int) throws -> Int {
            guard end - position >= length else { throw Zstd.Failure.corrupt("truncated literals header") }
            var value = 0
            for index in 0..<length { value |= Int(input[position + index]) << (8 * index) }
            position += length
            return value
        }
        if type < 2 {
            let regenerated: Int
            switch format {
            case 0, 2: regenerated = try header(1) >> 3
            case 1: regenerated = try header(2) >> 4
            default: regenerated = try header(3) >> 4
            }
            guard regenerated <= 128 << 10 else { throw Zstd.Failure.corrupt("literals too long") }
            if type == 0 {
                guard end - position >= regenerated else { throw Zstd.Failure.corrupt("truncated raw literals") }
                defer { position += regenerated }
                return Array(input[position..<(position + regenerated)])
            }
            guard position < end else { throw Zstd.Failure.corrupt("truncated RLE literals") }
            defer { position += 1 }
            return [UInt8](repeating: input[position], count: regenerated)
        }
        let (headerSize, sizeBits, streams) = [(3, 10, 1), (3, 10, 4), (4, 14, 4), (5, 18, 4)][format]
        let value = try header(headerSize)
        let regenerated = (value >> 4) & ((1 << sizeBits) - 1)
        let compressed = (value >> (4 + sizeBits)) & ((1 << sizeBits) - 1)
        guard end - position >= compressed, regenerated <= 128 << 10 else { throw Zstd.Failure.corrupt("bad literals size") }
        let streamEnd = position + compressed
        var start = position
        if type == 2 {
            let (table, used) = try HuffmanTable.read(input, offset: start, end: streamEnd)
            huffman = table
            start += used
        }
        guard let huffman else { throw Zstd.Failure.corrupt("treeless literals without a previous tree") }
        var literals: [UInt8] = []
        literals.reserveCapacity(regenerated)
        if streams == 1 {
            try huffman.decode(input, base: start, length: streamEnd - start, count: regenerated, into: &literals)
        } else {
            guard streamEnd - start >= 6 else { throw Zstd.Failure.corrupt("truncated jump table") }
            let sizes = (0..<3).map { Int(input[start + 2 * $0]) | Int(input[start + 2 * $0 + 1]) << 8 }
            var streamStart = start + 6
            let segment = (regenerated + 3) / 4
            for index in 0..<4 {
                let length = index < 3 ? sizes[index] : streamEnd - streamStart
                guard length >= 0, streamStart + length <= streamEnd else { throw Zstd.Failure.corrupt("bad jump table") }
                try huffman.decode(input, base: streamStart, length: length,
                                   count: index < 3 ? segment : regenerated - 3 * segment, into: &literals)
                streamStart += length
            }
        }
        position = streamEnd
        return literals
    }

    static let literalBase = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40,
                              48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let literalBits = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3,
                              4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let matchBase = (0..<32).map { $0 + 3 } + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027,
                                                      2051, 4099, 8195, 16387, 32771, 65539]
    static let matchBits = [Int](repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let defaultLiterals = try! FSETable(counts: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2,
                                                        2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], accuracyLog: 6)
    static let defaultMatches = try! FSETable(counts: [1, 4, 3, 2, 2, 2, 2, 2, 2] + [Int](repeating: 1, count: 37)
                                                  + [Int](repeating: -1, count: 7), accuracyLog: 6)
    static let defaultOffsets = try! FSETable(counts: [1, 1, 1, 1, 1, 1, 2, 2, 2] + [Int](repeating: 1, count: 15)
                                                  + [Int](repeating: -1, count: 5), accuracyLog: 5)

    mutating func table(mode: Int, _ position: inout Int, end: Int, fallback: FSETable, previous: FSETable?,
                        maxLog: Int, maxSymbol: Int) throws -> FSETable {
        switch mode {
        case 0: return fallback
        case 1:
            guard position < end, Int(input[position]) <= maxSymbol else { throw Zstd.Failure.corrupt("bad RLE sequence code") }
            defer { position += 1 }
            return .rle(input[position])
        case 2:
            let (table, used) = try FSETable.read(input, offset: position, end: end, maxLog: maxLog, maxSymbol: maxSymbol)
            position += used
            return table
        default:
            guard let previous else { throw Zstd.Failure.corrupt("repeated sequence table without a previous one") }
            return previous
        }
    }

    mutating func sequences(_ position: inout Int, end: Int, literals: [UInt8], frameStart: Int,
                            into output: inout [UInt8]) throws {
        guard position < end else { throw Zstd.Failure.corrupt("missing sequences header") }
        var count = Int(input[position])
        position += 1
        if count == 0 {
            guard literals.count <= limit - output.count else { throw Zstd.Failure.tooLarge }
            output.append(contentsOf: literals)
            return
        }
        if count >= 128 {
            guard position < end else { throw Zstd.Failure.corrupt("truncated sequences header") }
            if count == 255 {
                guard end - position >= 2 else { throw Zstd.Failure.corrupt("truncated sequences header") }
                count = Int(input[position]) + Int(input[position + 1]) << 8 + 0x7F00
                position += 2
            } else {
                count = (count - 128) << 8 + Int(input[position])
                position += 1
            }
        }
        guard position < end else { throw Zstd.Failure.corrupt("missing compression modes") }
        let modes = Int(input[position])
        position += 1
        guard modes & 3 == 0 else { throw Zstd.Failure.corrupt("reserved compression mode bits") }
        let lit = try table(mode: modes >> 6, &position, end: end, fallback: Self.defaultLiterals, previous: literalTable,
                            maxLog: 9, maxSymbol: 35)
        let off = try table(mode: (modes >> 4) & 3, &position, end: end, fallback: Self.defaultOffsets, previous: offsetTable,
                            maxLog: 8, maxSymbol: 31)
        let mat = try table(mode: (modes >> 2) & 3, &position, end: end, fallback: Self.defaultMatches, previous: matchTable,
                            maxLog: 9, maxSymbol: 52)
        (literalTable, offsetTable, matchTable) = (lit, off, mat)

        var stream = try BackwardBits(input, base: position, length: end - position)
        var literalState = Int(stream.read(lit.accuracyLog))
        var offsetState = Int(stream.read(off.accuracyLog))
        var matchState = Int(stream.read(mat.accuracyLog))
        var literalPosition = 0
        for index in 0..<count {
            let offsetCode = off.symbol(offsetState)
            let matchCode = mat.symbol(matchState)
            let literalCode = lit.symbol(literalState)
            guard offsetCode <= 31, matchCode <= 52, literalCode <= 35 else { throw Zstd.Failure.corrupt("bad sequence code") }
            let offsetValue = (1 << offsetCode) + Int(stream.read(offsetCode))
            let matchLength = Self.matchBase[matchCode] + Int(stream.read(Self.matchBits[matchCode]))
            let literalLength = Self.literalBase[literalCode] + Int(stream.read(Self.literalBits[literalCode]))
            if index + 1 < count {
                lit.update(&literalState, &stream)
                mat.update(&matchState, &stream)
                off.update(&offsetState, &stream)
            }

            var distance: Int
            if offsetValue > 3 {
                distance = offsetValue - 3
                repeats = [distance, repeats[0], repeats[1]]
            } else {
                let choice = offsetValue - 1 + (literalLength == 0 ? 1 : 0)
                switch choice {
                case 0: distance = repeats[0]
                case 1: distance = repeats[1]; repeats = [repeats[1], repeats[0], repeats[2]]
                case 2: distance = repeats[2]; repeats = [repeats[2], repeats[0], repeats[1]]
                default:
                    distance = repeats[0] - 1
                    guard distance > 0 else { throw Zstd.Failure.corrupt("zero offset") }
                    repeats = [distance, repeats[0], repeats[1]]
                }
            }

            guard literalLength <= literals.count - literalPosition else { throw Zstd.Failure.corrupt("literals overrun") }
            guard literalLength + matchLength <= limit - output.count else { throw Zstd.Failure.tooLarge }
            output.append(contentsOf: literals[literalPosition..<(literalPosition + literalLength)])
            literalPosition += literalLength
            guard distance <= output.count - frameStart else { throw Zstd.Failure.corrupt("offset before the frame") }
            // Byte by byte: appending a slice of `output` to itself would copy the whole buffer every time (and
            // a match may overlap what it writes).
            let from = output.count - distance
            for step in 0..<matchLength { output.append(output[from + step]) }
        }
        guard stream.position == 0 else { throw Zstd.Failure.corrupt("sequence stream size mismatch") }
        guard literals.count - literalPosition <= limit - output.count else { throw Zstd.Failure.tooLarge }
        output.append(contentsOf: literals[literalPosition...])
    }
}
