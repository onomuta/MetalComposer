import XCTest
import simd
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class TransformTests: XCTestCase {
    private func ndc(_ p: SIMD3<Float>, aspect: Float, model: simd_float4x4 = matrix_identity_float4x4) -> SIMD2<Float> {
        let clip = Camera.projection(aspect: aspect) * Camera.view * model * SIMD4(p, 1)
        return SIMD2(clip.x, clip.y) / clip.w
    }

    func testZeroPlaneKeepsCompositionUnits() {
        // x spans -1…1 and y spans ±h/w, exactly like the old 2D mapping (ndc.y = y * aspect).
        let aspect: Float = 16 / 9
        let p = ndc(SIMD3(1, 0.25, 0), aspect: aspect)
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 0.25 * aspect, accuracy: 1e-5)
    }

    func testPositiveZComesTowardTheViewer() {
        let near = ndc(SIMD3(0.5, 0, 0.5), aspect: 1)
        let far = ndc(SIMD3(0.5, 0, -0.5), aspect: 1)
        XCTAssertGreaterThan(near.x, 0.5)
        XCTAssertLessThan(far.x, 0.5)
    }

    func testTransformAppliesScaleThenRotationThenTranslation() {
        let inputs = Inputs(values: ["tx": .number(0.5), "rz": .number(90), "sx": .number(2), "sy": .number(1), "sz": .number(1)])
        let p = Transform3DPatch.matrix(inputs) * SIMD4<Float>(0.25, 0, 0, 1)
        // (0.25,0) → scale x2 → (0.5,0) → rotate 90° → (0,0.5) → translate → (0.5,0.5)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-5)
    }

    func testOldSpriteFilesStillLoad() throws {
        // Files saved before Billboard existed store a 2D "sprite" with a "rotation" key.
        let json = #"{"nodes":[{"id":"8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A10","type":"sprite","x":0,"y":0,"params":{"rotation":{"t":"n","v":30}}}],"connections":[]}"#
        let g = Graph()
        g.load(try JSONDecoder().decode(GraphRecord.self, from: Data(json.utf8)))
        let sprite = try XCTUnwrap(g.nodes.first as? SpritePatch)
        XCTAssertEqual(sprite.params["rotation"]?.number, 30)
        XCTAssertTrue(sprite.inputPorts.contains { $0.key == "rotation" })
    }
}
