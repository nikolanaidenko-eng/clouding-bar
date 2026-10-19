import AppKit

// Draws the app icon — Cloud awake on a dark rounded square — as an
// .iconset at every size macOS wants; `iconutil` turns it into AppIcon.icns.
// Usage: icon <out.iconset>
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824 pt square with 185 pt corners, centred.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.23, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    shape.lineWidth = 3 * s
    shape.stroke()
    // Cloud, from the mascot's 40-unit grid (y down there, up here).
    let unit = 15 * s, ox = 212 * s, oy = 230 * s
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: ox + x * unit, y: oy + (40 - y - h) * unit, width: w * unit, height: h * unit)
    }
    NSColor.black.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: r(11, 34, 18, 3.2)).fill()
    NSColor(calibratedRed: 0.925, green: 0.918, blue: 0.898, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(7, 11, 26, 23), xRadius: 11.5 * unit, yRadius: 11.5 * unit).fill()
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(ovalIn: r(14, 18.2, 4, 5.6)).fill()
    NSBezierPath(ovalIn: r(22, 18.2, 4, 5.6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try? draw(size * scale)?.write(to: out.appendingPathComponent(name))
    }
}
print(out.path)
