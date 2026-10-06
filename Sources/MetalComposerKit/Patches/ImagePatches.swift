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
         .font("font", "Font"), .fontStyle("fontStyle", "Weight", "Bold"),
         .menu("spacing", "Spacing", ["Proportional", "Monospaced Digits", "Monospaced"])]
    }

    /// The Font value for the system's monospaced font ("" is the regular system font).
    package static let systemMonospaced = "System Monospaced"

    /// The system fonts' weights, lightest first.
    package static let systemWeights: [(name: String, weight: NSFont.Weight)] = [
        ("Ultralight", .ultraLight), ("Thin", .thin), ("Light", .light), ("Regular", .regular), ("Medium", .medium),
        ("Semibold", .semibold), ("Bold", .bold), ("Heavy", .heavy), ("Black", .black),
    ]

    /// One style of a family: its PostScript name, the style name shown in Weight, and its traits.
    package struct FontStyle {
        package var postScriptName: String
        package var name: String
        package var weight: CGFloat
        package var width: CGFloat
        package var italic: Bool
    }

    /// The styles Weight offers for a family, lightest first (each upright style before its italic).
    /// Empty when the family isn't installed.
    package static func styles(of family: String) -> [FontStyle] {
        if let known = stylesByFamily[family] { return known }
        let found = findStyles(of: family)
        // Fonts installed while the app runs show up after a restart (like the Font menu).
        if !found.isEmpty { stylesByFamily[family] = found }
        return found
    }

    private static var stylesByFamily: [String: [FontStyle]] = [:]

    private static func findStyles(of family: String) -> [FontStyle] {
        if family.isEmpty || family == systemMonospaced {
            return systemWeights.map { FontStyle(postScriptName: "", name: $0.name, weight: $0.weight.rawValue, width: 0, italic: false) }
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { m -> FontStyle? in
            guard m.count >= 4, let ps = m[0] as? String, let name = m[1] as? String, let traits = m[3] as? UInt,
                  let font = NSFont(name: ps, size: 12) else { return nil }
            let t = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return FontStyle(postScriptName: ps, name: name, weight: t?[.weight] as? CGFloat ?? 0,
                             width: t?[.width] as? CGFloat ?? 0, italic: traits & NSFontTraitMask.italicFontMask.rawValue != 0)
        }
        .sorted { ($0.weight, abs($0.width), $0.italic ? 1 : 0) < ($1.weight, abs($1.width), $1.italic ? 1 : 0) }
    }

    /// A guess at how heavy a style name is, for picking the closest style in a family that
    /// doesn't have it (the longest matching word wins, so "ExtraBold" isn't read as "Bold").
    private static func weightGuess(_ style: String) -> CGFloat {
        let s = style.lowercased().filter { $0.isLetter }
        let words: [(String, CGFloat)] = [
            ("hairline", -0.7), ("ultralight", -0.8), ("extralight", -0.5), ("thin", -0.6), ("light", -0.4),
            ("book", -0.1), ("regular", 0), ("roman", 0), ("medium", 0.23), ("semibold", 0.3), ("demibold", 0.3),
            ("demi", 0.3), ("bold", 0.4), ("extrabold", 0.56), ("ultrabold", 0.56), ("heavy", 0.56), ("black", 0.62),
        ]
        return words.filter { s.contains($0.0) }.max { $0.0.count < $1.0.count }?.1 ?? 0
    }

    /// The style of `family` that Weight `style` means: the one with that name, otherwise the
    /// closest in weight (same slant, normal width preferred). Nil when the family isn't installed.
    package static func resolvedStyle(family: String, style: String) -> FontStyle? {
        let styles = styles(of: family)
        if let exact = styles.first(where: { $0.name.caseInsensitiveCompare(style) == .orderedSame }) { return exact }
        let target = weightGuess(style), italic = style.lowercased().contains("italic")
        let sameSlant = styles.filter { $0.italic == italic }
        return (sameSlant.isEmpty ? styles : sameSlant)
            .min { abs($0.weight - target) + abs($0.width) < abs($1.weight - target) + abs($1.width) }
    }

    /// The font for a family and Weight. Nil when the family isn't installed.
    package static func font(family: String, style: String, size: Double) -> NSFont? {
        guard let resolved = resolvedStyle(family: family, style: style) else { return nil }
        let weight = NSFont.Weight(resolved.weight)
        if family.isEmpty { return .systemFont(ofSize: size, weight: weight) }
        if family == systemMonospaced { return .monospacedSystemFont(ofSize: size, weight: weight) }
        return NSFont(name: resolved.postScriptName, size: size)
    }

    /// Before 0.9, Font held a style's PostScript name and Weight was a menu (Regular, Medium,
    /// Bold, Heavy, Monospaced) that only applied to the system font.
    package override func upgradeParams(saved: [String: Value]) {
        params["weight"] = nil
        guard saved["fontStyle"] == nil else { return }
        let oldFont = saved["font"]?.string ?? ""
        if !oldFont.isEmpty {
            if let font = NSFont(name: oldFont, size: 12), let family = font.familyName,
               let style = Self.styles(of: family).first(where: { $0.postScriptName == oldFont }) {
                params["font"] = .string(family)
                params["fontStyle"] = .string(style.name)
            } else {
                // Not installed here: guess from the PostScript name, e.g. "Outfit-Light".
                let parts = oldFont.split(separator: "-", maxSplits: 1).map(String.init)
                params["font"] = .string(parts[0])
                params["fontStyle"] = .string(parts.count > 1 ? parts[1] : "Regular")
            }
        } else if let old = saved["weight"].map({ Int($0.number.rounded()) }) {
            if old == 4 { params["font"] = .string(Self.systemMonospaced) }
            params["fontStyle"] = .string(["Regular", "Medium", "Bold", "Heavy", "Regular"][min(max(old, 0), 4)])
        }
    }

    package override class var outputSpecs: [PortSpec] { [.image("image", "Image")] }

    /// Recently rendered images by settings. Several are kept so a Text Image inside an Iterator,
    /// which shows a different string on each pass, renders each string once instead of every pass.
    /// Bounded by memory: images of large text are big, and a string that changes many times a
    /// second would otherwise fill the cache with images that are never shown again.
    private var cache: [String: (texture: MTLTexture?, used: Int)] = [:]
    private var cacheBytes = 0
    private var useCounter = 0
    package static let cacheByteLimit = 16_000_000

    package override func reset() { cache.removeAll(); cacheBytes = 0 }

    package override func evaluate(_ i: Inputs, _ ctx: EvalContext) -> [String: Value] {
        let text = i.string("text"), size = max(1, i.number("size")), style = i.string("fontStyle")
        let family = i.string("font"), spacing = i.int("spacing")
        let key = "\(text)|\(size)|\(style)|\(family)|\(spacing)"
        useCounter += 1
        if let hit = cache[key] {
            cache[key]?.used = useCounter
            return ["image": .image(hit.texture)]
        }
        var texture: MTLTexture?
        if !text.isEmpty {
            let layout = TextLayout.make(text, font: Self.resolvedFont(family: family, style: style, size: size), spacing: spacing)
            // On the GPU from cached glyphs; on the CPU for glyphs too large for the glyph atlas.
            texture = ctx.resources.textRenderer?.render(layout, commandBuffer: ctx.commandBuffer)
                ?? layout.drawOnCPU(device: ctx.device)
        }
        let bytes = texture.map { $0.width * $0.height * 4 } ?? 0
        // Drop the least recently used images until the new one fits.
        while cacheBytes + bytes > Self.cacheByteLimit,
              let oldest = cache.min(by: { $0.value.used < $1.value.used }) {
            cacheBytes -= oldest.value.texture.map { $0.width * $0.height * 4 } ?? 0
            cache[oldest.key] = nil
        }
        cache[key] = (texture, useCounter)
        cacheBytes += bytes
        // A composition may be opened on a Mac that doesn't have the font installed.
        setStatus(Self.font(family: family, style: style, size: size) != nil
                  ? nil : "Font \"\(family)\" is not installed; using the system font.")
        return ["image": .image(texture)]
    }

    /// The font Text Image uses: the family's style, or the system font when the family is missing.
    package static func resolvedFont(family: String, style: String, size: Double) -> NSFont {
        font(family: family, style: style, size: size) ?? font(family: "", style: style, size: size)!
    }

    /// Draws text on the CPU (for tools without a command buffer). Text Image itself draws on the GPU.
    package static func makeTexture(device: MTLDevice, text: String, size: Double, family: String = "",
                                    style: String = "Bold", spacing: Int = 0) -> MTLTexture? {
        guard !text.isEmpty else { return nil }
        let font = resolvedFont(family: family, style: style, size: size)
        return TextLayout.make(text, font: font, spacing: spacing).drawOnCPU(device: device)
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
