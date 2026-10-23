import AppKit
import SwiftTerm
import SwiftUI
import VibeCore

/// SwiftTerm's view, telling what you type apart from its automatic answers to terminal queries: only the
/// primary view's answers reach the program (see the session host's "one answer per query" rule).
final class HostTerminalView: TerminalView {
    var onReply: ((Data) -> Void)?

    #if DEBUG
    /// For `--idle-bench`: the terminal views alive now (made and freed on the main thread).
    static var live = 0

    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        Self.live += 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.live += 1
    }

    deinit { Self.live -= 1 }
    #endif

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        onReply?(Data(data))
    }

    /// SwiftTerm asks for 8-bit RGBA on the view's layer, but a terminal that redraws often is drawn into a content
    /// sublayer AppKit adds (drawn asynchronously, on the GPU) in a format AppKit picks: half-float, 8 bytes a pixel,
    /// 16 MB for a 758x683-point pane. CoreAnimation's accelerated renderer keeps the last surface it drew into after the
    /// terminal and the window are gone. The terminal's colours are 8-bit sRGB. AppKit makes that sublayer again
    /// between draws, so this holds from the draw after it appears.
    override func viewWillDraw() {
        super.viewWillDraw()
        for sublayer in layer?.sublayers ?? [] where !(sublayer.delegate is NSView) && sublayer.contentsFormat != .RGBA8Uint {
            sublayer.contentsFormat = .RGBA8Uint
        }
    }
}

/// The middle pane: the selected window session's live terminal, or a placeholder. Views of the last few
/// sessions stay attached for a while, so switching back is instant.
///
/// Each view holds its scrollback (about 30 MB at 10,000 lines and 120 columns) and parses its session's output on the
/// main thread, shown or not. So few stay: the one on screen and the last ones shown, each for `parkedLifetime` off
/// screen. A session shown again after that gets a new view, drawn from the host's replay.
final class TerminalPaneController: NSViewController, TerminalViewDelegate {
    /// The view on screen and the last two shown.
    static let keepAttached = 3
    /// How long a view off screen stays attached before it's let go.
    static let parkedLifetime: TimeInterval = 30

