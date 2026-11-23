// Draws the MacDirStat app icon (a little cushion treemap) into an .iconset folder.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let clip = NSBezierPath(roundedRect: body, xRadius: s * 0.19, yRadius: s * 0.19)
    NSColor(white: 0.12, alpha: 1).setFill()
    clip.fill()
    clip.addClip()
    let g = s * 0.012
    // rects in unit coordinates (x, y, w, h) with colors
    let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.00, 0.00, 0.55, 0.62, NSColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)),
        (0.00, 0.62, 0.55, 0.38, NSColor(red: 0.20, green: 0.66, blue: 0.33, alpha: 1)),
        (0.55, 0.55, 0.45, 0.45, NSColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1)),
        (0.55, 0.25, 0.25, 0.30, NSColor(red: 0.98, green: 0.74, blue: 0.02, alpha: 1)),
        (0.80, 0.25, 0.20, 0.30, NSColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1)),
        (0.55, 0.00, 0.17, 0.25, NSColor(red: 0.00, green: 0.74, blue: 0.83, alpha: 1)),
        (0.72, 0.00, 0.14, 0.25, NSColor(red: 1.00, green: 0.44, blue: 0.26, alpha: 1)),
        (0.86, 0.00, 0.14, 0.25, NSColor(red: 0.49, green: 0.70, blue: 0.26, alpha: 1)),
    ]
    for (x, y, w, h, c) in tiles {
        let r = NSRect(x: body.minX + x * body.width + g, y: body.minY + y * body.height + g,
                       width: w * body.width - 2 * g, height: h * body.height - 2 * g)
        let grad = NSGradient(colors: [c.blended(withFraction: 0.45, of: .white)!, c, c.blended(withFraction: 0.55, of: .black)!])!
        grad.draw(in: NSBezierPath(rect: r), relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
