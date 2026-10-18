import Metal
import XCTest
@testable import MetalComposerKit

final class ImageEffectTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// A 64×64 straight-alpha image from a function of the pixel.
    private func image(_ pixel: (Int, Int) -> [UInt8]) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: desc))
        var bytes: [UInt8] = []
        for y in 0..<64 { for x in 0..<64 { bytes += pixel(x, y) } }
        texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 64 * 4)
        return texture
    }

    private func run(_ patch: Patch, _ values: [String: Value]) throws -> (texture: MTLTexture, read: (Int, Int) -> [UInt8]) {
        let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let ctx = EvalContext(resources: resources, commandBuffer: cb, time: 0, deltaTime: 1.0 / 60,
                              viewportSize: CGSize(width: 64, height: 64), mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = values[spec.key] ?? spec.defaultValue }
        let out = try XCTUnwrap(patch.evaluate(Inputs(values: inputs), ctx)["image"]?.image)
        let buffer = try XCTUnwrap(resources.device.makeBuffer(length: out.width * out.height * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: out, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: out.width, height: out.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: out.width * 4, destinationBytesPerImage: out.width * out.height * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let px = buffer.contents().bindMemory(to: UInt8.self, capacity: out.width * out.height * 4)
        let width = out.width
        return (out, { x, y in (0..<4).map { px[(y * width + x) * 4 + $0] } })
    }

    func testOutlineSurroundsTheShape() throws {
        // A green square from 24 to 39 on a transparent background.
        let square = try image { x, y in (24...39).contains(x) && (24...39).contains(y) ? [0, 255, 0, 255] : [0, 0, 0, 0] }
        let (out, read) = try run(OutlinePatch(), ["image": .image(square), "color": .color(SIMD4(1, 0, 0, 1)), "width": .number(4),
                                                    "grow": .bool(false)])
        XCTAssertEqual(out.width, 64, "Grow Image off keeps the size")
        XCTAssertEqual(read(32, 32), [0, 255, 0, 255], "the image stays on top")
        XCTAssertEqual(read(21, 32), [255, 0, 0, 255], "3 px outside: outline")
        XCTAssertEqual(read(20, 32), [255, 0, 0, 255], "4 px outside: outline")
        XCTAssertEqual(read(19, 32)[3], 0, "5 px outside: nothing")
        XCTAssertEqual(read(41, 41)[3], 255, "round corner: 2√2 ≈ 2.8 px away is covered")
        XCTAssertTrue((1...254).contains(read(42, 42)[3]), "3√2 ≈ 4.2 px away is on the soft outer edge")
        XCTAssertEqual(read(45, 45)[3], 0, "corner further than the width")

        let ring = try run(OutlinePatch(), ["image": .image(square), "width": .number(4), "outlineOnly": .bool(true),
                                            "grow": .bool(false)]).read
        XCTAssertEqual(ring(32, 32)[3], 0, "Outline Only leaves out the image")
        XCTAssertEqual(ring(21, 32), [255, 255, 255, 255])
    }

    func testOutlineGrowsTheImageSoItIsNotCutOff() throws {
        // A shape touching the left edge: without growing, the outline on that side would be lost.
        let edge = try image { x, _ in x < 16 ? [0, 0, 255, 255] : [0, 0, 0, 0] }
        let (out, read) = try run(OutlinePatch(), ["image": .image(edge), "color": .color(SIMD4(1, 1, 0, 1)), "width": .number(6)])
        XCTAssertEqual(out.width, 64 + 2 * 7, "grows by the width (rounded up) + 1 on each side")
        XCTAssertEqual(out.height, 64 + 2 * 7)
        XCTAssertEqual(read(3, 40), [255, 255, 0, 255], "the outline beyond the original left edge")
        XCTAssertEqual(read(7 + 8, 40), [0, 0, 255, 255], "the image, shifted by the margin")
    }

    func testTileRepeatsAndMirrors() throws {
        let halves = try image { x, _ in x < 32 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let plain = try run(TilePatch(), ["image": .image(halves), "columns": .number(2), "rows": .number(1)]).read
        // Two tiles across: red, blue, red, blue in quarters.
        XCTAssertEqual([plain(8, 10), plain(24, 10), plain(40, 10), plain(56, 10)].map { $0[0] > 127 }, [true, false, true, false])

        let mirrored = try run(TilePatch(), ["image": .image(halves), "columns": .number(2), "rows": .number(1),
                                              "mirror": .bool(true)]).read
        // The second tile is flipped: red, blue | blue, red.
        XCTAssertEqual([mirrored(8, 10), mirrored(24, 10), mirrored(40, 10), mirrored(56, 10)].map { $0[0] > 127 }, [true, false, false, true])

        let shifted = try run(TilePatch(), ["image": .image(halves), "columns": .number(1), "rows": .number(1),
                                             "offsetX": .number(0.5)]).read
        XCTAssertLessThan(shifted(8, 10)[0], 128, "half a tile offset puts the blue half first")
    }

    func testEachIteratorPassKeepsItsOwnImage() throws {
        let square = try image { _, _ in [255, 255, 255, 255] }
        let patch = OutlinePatch()
        let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
        var images: [MTLTexture] = []
        for index in 0..<3 {
            let ctx = EvalContext(resources: resources, commandBuffer: cb, time: 0, deltaTime: 1.0 / 60,
                                  viewportSize: CGSize(width: 64, height: 64), mouse: .zero, mouseDown: false,
                                  iteration: (index, 3))
            var inputs: [String: Value] = [:]
            for spec in patch.allInputs { inputs[spec.key] = spec.defaultValue }
            inputs["image"] = .image(square)
            images.append(try XCTUnwrap(patch.evaluate(Inputs(values: inputs), ctx)["image"]?.image))
        }
        cb.commit()
        XCTAssertEqual(Set(images.map { ObjectIdentifier($0) }).count, 3)
    }
}