    private let host: HostClient
    private var views: [UUID: HostTerminalView] = [:]
    /// Holds back each view's answers to terminal queries while it's being replayed earlier output.
    private var gates: [UUID: ReplayGate] = [:]
    private var recent: [UUID] = []
    private var placeholder: NSView?
    private(set) var current: UUID?
    /// Applied to each view when it's created and by `reconfigureAll` (fonts, colors, cursor; Settings).
    var configure: (HostTerminalView) -> Void = { _ in }
    /// Scrollback for new views.
    var scrollbackLines = 10_000
    /// Called for a bell in the session on screen.
    var onBell: (HostTerminalView) -> Void = { _ in NSSound.beep() }
    /// Runs its argument once a view has been off screen for `parkedLifetime` (a test runs it when it chooses).
    var afterParked: (@escaping () -> Void) -> Void = { release in
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalPaneController.parkedLifetime, execute: release)
    }
    /// The views off screen waiting to be let go, each by the release that's still theirs (shown again: none).
    private var releases: [UUID: UUID] = [:]

    init(host: HostClient) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Space between the pane's edges and the terminal text; it takes the terminal's background color.
    static let inset = NSSize(width: 10, height: 6)

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    /// Paints the margin around the terminal in the terminal's background color (nil: none).
    private func setMargin(_ color: NSColor?) {
        view.layer?.backgroundColor = color?.cgColor
    }

    var currentView: HostTerminalView? { current.flatMap { views[$0] } }

    /// The session's view while it's attached.
    func terminalView(_ id: UUID) -> HostTerminalView? { views[id] }

    /// The chat covers the pane: its terminal leaves the screen too (and keeps reading the session).
    var covered = false {
        didSet {
            guard covered != oldValue else { return }
            view.isHidden = covered
            if let currentView { covered ? park(currentView) : unpark(currentView) }
        }
    }

    /// `focus`: false while the chat covers the terminal (keys must not go to a terminal you can't see).
    func show(hostID: UUID, focus takesFocus: Bool = true) {
        placeholder?.removeFromSuperview()
        placeholder = nil
        for (id, other) in views where id != hostID { park(other, releasing: id) }
        releases[hostID] = nil
        let terminal = views[hostID] ?? makeView(for: hostID)
        covered ? park(terminal) : unpark(terminal)
        setMargin(terminal.nativeBackgroundColor)
        current = hostID
        // Hidden views don't resize their sessions (each would redraw on every step of a window drag): the one on
        // screen catches up now.
        let screen = terminal.getTerminal()
        host.resize(hostID, cols: screen.cols, rows: screen.rows, reason: .shown)
        recent.removeAll { $0 == hostID }
        recent.insert(hostID, at: 0)
        for evicted in recent.dropFirst(Self.keepAttached) { forget(evicted) }
        if takesFocus { focus() }
    }

    func show(placeholder content: AnyView) {
        current = nil
        for (id, terminal) in views { park(terminal, releasing: id) }
        placeholder?.removeFromSuperview()
        let hosting = NSHostingView(rootView: content)
        setMargin(nil)
        pin(hosting)
        placeholder = hosting
    }

    /// A view that's not on screen leaves the view tree, so its layer gives back its backing store (the size of the pane,
    /// several MB each); its terminal goes on reading the session, and it's drawn again when it's shown.
    private func park(_ terminal: HostTerminalView) {
        guard terminal.superview != nil else { return }
        terminal.removeFromSuperview()
        terminal.layer?.contents = nil
    }

    /// Parks a view that's leaving the screen, and lets it go after `parkedLifetime` unless it's shown again.
    private func park(_ terminal: HostTerminalView, releasing id: UUID) {
        park(terminal)
        guard releases[id] == nil else { return }
        let release = UUID()
        releases[id] = release
        afterParked { [weak self] in
            guard let self, self.releases[id] == release, id != self.current else { return }
            self.forget(id)
        }
    }

    private func unpark(_ terminal: HostTerminalView) {
        guard terminal.superview == nil else { return }
        pin(terminal, inset: Self.inset)
        terminal.needsDisplay = true
    }

    /// Stops showing a session (evicted, removed or the window closed); the host keeps it running.
    func forget(_ id: UUID) {
        views.removeValue(forKey: id)?.removeFromSuperview()
        gates[id] = nil
        releases[id] = nil
        recent.removeAll { $0 == id }
        host.detach(id)
        if current == id { current = nil }
    }

    func detachAll() {
        Array(views.keys).forEach(forget)
    }

    var attachedIDs: [UUID] { Array(views.keys) }

    /// For `--idle-bench`: the attached views whose layer holds a drawing, and roughly its size.
    var backingStores: (views: Int, bytes: Int) {
        let held = views.values.compactMap(\.layer).filter { $0.contents != nil }
        return (held.count, held.reduce(0) { $0 + Int($1.bounds.width * $1.bounds.height * $1.contentsScale * $1.contentsScale * 4) })
    }

    func reconfigureAll() {
        views.values.forEach(configure)
        if let currentView { setMargin(currentView.nativeBackgroundColor) }
    }

    func focus() {
        guard let terminal = currentView else { return }
        view.window?.makeFirstResponder(terminal)
    }

    /// The session's screen as text lines (wide characters and clusters kept whole: each cell is read through the
    /// terminal, as a cell alone reads an emoji with VS16 as a space), for reading menus and modes off it.
    /// Blank lines at the bottom are dropped: a fresh program draws from the top of a tall screen.
    func screenLines(_ id: UUID) -> [String] {
        guard let terminal = views[id]?.getTerminal() else { return [] }
        var lines = (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: false, skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:))
                .replacingOccurrences(of: "\u{0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// `screenLines`, and on each of them the stretches drawn on a coloured background or inverted: what a program
    /// marks only that way (Claude's open question tab). Read cell by cell.
    func screenText(_ id: UUID) -> ScreenRead {
        guard let terminal = views[id]?.getTerminal() else { return ScreenRead() }
        var read = ScreenRead()
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            read.lines.append(line.translateToString(trimRight: false, skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:))
                .replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces))
            var spans: [String] = []
            var span = ""
            for column in 0..<line.count {
                let attribute = line[column].attribute
                var marked = attribute.style.contains(.inverse)
                if case .defaultColor = attribute.bg {} else { marked = true }
                if marked {
                    let character = terminal.getCharacter(for: line[column])
                    if character != "\u{0}" { span.append(character) }
                } else if !span.isEmpty {
                    spans.append(span)
                    span = ""
                }
            }
            if !span.isEmpty { spans.append(span) }
            read.highlights.append(spans.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        while read.lines.last?.isEmpty == true {
            read.lines.removeLast()
            read.highlights.removeLast()
        }
        return read
    }

    /// Whether the program in that session asked for bracketed paste (needs its view attached).
    func bracketedPaste(_ id: UUID) -> Bool {
        views[id]?.getTerminal().bracketedPasteMode ?? false
    }

    func clearScrollback() {
        currentView?.feed(text: "\u{1b}[3J")
    }

    private func makeView(for id: UUID) -> HostTerminalView {
        let terminal = HostTerminalView(frame: view.bounds, font: nil, options: TerminalOptions(scrollback: scrollbackLines))
        terminal.terminalDelegate = self
        terminal.onReply = { [weak self] data in
            guard let self, self.gates[id]?.allowsReplies != false else { return }
            self.host.send(id, bytes: data, reply: true)
        }
        configure(terminal)
        pin(terminal, inset: Self.inset)
        views[id] = terminal
        gates[id, default: ReplayGate()].attaching()
        let size = terminal.getTerminal()
        host.attach(id, cols: size.cols, rows: size.rows, sink: .init(
            output: { [weak terminal] data in terminal?.feed(byteArray: [UInt8](data)[...]) },
            attached: { [weak self] in self?.gates[id]?.attached() },
            // The host dropped our stream (we fell behind): start clean; a fresh replay follows.
            resync: { [weak self, weak terminal] in
                self?.gates[id]?.attaching()
                terminal?.feed(text: "\u{1b}c")
            }))
        return terminal
    }

    private func pin(_ subview: NSView, inset: NSSize = .zero) {
        subview.frame = view.bounds.insetBy(dx: inset.width, dy: inset.height)
        subview.autoresizingMask = [.width, .height]
        view.addSubview(subview)
    }

    private func id(of source: TerminalView) -> UUID? {
        views.first { $0.value === source }?.key
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let id = id(of: source) else { return }
        host.send(id, bytes: Data(data), reply: false)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let id = id(of: source), id == current else { return }
        let windowSize = view.window?.frame.size
        let windowResized = view.window?.inLiveResize == true || windowSize != lastWindowSize
        lastWindowSize = windowSize
        host.resize(id, cols: newCols, rows: newRows, reason: resizeCause ?? (windowResized ? .windowResize : .paneSplit))
    }

    /// What the terminal's size changes come from while the window changes something itself (focus mode, the font
    /// size); otherwise a window resize, or the split between the panes when the window kept its size.
    private var resizeCause: HostClient.ResizeReason?
    private var resizeCauses = 0
    private var lastWindowSize: NSSize?

    /// The size changes in the next `seconds` (an animation, a font applied on the next turn) come from `reason`.
    func attributeResizes(to reason: HostClient.ResizeReason, for seconds: TimeInterval = 1) {
        resizeCause = reason
        resizeCauses += 1
        let mine = resizeCauses
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.resizeCauses == mine else { return }
            self.resizeCause = nil
        }
    }

    func bell(source: TerminalView) {
        guard let terminal = source as? HostTerminalView, terminal === currentView else { return }
        onBell(terminal)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Programs don't get to read your clipboard.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Shown for a session that runs in Terminal.app: its screen, re-read every 2 s while shown, and a way
/// to go there. Read-only: nothing is typed into Terminal from here.
/// A label style chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct TerminalMirror: View {
    let session: Session
    let open: () -> Void
    /// Offered between turns: continue it in the window, in full color.
    let move: (() -> Void)?
    @State private var screen: String?

    @ViewBuilder private func buttons(labels: Bool) -> some View {
        HStack(spacing: 8) {
            if let move {
                Button(action: move) {
                    Label("Move to Window", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                }
                .buttonStyle(.borderedProminent)
                .help("Quit it in Terminal and continue the same conversation here, in full color")
            }
            Button(action: open) {
                Label("Open in Terminal", systemImage: "arrow.up.forward.app")
                    .labelStyle(labels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            }
            .help("Open in Terminal (⌘O)")
        }
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow").font(.system(size: 16)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Runs in Terminal").font(.system(size: 13, weight: .semibold))
                    Text(move != nil ? "Terminal shares only plain text. Move it here for full color."
                                     : "Its screen as plain text, as of a moment ago. Answer it in Terminal.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    buttons(labels: true)
                    buttons(labels: false)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(screen ?? "Reading its screen…")
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                        Color.clear.frame(width: 1, height: 1).id("end")
                    }
                    .padding(14)
                }
                .onChange(of: screen) { proxy.scrollTo("end", anchor: .bottomLeading) }
            }
        }
        .task(id: session.identity) {
            let tty = session.tty
            while !Task.isCancelled {
                if NSApp.isActive || screen == nil {
                    let text = await Task.detached { TerminalBridge.screens(for: [tty])[tty] }.value
                    let shown = (text ?? "Couldn't read its Terminal tab.").trimmingTrailingBlankLines
                    if shown != screen { screen = shown }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private extension String {
    var trimmingTrailingBlankLines: String {
        var lines = split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

extension HostTerminalView {
    func apply(_ appearance: TerminalAppearance, darkMode: Bool) {
        let size = CGFloat(appearance.fontSize)
        font = (appearance.fontName.isEmpty ? nil : NSFont(name: appearance.fontName, size: size))
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let palette = appearance.palette(darkMode: darkMode)
        func color(_ hex: String) -> NSColor {
            let rgb = RGB(hex: hex) ?? RGB(red: 0.5, green: 0.5, blue: 0.5)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        nativeForegroundColor = color(palette.foreground)
        nativeBackgroundColor = color(palette.background)
        caretColor = color(palette.cursor)
        selectedTextBackgroundColor = color(palette.selection)
        installColors(palette.ansi.map { hex in
            let rgb = RGB(hex: hex) ?? RGB(red: 0, green: 0, blue: 0)
            return SwiftTerm.Color(red: UInt16(rgb.red * 65_535), green: UInt16(rgb.green * 65_535), blue: UInt16(rgb.blue * 65_535))
        })
        optionAsMetaKey = appearance.optionAsMeta
        let style: CursorStyle
        switch (appearance.cursorShape, appearance.cursorBlink) {
        case (.block, true): style = .blinkBlock
        case (.block, false): style = .steadyBlock
        case (.underline, true): style = .blinkUnderline
        case (.underline, false): style = .steadyUnderline
        case (.bar, true): style = .blinkBar
        case (.bar, false): style = .steadyBar
        }
        getTerminal().setCursorStyle(style)
    }

    /// A short flash over the terminal (Settings › Terminal › Bell: Visual).
    func flash() {
        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        // a11y: kept with Reduce Motion: a fade in place, nothing moves, and it's the bell you asked to see.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            overlay.animator().alphaValue = 0
        }, completionHandler: { overlay.removeFromSuperview() })
    }
}
