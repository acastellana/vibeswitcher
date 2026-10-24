import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The image viewer's size (`ImageViewerLayout`): the whole image, fitted to the room it has, never past 1:1, never
/// narrower than its bar.
@MainActor
struct ImageViewerLayoutTests {
    /// What a 1400 × 900 main window gives, alone.
    let room = ImageViewerLayout.room(window: CGSize(width: 1400, height: 900), screen: nil)

    @Test func roomIsTheBiggerOfWindowAndScreenLessAMargin() {
        #expect(room == CGSize(width: 1260, height: 810))
        #expect(ImageViewerLayout.room(window: CGSize(width: 800, height: 600), screen: CGSize(width: 1512, height: 945))
                == CGSize(width: 1360, height: 850))
        #expect(ImageViewerLayout.room(window: CGSize(width: 2000, height: 600), screen: CGSize(width: 1512, height: 945))
                == CGSize(width: 1800, height: 850))
        #expect(ImageViewerLayout.room(window: nil, screen: nil).width > 0)
    }

    @Test func wideImageFitsTheWidthKeepingItsShape() {
        let size = ImageViewerLayout.size(image: CGSize(width: 1776, height: 376), room: room)
        #expect(size.content.width <= room.width && size.content.height <= room.height)
        #expect(size.content.width >= room.width - 1, "a wide image takes the width it has")
        #expect(size.scaled)
        #expect(abs(size.image.width / size.image.height - 1776.0 / 376) < 0.02)
        #expect(size.image.width + 2 * ImageViewerLayout.padding <= size.content.width)
        #expect(size.image.height + ImageViewerLayout.chrome + 2 * ImageViewerLayout.padding <= size.content.height)
    }

    @Test func tallImageFitsTheHeightKeepingItsShape() {
        let size = ImageViewerLayout.size(image: CGSize(width: 1200, height: 2400), room: room)
        #expect(size.content.height <= room.height && size.content.height >= room.height - 1)
        #expect(size.content.width <= room.width)
        #expect(size.scaled)
        #expect(abs(size.image.width / size.image.height - 0.5) < 0.01)
        #expect(size.image.height + ImageViewerLayout.chrome + 2 * ImageViewerLayout.padding <= size.content.height)
    }

    @Test func smallImageShowsAtItsOwnSize() {
        let size = ImageViewerLayout.size(image: CGSize(width: 300, height: 200), room: room)
        #expect(size.image == CGSize(width: 300, height: 200))
        #expect(!size.scaled)
        // Wide enough for the bar, though the image is narrower.
        #expect(size.content == CGSize(width: ImageViewerLayout.minimum.width,
                                       height: 200 + ImageViewerLayout.chrome + 2 * ImageViewerLayout.padding))
    }

    @Test func tinyImageStillGetsTheBar() {
        let size = ImageViewerLayout.size(image: CGSize(width: 16, height: 16), room: room)
        #expect(size.image == CGSize(width: 16, height: 16))
        #expect(size.content == ImageViewerLayout.minimum)
    }

    @Test func tinyRoomKeepsTheMinimum() {
        let size = ImageViewerLayout.size(image: CGSize(width: 4000, height: 3000), room: CGSize(width: 200, height: 100))
        #expect(size.content.width >= ImageViewerLayout.minimum.width && size.content.height >= ImageViewerLayout.minimum.height)
        #expect(abs(size.image.width / size.image.height - 4.0 / 3) < 0.05)
    }

    @Test func unknownSizeGetsAUsefulBox() {
        let size = ImageViewerLayout.size(image: nil, room: room)
        #expect(size.content == CGSize(width: 1000, height: 720))
        #expect(ImageViewerLayout.size(image: CGSize(width: 0, height: 10), room: room).content == CGSize(width: 1000, height: 720))
    }

    @Test func pixelSizeComesFromTheHeader() throws {
        #expect(ImageViewerLayout.pixelSize(try Self.png(width: 1776, height: 376)) == CGSize(width: 1776, height: 376))
        #expect(ImageViewerLayout.pixelSize(Data("not an image".utf8)) == nil)
    }

    /// The bug: a sheet's window came up at the content's minimum (640 × 420), not its ideal. The viewer's window now
    /// comes up at exactly the size worked out for its image.
    @Test func hostedViewerComesUpAtItsSize() async throws {
        for (width, height) in [(1776, 376), (1200, 2400), (300, 200)] {
            let image = ChatImage(id: "viewer-\(width)x\(height)", mediaType: "image/png", data: try Self.png(width: width, height: height))
            let expected = ImageViewerLayout.size(image: CGSize(width: width, height: height), room: room).content
            let controller = NSHostingController(rootView: ImageViewer(image: image, room: room) {})
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 10, height: 10), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFrontRegardless()
            defer { window.close() }
            let ok = await until { window.contentLayoutRect.size == expected }
            #expect(ok, "\(width)×\(height): window \(window.contentLayoutRect.size), expected \(expected)")
        }
    }

    // MARK: Snapshots

    nonisolated static let folder = ProcessInfo.processInfo.environment["IMAGE_VIEWER_SNAPSHOT_DIR"]

    /// The viewer over a 1400 × 900 main window, for a wide, a tall and a small image, light and dark. Only with
    /// `IMAGE_VIEWER_SNAPSHOT_DIR=/some/folder`.
    @Test(.enabled(if: folder != nil)) func drawViewer() throws {
        let folder = try #require(Self.folder)
        for (name, width, height) in [("wide", 1776, 376), ("tall", 1200, 2400), ("small", 300, 200)] {
            let data = try Self.png(width: width, height: height, marked: true)
            let image = ChatImage(id: "snapshot-\(name)", mediaType: "image/png", data: data)
            let full = try #require(NSImage(data: data))
            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                let view = ZStack(alignment: .top) {
                    Color(nsColor: .underPageBackgroundColor)
                    ImageViewer(image: image, room: room, full: full) {}
                        .background(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 12)
                }
                .frame(width: 1400, height: 900)
                let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1400, height: 900), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder)
                    .appendingPathComponent("image-viewer-\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
            }
        }
    }

    /// A PNG of `width` × `height` pixels; `marked`: with a border, diagonals and its size written in the middle, so a
    /// picture shows whether any of it is cut off.
    static func png(width: Int, height: Int, marked: Bool = false) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        if marked {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let bounds = NSRect(x: 0, y: 0, width: width, height: height)
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: bounds, angle: 30)
            let lines = NSBezierPath()
            lines.move(to: .zero); lines.line(to: NSPoint(x: width, y: height))
            lines.move(to: NSPoint(x: 0, y: height)); lines.line(to: NSPoint(x: width, y: 0))
            lines.lineWidth = 3
            NSColor.white.withAlphaComponent(0.6).setStroke()
            lines.stroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            border.lineWidth = 8
            NSColor.systemRed.setStroke()
            border.stroke()
            let label = "\(width) × \(height)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(min(width, height)) / 6),
                                                             .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
