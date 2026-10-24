import AppKit
import ImageIO

/// How big the image viewer (`ImageViewer`) opens. A sheet doesn't come up at its content's ideal size: its window
/// starts at the content's minimum (640 × 420 for the old `.frame(minWidth:idealWidth:…)`), and a two-axis scroll view
/// showed the image at its own size inside that, cut off. So the viewer gets an exact size, worked out here before
/// it's presented: the whole image, scaled down to fit the room it has, never up past 1 image pixel per point.
enum ImageViewerLayout {
    /// The Copy / Save… / Done bar, and the divider under it.
    static let barHeight: CGFloat = 44
    static let chrome = barHeight + 1
    /// Around the image.
    static let padding: CGFloat = 12
    /// The least the viewer takes, so the bar's buttons fit whatever the image.
    static let minimum = CGSize(width: 440, height: 200)
    /// Of the room the window (or screen) gives, what the viewer may take.
    static let share: CGFloat = 0.9

    struct Size: Equatable {
        /// The viewer's whole content: bar, divider and image area.
        var content: CGSize
        /// The image within it, at the scale it's shown.
        var image: CGSize
        /// Whether the image is shown smaller than its own size (`Actual Size` then shows it 1:1).
        var scaled: Bool
    }

    /// The viewer for an image of `image` pixels (nil: unknown), given at most `room` (`room(window:screen:)`).
    static func size(image: CGSize?, room: CGSize) -> Size {
        let room = CGSize(width: max(room.width, minimum.width), height: max(room.height, minimum.height))
        guard let image, image.width > 0, image.height > 0 else {
            return Size(content: CGSize(width: min(room.width, 1000), height: min(room.height, 720)), image: .zero, scaled: false)
        }
        let area = CGSize(width: room.width - 2 * padding, height: room.height - chrome - 2 * padding)
        let scale = min(1, area.width / image.width, area.height / image.height)
        let shown = CGSize(width: max(1, (image.width * scale).rounded(.down)), height: max(1, (image.height * scale).rounded(.down)))
        let content = CGSize(width: max(shown.width + 2 * padding, minimum.width),
                             height: max(shown.height + chrome + 2 * padding, minimum.height))
        return Size(content: content, image: shown, scaled: scale < 1)
    }

    /// The room for the viewer: the window it opens from or its screen's visible area, whichever is bigger (each way),
    /// less a margin.
    static func room(window: CGSize?, screen: CGSize?) -> CGSize {
        let width = max(window?.width ?? 0, screen?.width ?? 0), height = max(window?.height ?? 0, screen?.height ?? 0)
        guard width > 0, height > 0 else { return CGSize(width: 1200, height: 800) }
        return CGSize(width: (width * share).rounded(.down), height: (height * share).rounded(.down))
    }

    /// `room(window:screen:)` for a window (nil: the main screen alone).
    @MainActor
    static func room(over window: NSWindow?) -> CGSize {
        room(window: window?.frame.size, screen: (window?.screen ?? NSScreen.main)?.visibleFrame.size)
    }

    /// The image's size in pixels as shown (EXIF orientation applied), read from its header without decoding it.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // Orientations 5–8 turn the image a quarter.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
