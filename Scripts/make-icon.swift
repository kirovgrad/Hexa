import AppKit

// A resolution-independent native drawing: no downloaded or generated image assets.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let square = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844), xRadius: 186, yRadius: 186)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 38; shadow.shadowOffset = NSSize(width: 0, height: -12)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.47, alpha: 1).setFill(); square.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(calibratedRed: 0.17, green: 0.56, blue: 0.91, alpha: 1), NSColor(calibratedRed: 0.09, green: 0.25, blue: 0.66, alpha: 1)])!.draw(in: square, angle: -80)
        NSColor.white.withAlphaComponent(0.15).setStroke(); square.lineWidth = 3; square.stroke()
        for row in 0..<3 { for column in 0..<3 {
            let box = NSRect(x: 235 + column * 195, y: 225 + row * 195, width: 164, height: 164)
            NSColor.white.withAlphaComponent(row == 1 && column == 1 ? 0.96 : 0.09).setFill()
            NSBezierPath(roundedRect: box, xRadius: 26, yRadius: 26).fill()
            if pixels >= 32 {
                let label = [["4F", "2A", "FF"], ["00", "48", "65"], ["A0", "1B", "7F"]][row][column]
                let font = NSFont.monospacedSystemFont(ofSize: 72, weight: row == 1 && column == 1 ? .semibold : .regular)
                let textSize = (label as NSString).size(withAttributes: [.font: font])
                (label as NSString).draw(at: NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2), withAttributes: [.font: font, .foregroundColor: row == 1 && column == 1 ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.85)])
            }
        } }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try representation.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// ICNS supports PNG payloads. Write the container directly so packaging also
// works when iconutil's image-conversion service is unavailable in a sandbox.
if CommandLine.arguments.count > 2 {
    func uint32(_ value: Int) -> Data { var big = UInt32(value).bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    let entries = [("icp4", "16x16"), ("icp5", "32x32"), ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x"), ("ic11", "16x16@2x"), ("ic12", "32x32@2x"), ("ic13", "128x128@2x"), ("ic14", "256x256@2x")]
    var payload = Data()
    for (type, name) in entries {
        let png = try Data(contentsOf: directory.appendingPathComponent("icon_\(name).png"))
        payload.append(Data(type.utf8)); payload.append(uint32(png.count + 8)); payload.append(png)
    }
    var icon = Data("icns".utf8); icon.append(uint32(payload.count + 8)); icon.append(payload)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
