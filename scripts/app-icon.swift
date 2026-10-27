// Draws VibeSwitcher's app icon with CoreGraphics, so it can be redrawn: nothing here needs more than macOS.
//
//   bash scripts/app-icon.sh                               # the app icon: Resources/AppIcon.icns, Web/icon-192.png, icon-512.png
//   swift scripts/app-icon.swift concepts docs/eval/logo   # every concept: master, contact sheet, Dock mocks, overview
//
// Shapes follow the macOS icon grid: a 1024 canvas, an 824 px rounded-square body centred on it, a soft shadow below.
// The status marks and colours are the app's own (StatusMark and StatusPalette in Sources/VibeCore/MenuBarDots.swift).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colours

struct RGB {
    let r, g, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

/// StatusPalette.ink: `dark` is the dark-mode ink (bright, for a dark body), `light` the light-mode one.
enum Ink {
    static let needsDark = RGB(0xFF7A72), needsLight = RGB(0xC4001A)
    static let workingDark = RGB(0xFF9F0A), workingLight = RGB(0x9C4400)
    static let backgroundDark = RGB(0x5EB0FF), backgroundLight = RGB(0x0058B8)
    static let doneDark = RGB(0x30D158), doneLight = RGB(0x1A7330)
    /// StatusPalette.onInk: the glyph on a dark-mode fill, and on a light-mode one.
    static let onDark = RGB(0x1F1F1F), onLight = RGB(0xFFFFFF)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Device pixels per canvas unit while drawing: shadows are in device space, so they're scaled by hand.
var unit: CGFloat = 1

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

func shadow(_ c: CGContext, y: CGFloat, blur: CGFloat, alpha: CGFloat, color: RGB = RGB(0x000000)) {
    c.setShadow(offset: CGSize(width: 0, height: y * unit), blur: blur * unit, color: color.cg(alpha))
}

// MARK: - The body: macOS's rounded square

let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)

/// A superellipse (|x|ⁿ + |y|ⁿ = 1), close to the continuous-corner square macOS icons use.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let (cx, sy) = (cos(t), sin(t))
        let x = rect.midX + rect.width / 2 * (cx < 0 ? -1 : 1) * pow(abs(cx), 2 / n)
        let y = rect.midY + rect.height / 2 * (sy < 0 ? -1 : 1) * pow(abs(sy), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The body with its shadow, filled top to bottom with `top` → `bottom`, and a faint light edge along the top.
func drawBody(_ c: CGContext, top: RGB, bottom: RGB, edge: CGFloat = 0.10) {
    let body = squircle(bodyRect)
    c.saveGState()
    shadow(c, y: -12, blur: 28, alpha: 0.32)
    c.addPath(body)
    c.setFillColor(bottom.cg())
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(body)
    c.clip()
    c.drawLinearGradient(gradient([top.cg(), bottom.cg()]), start: CGPoint(x: 512, y: bodyRect.maxY),
                         end: CGPoint(x: 512, y: bodyRect.minY), options: [])
    // The edge: a hairline of light, strongest at the top.
    c.addPath(body)
    c.setLineWidth(6)
    c.replacePathWithStrokedPath()
    c.clip()
    c.drawLinearGradient(gradient([CGColor(gray: 1, alpha: edge), CGColor(gray: 1, alpha: 0)]),
                         start: CGPoint(x: 512, y: bodyRect.maxY), end: CGPoint(x: 512, y: bodyRect.midY), options: [])
    c.restoreGState()
}

// MARK: - Status marks (after StatusMark: a disc with "!", a ¾ arc, a half-filled ring, a disc with a check)

enum Mark { case alert, spinner, half, check }

func drawMark(_ c: CGContext, _ mark: Mark, center: CGPoint, size d: CGFloat, color: RGB, glyph: RGB) {
    let rect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * d, y: rect.maxY - y * d) }
    c.setFillColor(color.cg())
    switch mark {
    case .alert, .check:
        c.fillEllipse(in: rect)
    case .spinner:
        let width = d * 0.28
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: (d - width) / 2, startAngle: .pi / 2, endAngle: .pi / 2 + 1.5 * .pi, clockwise: false)
        c.addPath(arc.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        c.fillPath()
    case .half:
        let width = d * 0.14
        c.addPath(CGPath(ellipseIn: rect.insetBy(dx: width / 2, dy: width / 2), transform: nil)
            .copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
        c.fillPath()
        let half = CGMutablePath()
        half.addArc(center: center, radius: d / 2, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        half.closeSubpath()
        c.addPath(half)
        c.fillPath()
    }
    c.setFillColor(glyph.cg())
    switch mark {
    case .alert:
        let a = point(0.41, 0.18), b = point(0.59, 0.60)
        let bar = CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y)
        c.addPath(CGPath(roundedRect: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2, transform: nil))
        c.fillPath()
        let dot = point(0.5, 0.77)
        c.fillEllipse(in: CGRect(x: dot.x - d * 0.095, y: dot.y - d * 0.095, width: d * 0.19, height: d * 0.19))
    case .check:
        let path = CGMutablePath()
        path.addLines(between: [point(0.27, 0.52), point(0.44, 0.69), point(0.74, 0.35)])
        c.addPath(path.copy(strokingWithWidth: d * 0.17, lineCap: .round, lineJoin: .round, miterLimit: 10))
        c.fillPath()
    case .spinner, .half:
        break
    }
}

// MARK: - Concepts

struct Concept {
    let key: String
    let name: String
    let idea: String
    /// The body's gradient, top to bottom, and how bright its top edge is.
    let top: RGB, bottom: RGB, edge: CGFloat
    /// What sits on the body, in the 1024 canvas.
    let motif: (CGContext) -> Void

