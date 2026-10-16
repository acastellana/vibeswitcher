import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeCore

/// The message box under the chat: ↩ sends, ⇧↩ adds a line, ↑ / ↓ in an empty box walk through earlier
/// prompts. Pasting or dropping an image saves it and inserts its path; dropping files inserts their paths.
struct ComposerView: View {
    let agent: String
    let history: [String]
    let send: (String) -> Void
    @State private var text = ""
    @State private var height: CGFloat = 22

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message \(agent)… ↩ to send, ⇧↩ for a new line, drop files or paste images")
                        .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $height, history: history, submit: submit)
                    .frame(height: min(max(height, 22), 220))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              ? Color.secondary.opacity(0.4) : Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            .help("Send (↩)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        send(message)
        text = ""
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let history: [String]
    let submit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.measure(textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// Position while walking through history (nil: not walking).
        private var historyIndex: Int?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            historyIndex = nil
            measure(textView)
        }

        func measure(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 6
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.submit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                return walkHistory(textView, by: -1)
            case #selector(NSResponder.moveDown(_:)):
                return walkHistory(textView, by: 1)
            default:
                return false
            }
        }

        /// ↑ / ↓ go through earlier prompts while the box is empty or showing one of them.
        private func walkHistory(_ textView: NSTextView, by step: Int) -> Bool {
            let history = parent.history
            guard !history.isEmpty, textView.string.isEmpty || historyIndex != nil else { return false }
            let next = (historyIndex ?? history.count) + step
            guard next >= 0 else { return true }
            if next >= history.count {
                historyIndex = nil
                textView.string = ""
            } else {
                historyIndex = next
                textView.string = history[next]
            }
            parent.text = textView.string
            measure(textView)
            return true
        }
    }
}

/// Pastes images as saved files and drops files as their paths.
private final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return insertPaths(urls)
        }
        if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board), let url = Attachments.save(image) {
            return insertPaths([url])
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaths(urls)
            return true
        }
        if let image = NSImage(pasteboard: board), let url = Attachments.save(image) {
            insertPaths([url])
            return true
        }
        return super.performDragOperation(sender)
    }

    private func insertPaths(_ urls: [URL]) {
        let text = urls.map { RecentProjects.shellQuote($0.path) }.joined(separator: " ")
        let before = selectedRange().location > 0 ? (string as NSString).substring(with: NSRange(location: selectedRange().location - 1, length: 1)) : " "
        insertText((before == " " || before == "\n" ? "" : " ") + text + " ", replacementRange: selectedRange())
        window?.makeFirstResponder(self)
    }
}

/// Images pasted into the composer, saved where the agent can read them.
enum Attachments {
    static var folder: URL { VibePaths.root.appendingPathComponent("attachments", isDirectory: true) }

    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("pasted-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).png")
        guard fileManager.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else { return nil }
        return url
    }
}
