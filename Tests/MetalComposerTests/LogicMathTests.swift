import Metal
import XCTest
@testable import MetalComposerKit

final class LogicMathTests: XCTestCase {
    private var resources: RenderResources!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        resources = try RenderResources(device: device)
    }

    private func run(_ patch: Patch, _ values: [String: Value]) -> Value {
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        var inputs: [String: Value] = [:]
        for spec in patch.allInputs { inputs[spec.key] = (values[spec.key] ?? spec.defaultValue).coerced(to: spec.type) }
        return patch.evaluate(Inputs(values: inputs), ctx)["result"]!
    }

    func testLogicTruthTables() {
        // 演算ごとに (F,F) (F,T) (T,F) (T,T) の結果。
        let tables: [[Bool]] = [
            [false, false, false, true],   // AND
            [false, true, true, true],     // OR
            [false, true, true, false],    // XOR
            [true, true, false, false],    // NOT（First Value だけを見る）
            [true, true, true, false],     // NAND
            [true, false, false, false],   // NOR
        ]
        let logic = LogicPatch()
        for (op, table) in tables.enumerated() {
            for (n, expected) in table.enumerated() {
                let r = run(logic, ["op": .number(Double(op)), "a": .bool(n >= 2), "b": .bool(n % 2 == 1)])
                XCTAssertEqual(r.bool, expected, "op \(op), case \(n)")
            }
        }
    }

    func testRangeClampWrapMirror() {
        let range = RangePatch()
        func r(_ v: Double, _ mode: Int, _ lo: Double = 0, _ hi: Double = 1) -> Double {
            run(range, ["value": .number(v), "mode": .number(Double(mode)), "min": .number(lo), "max": .number(hi)]).number
        }
        XCTAssertEqual(r(1.5, 0), 1)
        XCTAssertEqual(r(-2, 0), 0)
        XCTAssertEqual(r(0.25, 0), 0.25)
        XCTAssertEqual(r(1.25, 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(r(-0.25, 1), 0.75, accuracy: 1e-9)
        XCTAssertEqual(r(1.25, 2), 0.75, accuracy: 1e-9)
        XCTAssertEqual(r(-0.25, 2), 0.25, accuracy: 1e-9)
        XCTAssertEqual(r(2.25, 2), 0.25, accuracy: 1e-9)
        // 最小と最大が逆でも同じ範囲として扱う。幅 0 なら最小値。
        XCTAssertEqual(r(5, 0, 10, 2), 5)
        XCTAssertEqual(r(5, 1, 3, 3), 3)
    }

    func testMapRange() {
        let map = MapRangePatch()
        func m(_ v: Double, clamp: Bool = false) -> Double {
            run(map, ["value": .number(v), "inMin": .number(0), "inMax": .number(1),
                      "outMin": .number(-1), "outMax": .number(1), "clamp": .bool(clamp)]).number
        }
        XCTAssertEqual(m(0.5), 0)
        XCTAssertEqual(m(0.75), 0.5)
        XCTAssertEqual(m(2), 3)
        XCTAssertEqual(m(2, clamp: true), 1)
    }

    func testRoundModesAndStep() {
        let round = RoundPatch()
        func r(_ v: Double, _ mode: Int, step: Double = 1) -> Double {
            run(round, ["value": .number(v), "mode": .number(Double(mode)), "step": .number(step)]).number
        }
        XCTAssertEqual(r(2.5, 0), 3)
        XCTAssertEqual(r(-2.5, 0), -3)
        XCTAssertEqual(r(2.7, 1), 2)
        XCTAssertEqual(r(-2.2, 1), -3)
        XCTAssertEqual(r(2.2, 2), 3)
        XCTAssertEqual(r(-2.7, 3), -2)
        XCTAssertEqual(r(0.37, 0, step: 0.25), 0.25)
        XCTAssertEqual(r(7, 2, step: 5), 10)
        XCTAssertEqual(r(1.6, 0, step: 0), 2)
    }
}
