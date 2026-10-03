import XCTest
@testable import MetalComposer

final class PortSpecTests: XCTestCase {
    private var allNumberSpecs: [(String, PortSpec)] {
        PatchRegistry.all.flatMap { t in t.inputSpecs.filter { $0.type == .number && $0.options == nil }.map { (t.title, $0) } }
    }

    func testRangeIsAGuideAndLimitsClamp() {
        let free = PortSpec.number("v", "V", 0, 0...1)
        XCTAssertEqual(free.clamped(5), 5, "a suggested range must not restrict the value")
        let count = PortSpec.number("n", "N", 1, 1...100).limited(1...200)
        XCTAssertEqual(count.clamped(0), 1)
        XCTAssertEqual(count.clamped(500), 200)
        XCTAssertEqual(PortSpec.number("t", "T", 1).limited(min: 0.5).clamped(1e9), 1e9)
    }

    func testPositionsAndAnglesAreUnbounded() {
        for (title, spec) in allNumberSpecs where spec.name.contains("Position") || spec.name.contains("Translation")
            || spec.name.contains("(°)") && !spec.name.contains("Spread") {
            XCTAssertNil(spec.range, "\(title).\(spec.name) should not have a slider range")
            XCTAssertNil(spec.limits, "\(title).\(spec.name) should not be limited")
            XCTAssertNotNil(spec.step, "\(title).\(spec.name) needs a knob step")
        }
    }

    func testDefaultsSitInsideLimits() {
        for (title, spec) in allNumberSpecs {
            let v = spec.defaultValue.number
            XCTAssertEqual(spec.clamped(v), v, "\(title).\(spec.name) default \(v) is outside its limits")
        }
    }
}
