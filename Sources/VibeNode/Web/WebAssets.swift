import Foundation
import VibeCore

/// What the web listener answers a `GET` with, once `If-None-Match` is weighed: 200 with the file, or 304 with no body.
public struct WebAssetResponse: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [(String, String)]
}

/// The rules of the page's files (the live plan's C1, LW-D9): which are served and as what, their `ETag`s, the build,
/// and the paths they're served at. A path is matched whole against the list, never decoded or normalised:
///
/// - `/` and `/index.html`: the page, its own files named by their build's paths (below); revalidated every time.
/// - `/build.json`: `{"assets":"<build>"}`, what the page compares with `hello.assets`; revalidated.
/// - `/_/<build>/<path>`: a file of this build, kept by the browser for good (`immutable`). A module's relative import
///   resolves under the same prefix, so the whole page after the first load is read from the cache. Another build's
///   prefix is 404: its page is stale and reloads.
/// - `/<path>`: the same file by its plain path, revalidated (`bench/bench.html`'s files, a bookmark).
///
/// A query (`?mock`) is the page's and is left off before matching.
public enum WebAssets {
    /// The fixed table: a file of another type is neither embedded nor served. No SVG (it runs script), and HTML only
    /// as `index.html` and `bench/bench.html` (`embeddable`). `scripts/webapp-embed.sh` holds the same list.
    public static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "png": "image/png",
        "ico": "image/x-icon",
        "woff2": "font/woff2",
    ]

    /// The HTML files there may be.
    public static let pages: Set<String> = ["index.html", "bench/bench.html"]

    /// Left out of what is embedded, with what's under them: Node's tests of the page and its screenshots.
    public static let leftOut: Set<String> = ["shots", "test", "tests"]

    /// The first load's budget (500 ms) wants small files (`WebAssetsTests.theEmbeddedFilesStaySmall`).
    public static let maxFileBytes = 256 * 1024
    public static let maxTotalBytes = 1024 * 1024
    /// What the page vendors (`WebApp/vendor/`: xterm.js, slice 4) loads only with a terminal, never at the first load:
    /// a file there may be up to 512 KiB (xterm.js 6.0.0 is 337 KiB). It still counts in `maxTotalBytes`.
    public static let vendorFolder = "vendor/"
    public static let maxVendoredFileBytes = 512 * 1024

    /// Where a build's files are kept for good: `/_/<build>/<path>`.
    public static let buildPrefix = "/_/"

    public static func contentType(of path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return contentTypes[String(name[name.index(after: dot)...])]
    }

    /// Whether a relative path is one the generator embeds and a test root serves: a name of the safe characters, no
    /// part empty or a dotfile, outside `leftOut`, its type in the table, HTML only as one of `pages`.
    public static func embeddable(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }), !leftOut.contains(String(parts[0])),
              path.utf8.allSatisfy({ safe.contains($0) }), let type = contentType(of: path) else { return false }
        return !type.hasPrefix("text/html") || pages.contains(path)
    }

    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-".utf8)

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A strong validator: the first 128 bits of the body's SHA-256, quoted.
    public static func etag(of body: Data) -> String { etag(sha256: sha256(body)) }

    static func etag(sha256: String) -> String { "\"\(sha256.prefix(32))\"" }

    /// The first 8 hex of the SHA-256 of each `<path> <sha256>\n`, sorted by path.
    public static func build(of files: [(path: String, sha256: String)]) -> String {
        let listed = files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }.map { "\($0.path) \($0.sha256)\n" }.joined()
        return String(sha256(Data(listed.utf8)).prefix(8))
    }

    /// 304 with no body (and no `Content-Type`) when `ifNoneMatch` names the asset's `ETag` (weak or strong, in a
    /// list) or is `*`; else 200 with the asset.
    public static func response(to asset: WebAsset, ifNoneMatch: String?) -> WebAssetResponse {
        let etag = asset.headers.first { $0.0 == "ETag" }?.1
        let given = (ifNoneMatch ?? "").split(separator: ",").map { tag -> Substring in
            let tag = Substring(tag.trimmingCharacters(in: .whitespaces))
            return tag.hasPrefix("W/") ? tag.dropFirst(2) : tag
        }
        guard let etag, given.contains(where: { $0 == "*" || $0 == etag }) else {
            return WebAssetResponse(status: 200, body: asset.body, headers: asset.headers)
        }
        return WebAssetResponse(status: 304, body: Data(), headers: asset.headers.filter { $0.0 != "Content-Type" })
    }
}

/// A set of the page's files and what they're served as: the embedded files once, a test root's at each request.
struct WebAssetTable: Sendable {
    struct Entry: Sendable {
        var body: Data
        var sha256: String
        var contentType: String
    }

    let entries: [String: Entry]
    let build: String
    /// `index.html` with its own files named by this build's paths, and its hash.
    let index: Entry?
    let buildFile: Entry

