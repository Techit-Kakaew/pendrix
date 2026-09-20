// App icon: indigo glass squircle, 3/4 white ring open at the bottom, an amber dot resting in the gap.
// "Pending" = the ring is not closed yet. Usage: swift scripts/make_appicon.swift <appiconset dir> [preview.png]
import AppKit

func squircle(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.width * 0.2237, cornerHeight: r.height * 0.2237, transform: nil) }

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let prev = NSGraphicsContext.current
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!; NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    let S = CGFloat(px), inset = S * 0.1
    let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    g.addPath(squircle(box)); g.setFillColor(NSColor.black.cgColor); g.fillPath()
    g.restoreGState()

    g.saveGState(); g.addPath(squircle(box)); g.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1).cgColor,
                                 NSColor(red: 0.18, green: 0.22, blue: 0.62, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(bg, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(gloss, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY - box.height * 0.1), options: [])
    g.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor); g.setLineWidth(S * 0.006)
    g.addPath(squircle(box.insetBy(dx: S * 0.004, dy: S * 0.004))); g.strokePath()

    // ring
    let c = CGPoint(x: box.midX, y: box.midY + box.height * 0.02), R = box.width * 0.26
    g.setLineWidth(box.width * 0.085); g.setLineCap(.round); g.setStrokeColor(NSColor.white.cgColor)
    g.addArc(center: c, radius: R, startAngle: -.pi * 0.25, endAngle: .pi * 1.25, clockwise: false); g.strokePath()
    // dot
    let d = CGPoint(x: c.x, y: c.y - R), r = box.width * 0.062
    g.saveGState()
    g.setShadow(offset: .zero, blur: S * 0.05, color: NSColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.9).cgColor)
    g.setFillColor(NSColor(red: 1.0, green: 0.87, blue: 0.45, alpha: 1).cgColor)
    g.addEllipse(in: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)); g.fillPath()
    g.restoreGState()
    g.restoreGState()
    NSGraphicsContext.current = prev
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px: base * scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
if CommandLine.arguments.count > 2 {
    try! render(px: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("icons → \(out)")
