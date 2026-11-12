import Foundation

extension Platform {
    /// What the shared code asks of an image file: its size in pixels, and a smaller copy of it.
    ///
    /// - `pixelSize(of:) -> (width: Int, height: Int)?`: the size the file itself states, a photo's turn (its EXIF
    ///   orientation) not applied; nil when the file isn't an image the system reads.
    /// - `pngThumbnail(of:maxSide:) -> Data?`: the image as a PNG whose longer side is at most `maxSide` pixels,
    ///   turned upright; nil when it can't be made.
    ///
    /// The Mac's are ImageIO's (Images+Darwin.swift), which reads every format the Mac shows. Linux has no image
    /// library here: the size is read from the header of a PNG, a GIF, a JPEG or a WebP (`headerSize(of:)`, below),
    /// any other file is no image, and there is no thumbnail: `pngThumbnail` is always nil.
    public enum Images {}
}

#if !canImport(Darwin)
extension Platform.Images {
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        headerSize(of: url)
    }

    public static func pngThumbnail(of url: URL, maxSide: Int) -> Data? {
        nil
    }
}
#endif

extension Platform.Images {
    /// The size the header of the image at `url` states, for a PNG (its IHDR), a GIF (its logical screen), a JPEG
    /// (its frame header) or a WebP (lossy, lossless or extended: the canvas); nil for anything else, for a file cut
    /// short before its size, and for a size of 0. Only the header is read: a few dozen bytes, and for a JPEG four
    /// bytes of each segment before its frame header, whatever the file's length.
    static func headerSize(of url: URL) -> (width: Int, height: Int)? {
        measuredHeader(of: url).size
    }

    /// `headerSize`, and how many bytes of the file were read for it.
    static func measuredHeader(of url: URL) -> (size: (width: Int, height: Int)?, bytesRead: Int) {
        // Not waiting on a pipe someone named like an image: only a regular file is read.
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return (nil, 0) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return (nil, 0) }
        var file = HeaderFile(fd: fd)
        let size = size(in: &file)
        return (size, file.bytesRead)
    }

    /// A file read a few bytes at a place.
    struct HeaderFile {
        let fd: Int32
        private(set) var bytesRead = 0

        init(fd: Int32) {
            self.fd = fd
        }

        /// The `count` bytes at `offset`, or as many as the file has from there.
        mutating func upTo(_ count: Int, at offset: Int64) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var have = 0
            while have < count {
                let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + have, count - have, off_t(offset) + off_t(have)) }
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { break }
                have += got
            }
            bytesRead += have
            return Array(bytes[0..<have])
        }

        /// The `count` bytes at `offset`; nil when the file ends before them.
        mutating func exactly(_ count: Int, at offset: Int64) -> [UInt8]? {
            let bytes = upTo(count, at: offset)
            return bytes.count == count ? bytes : nil
        }
    }

    /// How many JPEG segments are passed over in search of the frame header before the file is given up: a real
    /// file has a few dozen at most (its metadata, its tables).
    static let mostSegments = 1_024

    private static func size(in file: inout HeaderFile) -> (width: Int, height: Int)? {
        // Enough for every header but a JPEG's, whose frame header comes after its metadata.
        let head = file.upTo(32, at: 0)
        func little16(_ at: Int) -> Int { Int(head[at]) | Int(head[at + 1]) << 8 }
        func little24(_ at: Int) -> Int { little16(at) | Int(head[at + 2]) << 16 }
        func starts(_ bytes: [UInt8], at: Int = 0) -> Bool { head.count >= at + bytes.count && Array(head[at..<at + bytes.count]) == bytes }
        func sized(_ width: Int, _ height: Int) -> (width: Int, height: Int)? {
            width > 0 && height > 0 ? (width, height) : nil
        }

        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            // Chunks: a length, a type, the data, a checksum. IHDR is the first, but for a PNG made for an iPhone,
            // which has Apple's CgBI before it.
            var offset: Int64 = 8
            for _ in 0..<2 {
                guard let chunk = file.exactly(16, at: offset) else { return nil }
                func big32(_ at: Int) -> Int { Int(chunk[at]) << 24 | Int(chunk[at + 1]) << 16 | Int(chunk[at + 2]) << 8 | Int(chunk[at + 3]) }
                let type = Array(chunk[4..<8])
                if type == Array("IHDR".utf8) { return sized(big32(8), big32(12)) }
                guard type == Array("CgBI".utf8) else { return nil }
                offset += 12 + Int64(big32(0))
            }
            return nil
        }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) {
            return head.count >= 10 ? sized(little16(6), little16(8)) : nil
        }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) {
            if starts(Array("VP8 ".utf8), at: 12) {
                // Lossy: a key frame's tag (its first bit 0), the start code, then 14 bits each of width and height.
                guard head.count >= 30, head[20] & 1 == 0, starts([0x9D, 0x01, 0x2A], at: 23) else { return nil }
                return sized(little16(26) & 0x3FFF, little16(28) & 0x3FFF)
            }
            if starts(Array("VP8L".utf8), at: 12) {
                // Lossless: a signature byte, then 14 bits each of width and height less one, and 3 of version.
                guard head.count >= 25, head[20] == 0x2F else { return nil }
                let bits = little16(21) | little16(23) << 16
                guard bits >> 29 == 0 else { return nil }
                return sized((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            }
            if starts(Array("VP8X".utf8), at: 12) {
                // Extended: flags, then the canvas, 24 bits each of width and height less one.
                return head.count >= 30 ? sized(little24(24) + 1, little24(27) + 1) : nil
            }
            return nil
        }
        if starts([0xFF, 0xD8]) { return jpegSize(in: &file) }
        return nil
    }

    /// A JPEG's size, from its frame header (a SOFn segment): each segment before it is passed over by its length,
    /// unread. nil when the scan data starts or the file ends with none found.
    private static func jpegSize(in file: inout HeaderFile) -> (width: Int, height: Int)? {
        var offset: Int64 = 2
        for _ in 0..<mostSegments {
            // A marker (0xFF, its code) and, for most, the segment's length, itself counted in it.
            guard let marker = file.exactly(4, at: offset), marker[0] == 0xFF else { return nil }
            let code = marker[1]
            switch code {
            case 0xFF:
                // A fill byte before the marker.
                offset += 1
            case 0x01, 0xD0...0xD8:
                // Markers that stand alone.
                offset += 2
            case 0x00, 0xD9, 0xDA:
                // No marker, the image's end, the scan's start: no frame header came before.
                return nil
            default:
                let length = Int(marker[2]) << 8 | Int(marker[3])
                guard length >= 2 else { return nil }
                // Start of frame: every 0xC0 to 0xCF but the Huffman tables (C4), JPG (C8) and the arithmetic
                // conditioning (CC). Its data: the sample precision, then the height and the width.
                if (0xC0...0xCF).contains(code), ![0xC4, 0xC8, 0xCC].contains(code) {
                    guard let frame = file.exactly(5, at: offset + 4) else { return nil }
                    let height = Int(frame[1]) << 8 | Int(frame[2]), width = Int(frame[3]) << 8 | Int(frame[4])
                    return width > 0 && height > 0 ? (width, height) : nil
                }
                offset += 2 + Int64(length)
            }
        }
        return nil
    }
}
