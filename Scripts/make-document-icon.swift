// Renders the icon for Mirage Composer composition files (.mcomp), 1024×1024 PNG with CoreGraphics:
// a page with a folded corner, in the app icon's colors, with a small patch graph and "MCOMP".
// Usage: swift Scripts/make-document-icon.swift Assets/DocumentIcon-1024.png
// (Scripts/make-icon.sh runs it and makes the .icns and the iOS PNGs.)
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "DocumentIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-left origin like a design tool.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func linear(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

// The page, on the macOS document icon grid, with its top-right corner folded down.
let page = CGRect(x: 160, y: 72, width: 704, height: 880)
let fold: CGFloat = 200
let radius: CGFloat = 52
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: page.minX + radius, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
pagePath.addArc(tangent1End: CGPoint(x: page.maxX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.maxY), radius: radius)
pagePath.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.minY), radius: radius)
pagePath.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.minY), radius: radius)
pagePath.closeSubpath()

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.4))
ctx.addPath(pagePath)
ctx.setFillColor(rgb(0x14163A))
ctx.fillPath()
ctx.restoreGState()

// Background: the app icon's indigo gradient, glows and editor grid.
ctx.saveGState()
ctx.addPath(pagePath)
ctx.clip()
ctx.drawLinearGradient(linear([rgb(0x2C3180), rgb(0x0C0C24)]), start: CGPoint(x: 512, y: page.minY),
                       end: CGPoint(x: 512, y: page.maxY), options: [])
ctx.drawRadialGradient(linear([rgb(0xB040FF, 0.55), rgb(0xB040FF, 0)]), startCenter: CGPoint(x: 640, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 640, y: 520), endRadius: 340, options: [])
ctx.drawRadialGradient(linear([rgb(0x30D5FF, 0.28), rgb(0x30D5FF, 0)]), startCenter: CGPoint(x: 300, y: 330), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 330), endRadius: 280, options: [])
ctx.setStrokeColor(rgb(0xFFFFFF, 0.05))
ctx.setLineWidth(2)
for v in stride(from: page.minX, through: page.maxX, by: 44) {
    ctx.move(to: CGPoint(x: v, y: page.minY)); ctx.addLine(to: CGPoint(x: v, y: page.maxY))
}
for v in stride(from: page.minY, through: page.maxY, by: 44) {
    ctx.move(to: CGPoint(x: page.minX, y: v)); ctx.addLine(to: CGPoint(x: page.maxX, y: v))
}
ctx.strokePath()
ctx.restoreGState()

// Nodes: two sources feeding one output, as in the app icon but smaller.
struct Node { var rect: CGRect; var header: UInt32 }
let a = Node(rect: CGRect(x: 232, y: 300, width: 196, height: 132), header: 0x7A5CE0)
let b = Node(rect: CGRect(x: 232, y: 540, width: 196, height: 132), header: 0x2FA36F)
let c = Node(rect: CGRect(x: 556, y: 404, width: 220, height: 176), header: 0xE0554F)
let header: CGFloat = 54

func outPort(_ n: Node) -> CGPoint { CGPoint(x: n.rect.maxX, y: n.rect.minY + header + (n.rect.height - header) / 2) }
func inPort(_ n: Node, _ i: Int, of count: Int) -> CGPoint {
    let h = (n.rect.height - header) / CGFloat(count + 1)
    return CGPoint(x: n.rect.minX, y: n.rect.minY + header + h * CGFloat(i + 1))
}

func wire(_ p: CGPoint, _ q: CGPoint, _ from: UInt32, _ to: UInt32) {
    let path = CGMutablePath()
    path.move(to: p)
    let dx = max(70, (q.x - p.x) * 0.55)
    path.addCurve(to: q, control1: CGPoint(x: p.x + dx, y: p.y), control2: CGPoint(x: q.x - dx, y: q.y))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: rgb(to, 0.9))
    ctx.addPath(path)
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(to, 0.85))
    ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    ctx.drawLinearGradient(linear([rgb(from), rgb(to)]), start: p, end: q, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
wire(outPort(a), inPort(c, 0, of: 2), 0x8FB4FF, 0x5BE3FF)
wire(outPort(b), inPort(c, 1, of: 2), 0x7CF0B0, 0xFF6FB5)

func drawNode(_ n: Node, inputs: Int, outputs: Int) {
    let r = n.rect
    let shape = CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: rgb(0x000000, 0.55))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x262838))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(linear([rgb(0x3D4160), rgb(0x2A2D42)]), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
    ctx.clip(to: CGRect(x: r.minX, y: r.minY, width: r.width, height: header))
    ctx.drawLinearGradient(linear([rgb(n.header), rgb(n.header, 0.78)]), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.minY + header), options: [])
    ctx.restoreGState()

    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 22, y: r.minY + 20, width: r.width * 0.42, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.fillPath()

    func port(_ p: CGPoint, _ color: UInt32) {
        let pr: CGFloat = 16
        ctx.setFillColor(rgb(color))
        ctx.fillEllipse(in: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2))
        ctx.setStrokeColor(rgb(0x14152A))
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2))
    }
    for i in 0..<inputs { port(inPort(n, i, of: inputs), i == 0 ? 0x5BE3FF : 0xFF6FB5) }
    if outputs > 0 { port(outPort(n), n.header == a.header ? 0x8FB4FF : 0x7CF0B0) }
}
drawNode(a, inputs: 0, outputs: 1)
drawNode(b, inputs: 0, outputs: 1)
drawNode(c, inputs: 2, outputs: 0)

// The file extension near the bottom.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
let label = NSAttributedString(string: "MCOMP", attributes: [
    .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    .kern: 6,
])
let labelSize = label.size()
label.draw(at: CGPoint(x: page.midX - labelSize.width / 2, y: 768))
NSGraphicsContext.current = nil

// Gloss on the upper half, then the folded-over corner on top.
ctx.saveGState()
ctx.addPath(pagePath)
ctx.clip()
ctx.drawLinearGradient(linear([rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)]), start: CGPoint(x: 512, y: page.minY),
                       end: CGPoint(x: 512, y: 440), options: [])
ctx.restoreGState()

let flap = CGMutablePath()
flap.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
flap.addArc(tangent1End: CGPoint(x: page.maxX - fold, y: page.minY + fold), tangent2End: CGPoint(x: page.maxX, y: page.minY + fold), radius: 36)
flap.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
flap.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -6, height: 10), blur: 18, color: rgb(0x000000, 0.45))
ctx.addPath(flap)
ctx.setFillColor(rgb(0x6A6FD0))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(flap)
ctx.clip()
ctx.drawLinearGradient(linear([rgb(0x9A9EF0), rgb(0x5A5FC0)]), start: CGPoint(x: page.maxX - fold, y: page.minY + fold),
                       end: CGPoint(x: page.maxX - fold / 2, y: page.minY + fold / 2), options: [])
ctx.restoreGState()

// Thin rim light around the page.
ctx.addPath(pagePath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