    /// The Mac icon: the body, its shadow and the motif.
    func draw(_ c: CGContext) {
        drawBody(c, top: top, bottom: bottom, edge: edge)
        motif(c)
    }

    /// The phone's icon: the body's gradient to every edge (the phone cuts its own shape), and the motif shrunk so all
    /// of it, shadows included, stays inside the central circle a maskable icon keeps (80 % of the side).
    func drawFullBleed(_ c: CGContext) {
        c.drawLinearGradient(gradient([top.cg(), bottom.cg()]), start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0),
                             options: [])
        c.translateBy(x: 512, y: 512)
        c.scaleBy(x: Self.phoneScale, y: Self.phoneScale)
        c.translateBy(x: -512, y: -512)
        unit *= Self.phoneScale
        motif(c)
    }

    static let phoneScale: CGFloat = 0.85
}

/// Stacked sessions: the front one needs you, the ones behind are working and done.
func drawStack(_ c: CGContext) {
    let front = CGRect(x: 212, y: 236, width: 600, height: 414)
    let middle = CGRect(x: 262, y: front.maxY - 300, width: 500, height: 374)
    let back = CGRect(x: 312, y: middle.maxY - 300, width: 400, height: 374)
    let radius: CGFloat = 58
    func card(_ rect: CGRect, top: RGB, bottom: RGB) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        c.saveGState()
        shadow(c, y: -10, blur: 26, alpha: 0.45)
        c.addPath(path)
        c.setFillColor(bottom.cg())
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(path)
        c.clip()
        c.drawLinearGradient(gradient([top.cg(), bottom.cg()]), start: CGPoint(x: 0, y: rect.maxY),
                             end: CGPoint(x: 0, y: rect.minY), options: [])
        c.restoreGState()
    }
    card(back, top: RGB(0x6A6E78), bottom: RGB(0x4E525B))
    drawMark(c, .check, center: CGPoint(x: back.minX + 74, y: back.maxY - 37), size: 46, color: Ink.doneDark, glyph: Ink.onDark)
    card(middle, top: RGB(0x8E929C), bottom: RGB(0x6F737D))
    drawMark(c, .spinner, center: CGPoint(x: middle.minX + 76, y: middle.maxY - 37), size: 46, color: Ink.workingDark,
             glyph: Ink.onDark)
    card(front, top: RGB(0xFFFFFF), bottom: RGB(0xE6E7EB))
    drawMark(c, .alert, center: CGPoint(x: front.minX + 150, y: front.midY), size: 172, color: Ink.needsLight, glyph: Ink.onLight)
    c.setFillColor(RGB(0xC3C5CC).cg())
    for (y, width) in [(front.midY + 30, CGFloat(270)), (front.midY - 60, CGFloat(190))] {
        let bar = CGRect(x: front.minX + 278, y: y, width: width, height: 34)
        c.addPath(CGPath(roundedRect: bar, cornerWidth: 17, cornerHeight: 17, transform: nil))
        c.fillPath()
    }
}

