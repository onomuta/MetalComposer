import XCTest
@testable import MirageMCPCore

/// Registering mirage-mcp with AI clients (ADR 0002, step 3). Temporary files only: the real
/// settings of Claude Desktop and Claude Code are never touched by tests.
final class MCPRegistrationTests: XCTestCase {
    private var folder: URL!
    private let server = "/Applications/Mirage MCP.app/Contents/MacOS/mirage-mcp"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { [folder] in try? FileManager.default.removeItem(at: folder!) }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testDesktopChangesOnlyItsOwnEntryAndKeepsACopy() throws {
        let file = folder.appendingPathComponent("claude_desktop_config.json")
        let original: [String: Any] = [
            "mcpServers": ["other": ["command": "/usr/bin/other", "env": ["TOKEN": "secret"]]],
            "preferences": ["theme": "dark"],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let config = ClaudeDesktopConfig(url: file, backups: folder.appendingPathComponent("backups"))

        XCTAssertEqual(config.status(server: server), .notRegistered)
        let backup = try XCTUnwrap(try config.register(server: server))
        XCTAssertEqual(config.status(server: server), .registered)
        let after = try json(file)
        let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["mirage"] as? [String: Any])?["command"] as? String, server)
        XCTAssertEqual(((servers["other"] as? [String: Any])?["env"] as? [String: String])?["TOKEN"], "secret", "other servers untouched")
        XCTAssertEqual((after["preferences"] as? [String: String])?["theme"], "dark", "other settings untouched")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil((try json(backup)["mcpServers"] as? [String: Any])?["mirage"], "the copy is the previous version")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)

        XCTAssertEqual(config.status(server: "/elsewhere/mirage-mcp"), .otherPath(server))
        try config.unregister()
        XCTAssertEqual(config.status(server: server), .notRegistered)
        XCTAssertNotNil((try json(file)["mcpServers"] as? [String: Any])?["other"])

        for _ in 0..<8 { try config.register(server: server) }
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("backups").path)
        XCTAssertEqual(copies.count, 5, "only the newest copies are kept")
    }

    func testDesktopWithoutAFileAndWithABrokenOne() throws {
        let file = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        let config = ClaudeDesktopConfig(url: file, backups: folder.appendingPathComponent("backups"))
        XCTAssertNil(try config.register(server: server), "nothing to copy")
        XCTAssertEqual(config.status(server: server), .registered)

        try Data("{ broken".utf8).write(to: file)
        if case .unknown = config.status(server: server) {} else { XCTFail("a broken file is reported") }
        XCTAssertThrowsError(try config.register(server: server))
        XCTAssertEqual(try String(contentsOf: file), "{ broken", "a file that can't be read is left alone")
    }

    func testClaudeCodeIsOnlyRead() throws {
        let settings = folder.appendingPathComponent(".claude.json")
        let code = ClaudeCode(settingsURL: settings, cli: nil)
        XCTAssertEqual(code.status(server: server), .notRegistered)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["mirage": ["type": "stdio", "command": server]],
                                                    "projects": ["/x": ["history": []]]]).write(to: settings)
        XCTAssertEqual(code.status(server: server), .registered)
        XCTAssertEqual(code.status(server: "/other"), .otherPath(server))
        XCTAssertThrowsError(try code.run(register: true, server: server), "no claude command, nothing runs")

        XCTAssertEqual(ClaudeCode.addCommand(server: server),
                       "claude mcp add --scope user mirage -- '/Applications/Mirage MCP.app/Contents/MacOS/mirage-mcp'")
        XCTAssertEqual(ClaudeCode.addCommand(server: "/opt/mirage-mcp"), "claude mcp add --scope user mirage -- /opt/mirage-mcp")
        XCTAssertEqual(ClaudeCode.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertNil(ClaudeCode.findCLI(home: folder.path).flatMap { $0.path.hasPrefix(folder.path) ? $0 : nil })
    }
}
