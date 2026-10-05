import AppKit
import Metal
import XCTest
@testable import MetalComposerKit

final class TextImageTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func render(_ patch: TextImagePatch, font: String) -> MTLTexture? {
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = spec.defaultValue }
        inputs["text"] = .string("iiiiiiii")
        inputs["font"] = .string(font)
        return patch.evaluate(Inputs(values: inputs), ctx)["image"]?.image
    }

    func testUsesTheChosenFont() throws {
        // Courier is monospaced, so a row of "i" is much wider than in the system font.
        XCTAssertNotNil(NSFont(name: "Courier", size: 12), "Courier ships with macOS")
        let patch = TextImagePatch()
        let system = try XCTUnwrap(render(patch, font: ""))
        let courier = try XCTUnwrap(render(patch, font: "Courier"))
        XCTAssertGreaterThan(courier.width, system.width * 3 / 2)
        XCTAssertNil(patch.statusMessage)
    }

    func testMissingFontFallsBackToTheSystemFontAndSaysSo() throws {
        let patch = TextImagePatch()
        let system = try XCTUnwrap(render(patch, font: ""))
        let missing = try XCTUnwrap(render(patch, font: "NoSuchFont-Regular"))
        XCTAssertEqual(missing.width, system.width)
        XCTAssertTrue(patch.statusMessage?.contains("NoSuchFont-Regular") ?? false)
    }
}
