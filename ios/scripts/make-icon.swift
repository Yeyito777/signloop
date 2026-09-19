import AppKit

// Reproducible original app icon, drawn locally without external assets.
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(red: 0.047, green: 0.063, blue: 0.051, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let green = NSColor(red: 0.73, green: 0.98, blue: 0.36, alpha: 1)
green.setStroke()
let loop = NSBezierPath()
loop.lineWidth = 70
loop.lineCapStyle = .round
loop.move(to: NSPoint(x: 305, y: 405))
loop.curve(to: NSPoint(x: 719, y: 619), controlPoint1: NSPoint(x: 125, y: 685), controlPoint2: NSPoint(x: 525, y: 885))
loop.curve(to: NSPoint(x: 305, y: 405), controlPoint1: NSPoint(x: 899, y: 339), controlPoint2: NSPoint(x: 499, y: 139))
loop.stroke()
NSColor(red: 0.047, green: 0.063, blue: 0.051, alpha: 1).setStroke()
let gap = NSBezierPath()
gap.lineWidth = 115
gap.move(to: NSPoint(x: 395, y: 380))
gap.line(to: NSPoint(x: 629, y: 644))
gap.stroke()
green.setStroke()
let diagonal = NSBezierPath()
diagonal.lineWidth = 57
diagonal.lineCapStyle = .round
diagonal.move(to: NSPoint(x: 365, y: 346))
diagonal.line(to: NSPoint(x: 659, y: 678))
diagonal.stroke()
NSColor.white.setFill()
for point in [NSPoint(x: 365, y: 346), NSPoint(x: 659, y: 678)] {
    NSBezierPath(ovalIn: NSRect(x: point.x - 36, y: point.y - 36, width: 72, height: 72)).fill()
}
NSGraphicsContext.restoreGraphicsState()
let directory = URL(fileURLWithPath: "Signloop/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("AppIcon.png"))
