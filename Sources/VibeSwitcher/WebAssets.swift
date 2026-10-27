import CryptoKit
import Foundation
import VibeCore

/// The phone web app: static files from `Web/` (copied into the app's Resources by build-app.sh). Only this fixed list
/// of paths is ever served. The icons are the app's logo, drawn by scripts/app-icon.sh.
enum WebAssets {
    private static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/style.css": ("style.css", "text/css; charset=utf-8"),
        "/sw.js": ("sw.js", "text/javascript; charset=utf-8"),
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
        "/icon-192.png": ("icon-192.png", "image/png"),
        "/icon-512.png": ("icon-512.png", "image/png"),
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
}
