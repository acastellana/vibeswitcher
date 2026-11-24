import Foundation
import Testing
@testable import VibeCore

/// The Mac app's tests pin some shared types' stored properties (`Mirror(reflecting: X()).children.map { $0.label ?? "" }
/// == [...]`): `TeamChurnTests` holds LeadBoard's to the list its `isSame` compares. The Mac app and its tests aren't
/// edited on v2, and the Linux jobs don't build them, so a stored property added to such a type here broke only the Mac's
/// gate (goals, 2026-11-23). Here every such pin is read from the Mac tests' text (so it can't drift) and held against the
/// type as this build has it; a pinned type this test doesn't know fails until it is added below.
struct MacPinsLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The types a Mac test may pin, made empty, by name.
    static let known: [String: Any] = ["LeadBoard": LeadBoard()]

    /// Each pin in the Mac tests: the type's name and the labels listed, with the file.
    static func pins() throws -> [(type: String, labels: [String], file: String)] {
        let folder = repo.appendingPathComponent("Tests/VibeSwitcherTests")
        let pattern = try NSRegularExpression(pattern: #"Mirror\(reflecting:\s*(\w+)\(\)\)\.children\.map\s*\{[^}]*\}\s*==\s*\[([^\]]*)\]"#)
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
        var found: [(String, [String], String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let type = Range(match.range(at: 1), in: text), let list = Range(match.range(at: 2), in: text) else { continue }
                let body = String(text[list])
                let labels = quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
                found.append((String(text[type]), labels, name))
            }
        }
        return found
    }

    @Test func everyMacPinHoldsOnThisBuild() throws {
        let pins = try Self.pins()
        #expect(pins.contains { $0.type == "LeadBoard" && $0.file == "TeamChurnTests.swift" }, "TeamChurnTests' pin wasn't found: \(pins)")
        for pin in pins {
            let value = try #require(Self.known[pin.type], "\(pin.file) pins \(pin.type)'s stored properties: add it to MacPinsLintTests.known")
            let labels = Mirror(reflecting: value).children.map { $0.label ?? "" }
            let why = "\(pin.type)'s stored properties are no longer what \(pin.file) pins (the Mac's gate fails): "
                + "added \(labels.filter { !pin.labels.contains($0) }), gone \(pin.labels.filter { !labels.contains($0) }). Keep new data out of \(pin.type) (a file of its own, as goals.json)."
            #expect(labels == pin.labels, "\(why)")
        }
    }
}
