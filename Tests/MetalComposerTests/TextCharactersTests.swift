import Metal
import XCTest
@testable import MetalComposerKit

/// Text Characters: one character at a time, placed where Text Image would put it.
final class TextCharactersTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func run(_ patch: TextCharactersPatch, _ values: [String: Value]) -> [String: Value] {
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = (values[spec.key] ?? spec.defaultValue).coerced(to: spec.type) }
        return patch.evaluate(Inputs(values: inputs), ctx)
    }

    func testCharactersAndCount() {
        let patch = TextCharactersPatch()
        let chars = (0..<4).map { run(patch, ["text": .string("DJ あ"), "index": .number(Double($0))])["character"]!.string }
        XCTAssertEqual(chars, ["D", "J", " ", "あ"], "spaces and Japanese count as one character each")
        XCTAssertEqual(run(patch, ["text": .string("DJ あ")])["count"]?.number, 4)
        XCTAssertEqual(run(patch, ["text": .string("👍🏽!")])["count"]?.number, 2, "an emoji with a skin tone is one character")

        let past = run(patch, ["text": .string("DJ"), "index": .number(5)])
        XCTAssertEqual(past["character"]?.string, "")
        XCTAssertEqual(past["width"]?.number, 0)
        XCTAssertEqual(run(patch, ["text": .string("")])["count"]?.number, 0)
    }

    func testPositionsMatchTheWholeLine() throws {
        for spacing in 0...2 {
            let m = TextCharactersPatch.measure("WAVE 128", family: "", style: "Bold", spacing: spacing)
            XCTAssertEqual(m.characters.count, 8)
            // Left to right, symmetric about the middle of the line, and inside it.
            XCTAssertEqual(m.centers, m.centers.sorted(), "spacing \(spacing)")
            XCTAssertLessThan(m.centers[0], 0)
            XCTAssertGreaterThan(m.centers[7], 0)
            XCTAssertTrue(m.centers.allSatisfy { abs($0) < m.lineWidth / 2 })
            XCTAssertTrue(m.widths.allSatisfy { $0 > 0 })
        }
        // Monospaced puts every character in the same cell: equal gaps between centres.
        let mono = TextCharactersPatch.measure("Wil1", family: "", style: "Bold", spacing: 2)
        let gaps = zip(mono.centers.dropFirst(), mono.centers).map { $0 - $1 }
        XCTAssertEqual(gaps.max()! - gaps.min()!, 0, accuracy: 1e-9)
        // Proportional: a W is wider than an i.
        let prop = TextCharactersPatch.measure("Wi", family: "", style: "Bold", spacing: 0)
        XCTAssertGreaterThan(prop.widths[0], prop.widths[1])
    }

    func testUnitsAreTextHeightsAtAnySize() throws {
        // Width is the character's Text Image width over its height, whatever the font size.
        let m = TextCharactersPatch.measure("Mx", family: "", style: "Bold", spacing: 0)
        let font = TextImagePatch.resolvedFont(family: "", style: "Bold", size: 64)
        let image = TextLayout.make("M", font: font, spacing: 0).size
        XCTAssertEqual(m.widths[0], Double(image.width / image.height), accuracy: 0.03)
        let line = TextLayout.make("Mx", font: font, spacing: 0).size
        XCTAssertEqual(m.lineWidth, Double(line.width / line.height), accuracy: 0.03)
    }

    func testIsRegisteredAsAProcessor() {
        XCTAssertTrue(PatchRegistry.all.contains { $0 == TextCharactersPatch.self })
        XCTAssertEqual(TextCharactersPatch.category, .processor)
    }
}
