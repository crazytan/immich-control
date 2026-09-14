import AppKit

// Native symbol artwork keeps the application icon consistent with its menu.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                      pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let unit = CGFloat(pixels)
        let bounds = NSRect(x: unit * 0.08, y: unit * 0.08, width: unit * 0.84, height: unit * 0.84)
        NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: unit * 0.19, yRadius: unit * 0.19).fill()
        if let symbol = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: unit * 0.48, weight: .medium)) {
            let whiteSymbol = NSImage(size: symbol.size)
            whiteSymbol.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
            whiteSymbol.unlockFocus()
            let width = unit * 0.58
            let height = width * symbol.size.height / symbol.size.width
            whiteSymbol.draw(in: NSRect(x: (unit - width) / 2, y: (unit - height) / 2, width: width, height: height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: destination.appendingPathComponent(name))
    }
}
if CommandLine.arguments.count > 2 {
    var chunks = Data()
    let entries = [("icp4", "16x16"), ("icp5", "32x32"),
                   ("ic07", "128x128"), ("ic08", "256x256"),
                   ("ic09", "512x512"), ("ic10", "512x512@2x"),
                   ("ic11", "16x16@2x"), ("ic12", "32x32@2x"),
                   ("ic13", "128x128@2x"), ("ic14", "256x256@2x")]
    func lengthBytes(_ count: Int) -> Data {
        var length = UInt32(count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }
    for (type, name) in entries {
        let png = try Data(contentsOf: destination.appendingPathComponent("icon_\(name).png"))
        chunks.append(Data(type.utf8))
        chunks.append(lengthBytes(png.count + 8))
        chunks.append(png)
    }
    var icon = Data("icns".utf8)
    icon.append(lengthBytes(chunks.count + 8))
    icon.append(chunks)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
