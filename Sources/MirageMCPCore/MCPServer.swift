import Foundation

/// A Model Context Protocol server over stdio (ADR 0001): one JSON-RPC 2.0 message per line in,
/// one per line out. It offers tools only. Logs go to stderr, never stdout.
package final class MCPServer {
    package static let name = "mirage-mcp"
    package static let version = "0.1.0"
    /// Protocol versions this server speaks, newest first.
    package static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

    private let tools: ToolBox

    /// `imageFolders`: folders Image Importer may read from besides the composition's folder.
    package init(imageFolders: [URL] = []) throws {
        tools = ToolBox(session: try Session(imageFolders: imageFolders))
    }

    /// Folders given as `--allow-images <folder>` (repeatable).
    package static func imageFolders(from arguments: [String]) -> [URL] {
        zip(arguments, arguments.dropFirst()).compactMap { flag, value in
            flag == "--allow-images" ? URL(fileURLWithPath: (value as NSString).expandingTildeInPath) : nil
        }
    }

    /// Reads requests from stdin until it closes.
    package func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// Handles one message and returns the reply line, or nil when none is due (notifications,
    /// and replies from the client).
    package func handle(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = object["id"], let method = object["method"] as? String else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]
        let result: Any
        switch method {
        case "initialize":
            result = initialize(params)
        case "ping":
            result = [String: Any]()
        case "tools/list":
            result = ["tools": ToolBox.definitions]
        case "tools/call":
            result = tools.call(name: params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": Self.name, "version": Self.version],
            "instructions": Self.instructions,
        ]
    }

    static let instructions = """
    Builds and renders Mirage Composer compositions (.mcomp), a node-based real-time visual
    programming environment in the spirit of Quartz Composer, rendered with Metal.
    Work on one composition at a time: new_composition or open it, add patches, connect outputs to
    inputs, set values, render to look at the result, and save. Use list_patches to see what exists
    and list_patches with `types` for their inputs and outputs before using them.
    Consumers (Clear, Billboard, Sprite, Cube, Particle System…) draw in the order they were added;
    put a Clear first. Coordinates: x goes from -1 (left) to 1 (right), y is ±(height/width)
    (±0.5625 at 16:9), +z comes toward the camera, which sits at z = 2. Time is in seconds; the same
    time always gives the same picture. Colors are [r, g, b, a] from 0 to 1.
    """

    static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Could not encode the reply"}}"# }
        return text
    }
}
