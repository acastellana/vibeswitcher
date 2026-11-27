import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The page's text files gzipped (the design review's D26): the encoder's output is gzip the system's own `gzip -d`
/// reads back to the same bytes, for every embedded file and the shapes that test an encoder (empty, one byte, a long
/// run, bytes that don't compress, a block boundary, the longest match and the farthest distance); the same input
/// always gives the same output; and the page's text comes out well under half its size.
struct WebGzipTests {
    let scratch = Scratch()

    /// `data` gzipped here, then read back by the system's gzip (`gzip -dc`): the bytes it gives.
    func roundTrip(_ data: Data, name: String) async throws -> Data {
        let folder = scratch.url("gzip-\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let packed = folder.appendingPathComponent("in.gz")
        let unpacked = folder.appendingPathComponent("out")
        try WebGzip.gzip(data).write(to: packed)
        let ran = try await run(URL(fileURLWithPath: "/bin/sh"), ["-c", #"gzip -dc "$1" > "$2""#, "sh", packed.path, unpacked.path],
                                environment: scratchEnvironment(folder))
        #expect(ran.status == 0, "\(name): \(ran.errors)")
        return try Data(contentsOf: unpacked)
    }

    @Test func theSystemsGzipReadsBackEveryShape() async throws {
        var noise = [UInt8](repeating: 0, count: 70_000)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in noise.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            noise[index] = UInt8(truncatingIfNeeded: state)
        }
        let text = Data(String(repeating: "export const word = 'VibeSwitcher'; // a line of a module\n", count: 3_000).utf8)
        // A match at the farthest distance: 32 KiB of noise, then its first 300 bytes again.
        let far = Data(noise.prefix(32_768) + noise.prefix(300))
        let shapes: [(String, Data)] = [
            ("empty", Data()), ("one", Data([0x41])), ("two", Data([0x41, 0x42])), ("run", Data(repeating: 0x61, count: 100_000)),
            ("noise", Data(noise)), ("text", text), ("far", far), ("mixed", text + Data(noise.prefix(5_000)) + text),
            // More symbols than one block holds, so several blocks.
            ("blocks", Data((0..<200_000).map { UInt8(truncatingIfNeeded: ($0 * 7919) % 251) })),
        ]
        for (name, data) in shapes {
            #expect(try await roundTrip(data, name: name) == data, "\(name)")
        }
    }

    @Test func everyEmbeddedFileReadsBackAndTheTextHalvesAtLeast() async throws {
        var plain = 0
        var packed = 0
        for file in EmbeddedAssets.files {
            let gz = WebGzip.gzip(file.body)
            #expect(try await roundTrip(file.body, name: file.path.replacingOccurrences(of: "/", with: "_")) == file.body, "\(file.path)")
            guard let type = WebAssets.contentType(of: file.path), WebAssets.compressible.contains(type) else { continue }
            plain += file.body.count
            packed += gz.count
        }
        #expect(plain > 500_000)
        #expect(packed * 100 / plain < 35, "the page's text gzipped is \(packed) of \(plain) bytes")
    }

    @Test func theSameBytesGiveTheSameGzip() {
        let body = Data(String(repeating: "the same input, the same output; ", count: 2_000).utf8)
        #expect(WebGzip.gzip(body) == WebGzip.gzip(body))
        // No time and no name in the header; the trailer is the CRC-32 and the size.
        let gz = [UInt8](WebGzip.gzip(body))
        #expect(Array(gz.prefix(10)) == [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        #expect(WebGzip.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        let size = gz.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        #expect(size == body.count)
    }

    @Test func codeLengthsStayUnderTheirLimitAndComplete() {
        // Fibonacci frequencies make the deepest Huffman tree: 30 symbols would want lengths up to 29.
        var fibonacci = [1, 1]
        while fibonacci.count < 30 { fibonacci.append(fibonacci[fibonacci.count - 1] + fibonacci[fibonacci.count - 2]) }
        for limit in [7, 15] {
            let lengths = WebGzip.lengths(fibonacci, limit: limit)
            #expect(lengths.allSatisfy { $0 >= 1 && $0 <= limit }, "\(lengths)")
            // Kraft's sum is exactly one: a complete code.
            let kraft = lengths.reduce(0.0) { $0 + pow(2.0, -Double($1)) }
            #expect(abs(kraft - 1) < 1e-12, "\(lengths)")
        }
        // One symbol used: a complete two-symbol code all the same.
        #expect(WebGzip.lengths([0, 0, 5, 0], limit: 15) == [1, 0, 1, 0])
    }
}