/// A lead and its team: the lead (ringed, like the session you're viewing in the menu bar) above three workers.
func drawTeam(_ c: CGContext) {
    let lead = CGPoint(x: 512, y: 640)
    let team = [CGPoint(x: 268, y: 318), CGPoint(x: 512, y: 300), CGPoint(x: 756, y: 318)]
    // The links: from under the lead, curving down to each worker.
    c.saveGState()
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.38))
    c.setLineWidth(16)
    c.setLineCap(.round)
    for member in team {
        c.move(to: CGPoint(x: lead.x, y: lead.y - 120))
        c.addCurve(to: CGPoint(x: member.x, y: member.y + 90), control1: CGPoint(x: lead.x, y: lead.y - 220),
                   control2: CGPoint(x: member.x, y: member.y + 200))
    }
    c.strokePath()
    c.restoreGState()
    // The lead: a white disc in a white ring.
    c.saveGState()
    shadow(c, y: -8, blur: 24, alpha: 0.35)
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fillEllipse(in: CGRect(x: lead.x - 92, y: lead.y - 92, width: 184, height: 184))
    c.restoreGState()
    c.setStrokeColor(CGColor(gray: 1, alpha: 1))
    c.setLineWidth(18)
    c.strokeEllipse(in: CGRect(x: lead.x - 132, y: lead.y - 132, width: 264, height: 264))
    let marks: [(Mark, RGB)] = [(.spinner, Ink.workingDark), (.check, Ink.doneDark), (.half, Ink.backgroundDark)]
    for (member, (mark, color)) in zip(team, marks) {
        c.saveGState()
        shadow(c, y: -6, blur: 18, alpha: 0.35)
        drawMark(c, mark, center: member, size: 168, color: color, glyph: Ink.onDark)
        c.restoreGState()
    }
}

/// A rotary switch: the knob points at the session that needs you, among the others' marks.
func drawDial(_ c: CGContext) {
    let knob = CGPoint(x: 512, y: 448)
    let radius: CGFloat = 208
    let marks: [(Mark, RGB, CGFloat)] = [
        (.alert, Ink.needsLight, 150), (.spinner, Ink.workingLight, 110),
        (.half, Ink.backgroundLight, 70), (.check, Ink.doneLight, 30),
    ]
    for (mark, color, degrees) in marks {
        let angle = degrees * .pi / 180
        drawMark(c, mark, center: CGPoint(x: knob.x + 322 * cos(angle), y: knob.y + 322 * sin(angle)), size: 124,
                 color: color, glyph: Ink.onLight)
    }
    let knobRect = CGRect(x: knob.x - radius, y: knob.y - radius, width: 2 * radius, height: 2 * radius)
    c.saveGState()
    shadow(c, y: -18, blur: 36, alpha: 0.38)
    c.setFillColor(RGB(0x1E1F23).cg())
    c.fillEllipse(in: knobRect)
    c.restoreGState()
    c.saveGState()
    c.addEllipse(in: knobRect)
    c.clip()
    c.drawRadialGradient(gradient([RGB(0x55575E).cg(), RGB(0x1B1C20).cg()]),
                         startCenter: CGPoint(x: knob.x - 60, y: knob.y + 90), startRadius: 0,
                         endCenter: knob, endRadius: radius, options: [.drawsAfterEndLocation])
    c.restoreGState()
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
    c.setLineWidth(6)
    c.strokeEllipse(in: knobRect.insetBy(dx: 3, dy: 3))
    // The pointer, towards "needs you".
    let angle: CGFloat = 150 * .pi / 180
    c.setStrokeColor(CGColor(gray: 1, alpha: 1))
    c.setLineWidth(40)
    c.setLineCap(.round)
    c.move(to: CGPoint(x: knob.x + 40 * cos(angle), y: knob.y + 40 * sin(angle)))
    c.addLine(to: CGPoint(x: knob.x + 160 * cos(angle), y: knob.y + 160 * sin(angle)))
    c.strokePath()
}

