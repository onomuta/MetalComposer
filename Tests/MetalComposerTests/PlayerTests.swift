import Metal
import XCTest
import MetalComposerKit // public API only, as a host app (e.g. OnomFlow) would use it

final class PlayerTests: XCTestCase {
    private var engine: MetalComposerEngine!

    override func setUpWithError() throws {
        engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// Renders one frame into a 16×16 texture and returns the center pixel as (r, g, b, a).
    private func render(_ player: CompositionPlayer, time: Double = 0) throws -> [UInt8] {
        let device = engine.device
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalComposerEngine.pixelFormat, width: 16, height: 16, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let target = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        player.encode(into: target, time: time, commandBuffer: cb)
        if desc.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: 4)
        target.getBytes(&bgra, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
        return [bgra[2], bgra[1], bgra[0], bgra[3]]
    }

    func testParametersAreListedAndDriveTheComposition() throws {
        let player = try CompositionPlayer(engine: engine, data: PlayerFixtures.redParameter())
        XCTAssertEqual(player.parameters.map(\.name), ["Red", "Flag"])
        XCTAssertEqual(player.parameters.map(\.type), [.number, .boolean])
        guard case .number(let d) = player.parameters[0].defaultValue else { return XCTFail("number default") }
        XCTAssertEqual(d, 0.25)

        XCTAssertEqual(Int(try render(player)[0]), 64, accuracy: 2, "default value 0.25")
        player.setValue(.number(1), forParameter: player.parameters[0].key)
        XCTAssertEqual(try render(player, time: 1 / 60.0), [255, 0, 0, 255])
    }

    func testRelativeImagePathResolvesAgainstTheCompositionFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mc-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try PlayerFixtures.writePNG(to: folder.appendingPathComponent("images/green.png"), red: 0, green: 255, blue: 0)
        let file = folder.appendingPathComponent("logo.mcomp")
        try PlayerFixtures.relativeImage("images/green.png").write(to: file)

        let player = try CompositionPlayer(engine: engine, contentsOf: file)
        XCTAssertEqual(try render(player), [0, 255, 0, 255])
        XCTAssertTrue(player.problems.isEmpty)
    }

    func testReportsMissingFilesAndRejectsNewerFormats() throws {
        let player = try CompositionPlayer(engine: engine, data: PlayerFixtures.relativeImage("nowhere.png"),
                                           baseDirectory: FileManager.default.temporaryDirectory)
        _ = try render(player)
        XCTAssertEqual(player.problems.count, 1)
        XCTAssertThrowsError(try CompositionPlayer(engine: engine, data: PlayerFixtures.futureVersion()))
    }
}
