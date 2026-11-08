import AppKit
import Testing
@testable import VibeSwitcher

/// `shot`'s pixel check: a side pane that drew blank, or in the wrong look's colors, fails the shot.
@Suite struct PaneCheckTests {
    private static let width = 200, height = 400
    private static let pane = CGRect(x: 0, y: 0, width: width, height: height)
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let dark = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    private static let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    private func image(_ background: NSColor, _ marks: [(rows: Range<Int>, color: NSColor)] = []) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(background.cgColor)
        context.fill(Self.pane)
        for (rows, color) in marks {
            context.setFillColor(color.cgColor)
            // A context's origin is its bottom left; the marks' rows count from the top.
            context.fill(CGRect(x: 0, y: Self.height - rows.upperBound, width: Self.width, height: rows.count))
        }
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    /// A pane with something in its header, its list and its footer (at scale 1: 96 points of header, 70 of footer).
    private var drawn: [(rows: Range<Int>, color: NSColor)] {
        [(10..<30, Self.gray), (120..<160, Self.gray), (360..<380, Self.gray)]
    }

    private func problem(_ image: NSBitmapImageRep, dark: Bool, expectsList: Bool = true) -> String? {
        PaneCheck.problem(in: image, pane: Self.pane, scale: 1, dark: dark, expectsList: expectsList)
    }

    @Test func aPaneThatDrewPasses() throws {
        #expect(problem(try image(Self.white, drawn), dark: false) == nil)
        #expect(problem(try image(Self.dark, drawn), dark: true) == nil)
    }

    @Test func aPaneAllOneColorIsBlank() throws {
        #expect(problem(try image(Self.white), dark: false, expectsList: false)?.contains("blank") == true)
        #expect(problem(try image(Self.dark), dark: true, expectsList: false)?.contains("blank") == true)
    }

    @Test func aWhitePaneInADarkWindowFails() throws {
        #expect(problem(try image(Self.white, drawn), dark: true)?.contains("in a dark window") == true)
    }

    @Test func aBlackPaneInALightWindowFails() throws {
        #expect(problem(try image(.black, drawn), dark: false)?.contains("in a light window") == true)
    }

    @Test func aSidebarWithoutItsListFailsOnlyWhenOneIsExpected() throws {
        let noList = try image(Self.white, [(10..<30, Self.gray), (360..<380, Self.gray)])
        #expect(problem(noList, dark: false)?.contains("list is blank") == true)
        #expect(problem(noList, dark: false, expectsList: false) == nil)
    }

    @Test func aPaneOutsideTheImageSaysSoInsteadOfPassing() throws {
        let outside = CGRect(x: 1000, y: 1000, width: 10, height: 10)
        #expect(PaneCheck.problem(in: try image(Self.white, drawn), pane: outside, scale: 1, dark: false, expectsList: false) != nil)
    }
}
