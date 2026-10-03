import AppKit
import CoreImage
import Metal
import MetalKit

final class ImageImporterPatch: Patch {
    override class var typeID: String { "image-importer" }
    override class var title: String { "Image Importer" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "Loads an image file (PNG, JPEG, HEIC…) into a texture." }
    override class var inputSpecs: [PortSpec] {
        [.string("path", "File", "", isPort: false, isFilePath: true)]
    }
    override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var loadedPath: String?
    private var texture: MTLTexture?

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let path = (i.string("path") as NSString).expandingTildeInPath
        if path != loadedPath {
            loadedPath = path
            texture = nil
            if path.isEmpty {
                setStatus(nil)
            } else {
                do {
                    texture = try ctx.resources.textureLoader.newTexture(
                        URL: URL(fileURLWithPath: path),
                        options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
                    setStatus(nil)
                } catch {
                    setStatus("Could not load image: \(error.localizedDescription)")
                }
            }
        }
        return ["image": .image(texture)]
    }
}

final class TextImagePatch: Patch {
    override class var typeID: String { "text-image" }
    override class var title: String { "Text Image" }
    override class var category: PatchCategory { .provider }
    override class var summary: String { "Renders a string into an image (white, tint it with Sprite color)." }
    override class var inputSpecs: [PortSpec] {
        [.string("text", "String", "Hello"), .number("size", "Font Size", 64, 8...300),
         .menu("weight", "Weight", ["Regular", "Medium", "Bold", "Heavy", "Monospaced"], 2)]
    }
    override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var key = ""
    private var texture: MTLTexture?

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let text = i.string("text"), size = max(1, i.number("size")), weight = i.int("weight")
        let newKey = "\(text)|\(size)|\(weight)"
        if newKey != key {
            key = newKey
            texture = Self.makeTexture(device: ctx.device, text: text, size: size, weight: weight)
        }
        return ["image": .image(texture)]
    }

    static func makeTexture(device: MTLDevice, text: String, size: Double, weight: Int) -> MTLTexture? {
        guard !text.isEmpty else { return nil }
        let font: NSFont
        switch weight {
        case 0: font = .systemFont(ofSize: size, weight: .regular)
        case 1: font = .systemFont(ofSize: size, weight: .medium)
        case 3: font = .systemFont(ofSize: size, weight: .heavy)
        case 4: font = .monospacedSystemFont(ofSize: size, weight: .regular)
        default: font = .systemFont(ofSize: size, weight: .bold)
        }
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let bounds = string.boundingRect(with: CGSize(width: 8192, height: 8192), options: [.usesLineFragmentOrigin])
        let pad = 4
        let w = min(Int(ceil(bounds.width)) + pad * 2, 8192)
        let h = min(Int(ceil(bounds.height)) + pad * 2, 8192)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        string.draw(with: CGRect(x: CGFloat(pad), y: CGFloat(pad), width: bounds.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()

        guard let data = cg.data else { return nil }
        // Store straight (non-premultiplied) white so tinting and alpha blending stay clean.
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for p in 0..<(w * h) {
            px[p * 4] = 255; px[p * 4 + 1] = 255; px[p * 4 + 2] = 255
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }
}

final class CoreImageFilterPatch: Patch {
    override class var typeID: String { "core-image-filter" }
    override class var title: String { "Core Image Filter" }
    override class var summary: String { "Applies a Core Image filter on the GPU." }
    static let filters = ["Gaussian Blur", "Pixellate", "Bloom", "Color Invert", "Sepia Tone", "Edges", "Vignette", "Comic"]
    override class var inputSpecs: [PortSpec] {
        [.image("image", "Image"), .menu("filter", "Filter", filters), .number("amount", "Amount", 10, 0...100)]
    }
    override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var output: MTLTexture?

    override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        guard let src = i.image("image") else { return ["image": .image(nil)] }
        if output == nil || output!.width != src.width || output!.height != src.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: src.width, height: src.height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            output = ctx.device.makeTexture(descriptor: desc)
        }
        let space = ctx.resources.colorSpace
        guard let out = output, var image = CIImage(mtlTexture: src, options: [.colorSpace: space]) else {
            return ["image": .image(src)]
        }
        let extent = image.extent
        let amount = i.number("amount")
        switch i.int("filter") {
        case 0: image = image.clampedToExtent().applyingGaussianBlur(sigma: amount)
        case 1: image = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, amount), kCIInputCenterKey: CIVector(x: 0, y: 0)])
        case 2: image = image.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: amount, kCIInputIntensityKey: 1])
        case 3: image = image.applyingFilter("CIColorInvert")
        case 4: image = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: min(1, amount / 100)])
        case 5: image = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: amount])
        case 6: image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: amount / 10, kCIInputRadiusKey: 2])
        case 7: image = image.applyingFilter("CIComicEffect")
        default: break
        }
        ctx.resources.ciContext.render(image.cropped(to: extent), to: out, commandBuffer: ctx.commandBuffer,
                                       bounds: extent, colorSpace: space)
        return ["image": .image(out)]
    }
}
