import Metal
import simd
import XCTest
@testable import MetalComposerKit

final class CylinderTests: XCTestCase {
    func testVertexLayoutMatchesTheShader() {
        XCTAssertEqual(MemoryLayout<MeshVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<MeshVertex>.offset(of: \.uv), 16)
    }

    func testMeshPartsAndCone() {
        let cylinder = CylinderPatch.mesh(top: 0.25, bottom: 0.25, height: 0.5, segments: 8)
        XCTAssertEqual(cylinder.side.count, 8 * 6)
        XCTAssertEqual(cylinder.top.count, 8 * 3)
        XCTAssertEqual(cylinder.bottom.count, 8 * 3)
        XCTAssertEqual(cylinder.vertices.count, 8 * 12)
        // A cone has no top cap; its side meets at the apex.
        let cone = CylinderPatch.mesh(top: 0, bottom: 0.25, height: 0.5, segments: 8)
        XCTAssertTrue(cone.top.isEmpty)
        XCTAssertTrue(cone.vertices[cone.side].allSatisfy { $0.position.y < 0 || simd_length(SIMD2($0.position.x, $0.position.z)) < 1e-6 })
    }

    private let colors: [String: SIMD4<Float>] = ["color": SIMD4(1, 0, 0, 1), "topColor": SIMD4(0, 1, 0, 1),
                                                  "bottomColor": SIMD4(0, 0, 1, 1)]

    private func centerPart(_ params: [String: Value]) throws -> String? {
        let g = Graph()
        g.put(ClearPatch.self, 0, 0)
        var all = params
        for (key, color) in colors { all[key] = .color(color) }
        g.put(CylinderPatch.self, 200, 0, all)
        let engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let player = try CompositionPlayer(engine: engine, data: try JSONEncoder().encode(g.record()))
        let pixel = try PlayerFixtures.centerPixel(player, engine: engine)
        let rgb = SIMD4<Float>(Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255, 1)
        return colors.first { simd_distance($0.value, rgb) < 0.05 }?.key
    }

    func testSideAndCapsAreWhereExpected() throws {
        XCTAssertEqual(try centerPart([:]), "color")
        XCTAssertEqual(try centerPart(["rotationX": .number(90)]), "topColor")
        XCTAssertEqual(try centerPart(["rotationX": .number(-90)]), "bottomColor")
        XCTAssertNil(try centerPart(["enable": .bool(false)]))
    }
}
