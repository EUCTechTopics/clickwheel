// Renders the Clickwheel app icon (a click wheel on a graphite squircle) to a 1024 px PNG.
// Usage: swift make_icon.swift OUT.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
// drop shadow + graphite body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: squircle, angle: -90)
ctx.restoreGState()
// faint scanlines
NSColor.white.withAlphaComponent(0.025).setFill()
var y = rect.minY
while y < rect.maxY { NSBezierPath(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: 3)).fill(); y += 9 }
// wheel
let c = CGPoint(x: size / 2, y: size / 2 - 10)
let R: CGFloat = 300
let wheel = NSBezierPath(ovalIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.80, alpha: 1)])!.draw(in: wheel, angle: -90)
// phosphor arc around the wheel
let green = NSColor(calibratedRed: 0.30, green: 0.92, blue: 0.55, alpha: 1)
let arc = NSBezierPath()
arc.appendArc(withCenter: c, radius: R + 34, startAngle: 120, endAngle: 420)
arc.lineWidth = 22
arc.lineCapStyle = .round
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28, color: green.cgColor)
green.setStroke(); arc.stroke()
ctx.restoreGState()
// centre button
let r: CGFloat = 112
let btn = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
NSGradient(colors: [NSColor(white: 0.86, alpha: 1), NSColor(white: 0.99, alpha: 1)])!.draw(in: btn, angle: -90)
// labels: MENU and a hex byte at the bottom
let font = NSFont.monospacedSystemFont(ofSize: 54, weight: .bold)
func draw(_ s: String, at p: CGPoint, color: NSColor) {
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let sz = (s as NSString).size(withAttributes: a)
    (s as NSString).draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: a)
}
draw("MENU", at: CGPoint(x: c.x, y: c.y + 205), color: NSColor(white: 0.55, alpha: 1))
draw("0xD1", at: CGPoint(x: c.x, y: c.y - 205), color: NSColor(white: 0.55, alpha: 1))
draw("◀◀", at: CGPoint(x: c.x - 205, y: c.y), color: NSColor(white: 0.6, alpha: 1))
draw("▶▶", at: CGPoint(x: c.x + 205, y: c.y), color: NSColor(white: 0.6, alpha: 1))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
