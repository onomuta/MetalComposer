import Foundation
import Metal
import simd

package final class ClearPatch: Patch {
    package override class var typeID: String { "clear" }
    package override class var title: String { "Clear" }
    package override class var category: PatchCategory { .consumer }
    package override class var summary: String { "Fills the whole viewer with a color." }
    package override class var inputSpecs: [PortSpec] { [.color("color", "Color", SIMD4(0, 0, 0, 1))] }

    package override func render(_ i: Inputs, _ ctx: RenderContext) {
        var color = i.color("color")
        let enc = ctx.encoder
        enc.setRenderPipelineState(ctx.resources.clearPipeline)
        enc.setDepthStencilState(ctx.resources.depthReset)
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

package struct QuadUniforms {
    package var c0, c1, c2, c3: SIMD4<Float> // clip-space corners: bottom-left, bottom-right, top-left, top-right
    package var color: SIMD4<Float>
    package var hasTexture: Int32
}

/// Unit quad corners in the order the triangle strip expects.
package let quadCorners: [SIMD2<Float>] = [SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5)]

/// Draws a textured or solid quad from four clip-space corners.
package func drawQuad(_ ctx: RenderContext, corners: [SIMD4<Float>], color: SIMD4<Float>, texture: MTLTexture?,
              additive: Bool, depthTest: Bool) {
    let res = ctx.resources
    var u = QuadUniforms(c0: corners[0], c1: corners[1], c2: corners[2], c3: corners[3],
                         color: color, hasTexture: texture == nil ? 0 : 1)
    let enc = ctx.encoder
    enc.setRenderPipelineState(additive ? res.spriteAdd : res.spriteOver)
    enc.setDepthStencilState(depthTest ? res.depthReadWrite : res.depthOff)
    enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
    enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
    enc.setFragmentTexture(texture ?? res.whiteTexture, index: 0)
    enc.setFragmentSamplerState(res.sampler, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
}

/// Height 0 means "keep the image's aspect ratio" (square without an image).
private func resolvedSize(_ i: Inputs, _ tex: MTLTexture?) -> SIMD2<Float> {
    let w = i.float("width")
    var h = i.float("height")
    if h <= 0 { h = tex.map { w * Float($0.height) / Float(max($0.width, 1)) } ?? w }
    return SIMD2(w, h)
}

/// 2D quad that always faces the viewer. Inside a 3D Transformation only its position moves.
package final class BillboardPatch: Patch {
    package override class var typeID: String { "billboard" }
    package override class var title: String { "Billboard" }
    package override class var category: PatchCategory { .consumer }
    package override class var summary: String { "2D image or solid quad that always faces the viewer. Height 0 keeps the image aspect ratio." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true),
         .position("x", "X Position"), .position("y", "Y Position"),
         .number("width", "Width", 1, 0...2).limited(min: 0), .number("height", "Height (0 = auto)", 0, 0...2).limited(min: 0),
         .angle("rotation", "Rotation (°)"),
         .color("color", "Color"), .image("image", "Image"),
         .menu("blending", "Blending", ["Over", "Add"]),
         .menu("depth", "Depth Test", ["Off", "On"], 0).setting()]
    }

    package override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let tex = i.image("image")
        let size = resolvedSize(i, tex)
        let angle = i.float("rotation") * .pi / 180
        let (s, c) = (sin(angle), cos(angle))
        let center = ctx.modelView * SIMD4(i.float("x"), i.float("y"), 0, 1)
        let proj = ctx.projection
        let corners = quadCorners.map { k -> SIMD4<Float> in
            let p = k * size
            let r = SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
            return proj * SIMD4(center.x + r.x, center.y + r.y, center.z, 1)
        }
        drawQuad(ctx, corners: corners, color: i.color("color"), texture: tex,
                 additive: i.int("blending") == 1, depthTest: i.int("depth") == 1)
    }
}

