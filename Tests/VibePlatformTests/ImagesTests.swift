import Foundation
import Testing
@testable import VibePlatform

/// `Platform.Images`: an image's size in pixels, read by the system's own reader (ImageIO on the Mac, the file's
/// header on Linux), and the header reader itself, which is the same code on both. The images are written by the
/// tests into the run's scratch folder: each whole and valid (made with Pillow 12.2, checked by reading them back),
/// a few hundred bytes, and wider than high, so a width taken for a height shows.
struct ImagesTests {

    static let fixtures: [(name: String, bytes: [UInt8], width: Int, height: Int)] = [
        ("five-by-three.png", png, 5, 3), ("seven-by-four.gif", gif, 7, 4), ("nine-by-six.jpg", jpeg, 9, 6),
        ("eleven-by-eight.webp", webpLossy, 11, 8), ("thirteen-by-ten.webp", webpLossless, 13, 10),
        ("fifteen-by-twelve.webp", webpExtended, 15, 12),
    ]

    static func write(_ bytes: [UInt8], _ name: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data(bytes).write(to: file)
        return file
    }

    /// "5x3", or "nil".
    static func text(_ size: (width: Int, height: Int)?) -> String {
        size.map { "\($0.width)x\($0.height)" } ?? "nil"
    }

    @Test func pixelSizeReadsPNGJPEGGIFAndWebPHeaders() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        for fixture in Self.fixtures {
            let file = try Self.write(fixture.bytes, fixture.name, in: folder)
            let expected = "\(fixture.width)x\(fixture.height)"
            // The system's reader, and the header reader on its own.
            #expect(Self.text(Platform.Images.pixelSize(of: file)) == expected, "\(fixture.name)")
            #expect(Self.text(Platform.Images.headerSize(of: file)) == expected, "\(fixture.name) by its header")
            // The name says nothing: the bytes do.
            let renamed = try Self.write(fixture.bytes, fixture.name + ".txt", in: folder)
            #expect(Self.text(Platform.Images.headerSize(of: renamed)) == expected, "\(fixture.name) under another name")
        }
    }

    /// A file cut before its size is told is no image, and neither is one cut to nothing; cut just after, the header
    /// reader has all it needs.
    @Test func aTruncatedFileIsNil() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        // For each image, the byte after its width and height: the PNG's IHDR, the GIF's logical screen, the JPEG's
        // frame header (at 89: marker, length, precision, then the two), the three WebP headers.
        let sizeEnds = [24, 10, 98, 30, 25, 30]
        for (fixture, end) in zip(Self.fixtures, sizeEnds) {
            for cut in Set([0, 1, 4, 12, end - 1]).filter({ $0 < end }).sorted() {
                let file = try Self.write(Array(fixture.bytes[0..<cut]), "cut-\(cut)-\(fixture.name)", in: folder)
                #expect(Self.text(Platform.Images.headerSize(of: file)) == "nil", "\(fixture.name) cut at \(cut), by its header")
            }
            // What no reader can know: the file ends before a size is anywhere in it.
            for cut in [0, 1, 4] {
                let file = folder.appendingPathComponent("cut-\(cut)-\(fixture.name)")
                #expect(Self.text(Platform.Images.pixelSize(of: file)) == "nil", "\(fixture.name) cut at \(cut)")
            }
            let enough = try Self.write(Array(fixture.bytes[0..<end]), "cut-\(end)-\(fixture.name)", in: folder)
            #expect(Self.text(Platform.Images.headerSize(of: enough)) == "\(fixture.width)x\(fixture.height)", "\(fixture.name) cut at \(end)")
        }
    }

    @Test func whatIsNoImageIsNil() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = try Self.write(Array("Not an image, whatever its name says.\n".utf8), "notes.png", in: folder)
        let empty = try Self.write([], "empty.jpg", in: folder)
        for file in [text, empty, folder, folder.appendingPathComponent("never-made.png")] {
            #expect(Self.text(Platform.Images.pixelSize(of: file)) == "nil", "\(file.lastPathComponent)")
            #expect(Self.text(Platform.Images.headerSize(of: file)) == "nil", "\(file.lastPathComponent) by its header")
        }
        // Headers that start right and say nothing a size can be made of.
        var zeroWide = Self.png
        zeroWide.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        var noHeaderChunk = Self.png
        noHeaderChunk.replaceSubrange(12..<16, with: Array("IDAT".utf8))
        var zeroScreen = Self.gif
        zeroScreen.replaceSubrange(8..<10, with: [0, 0])
        var otherChunk = Self.webpLossy
        otherChunk.replaceSubrange(12..<16, with: Array("ICCP".utf8))
        var noStartCode = Self.webpLossy
        noStartCode[23] = 0
        var notWebP = Self.webpLossy
        notWebP.replaceSubrange(8..<12, with: Array("WAVE".utf8))
        // A JPEG whose scan starts with no frame header before it (the header is the 13 bytes from 89).
        let noFrame = Array(Self.jpeg[0..<89]) + Array(Self.jpeg[102...])
        for (name, bytes) in [("zero-wide.png", zeroWide), ("no-ihdr.png", noHeaderChunk), ("zero-screen.gif", zeroScreen),
                              ("other-chunk.webp", otherChunk), ("no-start-code.webp", noStartCode), ("riff.wav", notWebP),
                              ("no-frame.jpg", noFrame)] {
            let file = try Self.write(bytes, name, in: folder)
            #expect(Self.text(Platform.Images.headerSize(of: file)) == "nil", "\(name)")
        }
    }

    /// A 50 MB file that starts as a PNG gives its size from its first bytes: the header reader reads 48 of them
    /// (counted), whatever follows. The file is sparse: it takes no room in the scratch folder.
    @Test func aLargeFileIsNotReadWhole() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.write(Self.png, "large.png", in: folder)
        try #require(truncate(file.path, 50 << 20) == 0, "truncate: errno \(errno)")
        var info = stat()
        try #require(stat(file.path, &info) == 0)
        #expect(info.st_size == 50 << 20)

        #expect(Self.text(Platform.Images.pixelSize(of: file)) == "5x3")
        let measured = Platform.Images.measuredHeader(of: file)
        #expect(Self.text(measured.size) == "5x3")
        #expect(measured.bytesRead == 48)
    }

    /// A JPEG's metadata is passed over, not read: with 2 MB of it before the frame header (32 segments of the
    /// largest size, as a camera's EXIF, colour profile and preview are), the reader takes four bytes of each.
    @Test func aJPEGsMetadataIsPassedOverUnread() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        // An APP1 segment of the largest length there is: 0xFFFF, the two length bytes counted.
        let segment: [UInt8] = [0xFF, 0xE1, 0xFF, 0xFF] + [UInt8](repeating: 0x41, count: 0xFFFD)
        let padded = Array(Self.jpeg[0..<2]) + (0..<32).flatMap { _ in segment } + Array(Self.jpeg[2...])
        let measured = Platform.Images.measuredHeader(of: try Self.write(padded, "metadata.jpg", in: folder))
        #expect(Self.text(measured.size) == "9x6")
        #expect(padded.count > 2 << 20)
        // The first 32 bytes, then each segment's marker and length (32 of them and the image's own three), then
        // the frame header's five bytes.
        #expect(measured.bytesRead == 32 + 4 * 35 + 5)

        // The other frame headers a JPEG can have (progressive, SOF2, the commonest), fill bytes before a marker,
        // and a restart marker standing alone before the frame.
        var progressive = Self.jpeg
        progressive[90] = 0xC2
        let filled = Array(Self.jpeg[0..<89]) + [0xFF, 0xFF, 0xFF] + Array(Self.jpeg[89...])
        let restart = Array(Self.jpeg[0..<2]) + [0xFF, 0xD0] + Array(Self.jpeg[2...])
        for (name, bytes) in [("progressive.jpg", progressive), ("filled.jpg", filled), ("restart.jpg", restart)] {
            #expect(Self.text(Platform.Images.headerSize(of: try Self.write(bytes, name, in: folder))) == "9x6", "\(name)")
        }
        // Tables are not frames: a file of Huffman tables without end is given up, after a bounded number of them.
        let tables = Array(Self.jpeg[0..<2]) + (0..<(Platform.Images.mostSegments + 10)).flatMap { _ in [0xFF, 0xC4, 0x00, 0x02] as [UInt8] } + Array(Self.jpeg[2...])
        let endless = Platform.Images.measuredHeader(of: try Self.write(tables, "tables.jpg", in: folder))
        #expect(Self.text(endless.size) == "nil")
        #expect(endless.bytesRead == 32 + 4 * Platform.Images.mostSegments)
    }

    /// A PNG made for an iPhone has Apple's chunk before its header; the size is still the header's.
    @Test func aPNGWithApplesChunkFirstIsRead() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        let apples: [UInt8] = [0, 0, 0, 4] + Array("CgBI".utf8) + [0x50, 0x00, 0x20, 0x02] + [0x2B, 0xD5, 0xB3, 0x7F]
        let file = try Self.write(Array(Self.png[0..<8]) + apples + Array(Self.png[8...]), "iphone.png", in: folder)
        #expect(Self.text(Platform.Images.headerSize(of: file)) == "5x3")
    }

    /// The Mac makes a thumbnail, a PNG no larger than asked; Linux has nothing to make one with and says so.
    @Test func aThumbnailIsAPNGOnTheMacAndNilOnLinux() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try Self.write(Self.jpeg, "nine-by-six.jpg", in: folder)
        let thumbnail = Platform.Images.pngThumbnail(of: file, maxSide: 4)
        #if os(Linux)
        #expect(thumbnail == nil)
        #else
        let made = try #require(thumbnail)
        #expect(Array(made.prefix(8)) == Array(Self.png[0..<8]))
        let size = Platform.Images.headerSize(of: try Self.write(Array(made), "thumbnail.png", in: folder))
        #expect(max(size?.width ?? 0, size?.height ?? 0) == 4, "\(Self.text(size))")
        #endif
        #expect(Platform.Images.pngThumbnail(of: folder.appendingPathComponent("never-made.png"), maxSide: 4) == nil)
    }

    /// A file opened once answers as the three questions asked of its path do: whether it's an image, its size, and
    /// a smaller copy of it (several, from the one opened file: what `KeptImages` asks while it scales one down).
    @Test func anOpenedImageAnswersAsItsPathDoes() throws {
        let folder = try TestScriptLinuxTests.scratch("images")
        defer { try? FileManager.default.removeItem(at: folder) }
        for fixture in Self.fixtures {
            let file = try Self.write(fixture.bytes, fixture.name, in: folder)
            #expect(Platform.Images.isImage(file), "\(fixture.name)")
            let source = try #require(Platform.Images.Source(url: file), "\(fixture.name)")
            #expect(source.hasImage, "\(fixture.name)")
            #expect(Self.text(source.pixelSize) == "\(fixture.width)x\(fixture.height)", "\(fixture.name)")
        }
        let source = try #require(Platform.Images.Source(url: try Self.write(Self.jpeg, "nine-by-six-again.jpg", in: folder)))
        for side in [4, 3, 2] {
            let thumbnail = source.pngThumbnail(maxSide: side)
            #if os(Linux)
            #expect(thumbnail == nil)
            #else
            let made = try #require(thumbnail)
            let size = Platform.Images.headerSize(of: try Self.write(Array(made), "thumbnail-\(side).png", in: folder))
            #expect(max(size?.width ?? 0, size?.height ?? 0) == side, "\(Self.text(size))")
            #endif
        }
        // What is no image: by its path, and opened (when it opens at all).
        let text = try Self.write(Array("Not an image, whatever its name says.\n".utf8), "notes.png", in: folder)
        let empty = try Self.write([], "empty.jpg", in: folder)
        for file in [text, empty, folder, folder.appendingPathComponent("never-made.png")] {
            #expect(!Platform.Images.isImage(file), "\(file.lastPathComponent)")
            let opened = Platform.Images.Source(url: file)
            #expect(opened?.hasImage != true, "\(file.lastPathComponent)")
            #expect(Self.text(opened?.pixelSize ?? nil) == "nil", "\(file.lastPathComponent)")
            #expect(opened?.pngThumbnail(maxSide: 4) == nil, "\(file.lastPathComponent)")
        }
    }

    // MARK: The images

    /// A PNG, 5 wide and 3 high: 8-bit grey, 83 bytes.
    static let png: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03,
        0x08, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x5d, 0x9a, 0x24, 0x00, 0x00, 0x00, 0x1a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0x50, 0x55, 0x55,
        0x55, 0x65, 0xb4, 0x56, 0x55, 0x55, 0x55, 0x65, 0xb1, 0x56, 0x55, 0x55, 0x55, 0x05, 0x00, 0x12, 0xb6, 0x02, 0x39, 0x68, 0x64, 0x29, 0x09, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ]
    /// A GIF (87a), 7 wide and 4 high: 157 bytes.
    static let gif: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x37, 0x61, 0x07, 0x00, 0x04, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x0a, 0x0a, 0x19, 0x19, 0x19, 0x20, 0x20,
        0x20, 0x25, 0x25, 0x25, 0x2f, 0x2f, 0x2f, 0x3b, 0x3b, 0x3b, 0x45, 0x45, 0x45, 0x4a, 0x4a, 0x4a, 0x54, 0x54, 0x54, 0x60, 0x60, 0x60, 0x6a, 0x6a,
        0x6a, 0x6f, 0x6f, 0x6f, 0x76, 0x76, 0x76, 0x85, 0x85, 0x85, 0x8f, 0x8f, 0x8f, 0x94, 0x94, 0x94, 0x9b, 0x9b, 0x9b, 0xaa, 0xaa, 0xaa, 0xb1, 0xb1,
        0xb1, 0xb9, 0xb9, 0xb9, 0xc0, 0xc0, 0xc0, 0xcf, 0xcf, 0xcf, 0xd6, 0xd6, 0xd6, 0xde, 0xde, 0xde, 0xe5, 0xe5, 0xe5, 0xf4, 0xf4, 0xf4, 0xfb, 0xfb,
        0xfb, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x04, 0x00, 0x00, 0x08,
        0x22, 0x00, 0x01, 0x10, 0x40, 0xc0, 0x00, 0x02, 0x05, 0x0c, 0x06, 0x14, 0x38, 0x90, 0x60, 0x41, 0x83, 0x80, 0x06, 0x11, 0x2a, 0x64, 0x08, 0x50,
        0x20, 0xc1, 0x84, 0x0b, 0x1b, 0x06, 0x1c, 0x58, 0xf0, 0x20, 0x20, 0x00, 0x3b,
    ]
    /// A baseline JPEG (SOF0), 9 wide and 6 high: one grey component, 197 bytes. Its frame header is at byte 89, after
    /// the JFIF segment and a quantization table.
    static let jpeg: [UInt8] = [
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
        0x00, 0x1b, 0x12, 0x14, 0x17, 0x14, 0x11, 0x1b, 0x17, 0x16, 0x17, 0x1e, 0x1c, 0x1b, 0x20, 0x28, 0x42, 0x2b, 0x28, 0x25, 0x25, 0x28, 0x51, 0x3a,
        0x3d, 0x30, 0x42, 0x60, 0x55, 0x65, 0x64, 0x5f, 0x55, 0x5d, 0x5b, 0x6a, 0x78, 0x99, 0x81, 0x6a, 0x71, 0x90, 0x73, 0x5b, 0x5d, 0x85, 0xb5, 0x86,
        0x90, 0x9e, 0xa3, 0xab, 0xad, 0xab, 0x67, 0x80, 0xbc, 0xc9, 0xba, 0xa6, 0xc7, 0x99, 0xa8, 0xab, 0xa4, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x06,
        0x00, 0x09, 0x01, 0x01, 0x11, 0x00, 0xff, 0xc4, 0x00, 0x15, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x02, 0x03, 0xff, 0xc4, 0x00, 0x21, 0x10, 0x00, 0x02, 0x00, 0x04, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x02, 0x00, 0x03, 0x04, 0x71, 0x11, 0x13, 0x14, 0x31, 0x54, 0x81, 0x93, 0xe2, 0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00,
        0x3f, 0x00, 0x0a, 0x65, 0x69, 0x19, 0xd5, 0x4c, 0xaa, 0x55, 0x18, 0x32, 0xa8, 0x05, 0xdc, 0x12, 0x07, 0x56, 0xbe, 0xf1, 0x1c, 0xca, 0x7e, 0x0a,
        0xfa, 0xfc, 0xc7, 0xff, 0xd9,
    ]
    /// A lossy WebP (a `VP8 ` chunk), 11 wide and 8 high: 88 bytes.
    static let webpLossy: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, 0x50, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20, 0x44, 0x00, 0x00, 0x00, 0xf0, 0x01, 0x00, 0x9d,
        0x01, 0x2a, 0x0b, 0x00, 0x08, 0x00, 0x05, 0x40, 0x7c, 0x25, 0xb0, 0x02, 0x74, 0x01, 0x1f, 0x50, 0xe1, 0x2e, 0xef, 0x00, 0x00, 0xfa, 0x3e, 0x41,
        0x17, 0x76, 0x09, 0xdb, 0x58, 0xa5, 0x6a, 0x32, 0xd5, 0xa3, 0x89, 0xbb, 0x72, 0xd6, 0xaa, 0x69, 0x6f, 0xd3, 0x05, 0x7b, 0xa0, 0x11, 0x7e, 0x04,
        0xda, 0xe8, 0xba, 0x0e, 0x94, 0x60, 0xf8, 0x55, 0x67, 0x19, 0x91, 0x60, 0x54, 0x20, 0x00, 0x00,
    ]
    /// A lossless WebP (`VP8L`), 13 wide and 10 high: 54 bytes.
    static let webpLossless: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, 0x2e, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c, 0x22, 0x00, 0x00, 0x00, 0x2f, 0x0c, 0x40, 0x02,
        0x00, 0xb9, 0x8c, 0xe8, 0x7f, 0xec, 0x22, 0xfa, 0xdd, 0xff, 0x00, 0x91, 0xb6, 0x8d, 0x7f, 0x61, 0x53, 0x31, 0x31, 0x63, 0x67, 0xe7, 0xfd, 0x1f,
        0x8a, 0x98, 0x80, 0x78, 0xc6, 0x27,
    ]
    /// An extended WebP (`VP8X`: a lossy image with an alpha chunk), its canvas 15 wide and 12 high: 154 bytes.
    static let webpExtended: [UInt8] = [
        0x52, 0x49, 0x46, 0x46, 0x92, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58, 0x0a, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
        0x0e, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x41, 0x4c, 0x50, 0x48, 0x16, 0x00, 0x00, 0x00, 0x01, 0xb9, 0x0a, 0x44, 0xf4, 0x3f, 0x40, 0xa4, 0x6d, 0x33,
        0x38, 0xd9, 0x73, 0x7f, 0x76, 0x1c, 0x31, 0x01, 0x59, 0x0d, 0x7c, 0x04, 0x56, 0x50, 0x38, 0x20, 0x56, 0x00, 0x00, 0x00, 0x30, 0x02, 0x00, 0x9d,
        0x01, 0x2a, 0x0f, 0x00, 0x0c, 0x00, 0x05, 0x40, 0x7c, 0x25, 0xb0, 0x02, 0x74, 0x30, 0x43, 0x41, 0xa9, 0xfd, 0xdb, 0x89, 0xc0, 0x00, 0x00, 0xf3,
        0xfc, 0xbc, 0x14, 0x73, 0x09, 0x23, 0x85, 0xf0, 0x45, 0xe9, 0x85, 0x0a, 0x07, 0x62, 0x53, 0x67, 0x57, 0xc9, 0x4e, 0xb1, 0xbf, 0xdf, 0x7a, 0x47,
        0xf8, 0x90, 0xe3, 0x79, 0xa6, 0x26, 0x3c, 0x9f, 0xa2, 0x34, 0x7e, 0x17, 0xc6, 0x31, 0x8e, 0x48, 0x33, 0x11, 0xc0, 0x00, 0x79, 0x3f, 0xe6, 0xb0,
        0x25, 0xfa, 0x8d, 0x56, 0xbf, 0x8d, 0x47, 0x00, 0x00, 0x00,
    ]
}
