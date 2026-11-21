import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The web page's files and their headers (the live plan's C1, LW-D9, and its Security table's rows on the policy, the
/// headers and what is served): `WebApp/` embedded by `scripts/webapp-embed.sh`, served by exact path; `/` revalidated
/// every time, a build's files under `/_/<build>/` kept by the browser for good; and the test root (`FolderAssets`).
struct WebAssetsTests {
    let scratch = Scratch()
    static let port: UInt16 = 47999

    static let policy = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; font-src 'self'; "
        + "connect-src 'self' ws://127.0.0.1:47999; manifest-src 'self'; worker-src 'self'; base-uri 'none'; "
        + "form-action 'none'; frame-ancestors 'none'; require-trusted-types-for 'script'; trusted-types 'none'"

    // MARK: A folder of the test's own, served

    /// A page of three files and a module that imports another, the way `WebApp/` is laid out.
    func page(_ files: [String: String]? = nil) throws -> URL {
        // In a folder of its own, so that what a test puts beside it goes with the scratch.
        let root = scratch.url("webapp").appendingPathComponent("page")
        let given = files ?? [
            "index.html": #"<!doctype html><link rel="stylesheet" href="style.css"><script type="module" src="app.js"></script><a href="https://example.com/">x</a>"#,
            "style.css": "body { margin: 0 }\n",
            "app.js": "import { word } from './js/words.js';\ndocument.title = word;\n",
            "js/words.js": "export const word = 'VibeSwitcher';\n",
        ]
        for (path, text) in given {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    func header(_ name: String, _ asset: WebAsset?) -> [String] {
        (asset?.headers ?? []).filter { $0.0.lowercased() == name.lowercased() }.map(\.1)
    }

    func text(_ asset: WebAsset?) -> String { String(decoding: asset?.body ?? Data(), as: UTF8.self) }

    /// Every path a source serves: its pages, its build's files, `/build.json`.
    func everyPath(_ source: WebAssetSource, files: [String], build: String) -> [String] {
        ["/", "/index.html", "/build.json"] + files.filter { $0 != "index.html" }.flatMap { ["/\($0)", "/_/\(build)/\($0)"] }
    }

    @Test func everyResponseCarriesThePolicy() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let build = try #require(folder.build)
        let embedded = EmbeddedAssets(port: Self.port)
        let served = everyPath(folder, files: ["app.js", "style.css", "js/words.js"], build: build).map { folder.asset(path: $0) }
            + everyPath(embedded, files: EmbeddedAssets.files.map(\.path), build: EmbeddedAssets.build).map { embedded.asset(path: $0) }
        #expect(served.count > 8)
        for asset in served {
            #expect(header("Content-Security-Policy", asset) == [Self.policy])
        }
        #expect(WebSecurityHeaders.policy(port: Self.port) == Self.policy)
    }

    @Test func everyResponseCarriesTheHeaders() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let build = try #require(folder.build)
        for path in everyPath(folder, files: ["app.js", "style.css", "js/words.js"], build: build) {
            let asset = try #require(folder.asset(path: path), "\(path)")
            #expect(header("X-Content-Type-Options", asset) == ["nosniff"], "\(path)")
            #expect(header("X-Frame-Options", asset) == ["DENY"], "\(path)")
            #expect(header("Referrer-Policy", asset) == ["no-referrer"], "\(path)")
            #expect(header("Cross-Origin-Opener-Policy", asset) == ["same-origin"], "\(path)")
            #expect(header("Cross-Origin-Resource-Policy", asset) == ["same-origin"], "\(path)")
            #expect(header("Cache-Control", asset).count == 1, "\(path)")
            #expect(header("Content-Type", asset).count == 1, "\(path)")
            let etag = try #require(header("ETag", asset).first, "\(path)")
            #expect(etag == WebAssets.etag(of: asset.body), "\(path)")
            // No cookie, ever (the contract's §1).
            #expect(header("Set-Cookie", asset).isEmpty)
        }
    }

