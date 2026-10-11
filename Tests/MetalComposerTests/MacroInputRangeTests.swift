import Metal
import XCTest
@testable import MetalComposerKit

/// Macro Input's Minimum / Maximum.
final class MacroInputRangeTests: XCTestCase {
    func testRangeIsOffUntilLimitRangeIsOn() {
        let input = PublishedInputPatch()
        XCTAssertNil(input.valueRange)
        XCTAssertNil(input.publishedSpec.range)
        XCTAssertFalse(input.showsSetting("min"))
        XCTAssertTrue(input.allInputs.contains { $0.key == "limitRange" })

        input.params["limitRange"] = .bool(true)
        input.params["min"] = .number(-2)
        input.params["max"] = .number(5)
        XCTAssertEqual(input.valueRange, -2...5)
        XCTAssertTrue(input.showsSetting("max"))
        XCTAssertEqual(input.publishedSpec.range, -2...5, "the macro's slider spans it")
        XCTAssertEqual(input.publishedSpec.limits, -2...5)
        XCTAssertEqual(input.allInputs.first { $0.key == "default" }?.limits, -2...5)

        // Minimum and Maximum entered the other way round still make a range.
        input.params["min"] = .number(5)
        input.params["max"] = .number(-2)
        XCTAssertEqual(input.valueRange, -2...5)
    }

    func testOnlyNumbersHaveARange() {
        let input = PublishedInputPatch()
        input.portType = .color
        input.params["limitRange"] = .bool(true)
        XCTAssertNil(input.valueRange)
        XCTAssertFalse(input.allInputs.contains { $0.key == "min" })
        XCTAssertEqual(input.clamped(.color(SIMD4(2, 2, 2, 1))).color, SIMD4(2, 2, 2, 1))
    }

    func testValuesAreKeptInRangeWhereverTheyComeFrom() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let input = PublishedInputPatch()
        input.params["limitRange"] = .bool(true)
        input.params["min"] = .number(0)
        input.params["max"] = .number(10)
        input.params["default"] = .number(50)
        XCTAssertEqual(input.defaultValue.number, 10, "the default")

        var ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        ctx.published[input.portKey] = .number(-3) // connected outside the macro, or set by a host
        XCTAssertEqual(input.evaluate(Inputs(values: [:]), ctx)["value"]?.number, 0)
        ctx.published[input.portKey] = .number(4)
        XCTAssertEqual(input.evaluate(Inputs(values: [:]), ctx)["value"]?.number, 4)
    }

    func testHostsSeeTheRange() throws {
        let g = Graph()
        g.put(PublishedInputPatch.self, 0, 0, ["limitRange": .bool(true), "min": .number(20), "max": .number(80),
                                                "default": .number(40)], name: "Speed")
        g.put(PublishedInputPatch.self, 0, 100, name: "Free")
        let engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let player = try CompositionPlayer(engine: engine, data: try JSONEncoder().encode(g.record()))
        XCTAssertEqual(player.parameters.map(\.name), ["Speed", "Free"])
        XCTAssertEqual(player.parameters[0].range, 20...80)
        XCTAssertNil(player.parameters[1].range)
    }
}
