import AppKit
import Metal
import XCTest
@testable import MetalComposerKit

final class ImagePresetTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// The preset image's alpha channel, row by row from the top.
    private func alpha(preset: String, thickness: Double = 0.15, glow: Double = 0, glowIntensity: Double = 0.6) throws -> [UInt8] {
        let importer = ImageImporterPatch()
        let index = try XCTUnwrap(ImageImporterPatch.presets.firstIndex(of: preset))
        let cb = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let ctx = EvalContext(resources: resources, commandBuffer: cb, time: 0, deltaTime: 0,
                              viewportSize: CGSize(width: 16, height: 16), mouse: .zero, mouseDown: false)
        let out = importer.evaluate(Inputs(values: ["preset": .number(Double(index)), "thickness": .number(thickness),
                                                    "glow": .number(glow), "glowIntensity": .number(glowIntensity)]), ctx)
        let texture = try XCTUnwrap(out["image"]?.image)
        let size = ImageImporterPatch.presetSize
        XCTAssertEqual(texture.width, size)
        let buffer = try XCTUnwrap(resources.device.makeBuffer(length: size * size * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: size * size * 4)
        return (0..<size * size).map { bytes[$0 * 4 + 3] }
    }

    private func at(_ a: [UInt8], _ x: Double, _ y: Double) -> UInt8 {
        let size = ImageImporterPatch.presetSize
        return a[min(size - 1, Int(y * Double(size))) * size + min(size - 1, Int(x * Double(size)))]
    }

    func testShapesFillTheirArea() throws {
        let circle = try alpha(preset: "Circle")
        XCTAssertEqual(at(circle, 0.5, 0.5), 255)
        XCTAssertEqual(at(circle, 0.02, 0.02), 0)   // corner, outside the circle

        let ring = try alpha(preset: "Ring")
        XCTAssertEqual(at(ring, 0.5, 0.5), 0)       // hollow
        XCTAssertEqual(at(ring, 0.5, 0.02), 255)    // on the ring

        let square = try alpha(preset: "Square")
        XCTAssertEqual(at(square, 0.02, 0.02), 255)

        // The triangle points up: its top center is filled, the top corners are not.
        let triangle = try alpha(preset: "Triangle")
        XCTAssertEqual(at(triangle, 0.5, 0.2), 255)
        XCTAssertEqual(at(triangle, 0.1, 0.2), 0)
        XCTAssertEqual(at(triangle, 0.2, 0.8), 255)
    }

    func testGlowSurroundsTheShape() throws {
        let plain = try alpha(preset: "Circle")
        let glowing = try alpha(preset: "Circle", glow: 0.5)
        XCTAssertEqual(at(glowing, 0.5, 0.5), 255)
        // Just outside the (now smaller) circle the glow is visible, fading to nothing at the edge.
        XCTAssertGreaterThan(at(glowing, 0.5, 0.12), 20)
        XCTAssertEqual(at(glowing, 0.5, 0.0), 0)
        XCTAssertEqual(at(plain, 0.5, 0.0), 255)  // without glow the circle reaches the edge
    }

    func testFileModeIsTheDefault() {
        XCTAssertEqual(ImageImporterPatch.presets.first, "File")
        XCTAssertEqual(ImageImporterPatch().params["preset"]?.number, 0)
    }

    func testInspectorShowsOnlyTheSettingsOfTheChosenImage() {
        let importer = ImageImporterPatch()
        XCTAssertTrue(importer.showsSetting("path"))
        XCTAssertFalse(importer.showsSetting("glow"))

        importer.params["preset"] = .number(Double(ImageImporterPatch.presets.firstIndex(of: "Circle")!))
        XCTAssertFalse(importer.showsSetting("path"))
        XCTAssertFalse(importer.showsSetting("embed"))
        XCTAssertFalse(importer.showsSetting("thickness"))  // a filled circle has no line width
        XCTAssertTrue(importer.showsSetting("glow"))
        XCTAssertFalse(importer.showsSetting("glowIntensity"))
        importer.params["glow"] = .number(0.5)
        XCTAssertTrue(importer.showsSetting("glowIntensity"))

        importer.params["preset"] = .number(Double(ImageImporterPatch.presets.firstIndex(of: "Ring")!))
        XCTAssertTrue(importer.showsSetting("thickness"))
    }

    /// Writes all presets, with and without glow, to MC_PRESET_SHEET (a PNG path) for a visual check.
    func testWritesContactSheetWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["MC_PRESET_SHEET"] else { throw XCTSkip("MC_PRESET_SHEET not set") }
        let presets = Array(ImageImporterPatch.presets.dropFirst())
        let size = ImageImporterPatch.presetSize, cell = size / 2
        let ctx = CGContext(data: nil, width: cell * presets.count, height: cell * 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, preset) in presets.enumerated() {
            for (row, glow) in [0.0, 0.6].enumerated() {
                let a = try alpha(preset: preset, glow: glow)
                let gray = CGColorSpaceCreateDeviceGray()
                let mask = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: gray,
                                   bitmapInfo: CGBitmapInfo(), provider: CGDataProvider(data: Data(a) as CFData)!,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                ctx.saveGState()
                let rect = CGRect(x: column * cell, y: (1 - row) * cell, width: cell, height: cell)
                ctx.clip(to: rect, mask: mask)
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
                ctx.restoreGState()
            }
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
