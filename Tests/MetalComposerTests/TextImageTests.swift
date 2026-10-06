import AppKit
import Metal
import XCTest
@testable import MetalComposerKit

final class TextImageTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func render(_ patch: TextImagePatch, font: String, text: String = "iiiiiiii", spacing: Int = 0) -> MTLTexture? {
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = spec.defaultValue }
        inputs["text"] = .string(text)
        inputs["font"] = .string(font)
        inputs["spacing"] = .number(Double(spacing))
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

    func testMonospacedKeepsTheWidthWhateverTheCharacters() throws {
        let patch = TextImagePatch()
        func width(_ text: String, _ spacing: Int, font: String = "") throws -> Int {
            try XCTUnwrap(render(patch, font: font, text: text, spacing: spacing)).width
        }
        XCTAssertLessThan(try width("iiii", 0), try width("WWWW", 0), "proportional: i is narrower than W")
        XCTAssertEqual(try width("iiii", 2), try width("WWWW", 2))
        XCTAssertEqual(try width("iiii", 2, font: "Courier"), try width("WWWW", 2, font: "Courier"))
        // Monospaced Digits: digits share a width, letters keep theirs.
        XCTAssertEqual(try width("1111", 1), try width("8888", 1))
        XCTAssertLessThan(try width("iiii", 1), try width("WWWW", 1))
        // Lines stack: two lines are taller than one.
        let one = try XCTUnwrap(render(patch, font: "", text: "AB", spacing: 2))
        let two = try XCTUnwrap(render(patch, font: "", text: "AB\nCD", spacing: 2))
        XCTAssertEqual(one.width, two.width)
        XCTAssertGreaterThan(two.height, one.height * 3 / 2)
    }
}
