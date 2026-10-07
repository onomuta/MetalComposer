import Metal
import XCTest
import MetalComposerKit // public API only, as a host app (e.g. OnomFlow) would use it

final class PlayerTests: XCTestCase {
    private var engine: MetalComposerEngine!

    override func setUpWithError() throws {
        engine = try MetalComposerEngine(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func render(_ player: CompositionPlayer, time: Double = 0) throws -> [UInt8] {
        try PlayerFixtures.centerPixel(player, engine: engine, time: time)
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

    func testBuiltInDemosLoadAndRender() throws {
        XCTAssertEqual(CompositionPlayer.demoNames.count, 7)
        for name in CompositionPlayer.demoNames where name != "Audio Reactive" {
            let player = try XCTUnwrap(CompositionPlayer(engine: engine, demoNamed: name), name)
            _ = try render(player)
            XCTAssertTrue(player.problems.isEmpty, "\(name): \(player.problems)")
        }
        XCTAssertNil(CompositionPlayer(engine: engine, demoNamed: "No Such Demo"))
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

    func testReportsUnknownPatchesInsteadOfSilentlyDroppingThem() throws {
        // A clear patch plus two patches from "a newer version", one of them inside a macro.
        let data = Data("""
        {"version": 2, "connections": [], "nodes": [
          {"id": "8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A10", "type": "clear", "x": 0, "y": 0,
           "params": {"color": {"t": "c", "v": [0, 0, 1, 1]}}},
          {"id": "8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A11", "type": "future-patch", "x": 0, "y": 0, "params": {}},
          {"id": "8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A12", "type": "macro", "x": 0, "y": 0, "params": {},
           "subgraph": {"connections": [], "nodes": [
             {"id": "8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A13", "type": "future-patch", "x": 0, "y": 0, "params": {}},
             {"id": "8C4C2B4E-3C55-4E3B-9F51-0E1E4E2F6A14", "type": "other-future-patch", "x": 0, "y": 0, "params": {}}]}}]}
        """.utf8)
        let player = try CompositionPlayer(engine: engine, data: data)
        XCTAssertEqual(try render(player), [0, 0, 255, 255], "the known patches still render")
        XCTAssertEqual(player.problems.count, 2)
        XCTAssertTrue(player.problems[0].contains("\"future-patch\""))
        XCTAssertTrue(player.problems[1].contains("\"other-future-patch\""))
    }
}
