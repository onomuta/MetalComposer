import XCTest
@testable import MetalComposer

final class GraphTests: XCTestCase {
    private func roundTrip(_ graph: Graph) throws -> Graph {
        let data = try JSONEncoder().encode(graph.record())
        let copy = Graph()
        copy.load(try JSONDecoder().decode(GraphRecord.self, from: data))
        return copy
    }

    func testDemosSurviveSaveAndLoad() throws {
        for demo in Demo.allCases {
            let g = Graph()
            demo.build(into: g)
            let copy = try roundTrip(g)
            XCTAssertEqual(copy.nodes.map(\.typeID), g.nodes.map(\.typeID), demo.rawValue)
            XCTAssertEqual(Set(copy.connections), Set(g.connections), demo.rawValue)
            for (a, b) in zip(g.nodes, copy.nodes) {
                XCTAssertEqual(a.inputPorts.map(\.key), b.inputPorts.map(\.key), "\(demo.rawValue) \(a.title)")
                XCTAssertEqual(a.subgraph?.nodes.count, b.subgraph?.nodes.count)
                XCTAssertEqual(a.subgraph?.connections.count, b.subgraph?.connections.count)
            }
        }
    }

    func testFeedbackDemoHasSelfLoopOnPublishedPort() {
        let g = Graph()
        Demo.feedback.build(into: g)
        let rim = g.nodes.compactMap { $0 as? RenderInImagePatch }.first!
        XCTAssertTrue(g.connections.contains { $0.from.node == rim.id && $0.to.node == rim.id })
        XCTAssertEqual(rim.category, .processor)
    }

    func testGroupIntoMacroPreservesDataflow() {
        let c = Composition()
        let g = c.root
        let num = g.put(NumberPatch.self, 0, 0, ["value": .number(2)])
        let math = g.put(MathPatch.self, 200, 0, ["op": .number(2), "b": .number(5)]) // 2 * 5
        let out = g.put(NumberPatch.self, 400, 0)
        g.link(num, "value", math, "a")
        g.link(math, "result", out, "value")

        c.selection = [math.id]
        c.groupSelectionIntoMacro()

        let macro = g.nodes.compactMap { $0 as? MacroPatch }.first!
        XCTAssertEqual(macro.publishedInputs.count, 1)
        XCTAssertEqual(macro.publishedOutputs.count, 1)
        XCTAssertEqual(g.connections.count, 2)
        XCTAssertEqual(macro.contents.connections.count, 2)
        XCTAssertEqual(g.nodes.count, 3)
    }

    func testPasteGivesFreshIDsAndKeepsInternalWires() throws {
        let src = Graph()
        let a = src.put(LFOPatch.self, 0, 0)
        let b = src.put(SmoothPatch.self, 200, 0)
        src.link(a, "value", b, "value")
        let c = Composition()
        c.root.load(src.record())
        c.selectAll()
        c.duplicateSelection()
        XCTAssertEqual(c.root.nodes.count, 4)
        XCTAssertEqual(Set(c.root.nodes.map(\.id)).count, 4)
        XCTAssertEqual(c.root.connections.count, 2)
        XCTAssertEqual(c.selection.count, 2)
    }

    func testMathExpression() throws {
        XCTAssertEqual(try MathExpression("1 + 2 * 3").evaluate([:]), 7)
        XCTAssertEqual(try MathExpression("-2 ^ 2").evaluate([:]), -4)
        XCTAssertEqual(try MathExpression("max(a, b) + clamp(5, 0, 1)").evaluate(["a": 3, "b": 4]), 5)
        XCTAssertThrowsError(try MathExpression("foo(1)"))
        XCTAssertThrowsError(try MathExpression("1 +"))
    }
}
