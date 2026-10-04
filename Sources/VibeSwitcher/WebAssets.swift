import CryptoKit
import AppKit
import VibeCore

/// The phone web app: static files from `Web/` (copied into the app's Resources by build-app.sh),
/// plus icons drawn here. Only this fixed list of paths is ever served.
enum WebAssets {
    private static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/style.css": ("style.css", "text/css; charset=utf-8"),
        "/sw.js": ("sw.js", "text/javascript; charset=utf-8"),
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    ]

    /// A short fingerprint of the web app's files: changes when an update serves a different app.
    static let version: String = {
        guard let directory else { return "" }
        var data = Data()
        for name in Set(files.values.map(\.name)).sorted() {
            data.append((try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data())
        }
        return Base64URL.encode(Data(SHA256.hash(data: data)).prefix(9))
    }()

    static func response(for path: String) -> HTTPResponse? {
        if path == "/icon-192.png" { return icon(192) }
        if path == "/icon-512.png" { return icon(512) }
        guard let file = files[path], let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(file.name))
        else { return nil }
        return HTTPResponse(status: 200, contentType: file.type, body: data, cacheable: true)
    }

    private static var directory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // `swift run` during development: the repo's Web folder.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Web")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    private static var iconCache: [Int: Data] = [:]

    /// Status dots on a dark rounded square, like the menu bar icon.
    private static func icon(_ size: Int) -> HTTPResponse? {
        if let cached = iconCache[size] { return HTTPResponse(status: 200, contentType: "image/png", body: cached, cacheable: true) }
        let side = CGFloat(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: side * 0.22, yRadius: side * 0.22).fill()
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemBlue, .systemGreen]
        let dot = side * 0.17, gap = side * 0.07
        let start = (side - (dot * 2 + gap)) / 2
        for (index, color) in colors.enumerated() {
            color.setFill()
            let x = start + CGFloat(index % 2) * (dot + gap), y = start + CGFloat(1 - index / 2) * (dot + gap)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache[size] = png
        return HTTPResponse(status: 200, contentType: "image/png", body: png, cacheable: true)
    }
}
