import XCTest
@testable import MirageMCPCore

/// The settings and activity record shared between mirage-mcp and the Mirage MCP app (ADR 0002).
final class MCPSupportFilesTests: XCTestCase {
    private var folder: URL!
    private var support: SupportFiles!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-support-\(UUID().uuidString)")
        support = SupportFiles(folder: folder)
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder!) }
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let line = MCPServer.encode(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(server.handle(line)).utf8)) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return (texts.joined(separator: "\n"), result["isError"] as? Bool ?? false)
    }

    private func entries() throws -> [SupportFiles.Entry] {
        guard FileManager.default.fileExists(atPath: support.activityURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: support.activityURL).split(separator: "\n").map {
            try decoder.decode(SupportFiles.Entry.self, from: Data($0.utf8))
        }
    }

    private func writeSettings(_ settings: SupportFiles.Settings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: support.settingsURL)
    }

    func testNoAppFolderNoRecord() throws {
        let server = try MCPServer(support: support)
        XCTAssertFalse(try call(server, "add_patch", ["type": "lfo"]).isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is created without the app")
    }

    func testRecordsEachCallWithShortenedArgumentsAndThumbnails() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let server = try MCPServer(support: support)
        _ = try call(server, "add_patch", ["type": "text-image", "values": ["text": String(repeating: "x", count: 5000)]])
        _ = try call(server, "add_patch", ["type": "no-such-patch"])
        _ = try call(server, "render", ["times": [0, 1], "width": 64, "height": 36])
        let saved = folder.appendingPathComponent("work/a.mcomp")
        _ = try call(server, "save_composition", ["path": saved.path])

        let log = try entries()
        XCTAssertEqual(log.map(\.tool), ["add_patch", "add_patch", "render", "save_composition"])
        XCTAssertEqual(log.map(\.ok), [true, false, true, true])
        XCTAssertLessThan(log[0].arguments.count, 700, "long values are shortened")
        XCTAssertTrue(log[0].arguments.contains("5000 characters"))
        XCTAssertTrue(log[1].message.contains("Unknown patch type"))
        XCTAssertEqual(log[2].thumbnails.count, 2)
        for name in log[2].thumbnails {
            XCTAssertTrue(FileManager.default.fileExists(atPath: support.thumbnailsFolder.appendingPathComponent(name).path))
        }
        XCTAssertEqual(log[3].saved, saved.standardizedFileURL.path)
        let permissions = try FileManager.default.attributesOfItem(atPath: support.activityURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "only the user can read the record")
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: support.thumbnailsFolder.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderPermissions, 0o700)
    }

    func testPausedRefusesEverythingAndFailsSafe() throws {
        let server = try MCPServer(support: support)
        try writeSettings(SupportFiles.Settings(paused: true))
        let paused = try call(server, "add_patch", ["type": "lfo"])
        XCTAssertTrue(paused.isError)
        XCTAssertTrue(paused.text.contains("paused"))
        XCTAssertEqual(try entries().last?.ok, false, "refusals are recorded too")

        try writeSettings(SupportFiles.Settings(paused: false))
        XCTAssertFalse(try call(server, "add_patch", ["type": "lfo"]).isError, "takes effect on the next call")

        try Data("{ not json".utf8).write(to: support.settingsURL)
        let broken = try call(server, "add_patch", ["type": "lfo"])
        XCTAssertTrue(broken.isError, "unreadable settings mean paused")
        XCTAssertTrue(broken.text.contains("can't be read"))
    }

    func testFoldersAllowedInTheApp() throws {
        let images = folder.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try PlayerFixtures.writePNG(to: images.appendingPathComponent("green.png"), red: 0, green: 255, blue: 0)
        let server = try MCPServer(support: support)
        let id = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try call(server, "add_patch", ["type": "image-importer"]).text.utf8)) as? [String: Any])["id"] as? String
        let path = images.appendingPathComponent("green.png").path
        XCTAssertTrue(try call(server, "set_params", ["patch": try XCTUnwrap(id), "values": ["path": path]]).isError)
        try writeSettings(SupportFiles.Settings(imageFolders: [images.path]))
        XCTAssertFalse(try call(server, "set_params", ["patch": try XCTUnwrap(id), "values": ["path": path]]).isError)
    }
}
