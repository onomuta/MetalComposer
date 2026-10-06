import CoreImage
import Metal
import MetalKit

package struct ShaderCompileError: Error {
    package let message: String
}

/// Shared GPU objects: pipelines, samplers, texture loader and the live shader cache.
package final class RenderResources {
    package static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    package static let depthFormat: MTLPixelFormat = .depth32Float

    package let device: MTLDevice
    package let queue: MTLCommandQueue
    package let library: MTLLibrary
    package let clearPipeline: MTLRenderPipelineState
    package let spriteOver: MTLRenderPipelineState
    package let spriteAdd: MTLRenderPipelineState
    package let meshOver: MTLRenderPipelineState
    package let meshAdd: MTLRenderPipelineState
    package let particleOver: MTLRenderPipelineState
    package let particleAdd: MTLRenderPipelineState
    package let sampler: MTLSamplerState
    /// Depth states: no test, test + write (opaque 3D), test only (translucent), and reset (Clear).
    package let depthOff: MTLDepthStencilState
    package let depthReadWrite: MTLDepthStencilState
    package let depthReadOnly: MTLDepthStencilState
    package let depthReset: MTLDepthStencilState
    package let whiteTexture: MTLTexture
    package let transparentTexture: MTLTexture
    package let textureLoader: MTKTextureLoader
    package let ciContext: CIContext
    package let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws Text Image strings on the GPU from cached glyphs (nil if its pipeline failed to build;
    /// Text Image then draws on the CPU).
    package private(set) lazy var textRenderer: TextRenderer? = try? TextRenderer(device: device, library: library)

    /// Folder that relative file paths (Image Importer) are resolved against: the composition's folder.
    package var baseDirectory: URL?

    private var userShaders: [String: Result<MTLRenderPipelineState, ShaderCompileError>] = [:]

    package enum Blend { case none, over, add }

    package init(device: MTLDevice) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: ShaderLibrary.builtin, options: nil)
        library = lib

        let pipeline = { (v: String, f: String, blend: Blend) throws -> MTLRenderPipelineState in
            try RenderResources.makePipeline(device: device, library: lib, vertex: v, fragment: f, blend: blend)
        }
        clearPipeline = try pipeline("fullscreen_vertex", "clear_fragment", .none)
        spriteOver = try pipeline("sprite_vertex", "sprite_fragment", .over)
        spriteAdd = try pipeline("sprite_vertex", "sprite_fragment", .add)
        meshOver = try pipeline("mesh_vertex", "sprite_fragment", .over)
        meshAdd = try pipeline("mesh_vertex", "sprite_fragment", .add)
        particleOver = try pipeline("particle_vertex", "particle_fragment", .over)
        particleAdd = try pipeline("particle_vertex", "particle_fragment", .add)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteTexture = device.makeTexture(descriptor: td)!
        var white: UInt32 = 0xFFFF_FFFF
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        transparentTexture = device.makeTexture(descriptor: td)!
        var clear: UInt32 = 0
        transparentTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 4)

        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthOff = depthState(.always, write: false)
        // lessEqual lets coplanar 2D layers at z = 0 keep drawing in layer order.
        depthReadWrite = depthState(.lessEqual, write: true)
        depthReadOnly = depthState(.lessEqual, write: false)
        depthReset = depthState(.always, write: true)

        textureLoader = MTKTextureLoader(device: device)
        ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: colorSpace])
    }

    package static func makePipeline(device: MTLDevice, library: MTLLibrary, vertex: String, fragment: String,
                             blend: Blend) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        let att = d.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        d.depthAttachmentPixelFormat = depthFormat
        if blend != .none {
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    /// Compiles (or returns the cached) pipeline for a user-written fragment shader.
    package func userShaderPipeline(source: String) -> Result<MTLRenderPipelineState, ShaderCompileError> {
        if let cached = userShaders[source] { return cached }
        if userShaders.count > 64 { userShaders.removeAll() }
        let result: Result<MTLRenderPipelineState, ShaderCompileError>
        do {
            let lib = try device.makeLibrary(source: ShaderLibrary.wrapUserShader(source), options: nil)
            result = .success(try Self.makePipeline(device: device, library: lib, vertex: "mc_vertex",
                                                    fragment: "mc_fragment", blend: .over))
        } catch {
            result = .failure(ShaderCompileError(message: Self.cleanCompilerMessage(error)))
        }
        userShaders[source] = result
        return result
    }

    private static func cleanCompilerMessage(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let lines = text.components(separatedBy: "\n")
            .filter { $0.contains("error:") }
            .map { $0.replacingOccurrences(of: "program_source:", with: "line ") }
        return lines.isEmpty ? text : lines.joined(separator: "\n")
    }
}
