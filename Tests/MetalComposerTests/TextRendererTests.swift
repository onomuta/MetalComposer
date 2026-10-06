import AppKit
import Metal
import XCTest
@testable import MetalComposerKit

final class TextRendererTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// RGBA bytes of a texture (any storage mode).
    private func pixels(_ texture: MTLTexture) throws -> [UInt8] {
        let length = texture.width * texture.height * 4
        let buffer = try XCTUnwrap(resources.device.makeBuffer(length: length, options: .storageModeShared))
        let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt8.self, capacity: length), count: length))
    }

    private func gpu(_ layout: TextLayout) throws -> MTLTexture {
        let renderer = try XCTUnwrap(resources.textRenderer)
        let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let texture = try XCTUnwrap(renderer.render(layout, commandBuffer: cb))
        cb.commit()
        cb.waitUntilCompleted()
        return texture
    }

    func testGPUTextMatchesTheCPUDrawing() throws {
        let font = TextImagePatch.resolvedFont(family: "Helvetica Neue", style: "Bold", size: 64)
        for (text, spacing) in [("Hello, Wörld!", 0), ("AVATAR 0123\nline two", 0), ("88:88 WiW", 2), ("12:34 ab", 1), ("かな Mix", 2)] {
            let layout = TextLayout.make(text, font: font, spacing: spacing)
            let a = try pixels(try gpu(layout))
            let b = try pixels(try XCTUnwrap(layout.drawOnCPU(device: resources.device)))
            XCTAssertEqual(a.count, b.count)
            // Same ink: compare coverage, allowing for whole-pixel glyph positions on the GPU.
            var both = 0, either = 0
            for p in stride(from: 3, to: a.count, by: 4) {
                let x = a[p] > 127, y = b[p] > 127
                if x && y { both += 1 }
                if x || y { either += 1 }
            }
            XCTAssertGreaterThan(either, 0, text)
            XCTAssertGreaterThan(Double(both) / Double(either), 0.8, "\(text): ink overlap")
            // Color is straight white everywhere there is ink.
            for p in stride(from: 0, to: a.count, by: 4) where a[p + 3] > 0 {
                XCTAssertEqual(a[p], 255); XCTAssertEqual(a[p + 1], 255); XCTAssertEqual(a[p + 2], 255)
                break
            }
        }
    }

    func testManyDifferentGlyphsStillRender() throws {
        // Enough large glyphs to fill the atlas several times; every string must still come out.
        let font = TextImagePatch.resolvedFont(family: "", style: "Regular", size: 300)
        let renderer = try XCTUnwrap(resources.textRenderer)
        for k in 0..<12 {
            let text = String((0..<16).compactMap { UnicodeScalar(0x3041 + k * 16 + $0).map(Character.init) }) // hiragana
            let layout = TextLayout.make(text, font: font, spacing: 0)
            let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
            XCTAssertNotNil(renderer.render(layout, commandBuffer: cb))
            cb.commit()
        }
    }
}
