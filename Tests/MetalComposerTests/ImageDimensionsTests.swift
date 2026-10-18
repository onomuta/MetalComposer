import Metal
import XCTest
@testable import MetalComposerKit

final class ImageDimensionsTests: XCTestCase {
    func testSizeAndRatio() throws {
        let resources = try RenderResources(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let ctx = EvalContext(resources: resources, commandBuffer: resources.queue.makeCommandBuffer()!,
                              time: 0, deltaTime: 1.0 / 60, viewportSize: CGSize(width: 64, height: 64),
                              mouse: .zero, mouseDown: false)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1080, mipmapped: false)
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: desc))
        let patch = ImageDimensionsPatch()

        let out = patch.evaluate(Inputs(values: ["image": .image(texture)]), ctx)
        XCTAssertEqual(out["width"]?.number, 1920)
        XCTAssertEqual(out["height"]?.number, 1080)
        XCTAssertEqual(try XCTUnwrap(out["ratio"]?.number), 16.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(out["inverse"]?.number), 9.0 / 16, accuracy: 1e-9)

        let none = patch.evaluate(Inputs(values: ["image": .image(nil)]), ctx)
        XCTAssertEqual(["width", "height", "ratio", "inverse"].map { none[$0]?.number }, [0, 0, 0, 0])
    }
}