/// Quad placed in 3D space with perspective.
package final class SpritePatch: Patch {
    package override class var typeID: String { "sprite" }
    package override class var title: String { "Sprite" }
    package override class var category: PatchCategory { .consumer }
    package override class var summary: String { "Image or solid quad in 3D space (position and rotation on X/Y/Z). Height 0 keeps the image aspect ratio." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true),
         .position("x", "X Position"), .position("y", "Y Position"), .position("z", "Z Position"),
         .angle("rotationX", "X Rotation (°)"), .angle("rotationY", "Y Rotation (°)"),
         // "rotation" keeps files saved before 3D support loading unchanged.
         .angle("rotation", "Z Rotation (°)"),
         .number("width", "Width", 1, 0...2).limited(min: 0), .number("height", "Height (0 = auto)", 1, 0...2).limited(min: 0),
         .color("color", "Color"), .image("image", "Image"),
         .menu("blending", "Blending", ["Over", "Add"]),
         .menu("depth", "Depth Test", ["Off", "On"], 1).setting()]
    }

    package override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let tex = i.image("image")
        let size = resolvedSize(i, tex)
        let local = simd_float4x4.translation(SIMD3(i.float("x"), i.float("y"), i.float("z")))
            * simd_float4x4.rotation(degrees: SIMD3(i.float("rotationX"), i.float("rotationY"), i.float("rotation")))
            * simd_float4x4.scale(SIMD3(size.x, size.y, 1))
        let mvp = ctx.projection * ctx.modelView * local
        let corners = quadCorners.map { mvp * SIMD4($0.x, $0.y, 0, 1) }
        drawQuad(ctx, corners: corners, color: i.color("color"), texture: tex,
                 additive: i.int("blending") == 1, depthTest: i.int("depth") == 1)
    }
}

/// Matches `ParticleInstance` in ShaderLibrary (48-byte stride; `color` starts at 32).
package struct ParticleInstance {
    package var position: SIMD2<Float>
    package var z: Float
    package var size: Float
    package var alpha: Float
    /// The emitter's color when the particle was born.
    package var color: SIMD4<Float>
}

package struct ParticleUniforms {
    package var modelView: simd_float4x4
    package var projection: simd_float4x4
    package var hasTexture: Int32
}

