import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compares two screenshots pixel by pixel, for scripts/ui-journeys.sh (its command-line helper,
/// scripts/ui-journeys/image-diff.swift, is compiled with this file). A pixel counts as changed when any of its four
/// channels differs by more than `tolerance` (0–255); masked rectangles are never counted. Two images of different
/// sizes differ everywhere.
public enum ImageDiff {
    /// An image as 8-bit RGBA, rows from the top.
    public struct Pixels: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public var rgba: [UInt8]

        public init(width: Int, height: Int, rgba: [UInt8]) {
            precondition(rgba.count == width * height * 4, "rgba holds width × height × 4 bytes")
            (self.width, self.height, self.rgba) = (width, height, rgba)
        }

        /// A `width` × `height` image of one colour.
        public init(width: Int, height: Int, filled color: (UInt8, UInt8, UInt8, UInt8)) {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]) = color
            }
            self.init(width: width, height: height, rgba: bytes)
        }

        /// Paints the rectangle (clipped to the image) one colour.
        public mutating func fill(_ rect: Rect, _ color: (UInt8, UInt8, UInt8, UInt8)) {
            for y in max(0, rect.y)..<min(height, rect.y + rect.height) {
                for x in max(0, rect.x)..<min(width, rect.x + rect.width) {
                    let index = (y * width + x) * 4
                    (rgba[index], rgba[index + 1], rgba[index + 2], rgba[index + 3]) = color
                }
            }
        }
    }

    /// A rectangle in pixels, from the image's top left.
    public struct Rect: Equatable, Sendable {
        public let x, y, width, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { (self.x, self.y, self.width, self.height) = (x, y, width, height) }

        func contains(x px: Int, y py: Int) -> Bool { px >= x && px < x + width && py >= y && py < y + height }
    }

    public struct Result: Equatable, Sendable {
        /// Pixels that differ beyond the tolerance, outside the masks.
        public let changed: Int
        /// Pixels compared (the image's, less the masked ones); the larger image's when the sizes differ.
        public let compared: Int
        /// Whether the two images' sizes differ (then every pixel counts as changed).
        public let sizeDiffers: Bool
        /// The smallest rectangle holding every changed pixel, nil when none changed.
        public let bounds: Rect?

        /// The share of compared pixels that changed, in percent (0–100).
        public var percent: Double { compared == 0 ? 0 : Double(changed) * 100 / Double(compared) }

        /// Whether the change is beyond `threshold` percent of the pixels.
        public func exceeds(threshold: Double) -> Bool { sizeDiffers || percent > threshold }
    }

    /// The default per-channel tolerance: anti-aliasing and colour-space rounding stay under it.
    public static let defaultTolerance = 8
    /// The default threshold, in percent of the pixels.
    public static let defaultThreshold = 0.5

    public static func compare(_ a: Pixels, _ b: Pixels, tolerance: Int = defaultTolerance, masks: [Rect] = []) -> Result {
        guard a.width == b.width, a.height == b.height else {
            let all = max(a.width * a.height, b.width * b.height)
            return Result(changed: all, compared: all, sizeDiffers: true,
                          bounds: Rect(x: 0, y: 0, width: max(a.width, b.width), height: max(a.height, b.height)))
        }
        var changed = 0, compared = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        a.rgba.withUnsafeBufferPointer { pa in
            b.rgba.withUnsafeBufferPointer { pb in
                for y in 0..<a.height {
                    for x in 0..<a.width {
                        if !masks.isEmpty, masks.contains(where: { $0.contains(x: x, y: y) }) { continue }
                        compared += 1
                        let index = (y * a.width + x) * 4
                        var differs = false
                        for channel in 0..<4 where abs(Int(pa[index + channel]) - Int(pb[index + channel])) > tolerance {
                            differs = true
                            break
                        }
                        guard differs else { continue }
                        changed += 1
                        (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                    }
                }
            }
        }
        let bounds = maxX < 0 ? nil : Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Result(changed: changed, compared: compared, sizeDiffers: false, bounds: bounds)
    }

    /// `current` faded to a third, with each changed pixel in solid red and masked areas in grey: where it changed, at a
    /// glance. Nil when the sizes differ.
    public static func diffImage(_ baseline: Pixels, _ current: Pixels, tolerance: Int = defaultTolerance, masks: [Rect] = []) -> Pixels? {
        guard baseline.width == current.width, baseline.height == current.height else { return nil }
        var out = current
        for y in 0..<current.height {
            for x in 0..<current.width {
                let index = (y * current.width + x) * 4
                if masks.contains(where: { $0.contains(x: x, y: y) }) {
                    (out.rgba[index], out.rgba[index + 1], out.rgba[index + 2], out.rgba[index + 3]) = (128, 128, 128, 255)
                    continue
                }
                let differs = (0..<4).contains { abs(Int(baseline.rgba[index + $0]) - Int(current.rgba[index + $0])) > tolerance }
                if differs {
                    (out.rgba[index], out.rgba[index + 1], out.rgba[index + 2], out.rgba[index + 3]) = (255, 0, 0, 255)
                } else {
                    for channel in 0..<3 { out.rgba[index + channel] = UInt8(255 - (255 - Int(current.rgba[index + channel])) / 3) }
                    out.rgba[index + 3] = 255
                }
            }
        }
        return out
    }

    /// The PNG (or any image ImageIO reads) at `url`, as RGBA in sRGB. Nil when it can't be read.
    public static func load(_ url: URL) -> Pixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, rgba: bytes) : nil
    }

    /// `pixels` as a PNG at `url`. False when it couldn't be written.
    @discardableResult
    public static func writePNG(_ pixels: Pixels, to url: URL) -> Bool {
        var bytes = pixels.rgba
        let image: CGImage? = bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                                          bytesPerRow: pixels.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
