import Metal
import XCTest
@testable import MetalComposerKit
@testable import MetalComposerEditor

final class EmbeddedImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mc-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder!) }
    }

    func testEmbeddingCopiesTheFileAndTurningItOffDropsTheCopy() throws {
        let file = folder.appendingPathComponent("green.png")
        try PlayerFixtures.writePNG(to: file, red: 0, green: 255, blue: 0)
        let c = Composition()
        let importer = ImageImporterPatch()
        c.graph.nodes.append(importer)
        c.setParam(importer, "path", .string(file.path))
        XCTAssertNil(importer.params["data"])

        c.setParam(importer, "embed", .bool(true))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(importer.params["data"]?.string)), try Data(contentsOf: file))
        XCTAssertGreaterThan(importer.embeddedByteCount, 0)

        // Choosing another file while embedding replaces the copy.
        let other = folder.appendingPathComponent("red.png")
        try PlayerFixtures.writePNG(to: other, red: 255, green: 0, blue: 0)
        c.setParam(importer, "path", .string(other.path))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(importer.params["data"]?.string)), try Data(contentsOf: other))

        c.setParam(importer, "embed", .bool(false))
        XCTAssertNil(importer.params["data"])
        XCTAssertEqual(importer.embeddedByteCount, 0)
    }

    func testEmbeddedImageRendersWithoutTheFile() throws {
        let file = folder.appendingPathComponent("green.png")
        try PlayerFixtures.writePNG(to: file, red: 0, green: 255, blue: 0)
        let c = Composition()
        let importer = ImageImporterPatch()
        let board = BillboardPatch()
        board.params["width"] = .number(4)
        board.params["height"] = .number(4)
        c.graph.nodes += [importer, board]
        c.graph.link(importer, "image", board, "image")
        c.setParam(importer, "path", .string(file.path))
        c.setParam(importer, "embed", .bool(true))
        let saved = try c.encoded()
        try FileManager.default.removeItem(at: file)

        let engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let player = try CompositionPlayer(engine: engine, data: saved)
        XCTAssertEqual(try PlayerFixtures.centerPixel(player, engine: engine), [0, 255, 0, 255])
        XCTAssertTrue(player.problems.isEmpty)
    }
}
