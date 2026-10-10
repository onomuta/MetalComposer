import CoreGraphics
import ImageIO
import XCTest
@testable import MirageMCPCore

final class MCPServerTests: XCTestCase {
    private var server: MCPServer!
    private var nextID = 0

    override func setUpWithError() throws {
        server = try MCPServer()
    }

    private func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        let line = MCPServer.encode(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        let reply = try XCTUnwrap(server.handle(line))
        XCTAssertFalse(reply.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func tool(_ name: String, _ arguments: [String: Any]) throws -> (content: [[String: Any]], isError: Bool) {
        let result = try XCTUnwrap(try request("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
        return (try XCTUnwrap(result["content"] as? [[String: Any]]), result["isError"] as? Bool ?? false)
    }

    private func json(_ content: [[String: Any]]) throws -> [String: Any] {
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testHandshakeAndToolList() throws {
        let initialize = try XCTUnwrap(try request("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18", "a supported version is echoed")
        let unknown = try XCTUnwrap(try request("initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        XCTAssertEqual(unknown["protocolVersion"] as? String, MCPServer.protocolVersions[0])
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")

        let tools = try XCTUnwrap((try request("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["list_patches", "new_composition", "add_patch", "connect", "set_params", "render", "save_composition"])
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

        let missing = try request("resources/list")
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNotNil(server.handle("not json"), "a parse error is answered")
    }

    func testBuildRenderAndSave() throws {
        _ = try tool("new_composition", [:])
        let square = try json(try tool("add_patch", ["type": "billboard",
                                                     "values": ["color": "#FF0000", "width": 2, "height": 2]]).content)
        let id = try XCTUnwrap(square["id"] as? String)
        let values = try json(try tool("set_params", ["patch": String(id.prefix(8)), "values": ["blending": "Add"]]).content)
        XCTAssertEqual(values["blending"] as? String, "Add")

        let render = try tool("render", ["times": [0.5], "width": 64, "height": 36])
        XCTAssertFalse(render.isError)
        let image = try XCTUnwrap(render.content.first { $0["type"] as? String == "image" })
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image["data"] as? String)))
        let cg = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(cg.width, 64)
        // The full-screen red square covers the center.
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: -32, y: -18, width: 64, height: 36))
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertLessThan(pixel[1], 15)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let saved = try tool("save_composition", ["path": folder.appendingPathComponent("square").path])
        XCTAssertFalse(saved.isError)
        let file = folder.appendingPathComponent("square.mcomp")
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual((record?["nodes"] as? [Any])?.count, 2, "Clear and Billboard")
    }

    func testMistakesComeBackAsToolErrors() throws {
        XCTAssertTrue(try tool("add_patch", ["type": "no-such-patch"]).isError)
        let lfo = try XCTUnwrap(try json(try tool("add_patch", ["type": "lfo"]).content)["id"] as? String)
        let board = try XCTUnwrap(try json(try tool("add_patch", ["type": "billboard"]).content)["id"] as? String)
        let badPort = try tool("connect", ["from": lfo, "output": "nope", "to": board, "input": "x"])
        XCTAssertTrue(badPort.isError)
        XCTAssertTrue((badPort.content.first?["text"] as? String ?? "").contains("value"), "lists the real outputs")
        XCTAssertTrue(try tool("connect", ["from": board, "output": "x", "to": lfo, "input": "period"]).isError)
        XCTAssertTrue(try tool("set_params", ["patch": board, "values": ["color": "red"]]).isError)
        XCTAssertTrue(try tool("set_params", ["patch": board, "values": ["image": 1]]).isError)
        // Nothing was changed by a failing set_params.
        let mixed = try tool("set_params", ["patch": board, "values": ["width": 1.5, "nope": 1]])
        XCTAssertTrue(mixed.isError)
        XCTAssertFalse(try tool("connect", ["from": lfo, "output": "value", "to": board, "input": "x"]).isError)
    }

    func testListsPatchesAndTheirPorts() throws {
        let all = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try tool("list_patches", [:]).content.first?["text"] as? String).utf8)) as? [[String: Any]])
        XCTAssertTrue(all.contains { $0["type"] as? String == "particle-system" })
        let detail = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(try tool("list_patches", ["types": ["Text Image"]]).content.first?["text"] as? String).utf8)) as? [[String: Any]])
        let inputs = try XCTUnwrap(detail.first?["inputs"] as? [[String: Any]])
        let spacing = try XCTUnwrap(inputs.first { $0["key"] as? String == "spacing" })
        XCTAssertEqual(spacing["type"] as? String, "menu")
        XCTAssertEqual(spacing["options"] as? [String], ["Proportional", "Monospaced Digits", "Monospaced"])
    }

    // MARK: Safety (what an AI may do through the server)

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testSavesOnlyMcompFilesAndOverwritesOnlyWhenAsked() throws {
        let folder = try temporaryFolder()
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: notes)
        XCTAssertTrue(try tool("save_composition", ["path": notes.path]).isError)
        XCTAssertTrue(try tool("save_composition", ["path": notes.path, "overwrite": true]).isError)
        XCTAssertEqual(try String(contentsOf: notes), "keep me")
        let bundle = folder.appendingPathComponent("folder.mcomp")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertTrue(try tool("save_composition", ["path": bundle.path, "overwrite": true]).isError, "a folder")

        let file = folder.appendingPathComponent("a.mcomp").path
        XCTAssertFalse(try tool("save_composition", ["path": file]).isError)
        XCTAssertTrue(try tool("save_composition", ["path": file]).isError, "exists")
        XCTAssertFalse(try tool("save_composition", ["path": file, "overwrite": true]).isError)
    }

    func testImagesOnlyFromTheCompositionFolderOrAllowedFolders() throws {
        let inside = try temporaryFolder(), outside = try temporaryFolder()
        for folder in [inside, outside] {
            try PlayerFixtures.writePNG(to: folder.appendingPathComponent("green.png"), red: 0, green: 255, blue: 0)
        }
        try Data("secret".utf8).write(to: inside.appendingPathComponent("secret.txt"))
        let importer = try XCTUnwrap(try json(try tool("add_patch", ["type": "image-importer"]).content)["id"] as? String)

        // Nothing is allowed before the composition is saved somewhere.
        XCTAssertTrue(try tool("set_params", ["patch": importer, "values": ["path": inside.appendingPathComponent("green.png").path]]).isError)
        XCTAssertFalse(try tool("save_composition", ["path": inside.appendingPathComponent("c.mcomp").path]).isError)
        XCTAssertFalse(try tool("set_params", ["patch": importer, "values": ["path": "green.png"]]).isError, "relative to the composition")
        XCTAssertFalse(try tool("set_params", ["patch": importer, "values": ["path": inside.appendingPathComponent("green.png").path]]).isError)
        XCTAssertTrue(try tool("set_params", ["patch": importer, "values": ["path": outside.appendingPathComponent("green.png").path]]).isError)
        XCTAssertTrue(try tool("set_params", ["patch": importer, "values": ["path": "../" + outside.lastPathComponent + "/green.png"]]).isError, "no escaping with ..")
        XCTAssertTrue(try tool("set_params", ["patch": importer, "values": ["path": "secret.txt"]]).isError, "images only")
        XCTAssertFalse(try tool("render", ["width": 32, "height": 18]).isError)

        // A folder allowed when the server starts.
        let allowed = try MCPServer(imageFolders: [outside])
        server = allowed
        let other = try XCTUnwrap(try json(try tool("add_patch", ["type": "image-importer"]).content)["id"] as? String)
        XCTAssertFalse(try tool("set_params", ["patch": other, "values": ["path": outside.appendingPathComponent("green.png").path]]).isError)
        XCTAssertEqual(MCPServer.imageFolders(from: ["mirage-mcp", "--allow-images", "/tmp/a", "--allow-images", "~/b"]).map(\.lastPathComponent), ["a", "b"])
    }

    func testMicrophonePatchesAreUnavailable() throws {
        XCTAssertTrue(try tool("add_patch", ["type": "audio-input"]).isError)
        XCTAssertTrue(try tool("add_patch", ["type": "Audio Spectrum"]).isError)
        let all = try XCTUnwrap(try tool("list_patches", ["query": "audio"]).content.first?["text"] as? String)
        XCTAssertFalse(all.contains("audio-input"))
    }
}
