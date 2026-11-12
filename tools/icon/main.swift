import AppKit
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let plate = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(deviceRed: 0.13, green: 0.17, blue: 0.20, alpha: 1),
           ending: NSColor(deviceRed: 0.05, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: plate, angle: -90)
drawGauge(in: CGRect(x: 512 - 300, y: 512 - 250, width: 600, height: 600), fraction: 0.62,
          color: NSColor(deviceRed: 0.93, green: 0.95, blue: 0.96, alpha: 1),
          accent: NSColor(deviceRed: 0.36, green: 0.84, blue: 0.70, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
