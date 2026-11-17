// Draws the app icons for the Mac and Watch apps and writes the asset
// catalogs. Run from the project root:  swift Scripts/make-icons.swift
//
// Design: a graphite MacBook on light brushed metal, its black screen
// showing a red heartbeat ending in a heart. The Watch icon is full-bleed (watchOS masks it to a circle);
// the Mac icon sits on the standard macOS rounded-square grid with a shadow.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let metal = CGGradient(colorsSpace: space,
                       colors: [color(0.97, 0.97, 0.98), color(0.88, 0.88, 0.90), color(0.76, 0.77, 0.80)] as CFArray,
                       locations: [0, 0.55, 1])!

/// Heart outline in a unit box (y up), tip at the bottom.
func heartPath(in r: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    let path = CGMutablePath()
    path.move(to: p(0.5, 0.0))
    path.addCurve(to: p(0.0, 0.64), control1: p(0.28, 0.20), control2: p(0.0, 0.38))
    path.addCurve(to: p(0.5, 0.80), control1: p(0.0, 0.98), control2: p(0.40, 1.02))
    path.addCurve(to: p(1.0, 0.64), control1: p(0.60, 1.02), control2: p(1.0, 0.98))
    path.addCurve(to: p(0.5, 0.0), control1: p(1.0, 0.38), control2: p(0.72, 0.20))
    path.closeSubpath()
    return path
}

let accent = color(1.0, 0.22, 0.32)

/// Metal background and a graphite MacBook whose black screen shows a red
/// heartbeat with a small heart, inside `canvas`. `scale` is the laptop
/// width as a fraction of the canvas.
func drawArtwork(_ ctx: CGContext, canvas: CGRect, heartScale scale: CGFloat) {
    ctx.saveGState()
    // Light brushed aluminium: vertical gradient plus faint horizontal grain.
    ctx.drawLinearGradient(metal, start: CGPoint(x: canvas.midX, y: canvas.maxY),
                           end: CGPoint(x: canvas.midX, y: canvas.minY), options: [])
    var y = canvas.minY
    var row = 0
    while y < canvas.maxY {
        let shade: CGFloat = row % 3 == 0 ? 1 : 0
        ctx.setFillColor(color(shade, shade, shade, 0.018))
        ctx.fill(CGRect(x: canvas.minX, y: y, width: canvas.width, height: canvas.height / 512))
        y += canvas.height / 256
        row += 1
    }

    let w = canvas.width * scale
    // Laptop: screen above a thin base, centred as one block.
    let screenW = w * 0.80, screenH = w * 0.54
    let baseW = w, baseH = w * 0.055, gap = w * 0.018
    let blockH = screenH + gap + baseH
    let bottom = canvas.midY - blockH / 2
    let base = CGRect(x: canvas.midX - baseW / 2, y: bottom, width: baseW, height: baseH)
    let screen = CGRect(x: canvas.midX - screenW / 2, y: bottom + baseH + gap, width: screenW, height: screenH)

    // Graphite lid and base with a soft shadow on the metal.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas.height * 0.014), blur: canvas.height * 0.04,
                  color: color(0, 0, 0, 0.30))
    ctx.setFillColor(color(0.20, 0.20, 0.22))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: w * 0.045, cornerHeight: w * 0.045, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: baseH / 2, cornerHeight: baseH / 2, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    // Black display inside a thin bezel.
    let bezel = w * 0.028
    let display = screen.insetBy(dx: bezel, dy: bezel)
    ctx.setFillColor(color(0.04, 0.04, 0.05))
    ctx.addPath(CGPath(roundedRect: display, cornerWidth: w * 0.025, cornerHeight: w * 0.025, transform: nil))
    ctx.fillPath()
    // Thumb notch on the base.
    let notch = CGRect(x: canvas.midX - w * 0.08, y: base.maxY - baseH * 0.45, width: w * 0.16, height: baseH * 0.45)
    ctx.setFillColor(color(0.42, 0.42, 0.45))
    ctx.addPath(CGPath(roundedRect: notch, cornerWidth: baseH * 0.2, cornerHeight: baseH * 0.2, transform: nil))
    ctx.fillPath()

    // Heartbeat across the screen, rising into a small heart.
    let inner = screen.insetBy(dx: screenW * 0.10, dy: screenH * 0.16)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inner.minX + x * inner.width, y: inner.minY + y * inner.height) }
    let line = CGMutablePath()
    line.move(to: p(0.0, 0.42))
    line.addLine(to: p(0.22, 0.42))
    line.addLine(to: p(0.30, 0.66))
    line.addLine(to: p(0.40, 0.08))
    line.addLine(to: p(0.50, 0.92))
    line.addLine(to: p(0.58, 0.42))
    line.addLine(to: p(0.66, 0.42))
    ctx.addPath(line)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(w * 0.05)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
    let heartW = inner.width * 0.30
    let heartRect = CGRect(x: inner.maxX - heartW, y: inner.minY + inner.height * 0.42 - heartW * 0.40,
                           width: heartW, height: heartW * 0.92)
    ctx.addPath(heartPath(in: heartRect))
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()
}

func makeContext(_ size: Int, opaque: Bool) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func resized(_ image: CGImage, _ size: Int, opaque: Bool) -> CGImage {
    let ctx = makeContext(size, opaque: opaque)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let info = ["author": "xcode", "version": 1] as [String: Any]

// MARK: Watch: one 1024 px opaque, full-bleed image.
do {
    let ctx = makeContext(1024, opaque: true)
    drawArtwork(ctx, canvas: CGRect(x: 0, y: 0, width: 1024, height: 1024), heartScale: 0.66)
    let catalog = root.appendingPathComponent("Watch/Assets.xcassets")
    let set = catalog.appendingPathComponent("AppIcon.appiconset")
    try! fm.createDirectory(at: set, withIntermediateDirectories: true)
    writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
    write(ctx.makeImage()!, to: set.appendingPathComponent("icon-1024.png"))
    writeJSON(["images": [["filename": "icon-1024.png", "idiom": "universal", "platform": "watchos",
                           "size": "1024x1024"]], "info": info],
              to: set.appendingPathComponent("Contents.json"))
}

// MARK: Mac: rounded square on the 1024 grid (824 px body), every size.
do {
    let ctx = makeContext(1024, opaque: false)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.88, 0.88, 0.90))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    drawArtwork(ctx, canvas: body, heartScale: 0.70)
    let master = ctx.makeImage()!

    let catalog = root.appendingPathComponent("Mac/Assets.xcassets")
    let set = catalog.appendingPathComponent("AppIcon.appiconset")
    try! fm.createDirectory(at: set, withIntermediateDirectories: true)
    writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
    var images: [[String: String]] = []
    for point in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = point * scale
            let name = "icon-\(px).png"
            write(px == 1024 ? master : resized(master, px, opaque: false), to: set.appendingPathComponent(name))
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
        }
    }
    writeJSON(["images": images, "info": info], to: set.appendingPathComponent("Contents.json"))
}
print("Icons written to Watch/Assets.xcassets and Mac/Assets.xcassets")
