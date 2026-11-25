import Foundation
import Testing
@testable import VibeNode

/// Nothing outside a plugin's folder names it (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md, "What a plugin
/// is"): outside `Sources/VibeNode/Plugins/<Name>/` and the registry's list (`PluginRegistry.swift`), no source of the
/// node, the command line or the page names `shell` or `wallet` as a card kind, a card's field, an answer word or a
/// view. Everything else asks the registry and draws the generic card. Comments don't count; string literals do (a
/// kind is a string on the wire).
///
/// `pending`: the files still wired by hand (none since step 2). A file that no longer matches must leave the list, so it
/// only shrinks.
struct PluginLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The folders the rule covers, and the extensions it reads in each.
    static let covered: [(folder: String, extensions: Set<String>)] = [
        ("Sources/VibeNode", ["swift"]), ("Sources/vibeswitcher-cli", ["swift"]), ("WebApp/js", ["js"]), ("WebApp", ["js"]),
    ]

    /// Where a plugin may name itself.
    static func exempt(_ path: String) -> Bool {
        path.hasPrefix("Sources/VibeNode/Plugins/") && (path.dropFirst("Sources/VibeNode/Plugins/".count).contains("/")
            || path == "Sources/VibeNode/Plugins/PluginRegistry.swift")
    }

    /// The plugins' ids, as the registry lists them: `shell|wallet`.
    static let ids = PluginRegistry.standard().map(\.info.id).joined(separator: "|")

    /// What the rule refuses, each with what it says.
    static let refused: [(pattern: String, what: String)] = [
        // Swift: the card kind, the card's own field, the hand-wired types. (A launch preset's `.shell` is a preset's.)
        (#"\bKind\.(\#(ids))\b|\bCard\(.*\bkind\s*:\s*\.(\#(ids))\b|\bcase\s+\.(\#(ids))\b|\[\s*\.question\b[^\]]*\.(\#(ids))\b|\bcard\.kind\s*==\s*\.(\#(ids))\b"#, "a card kind"),
        (#"\b(card|\$0|closed|existing|updated|shown)\??\.(\#(ids))\b"#, "a card's field"),
        (#"\b(ShellShown|WalletShown|answerShell|shellNotices|shellCards|lookAtShellRequests)\b|\bShellCards\s*\."#, "a hand-wired card"),
        (#"\bcard\["kind"\]\??\.string\s*==\s*"(\#(ids))""#, "a card kind"),
        (#"\[\s*"(\#(ids))"\s*\]\??\[\s*""#, "a card's field"),
        (#"\[\s*"run"\s*,\s*"decline"\s*\]|"sign"\s*,\s*"decline""#, "answer words"),
        (#"\(\s*"shell request"\s*,"#, "a card kind"),
        // The page: the kind, the field, the hand-wired view.
        (#"\b(card|c)\.kind\s*===\s*'(\#(ids))'"#, "a card kind"),
        (#"\b(card|c)\??\.(\#(ids))\b"#, "a card's field"),
        (#"\b(shellcard\.js|shellFacts|shellCardsOf|shellCard|walletCard)\b"#, "a hand-wired view"),
        (#"\bshell:\s*'A shell asked for'"#, "a card kind"),
    ]

    /// The files still wired by hand: none since shell requests moved onto the plugin system (the definition's step 2).
    static let pending: Set<String> = []

    /// `text` with its comments blanked (each byte but a newline made a space), string literals kept.
    static func uncommented(_ text: String) -> String {
        var bytes = Array(text.utf8)
        var index = 0
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index], next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if let open = quote {
                if byte == UInt8(ascii: "\\") { index += 2; continue }
                if byte == open || byte == UInt8(ascii: "\n") { quote = nil }
                index += 1
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: "`") {
                quote = byte
                index += 1
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { bytes[index] = UInt8(ascii: " "); index += 1 }
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                while index < bytes.count, !(bytes[index] == UInt8(ascii: "*") && index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/")) {
                    if bytes[index] != UInt8(ascii: "\n") { bytes[index] = UInt8(ascii: " ") }
                    index += 1
                }
                if index + 1 < bytes.count { bytes[index] = UInt8(ascii: " "); bytes[index + 1] = UInt8(ascii: " ") }
                index += 2
            } else {
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Each covered file (relative path) and what it says.
    static func files() -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        var seen: Set<String> = []
        for (folder, extensions) in covered {
            let base = repo.appendingPathComponent(folder)
            // WebApp's own files only at its top (its js/ is covered on its own; tests, vendor and wire aren't the page's code).
            let deep = folder != "WebApp"
            let names: [String] = deep ? (FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? [])
                : ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            for name in names.sorted() where extensions.contains((name as NSString).pathExtension) {
                let path = folder + "/" + name
                guard seen.insert(path).inserted, !exempt(path), !path.hasSuffix(".generated.swift"), let text = try? String(contentsOfFile: base.appendingPathComponent(name).path, encoding: .utf8) else { continue }
                found.append((path, text))
            }
        }
        return found
    }

    /// Where `text` breaks the rule: each line's number and what it names.
    static func breaks(_ text: String) -> [String] {
        let code = uncommented(text)
        var said: [String] = []
        for (number, line) in code.components(separatedBy: "\n").enumerated() {
            for (pattern, what) in refused where line.range(of: pattern, options: .regularExpression) != nil {
                said.append("line \(number + 1): \(what)")
            }
        }
        return said
    }

    @Test func noSourceOutsideAPluginNamesIt() {
        var matched: Set<String> = []
        for (path, text) in Self.files() {
            let found = Self.breaks(text)
            guard !found.isEmpty else { continue }
            matched.insert(path)
            #expect(Self.pending.contains(path), "\(path) names a plugin outside its folder (\(found.prefix(5).joined(separator: "; "))): ask the registry, draw the generic card")
        }
        for path in Self.pending.subtracting(matched).sorted() {
            Issue.record("\(path) no longer names a plugin: take it off PluginLintTests.pending")
        }
    }

    /// The rule catches what it is for, and not a launch preset's shell or a comment.
    @Test func theRuleCatchesACardKindAndNotAPresetOrAComment() {
        #expect(Self.breaks(#"if card.kind == .question || card.kind == .approval { return }"#).isEmpty)
        #expect(!Self.breaks(#"case .shell: return false"#).isEmpty)
        #expect(!Self.breaks(#"guard let shown = card.shell else { return }"#).isEmpty)
        #expect(!Self.breaks(#"guard card["kind"]?.string == "shell" else { return nil }"#).isEmpty)
        #expect(!Self.breaks(#"return ["run", "decline"].contains(word) ? word : nil"#).isEmpty)
        #expect(!Self.breaks(#"case "answer": kinds = [.question, .approval, .shell, .plugin]"#).isEmpty)
        #expect(Self.breaks(#"if model != nil, preset["kind"]?.string == "shell" { return }"#).isEmpty, "a launch preset's kind")
        #expect(!Self.breaks(#"const words = card.kind === 'shell' ? 'x' : 'y';"#).isEmpty)
        #expect(!Self.breaks(#"import { shellFacts } from '../shellcard.js';"#).isEmpty)
        #expect(Self.breaks(#"guard preset.kind != .shell else { return nil }"#).isEmpty, "a launch preset's shell")
        #expect(Self.breaks(#"let sessionLabels = ["claude": "Claude", "shell": "Shell"]"#).isEmpty)
        #expect(Self.breaks("// card.shell and kind: .shell in a comment\nlet x = 1").isEmpty)
        #expect(Self.breaks(#"const how = preset.kind === 'shell' ? ' --agent shell' : '';"#).isEmpty)
        #expect(Self.exempt("Sources/VibeNode/Plugins/Shell/ShellPlugin.swift") && Self.exempt("Sources/VibeNode/Plugins/PluginRegistry.swift"))
        #expect(!Self.exempt("Sources/VibeNode/Plugins/PluginEngine.swift"))
    }

    /// A new card kind or a new field on a card is the registry's to judge (a hand-wired card would start as one): this
    /// list moves only with a plugin system's change, reviewed.
    @Test func noNewCardKindOrFieldOutsideTheRegistry() {
        #expect(CardStore.Kind.allCases.map(\.rawValue) == ["question", "approval", "config", "base", "plugin"])
        let fields = Mirror(reflecting: CardStore.Card(root: "/r", kind: .plugin)).children.compactMap(\.label)
        // `facts`: the vault's facts on a question the lead's audit asked (the review of 6a610ed8, A1: reviewed there).
        #expect(fields == ["id", "code", "project", "root", "kind", "question", "approval", "config", "base", "plugin", "notice", "facts", "closed",
                           "at", "closedAt", "draft"], "\(fields)")
    }

    /// A plugin's own code (`Plugins/<Name>/`) reaches the node through its desk only: no card store, no host link, no
    /// engine, no file manager of its own.
    @Test func aPluginReachesTheNodeThroughItsDeskOnly() throws {
        let base = Self.repo.appendingPathComponent("Sources/VibeNode/Plugins")
        let names = FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? []
        var checked = 0
        for name in names where name.contains("/") && name.hasSuffix(".swift") {
            let code = Self.uncommented(try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8))
            checked += 1
            for (pattern, what) in [(#"\bFileManager\b"#, "a file manager"), (#"\bengine\b"#, "the engine"), (#"\.link\b"#, "the host link"),
                                    (#"\bcards\s*\."#, "the card store"), (#"\bCardStore\s*\.\s*Card\s*\("#, "a card made by hand")] {
                #expect(code.range(of: pattern, options: .regularExpression) == nil, "Plugins/\(name) reaches \(what): go through its desk")
            }
        }
        #expect(checked > 0)
        #expect(PluginInfo(id: "x", title: "X", summary: "x", defaultOn: false, folder: ".").refusal != nil)
        #expect(PluginInfo(id: "x", title: "X", summary: "x", defaultOn: false, folder: "state/x").refusal != nil, "shared with the node's state")
        #expect(PluginInfo(id: "x", title: "X", summary: "x", defaultOn: false, folder: "x-requests/./asked").refusal != nil)
        #expect(PluginInfo(id: "x", title: "X", summary: "x", defaultOn: false, folder: "x-requests/asked").refusal == nil)
    }
}
