import XCTest
@testable import MetalComposer

final class ViewerAspectTests: XCTestCase {
    func testFitsInsideAndKeepsRatio() {
        let space = CGSize(width: 400, height: 400)
        XCTAssertEqual(ViewerAspect.r16x9.fitted(in: space), CGSize(width: 400, height: 225))
        XCTAssertEqual(ViewerAspect.r9x16.fitted(in: space), CGSize(width: 225, height: 400))
        XCTAssertEqual(ViewerAspect.r4x3.fitted(in: CGSize(width: 800, height: 300)), CGSize(width: 400, height: 300))
        XCTAssertEqual(ViewerAspect.free.fitted(in: space), space)
    }

    func testRatios() {
        XCTAssertNil(ViewerAspect.free.ratio)
        XCTAssertEqual(ViewerAspect.r1x1.ratio, 1)
        XCTAssertEqual(ViewerAspect.r21x9.ratio!, 21.0 / 9, accuracy: 1e-9)
    }
}
