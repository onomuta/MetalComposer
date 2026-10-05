import Metal
import simd
import XCTest
@testable import MetalComposerKit

final class SphereTests: XCTestCase {
    func testMeshIsAClosedUnitSphere() {
        let n = 16, rings = 8
        let mesh = SpherePatch.mesh(segments: n)
        // Each band is two triangles per segment, except the pole bands (one each).
        XCTAssertEqual(mesh.count, (n * rings * 2 - 2 * n) * 3)
        XCTAssertTrue(mesh.allSatisfy { abs(simd_length(SIMD3($0.position.x, $0.position.y, $0.position.z)) - 1) < 1e-5 })
        // The middle of the image (u = 0.5, v = 0.5) is the point facing the viewer.
        let front = mesh.first { abs($0.uv.x - 0.5) < 1e-6 && abs($0.uv.y - 0.5) < 1e-6 }
        XCTAssertEqual(front.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }.map { simd_distance($0, SIMD3(0, 0, 1)) } ?? 1, 0, accuracy: 1e-5)
    }

    private func centerPixel(_ params: [String: Value]) throws -> [UInt8] {
        let g = Graph()
        g.put(ClearPatch.self, 0, 0)
        g.put(SpherePatch.self, 200, 0, params.merging(["color": .color(SIMD4(1, 0, 0, 1))]) { a, _ in a })
        let engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let player = try CompositionPlayer(engine: engine, data: try JSONEncoder().encode(g.record()))
        return try PlayerFixtures.centerPixel(player, engine: engine)
    }

    func testDrawsAtTheCenterUnlessTheRadiusIsZero() throws {
        XCTAssertEqual(try centerPixel([:]), [255, 0, 0, 255])
        XCTAssertEqual(try centerPixel(["radius": .number(0)]), [0, 0, 0, 255])
        XCTAssertEqual(try centerPixel(["x": .number(0.8)]), [0, 0, 0, 255])
    }
}
