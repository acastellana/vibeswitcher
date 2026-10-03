import Foundation
import Network
import Testing
@testable import VibeCore

struct DevPagesTests {
    @Test func onlyLocalHttpPagesQualify() throws {
        let page = try #require(DevPages.page(url: "http://localhost:5173/settings?tab=2#top", title: " Settings "))
        #expect(page.title == "Settings")
        #expect(page.path == "/settings?tab=2#top")
        #expect(page.target == PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173))
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.title == "127.0.0.1:3000")
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.path == "/")
        #expect(DevPages.page(url: "http://[::1]:8080/", title: "x")?.target
                == PreviewTarget(connectHost: "::1", hostHeader: "[::1]:8080", port: 8080))
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.connectHost == "localhost")
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.hostHeader == "app.localhost:3000")
        for url in ["https://localhost:5173/", "http://example.com:5173/", "http://192.168.1.4:3000/",
                    "http://localhost/", "http://localhost:47823/", "http://localhost:47826/",
                    "http://user:pw@localhost:3000/", "chrome://settings", "http://localhost.evil.com:3000/"] {
            #expect(DevPages.page(url: url, title: "x") == nil, "\(url)")
        }
    }

    @Test func pathsCanNeverRedirectOffTheMac() {
        #expect(DevPages.page(url: "http://localhost:3000//evil.example/x", title: "x")?.path == "/evil.example/x")
        #expect(DevPages.safePath("/\\evil.example") == "/evil.example")
        #expect(DevPages.safePath("/ok/path?a=1") == "/ok/path?a=1")
        #expect(DevPages.safePath("") == "/")
    }

    @Test func listsEachPageOnceInTabOrder() throws {
        let pages = DevPages.pages(fromTabs: [("http://localhost:5173/", "A"), ("https://github.com/", "B"),
                                              ("http://localhost:5173/", "A again"), ("http://localhost:3000/x", "C")])
        #expect(pages.map(\.title) == ["A", "C"])
        #expect(DevPages.id(for: pages[0]) != DevPages.id(for: pages[1]))
        let renamed = try #require(DevPages.page(url: "http://localhost:5173/", title: "renamed"))
        #expect(DevPages.id(for: pages[0]) == DevPages.id(for: renamed))
    }
}
