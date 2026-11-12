#if canImport(Darwin)
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ImageIO's readings, as `KeptImages` made them before this file (VibeCore's LeadImages.swift).
extension Platform.Images {
    /// The size of the image at `url` in pixels, as stored: ImageIO's `PixelWidth` and `PixelHeight` of its first
    /// image, which don't count a photo's orientation. nil when ImageIO reads no image there.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The image at `url` as a PNG whose longer side is at most `maxSide` pixels, turned as its orientation says
    /// (made from the whole image, never from a thumbnail the file carries); nil when it can't be read or written.
    public static func pngThumbnail(of url: URL, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide]
        let data = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
