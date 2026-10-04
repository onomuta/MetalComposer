import Metal
import XCTest
@testable import MetalComposer

final class SmoothTests: XCTestCase {
    private var resources: RenderResources!
    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// Feeds `value` for `seconds` at 60 fps and returns the last output.
    private func run(_ g: Graph, _ smooth: Patch, value: Double, seconds: Double, dt: Double = 1.0 / 60) -> Double {
        smooth.params["value"] = .number(value)
        var out = 0.0
        // Frame count from 60 fps, independent of dt (dt may be 0 or negative for paused / rewound time).
        for _ in 0..<max(1, Int((seconds * 60).rounded())) {
            let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!, time: 0,
                                  deltaTime: dt, viewportSize: CGSize(width: 8, height: 8), mouse: .zero, mouseDown: false)
            out = Evaluator(graph: g, context: ctx).outputs(of: smooth)["value"]!.number
        }
        return out
    }

    func testExponentialArrivesWithinDuration() {
        let g = Graph()
        let s = g.put(SmoothPatch.self, 0, 0, ["up": .number(1), "down": .number(0.25)])
        XCTAssertEqual(run(g, s, value: 0, seconds: 1.0 / 60), 0) // starts at its first input
        let half = run(g, s, value: 1, seconds: 0.5)
        XCTAssertTrue(half > 0.8 && half < 0.95, "still on its way after half the duration (\(half))")
        XCTAssertEqual(run(g, s, value: 1, seconds: 0.5), 1, accuracy: 0.01, "within ~1% after the duration")
        XCTAssertEqual(run(g, s, value: 0, seconds: 0.25), 0, accuracy: 0.01, "falls with the shorter decreasing duration")
    }

    func testLinearAndEaseCurves() {
        let g = Graph()
        let linear = g.put(SmoothPatch.self, 0, 0, ["up": .number(1), "curve": .number(1)])
        _ = run(g, linear, value: 0, seconds: 1.0 / 60)
        XCTAssertEqual(run(g, linear, value: 1, seconds: 0.5), 0.5, accuracy: 0.02, "constant speed: halfway at half time")
        XCTAssertEqual(run(g, linear, value: 1, seconds: 0.6), 1, accuracy: 1e-9, "arrives and stays")

        let ease = g.put(SmoothPatch.self, 0, 0, ["up": .number(1), "curve": .number(2)])
        _ = run(g, ease, value: 0, seconds: 1.0 / 60)
        let early = run(g, ease, value: 1, seconds: 0.2)
        XCTAssertLessThan(early, 0.2, "eases in")
    }

    func testHoldsWhenTimeStopsOrRewinds() {
        let g = Graph()
        let s = g.put(SmoothPatch.self, 0, 0, ["up": .number(1)])
        _ = run(g, s, value: 0, seconds: 1.0 / 60)
        let moving = run(g, s, value: 1, seconds: 0.2)
        XCTAssertEqual(run(g, s, value: 1, seconds: 1, dt: 0), moving, "paused: no change")
        XCTAssertEqual(run(g, s, value: 1, seconds: 1, dt: -0.1), moving, "rewound: holds")
    }
}
