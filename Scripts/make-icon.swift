// Renders the Mirage Composer app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift Scripts/make-icon.swift Assets/AppIcon-1024.png [--ios]
// --ios draws the same artwork across the whole opaque square, without the macOS margin, shadow,
// rounded corners or rim: iOS masks the corners itself and rejects icons with transparency.
import AppKit
import CoreGraphics

let size = 1024
let arguments = CommandLine.arguments.dropFirst()
let ios = arguments.contains("--ios")
let out = arguments.first { !$0.hasPrefix("--") } ?? "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: (ios ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
// Work top-left origin like a design tool.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
if ios {
    // The macOS body (100…924) fills the canvas.
    ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
    ctx.translateBy(x: -100, y: -100)
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func linear(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// macOS icon grid: 824pt body inside the 1024 canvas, continuous-looking corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = ios ? CGPath(rect: body, transform: nil)
                   : CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow.
if !ios {
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x14163A))
ctx.fillPath()
ctx.restoreGState()
}

// Background: deep indigo gradient plus a soft magenta/cyan glow behind the output node.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(linear([rgb(0x2C3180), rgb(0x0C0C24)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.drawRadialGradient(linear([rgb(0xB040FF, 0.55), rgb(0xB040FF, 0)]), startCenter: CGPoint(x: 690, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 690, y: 520), endRadius: 360, options: [])
ctx.drawRadialGradient(linear([rgb(0x30D5FF, 0.28), rgb(0x30D5FF, 0)]), startCenter: CGPoint(x: 300, y: 330), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 330), endRadius: 300, options: [])
// Faint editor grid.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.05))
ctx.setLineWidth(2)
for v in stride(from: 100, through: 924, by: 48) {
    ctx.move(to: CGPoint(x: CGFloat(v), y: 100)); ctx.addLine(to: CGPoint(x: CGFloat(v), y: 924))
    ctx.move(to: CGPoint(x: 100, y: CGFloat(v))); ctx.addLine(to: CGPoint(x: 924, y: CGFloat(v)))
}
ctx.strokePath()
ctx.restoreGState()

// Nodes: two sources on the left feeding one output on the right.
struct Node { var rect: CGRect; var header: UInt32 }
let a = Node(rect: CGRect(x: 178, y: 250, width: 250, height: 168), header: 0x7A5CE0)   // provider
let b = Node(rect: CGRect(x: 178, y: 600, width: 250, height: 168), header: 0x2FA36F)   // processor
let c = Node(rect: CGRect(x: 588, y: 400, width: 262, height: 224), header: 0xE0554F)   // consumer
let header: CGFloat = 70

func outPort(_ n: Node) -> CGPoint { CGPoint(x: n.rect.maxX, y: n.rect.minY + header + (n.rect.height - header) / 2) }
func inPort(_ n: Node, _ i: Int, of count: Int) -> CGPoint {
    let h = (n.rect.height - header) / CGFloat(count + 1)
    return CGPoint(x: n.rect.minX, y: n.rect.minY + header + h * CGFloat(i + 1))
}

// Glowing wires, drawn under the nodes.
func wire(_ p: CGPoint, _ q: CGPoint, _ from: UInt32, _ to: UInt32) {
    let path = CGMutablePath()
    path.move(to: p)
    let dx = max(90, (q.x - p.x) * 0.55)
    path.addCurve(to: q, control1: CGPoint(x: p.x + dx, y: p.y), control2: CGPoint(x: q.x - dx, y: q.y))
    // Glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: rgb(to, 0.9))
    ctx.addPath(path)
    ctx.setLineWidth(28)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(to, 0.85))
    ctx.strokePath()
    ctx.restoreGState()
    // Gradient core.
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: 24, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    ctx.drawLinearGradient(linear([rgb(from), rgb(to)]), start: p, end: q, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
wire(outPort(a), inPort(c, 0, of: 2), 0x8FB4FF, 0x5BE3FF)
wire(outPort(b), inPort(c, 1, of: 2), 0x7CF0B0, 0xFF6FB5)

func drawNode(_ n: Node, inputs: Int, outputs: Int) {
    let r = n.rect
    let shape = CGPath(roundedRect: r, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.55))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x262838))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(linear([rgb(0x3D4160), rgb(0x2A2D42)]), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
    let headerRect = CGRect(x: r.minX, y: r.minY, width: r.width, height: header)
    ctx.clip(to: headerRect)
    ctx.drawLinearGradient(linear([rgb(n.header), rgb(n.header, 0.78)]), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.minY + header), options: [])
    ctx.restoreGState()

    // Title bar line and "text" rows suggesting port labels.
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 28, y: r.minY + 26, width: r.width * 0.42, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.fillPath()

    func port(_ p: CGPoint, _ color: UInt32) {
        let pr: CGFloat = 19
        ctx.setFillColor(rgb(color))
        ctx.fillEllipse(in: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2))
        ctx.setStrokeColor(rgb(0x14152A))
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2))
    }
    for i in 0..<inputs {
        let p = inPort(n, i, of: inputs)
        ctx.setFillColor(rgb(0xFFFFFF, 0.28))
        ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 30, y: p.y - 6, width: r.width * 0.36, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        port(p, i == 0 ? 0x5BE3FF : 0xFF6FB5)
    }
    if outputs > 0 {
        let p = outPort(n)
        ctx.setFillColor(rgb(0xFFFFFF, 0.28))
        ctx.addPath(CGPath(roundedRect: CGRect(x: r.maxX - 30 - r.width * 0.32, y: p.y - 6, width: r.width * 0.32, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        port(p, n.header == a.header ? 0x8FB4FF : 0x7CF0B0)
    }
}
drawNode(a, inputs: 0, outputs: 1)
drawNode(b, inputs: 0, outputs: 1)
drawNode(c, inputs: 2, outputs: 0)

// Gloss on the upper half and a thin rim light.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(linear([rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()
if !ios {
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