    /// From relative paths that are `WebAssets.embeddable`, with their bodies and hashes.
    init(files: [(path: String, sha256: String, body: Data)]) {
        var entries: [String: Entry] = [:]
        for file in files {
            guard let type = WebAssets.contentType(of: file.path) else { continue }
            entries[file.path] = Entry(body: file.body, sha256: file.sha256, contentType: type)
        }
        self.entries = entries
        let build = WebAssets.build(of: entries.map { ($0.key, $0.value.sha256) })
        self.build = build
        index = entries["index.html"].map { page in
            let body = Data(Self.named(String(decoding: page.body, as: UTF8.self), files: entries, build: build).utf8)
            return Entry(body: body, sha256: WebAssets.sha256(body), contentType: page.contentType)
        }
        let json = Data(#"{"assets":"\#(build)"}"#.utf8)
        buildFile = Entry(body: json, sha256: WebAssets.sha256(json), contentType: "application/json")
    }

    func asset(path target: String, port: UInt16, host: String = "127.0.0.1") -> WebAsset? {
        let path = target.firstIndex(of: "?").map { String(target[..<$0]) } ?? target
        func served(_ entry: Entry?, _ caching: WebSecurityHeaders.Caching) -> WebAsset? {
            entry.map {
                WebAsset(body: $0.body, headers: WebSecurityHeaders.all(port: port, host: host, contentType: $0.contentType,
                                                                        etag: WebAssets.etag(sha256: $0.sha256), caching: caching))
            }
        }
        switch path {
        case "/", "/index.html": return served(index, .revalidate)
        case "/build.json": return served(buildFile, .revalidate)
        default: break
        }
        guard path.hasPrefix("/") else { return nil }
        if path.hasPrefix(WebAssets.buildPrefix) {
            let rest = path.dropFirst(WebAssets.buildPrefix.count)
            guard rest.hasPrefix(build + "/") else { return nil }
            let file = String(rest.dropFirst(build.count + 1))
            guard file != "index.html" else { return nil }
            return served(entries[file], .immutable)
        }
        return served(entries[String(path.dropFirst())], .revalidate)
    }

    /// `html` with each `src="…"` and `href="…"` that names one of `files` (as `x` or `./x`) given as
    /// `/_/<build>/x`. Any other value is left as it is.
    static func named(_ html: String, files: [String: Entry], build: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let next = [rest.firstRange(of: #"src=""#), rest.firstRange(of: #"href=""#)].compactMap({ $0 })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            out += rest[..<next.upperBound]
            rest = rest[next.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            let value = rest[..<close]
            let file = value.hasPrefix("./") ? String(value.dropFirst(2)) : String(value)
            out += files[file] != nil && file != "index.html" ? "\(WebAssets.buildPrefix)\(build)/\(file)" : String(value)
            rest = rest[close...]
        }
        return out + rest
    }
}

/// The page's files as built into the server (`WebAssets.generated.swift`, made by `scripts/webapp-embed.sh`): what the
/// user's node serves, with no file read from disk (rule 10).
public struct EmbeddedAssets: WebAssetSource {
    /// One embedded file: its path under `WebApp/`, its SHA-256 (hex) and its bytes.
    struct File: Sendable {
        var path: String
        var sha256: String
        var body: Data

        /// What the generated file writes: the body as base64 in lines.
        init(path: String, sha256: String, base64: String) {
            self.path = path
            self.sha256 = sha256
            body = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        }
    }

    /// The embedded files, sorted by path (decoded once).
    static var files: [File] { embedded }

    private static let table = WebAssetTable(files: embedded.map { ($0.path, $0.sha256, $0.body) })

    /// The build of the embedded files: `/build.json`'s `assets` and `hello.assets`.
    public static var build: String { table.build }

    private let port: UInt16
    private let host: String

    /// `port` and `host` are the listener's, for the policy's `connect-src`.
    public init(port: UInt16, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }

    public func asset(path: String) -> WebAsset? {
        Self.table.asset(path: path, port: port, host: host)
    }
}

/// A folder served in place of the embedded files (a scratch server's `--test-web-root=`), so the web lane sees a
/// change at the next load with no step between. Read whole at each request, with the generator's rules: only
/// `WebAssets.embeddable` plain files, no link followed, nothing outside the folder. The same headers as the embedded.
public struct FolderAssets: WebAssetSource {
    public let root: URL
    private let port: UInt16
    private let host: String

    public init(root: URL, port: UInt16, host: String = "127.0.0.1") {
        self.root = root
        self.port = port
        self.host = host
    }

    /// The folder's build as it is now; nil when it can't be read.
    public var build: String? { table()?.build }

    public func asset(path: String) -> WebAsset? {
        table()?.asset(path: path, port: port, host: host)
    }

    private func table() -> WebAssetTable? {
        var files: [(path: String, sha256: String, body: Data)] = []
        guard walk(root, under: "", into: &files) else { return nil }
        return WebAssetTable(files: files)
    }

    /// Adds `folder`'s embeddable files, then its folders' (never through a link): whether `folder` could be listed.
    private func walk(_ folder: URL, under prefix: String, into files: inout [(path: String, sha256: String, body: Data)]) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            let path = prefix + name
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if type == .typeDirectory, !(prefix.isEmpty && WebAssets.leftOut.contains(name)) {
                _ = walk(url, under: path + "/", into: &files)
            } else if type == .typeRegular, WebAssets.embeddable(path), let body = try? Data(contentsOf: url) {
                files.append((path, WebAssets.sha256(body), body))
            }
        }
        return true
    }
}