/// A terminal prompt whose cursor is a status mark: a session waiting on you.
func drawPrompt(_ c: CGContext) {
    c.setStrokeColor(CGColor(gray: 1, alpha: 1))
    c.setLineWidth(96)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: 268, y: 690))
    c.addLine(to: CGPoint(x: 498, y: 512))
    c.addLine(to: CGPoint(x: 268, y: 334))
    c.strokePath()
    let cursor = CGPoint(x: 702, y: 392)
    c.saveGState()
    shadow(c, y: 0, blur: 70, alpha: 0.75, color: Ink.needsDark)
    drawMark(c, .alert, center: cursor, size: 216, color: Ink.needsDark, glyph: Ink.onDark)
    c.restoreGState()
}

/// The app's icon is the first; the others are the concepts it was picked from (docs/eval/logo), kept so they redraw.
let concepts = [
    Concept(key: "a-stack", name: "A · Stack", idea: "Stacked sessions: the front one needs you, behind it one works and one is done.",
            top: RGB(0x3B3E46), bottom: RGB(0x16171B), edge: 0.10, motif: drawStack),
    Concept(key: "b-team", name: "B · Team", idea: "A lead, ringed like the session you're viewing, linked to its team of three.",
            top: RGB(0x3D43A3), bottom: RGB(0x15173F), edge: 0.16, motif: drawTeam),
    Concept(key: "c-dial", name: "C · Dial", idea: "A rotary switch whose knob points at the session that needs you.",
            top: RGB(0xFCFCFD), bottom: RGB(0xD5D7DD), edge: 0.6, motif: drawDial),
    Concept(key: "d-prompt", name: "D · Prompt", idea: "A terminal prompt whose cursor is the \"needs you\" mark.",
            top: RGB(0x2C2C31), bottom: RGB(0x0C0C0E), edge: 0.14, motif: drawPrompt),
]
let appIcon = concepts[0]

// MARK: - Rendering

/// A bitmap to draw in: transparent for an icon, opaque (smaller files) for a sheet.
func context(_ width: Int, _ height: Int, opaque: Bool = true) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
}

/// One concept at `px` × `px`, drawn at that size (not scaled down from the master).
func render(_ concept: Concept, px: Int) -> CGImage {
    let c = context(px, px, opaque: false)
    unit = CGFloat(px) / 1024
    c.scaleBy(x: unit, y: unit)
    concept.draw(c)
    unit = 1
    return c.makeImage()!
}

/// The phone's icon at `px` × `px`: opaque, square, the motif inside the maskable safe zone.
func renderPhone(_ concept: Concept, px: Int) -> CGImage {
    let c = context(px, px)
    unit = CGFloat(px) / 1024
    c.scaleBy(x: unit, y: unit)
    concept.drawFullBleed(c)
    unit = 1
    return c.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(path)") }
}

func text(_ c: CGContext, _ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .black, width: CGFloat? = nil) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let string = NSAttributedString(string: string, attributes: attributes)
    if let width {
        string.draw(with: CGRect(x: point.x, y: point.y, width: width, height: size * 3), options: [.usesLineFragmentOrigin])
    } else {
        string.draw(at: point)
    }
    NSGraphicsContext.restoreGraphicsState()
}

func fill(_ c: CGContext, _ rect: CGRect, _ color: RGB) {
    c.setFillColor(color.cg())
    c.fill(rect)
}

/// Draws `image` at its own pixel size with its bottom-left at `origin` (or scaled to `side`, crisp when `pixelated`).
func place(_ c: CGContext, _ image: CGImage, _ origin: CGPoint, side: CGFloat? = nil, pixelated: Bool = false) {
    c.saveGState()
    c.interpolationQuality = pixelated ? .none : .high
    let side = side ?? CGFloat(image.width)
    c.draw(image, in: CGRect(x: origin.x, y: origin.y, width: side, height: side))
    c.restoreGState()
}

