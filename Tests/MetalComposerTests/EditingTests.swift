import XCTest
@testable import MetalComposer

final class EditingTests: XCTestCase {
    private func wire(_ g: Graph, _ a: Patch, _ out: String, _ b: Patch, _ inp: String) -> Bool {
        g.connections.contains { $0.from == PortRef(node: a.id, port: out) && $0.to == PortRef(node: b.id, port: inp) }
    }

    func testExplodeUndoesGroup() {
        let c = Composition()
        let g = c.root
        let num = g.put(NumberPatch.self, 0, 0, ["value": .number(2)])
        let math = g.put(MathPatch.self, 200, 0, ["op": .number(2), "b": .number(5)])
        let smooth = g.put(SmoothPatch.self, 400, 0)
        let out = g.put(NumberPatch.self, 600, 0)
        g.link(num, "value", math, "a")
        g.link(math, "result", smooth, "value")
        g.link(smooth, "value", out, "value")

        c.selection = [math.id, smooth.id]
        c.groupSelectionIntoMacro()
        let macro = g.nodes.first { $0 is MacroPatch }!
        c.explodeMacro(macro)

        XCTAssertFalse(g.nodes.contains { $0 is MacroPatch || $0 is PublishedPortPatch })
        XCTAssertEqual(Set(g.nodes.map(\.id)), [num.id, math.id, smooth.id, out.id])
        XCTAssertEqual(g.connections.count, 3)
        XCTAssertTrue(wire(g, num, "value", math, "a"))
        XCTAssertTrue(wire(g, math, "result", smooth, "value"))
        XCTAssertTrue(wire(g, smooth, "value", out, "value"))
        XCTAssertEqual(c.selection, [math.id, smooth.id])
    }

    func testExplodeKeepsMacroInputValuesAndPassThroughs() {
        let c = Composition()
        let g = c.root
        let macro = g.put(MacroPatch.self, 0, 0)
        let input = macro.contents.put(PublishedInputPatch.self, 0, 0, name: "Gain")
        let output = macro.contents.put(PublishedOutputPatch.self, 400, 0, name: "Out")
        let math = macro.contents.put(MathPatch.self, 200, 0)
        macro.contents.link(input, "value", math, "b")   // unconnected outside: its value moves onto math.b
        macro.contents.link(input, "value", output, "value") // pass-through
        macro.params[input.portKey] = .number(7)
        let src = g.put(NumberPatch.self, -300, 0)
        let dst = g.put(NumberPatch.self, 300, 0)
        g.link(src, "value", macro, input.portKey)
        g.link(macro, output.portKey, dst, "value")

        // With the outer source connected, the pass-through becomes a direct wire.
        c.selection = [macro.id]
        c.explodeMacro(macro)
        XCTAssertTrue(wire(g, src, "value", math, "b"))
        XCTAssertTrue(wire(g, src, "value", dst, "value"))
    }

    func testExplodeUsesMacroValueWhenInputIsUnconnected() {
        let c = Composition()
        let g = c.root
        let macro = g.put(MacroPatch.self, 0, 0)
        let input = macro.contents.put(PublishedInputPatch.self, 0, 0)
        let math = macro.contents.put(MathPatch.self, 200, 0)
        macro.contents.link(input, "value", math, "b")
        macro.params[input.portKey] = .number(7)
        c.explodeMacro(macro)
        XCTAssertEqual(math.params["b"]?.number, 7)
        XCTAssertTrue(g.connections.isEmpty)
    }

    func testOnlyPlainMacrosExplode() {
        let c = Composition()
        XCTAssertTrue(c.canExplode(MacroPatch()))
        XCTAssertFalse(c.canExplode(IteratorPatch()))
        XCTAssertFalse(c.canExplode(RenderInImagePatch()))
        XCTAssertFalse(c.canExplode(Transform3DPatch()))
    }

    func testCommentsSaveAndNeverRender() throws {
        let g = Graph()
        let note = g.put(CommentPatch.self, 10, 20, ["text": .string("hello"), "width": .number(300), "color": .number(2)])
        XCTAssertTrue(note.inputPorts.isEmpty)
        XCTAssertTrue(note.outputPorts.isEmpty)
        XCTAssertTrue(g.consumers.isEmpty)
        let copy = Graph()
        copy.load(try JSONDecoder().decode(GraphRecord.self, from: JSONEncoder().encode(g.record())))
        let loaded = try XCTUnwrap(copy.nodes.first as? CommentPatch)
        XCTAssertEqual(loaded.text, "hello")
        XCTAssertEqual(loaded.size.width, 300)
    }
}
