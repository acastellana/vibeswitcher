import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VibeSwitcher

/// The app's logo, drawn by scripts/app-icon.sh: the Mac app's AppIcon.icns, named in Info.plist, and the phone web
/// app's icons, served from Web/ as they were drawn.
struct AppIconTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The served PNG at `path`, decoded to RGBA rows (top row first).
    private func served(_ path: String) throws -> (response: HTTPResponse, image: CGImage, pixels: [UInt8]) {
        let response = try #require(WebAssets.response(for: path))
        let source = try #require(CGImageSourceCreateWithData(response.body as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (response, image, pixels)
    }

    @Test(arguments: [192, 512]) func thePhoneIconIsTheLogoAsDrawn(size: Int) throws {
        let (response, image, _) = try served("/icon-\(size).png")
        #expect(response.status == 200 && response.contentType == "image/png")
        #expect(response.body == (try Data(contentsOf: Self.repo.appendingPathComponent("Web/icon-\(size).png"))))
        #expect(image.width == size && image.height == size)
        // Opaque: a phone cuts its own shape out of a maskable icon, and shows any transparency as black or white.
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo))
    }

    /// A maskable icon keeps what matters in the central circle, 80 % of the side across: a phone may cut away all the
    /// rest. Outside it, each row is the background's gradient alone (one colour across the row), with no part of the
    /// cards or their shadows; inside it, the logo covers a good share of the circle.
    @Test func the512IconKeepsTheLogoInsideTheMaskableSafeZone() throws {
        let (_, image, pixels) = try served("/icon-512.png")
        let side = image.width, center = Double(side) / 2, safe = 0.4 * Double(side)
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(pixels[(y * side + x) * 4 + $0]) } }
        func distance(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max()! }
        var outside = 0, firstOutside: [String] = [], logo = 0, inside = 0
        for y in 0..<side {
            let background = pixel(0, y)
            for x in 0..<side {
                let r = hypot(Double(x) + 0.5 - center, Double(y) + 0.5 - center)
                let difference = distance(pixel(x, y), background)
                if r > safe {
                    if difference > 2 {
                        outside += 1
                        if firstOutside.count < 10 { firstOutside.append("(\(x), \(y))") }
                    }
                } else {
                    inside += 1
                    if difference > 40 { logo += 1 }
                }
            }
        }
        #expect(outside == 0, "\(outside) pixels drawn outside the safe zone, first at \(firstOutside.joined(separator: ", "))")
        #expect(Double(logo) / Double(inside) > 0.3, "the logo covers \(logo) of the \(inside) pixels in the safe zone")
    }

    @Test func theMacAppNamesItsIconAndTheIconIsThere() throws {
        let plist = try #require(NSDictionary(contentsOf: Self.repo.appendingPathComponent("Resources/Info.plist")))
        let name = try #require(plist["CFBundleIconFile"] as? String)
        let icns = try Data(contentsOf: Self.repo.appendingPathComponent("Resources/\(name).icns"))
        #expect(icns.prefix(4) == Data("icns".utf8))
    }
}