/// The master at 1024, then 256, 64, 32 and 16 at their own size on light and on dark, and 32 and 16 enlarged.
func contactSheet(_ concept: Concept) -> CGImage {
    let (width, height) = (1660, 1170)
    let c = context(width, height)
    fill(c, CGRect(x: 0, y: 0, width: width, height: height), RGB(0xF2F2F4))
    text(c, concept.name, at: CGPoint(x: 40, y: height - 76), size: 40, weight: .semibold)
    text(c, concept.idea, at: CGPoint(x: 330, y: height - 70), size: 24, color: .darkGray)
    place(c, render(concept, px: 1024), CGPoint(x: 40, y: 40))
    let x0: CGFloat = 1100
    let sizes = [256, 64, 32, 16]
    for (row, (background, ink)) in [(RGB(0xFFFFFF), NSColor.darkGray), (RGB(0x1E1E1E), NSColor.lightGray)].enumerated() {
        let band = CGRect(x: x0 - 20, y: CGFloat(height) - 100 - CGFloat(row + 1) * 340, width: 540, height: 320)
        fill(c, band, background)
        var x = band.minX + 20
        for px in sizes {
            let y = band.minY + 50
            place(c, render(concept, px: px), CGPoint(x: x, y: y))
            text(c, "\(px)", at: CGPoint(x: x, y: band.minY + 14), size: 18, color: ink)
            x += CGFloat(px) + 34
        }
    }
    let band = CGRect(x: x0 - 20, y: 40, width: 540, height: 330)
    fill(c, band, RGB(0xFFFFFF))
    place(c, render(concept, px: 32), CGPoint(x: band.minX + 30, y: band.minY + 60), side: 224, pixelated: true)
    text(c, "32 at 7×", at: CGPoint(x: band.minX + 30, y: band.minY + 22), size: 18, color: .darkGray)
    place(c, render(concept, px: 16), CGPoint(x: band.minX + 286, y: band.minY + 60), side: 224, pixelated: true)
    text(c, "16 at 14×", at: CGPoint(x: band.minX + 286, y: band.minY + 22), size: 18, color: .darkGray)
    return c.makeImage()!
}

/// The concept in a Dock between some of macOS's own apps, on a light or a dark wallpaper.
func dockMock(_ concept: Concept, dark: Bool) -> CGImage {
    let (width, height) = (1400, 440)
    let c = context(width, height)
    let wallpaper = dark ? [RGB(0x141833), RGB(0x3B1D44)] : [RGB(0xC9E0F8), RGB(0xF7D7E5)]
    c.drawLinearGradient(gradient(wallpaper.map { $0.cg() }), start: CGPoint(x: 0, y: CGFloat(height)),
                         end: CGPoint(x: CGFloat(width), y: 0), options: [])
    let apps = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Photos.app", "/System/Applications/Mail.app",
                "/System/Applications/Utilities/Terminal.app", nil, "/System/Applications/Notes.app",
                "/System/Applications/Calendar.app", "/System/Applications/System Settings.app"]
    let icon: CGFloat = 128, padding: CGFloat = 12
    let dock = CGRect(x: (CGFloat(width) - CGFloat(apps.count) * icon - 2 * padding) / 2, y: 30,
                      width: CGFloat(apps.count) * icon + 2 * padding, height: icon + 2 * padding)
    let dockPath = CGPath(roundedRect: dock, cornerWidth: 34, cornerHeight: 34, transform: nil)
    c.addPath(dockPath)
    c.setFillColor(dark ? RGB(0x2A2A30).cg(0.62) : CGColor(gray: 1, alpha: 0.42))
    c.fillPath()
    c.addPath(dockPath)
    c.setStrokeColor(CGColor(gray: 1, alpha: dark ? 0.16 : 0.6))
    c.setLineWidth(2)
    c.strokePath()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    for (index, app) in apps.enumerated() {
        let rect = CGRect(x: dock.minX + padding + CGFloat(index) * icon, y: dock.minY + padding, width: icon, height: icon)
        if let app {
            NSWorkspace.shared.icon(forFile: app).draw(in: rect)
        } else {
            place(c, render(concept, px: Int(icon)), rect.origin)
            c.setFillColor(dark ? CGColor(gray: 1, alpha: 0.8) : CGColor(gray: 0, alpha: 0.6))
            c.fillEllipse(in: CGRect(x: rect.midX - 4, y: dock.minY + 2, width: 8, height: 8))
            // The name, as the Dock shows it on hover.
            let label = CGRect(x: rect.midX - 92, y: dock.maxY + 18, width: 184, height: 44)
            c.addPath(CGPath(roundedRect: label, cornerWidth: 10, cornerHeight: 10, transform: nil))
            c.setFillColor(dark ? RGB(0x3A3A40).cg(0.9) : CGColor(gray: 1, alpha: 0.85))
            c.fillPath()
            let name = "VibeSwitcher"
            let nameWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 20)]).width
            text(c, name, at: CGPoint(x: label.midX - nameWidth / 2, y: label.minY + 10), size: 20, color: dark ? .white : .black)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return c.makeImage()!
}

