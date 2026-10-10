import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let rect = NSRect(x: Double(pixels) * 0.075, y: Double(pixels) * 0.075, width: Double(pixels) * 0.85, height: Double(pixels) * 0.85)
        NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Double(pixels) * 0.19, yRadius: Double(pixels) * 0.19).fill()
        if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.46, weight: .medium)) {
            let symbolRect = NSRect(x: Double(pixels) * 0.24, y: Double(pixels) * 0.24, width: Double(pixels) * 0.52, height: Double(pixels) * 0.52)
            symbol.withSymbolConfiguration(.init(paletteColors: [.white]))?.draw(in: symbolRect)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon export failed") }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: directory.appendingPathComponent(name))
    }
}
