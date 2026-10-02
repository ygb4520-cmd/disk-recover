import AppKit

// Renders the app icon (a drive glyph on a gradient squircle) into an .iconset folder.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()
    let rect = NSRect(origin: .zero, size: size).insetBy(dx: CGFloat(px) * 0.06, dy: CGFloat(px) * 0.06)
    let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(px) * 0.2, yRadius: CGFloat(px) * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.20, blue: 0.55, alpha: 1)])!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "externaldrive.badge.checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