    /// The page is asked again every time (a new build is seen at once); a build's files are the browser's to keep, since
    /// their path names the build, and the page names its files by that path.
    @Test func theIndexIsRevalidatedAndTheBuildsFilesAreKept() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let build = try #require(folder.build)
        for path in ["/", "/index.html", "/build.json", "/app.js", "/js/words.js"] {
            #expect(header("Cache-Control", folder.asset(path: path)) == ["no-cache"], "\(path)")
        }
        for path in ["/_/\(build)/app.js", "/_/\(build)/style.css", "/_/\(build)/js/words.js"] {
            #expect(header("Cache-Control", folder.asset(path: path)) == ["public, max-age=31536000, immutable"], "\(path)")
        }
        let index = text(folder.asset(path: "/"))
        #expect(index.contains(#"href="/_/\#(build)/style.css""#), "\(index)")
        #expect(index.contains(#"src="/_/\#(build)/app.js""#), "\(index)")
        // Only the page's own files are renamed.
        #expect(index.contains(#"href="https://example.com/""#), "\(index)")
        // The module's relative import resolves under the same build: `/_/<build>/js/words.js`, kept too.
        #expect(text(folder.asset(path: "/_/\(build)/app.js")).contains("./js/words.js"))
    }

    @Test func rootServesIndex() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let root = try #require(folder.asset(path: "/"))
        #expect(root.body == folder.asset(path: "/index.html")?.body)
        #expect(text(root).hasPrefix("<!doctype html>"))
        #expect(header("Content-Type", root) == ["text/html; charset=utf-8"])
        // A query is the page's (`?mock`), not part of the path.
        #expect(folder.asset(path: "/?mock")?.body == root.body)
        #expect(folder.asset(path: "/index.html?mock")?.body == root.body)
        let embedded = EmbeddedAssets(port: Self.port)
        #expect(embedded.asset(path: "/")?.body == embedded.asset(path: "/index.html")?.body)
        #expect(text(embedded.asset(path: "/")).lowercased().hasPrefix("<!doctype html>"))
    }

    @Test func aPathOutsideTheListIs404() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let build = try #require(folder.build)
        #expect(folder.asset(path: "/app.js") != nil)
        let refused = ["/../index.html", "/%2e%2e/index.html", "/%2E%2E/app.js", "//app.js", "/app.js\u{0}", "/app.js\u{0}.png",
                       "/js/../app.js", "/./app.js", "/js//words.js", "app.js", "", "/APP.JS", "/app.js/", "/js", "/js/",
                       "/_/\(build)/", "/_/\(build)/index.html", "/_/\(build)/build.json", "/_/00000000/app.js",
                       "/_/\(build)/../app.js", "/_/\(build)//app.js", "/_/\(build)", "/%61pp.js", "/app.js#x", "/nothing.js"]
        for path in refused {
            #expect(folder.asset(path: path) == nil, "\(path)")
        }
        let embedded = EmbeddedAssets(port: Self.port)
        for path in ["/../index.html", "/%2e%2e/index.html", "//index.html", "/index.html\u{0}", "/_/00000000/index.html"] {
            #expect(embedded.asset(path: path) == nil, "\(path)")
        }
    }

    @Test func aTestRootNeverLeavesItsFolder() throws {
        let outside = scratch.url("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.js"))
        let root = try page()
        try Data("beside".utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("beside.js"))
        // A link out of the folder, to a file and to a folder: neither is followed.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.js"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.js"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        // What the generator leaves out, the test root leaves out too.
        for path in [".hidden.js", "shots/a.png", "test/a.test.mjs", "tests/b.js", "icon.svg", "other.html", "notes.md", "data.xml"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let folder = FolderAssets(root: root, port: Self.port)
        let build = try #require(folder.build)
        for path in ["/linked.js", "/out/secret.js", "/../beside.js", "/../outside/secret.js", "/.hidden.js", "/shots/a.png",
                     "/test/a.test.mjs", "/tests/b.js", "/icon.svg", "/other.html", "/notes.md", "/data.xml",
                     "/_/\(build)/linked.js", "/_/\(build)/out/secret.js"] {
            #expect(folder.asset(path: path) == nil, "\(path)")
        }
        #expect(text(folder.asset(path: "/app.js")).contains("import"))
        // Read at each request: a changed file is served as it is now, under a new build.
        try Data("export const word = 'changed';\n".utf8).write(to: root.appendingPathComponent("js/words.js"))
        #expect(text(folder.asset(path: "/js/words.js")).contains("changed"))
        #expect(folder.build != build)
        // A folder that isn't there serves nothing.
        #expect(FolderAssets(root: scratch.url("missing"), port: Self.port).asset(path: "/") == nil)
    }

    @Test func theContentTypeComesFromTheTable() throws {
        let root = try page()
        for path in ["wire/vectors.json", "manifest.webmanifest", "icon.png", "font.woff2", "bench/bench.html", "x.mjs"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        let folder = FolderAssets(root: root, port: Self.port)
        let expected = ["/app.js": "text/javascript; charset=utf-8", "/x.mjs": "text/javascript; charset=utf-8",
                        "/style.css": "text/css; charset=utf-8", "/index.html": "text/html; charset=utf-8",
                        "/bench/bench.html": "text/html; charset=utf-8", "/wire/vectors.json": "application/json",
                        "/build.json": "application/json", "/manifest.webmanifest": "application/manifest+json",
                        "/icon.png": "image/png", "/font.woff2": "font/woff2"]
        for (path, type) in expected {
            #expect(header("Content-Type", folder.asset(path: path)) == [type], "\(path)")
        }
        #expect(WebAssets.contentType(of: "icon.svg") == nil)
        #expect(WebAssets.contentType(of: "page.htm") == nil)
        #expect(WebAssets.contentType(of: "README") == nil)
        #expect(WebAssets.embeddable("other.html") == false)
        #expect(WebAssets.embeddable("bench/other.html") == false)
        #expect(WebAssets.embeddable("js/a b.js") == false)
        #expect(WebAssets.embeddable("js/a.js") == true)
    }

    @Test func anETagThatMatchesIs304() throws {
        let folder = FolderAssets(root: try page(), port: Self.port)
        let asset = try #require(folder.asset(path: "/app.js"))
        let etag = try #require(header("ETag", asset).first)
        #expect(etag.hasPrefix("\"") && etag.hasSuffix("\"") && etag.count == 34)
        for given in [etag, "W/\(etag)", "\"other\", \(etag)", "*"] {
            let response = WebAssets.response(to: asset, ifNoneMatch: given)
            #expect(response.status == 304, "\(given)")
            #expect(response.body.isEmpty)
            #expect(response.headers.contains { $0.0 == "ETag" && $0.1 == etag })
            #expect(response.headers.contains { $0.0 == "Content-Security-Policy" })
            #expect(!response.headers.contains { $0.0 == "Content-Type" })
        }
        for given in [nil, "\"other\"", "", String(etag.dropLast()) + "x\""] as [String?] {
            let response = WebAssets.response(to: asset, ifNoneMatch: given)
            #expect(response.status == 200, "\(given ?? "nil")")
            #expect(response.body == asset.body)
            #expect(response.headers.map(\.0) == asset.headers.map(\.0))
        }
    }

    @Test func theBuildIsTheSameForTheSameFiles() throws {
        let one = FolderAssets(root: try page(), port: Self.port)
        let two = FolderAssets(root: try page(), port: 1234)
        let build = try #require(one.build)
        #expect(build.count == 8 && build.allSatisfy(\.isHexDigit))
        #expect(two.build == build)
        #expect(text(one.asset(path: "/build.json")) == #"{"assets":"\#(build)"}"#)
        // The build is the sorted paths and hashes: one byte changed, or one file renamed, is another build.
        let changed = try page()
        try Data("body { margin: 1px }\n".utf8).write(to: changed.appendingPathComponent("style.css"))
        #expect(FolderAssets(root: changed, port: Self.port).build != build)
        let renamed = try page()
        try FileManager.default.moveItem(at: renamed.appendingPathComponent("style.css"), to: renamed.appendingPathComponent("site.css"))
        #expect(FolderAssets(root: renamed, port: Self.port).build != build)
        // The embedded files' build is what `/build.json` says.
        let embedded = EmbeddedAssets(port: Self.port)
        #expect(text(embedded.asset(path: "/build.json")) == #"{"assets":"\#(EmbeddedAssets.build)"}"#)
        #expect(EmbeddedAssets.build == WebAssets.build(of: EmbeddedAssets.files.map { ($0.path, $0.sha256) }))
    }

    // MARK: The generator and the checked-in file

    static let script = packageFolder.appendingPathComponent("scripts/webapp-embed.sh")
    static let generated = packageFolder.appendingPathComponent("Sources/VibeNode/Web/WebAssets.generated.swift")

    /// Where a generated file goes: a new scratch folder's `out.swift`.
    func outFile(_ name: String) throws -> URL {
        let folder = scratch.url(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("out.swift")
    }

    func embed(root: URL, out: URL) async throws -> CommandRun {
        let home = scratch.url("embed-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return try await run(URL(fileURLWithPath: "/bin/bash"), [Self.script.path, "--root", root.path, "--out", out.path],
                             environment: scratchEnvironment(home))
    }

    /// Stale: the checked-in file is what the generator makes of `WebApp/` today, and each file in it is the tree's.
    @Test func theEmbeddedFilesAreWebAppsToday() async throws {
        let out = try outFile("generated")
        let ran = try await embed(root: packageFolder.appendingPathComponent("WebApp"), out: out)
        #expect(ran.status == 0, "\(ran.errors)")
        let fresh = try Data(contentsOf: out)
        let checkedIn = try Data(contentsOf: Self.generated)
        #expect(fresh == checkedIn, "WebAssets.generated.swift is stale: run scripts/webapp-embed.sh (the integrator's, LW-D9)")
        #expect(!EmbeddedAssets.files.isEmpty)
        for file in EmbeddedAssets.files {
            let onDisk = try Data(contentsOf: packageFolder.appendingPathComponent("WebApp").appendingPathComponent(file.path))
            #expect(file.body == onDisk, "\(file.path)")
            #expect(file.sha256 == SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined(), "\(file.path)")
        }
        #expect(EmbeddedAssets.files.map(\.path) == EmbeddedAssets.files.map(\.path).sorted())
        #expect(EmbeddedAssets.files.contains { $0.path == "index.html" })
    }

    @Test func theGeneratorIsReproducible() async throws {
        // Made in two orders, the same files: the same output, sorted by path in bytes.
        let first = try page()
        let second = try page(["js/words.js": "export const word = 'VibeSwitcher';\n", "app.js": "import { word } from './js/words.js';\ndocument.title = word;\n",
                               "style.css": "body { margin: 0 }\n",
                               "index.html": #"<!doctype html><link rel="stylesheet" href="style.css"><script type="module" src="app.js"></script><a href="https://example.com/">x</a>"#])
        let big = String(repeating: "export const x = 'a long line of text';\n", count: 200)
        for root in [first, second] { try Data(big.utf8).write(to: root.appendingPathComponent("js/big.js")) }
        let outs = [try outFile("one"), try outFile("two")]
        for (root, out) in zip([first, second], outs) {
            let ran = try await embed(root: root, out: out)
            #expect(ran.status == 0, "\(ran.errors)")
        }
        let one = try String(contentsOf: outs[0], encoding: .utf8)
        #expect(one == (try String(contentsOf: outs[1], encoding: .utf8)))
        // Again over the same folder: byte for byte.
        let again = try await embed(root: first, out: outs[1])
        #expect(again.status == 0)
        #expect(one == (try String(contentsOf: outs[1], encoding: .utf8)))
        // Sorted in bytes, base64 in lines of at most 76.
        #expect(paths(in: one) == ["app.js", "index.html", "js/big.js", "js/words.js", "style.css"], "\(one.prefix(400))")
        let lines = one.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let base64 = lines.filter { $0.count > 40 && $0.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) } }
        #expect(!base64.isEmpty && base64.allSatisfy { $0.count <= 76 })
        #expect(base64.contains { $0.count == 76 })
    }

    /// The paths a generated file lists, in its order.
    func paths(in generated: String) -> [String] {
        generated.split(separator: "\n").compactMap { line in
            guard let start = line.range(of: "path: \"") else { return nil }
            return String(line[start.upperBound...].prefix { $0 != "\"" })
        }
    }

    @Test func theGeneratorRefusesAnSVG() async throws {
        for (path, said) in [("icon.svg", "icon.svg"), ("other.html", "other.html"), ("data.xml", "data.xml"), ("js/a b.js", "a b.js")] {
            let root = try page()
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<svg/>".utf8).write(to: url)
            let out = try outFile("refused")
            let ran = try await embed(root: root, out: out)
            #expect(ran.status != 0, "\(path)")
            #expect(ran.errors.contains(said), "\(path): \(ran.errors)")
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(path)")
        }
        // Left out, not refused: what the page never loads.
        let root = try page()
        for path in ["shots/a.png", "test/a.test.mjs", "tests/b.test.mjs", ".DS_Store", "js/.hidden.svg", "README.md", "js/notes.md", "serve.sh", "wire/vectors.json"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let out = try outFile("left-out")
        let ran = try await embed(root: root, out: out)
        #expect(ran.status == 0, "\(ran.errors)")
        #expect(paths(in: try String(contentsOf: out, encoding: .utf8)) == ["app.js", "index.html", "js/words.js", "style.css"])
    }

    /// The first load's budget (500 ms) wants small files: no file over 256 KiB, and the page under 1 MiB. A vendored
    /// file (`vendor/`, loaded only with a terminal) may be up to 512 KiB.
    @Test func theEmbeddedFilesStaySmall() {
        let sizes = EmbeddedAssets.files.map { ($0.path, $0.body.count) }
        let limit = { (path: String) in path.hasPrefix(WebAssets.vendorFolder) ? WebAssets.maxVendoredFileBytes : WebAssets.maxFileBytes }
        #expect(sizes.allSatisfy { $0.1 <= limit($0.0) }, "\(sizes.filter { $0.1 > limit($0.0) })")
        #expect(sizes.reduce(0) { $0 + $1.1 } <= WebAssets.maxTotalBytes)
    }
}
