import Metal
import simd
import XCTest
@testable import MetalComposerKit

final class CubeTests: XCTestCase {
    private let colors: [String: SIMD4<Float>] = [
        "front": SIMD4(1, 0, 0, 1), "back": SIMD4(0, 0, 1, 1), "left": SIMD4(1, 1, 0, 1),
        "right": SIMD4(0, 1, 0, 1), "top": SIMD4(1, 0, 1, 1), "bottom": SIMD4(0, 1, 1, 1),
    ]

    /// The face seen at the center of the viewer for the given rotation.
    private func centerFace(_ rotation: [String: Double]) throws -> String? {
        let g = Graph()
        g.put(ClearPatch.self, 0, 0)
        var params: [String: Value] = [:]
        for (face, color) in colors { params["\(face)Color"] = .color(color) }
        for (key, degrees) in rotation { params[key] = .number(degrees) }
        g.put(CubePatch.self, 200, 0, params)
        let engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let player = try CompositionPlayer(engine: engine, data: try JSONEncoder().encode(g.record()))
        let pixel = try PlayerFixtures.centerPixel(player, engine: engine)
        let rgb = SIMD4<Float>(Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255, 1)
        return colors.first { simd_distance($0.value, rgb) < 0.05 }?.key
    }

    func testFacesAreWhereTheirNamesSay() throws {
        XCTAssertEqual(try centerFace([:]), "front")
        XCTAssertEqual(try centerFace(["rotationY": 180]), "back")
        // Turning the cube 90° to the right (around Y) brings its left face to the front.
        XCTAssertEqual(try centerFace(["rotationY": 90]), "left")
        XCTAssertEqual(try centerFace(["rotationY": -90]), "right")
        // Tipping it toward the viewer (around X) shows the top face.
        XCTAssertEqual(try centerFace(["rotationX": 90]), "top")
        XCTAssertEqual(try centerFace(["rotationX": -90]), "bottom")
    }
}
