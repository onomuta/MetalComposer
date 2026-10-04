import Metal
import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class CounterTests: XCTestCase {
    func testCountsRisingEdgesOnly() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let g = Graph()
        let counter = g.put(CounterPatch.self, 0, 0)
        func frame(up: Bool = false, down: Bool = false, reset: Bool = false) -> Double {
            counter.params["up"] = .bool(up)
            counter.params["down"] = .bool(down)
            counter.params["reset"] = .bool(reset)
            let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!, time: 0,
                                  deltaTime: 1.0 / 60, viewportSize: CGSize(width: 8, height: 8), mouse: .zero, mouseDown: false)
            return Evaluator(graph: g, context: ctx).outputs(of: counter)["count"]!.number
        }
        XCTAssertEqual(frame(up: true), 1)
        XCTAssertEqual(frame(up: true), 1, "holding the signal counts once")
        XCTAssertEqual(frame(), 1)
        XCTAssertEqual(frame(up: true), 2)
        XCTAssertEqual(frame(), 2)
        XCTAssertEqual(frame(down: true), 1)
        XCTAssertEqual(frame(down: true), 1)
        XCTAssertEqual(frame(reset: true), 0)
        XCTAssertEqual(frame(up: true, reset: true), 0, "reset held: no counting")
        XCTAssertEqual(frame(up: true), 0, "up was already on, so no new edge")
        XCTAssertEqual(frame(), 0)
        XCTAssertEqual(frame(up: true), 1)
        counter.restart()
        XCTAssertEqual(frame(), 0, "playback restart clears the count")
    }
}