package final class ParticleSystemPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "particle-system" }
    package override class var title: String { "Particle System" }
    package override class var category: PatchCategory { .consumer }
    package override class var summary: String { "Emits and draws particles (GPU instanced). Follows its Time Base, so it can be stopped, rewound or scrubbed." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true),
         .position("x", "X Position"), .position("y", "Y Position"), .position("z", "Z Position"),
         .number("count", "Count", 600, 1...2000).limited(1...20000),
         .number("lifetime", "Lifetime", 2, 0.1...10).limited(min: 0.01),
         .number("speed", "Speed", 0.6, 0...3).limited(min: 0), .angle("direction", "Direction (°)", 90),
         .number("spread", "Spread (°)", 360, 0...360).limited(0...360), .number("gravity", "Gravity", -0.4, -3...3),
         .number("size", "Size", 0.05, 0...0.3).limited(min: 0),
         .color("color", "Color", SIMD4(1, 0.6, 0.2, 1)), .image("image", "Image"),
         .menu("blending", "Blending", ["Over", "Add"], 1),
         PortSpec.number("seed", "Random Seed", 0).setting()]
    }

    /// Emitter settings at a moment in time. Each particle uses the values from its birth.
    private struct EmitterSample {
        var time: Double
        var origin: SIMD3<Float>
        var speed: Float
        var direction: Float // radians
        var spread: Float    // radians
        var color: SIMD4<Float>
    }

    /// Emitter history, sorted by time. Kept for `historySeconds` around the latest time so the
    /// system can be stopped, rewound or scrubbed (External time base) and still look the same.
    private var history: [EmitterSample] = []
    package static let historySeconds = 120.0

    package override func reset() { history.removeAll() }

    /// Particles alive at `time`. A pure function of time and the recorded emitter history:
    /// particle k is born at k / rate with its own fixed random values, so playing forward,
    /// pausing, rewinding or jumping to a time always gives the same picture.
    package func instances(_ i: Inputs, time t: Double) -> [ParticleInstance] {
        let count = min(max(1, i.int("count")), 20000) // inputs can be wired to anything
        let life = max(0.05, i.number("lifetime"))
        record(EmitterSample(time: t, origin: SIMD3(i.float("x"), i.float("y"), i.float("z")),
                             speed: i.float("speed"), direction: i.float("direction") * .pi / 180,
                             spread: i.float("spread") * .pi / 180, color: i.color("color")))

        let rate = Double(count) / life
        guard t >= 0 else { return [] }
        let newest = Int((t * rate).rounded(.down))
        let oldest = max(0, Int(((t - life) * rate).rounded(.up)))
        guard newest >= oldest else { return [] }

        let seed = i.number("seed") * 7.31
        let gravity = SIMD2<Float>(0, i.float("gravity"))
        let baseSize = i.float("size")
        var out: [ParticleInstance] = []
        out.reserveCapacity(newest - oldest + 1)
        for k in oldest...newest {
            func random(_ n: Double) -> Float { Float(MathExpression.hash(Double(k) * 3.17 + n + seed)) }
            let birth = Double(k) / rate
            let lifespan = Float(life) * (0.6 + 0.4 * random(0))
            let age = Float(t - birth)
            guard age >= 0, age < lifespan else { continue }
            let e = sample(at: birth)
            let angle = e.direction + (random(1) - 0.5) * e.spread
            let velocity = SIMD2(cos(angle), sin(angle)) * e.speed * (0.4 + 0.6 * random(2))
            let position = SIMD2(e.origin.x, e.origin.y) + velocity * age + 0.5 * gravity * age * age
            let f = age / lifespan
            out.append(ParticleInstance(position: position, z: e.origin.z, size: baseSize * (1 - 0.6 * f),
                                        alpha: 1 - f, color: e.color))
        }
        return out
    }

    /// Stores the emitter state at `sample.time`, replacing a sample at (almost) the same time.
    private func record(_ sample: EmitterSample) {
        let i = insertionIndex(sample.time)
        let tolerance = 1.0 / 240
        if i < history.count, abs(history[i].time - sample.time) < tolerance {
            history[i] = sample
        } else if i > 0, abs(history[i - 1].time - sample.time) < tolerance {
            history[i - 1] = sample
        } else {
            history.insert(sample, at: i)
        }
        history.removeAll { abs($0.time - sample.time) > Self.historySeconds }
    }

    private func insertionIndex(_ t: Double) -> Int {
        var lo = 0, hi = history.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if history[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Emitter state at time `t`, interpolated between recorded samples.
    private func sample(at t: Double) -> EmitterSample {
        let i = insertionIndex(t)
        if i == 0 { return history[0] }
        if i >= history.count { return history[history.count - 1] }
        let a = history[i - 1], b = history[i]
        let f = Float((t - a.time) / max(b.time - a.time, 1e-9))
        return EmitterSample(time: t, origin: a.origin + (b.origin - a.origin) * f,
                             speed: a.speed + (b.speed - a.speed) * f,
                             direction: a.direction + (b.direction - a.direction) * f,
                             spread: a.spread + (b.spread - a.spread) * f,
                             color: a.color + (b.color - a.color) * f)
    }

    package override func render(_ i: Inputs, _ ctx: RenderContext) {
        guard i.bool("enable") else { return }
        let instances = instances(i, time: ctx.eval.time)
        guard !instances.isEmpty,
              let buffer = ctx.resources.device.makeBuffer(bytes: instances,
                                                           length: MemoryLayout<ParticleInstance>.stride * instances.count)
        else { return }

        let tex = i.image("image")
        var u = ParticleUniforms(modelView: ctx.modelView, projection: ctx.projection, hasTexture: tex == nil ? 0 : 1)
        let res = ctx.resources
        let enc = ctx.encoder
        enc.setRenderPipelineState(i.int("blending") == 1 ? res.particleAdd : res.particleOver)
        enc.setDepthStencilState(res.depthReadOnly)
        enc.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.setVertexBuffer(buffer, offset: 0, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex ?? res.whiteTexture, index: 0)
        enc.setFragmentSamplerState(res.sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}

package struct ShaderUniforms {
    package var time: Float
    package var resolution: SIMD2<Float>
    package var mouse: SIMD2<Float>
    package var color: SIMD4<Float>
    package var params: SIMD4<Float>
}

package final class MetalShaderPatch: Patch {
    package override class var usesTime: Bool { true }
    package override class var typeID: String { "metal-shader" }
    package override class var title: String { "Metal Shader" }
    package override class var category: PatchCategory { .consumer }
    package override class var summary: String { "Full-screen fragment shader written in Metal Shading Language, compiled live." }
    package override class var inputSpecs: [PortSpec] {
        [.bool("enable", "Enable", true), .color("color", "Color"),
         .number("p1", "Param 1", 0, 0...1), .number("p2", "Param 2", 0, 0...1),
         .number("p3", "Param 3", 0, 0...1), .number("p4", "Param 4", 0, 0...1),
         .image("image", "Image"),
         .string("source", "Source", ShaderLibrary.defaultUserShader, isPort: false, multiline: true)]
    }

    package override func render(_ i: Inputs, _ ctx: RenderContext) {
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
        enc.setDepthStencilState(res.depthOff)
        enc.setFragmentBytes(&u, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        enc.setFragmentTexture(i.image("image") ?? res.whiteTexture, index: 0)
        enc.setFragmentSamplerState(res.sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
