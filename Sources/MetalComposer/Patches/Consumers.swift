import Foundation
import Metal
import simd

final class ClearPatch: Patch {
    override class var typeID: String { "clear" }
    override class var title: String { "Clear" }
    override class var category: PatchCategory { .consumer }
    override class var summary: String { "Fills the whole viewer with a color." }
    override class var inputSpecs: [PortSpec] { [.color("color", "Color", SIMD4(0, 0, 0, 1))] }

    override func render(_ i: Inputs, _ ctx: RenderContext) {
        var color = i.color("color")
        let enc = ctx.encoder
        enc.setRenderPipelineState(ctx.resources.clearPipeline)
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

struct SpriteUniforms {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var rotation: Float
    var aspect: Float
    var color: SIMD4<Float>
    var hasTexture: Int32
}

final class SpritePatch: Patch {
    override class var typeID: String { "sprite" }
    override class var title: String { "Sprite" }
    override class var category: PatchCategory { .consumer }
    override class var summary: String { "Draws a textured or solid quad. Height 0 keeps the image aspect ratio." }
    override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true),
         .number("x", "X Position", 0, -1...1), .number("y", "Y Position", 0, -1...1),
         .number("width", "Width", 1, 0...2), .number("height", "Height", 1, 0...2),
         .number("rotation", "Rotation (°)", 0, -180...180),
         .color("color", "Color"), .image("image", "Image"),
         .menu("blending", "Blending", ["Over", "Add"])]
    }

    override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let res = ctx.resources
        let tex = i.image("image")
        let w = i.float("width")
        var h = i.float("height")
        if h <= 0 { h = tex.map { w * Float($0.height) / Float(max($0.width, 1)) } ?? w }
        var u = SpriteUniforms(center: SIMD2(i.float("x"), i.float("y")), size: SIMD2(w, h),
                               rotation: i.float("rotation") * .pi / 180, aspect: ctx.aspect,
                               color: i.color("color"), hasTexture: tex == nil ? 0 : 1)
        let enc = ctx.encoder
        enc.setRenderPipelineState(i.int("blending") == 1 ? res.spriteAdd : res.spriteOver)
        enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex ?? res.whiteTexture, index: 0)
        enc.setFragmentSamplerState(res.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

struct ParticleInstance {
    var position: SIMD2<Float>
    var size: Float
    var alpha: Float
}

struct ParticleUniforms {
    var aspect: Float
    var color: SIMD4<Float>
    var hasTexture: Int32
}

final class ParticleSystemPatch: Patch {
    override class var typeID: String { "particle-system" }
    override class var title: String { "Particle System" }
    override class var category: PatchCategory { .consumer }
    override class var summary: String { "Emits, simulates and draws particles (GPU instanced)." }
    override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true),
         .number("x", "X Position", 0, -1...1), .number("y", "Y Position", 0, -1...1),
         .number("count", "Count", 600, 1...5000), .number("lifetime", "Lifetime", 2, 0.05...10),
         .number("speed", "Speed", 0.6, 0...3), .number("direction", "Direction (°)", 90, -180...180),
         .number("spread", "Spread (°)", 360, 0...360), .number("gravity", "Gravity", -0.4, -3...3),
         .number("size", "Size", 0.05, 0.001...0.5),
         .color("color", "Color", SIMD4(1, 0.6, 0.2, 1)), .image("image", "Image"),
         .menu("blending", "Blending", ["Over", "Add"], 1)]
    }

    private struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var age: Float
        var life: Float
    }

    private var particles: [Particle] = []
    private var spawnBudget: Float = 0

    override func reset() {
        particles.removeAll()
        spawnBudget = 0
    }

    override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let dt = Float(min(ctx.eval.deltaTime, 0.1))
        let count = max(1, i.int("count"))
        let life = max(0.05, i.float("lifetime"))
        let origin = SIMD2(i.float("x"), i.float("y"))
        let speed = i.float("speed"), gravity = i.float("gravity")
        let direction = i.float("direction") * .pi / 180, spread = i.float("spread") * .pi / 180

        spawnBudget += Float(count) / life * dt
        while spawnBudget >= 1, particles.count < count {
            spawnBudget -= 1
            let angle = direction + (Float.random(in: -0.5...0.5)) * spread
            let v = SIMD2(cos(angle), sin(angle)) * speed * Float.random(in: 0.4...1)
            particles.append(Particle(position: origin, velocity: v, age: 0, life: life * Float.random(in: 0.6...1)))
        }
        if particles.count >= count { spawnBudget = 0 }

        var instances: [ParticleInstance] = []
        instances.reserveCapacity(particles.count)
        let baseSize = i.float("size")
        particles = particles.compactMap { p in
            var p = p
            p.age += dt
            guard p.age < p.life else { return nil }
            p.velocity.y += gravity * dt
            p.position += p.velocity * dt
            let k = p.age / p.life
            instances.append(ParticleInstance(position: p.position, size: baseSize * (1 - 0.6 * k), alpha: 1 - k))
            return p
        }
        guard !instances.isEmpty,
              let buffer = ctx.resources.device.makeBuffer(bytes: instances,
                                                           length: MemoryLayout<ParticleInstance>.stride * instances.count)
        else { return }

        let tex = i.image("image")
        var u = ParticleUniforms(aspect: ctx.aspect, color: i.color("color"), hasTexture: tex == nil ? 0 : 1)
        let res = ctx.resources
        let enc = ctx.encoder
        enc.setRenderPipelineState(i.int("blending") == 1 ? res.particleAdd : res.particleOver)
        enc.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.setVertexBuffer(buffer, offset: 0, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex ?? res.whiteTexture, index: 0)
        enc.setFragmentSamplerState(res.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}

struct ShaderUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var mouse: SIMD2<Float>
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

final class MetalShaderPatch: Patch {
    override class var typeID: String { "metal-shader" }
    override class var title: String { "Metal Shader" }
    override class var category: PatchCategory { .consumer }
    override class var summary: String { "Full-screen fragment shader written in Metal Shading Language, compiled live." }
    override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true), .color("color", "Color"),
         .number("p1", "Param 1", 0, 0...1), .number("p2", "Param 2", 0, 0...1),
         .number("p3", "Param 3", 0, 0...1), .number("p4", "Param 4", 0, 0...1),
         .image("image", "Image"),
         .string("source", "Source", ShaderLibrary.defaultUserShader, isPort: false, multiline: true)]
    }

    override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let res = ctx.resources
        let pipeline: MTLRenderPipelineState
        switch res.userShaderPipeline(source: i.string("source")) {
        case .success(let p): pipeline = p; setStatus(nil)
        case .failure(let e): setStatus(e.message); return
        }
        let size = ctx.targetSize
        let m = ctx.eval.mouse
        var u = ShaderUniforms(
            time: Float(ctx.eval.time),
            resolution: SIMD2(Float(size.width), Float(size.height)),
            mouse: SIMD2((m.x + 1) / 2, (m.y * ctx.eval.aspect + 1) / 2),
            color: i.color("color"),
            params: SIMD4(i.float("p1"), i.float("p2"), i.float("p3"), i.float("p4")))
        let enc = ctx.encoder
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        enc.setFragmentTexture(i.image("image") ?? res.whiteTexture, index: 0)
        enc.setFragmentSamplerState(res.sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
