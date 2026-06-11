// Renders the app icon (asterisk on a dark rounded square) and emits an .icns
// via iconutil. Run: swift scripts/make_icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int, scale: Int, name: String) {
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    // macOS icon grid: content inset ~10%
    let inset = CGFloat(px) * 0.09
    let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                xRadius: CGFloat(px) * 0.20, yRadius: CGFloat(px) * 0.20)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.14, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.07, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -90)

    let text = "✳" as NSString
    let fontSize = CGFloat(px) * 0.52
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.25, alpha: 1),
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (CGFloat(px) - textSize.width) / 2,
                          y: (CGFloat(px) - textSize.height) / 2),
              withAttributes: attrs)

    image.unlockFocus()

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    draw(size: size, scale: 1, name: "icon_\(size)x\(size).png")
    draw(size: size, scale: 2, name: "icon_\(size)x\(size)@2x.png")
}
print("iconset written to \(iconset.path)")
