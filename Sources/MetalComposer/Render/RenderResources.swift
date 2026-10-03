import CoreImage
import Metal
import MetalKit

struct ShaderCompileError: Error {
    let message: String
}

/// Shared GPU objects: pipelines, samplers, texture loader and the live shader cache.
final class RenderResources {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    static let depthFormat: MTLPixelFormat = .depth32Float

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let clearPipeline: MTLRenderPipelineState
    let spriteOver: MTLRenderPipelineState
    let spriteAdd: MTLRenderPipelineState
    let particleOver: MTLRenderPipelineState
    let particleAdd: MTLRenderPipelineState
    let sampler: MTLSamplerState
    /// Depth states: no test, test + write (opaque 3D), test only (translucent), and reset (Clear).
    let depthOff: MTLDepthStencilState
    let depthReadWrite: MTLDepthStencilState
    let depthReadOnly: MTLDepthStencilState
    let depthReset: MTLDepthStencilState
    let whiteTexture: MTLTexture
    let transparentTexture: MTLTexture
    let textureLoader: MTKTextureLoader
    let ciContext: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var userShaders: [String: Result<MTLRenderPipelineState, ShaderCompileError>] = [:]

    enum Blend { case none, over, add }

    init(device: MTLDevice) throws {
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

    static func makePipeline(device: MTLDevice, library: MTLLibrary, vertex: String, fragment: String,
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
    func userShaderPipeline(source: String) -> Result<MTLRenderPipelineState, ShaderCompileError> {
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
