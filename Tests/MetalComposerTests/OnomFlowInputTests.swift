import Metal
import XCTest
@testable import MetalComposerKit

/// ONOM FLOW Input: the values ONOM FLOW passes in, in one patch.
final class OnomFlowInputTests: XCTestCase {
    private func engine() throws -> MetalComposerEngine {
        try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// A Clear inside a macro, colored by the patch's Main Color.
    private func mainColorInsideAMacro() throws -> Data {
        let g = Graph()
        let macro = g.put(MacroPatch.self, 0, 0)
        let input = macro.contents.put(OnomFlowInputPatch.self, 0, 0)
        let clear = macro.contents.put(ClearPatch.self, 200, 0)
        macro.contents.link(input, "mainColor", clear, "color")
        return try JSONEncoder().encode(g.record())
    }

    func testHostsSeeTheValuesOnlyWhenThePatchIsUsed() throws {
        let plain = Graph()
        plain.put(PublishedInputPatch.self, 0, 0, name: "Speed")
        let without = try CompositionPlayer(engine: engine(), data: JSONEncoder().encode(plain.record()))
        XCTAssertEqual(without.parameters.map(\.name), ["Speed"])

        let with = try CompositionPlayer(engine: engine(), data: mainColorInsideAMacro())
        XCTAssertEqual(with.parameters.map(\.name), [
            "BPM", "Beat", "Gain", "Input 1", "Input 2", "Input 3", "Input 4",
            "Text 1", "Text 2", "Image 1", "Image 2", "Main Color", "Sub Color",
        ], "the names ONOM FLOW sends, found even inside a macro")
        XCTAssertEqual(with.parameters.first { $0.name == "Text 1" }?.type, .string)
        XCTAssertEqual(with.parameters.first { $0.name == "Image 2" }?.type, .image)
        XCTAssertEqual(with.parameters.first { $0.name == "Main Color" }?.type, .color)
        XCTAssertTrue(with.parameters.allSatisfy { $0.range == nil })
    }

    func testValuesSetByTheHostReachThePatchInsideAMacro() throws {
        let engine = try engine()
        let player = try CompositionPlayer(engine: engine, data: mainColorInsideAMacro())
        XCTAssertEqual(Array(try PlayerFixtures.centerPixel(player, engine: engine).prefix(3)), [255, 255, 255], "white by default")
        let key = try XCTUnwrap(player.parameters.first { $0.name == "Main Color" }?.key)
        player.setValue(.color(SIMD4(1, 0, 0, 1)), forParameter: key)
        XCTAssertEqual(Array(try PlayerFixtures.centerPixel(player, engine: engine).prefix(3)), [255, 0, 0])
    }

    func testBeatFollowsTheBPMWithoutAHostAndTheHostWins() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let patch = OnomFlowInputPatch()
        var ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0.25, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        // 120 BPM: a beat every 0.5 s, so halfway through the first beat.
        XCTAssertEqual(patch.evaluate(Inputs(values: [:]), ctx)["beat"]?.number ?? -1, 0.5, accuracy: 1e-9)
        ctx.host["onom-flow.bpm"] = .number(60)
        XCTAssertEqual(patch.evaluate(Inputs(values: [:]), ctx)["beat"]?.number ?? -1, 0.25, accuracy: 1e-9)
        ctx.host["onom-flow.beat"] = .number(0.9)
        XCTAssertEqual(patch.evaluate(Inputs(values: [:]), ctx)["beat"]?.number ?? -1, 0.9, accuracy: 1e-9, "what the host sends")
    }

    func testDefaults() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 0, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        let out = OnomFlowInputPatch().evaluate(Inputs(values: [:]), ctx)
        XCTAssertEqual(out["bpm"]?.number, 120)
        XCTAssertEqual(out["gain"]?.number, 0)
        XCTAssertEqual(out["input4"]?.number, 0)
        XCTAssertEqual(out["text1"]?.string, "Text 1", "visible text, not an empty string")
        XCTAssertNil(out["image1"]?.image)
        XCTAssertEqual(out["subColor"]?.color, .one)
        XCTAssertEqual(Set(out.keys), Set(OnomFlowInputPatch.outputSpecs.map(\.key)))
    }
}
