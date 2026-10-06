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

    func testWeightListsTheFamilysOwnStylesLightestFirst() throws {
        // Helvetica Neue ships with macOS. Its UltraLight is lighter than its Thin.
        let names = TextImagePatch.styles(of: "Helvetica Neue").filter { !$0.italic && $0.width == 0 }.map(\.name)
        XCTAssertEqual(Array(names.prefix(4)), ["UltraLight", "Thin", "Light", "Regular"])
        XCTAssertEqual(TextImagePatch.styles(of: "").map(\.name).first, "Ultralight")
        XCTAssertTrue(TextImagePatch.styles(of: "NoSuchFamily").isEmpty)
    }

    func testStylesResolveByNameThenByWeight() throws {
        func ps(_ family: String, _ style: String) -> String? { TextImagePatch.font(family: family, style: style, size: 12)?.fontName }
        XCTAssertEqual(ps("Helvetica Neue", "Light"), "HelveticaNeue-Light")
        XCTAssertEqual(ps("Helvetica Neue", "bold"), "HelveticaNeue-Bold", "names match regardless of case")
        XCTAssertEqual(ps("Helvetica Neue", "Bold Italic"), "HelveticaNeue-BoldItalic")
        // Missing styles fall back to the closest weight with the same slant at normal width.
        XCTAssertEqual(ps("Helvetica Neue", "ExtraBold"), "HelveticaNeue-Bold")
        XCTAssertEqual(ps("Helvetica Neue", "SemiBold"), "HelveticaNeue-Medium")
        XCTAssertEqual(ps("Courier", "Black"), "Courier-Bold")
        XCTAssertNil(ps("NoSuchFamily", "Regular"))
        XCTAssertTrue(try XCTUnwrap(TextImagePatch.font(family: TextImagePatch.systemMonospaced, style: "Regular", size: 12)).isFixedPitch)
    }

    func testUpgradesSettingsFromOlderVersions() {
        func upgraded(_ params: [String: Value]) -> [String: Value] {
            let record = NodeRecord(id: UUID(), type: "text-image", x: 0, y: 0, name: nil, params: params, subgraph: nil)
            return Graph.makePatch(record)!.params
        }
        // 0.6–0.8: a PostScript name.
        let courier = upgraded(["font": .string("Courier-Bold")])
        XCTAssertEqual(courier["font"]?.string, "Courier")
        XCTAssertEqual(courier["fontStyle"]?.string, "Bold")
        // Not installed: guessed from the name.
        let missing = upgraded(["font": .string("NoSuchFamily-ExtraBold")])
        XCTAssertEqual(missing["font"]?.string, "NoSuchFamily")
        XCTAssertEqual(missing["fontStyle"]?.string, "ExtraBold")
        // System font with the old Weight menu (Regular, Medium, Bold, Heavy, Monospaced).
        XCTAssertEqual(upgraded(["weight": .number(0)])["fontStyle"]?.string, "Regular")
        XCTAssertEqual(upgraded(["weight": .number(3)])["fontStyle"]?.string, "Heavy")
        let mono = upgraded(["weight": .number(4)])
        XCTAssertEqual(mono["font"]?.string, TextImagePatch.systemMonospaced)
        XCTAssertNil(mono["weight"])
        // Nothing set: the default (System Font, Bold) stays.
        XCTAssertEqual(upgraded([:])["fontStyle"]?.string, "Bold")
        XCTAssertEqual(upgraded([:])["font"]?.string, "")
        // New files are left alone.
        XCTAssertEqual(upgraded(["font": .string("Courier"), "fontStyle": .string("Regular")])["fontStyle"]?.string, "Regular")
    }
}

extension TextImageTests {
    /// Inside an Iterator one Text Image shows a different string on each pass; each string should
    /// be rendered once and then reused, not re-rendered every pass.
    func testReusesImagesForStringsItHasRendered() throws {
        let patch = TextImagePatch()
        let a1 = try XCTUnwrap(renderText(patch, "alpha")), b1 = try XCTUnwrap(renderText(patch, "beta"))
        let a2 = try XCTUnwrap(renderText(patch, "alpha")), b2 = try XCTUnwrap(renderText(patch, "beta"))
        XCTAssertTrue(a1 === a2)
        XCTAssertTrue(b1 === b2)
        XCTAssertFalse(a1 === b1)
    }

    private func renderText(_ patch: TextImagePatch, _ text: String) throws -> MTLTexture? {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = spec.defaultValue }
        inputs["text"] = .string(text)
        return patch.evaluate(Inputs(values: inputs), ctx)["image"]?.image
    }
}
