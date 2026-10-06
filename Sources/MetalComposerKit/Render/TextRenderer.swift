import AppKit
import CoreText
import Metal

/// One glyph of a laid-out text: which glyph of which font, and its pen position (baseline origin)
/// in pixels, measured from the bottom-left of the image (y up, like Core Graphics).
package struct PlacedGlyph {
    package var font: CTFont
    package var glyph: CGGlyph
    package var position: CGPoint
}

/// Text laid out for Text Image: the image size (padding included) and where each glyph goes.
package struct TextLayout {
    package var size: CGSize
    package var glyphs: [PlacedGlyph]

    package static let padding: CGFloat = 4

    /// Lays out `text`, one line per "\n". Spacing 0 uses the font's own advances and kerning;
    /// 1 puts digits in equal cells (their widest digit); 2 puts every character in equal cells
    /// (as wide as the widest letter or digit, or any wider character in the text), centered.
    package static func make(_ text: String, font: NSFont, spacing: Int) -> TextLayout {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let descent = ceil(-font.descender)
        let metrics = CharacterMetrics.shared
        var cell: CGFloat = 0, digitCell: CGFloat = 0
        if spacing != 0 {
            let cells = metrics.cells(font)
            digitCell = cells.digit
            cell = max(cells.alphanumeric, text.map { metrics.of($0, font).advance }.max() ?? 0)
        }
        var placed: [PlacedGlyph] = []
        var width: CGFloat = 0
        for (row, line) in lines.enumerated() {
            let baseline = padding + lineHeight * CGFloat(lines.count - 1 - row) + descent
            if spacing == 0 {
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))
                for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    CTRunGetPositions(run, CFRange(), &positions)
                    let runFont = Self.font(of: run, default: font)
                    for k in 0..<count {
                        placed.append(PlacedGlyph(font: runFont, glyph: glyphs[k],
                                                  position: CGPoint(x: padding + positions[k].x, y: baseline + positions[k].y)))
                    }
                }
                width = max(width, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
            } else {
                var x = padding
                for c in line {
                    let m = metrics.of(c, font)
                    let slot = spacing == 2 ? cell : (c.isASCII && c.isNumber ? digitCell : m.advance)
                    let start = x + (slot - m.advance) / 2
                    for g in m.glyphs {
                        placed.append(PlacedGlyph(font: g.font, glyph: g.glyph,
                                                  position: CGPoint(x: start + g.offset.x, y: baseline + g.offset.y)))
                    }
                    x += slot
                }
                width = max(width, x - padding)
            }
        }
        let size = CGSize(width: min(ceil(width) + padding * 2, 8192),
                          height: min(lineHeight * CGFloat(lines.count) + padding * 2, 8192))
        return TextLayout(size: size, glyphs: placed)
    }

    fileprivate static func font(of run: CTRun, default font: NSFont) -> CTFont {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName] else { return font }
        return value as! CTFont // swiftlint:disable:this force_cast
    }

    /// Draws the glyphs on the CPU into a straight-alpha white RGBA texture. Used when the GPU
    /// path can't (very large glyphs) and by tools that render without a command buffer.
    package func drawOnCPU(device: MTLDevice) -> MTLTexture? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for g in glyphs {
            var glyph = g.glyph, position = g.position
            CTFontDrawGlyphs(g.font, &glyph, &position, 1, cg)
        }
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

/// Character advances and glyphs by font, measured once: laying out a character is slow, and
/// equal-cell spacing needs the width of every letter and digit.
package final class CharacterMetrics {
    package static let shared = CharacterMetrics()

    package struct Glyph { var font: CTFont; var glyph: CGGlyph; var offset: CGPoint }
    package struct Metrics { var advance: CGFloat; var glyphs: [Glyph] }

    private var byFont: [String: [Character: Metrics]] = [:]
    private var cellsByFont: [String: (digit: CGFloat, alphanumeric: CGFloat)] = [:]

    private static func key(_ font: NSFont) -> String { "\(font.fontName)|\(font.pointSize)" }

    package func of(_ c: Character, _ font: NSFont) -> Metrics {
        let key = Self.key(font)
        if let m = byFont[key]?[c] { return m }
        // A one-character line, so font fallback (e.g. kana in a Latin font) and multi-glyph
        // characters come out as Core Text would draw them.
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(c), attributes: [.font: font]))
        var glyphs: [Glyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &ids)
            CTRunGetPositions(run, CFRange(), &positions)
            let runFont = TextLayout.font(of: run, default: font)
            for k in 0..<count { glyphs.append(Glyph(font: runFont, glyph: ids[k], offset: positions[k])) }
        }
        let m = Metrics(advance: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), glyphs: glyphs)
        if byFont.count > 64 { byFont.removeAll() }
        byFont[key, default: [:]][c] = m
        return m
    }

    package func cells(_ font: NSFont) -> (digit: CGFloat, alphanumeric: CGFloat) {
        let key = Self.key(font)
        if let c = cellsByFont[key] { return c }
        let digit = "0123456789".map { of($0, font).advance }.max() ?? 0
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".map { of($0, font).advance }.max() ?? 0
        let c = (digit, max(digit, letters))
        cellsByFont[key] = c
        return c
    }
}

