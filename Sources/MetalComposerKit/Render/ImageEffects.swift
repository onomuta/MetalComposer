import Metal

/// GPU passes behind the image effect patches (Tile, Outline). Results are straight-alpha RGBA
/// textures the size of the source image.
package final class ImageEffects {
    private let device: MTLDevice
    private let tile: MTLRenderPipelineState
    private let seed: MTLRenderPipelineState
    private let step: MTLRenderPipelineState
    private let outline: MTLRenderPipelineState

    package static let outputFormat: MTLPixelFormat = .rgba8Unorm

    package init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fx_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        tile = try pipeline("tile_fragment", Self.outputFormat)
        seed = try pipeline("jfa_seed_fragment", .rg32Float)
        step = try pipeline("jfa_step_fragment", .rg32Float)
        outline = try pipeline("outline_fragment", Self.outputFormat)
    }

    /// A texture for an effect's output (or its scratch), reused while the size and format stay.
    package func texture(_ existing: MTLTexture?, width: Int, height: Int, format: MTLPixelFormat = outputFormat) -> MTLTexture? {
        if let existing, existing.width == width, existing.height == height, existing.pixelFormat == format { return existing }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func pass(_ target: MTLTexture, _ commandBuffer: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState,
                      _ setUp: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        setUp(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Repeats `source` `tiles` times across `target`, shifted by `offset` tiles; with `mirror`,
    /// every other tile is flipped.
    package func tile(_ source: MTLTexture, into target: MTLTexture, tiles: SIMD2<Float>, offset: SIMD2<Float>,
                      mirror: Bool, commandBuffer: MTLCommandBuffer) {
        struct Params { var tiles: SIMD2<Float>; var offset: SIMD2<Float>; var mirror: Int32 }
        var p = Params(tiles: tiles, offset: offset, mirror: mirror ? 1 : 0)
        pass(target, commandBuffer, tile) { enc in
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }
    }

    /// Draws `source` over an outline `width` pixels wide around its shape (or the outline alone).
    /// The target and the two rg32Float `seeds` textures are the source's size plus `margin` pixels
    /// on every side (the source is drawn centered).
    package func outline(_ source: MTLTexture, into target: MTLTexture, seeds: (MTLTexture, MTLTexture), margin: Int,
                         color: SIMD4<Float>, width: Float, outlineOnly: Bool, commandBuffer: MTLCommandBuffer) {
        var margin32 = Int32(margin)
        pass(seeds.0, commandBuffer, seed) { enc in
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentBytes(&margin32, length: MemoryLayout<Int32>.stride, index: 0)
        }
        // Jump flood from the largest step the outline needs down to 1 (distances further than the
        // width don't matter), then one more 1-step pass to clean up.
        var read = seeds.0, write = seeds.1
        var k = 1
        while k * 2 <= Int(width.rounded(.up)) + 1 { k *= 2 }
        var steps: [Int] = []
        while k >= 1 { steps.append(k); k /= 2 }
        steps.append(1)
        for s in steps {
            var stepSize = Int32(s)
            pass(write, commandBuffer, step) { enc in
                enc.setFragmentTexture(read, index: 0)
                enc.setFragmentBytes(&stepSize, length: MemoryLayout<Int32>.stride, index: 0)
            }
            swap(&read, &write)
        }
        struct Params { var color: SIMD4<Float>; var width: Float; var outlineOnly: Int32; var margin: Int32 }
        var p = Params(color: color, width: width, outlineOnly: outlineOnly ? 1 : 0, margin: margin32)
        pass(target, commandBuffer, outline) { enc in
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentTexture(read, index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }
    }
}
