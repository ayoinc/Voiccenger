// Renders Voiccenger artwork with Core Graphics (no external tools).
// Usage: swift scripts/MakeArtwork.swift
//
// Output:
//   Resources/AppIcon.icns   app icon (all macOS sizes, via iconutil)
//   Resources/Assets.xcassets/AppIcon.appiconset   same icon as an asset catalog (Mac App Store build)
//   docs/icon.png            512 px icon for the README
//   docs/banner.png          README banner
//   Resources/dmg-background.tiff   installer window background (1x + 2x), 660 × 400 pt
//
// Motif: a meeting table seen from above. Radial waveform bars form the ring of seats;
// each seat dot is a speaker colour, the active speaker's bars are tall and a direction
// beam points at them (transcription + speaker identity + seat direction in one mark).
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let docs = root.appendingPathComponent("docs")
let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let indigo = rgb(0x24175E)
let violet = rgb(0x4B2FB0)
let teal = rgb(0x12B8A6)
let speakerColors: [UInt32] = [0xFFB547, 0xFF6B8B, 0x7DE3FF, 0xB7F57A, 0xC9A7FF]
let seatAngles: [Double] = [90, 162, 234, 306, 18]  // degrees, counter-clockwise from +x
let activeSeat = 0

func context(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ image: CGImage, _ url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Superellipse-ish continuous corner squircle (macOS icon shape).
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n = 5.0
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

/// Deterministic speech-like envelope for bar heights around the ring.
func envelope(_ angleDeg: Double) -> Double {
    var e = 0.18 + 0.10 * (0.5 + 0.5 * sin(angleDeg * .pi / 180 * 7 + 0.6))
    e += 0.06 * sin(angleDeg * .pi / 180 * 17 + 1.3)
    for (i, seat) in seatAngles.enumerated() {
        var d = abs(angleDeg - seat).truncatingRemainder(dividingBy: 360)
        d = min(d, 360 - d)
        let gain = i == activeSeat ? 0.85 : 0.22
        let width = i == activeSeat ? 16.0 : 10.0
        e += gain * exp(-(d * d) / (2 * width * width)) * (0.8 + 0.2 * cos(angleDeg * 1.9))
    }
    return min(1, e)
}

/// Draws the mark centred at `c` with outer radius `R` (bars + seats + beam + table).
func drawMark(_ ctx: CGContext, center c: CGPoint, radius R: CGFloat) {
    let tableR = R * 0.34
    let barInner = R * 0.42
    let barMax = R * 0.40

    // Direction beam toward the active speaker.
    let a = seatAngles[activeSeat] * .pi / 180
    let spread = 0.24
    ctx.saveGState()
    let beam = CGMutablePath()
    beam.move(to: c)
    beam.addArc(center: c, radius: R * 0.98, startAngle: a - spread, endAngle: a + spread, clockwise: false)
    beam.closeSubpath()
    ctx.addPath(beam)
    ctx.clip()
    let beamGrad = CGGradient(
        colorsSpace: nil, colors: [rgb(speakerColors[activeSeat], 0.55), rgb(speakerColors[activeSeat], 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(beamGrad, startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [])
    ctx.restoreGState()

    // Table.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - tableR, y: c.y - tableR, width: tableR * 2, height: tableR * 2))
    ctx.clip()
    let tableGrad = CGGradient(
        colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        tableGrad, start: CGPoint(x: c.x - tableR, y: c.y + tableR), end: CGPoint(x: c.x + tableR, y: c.y - tableR),
        options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
    ctx.setLineWidth(max(1, R * 0.012))
    ctx.strokeEllipse(in: CGRect(x: c.x - tableR, y: c.y - tableR, width: tableR * 2, height: tableR * 2))

    // Radial waveform bars.
    let count = 72
    let barWidth = max(1.5, 2 * .pi * barInner / CGFloat(count) * 0.52)
    ctx.setLineCap(.round)
    for i in 0..<count {
        let deg = Double(i) / Double(count) * 360
        let rad = deg * .pi / 180
        let len = barMax * CGFloat(envelope(deg))
        let dir = CGPoint(x: cos(rad), y: sin(rad))
        // Bars near a seat take that seat's colour; others are white.
        var color = rgb(0xFFFFFF, 0.85)
        for (s, seat) in seatAngles.enumerated() {
            var d = abs(deg - seat).truncatingRemainder(dividingBy: 360)
            d = min(d, 360 - d)
            if d < (s == activeSeat ? 26 : 14) { color = rgb(speakerColors[s], s == activeSeat ? 1 : 0.9) }
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(barWidth)
        ctx.move(to: CGPoint(x: c.x + dir.x * barInner, y: c.y + dir.y * barInner))
        ctx.addLine(to: CGPoint(x: c.x + dir.x * (barInner + len), y: c.y + dir.y * (barInner + len)))
        ctx.strokePath()
    }

    // Seats (speaker dots) on the inner edge of the bar ring.
    let seatR = R * 0.075
    for (s, seat) in seatAngles.enumerated() {
        let rad = seat * .pi / 180
        let p = CGPoint(x: c.x + cos(rad) * (tableR + (barInner - tableR) / 2), y: c.y + sin(rad) * (tableR + (barInner - tableR) / 2))
        let r = s == activeSeat ? seatR * 1.25 : seatR
        if s == activeSeat {
            ctx.setShadow(offset: .zero, blur: R * 0.08, color: rgb(speakerColors[s], 0.9))
        }
        ctx.setFillColor(rgb(speakerColors[s]))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
        ctx.setLineWidth(max(1, R * 0.012))
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Centre: direction-of-arrival pointer.
    let pr = tableR * 0.55
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.95))
    ctx.setLineWidth(max(1.5, R * 0.022))
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * pr, y: c.y + sin(a) * pr))
    ctx.strokePath()
    ctx.setFillColor(rgb(0xFFFFFF))
    let hub = R * 0.035
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
}

func background(_ ctx: CGContext, in rect: CGRect) {
    let g = CGGradient(colorsSpace: nil, colors: [indigo, violet, teal] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(
        g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Soft top highlight.
    let hl = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
}

func renderIcon(size: Int) -> CGImage {
    let ctx = context(size, size)
    let s = CGFloat(size)
    // macOS icon grid: 824/1024 body with drop shadow.
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024 + s * 0.012, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(indigo)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    background(ctx, in: body)
    drawMark(ctx, center: CGPoint(x: body.midX, y: body.midY), radius: body.width * 0.55)
    ctx.restoreGState()

    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(max(1, s / 512))
    ctx.strokePath()
    return ctx.makeImage()!
}

func renderBanner(width: Int, height: Int) -> CGImage {
    let ctx = context(width, height)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.clip()
    background(ctx, in: rect)

    // Faint large mark on the right as texture.
    ctx.saveGState()
    ctx.setAlpha(0.12)
    drawMark(ctx, center: CGPoint(x: CGFloat(width) * 0.95, y: CGFloat(height) * 0.5), radius: CGFloat(height) * 0.62)
    ctx.restoreGState()

    let icon = renderIcon(size: 1024)
    let iconSize = CGFloat(height) * 0.78
    ctx.draw(icon, in: CGRect(x: CGFloat(height) * 0.12, y: (CGFloat(height) - iconSize) / 2, width: iconSize, height: iconSize))

    let textX = CGFloat(height) * 0.12 + iconSize + CGFloat(height) * 0.06
    let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let title = NSAttributedString(
        string: "Voiccenger",
        attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(height) * 0.2, weight: .bold),
            .foregroundColor: NSColor.white,
            .kern: -1.5,
        ])
    title.draw(at: CGPoint(x: textX, y: CGFloat(height) * 0.48))
    let tagline = NSAttributedString(
        string: "Every voice in the meeting — transcribed, named and placed.",
        attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(height) * 0.065, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
        ])
    tagline.draw(at: CGPoint(x: textX + 4, y: CGFloat(height) * 0.34))
    let chips = NSAttributedString(
        string: "On-device  ·  Speaker ID  ·  GCC-PHAT seats  ·  Live corrections  ·  Meeting reports",
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(height) * 0.038, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ])
    chips.draw(at: CGPoint(x: textX + 4, y: CGFloat(height) * 0.22))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

// App icon set → .icns
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try savePNG(renderIcon(size: base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try savePNG(renderIcon(size: base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = resources.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")

// Asset catalog copy of the icon; the App Store build compiles it with actool into Assets.car.
let appiconset = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.removeItem(at: appiconset)
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try savePNG(renderIcon(size: base * scale), appiconset.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": file])
    }
}
let catalogInfo = ["author": "xcode", "version": "1"]
try JSONSerialization.data(withJSONObject: ["images": images, "info": catalogInfo], options: [.prettyPrinted, .sortedKeys])
    .write(to: appiconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": catalogInfo], options: [.prettyPrinted, .sortedKeys])
    .write(to: resources.appendingPathComponent("Assets.xcassets/Contents.json"))
print("wrote Resources/Assets.xcassets")

try savePNG(renderIcon(size: 512), docs.appendingPathComponent("icon.png"))
print("wrote docs/icon.png")
try savePNG(renderBanner(width: 1600, height: 480), docs.appendingPathComponent("banner.png"))
print("wrote docs/banner.png")

/// Installer window background. Finder draws the app icon at (165, 190) and the Applications
/// link at (495, 190) (points, top-left origin); scripts/make-dmg.sh uses the same positions.
func renderDMGBackground(scale: Int) -> CGImage {
    let w = 660 * scale, h = 400 * scale
    let s = CGFloat(scale)
    let ctx = context(w, h)
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0xF5F2FF), rgb(0xE7F8F5)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])

    ctx.saveGState()
    ctx.setAlpha(0.07)
    drawMark(ctx, center: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.52), radius: CGFloat(h) * 0.55)
    ctx.restoreGState()

    // Arrow from the app slot to the Applications slot.
    let y = CGFloat(400 - 190) * s
    ctx.setStrokeColor(rgb(0x4B2FB0, 0.75))
    ctx.setLineWidth(5 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 262 * s, y: y))
    ctx.addLine(to: CGPoint(x: 398 * s, y: y))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 380 * s, y: y + 16 * s))
    ctx.addLine(to: CGPoint(x: 400 * s, y: y))
    ctx.addLine(to: CGPoint(x: 380 * s, y: y - 16 * s))
    ctx.strokePath()

    let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    NSAttributedString(
        string: "Drag Voiccenger to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15 * s, weight: .medium),
            .foregroundColor: NSColor(cgColor: rgb(0x24175E, 0.8))!,
            .paragraphStyle: para,
        ]
    ).draw(in: CGRect(x: 0, y: 52 * s, width: CGFloat(w), height: 24 * s))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

let bgDir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dmg-bg")
try? FileManager.default.removeItem(at: bgDir)
try FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)
try savePNG(renderDMGBackground(scale: 1), bgDir.appendingPathComponent("background.png"))
try savePNG(renderDMGBackground(scale: 2), bgDir.appendingPathComponent("background@2x.png"))
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = [
    "-cathidpicheck", bgDir.appendingPathComponent("background.png").path,
    bgDir.appendingPathComponent("background@2x.png").path,
    "-out", resources.appendingPathComponent("dmg-background.tiff").path,
]
try tiff.run()
tiff.waitUntilExit()
guard tiff.terminationStatus == 0 else { fatalError("tiffutil failed") }
try? FileManager.default.removeItem(at: bgDir)
print("wrote Resources/dmg-background.tiff")
