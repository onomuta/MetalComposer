import Metal
import XCTest
@testable import MetalComposerKit

final class RandomStringTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func run(_ values: [String: Value], time: Double = 0) -> String {
        let patch = RandomStringPatch()
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: time, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = (values[spec.key] ?? spec.defaultValue).coerced(to: spec.type) }
        return patch.evaluate(Inputs(values: inputs), ctx)["string"]!.string
    }

    func testLengthAndSeed() {
        let a = run(["length": .number(12), "seed": .number(1)])
        XCTAssertEqual(a.count, 12)
        XCTAssertEqual(run(["length": .number(12), "seed": .number(1)]), a, "same seed, same string")
        XCTAssertNotEqual(run(["length": .number(12), "seed": .number(2)]), a)
        XCTAssertEqual(run(["length": .number(0)]), "")
    }

    func testCharacterSets() {
        let upper = run(["length": .number(200), "lowercase": .bool(false), "digits": .bool(false)])
        XCTAssertTrue(upper.allSatisfy { $0.isUppercase && $0.isASCII })
        let digits = run(["length": .number(200), "uppercase": .bool(false), "lowercase": .bool(false)])
        XCTAssertTrue(digits.allSatisfy(\.isNumber))
        let symbols = run(["length": .number(200), "uppercase": .bool(false), "lowercase": .bool(false),
                           "digits": .bool(false), "symbols": .bool(true)])
        XCTAssertTrue(symbols.allSatisfy { RandomStringPatch.symbols.contains($0) })
        let extra = run(["length": .number(50), "uppercase": .bool(false), "lowercase": .bool(false),
                         "digits": .bool(false), "extra": .string("あい")])
        XCTAssertTrue(extra.allSatisfy { "あい".contains($0) })
        XCTAssertEqual(run(["uppercase": .bool(false), "lowercase": .bool(false), "digits": .bool(false)]), "")
    }

    func testChangesOverTimeAndRewinds() {
        let fixed = ["rate": Value.number(0)]
        XCTAssertEqual(run(fixed, time: 0), run(fixed, time: 5), "Changes / sec 0 keeps one string")
        let twice = ["rate": Value.number(2)]
        XCTAssertEqual(run(twice, time: 0.1), run(twice, time: 0.4), "same half second, same string")
        XCTAssertNotEqual(run(twice, time: 0.1), run(twice, time: 0.6))
        XCTAssertEqual(run(twice, time: 3.2), run(twice, time: 3.2), "going back in time gives the same string")
        XCTAssertEqual(run(["rate": .number(.infinity)], time: 1).count, 8, "bad input doesn't crash")
    }
}
