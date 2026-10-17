import AppKit
import SwiftUI
import Testing
@testable import VibeSwitcher

/// Pictures of the menu bar's menus, drawn offscreen from `MainMenu.build()` (titles, shortcuts, separators and
/// submenus as built; every item drawn enabled, since nothing validates them here). Only with
/// `MENU_SNAPSHOT_DIR=/some/folder swift test --filter MenuSnapshots`.
@MainActor
struct MenuSnapshots {
    static let folder = ProcessInfo.processInfo.environment["MENU_SNAPSHOT_DIR"]

    @Test(.enabled(if: folder != nil)) func drawMenus() throws {
        let folder = try #require(Self.folder)
        let bar = MainMenu.build()
        for title in ["VibeSwitcher", "File", "Edit", "View", "Session", "Window"] {
            let menu = try #require(bar.item(withTitle: title)?.submenu)
            // Edit is drawn with its Find submenu open.
            let open = title == "Edit" ? menu.item(withTitle: "Find")?.submenu : nil
            for scheme in [ColorScheme.light, .dark] {
                let view = MenuPicture(bar: bar.items.map(\.title), open: title, menu: menu, submenu: open)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let tiff = try #require(image.tiffRepresentation)
                let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                let name = "menu-\(title.lowercased())-\(scheme == .dark ? "dark" : "light").png"
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }
}

/// "⇧⌘Z", "⌥⌘↓", "⇧⌘⌫": the shortcut as the menu shows it.
func menuShortcut(_ item: NSMenuItem) -> String {
    guard !item.keyEquivalent.isEmpty else { return "" }
    let flags = item.keyEquivalentModifierMask
    let names: [String: String] = [String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑",
                                   String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓",
                                   "\u{8}": "⌫", "\u{7f}": "⌫"]
    let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
}

private struct MenuPicture: View {
    let bar: [String]
    let open: String
    let menu: NSMenu
    let submenu: NSMenu?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo")
                ForEach(bar, id: \.self) { title in
                    Text(title).fontWeight(title == bar.first ? .bold : .regular)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(title == open ? Color.primary.opacity(0.15) : .clear))
                }
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.93))
            HStack(alignment: .top, spacing: -4) {
                panel(menu, highlighted: submenu == nil ? nil : "Find")
                if let submenu { panel(submenu, highlighted: nil).padding(.top, offset(of: submenu)) }
            }
            .padding(.leading, CGFloat(max(0, bar.firstIndex(of: open) ?? 0)) * 62 + 18)
            .padding([.bottom, .trailing], 24)
        }
        .frame(width: 900, alignment: .leading)
        .background(scheme == .dark ? Color(white: 0.2) : Color(white: 0.85))
    }

    /// How far down the item that opens `submenu` sits.
    private func offset(of submenu: NSMenu) -> CGFloat {
        menu.items.prefix { $0.submenu !== submenu }.reduce(0) { $0 + ($1.isSeparatorItem ? 11 : 22) }
    }

    private func panel(_ menu: NSMenu, highlighted: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider().padding(.horizontal, 10).padding(.vertical, 5)
                } else {
                    HStack {
                        Text(item.title)
                        Spacer(minLength: 28)
                        if item.submenu != nil {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        } else {
                            Text(menuShortcut(item)).foregroundStyle(item.title == highlighted ? .white : .secondary)
                        }
                    }
                    .foregroundStyle(item.title == highlighted ? .white : .primary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(item.title == highlighted ? Color.accentColor : .clear)
                        .padding(.horizontal, 5))
                }
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 5)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 8).fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