/// Every concept side by side: large, then at 64, 32 and 16 on light and on dark, with its idea.
func overview() -> CGImage {
    let column: CGFloat = 400, margin: CGFloat = 40
    let width = Int(CGFloat(concepts.count) * column + margin), height = 820
    let c = context(width, height)
    fill(c, CGRect(x: 0, y: 0, width: width, height: height), RGB(0xF2F2F4))
    text(c, "VibeSwitcher: logo concepts", at: CGPoint(x: margin, y: CGFloat(height) - 70), size: 34, weight: .semibold)
    for (index, concept) in concepts.enumerated() {
        let x = margin + CGFloat(index) * column
        place(c, render(concept, px: 1024), CGPoint(x: x, y: 380), side: 360)
        text(c, concept.name, at: CGPoint(x: x + 10, y: 330), size: 26, weight: .semibold)
        text(c, concept.idea, at: CGPoint(x: x + 10, y: 250), size: 17, color: .darkGray, width: 340)
        for (row, background) in [RGB(0xFFFFFF), RGB(0x1E1E1E)].enumerated() {
            let band = CGRect(x: x, y: 130 - CGFloat(row) * 100, width: 360, height: 90)
            fill(c, band, background)
            var cx = band.minX + 16
            for px in [64, 32, 16] {
                place(c, render(concept, px: px), CGPoint(x: cx, y: band.minY + (90 - CGFloat(px)) / 2))
                cx += CGFloat(px) + 30
            }
        }
    }
    return c.makeImage()!
}

// MARK: - Commands

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "concepts":
    let out = arguments.dropFirst().first ?? "docs/eval/logo"
    for concept in concepts {
        write(render(concept, px: 1024), to: "\(out)/\(concept.key)-1024.png")
        write(contactSheet(concept), to: "\(out)/\(concept.key)-sizes.png")
        write(dockMock(concept, dark: false), to: "\(out)/\(concept.key)-dock-light.png")
        write(dockMock(concept, dark: true), to: "\(out)/\(concept.key)-dock-dark.png")
    }
    write(overview(), to: "\(out)/overview.png")
    print("Wrote \(concepts.count) concepts and overview.png to \(out)")
case "iconset" where arguments.count == 2:
    // The sizes iconutil reads from an .iconset folder, each drawn at its own size.
    let out = arguments.dropFirst().first!
    for points in [16, 32, 128, 256, 512] {
        write(render(appIcon, px: points), to: "\(out)/icon_\(points)x\(points).png")
        write(render(appIcon, px: points * 2), to: "\(out)/icon_\(points)x\(points)@2x.png")
    }
case "phone" where arguments.count == 3:
    let size = Int(arguments.dropFirst().first!)!
    write(renderPhone(appIcon, px: size), to: arguments.last!)
default:
    print("""
    usage: swift scripts/app-icon.swift concepts [folder]   # the concept sheets (docs/eval/logo)
           swift scripts/app-icon.swift iconset FOLDER       # the app icon's .iconset, for iconutil
           swift scripts/app-icon.swift phone SIZE FILE      # the phone web app's icon, a maskable PNG
    scripts/app-icon.sh runs the last two: it redraws Resources/AppIcon.icns and Web/icon-192.png, Web/icon-512.png.
    """)
    exit(2)
}