/// Draws laid-out text on the GPU from an atlas of glyph images. Each glyph is rasterized once
/// (per font and size); a new string only costs one small render pass. Main thread only.
package final class TextRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private static let atlasSize = 2048
    /// Glyphs larger than this (huge font sizes) are drawn on the CPU instead.
    private static let maxGlyph = 512

    private struct Entry { var x: Int; var y: Int; var width: Int; var height: Int; var origin: CGPoint }
    private var atlas: MTLTexture?
    /// Bumped whenever a new atlas is started (the old entries are gone).
    private var atlasGeneration = 0
    private var entries: [String: Entry] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0

    /// Matches `GlyphInstance` in ShaderLibrary.
    private struct Instance { var destination: SIMD4<Float>; var source: SIMD4<Float> }

    package init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "glyph_vertex")
        d.fragmentFunction = library.makeFunction(name: "glyph_fragment")
        let att = d.colorAttachments[0]!
        att.pixelFormat = .rgba8Unorm
        // The target is cleared to transparent white and only its alpha is written: overlapping
        // glyph boxes keep the stronger coverage.
        att.writeMask = .alpha
        att.isBlendingEnabled = true
        att.alphaBlendOperation = .max
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .one
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    /// The text as a straight-alpha white RGBA texture, rendered into `commandBuffer`. Nil when a
    /// glyph is too large for the atlas (the caller draws on the CPU instead).
    package func render(_ layout: TextLayout, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard w > 0, h > 0 else { return nil }
        var instances: [Instance] = []
        // If the atlas fills up partway, it starts over, and the glyphs placed so far are gone:
        // place them all again in the new one.
        for _ in 0..<2 {
            let generation = atlasGeneration
            instances.removeAll(keepingCapacity: true)
            for g in layout.glyphs {
                guard let e = entry(for: g) else { return nil }
                guard e.width > 0 else { continue } // spaces
                // Whole-pixel positions keep the cached glyph images sharp.
                let x = (g.position.x + e.origin.x).rounded(), bottom = (g.position.y + e.origin.y).rounded()
                let top = CGFloat(h) - bottom - CGFloat(e.height)
                instances.append(Instance(destination: SIMD4(Float(x), Float(top), Float(e.width), Float(e.height)),
                                          source: SIMD4(Float(e.x), Float(e.y), Float(e.width), Float(e.height))))
            }
            if generation == atlasGeneration { break }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc), let atlas else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.label = "Text Image"
        if !instances.isEmpty {
            enc.setRenderPipelineState(pipeline)
            let length = MemoryLayout<Instance>.stride * instances.count
            if length <= 4096 {
                enc.setVertexBytes(instances, length: length, index: 0)
            } else if let buffer = device.makeBuffer(bytes: instances, length: length) {
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
            }
            var sizes = SIMD4<Float>(Float(w), Float(h), Float(Self.atlasSize), Float(Self.atlasSize))
            enc.setVertexBytes(&sizes, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.setFragmentTexture(atlas, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
        return target
    }

    /// The glyph's place in the atlas, rasterizing it on first use. Nil when it's too large.
    private func entry(for g: PlacedGlyph) -> Entry? {
        let key = "\(CTFontCopyPostScriptName(g.font))|\(CTFontGetSize(g.font))|\(g.glyph)"
        if let e = entries[key] { return e }
        var glyph = g.glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(g.font, .default, &glyph, &bounds, 1)
        if bounds.isEmpty {
            let e = Entry(x: 0, y: 0, width: 0, height: 0, origin: .zero)
            entries[key] = e
            return e
        }
        // One pixel of margin around the ink, aligned to whole pixels.
        let ox = floor(bounds.minX) - 1, oy = floor(bounds.minY) - 1
        let w = Int(ceil(bounds.maxX) + 1 - ox), h = Int(ceil(bounds.maxY) + 1 - oy)
        guard w <= Self.maxGlyph, h <= Self.maxGlyph else { return nil }
        guard let (x, y) = allocate(w, h) else { return nil }
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let atlas else { return nil }
        cg.setFillColor(gray: 1, alpha: 1)
        var position = CGPoint(x: -ox, y: -oy)
        CTFontDrawGlyphs(g.font, &glyph, &position, 1, cg)
        guard let data = cg.data else { return nil }
        atlas.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w)
        let e = Entry(x: x, y: y, width: w, height: h, origin: CGPoint(x: ox, y: oy))
        entries[key] = e
        return e
    }

    /// Shelf packing. When the atlas is full a new one is started (frames still on the GPU keep
    /// the old one alive), and glyphs are rasterized again as they are needed.
    private func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
        if atlas == nil { startAtlas() }
        if shelfX + w > Self.atlasSize { // next shelf
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + h > Self.atlasSize { startAtlas() } // full
        guard atlas != nil else { return nil }
        defer { shelfX += w; shelfHeight = max(shelfHeight, h) }
        return (shelfX, shelfY)
    }

    private func startAtlas() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.atlasSize,
                                                            height: Self.atlasSize, mipmapped: false)
        desc.usage = [.shaderRead]
        atlas = device.makeTexture(descriptor: desc)
        atlas?.label = "Glyph Atlas"
        atlasGeneration += 1
        entries.removeAll()
        shelfX = 0; shelfY = 0; shelfHeight = 0
    }
}
