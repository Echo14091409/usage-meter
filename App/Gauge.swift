import AppKit

/// Half-circle gauge with a needle, drawn on an 18×18 grid. `fraction` 0…1 sets the needle; nil = no data.
func drawGauge(in rect: CGRect, fraction: Double?, color: NSColor, accent: NSColor) {
    let u = rect.width / 18
    let c = CGPoint(x: rect.midX, y: rect.minY + 5.5 * u)
    color.set()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: 7.2 * u, startAngle: 180, endAngle: 0, clockwise: true)
    arc.lineWidth = 1.5 * u
    arc.lineCapStyle = .round
    arc.stroke()
    for a in stride(from: 180.0, through: 0, by: -45) {              // ticks
        let r = a * .pi / 180
        let t = NSBezierPath()
        t.move(to: CGPoint(x: c.x + cos(r) * 4.6 * u, y: c.y + sin(r) * 4.6 * u))
        t.line(to: CGPoint(x: c.x + cos(r) * 5.6 * u, y: c.y + sin(r) * 5.6 * u))
        t.lineWidth = 1.1 * u
        t.lineCapStyle = .round
        t.stroke()
    }
    let base = NSBezierPath(roundedRect: CGRect(x: rect.minX + 3 * u, y: rect.minY + 1.2 * u, width: 12 * u, height: 1.6 * u),
                            xRadius: 0.8 * u, yRadius: 0.8 * u)
    base.fill()
    accent.set()
    let f = min(max(fraction ?? 0.5, 0), 1)
    let r = (180 - 180 * f) * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: c)
    needle.line(to: CGPoint(x: c.x + cos(r) * 5.4 * u, y: c.y + sin(r) * 5.4 * u))
    needle.lineWidth = 1.6 * u
    needle.lineCapStyle = .round
    if fraction == nil { needle.setLineDash([0.6 * u, 1.6 * u], count: 2, phase: 0) }
    needle.stroke()
    NSBezierPath(ovalIn: CGRect(x: c.x - 1.4 * u, y: c.y - 1.4 * u, width: 2.8 * u, height: 2.8 * u)).fill()
}

func gaugeIcon(fraction: Double?, size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        drawGauge(in: rect, fraction: fraction, color: .black, accent: .black)
        return true
    }
    img.isTemplate = true
    return img
}
