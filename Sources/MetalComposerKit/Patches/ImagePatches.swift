import AppKit
import CoreImage
import Metal
import MetalKit

package final class ImageImporterPatch: Patch {
    package override class var typeID: String { "image-importer" }
    package override class var title: String { "Image Importer" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Loads an image file (PNG, JPEG, HEIC…) into a texture." }
    package override class var inputSpecs: [PortSpec] {
        [.string("path", "File", "", isPort: false, isFilePath: true),
         .bool("embed", "Embed in Composition", false).setting(),
         // The file's bytes (base64), kept in the composition while Embed is on. The editor fills it.
         .string("data", "Embedded Data", "").hiddenSetting()]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    /// Embedded images larger than this make opening the composition noticeably slower.
    package static let embedWarningBytes = 10_000_000

    /// Size in bytes of the embedded image (0 when nothing is embedded).
    package var embeddedByteCount: Int {
        guard params["embed"]?.bool == true, let data = params["data"]?.string else { return 0 }
        return data.utf8.count / 4 * 3
    }

    private var loadedPath: String?
    private var loadedData: String?
    private var texture: MTLTexture?

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        // An embedded image wins over the file, so the composition works without it.
        if i.bool("embed"), case let data = i.string("data"), !data.isEmpty {
            if data != loadedData {
                loadedData = data
                loadedPath = nil
                texture = nil
                do {
                    guard let bytes = Data(base64Encoded: data) else { throw CocoaError(.fileReadCorruptFile) }
                    texture = try ctx.resources.textureLoader.newTexture(
                        data: bytes, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
                    setStatus(nil)
                } catch {
                    setStatus("Could not load the embedded image: \(error.localizedDescription)")
                }
            }
            return ["image": .image(texture)]
        }
        loadedData = nil

        var path = (i.string("path") as NSString).expandingTildeInPath
        // Relative paths are relative to the composition file, so a folder of material moves as one.
        if !path.isEmpty, !path.hasPrefix("/"), let base = ctx.resources.baseDirectory {
            path = base.appendingPathComponent(path).standardizedFileURL.path
        }
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

package final class TextImagePatch: Patch {
    package override class var typeID: String { "text-image" }
    package override class var title: String { "Text Image" }
    package override class var category: PatchCategory { .provider }
    package override class var summary: String { "Renders a string into an image (white, tint it with Sprite color)." }
    package override class var inputSpecs: [PortSpec] {
        [.string("text", "String", "Hello"), .number("size", "Font Size", 64, 8...200).limited(1...2000),
         .font("font", "Font"),
         // Only for the system font; another font's style is part of its name.
         .menu("weight", "Weight", ["Regular", "Medium", "Bold", "Heavy", "Monospaced"], 2),
         .menu("spacing", "Spacing", ["Proportional", "Monospaced Digits", "Monospaced"])]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var key = ""
    private var texture: MTLTexture?

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let text = i.string("text"), size = max(1, i.number("size")), weight = i.int("weight")
        let fontName = i.string("font"), spacing = i.int("spacing")
        let newKey = "\(text)|\(size)|\(weight)|\(fontName)|\(spacing)"
        if newKey != key {
            key = newKey
            texture = Self.makeTexture(device: ctx.device, text: text, size: size, weight: weight, fontName: fontName,
                                       spacing: spacing)
            // A composition may be opened on a Mac that doesn't have the font installed.
            setStatus(fontName.isEmpty || NSFont(name: fontName, size: size) != nil
                      ? nil : "Font \"\(fontName)\" is not installed; using the system font.")
        }
        return ["image": .image(texture)]
    }

    private typealias TextLayout = (size: CGSize, draw: (CGPoint) -> Void)

    /// The string as the font lays it out (kerning and each character's own width).
    private static func proportionalLayout(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> TextLayout {
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.boundingRect(with: CGSize(width: 8192, height: 8192), options: [.usesLineFragmentOrigin])
        return (bounds.size, { origin in
            string.draw(with: CGRect(origin: origin, size: bounds.size), options: [.usesLineFragmentOrigin])
        })
    }

    /// Characters centered in equal-width cells, so the image doesn't change width or jitter when
    /// the text changes (counters, clocks, random strings). Works with any font. With
    /// `allCharacters` false only digits get cells (their widest digit); other characters keep
    /// their own width.
    private static func cellLayout(_ text: String, _ attributes: [NSAttributedString.Key: Any],
                                   allCharacters: Bool) -> TextLayout {
        func advance(_ c: Character) -> CGFloat { NSAttributedString(string: String(c), attributes: attributes).size().width }
        let digitCell = "0123456789".map(advance).max() ?? 0
        // Every letter and digit fits, plus anything wider in this text (symbols, kana…).
        let alphanumerics = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let cell = (alphanumerics + Array(text)).map(advance).max() ?? 0
        func slot(_ c: Character) -> CGFloat {
            if allCharacters { return cell }
            return c.isASCII && c.isNumber ? digitCell : advance(c)
        }
        let font = attributes[.font] as! NSFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = lines.map { $0.reduce(0) { $0 + slot($1) } }.max() ?? 0
        return (CGSize(width: width, height: lineHeight * CGFloat(lines.count)), { origin in
            for (row, line) in lines.enumerated() {
                var x = origin.x
                let y = origin.y + lineHeight * CGFloat(lines.count - 1 - row)
                for c in line {
                    let s = slot(c)
                    NSAttributedString(string: String(c), attributes: attributes)
                        .draw(at: CGPoint(x: x + (s - advance(c)) / 2, y: y))
                    x += s
                }
            }
        })
    }

    package static func makeTexture(device: MTLDevice, text: String, size: Double, weight: Int,
                                    fontName: String = "", spacing: Int = 0) -> MTLTexture? {
        guard !text.isEmpty else { return nil }
        var font: NSFont
        switch weight {
        case 0: font = .systemFont(ofSize: size, weight: .regular)
        case 1: font = .systemFont(ofSize: size, weight: .medium)
        case 3: font = .systemFont(ofSize: size, weight: .heavy)
        case 4: font = .monospacedSystemFont(ofSize: size, weight: .regular)
        default: font = .systemFont(ofSize: size, weight: .bold)
        }
        if !fontName.isEmpty, let named = NSFont(name: fontName, size: size) { font = named }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let pad = 4
        let layout = spacing == 0 ? proportionalLayout(text, attributes) : cellLayout(text, attributes, allCharacters: spacing == 2)
        let w = min(Int(ceil(layout.size.width)) + pad * 2, 8192)
        let h = min(Int(ceil(layout.size.height)) + pad * 2, 8192)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        layout.draw(CGPoint(x: pad, y: pad))
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

package final class CoreImageFilterPatch: Patch {
    package override class var typeID: String { "core-image-filter" }
    package override class var title: String { "Core Image Filter" }
    package override class var summary: String { "Applies a Core Image filter on the GPU." }
    package static let filters = ["Gaussian Blur", "Pixellate", "Bloom", "Color Invert", "Sepia Tone", "Edges", "Vignette", "Comic"]
    package override class var inputSpecs: [PortSpec] {
        [.image("image", "Image"), .menu("filter", "Filter", filters), .number("amount", "Amount", 10, 0...100).limited(min: 0)]
    }
    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    private var output: MTLTexture?

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
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
