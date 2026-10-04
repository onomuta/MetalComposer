import Metal
import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class MultiplexerTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func evaluator(_ g: Graph) -> Evaluator {
        Evaluator(graph: g, context: EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                                                 time: 0, deltaTime: 0, viewportSize: CGSize(width: 64, height: 64),
                                                 mouse: .zero, mouseDown: false))
    }

    func testMultiplexerSelectsAndClampsIndex() {
        let g = Graph()
        let a = g.put(NumberPatch.self, 0, 0, ["value": .number(10)])
        let b = g.put(NumberPatch.self, 0, 100, ["value": .number(20)])
        let mux = g.put(MultiplexerPatch.self, 200, 0)
        g.link(a, "value", mux, "i0")
        g.link(b, "value", mux, "i1")
        for (index, expected) in [(0.0, 10.0), (1, 20), (9, 20), (-3, 10)] {
            mux.params["index"] = .number(index)
            XCTAssertEqual(evaluator(g).outputs(of: mux)["output"]?.number, expected, "index \(index)")
        }
    }

    func testPortCountAndTypeFollowSettings() {
        let mux = MultiplexerPatch()
        mux.params["count"] = .number(4)
        mux.params["type"] = .number(Double(PortType.allCases.firstIndex(of: .color)!))
        let sources = mux.inputPorts.filter { $0.key.hasPrefix("i") && $0.key != "index" }
        XCTAssertEqual(sources.map(\.name), ["Source 0", "Source 1", "Source 2", "Source 3"])
        XCTAssertTrue(sources.allSatisfy { $0.type == .color })
        XCTAssertEqual(mux.outputPorts.first?.type, .color)

        let demux = DemultiplexerPatch()
        demux.params["count"] = .number(3)
        XCTAssertEqual(demux.outputPorts.map(\.key), ["o0", "o1", "o2"])
        XCTAssertEqual(demux.outputPorts.first?.type, .any)
    }

    func testDemultiplexerRoutesAndHandlesInactiveOutputs() {
        let g = Graph()
        let src = g.put(NumberPatch.self, 0, 0, ["value": .number(5)])
        let demux = g.put(DemultiplexerPatch.self, 200, 0)
        g.link(src, "value", demux, "input")

        var out = evaluator(g).outputs(of: demux)
        XCTAssertEqual(out["o0"]?.number, 5)
        XCTAssertEqual(out["o1"]?.number, 0)

        // Switch to output 1 with a new value: output 0 keeps the last value it got.
        demux.params["index"] = .number(1)
        src.params["value"] = .number(8)
        out = evaluator(g).outputs(of: demux)
        XCTAssertEqual(out["o0"]?.number, 5)
        XCTAssertEqual(out["o1"]?.number, 8)

        demux.params["inactive"] = .number(1) // Reset to Default
        out = evaluator(g).outputs(of: demux)
        XCTAssertEqual(out["o0"]?.number, 0)
        XCTAssertEqual(out["o1"]?.number, 8)
    }
}
