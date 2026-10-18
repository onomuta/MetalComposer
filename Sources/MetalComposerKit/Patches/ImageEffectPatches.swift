import Metal

/// Output textures of an image effect, one per Iterator pass (the effect runs once per pass, and
/// each pass's image must survive until it is drawn).
private struct EffectOutputs {
    var images: [Int: MTLTexture] = [:]
    var scratch: [Int: (MTLTexture, MTLTexture)] = [:]

    static func key(_ ctx: EvalContext) -> Int { ctx.iteration?.index ?? -1 }
}

/// Repeats an image in a grid (tiles), optionally mirrored so the tiles join without seams.
package final class TilePatch: Patch {
    package override class var typeID: String { "tile" }
    package override class var title: String { "Tile" }
    package override class var summary: String {
        "Repeats an image in a grid. Offset scrolls the tiles (animate it to move them); Mirror flips every other tile so they join seamlessly."
    }
    package override class var inputSpecs: [PortSpec] {
        [.image("image", "Image"),
         .number("columns", "Columns", 3, 1...16).limited(min: 0.01),
         .number("rows", "Rows", 3, 1...16).limited(min: 0.01),
         .number("offsetX", "Offset X", 0, -1...1), .number("offsetY", "Offset Y", 0, -1...1),
         .bool("mirror", "Mirror", false)]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var outputs = EffectOutputs()

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let src = i.image("image"), let fx = ctx.resources.imageEffects else { return ["image": .image(i.image("image"))] }
        let key = EffectOutputs.key(ctx)
        guard let out = fx.texture(outputs.images[key], width: src.width, height: src.height) else { return ["image": .image(src)] }
        outputs.images[key] = out
        fx.tile(src, into: out,
                tiles: SIMD2(max(0.01, i.float("columns")), max(0.01, i.float("rows"))),
                offset: SIMD2(i.float("offsetX"), i.float("offsetY")),
                mirror: i.bool("mirror"), commandBuffer: ctx.commandBuffer)
        return ["image": .image(out)]
    }

    package override func reset() { outputs = EffectOutputs() }
}

/// Draws an outline of any color and width around the shape of an image (its opaque pixels).
package final class OutlinePatch: Patch {
    package override class var typeID: String { "outline" }
    package override class var title: String { "Outline" }
    package override class var summary: String {
        "Adds an outline of any color and width (in pixels) around the opaque shape of an image, such as text or a logo. The image grows by the width on every side so the outline isn't cut off. Outline Only leaves out the image itself."
    }
    package override class var inputSpecs: [PortSpec] {
        [.image("image", "Image"),
         .color("color", "Color", SIMD4(1, 1, 1, 1)),
         .number("width", "Width (px)", 4, 0...40).limited(0...256),
         .bool("outlineOnly", "Outline Only", false),
         // Off: the result keeps the image's size, and the outline is cut off at its edges.
         .bool("grow", "Grow Image", true).setting()]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var outputs = EffectOutputs()

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let src = i.image("image"), let fx = ctx.resources.imageEffects else { return ["image": .image(i.image("image"))] }
        let key = EffectOutputs.key(ctx)
        let width = min(max(i.float("width"), 0), 256)
        let margin = i.bool("grow") ? Int(width.rounded(.up)) + 1 : 0
        let w = min(src.width + margin * 2, 16384), h = min(src.height + margin * 2, 16384)
        guard let out = fx.texture(outputs.images[key], width: w, height: h),
              let a = fx.texture(outputs.scratch[key]?.0, width: w, height: h, format: .rg32Float),
              let b = fx.texture(outputs.scratch[key]?.1, width: w, height: h, format: .rg32Float)
        else { return ["image": .image(src)] }
        outputs.images[key] = out
        outputs.scratch[key] = (a, b)
        fx.outline(src, into: out, seeds: (a, b), margin: margin, color: i.color("color"),
                   width: width, outlineOnly: i.bool("outlineOnly"), commandBuffer: ctx.commandBuffer)
        return ["image": .image(out)]
    }

    package override func reset() { outputs = EffectOutputs() }
}

/// Cuts a rectangle out of an image (QC's Image Crop). The origin is the image's top-left corner.
package final class ImageCropPatch: Patch {
    package override class var typeID: String { "image-crop" }
    package override class var title: String { "Image Crop" }
    package override class var summary: String {
        "Cuts a rectangle out of an image, measured from its top-left corner, as fractions of the image (0–1) or in pixels."
    }
    package override class var inputSpecs: [PortSpec] {
        [.image("image", "Image"),
         .menu("units", "Units", ["Fraction (0–1)", "Pixels"]),
         .number("x", "X", 0, 0...1), .number("y", "Y", 0, 0...1),
         .number("width", "Width", 1, 0...1).limited(min: 0), .number("height", "Height", 1, 0...1).limited(min: 0)]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    /// In Pixels, the sliders span a full HD image instead of 0–1.
    package override var ownInputs: [PortSpec] {
        guard params["units"]?.number == 1 else { return type(of: self).inputSpecs }
        return type(of: self).inputSpecs.map { spec in
            var s = spec
            switch spec.key {
            case "x", "width": s.range = 0...1920
            case "y", "height": s.range = 0...1080
            default: break
            }
            return s
        }
    }

    private var outputs = EffectOutputs()

    /// The pixel rectangle to keep, inside the image (nil when nothing is left).
    package static func region(imageWidth: Int, imageHeight: Int, pixels: Bool,
                               x: Double, y: Double, width: Double, height: Double) -> (x: Int, y: Int, width: Int, height: Int)? {
        let sx = pixels ? 1 : Double(imageWidth), sy = pixels ? 1 : Double(imageHeight)
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        let x0 = max(0, min(Double(imageWidth), (x * sx).rounded())), y0 = max(0, min(Double(imageHeight), (y * sy).rounded()))
        let x1 = max(x0, min(Double(imageWidth), ((x + width) * sx).rounded()))
        let y1 = max(y0, min(Double(imageHeight), ((y + height) * sy).rounded()))
        guard x1 > x0, y1 > y0 else { return nil }
        return (Int(x0), Int(y0), Int(x1 - x0), Int(y1 - y0))
    }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let src = i.image("image") else { return ["image": .image(nil)] }
        guard let r = Self.region(imageWidth: src.width, imageHeight: src.height, pixels: i.int("units") == 1,
                                  x: i.number("x"), y: i.number("y"), width: i.number("width"), height: i.number("height"))
        else { return ["image": .image(nil)] }
        if r.x == 0, r.y == 0, r.width == src.width, r.height == src.height { return ["image": .image(src)] }
        let key = EffectOutputs.key(ctx)
        var out = outputs.images[key]
        if out == nil || out!.width != r.width || out!.height != r.height || out!.pixelFormat != src.pixelFormat {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: r.width, height: r.height, mipmapped: false)
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            out = ctx.device.makeTexture(descriptor: desc)
            outputs.images[key] = out
        }
        guard let out, let blit = ctx.commandBuffer.makeBlitCommandEncoder() else { return ["image": .image(src)] }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                  sourceSize: MTLSize(width: r.width, height: r.height, depth: 1),
                  to: out, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        return ["image": .image(out)]
    }

    package override func reset() { outputs = EffectOutputs() }
}
