import CoreGraphics
import CoreText
import Foundation
import Metal

/// Everything ONOM FLOW (the VJ app that plays compositions as generator materials) passes in, in one patch:
/// BPM, Beat, Beat 2, Beat 4, Gain, Input 1–4, Text 1–2, Image 1–2, Main Color and Sub Color.
///
/// Beat is where the music is within the current beat (0 on the beat, rising to 1); Beat 2 and Beat 4
/// are the same over two and four beats, for movements that span a half or a whole bar. ONOM FLOW counts
/// them from the same beat origin, so they line up with its tap.
///
/// While a composition contains this patch (anywhere, also inside macros), `CompositionPlayer.parameters`
/// lists these values under the names ONOM FLOW sends, so the host sets them like Macro Inputs; inside the
/// graph they arrive through `EvalContext.host`, which reaches every macro unchanged. Played elsewhere, the
/// outputs keep their defaults, and Beat follows the BPM on the composition's clock so the preview moves.
package final class OnomFlowInputPatch: Patch {
    package override class var typeID: String { "onom-flow-input" }
    package override class var title: String { "ONOM FLOW Input" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String {
        "Values ONOM FLOW passes in: BPM, beat (also over 2 and 4 beats), gain, Input 1–4, texts, images and its main and sub colors."
    }

    /// One value the host sets: its host key, the name the host matches, and the output it drives.
    package struct HostValue {
        package let key: String
        package let name: String
        package let port: String
        package let type: PortType
        package let defaultValue: Value
    }

    package static let defaultBPM = 120.0

    package static let hostValues: [HostValue] = {
        var values: [HostValue] = [
            HostValue(key: "onom-flow.bpm", name: "BPM", port: "bpm", type: .number, defaultValue: .number(defaultBPM)),
            HostValue(key: "onom-flow.beat", name: "Beat", port: "beat", type: .number, defaultValue: .number(0)),
            HostValue(key: "onom-flow.beat2", name: "Beat 2", port: "beat2", type: .number, defaultValue: .number(0)),
            HostValue(key: "onom-flow.beat4", name: "Beat 4", port: "beat4", type: .number, defaultValue: .number(0)),
            HostValue(key: "onom-flow.gain", name: "Gain", port: "gain", type: .number, defaultValue: .number(0)),
        ]
        for i in 1...4 {
            values.append(HostValue(key: "onom-flow.input\(i)", name: "Input \(i)", port: "input\(i)", type: .number, defaultValue: .number(0)))
        }
        for i in 1...2 {
            // A visible default: an empty string draws nothing useful in Text Image.
            values.append(HostValue(key: "onom-flow.text\(i)", name: "Text \(i)", port: "text\(i)", type: .string, defaultValue: .string("Text \(i)")))
        }
        for i in 1...2 {
            values.append(HostValue(key: "onom-flow.image\(i)", name: "Image \(i)", port: "image\(i)", type: .image, defaultValue: .image(nil)))
        }
        values.append(HostValue(key: "onom-flow.main-color", name: "Main Color", port: "mainColor", type: .color, defaultValue: .color(.one)))
        values.append(HostValue(key: "onom-flow.sub-color", name: "Sub Color", port: "subColor", type: .color, defaultValue: .color(.one)))
        return values
    }()

    package override class var outputSpecs: [PortSpec] {
        hostValues.map { PortSpec(key: $0.port, name: $0.name, type: $0.type, defaultValue: $0.defaultValue) }
    }

    package override func evaluate(_ inputs: Inputs, _ ctx: EvalContext) -> [String: Value] {
        var out: [String: Value] = [:]
        for value in Self.hostValues {
            out[value.port] = ctx.host[value.key]?.coerced(to: value.type) ?? value.defaultValue
        }
        // In the editor, an image ONOM FLOW would pass shows where it will go.
        if ctx.showsPlaceholders {
            for (index, port) in ["image1", "image2"].enumerated() where out[port]?.image == nil {
                out[port] = .image(Self.placeholder(index, device: ctx.device))
            }
        }
        // Without a host, the beats run at the BPM on the composition's clock (0 at each beat, or each
        // 2 or 4 beats, rising to 1).
        let bpm = out["bpm"]?.number ?? Self.defaultBPM
        let beats = ctx.time * max(bpm, 0) / 60
        for (port, length) in [("beat", 1.0), ("beat2", 2.0), ("beat4", 4.0)] where ctx.host["onom-flow.\(port)"] == nil {
            out[port] = .number(Self.phase(beats, over: length))
        }
        return out
    }

    private static var placeholders: [Int: MTLTexture] = [:]

    /// A 16:9 stand-in for Image 1 / Image 2 in the editor: a frame, a big cross and the name, over a
    /// faint gray, so it's clear where ONOM FLOW's image will appear.
    package static func placeholder(_ index: Int, device: MTLDevice) -> MTLTexture? {
        if let texture = placeholders[index] { return texture }
        let w = 1280, h = 720
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        cg.setFillColor(CGColor(gray: 0.5, alpha: 0.25))
        cg.fill(rect)
        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        cg.setLineWidth(12)
        cg.stroke(rect.insetBy(dx: 6, dy: 6))
        cg.setLineWidth(6)
        cg.move(to: CGPoint(x: 0, y: 0)); cg.addLine(to: CGPoint(x: w, y: h))
        cg.move(to: CGPoint(x: 0, y: h)); cg.addLine(to: CGPoint(x: w, y: 0))
        cg.strokePath()
        // The name on a dark label in the middle.
        let label = "Image \(index + 1)"
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 96, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
        let bounds = CTLineGetImageBounds(line, cg)
        let box = CGRect(x: (CGFloat(w) - bounds.width) / 2 - 40, y: (CGFloat(h) - 150) / 2,
                         width: bounds.width + 80, height: 150)
        cg.setFillColor(CGColor(gray: 0, alpha: 0.75))
        cg.addPath(CGPath(roundedRect: box, cornerWidth: 20, cornerHeight: 20, transform: nil))
        cg.fillPath()
        cg.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2 - bounds.minX, y: (CGFloat(h) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, cg)

        guard let data = cg.data else { return nil }
        // Straight alpha, like the other images.
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for p in 0..<(w * h) {
            let a = Int(px[p * 4 + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { px[p * 4 + c] = UInt8(min(255, Int(px[p * 4 + c]) * 255 / a)) }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        placeholders[index] = texture
        return texture
    }

    /// Where `beats` falls within a span of `length` beats, 0…1.
    package static func phase(_ beats: Double, over length: Double) -> Double {
        let span = beats / length
        return span.isFinite ? span - span.rounded(.down) : 0
    }

    /// Whether a graph uses the patch anywhere, also inside macros.
    package static func isUsed(in graph: Graph) -> Bool {
        graph.nodes.contains { $0 is OnomFlowInputPatch || ($0.subgraph.map(isUsed) ?? false) }
    }
}
