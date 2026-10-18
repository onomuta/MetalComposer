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
