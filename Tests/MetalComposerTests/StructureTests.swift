import Metal
import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class StructureTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        resources = try RenderResources(device: device)
    }

    private func context(_ commandBuffer: MTLCommandBuffer? = nil) -> EvalContext {
        EvalContext(resources: resources, commandBuffer: commandBuffer ?? resources.queue.makeCommandBuffer()!,
                    time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                    mouse: .zero, mouseDown: false)
    }

    private func run(_ patch: Patch, _ values: [String: Value], ctx: EvalContext? = nil) -> [String: Value] {
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = (values[spec.key] ?? patch.params[spec.key] ?? spec.defaultValue).coerced(to: spec.type) }
        return patch.evaluate(Inputs(values: inputs), ctx ?? context())
    }

    func testMakerUsesKeysAndCount() {
        let maker = StructureMakerPatch()
        maker.params["count"] = .number(3)
        maker.params["keys"] = .string("x, , label")
        XCTAssertEqual(maker.inputPorts.map(\.name), ["x", "Member 2", "label"])
        let s = run(maker, ["m0": .number(1), "m1": .string("two"), "m2": .bool(true)])["structure"]!.structure
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.value(forKey: "x")?.number, 1)
        XCTAssertEqual(s.value(at: 1)?.string, "two")
        XCTAssertNil(s.members[1].key)
        XCTAssertEqual(s.value(forKey: "label")?.bool, true)
    }

    func testMembersAndCount() {
        let s = Value.structure(Structure(members: [.init(key: "a", value: .number(10)), .init(key: "b", value: .number(20))]))
        XCTAssertEqual(run(StructureIndexMemberPatch(), ["structure": s, "index": .number(1)])["member"]?.number, 20)
        XCTAssertNil(run(StructureIndexMemberPatch(), ["structure": s, "index": .number(5)])["member"])
        XCTAssertEqual(run(StructureKeyMemberPatch(), ["structure": s, "key": .string("a")])["member"]?.number, 10)
        XCTAssertNil(run(StructureKeyMemberPatch(), ["structure": s, "key": .string("zzz")])["member"])
        XCTAssertEqual(run(StructureCountPatch(), ["structure": s])["count"]?.number, 2)
        // A plain value connected to a structure input acts as a one-member structure.
        XCTAssertEqual(run(StructureCountPatch(), ["structure": .number(7)])["count"]?.number, 1)
    }

    func testQueueSizeOrderChangesAndReset() {
        let queue = QueuePatch()
        func push(_ v: Double, _ extra: [String: Value] = [:]) -> [Double] {
            var values: [String: Value] = ["value": .number(v), "size": .number(3)]
            values.merge(extra) { $1 }
            return run(queue, values)["queue"]!.structure.members.map(\.value.number)
        }
        _ = push(1); _ = push(2); _ = push(3)
        XCTAssertEqual(push(4), [2, 3, 4], "oldest drops off past Size")
        XCTAssertEqual(push(5, ["order": .number(1)]), [5, 4, 3], "newest first")
        XCTAssertEqual(push(6, ["filling": .bool(false)]), [3, 4, 5], "not filling: nothing added")
        XCTAssertEqual(push(5, ["add": .number(1)]), [3, 4, 5], "when changed: same value is skipped")
        XCTAssertEqual(push(7, ["add": .number(1)]), [4, 5, 7])
        XCTAssertEqual(push(8, ["reset": .bool(true)]), [])
    }

    func testQueueCopiesImagesSoEntriesKeepTheirFrame() throws {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let source = try XCTUnwrap(resources.device.makeTexture(descriptor: desc))
        let queue = QueuePatch()
        let cb = resources.queue.makeCommandBuffer()!
        let ctx = context(cb)
        _ = run(queue, ["value": .image(source)], ctx: ctx)
        let out = run(queue, ["value": .image(source)], ctx: ctx)["queue"]!.structure
        cb.commit()
        cb.waitUntilCompleted()
        let images = out.members.compactMap(\.value.image)
        XCTAssertEqual(images.count, 2)
        XCTAssertFalse(images.contains { $0 === source }, "queued images must be copies")
        XCTAssertFalse(images[0] === images[1])
    }

    func testStructuresSaveAndPublishedPortTypesKeepTheirIndex() throws {
        let value = Value.structure(Structure(members: [.init(key: "k", value: .string("v")), .init(key: nil, value: .number(2))]))
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(decoded.isSame(as: value))
        // Saved files store published port types by index, so existing indices must not move.
        XCTAssertEqual(Array(PortType.allCases.prefix(5)), [.number, .bool, .color, .string, .image])
    }

    func testDemoRuns() {
        let g = Graph()
        Demo.structures.build(into: g)
        XCTAssertEqual(g.connections.count, 6)
        let trail = g.nodes.compactMap { $0 as? IteratorPatch }.first!
        XCTAssertEqual(trail.contents.connections.count, 11)
    }
}
